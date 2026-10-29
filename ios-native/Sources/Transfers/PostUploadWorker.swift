import Foundation
import UIKit

/// What brings the post-upload work round: the engine calls it, never waiting for the work.
enum FollowUpTrigger: Hashable, Sendable {
    /// The engine started: work a process that ended left behind.
    case started
    /// A job's result was committed.
    case committed(TransferLane)
    /// The library lane ran jobs and has nothing runnable now: today's end of a backup run.
    case drained
    /// The user asked for a run now, which also retries failed follow-ups.
    case manualRun
    /// The user retried every failure, the follow-ups' among them.
    case retried
    /// A device condition changed (power, temperature): a pass the conditions stopped runs again.
    case conditionsChanged
    /// A row's backoff after a failure that may pass by itself ran out.
    case retryDue
}

/// The work an upload leaves for later (B4), beside the engine in each account's TransferRuntime (B9).
///
/// It runs beside the engine, never inside a job, so nothing it meets un-confirms a backup or stops
/// the engine's run: a photo stays backed up, with its receipt, whatever an album, stack or linked
/// album does. Each pass:
/// 1. album destinations whose photo's server ID is known: one PUT albums/<id>/assets per album
///    with at most 500 IDs; an ID the server already had in the album (duplicate) counts as done;
/// 2. stack tasks: a photo backed up again under a new server ID is stacked on its earlier copy,
///    the new one on top, as the old backup did;
/// 3. after a run, with Sync albums on, linked-album sync: each included phone album's backed-up
///    photos join the server album linked to it, found by name or made, each album on its own, so
///    one that fails doesn't stop the others.
/// A failure only the user can change (no permission, an album or asset that is gone, a refusal)
/// fails that row, which a manual run or Retry tries again. One that may pass by itself (the
/// network, the server) leaves it pending, at most five times, each time backing off longer
/// (30 s, 1, 2 and 4 min) before a pass tries it again, so a short outage during a run doesn't
/// use up its tries on the commits that follow. One about the account (an expired session,
/// read-only mode) stops the pass and blames nothing, and so do the device's conditions (Require
/// charging, a hot phone), checked before each request as the old backup did.
actor PostUploadWorker {
    /// IDs per PUT albums/<id>/assets, as today's linked-album sync sends them.
    static let batchSize = 500
    /// Tries that fail for a reason that may pass by itself before a row counts as failed.
    static let attempts = TransferFailureClassifier.unknownAttempts

    private let store: TransferStore
    private let server: any TransferServerAPI
    private let photos: any PhotoLibraryStaging
    private let authorization: any TransferAuthorizing

    /// Triggers not yet served, merged: a pass serves every one that came before it started.
    private var pending: Set<FollowUpTrigger> = []
    private var loop: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false
    /// The token the worker started under: a pass stops once the session changes.
    private var tokenDigest: String?
    private let now: @Sendable () -> Date
    /// Whether the device's conditions let transfers run, given Require charging.
    private let conditionsPermit: @Sendable (_ requireCharging: Bool) async -> Bool
    /// Rows that failed for a reason that may pass by itself, with when a pass may try them again.
    /// Kept in memory: a relaunch tries them at once, and their attempts still count.
    private var backoff: [RowKey: Date] = [:]
    private var retryWake: Task<Void, Never>?
    /// A pass that was to sync linked albums stopped first: the next pass syncs them.
    private var linkedAlbumsOwed = false
    /// Require charging, as the pass under way read it.
    private var requireCharging = false

    private enum RowKey: Hashable {
        case album(String, localID: String)
        case stack(Int64)
    }

    /// What the last pass did, for diagnostics and the backup screens.
    private(set) var lastReport = PostUploadReport()

    init(store: TransferStore, server: any TransferServerAPI, photos: any PhotoLibraryStaging, authorization: any TransferAuthorizing,
         now: @escaping @Sendable () -> Date = { Date() },
         conditionsPermit: @escaping @Sendable (_ requireCharging: Bool) async -> Bool = PostUploadWorker.deviceConditionsPermit) {
        self.store = store
        self.server = server
        self.photos = photos
        self.authorization = authorization
        self.now = now
        self.conditionsPermit = conditionsPermit
        tokenDigest = authorization.current()?.tokenDigest
    }

    /// As the old backup's conditionsPermitBackup: not while the phone is hot, and only while charging
    /// when Require charging is on.
    static let deviceConditionsPermit: @Sendable (Bool) async -> Bool = { requireCharging in
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious, thermal != .critical else { return false }
        guard requireCharging else { return true }
        return await MainActor.run { [.charging, .full].contains(UIDevice.current.batteryState) }
    }

    /// How long a row waits after its `attempts`th failure that may pass by itself.
    static func backoffDelay(afterAttempts attempts: Int) -> TimeInterval {
        30 * pow(2, Double(min(max(attempts, 1), 8) - 1))
    }

    /// Asks for a pass, returning at once: the engine never waits for post-upload work.
    nonisolated func wake(_ trigger: FollowUpTrigger) {
        Task { await self.request(trigger) }
    }

    /// Returns once every pass asked for so far has run.
    func idle() async {
        guard loop != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Ends the pass under way at its next step, and every pass after it.
    func stop() async {
        stopped = true
        pending = []
        retryWake?.cancel()
        retryWake = nil
        loop?.cancel()
        await loop?.value
    }

    /// Asks for a pass and returns once it is asked: `idle()` then waits for it.
    func request(_ trigger: FollowUpTrigger) {
        guard !stopped else { return }
        pending.insert(trigger)
        guard loop == nil else { return }
        loop = Task { await self.serve() }
    }

    private func serve() async {
        while !pending.isEmpty, !stopped, !Task.isCancelled {
            let triggers = pending
            pending = []
            // The user asked: what backs off is tried now.
            if triggers.contains(.manualRun) || triggers.contains(.retried) { backoff = [:] }
            if triggers.contains(.manualRun) { _ = try? await store.requeueFailedFollowUps() }
            let linked = linkedAlbumsOwed || triggers.contains(.drained) || triggers.contains(.manualRun)
            lastReport = await runPass(linkedAlbums: linked)
            if linked { linkedAlbumsOwed = lastReport.stopped }
            scheduleRetryWake()
        }
        loop = nil
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: A pass

    /// Runs one pass now and says what it did. Linked albums sync only when asked, and only with
    /// Sync albums on.
    func runPass(linkedAlbums: Bool) async -> PostUploadReport {
        var report = PostUploadReport()
        let started = now()
        backoff = backoff.filter { $0.value > started }
        do {
            let preferences = try await store.preferences()
            requireCharging = preferences?.requireCharging ?? false
            try await addToAlbums(&report)
            try await stack(&report)
            if linkedAlbums, preferences?.syncAlbums == true { try await syncLinkedAlbums(&report) }
        } catch let stop as PassStopped {
            report.stoppedBy = stop.restriction
            report.waitingForDevice = stop.waitingForDevice
            report.stopped = true
        } catch {
            // The database failed: nothing was decided, the next pass tries again.
            report.stopped = true
            report.message = error.localizedDescription
        }
        return report
    }

    private struct PassStopped: Error {
        let restriction: AccountRestriction?
        var waitingForDevice = false
    }

    /// Throws PassStopped unless the account may change things on the server now and the device's
    /// conditions let transfers run.
    private func ensureAllowed() async throws {
        try checkCancellation()
        guard let snapshot = authorization.current() else { throw PassStopped(restriction: .signedOut) }
        if let tokenDigest, snapshot.tokenDigest != tokenDigest { throw PassStopped(restriction: .sessionExpired) }
        if snapshot.requiresPasswordChange { throw PassStopped(restriction: .passwordChange) }
        if snapshot.readOnly { throw PassStopped(restriction: .readOnly) }
        guard await conditionsPermit(requireCharging) else { throw PassStopped(restriction: nil, waitingForDevice: true) }
        try checkCancellation()
    }

    /// Records a row's outcome for its backoff: a retry waits, anything else forgets it.
    private func noteBackoff(_ key: RowKey, _ outcome: FollowUpOutcome, attempts: Int) {
        if case .retry = outcome {
            backoff[key] = now().addingTimeInterval(Self.backoffDelay(afterAttempts: attempts + 1))
        } else {
            backoff[key] = nil
        }
    }

    /// Asks for a pass when the earliest backoff runs out.
    private func scheduleRetryWake() {
        retryWake?.cancel()
        retryWake = nil
        guard !stopped, let due = backoff.values.min() else { return }
        let delay = max(due.timeIntervalSince(now()), 0)
        retryWake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.request(.retryDue)
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled || stopped { throw PassStopped(restriction: nil) }
    }

    // MARK: Albums

    private func addToAlbums(_ report: inout PostUploadReport) async throws {
        for album in try await store.albumsWithRunnableDestinations() {
            var after: String?
            while true {
                let page = try await store.runnableAlbumDestinations(album: album, after: after, limit: Self.batchSize)
                guard let last = page.last else { break }
                after = last.localID
                let rows = page.filter { backoff[.album(album, localID: $0.localID)] == nil }
                guard !rows.isEmpty else { continue }
                try await ensureAllowed()
                let ids = Array(Set(rows.compactMap(\.remoteID))).sorted()
                let outcomes: [(row: AlbumDestinationRow, outcome: FollowUpOutcome)]
                do {
                    let results = try await server.addToAlbum(album, assetIDs: ids)
                    let byID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    outcomes = rows.map { row in
                        guard let result = row.remoteID.flatMap({ byID[$0] }) else {
                            return (row, row.attempts + 1 >= Self.attempts ? .failed(Self.albumMessage) : .retry("The server did not answer for this photo."))
                        }
                        if result.success || result.error == "duplicate" { return (row, .done) }
                        return (row, .failed(Self.albumMessage))
                    }
                } catch {
                    let decision = try decide(error, attempts: rows.map(\.attempts).max() ?? 0, message: Self.albumMessage)
                    outcomes = rows.map { ($0, decision) }
                }
                try await store.finishAlbumDestinations(album: album, outcomes)
                for (row, outcome) in outcomes {
                    report.count(outcome, in: \.albums)
                    noteBackoff(.album(album, localID: row.localID), outcome, attempts: row.attempts)
                }
                if outcomes.contains(where: { if case .failed = $0.outcome { true } else { false } }) { report.failedAlbums.insert(album) }
            }
        }
    }

    // MARK: Stacks

    private func stack(_ report: inout PostUploadReport) async throws {
        for task in try await store.pendingStackTasks() where backoff[.stack(task.id)] == nil {
            try await ensureAllowed()
            let outcome: FollowUpOutcome
            do {
                try await server.createStack([task.assetID, task.previousAssetID])
                outcome = .done
            } catch {
                outcome = try decide(error, attempts: task.attempts, message: Self.stackMessage)
            }
            try await store.finishStackTask(task.id, outcome)
            report.count(outcome, in: \.stacks)
            noteBackoff(.stack(task.id), outcome, attempts: task.attempts)
        }
    }

    // MARK: Linked albums

    /// As the old backup's syncLinkedAlbums, but each album on its own: the server's owned albums,
    /// then for each included phone album with backed-up photos the server album linked to it,
    /// else the one with its name, else a new one, linked, and its photos added 500 at a time.
    private func syncLinkedAlbums(_ report: inout PostUploadReport) async throws {
        guard let preferences = try await store.preferences() else { return }
        try await ensureAllowed()
        var remote: [Album]
        do { remote = try await server.ownedAlbums() } catch {
            // Nothing can be matched without the server's albums; the next run tries again.
            if case .stop(let restriction) = classify(error, attempts: 0) { throw PassStopped(restriction: restriction) }
            report.linkedFailures["*"] = Self.linkedMessage
            return
        }
        var linked = try await store.linkedAlbums()
        let included = await photos.albums().filter { preferences.includedAlbums.contains($0.id) && !preferences.excludedAlbums.contains($0.id) }
        for local in included.sorted(by: { $0.id < $1.id }) {
            try checkCancellation()
            let members = await photos.albumMembers(local.id, excluded: preferences.excludedAlbums)
            let assetIDs = Set(try await store.receipts(for: members).values.map(\.original.id)).sorted()
            guard !assetIDs.isEmpty else { continue }
            try await ensureAllowed()
            do {
                let album: Album
                if let existing = remote.first(where: { $0.id == linked[local.id] }) ?? remote.first(where: { $0.albumName == local.title }) {
                    album = existing
                } else {
                    album = try await server.createAlbum(name: local.title)
                    remote.append(album)
                }
                if linked[local.id] != album.id {
                    try await store.linkAlbum(device: local.id, to: album.id)
                    linked[local.id] = album.id
                }
                for offset in stride(from: 0, to: assetIDs.count, by: Self.batchSize) {
                    try await ensureAllowed()
                    let batch = Array(assetIDs[offset..<min(offset + Self.batchSize, assetIDs.count)])
                    let results = try await server.addToAlbum(album.id, assetIDs: batch)
                    guard results.count == batch.count, results.allSatisfy({ $0.success || $0.error == "duplicate" }) else {
                        throw LinkedAlbumRefused()
                    }
                }
                report.linkedAlbums += 1
            } catch let stop as PassStopped {
                throw stop
            } catch {
                if case .stop(let restriction) = classify(error, attempts: 0) { throw PassStopped(restriction: restriction) }
                report.linkedFailures[local.id] = "Some backed-up photos could not be added to \(local.title). Check album permissions and retry."
            }
        }
    }

    private struct LinkedAlbumRefused: Error {}

    // MARK: Failures

    private enum Decision {
        case outcome(FollowUpOutcome)
        case stop(AccountRestriction?)
    }

    /// The row's outcome for a failed call, or PassStopped for one about the account or the network.
    private func decide(_ error: any Error, attempts: Int, message: String) throws -> FollowUpOutcome {
        switch classify(error, attempts: attempts) {
        case .stop(let restriction): throw PassStopped(restriction: restriction)
        case .outcome(.failed): return .failed(message)
        case .outcome(let outcome): return outcome
        }
    }

    private func classify(_ error: any Error, attempts: Int) -> Decision {
        if error is CancellationError || Task.isCancelled { return .stop(nil) }
        switch error {
        // No permission, or the album or asset is gone: only the user changes that.
        case ServerFailure.forbidden(_), ServerFailure.notFound: return .outcome(.failed(error.localizedDescription))
        default: break
        }
        switch TransferFailureClassifier.classify(error, context: TransferFailureClassifier.Context(retryCount: attempts)) {
        case .item(let message): return .outcome(.failed(message))
        case .account(let restriction): return .stop(restriction)
        // Offline, or the server backing off: no other row would fare better now.
        case .waiting: return .stop(nil)
        case .transient:
            return .outcome(attempts + 1 >= Self.attempts ? .failed(error.localizedDescription) : .retry(error.localizedDescription))
        }
    }

    static let albumMessage = "The photo was backed up but could not be added to the album. Check album permissions and retry."
    static let stackMessage = "The photo was backed up but could not be stacked with its earlier version."
    static let linkedMessage = "Albums could not be synced. Check the connection and retry."
}

/// What one post-upload pass did.
struct PostUploadReport: Hashable, Sendable {
    struct Counts: Hashable, Sendable {
        var done = 0
        var retrying = 0
        var failed = 0
    }

    var albums = Counts()
    var stacks = Counts()
    /// Server albums with a destination that failed in this pass.
    var failedAlbums: Set<String> = []
    /// Linked phone albums synced, and those that failed with why, by phone album ID ("*" when the
    /// server's albums could not be read).
    var linkedAlbums = 0
    var linkedFailures: [String: String] = [:]
    /// The pass ended early: the account stopped it (an expired session, read-only mode), the
    /// network did, or the worker stopped.
    var stopped = false
    var stoppedBy: AccountRestriction?
    /// The device's conditions (Require charging, a hot phone) stopped it.
    var waitingForDevice = false
    var message: String?

    mutating func count(_ outcome: FollowUpOutcome, in counts: WritableKeyPath<PostUploadReport, Counts>) {
        switch outcome {
        case .done: self[keyPath: counts].done += 1
        case .retry: self[keyPath: counts].retrying += 1
        case .failed: self[keyPath: counts].failed += 1
        }
    }
}

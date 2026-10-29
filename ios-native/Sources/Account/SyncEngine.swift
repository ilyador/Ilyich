import Foundation
import Synchronization

/// What the screens show of the library's sync. SyncEngine is its only writer.
struct SyncStatus: Equatable, Sendable {
    /// A pass is running, or about to.
    var isSyncing = false
    /// Why the last pass, or the live connection, failed. A pass that succeeds clears it.
    var error: String?
    /// When the offline library last finished a pass.
    var lastSyncDate: Date?
}

/// The account's sync status, where the screens read it. Only SyncEngine writes it.
@MainActor @Observable final class SyncStatusBoard {
    private(set) var status = SyncStatus()
    /// The newest status shown, so one that arrives late never replaces a newer one.
    @ObservationIgnored private var shown: UInt64 = 0

    fileprivate func show(_ status: SyncStatus, sequence: UInt64) {
        guard sequence > shown else { return }
        shown = sequence
        if self.status != status { self.status = status }
    }
}

/// The account's library sync. It decides when a pass runs: when the app comes to the front,
/// when Diagnostics asks, when a hint arrives on the live connection, when the library refreshes
/// after a change and when a background backup window needs the library. Requests are numbered
/// as they arrive, and a pass serves the requests made before it started, so a request made
/// during a pass gets a pass of its own and none is lost. Every pass publishes what it changed as
/// a LibraryChange, unless it changed nothing, and the engine is the only writer of SyncStatus.
/// It belongs to one AccountRuntime; once that closes, nothing it began changes anything.
actor SyncEngine {
    private struct Waiter {
        let sequence: UInt64
        /// A background window's lease: the epoch it holds. Nil for anyone else.
        var lease: AuthorizationEpoch?
        /// What the passes that finished since it asked changed.
        var change: LibraryChange?
        let continuation: CheckedContinuation<LibraryChange, any Error>
    }

    private let client: APIClient
    private let entities: LibraryIndex
    private let native: NativeSync
    private let pipeline: MediaPipeline
    private let repairer: DependentRepairer
    /// Fetching the dependents the index queued for repair, while the app is in front.
    private var repairs: Task<Void, Never>?
    private let presence: AppPresence
    private let check: SessionCheck
    private let authorization: AuthorizationState
    private let device: any AccountDevice
    private let board: SyncStatusBoard
    private let connect: @Sendable () async throws -> ServerEventConnection
    private let debounce: Duration

    /// Until the account's runtime closes.
    private(set) var isOpen = true
    /// The app is in front: every return syncs, and the live connection is open.
    private var foreground = false
    /// The last request made, and the last one a finished pass served. Requests above
    /// `completed` wait for a pass that starts after them.
    private var requested: UInt64 = 0
    private var completed: UInt64 = 0
    /// The last request whose pass clears the error shown when it starts, as Sync now does.
    private var clearingError: UInt64 = 0
    /// Runs passes one after another while requests wait.
    private var runner: Task<Void, Never>?
    private var pass: Task<IndexChange, any Error>?
    /// The engine stopped the pass in flight, which therefore failed no one.
    private var passStopped = false
    private var waiters: [UUID: Waiter] = [:]
    /// Hints from the live connection that no pass has taken yet.
    private var hints = ServerInvalidation()
    private var live: Task<Void, Never>?
    /// Moves whenever the live connection stops, so one stopped never starts again.
    private var liveGeneration: UInt64 = 0
    private var resetting = false
    /// A server reset's memory was cleared and its sweep still waits for a complete index.
    private var resetSeen = false
    private var status = SyncStatus()
    private var statusSequence: UInt64 = 0
    /// Where the engine's changes go: media first, then the screens and every subscriber.
    let hub: LibraryChangeHub

    /// `connect` opens the live connection, the client's own by default. `hub` takes the engine's
    /// changes to the screens and the account's services; one that tells no screen by default.
    init(client: APIClient, entities: LibraryIndex, native: NativeSync, pipeline: MediaPipeline,
         presence: AppPresence, check: SessionCheck, authorization: AuthorizationState, device: any AccountDevice,
         status: SyncStatusBoard, connect: (@Sendable () async throws -> ServerEventConnection)? = nil,
         debounce: Duration = .milliseconds(350), dependents: (any DependentFetching)? = nil, hub: LibraryChangeHub? = nil) {
        self.client = client
        self.entities = entities
        self.native = native
        self.pipeline = pipeline
        repairer = DependentRepairer(index: entities, fetcher: dependents ?? ServerDependentFetcher(client: client))
        self.presence = presence
        self.check = check
        self.authorization = authorization
        self.device = device
        board = status
        self.connect = connect ?? { try await client.serverEvents() }
        self.debounce = debounce
        self.hub = hub ?? LibraryChangeHub(pipeline: pipeline)
    }

    // MARK: Commands

    /// The account opened. From now on sync follows the app: it runs while the app is in front.
    func start() async {
        guard isOpen else { return }
        // The client reads the offline library when the server can't be reached, and Diagnostics
        // counts it, once it is attached. A pass needs it no sooner.
        await client.attachEntityStore(entities)
        guard isOpen else { return }
        presenceChanged()
        let date = try? await entities.lastSyncDate()
        if isOpen, let date, status.lastSyncDate == nil { update { $0.lastSyncDate = date } }
    }

    /// The app came to the front, or left it, as `presence` now says. Coming back from the
    /// background syncs once, and the live connection opens after that pass. Becoming active
    /// again without leaving the front, after Control Center or the app switcher, syncs once too
    /// unless a pass is already running, since the live connection may be between retries.
    /// Leaving stops the live connection and every pass except one a background backup window holds.
    func presenceChanged() {
        guard isOpen else { return }
        let front = presence.isForeground
        guard front != foreground else {
            if front, runner == nil { requestPass(clearingError: false) }
            return
        }
        foreground = front
        if front {
            requestPass(clearingError: true)
        } else {
            stopLive()
            repairs?.cancel()
            for (id, waiter) in waiters where waiter.lease == nil {
                waiters[id] = nil
                waiter.continuation.resume(throwing: CancellationError())
            }
            dropPassesNobodyNeeds()
        }
    }

    /// Diagnostics' Sync now.
    func syncNow() {
        guard isOpen else { return }
        requestPass(clearingError: true)
    }

    /// Runs a pass that starts after this call and returns what changed since the call, once it
    /// is published. The library refreshes this way after a change it made, and on pull to refresh.
    func refresh() async throws -> LibraryChange {
        try await waitForPass(lease: nil)
    }

    /// Syncs once for a background backup window and returns whether the library is ready for it.
    /// The window holds a lease on the pass: when the window ends first, the pass stops unless the
    /// app is in front or someone else waits for it. The lease is tied to the authorization epoch,
    /// which only the session ending moves under it.
    func prepareForBackgroundBackup() async -> Bool {
        guard isOpen else { return false }
        do {
            _ = try await waitForPass(lease: authorization.snapshot.epoch)
            return isOpen
        } catch { return false }
    }

    /// Recreates the offline library from the server: the pass in flight stops, the index is
    /// emptied, and a pass rebuilds it once the app is in front.
    func resetLibraryMetadata() async {
        guard isOpen, !resetting else { return }
        resetting = true
        update { $0.isSyncing = true; $0.error = nil }
        stopLive()
        stopPass()
        await runner?.value
        guard isOpen else { resetting = false; return }
        do {
            try await entities.clear()
            guard isOpen else { resetting = false; return }
            // The index's month places went with its derived tables; a count that landed between
            // the clear and the epoch's move goes too.
            moveAccessEpoch()
            try? await entities.clearMonthPlaces()
            var change = LibraryChange(account: authorization.account, authorization: authorization.snapshot.epoch,
                                       indexRevision: await entities.revision, origin: .sync)
            change.reset = true
            await publish(change, accessChanged: false)
            resetting = false
            if foreground { requestPass(clearingError: true) } else { startRunnerIfNeeded() }
        } catch {
            resetting = false
            if isOpen { update { $0.error = error.localizedDescription } }
            startRunnerIfNeeded()
        }
        showSyncing()
    }

    /// Sign-out: nothing begun here changes anything any more. Stops the pass and the live
    /// connection, answers everyone waiting, and waits for the pass to end. The live connection
    /// is not waited for: one still connecting waits out the server's address check, which
    /// cancelling doesn't end, and once stopped it changes nothing.
    func shutdown() async {
        isOpen = false
        let runner = runner, repairs = repairs
        repairs?.cancel()
        stopLive()
        stopPass()
        for waiter in waiters.values { waiter.continuation.resume(throwing: CancellationError()) }
        waiters.removeAll()
        await hub.close()
        await runner?.value
        await repairs?.value
        update { $0.isSyncing = false }
    }

    /// How many callers wait for a pass.
    var waiting: Int { waiters.count }

    /// Every change the engine publishes from now on, until the account closes.
    func changes() async -> AsyncStream<LibraryChange> {
        await hub.subscribe()
    }

    // MARK: Passes

    @discardableResult
    private func requestPass(clearingError clears: Bool) -> UInt64 {
        requested &+= 1
        if clears { clearingError = requested }
        startRunnerIfNeeded()
        return requested
    }

    private func startRunnerIfNeeded() {
        guard isOpen, !resetting, runner == nil, completed < requested else { return }
        runner = Task { await self.runPasses() }
        showSyncing()
    }

    /// One pass after another while requests wait. A pass serves the requests made before it
    /// starts. The loop's last check and its end happen in one step, so a request made at any
    /// moment either is served by a pass still to run or starts the loop again.
    private func runPasses() async {
        while isOpen, !resetting, completed < requested {
            let covering = requested
            if clearingError > completed { update { $0.error = nil } }
            let taken = hints
            hints = ServerInvalidation()
            let committed = CommittedChanges()
            let native = native
            passStopped = false
            // The pass reads the server from here on, so once it has read its whole stream the
            // index holds everything the server had now.
            let began = ContinuousClock.now
            let pass = Task { try await SyncPassProbe.measure { try await native.pass(committed: { committed.add($0) }) } }
            self.pass = pass
            let outcome = await pass.result
            self.pass = nil
            let stopped = passStopped
            passStopped = false
            switch outcome {
            case .success(let index):
                let change = await passSucceeded(index, hints: taken, began: began)
                completed = max(completed, covering)
                if let change { resolve(through: covering, with: .success(change)) }
            case .failure(let error):
                // What the index committed before the pass ended is published all the same.
                if let settled = await settle(committed.change, hints: ServerInvalidation()) {
                    await publish(settled.change, accessChanged: settled.accessChanged)
                }
                var restored = taken
                restored.merge(hints)
                hints = restored
                guard !stopped else { break }
                // A cancellation the engine didn't ask for, such as a write the index refused
                // because it was emptied meanwhile, is a pass that failed quietly.
                if !Self.isCancellation(error) { await reportFailure(error, live: false) }
                completed = max(completed, covering)
                resolve(through: covering, with: .failure(error))
            }
            ensureLive()
        }
        runner = nil
        showSyncing()
    }

    private func passSucceeded(_ index: IndexChange, hints taken: ServerInvalidation, began: ContinuousClock.Instant) async -> LibraryChange? {
        guard var settled = await settle(index, hints: taken) else { return nil }
        settled.change.syncedThrough = began
        let date = try? await entities.lastSyncDate()
        guard isOpen else { return nil }
        update { status in
            status.error = nil
            if let date { status.lastSyncDate = date }
        }
        await client.persistCachedServerFeatures()
        // Coverage learns of a completed first sync from the change published below.
        await publish(settled.change, accessChanged: settled.accessChanged)
        // The widgets pick their photos again after every pass that succeeds, as they always have.
        if isOpen { await device.reloadWidgets() }
        startRepairs()
        return settled.change
    }

    /// Fetches the dependents the index queued for repair, two at a time, while the app is in
    /// front, and publishes what they changed like a pass.
    private func startRepairs() {
        guard isOpen, foreground, repairs == nil else { return }
        repairs = Task { [repairer] in
            let change = await repairer.run()
            await self.repairsEnded(change)
        }
    }

    private func repairsEnded(_ index: IndexChange) async {
        repairs = nil
        guard isOpen, !index.isEmpty, let settled = await settle(index, hints: ServerInvalidation()) else { return }
        await publish(settled.change, accessChanged: settled.accessChanged)
    }

    /// Makes a pass's effects safe and names them for this account: the media of removed photos
    /// is forgotten, and the access epoch moves when access was lost. When the server reset the
    /// library, memory and the URL cache are cleared, and once the index is complete again the
    /// grid thumbnails it no longer vouches for are swept; the rest stay, so the offline library
    /// needs no downloads. Nil once the account has closed.
    private func settle(_ index: IndexChange, hints: ServerInvalidation) async -> (change: LibraryChange, accessChanged: Bool)? {
        guard isOpen else { return nil }
        // A server reset committed in an earlier pass that failed, or before a crash, is still due;
        // so is the flag an older build left, which wiped every image instead.
        let resetPending = (try? await entities.accessInvalidationPending()) == true
        guard isOpen else { return nil }
        // Due once per reset: memory goes, the access epoch moves and the feeds reload.
        let resetDue = index.serverReset || (resetPending && !resetSeen)
        if resetPending || index.serverReset { await reconcileAfterReset(memory: resetDue) }
        // Clearing every cache for one deletion would throw away the whole offline library.
        let purged = await purgeRemovedMedia()
        guard isOpen else { return nil }
        let accessChanged = resetDue || !index.accessLost.isEmpty || !purged.revoked.isEmpty
        if accessChanged {
            // Places are kept through ordinary syncs, but not past a change in what may be seen:
            // the epoch moves first, so a count begun before it is never written after this.
            moveAccessEpoch()
            try? await entities.clearMonthPlaces()
            guard isOpen else { return nil }
        }
        var change = LibraryChange(account: authorization.account, authorization: authorization.snapshot.epoch,
                                   indexRevision: index.revision, origin: .sync)
        change.upserted = index.upserted
        change.removed = index.removed
        // Removals an earlier pass committed but never got to forget count too.
        for id in purged.removed where index.upserted[id] == nil { change.removed.insert(id) }
        change.accessLost = index.accessLost.union(purged.revoked)
        change.mediaRevisions = index.mediaRevisions
        change.albums = index.albums
        change.people = index.people
        change.stacks = index.stacks
        change.partnersChanged = index.partnersChanged
        change.memoriesChanged = index.memoriesChanged
        change.reset = index.serverReset || index.localReset || resetDue
        change.routingChanged = index.routingChanged
        change.configurationChanged = hints.configurationChanged
        change.overflow = index.overflow
        // A hinted revision counts for an asset the stream left alone that the index holds at
        // another revision: its previews were made again without its record changing.
        let hinted = hints.mediaRevisions.filter { change.upserted[$0.key] == nil && !change.removed.contains($0.key) }
        if !hinted.isEmpty, let held = try? await entities.mediaRevisions(of: Array(hinted.keys)) {
            for (id, revision) in hinted where held[id].map({ $0 != revision }) == true { change.mediaRevisions[id] = revision }
        }
        change.limitItems()
        return (change, accessChanged)
    }

    /// After a server reset: what memory and the URL cache hold goes, once per reset, since any of
    /// it may belong to a photo the account can no longer see. The grid thumbnails on disk wait
    /// until the index is complete again; then those of photos it doesn't hold, or holds at
    /// another revision, are removed, and only then is the reset marked done, so a crash before
    /// it sweeps on the next pass.
    private func reconcileAfterReset(memory: Bool) async {
        if memory { await pipeline.removeAllButStoredThumbnails() }
        resetSeen = true
        guard isOpen, (try? await entities.isComplete()) == true,
              let valid = try? await entities.thumbnailRevisions(), isOpen else { return }
        _ = await pipeline.sweepStoredThumbnails(keeping: valid)
        guard isOpen, (try? await entities.takeAccessInvalidation()) != nil else { return }
        resetSeen = false
    }

    /// Tells media, the screens and every observer, unless nothing changed.
    private func publish(_ change: LibraryChange, accessChanged: Bool) async {
        guard isOpen, !change.isEmpty else { return }
        await hub.publish(change, accessChanged: accessChanged)
        if change.configurationChanged { check.validate() }
    }

    /// Forgets the media of photos the index removed, a batch at a time, and only then takes them
    /// off the index's queue. Returns them, with those whose access was lost.
    private func purgeRemovedMedia() async -> (removed: Set<String>, revoked: Set<String>) {
        var removed = Set<String>(), revoked = Set<String>()
        // Bounded, so a queue that can't be cleared waits for the next sync instead of spinning.
        for _ in 0..<64 {
            guard isOpen, let purges = try? await entities.pendingMediaPurges(), !purges.isEmpty else { break }
            let lost = purges.contains(where: \.revoked)
            await pipeline.forget(assetIDs: Set(purges.map(\.assetID)), revoked: lost)
            for purge in purges {
                removed.insert(purge.assetID)
                if purge.revoked { revoked.insert(purge.assetID) }
            }
            guard (try? await entities.finishMediaPurges(purges)) != nil else { break }
        }
        return (removed, revoked)
    }

    /// `live` says the failure is the live connection's, which tries again by itself, rather than
    /// a sync pass's.
    private func reportFailure(_ error: any Error, live: Bool) async {
        if case ServerFailure.sessionExpired = error {
            // Signing out happens only when a second check agrees, as a transition of its own.
            let ending = await check.sessionEnds(after: error)
            // The session check found the session still valid.
            guard !ending, isOpen else { return }
            update { $0.error = live ? "The server rejected the live connection. The library will reconnect."
                                     : "The server refused to sync. Sync again in a moment." }
        } else {
            guard isOpen else { return }
            update { $0.error = error.localizedDescription }
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: Waiting for a pass

    private func waitForPass(lease: AuthorizationEpoch?) async throws -> LibraryChange {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LibraryChange, any Error>) in
                guard isOpen, !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                let sequence = requestPass(clearingError: false)
                waiters[id] = Waiter(sequence: sequence, lease: lease, change: nil, continuation: continuation)
            }
        } onCancel: {
            Task { await self.waiterCancelled(id) }
        }
    }

    private func waiterCancelled(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        dropPassesNobodyNeeds()
    }

    /// Answers everyone the pass that served `sequence` was for. Those still waiting remember its
    /// change, so what they get covers everything since they asked.
    private func resolve(through sequence: UInt64, with outcome: Result<LibraryChange, any Error>) {
        for (id, var waiter) in waiters {
            if case .success(let change) = outcome {
                if waiter.change == nil { waiter.change = change } else { waiter.change?.merge(change) }
            }
            guard waiter.sequence <= sequence else {
                waiters[id] = waiter
                continue
            }
            waiters[id] = nil
            switch outcome {
            case .success(let change):
                // A lease outlives only the epoch moves its own passes made.
                if let lease = waiter.lease, !authorization.isCurrent(lease) {
                    waiter.continuation.resume(throwing: CancellationError())
                } else {
                    waiter.continuation.resume(returning: waiter.change ?? change)
                }
            case .failure(let error):
                waiter.continuation.resume(throwing: error)
            }
        }
    }

    /// With the app in the background and nobody waiting, no pass is wanted: the one in flight
    /// stops, and requests no pass has served are dropped.
    private func dropPassesNobodyNeeds() {
        guard !foreground, waiters.isEmpty else { return }
        completed = requested
        stopPass()
    }

    private func stopPass() {
        guard let pass else { return }
        passStopped = true
        pass.cancel()
    }

    /// The access epoch moves, as after lost access or a reset. A background window's lease moves
    /// with it: these are the engine's own moves, and only the session ending voids a lease.
    private func moveAccessEpoch() {
        let epoch = authorization.accessChanged().epoch
        for (id, waiter) in waiters where waiter.lease != nil { waiters[id]?.lease = epoch }
    }

    // MARK: Live connection

    /// Opens the live connection after a pass, while the app is in front.
    private func ensureLive() {
        guard isOpen, foreground, !resetting, live == nil else { return }
        liveGeneration &+= 1
        let generation = liveGeneration
        live = Task { await self.runLive(generation) }
    }

    /// Closes the live connection. One that was stopped never starts or connects again.
    private func stopLive() {
        liveGeneration &+= 1
        live?.cancel()
        live = nil
    }

    /// Reads hints until the connection ends, then connects again, waiting longer each time. Each
    /// hint asks for a pass, after a moment in which a burst arrives merged.
    private func runLive(_ generation: UInt64) async {
        var retry: Duration = .seconds(1)
        while !Task.isCancelled, isOpen, liveGeneration == generation {
            do {
                let connection = try await connect()
                defer { connection.close() }
                guard !Task.isCancelled, liveGeneration == generation else { return }
                for try await hint in connection.events {
                    try await Task.sleep(for: debounce)
                    guard liveGeneration == generation else { return }
                    hints.merge(hint)
                    requestPass(clearingError: false)
                    retry = .seconds(1)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, liveGeneration == generation else { return }
                // An expired session the session check confirms ends this loop through sign-out,
                // which stops sync. Any other refusal is tried again: Immich's socket says
                // unauthorized whenever its connection handler fails, for any reason.
                await reportFailure(error, live: true)
            }
            do { try await Task.sleep(for: retry) } catch { return }
            retry = min(retry * 2, .seconds(30))
        }
    }

    // MARK: Status

    /// The status changes here and nowhere else; the screens see each change in order.
    private func update(_ change: (inout SyncStatus) -> Void) {
        var next = status
        change(&next)
        guard next != status else { return }
        status = next
        statusSequence &+= 1
        let board = board, shown = next, sequence = statusSequence
        Task { @MainActor in board.show(shown, sequence: sequence) }
    }

    private func showSyncing() {
        let syncing = runner != nil || resetting
        update { $0.isSyncing = syncing }
    }
}

/// What a pass's batches committed, kept as they commit, so a pass that fails still says it.
private final class CommittedChanges: Sendable {
    private let state = Mutex(IndexChange())

    func add(_ change: IndexChange) { state.withLock { $0.merge(change) } }
    var change: IndexChange { state.withLock { $0 } }
}

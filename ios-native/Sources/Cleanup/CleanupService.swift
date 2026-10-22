import Foundation
import IlyichPlatform
import os

/// A phone photo a check found safe to remove: backed up, verified on the server, unchanged.
struct CleanupCandidate: Hashable, Sendable {
    let receipt: CleanupReceipt
    let asset: DeviceAsset
    let size: VerifiedSize

    var localID: String { receipt.localID }

    /// The original's size plus its Live Photo video's, as the server reported them; nil when
    /// either is unknown.
    var originalBytes: Int64? {
        guard let original = size.original else { return nil }
        guard receipt.motion != nil else { return original }
        guard let motion = size.motion else { return nil }
        let (sum, overflow) = original.addingReportingOverflow(motion)
        return overflow ? nil : sum
    }
}

/// What one check found.
struct CleanupScanResult: Sendable {
    let id: UUID
    /// Newest first.
    let candidates: [CleanupCandidate]
    /// Every other backed-up phone photo, with why it stays.
    let exclusions: [String: CleanupExclusion]
    /// The most server checks that were in flight at once.
    var peakRequests = 0
}

/// Why a check no longer holds as a whole (DS11).
enum CleanupInvalidation: Hashable, Sendable {
    case settings
    case access
    case account
    case library
}

/// What the screen hears from the service between a check and a removal.
enum CleanupEvent: Hashable, Sendable {
    /// These candidates changed and are no longer offered.
    case dropped(Set<String>)
    /// The check no longer holds; nothing is offered until the next one.
    case invalidated(CleanupInvalidation)
}

/// Why a removal didn't start.
enum CleanupBlock: Hashable, Sendable {
    /// Removal is shut until the owner's device test (CleanupRemovalGate).
    case unavailable
    case readOnly
    /// The account, its session or its access changed since the check.
    case sessionChanged
    /// No current check offers the selection.
    case checkAgain
}

/// How a removal ended (DS1 to DS10).
enum CleanupRemovalResult: Hashable, Sendable {
    /// Photos removed exactly these.
    case removed([String])
    /// The person declined iOS's prompt. Nothing was removed; not an error.
    case declined
    /// Something about these changed since the check, so nothing was removed; they are no
    /// longer offered.
    case changed(Set<String>)
    case blocked(CleanupBlock)
    case failed(String)
}

/// Problems that stop a check before it finds anything.
enum CleanupCheckError: LocalizedError, Equatable {
    case photosAccess
    case signedOut
    case receiptsUnavailable
    case outdated

    var errorDescription: String? {
        switch self {
        case .photosAccess: "Allow Photos access before checking local items."
        case .signedOut: "You’re signed out. Sign in again to continue."
        case .receiptsUnavailable: "Backup records for this account aren’t ready yet. Open Backup, then check again."
        case .outdated: "Your account, Photos access or library changed during the check. Check again."
        }
    }
}

/// One account's cleanup (REBUILD_ROADMAP.md P4, invariants DS1 to DS12). A check reads the
/// account's receipts, filters them on the phone a batch at a time (revision, shape,
/// deletability, the settings and kept albums), then verifies the rest with the server, at most
/// six at once, each strictly (RemoteCopyVerifier). A removal names only the selection, checks it
/// all again, re-verifies it, checks the account twice, and asks Photos through the adapter with
/// the revisions expected, which Photos' change block checks once more.
///
/// The check stays live between check and removal: a change to Photos, a receipt or the server
/// drops only the candidates it names; settings, Photos access, the account, its session or its
/// access epoch invalidate it whole. The account's AccountRuntime owns it and shuts it down.
actor CleanupService {
    /// The account's digest.
    nonisolated let account: String
    private let authorization: AuthorizationState
    private let receipts: any ReceiptRepository
    private let makeDevice: @Sendable () -> any CleanupDevice
    private let verifier: RemoteCopyVerifier
    private let settings: CleanupSettingsStore
    private let credentialIsCurrent: @Sendable () -> Bool
    private let serverChanges: (@Sendable () async -> AsyncStream<LibraryChange>)?
    /// CleanupRemovalGate on the phone; tests open it.
    nonisolated let removalAllowed: Bool
    private let verificationLimit: Int
    private let batchSize: Int

    private lazy var device: any CleanupDevice = makeDevice()

    /// The fence a removal must still be inside (DS6).
    private struct Fence: Equatable {
        let account: String
        let tokenDigest: String
        let epoch: AuthorizationEpoch
    }

    private struct Scan {
        let id: UUID
        let fence: Fence
        let access: UInt64
        let settings: CleanupSettings
        let cutoff: Date
        var candidates: [String: CleanupCandidate]
    }

    private var current: Scan?
    private var scanning: (token: UUID, task: Task<CleanupScanResult, any Error>)?
    /// What changed while a check ran: the candidates it names, or the whole check.
    private var dirty: Set<String> = []
    private var dirtyWhole = false
    private var removing = false
    private var watchers: [Task<Void, Never>] = []
    private var observers: [UUID: AsyncStream<CleanupEvent>.Continuation] = [:]
    private var closed = false

    init(account: String, ownerID: String, authorization: AuthorizationState, receipts: any ReceiptRepository,
         device: @escaping @Sendable () -> any CleanupDevice,
         remote: @escaping @Sendable (String) async throws -> BackupRemoteAsset,
         settings: CleanupSettingsStore = CleanupSettingsStore(),
         credentialIsCurrent: @escaping @Sendable () -> Bool,
         serverChanges: (@Sendable () async -> AsyncStream<LibraryChange>)? = nil,
         removalAllowed: Bool = CleanupRemovalGate.isOpen, verificationLimit: Int = 6, batchSize: Int = 250) {
        self.account = account
        self.authorization = authorization
        self.receipts = receipts
        self.makeDevice = device
        self.verifier = RemoteCopyVerifier(ownerID: ownerID, fetch: remote)
        self.settings = settings
        self.credentialIsCurrent = credentialIsCurrent
        self.serverChanges = serverChanges
        self.removalAllowed = removalAllowed
        self.verificationLimit = max(1, verificationLimit)
        self.batchSize = max(1, batchSize)
    }

    // MARK: - Events

    /// Every event from now on, until the service shuts down.
    func events() -> AsyncStream<CleanupEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CleanupEvent.self)
        guard !closed else { continuation.finish(); return stream }
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { observers[id] = nil }

    private func emit(_ event: CleanupEvent) {
        for observer in observers.values { observer.yield(event) }
    }

    /// The candidates the current check still offers.
    var liveCandidates: Set<String> { current.map { Set($0.candidates.keys) } ?? [] }

    /// The current check's id, or nil once none holds.
    var currentScanID: UUID? { current?.id }

    // MARK: - Checking

    /// Checks which backed-up phone photos may be removed, with `cutoff` from the settings when
    /// not given. A check started meanwhile replaces this one, which then throws CancellationError.
    func scan(cutoff: Date? = nil) async throws -> CleanupScanResult {
        guard !closed else { throw CancellationError() }
        scanning?.task.cancel()
        invalidate(nil)
        let token = UUID()
        let task = Task { try await self.runScan(token: token, cutoff: cutoff) }
        scanning = (token, task)
        defer { if scanning?.token == token { scanning = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Drops the current check, as when a setting changes.
    func invalidate() { invalidate(.settings) }

    private func invalidate(_ reason: CleanupInvalidation?) {
        // A check under way read the settings when it began, and a removal compares them again.
        if scanning != nil, let reason, reason != .settings { dirtyWhole = true }
        guard current != nil else { return }
        current = nil
        if let reason { emit(.invalidated(reason)) }
    }

    private static let log = Logger(subsystem: PerfSignpost.subsystem, category: PerfSignpost.Category.cleanup)

    private func runScan(token: UUID, cutoff: Date?) async throws -> CleanupScanResult {
        // The P4 perf gate: time to candidates and the most server checks in flight at once.
        let signposter = PerfSignpost.cleanup
        let interval = signposter.isEnabled ? signposter.beginInterval(PerfSignpost.cleanupScan, id: signposter.makeSignpostID()) : nil
        let clock = ContinuousClock(), start = clock.now
        var outcome = "failed", receiptCount = 0, verified = 0, peak = 0, found = 0
        defer {
            let elapsed = clock.now - start
            if let interval {
                signposter.endInterval(PerfSignpost.cleanupScan, interval,
                                       "outcome=\(outcome, privacy: .public) receipts=\(receiptCount) verified=\(verified) peakGets=\(peak) candidates=\(found)")
            }
            Self.log.notice("cleanup.scan \(outcome, privacy: .public) in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public): receipts=\(receiptCount) verified=\(verified) peakGets=\(peak) candidates=\(found)")
        }
        do {
            let result = try await scanOnce(token: token, cutoff: cutoff, receiptCount: &receiptCount, verified: &verified, peak: &peak)
            outcome = "completed"; found = result.candidates.count
            return result
        } catch is CancellationError {
            outcome = "cancelled"; throw CancellationError()
        }
    }

    private func scanOnce(token: UUID, cutoff: Date?, receiptCount: inout Int, verified: inout Int, peak: inout Int) async throws -> CleanupScanResult {
        startWatching()
        dirty = []; dirtyWhole = false; pendingServer = []
        guard let fence = fence() else { throw CleanupCheckError.signedOut }
        let access = await device.access()
        guard PhotoKitAdapter.canRead(access.status) else { throw CleanupCheckError.photosAccess }
        let settings = settings.load()
        let cutoff = cutoff ?? settings.cutoff()
        guard let known = await receipts.receipts(account: account) else { throw CleanupCheckError.receiptsUnavailable }
        try Task.checkCancellation()
        receiptCount = known.count
        let kept = try await device.members(of: settings.keptAlbumIDs ?? [])

        // On the phone first, in batches, so no photo the phone rules out costs a request.
        var exclusions: [String: CleanupExclusion] = [:]
        var survivors: [(CleanupReceipt, DeviceAsset)] = []
        let ids = known.keys.filter { known[$0]?.locallyDeleted == false }.sorted()
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = ids[start..<min(start + batchSize, ids.count)].map(DeviceAssetID.init(rawValue:))
            for asset in try await device.assets(batch) {
                guard let receipt = known[asset.id.rawValue] else { continue }
                if let exclusion = Self.localExclusion(asset, receipt: receipt, settings: settings, cutoff: cutoff, kept: kept) {
                    exclusions[receipt.localID] = exclusion
                } else {
                    survivors.append((receipt, asset))
                }
            }
        }

        // Then the server, strictly, at most `verificationLimit` at once. A 401 throws and ends it.
        verified = survivors.count
        let (verdicts, inFlight) = try await Self.verify(survivors.map(\.0), with: verifier, limit: verificationLimit)
        peak = inFlight
        try Task.checkCancellation()
        var candidates: [String: CleanupCandidate] = [:]
        for (receipt, asset) in survivors {
            switch verdicts[receipt.localID] {
            case .verified(let size): candidates[receipt.localID] = CleanupCandidate(receipt: receipt, asset: asset, size: size)
            case .excluded(let exclusion): exclusions[receipt.localID] = exclusion
            case nil: break
            }
        }

        // What changed while it ran: a receipt changed, or Photos or the server named a candidate.
        let now = await receipts.receipts(account: account) ?? [:]
        for (id, candidate) in candidates
        where now[id] != candidate.receipt || dirty.contains(id) || candidate.receipt.remoteIDs.contains(where: pendingServer.contains) {
            candidates[id] = nil
        }
        guard !Task.isCancelled, scanning?.token == token else { throw CancellationError() }
        guard !dirtyWhole, self.fence() == fence, await device.access().generation == access.generation else {
            throw CleanupCheckError.outdated
        }
        // Sizes only for receipts that are still the ones verified (the repository checks again).
        await receipts.recordSizes(candidates.mapValues(\.size), account: account)
        guard !Task.isCancelled, scanning?.token == token, !dirtyWhole else { throw CancellationError() }
        current = Scan(id: UUID(), fence: fence, access: access.generation, settings: settings, cutoff: cutoff, candidates: candidates)
        let ordered = candidates.values.sorted {
            let left = $0.asset.created ?? .distantPast, right = $1.asset.created ?? .distantPast
            return left == right ? $0.localID < $1.localID : left > right
        }
        return CleanupScanResult(id: current!.id, candidates: ordered, exclusions: exclusions, peakRequests: peak)
    }

    /// Why the phone keeps this photo, or nil when the server should be asked (DS2, DS3, DS7).
    static func localExclusion(_ asset: DeviceAsset, receipt: CleanupReceipt, settings: CleanupSettings, cutoff: Date,
                               kept: Set<String>) -> CleanupExclusion? {
        guard asset.revision == receipt.revision else { return .changedSinceBackup }
        switch asset.shape {
        case .singleOriginal: if receipt.motion != nil { return .unsupportedShape }
        case .livePhoto: if receipt.motion == nil { return .livePhotoWithoutVideoBackup }
        case .edited: return .edited
        case .multipleOriginals: return .multipleOriginals
        case .other: return .unsupportedShape
        }
        guard asset.canDelete else { return .notDeletable }
        guard settings.keptAlbumIDs != nil else { return .settingsUnreadable }
        return settings.policy(cutoff: cutoff).exclusion(date: asset.created, favorite: asset.isFavorite, video: asset.isVideo,
                                                         inKeptAlbum: kept.contains(asset.id.rawValue))
    }

    /// Each receipt's verdict, with at most `limit` checks in flight, and the most that were.
    private nonisolated static func verify(_ receipts: [CleanupReceipt], with verifier: RemoteCopyVerifier,
                                           limit: Int) async throws -> ([String: RemoteCopyVerifier.Verdict], peak: Int) {
        try await withThrowingTaskGroup(of: (String, RemoteCopyVerifier.Verdict).self) { group in
            var results: [String: RemoteCopyVerifier.Verdict] = [:]
            var next = 0, inFlight = 0, peak = 0
            while next < min(limit, receipts.count) {
                let receipt = receipts[next]
                group.addTask { (receipt.localID, try await verifier.verify(receipt)) }
                next += 1; inFlight += 1; peak = max(peak, inFlight)
            }
            while let (id, verdict) = try await group.next() {
                results[id] = verdict
                inFlight -= 1
                if next < receipts.count, !Task.isCancelled {
                    let receipt = receipts[next]
                    group.addTask { (receipt.localID, try await verifier.verify(receipt)) }
                    next += 1; inFlight += 1; peak = max(peak, inFlight)
                }
            }
            try Task.checkCancellation()
            return (results, peak)
        }
    }

    // MARK: - Removing

    /// Removes the selection from the phone, if everything about it still holds (DS1 to DS10).
    func remove(_ selection: Set<String>) async -> CleanupRemovalResult {
        // The one gate: shut, nothing below runs and Photos is never asked.
        guard removalAllowed else { return .blocked(.unavailable) }
        guard !closed, !removing else { return .blocked(.checkAgain) }
        removing = true
        defer { removing = false }
        // DS1: only what the current check offers.
        guard let scan = current, !selection.isEmpty, selection.isSubset(of: scan.candidates.keys) else { return .blocked(.checkAgain) }
        if let block = blockedByAccount(scan) { return .blocked(block) }
        // DS7 and DS11: the settings and Photos access the check was made with.
        guard settings.load() == scan.settings else { invalidate(.settings); return .blocked(.checkAgain) }
        guard await device.access().generation == scan.access else { invalidate(.access); return .blocked(.checkAgain) }

        let reviewed = selection.sorted().compactMap { scan.candidates[$0] }
        // DS2: the receipts are still the ones checked.
        let receiptsNow = await receipts.receipts(account: account) ?? [:]
        var changed = Set(reviewed.filter { receiptsNow[$0.localID] != $0.receipt }.map(\.localID))
        // DS2, DS3 and DS7 again, with the phone and kept albums as they are now.
        let kept: Set<String>
        let assets: [DeviceAsset]
        do {
            kept = try await device.members(of: scan.settings.keptAlbumIDs ?? [])
            assets = try await device.assets(reviewed.map(\.asset.id))
        } catch { return .blocked(.checkAgain) }
        let found = Dictionary(assets.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        for candidate in reviewed {
            guard let asset = found[candidate.localID],
                  Self.localExclusion(asset, receipt: candidate.receipt, settings: scan.settings, cutoff: scan.cutoff, kept: kept) == nil
            else { changed.insert(candidate.localID); continue }
        }
        guard changed.isEmpty else { return drop(changed) }

        // DS5: only the selection is verified again, right before Photos is asked.
        let verdicts: [String: RemoteCopyVerifier.Verdict]
        do { verdicts = try await Self.verify(reviewed.map(\.receipt), with: verifier, limit: verificationLimit).0 }
        catch is CleanupAborted { invalidate(.account); return .failed(CleanupAborted().errorDescription ?? "") }
        catch { return .blocked(.checkAgain) }
        let failed = Set(reviewed.map(\.localID).filter {
            if case .verified = verdicts[$0] { return false }
            return true
        })
        guard failed.isEmpty else { return drop(failed) }

        // DS6, after re-verification.
        guard let latest = current, latest.id == scan.id else { return .blocked(.checkAgain) }
        if let block = blockedByAccount(scan) { return .blocked(block) }
        let lost = selection.subtracting(latest.candidates.keys)
        guard lost.isEmpty else { return .changed(lost) }
        let ids = reviewed.map(\.asset.id)
        let expected = Dictionary(uniqueKeysWithValues: reviewed.map { ($0.asset.id, $0.receipt.revision) })
        let removal = DeviceMutation.delete(ids, expected: expected, origin: .cleanup(scan: scan.id, account: account))
        // DS6 again, immediately before Photos is asked: nothing awaits between this and perform.
        guard !Task.isCancelled, current?.id == scan.id, blockedByAccount(scan) == nil else { return .blocked(.checkAgain) }
        let outcome = await device.perform(removal).outcome

        switch outcome {
        case .committed:
            // DS9: receipts are marked only once Photos committed.
            await receipts.markLocallyDeleted(selection.sorted(), account: account)
            if current?.id == scan.id { for id in selection { current?.candidates[id] = nil } }
            emit(.dropped(selection))
            return .removed(selection.sorted())
        case .declined:
            // DS10: the person's answer; nothing is touched.
            return .declined
        case .revisionChanged, .notPermitted:
            return drop(selection)
        case .failed(let message):
            return .failed(message)
        case .interrupted:
            return .failed("Photos didn’t say whether the items were removed. Check again.")
        }
    }

    /// Drops candidates that changed, and says so.
    private func drop(_ ids: Set<String>) -> CleanupRemovalResult {
        removeCandidates(ids)
        return .changed(ids)
    }

    private func removeCandidates(_ ids: Set<String>) {
        if scanning != nil { dirty.formUnion(ids) }
        guard current != nil else { return }
        let gone = ids.filter { current?.candidates[$0] != nil }
        guard !gone.isEmpty else { return }
        for id in gone { current?.candidates[id] = nil }
        emit(.dropped(Set(gone)))
    }

    /// The account fence now, or nil once the session ended.
    private func fence() -> Fence? {
        guard !authorization.hasEnded else { return nil }
        let snapshot = authorization.snapshot
        return Fence(account: authorization.account.digest, tokenDigest: snapshot.tokenDigest, epoch: snapshot.epoch)
    }

    /// Why the account no longer allows this check's removal (DS6), or nil when it does.
    private func blockedByAccount(_ scan: Scan) -> CleanupBlock? {
        guard let fence = fence(), fence == scan.fence, fence.account == account, credentialIsCurrent() else {
            invalidate(.account)
            return .sessionChanged
        }
        let snapshot = authorization.snapshot
        if snapshot.readOnly || snapshot.requiresPasswordChange { return .readOnly }
        return nil
    }

    // MARK: - Following changes (DS11)

    private func startWatching() {
        guard watchers.isEmpty, !closed else { return }
        let device = device, receipts = receipts, authorization = authorization, serverChanges = serverChanges
        watchers.append(Task { [weak self] in
            for await change in device.changes() {
                await self?.deviceChanged(change)
            }
        })
        watchers.append(Task { [weak self] in
            for await _ in await receipts.changes() {
                await self?.receiptsChanged()
            }
        })
        watchers.append(Task { [weak self] in
            for await snapshot in authorization.updates() {
                await self?.authorizationChanged(snapshot)
            }
            await self?.authorizationChanged(nil)
        })
        if let serverChanges {
            watchers.append(Task { [weak self] in
                for await change in await serverChanges() {
                    await self?.serverChanged(change)
                }
            })
        }
    }

    func deviceChanged(_ change: DeviceLibraryChange) {
        let access = current?.access
        if change.requiresFullReload || (access != nil && change.access.generation != access) {
            invalidate(change.requiresFullReload ? .library : .access)
            return
        }
        let named = Set(change.inserted.union(change.removed).union(change.changed).map(\.rawValue))
        removeCandidates(named)
    }

    func receiptsChanged() async {
        guard current != nil else { return }
        let now = await receipts.receipts(account: account) ?? [:]
        guard let candidates = current?.candidates else { return }
        removeCandidates(Set(candidates.filter { now[$0.key] != $0.value.receipt }.keys))
    }

    private func authorizationChanged(_ snapshot: AuthorizationSnapshot?) {
        guard let scan = current else {
            if scanning != nil, snapshot == nil || fence() == nil { dirtyWhole = true }
            return
        }
        if fence() != scan.fence { invalidate(.account) }
    }

    func serverChanged(_ change: LibraryChange) {
        // A change that no longer names its assets one by one could have touched any of them.
        if change.reset || change.overflow { invalidate(.library); return }
        let named = Set(change.upserted.keys).union(change.removed).union(change.accessLost)
        guard !named.isEmpty else { return }
        var ids = Set<String>()
        for (id, candidate) in current?.candidates ?? [:] where candidate.receipt.remoteIDs.contains(where: named.contains) { ids.insert(id) }
        removeCandidates(ids)
        // A check still running hears it through its own candidates' receipts at the end.
        if scanning != nil { pendingServer.formUnion(named) }
    }

    /// Server assets a change named while a check ran.
    private var pendingServer: Set<String> = []

    // MARK: - Shutdown

    /// Ends the check under way and the following of changes, and waits for them.
    func shutdown() async {
        closed = true
        current = nil
        let running = scanning?.task
        scanning = nil
        running?.cancel()
        let tasks = watchers
        watchers = []
        for task in tasks { task.cancel() }
        for observer in observers.values { observer.finish() }
        observers = [:]
        _ = try? await running?.value
        for task in tasks { await task.value }
    }
}

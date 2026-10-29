import Foundation
import IlyichPlatform
import IlyichShareInbox
import os
import Photos
import Synchronization

/// One signed-in account's transfer engine and the work beside it (B9): the engine over the
/// account's transfers database, its executors for both lanes, recovery, the post-upload worker,
/// the notifier and the lifecycle that spends background time on it. AccountRuntime owns it and
/// stops it at teardown; TransferHost makes it once the account's database is the engine's, and
/// feeds it the background sessions' events and the lifecycle's.
///
/// Start (architecture section 4, step 5): recovery reconciles what the sessions and the disk hold
/// (binding the tasks iOS still has and applying outcomes nobody applied, BM5), the share executor
/// settles what a crash left, and only then does the engine's loop start. A session's drain is
/// acknowledged to iOS once a reconcile that began after it has committed what it delivered (BM11).
final class TransferRuntime: Sendable {
    let account: AccountID
    let store: TransferStore
    let engine: TransferEngine<ContinuousClock>
    let recovery: Recovery
    let worker: PostUploadWorker
    let shares: ShareJobExecutor
    let discovery: LibraryDiscovery
    /// The commands and reads the backup screens send to this account's engine.
    let backend: EngineBackend
    let notifier: TransferNotifier
    private let lifecycle: TransferLifecycle<ContinuousClock>
    private let registry: TransportRegistry
    private let outcomes: TransportOutcomes
    private let transportEvents: AsyncStream<TransportEvent>.Continuation
    private let lifecycleEvents: AsyncStream<LifecycleEvent>.Continuation
    private let lifecycleStream: AsyncStream<LifecycleEvent>
    private let reconciler: Reconciler
    private let receiptChanges: ChangeBroadcast
    private let tasks = Mutex<[Task<Void, Never>]>([])
    private let stopped = Mutex(false)
    fileprivate static let logger = Logger(subsystem: "app.ilyich.native", category: "Transfers")

    /// What the runtime is made from. The registry, scheduler and time are the device's; the rest
    /// is the account's.
    struct Parts {
        var account: AccountID
        var store: TransferStore
        var authorization: any TransferAuthorizing
        var server: any TransferServerAPI
        var registry: TransportRegistry
        var layout: AppGroupLayout
        var inbox: ShareInboxRepository
        var staging: any PhotoLibraryStaging
        var scheduler: (any WindowScheduling)?
        var time: any BackgroundTimeGranting
        var appActive: Bool
        /// One sync pass before a background window looks for new photos; nil without a library.
        var preSync: (@Sendable () async -> Void)?
        /// Tells iOS a session's events up to `drain` are committed.
        var acknowledge: @Sendable (TransferSessionID, Int) async -> Void
        /// Whether the device's conditions let uploads run, given Require charging.
        var conditionsPermit: @Sendable (Bool) async -> Bool = PostUploadWorker.deviceConditionsPermit
        /// The system's notifications when nil.
        var poster: (any TransferNotificationPosting)?
        var clock = ContinuousClock()
    }

    @MainActor init(_ parts: Parts) {
        account = parts.account
        store = parts.store
        registry = parts.registry
        let (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        transportEvents = continuation
        let outcomes = TransportOutcomes(events: events)
        self.outcomes = outcomes
        let backup = parts.registry.transport(.backup)
        let share = parts.registry.transport(.shareUpload)
        let library = LibraryJobExecutor(store: parts.store, staging: parts.staging, server: parts.server,
                                         uploader: TransportPartUploader(transport: backup, outcomes: outcomes), layout: parts.layout,
                                         account: parts.account, conditionsPermit: parts.conditionsPermit)
        let shares = ShareJobExecutor(store: parts.store, inbox: parts.inbox, server: parts.server,
                                      uploader: TransportPartUploader(transport: share, outcomes: outcomes), layout: parts.layout, account: parts.account)
        self.shares = shares
        let worker = PostUploadWorker(store: parts.store, server: parts.server, photos: parts.staging, authorization: parts.authorization,
                                      conditionsPermit: parts.conditionsPermit)
        self.worker = worker
        let engine = TransferEngine(store: parts.store, executor: LaneJobExecutor(library: library, share: shares), authorization: parts.authorization,
                                    clock: parts.clock, concurrency: library.concurrency, scheduler: parts.scheduler,
                                    followUp: { worker.wake($0) })
        self.engine = engine
        let recovery = Recovery(store: parts.store, account: parts.account, layout: parts.layout, backup: backup, share: share)
        self.recovery = recovery
        let discovery = LibraryDiscovery(store: parts.store, staging: parts.staging, notifying: true)
        self.discovery = discovery
        notifier = TransferNotifier(store: parts.store, poster: parts.poster ?? SystemTransferNotificationPoster(), authorization: parts.authorization)
        let receiptChanges = ChangeBroadcast()
        self.receiptChanges = receiptChanges
        let acknowledge = parts.acknowledge
        let reconciler = Reconciler { drains in
            do {
                let report = try await recovery.reconcile()
                await engine.refresh()
                if report.committed > 0 { receiptChanges.send() }
            } catch {
                // Not acknowledged: iOS gets its answer at the deadline instead.
                TransferRuntime.logger.error("Transfer recovery failed: \(String(describing: error), privacy: .public)")
                return
            }
            for (session, drain) in drains { await acknowledge(session, drain) }
        }
        self.reconciler = reconciler
        let preferences: @Sendable () async -> TransferPreferences? = { try? await engine.preferences() }
        let work = EngineWindowWork(engine: engine, discovery: discovery, reconciling: { await reconciler.request(drain: nil).value },
                                    preSync: parts.preSync, preferences: preferences)
        lifecycle = TransferLifecycle(work: work, time: parts.time, clock: parts.clock, appActive: parts.appActive)
        let (lifecycleStream, lifecycleEvents) = AsyncStream.makeStream(of: LifecycleEvent.self)
        self.lifecycleStream = lifecycleStream
        self.lifecycleEvents = lifecycleEvents
        backend = EngineBackend(engine: engine, store: parts.store, discovery: discovery, preferencesChanged: {
            lifecycleEvents.yield(.preferencesChanged)
            // The backup albums are the device index's input too.
            receiptChanges.send()
        }, followUp: { worker.wake($0) })
    }

    // MARK: Lifecycle

    /// Reconciles, settles shares a crash left, then starts the engine, the worker's first pass,
    /// the notifier and the lifecycle. Returns once the engine runs.
    func start() async throws {
        // Leases of the process that ended are free, so recovery sees every job it left.
        try await store.releaseAllLeases()
        await reconciler.request(drain: nil).value
        await shares.replayConsumed()
        try await engine.start()
        let commits = await engine.snapshots()
        let receiptChanges = self.receiptChanges
        let watch = Task {
            // A photo confirmed changes the receipts cleanup and the device index read.
            var confirmed: Int?
            for await snapshot in commits {
                if let confirmed, confirmed != snapshot.confirmed { receiptChanges.send() }
                confirmed = snapshot.confirmed
            }
        }
        let notifier = self.notifier
        let follow = await MainActor.run {
            notifier.start()
            return notifier.follow(Self.unthrottled(engine))
        }
        await lifecycle.start(lifecycleStream)
        // As backup always did on taking an account up in front: automatic backup looks for new
        // photos after its delay. In the background this does nothing.
        lifecycleEvents.yield(.preferencesChanged)
        tasks.withLock { $0 += [watch, follow] }
    }

    /// The engine's snapshots, for the notifier.
    private static func unthrottled(_ engine: TransferEngine<ContinuousClock>) -> AsyncStream<TransferSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: TransferSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            for await snapshot in await engine.snapshots() { continuation.yield(snapshot) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Stops everything the runtime runs, in order: the lifecycle (no new window work), the
    /// engine (leases given back), the worker, the notifier, recovery. The database stays open
    /// for the account's runtime to close.
    func stop() async {
        guard stopped.withLock({ state in defer { state = true }; return !state }) else { return }
        await lifecycle.stop()
        lifecycleEvents.finish()
        await engine.stop()
        await worker.stop()
        let notifier = self.notifier
        await MainActor.run { notifier.stop() }
        await reconciler.stop()
        transportEvents.finish()
        outcomes.shutdown()
        for task in tasks.withLock({ tasks in defer { tasks = [] }; return tasks }) { task.cancel() }
        receiptChanges.finish()
    }

    /// Sign-out: automatic backup goes off and the library lane pauses (as every build did), and
    /// the account's tasks still with iOS are cancelled while their token is about to go. The
    /// staged copies, the database and the outcomes stay; the next sign-in reconciles them.
    func signOut(keepingAutomaticBackup: Bool) async {
        if !keepingAutomaticBackup, var preferences = try? await engine.preferences(), preferences.automatic {
            preferences.automatic = false
            try? await engine.setPreferences(preferences)
        }
        if !keepingAutomaticBackup { try? await engine.setIntent(.paused, requeueingFailures: false) }
        for session in TransferSessionID.allCases {
            _ = await registry.transport(session).cancel(scope: account.digest)
        }
    }

    // MARK: Events

    /// One event from the background sessions: passed to the executors waiting for their parts,
    /// and a finished task or a drain reconciles, which applies what no executor waited for.
    func receive(_ event: TransportEvent) {
        transportEvents.yield(event)
        switch event {
        case .progress: break
        case .finished: reconciler.schedule(drain: nil)
        case .drained(let session, let drain): reconciler.schedule(drain: (session, drain))
        }
    }

    /// One lifecycle event: a background window, the app coming forward or going to the
    /// background, a condition, a Photos change.
    func receive(_ event: LifecycleEvent) {
        if case .window(let lease) = event, stopped.withLock({ $0 }) { return lease.finish(success: true) }
        lifecycleEvents.yield(event)
    }

    /// Reconciles now and waits for it, as a background window does first.
    func reconcile() async { await reconciler.request(drain: nil).value }

    // MARK: Receipts

    /// The receipts cleanup and the device index read, from the transfers database.
    var receipts: TransferReceiptSource { TransferReceiptSource(store: store, broadcast: receiptChanges) }

    /// The receipts changed outside the engine, as when cleanup records a removal.
    func receiptsChanged() { receiptChanges.send() }
}

// MARK: - Recovery runs

/// Runs recovery one pass at a time. Requests that come while a pass waits to start join it; a
/// request that comes while one runs gets a pass of its own after it, so every finished task and
/// drain is reconciled by a pass that began after it.
private actor Reconciler {
    private let pass: @Sendable ([(TransferSessionID, Int)]) async -> Void
    private var tail: Task<Void, Never>?
    private var queued: Task<Void, Never>?
    private var drains: [TransferSessionID: Int] = [:]
    private var stopped = false

    init(pass: @escaping @Sendable ([(TransferSessionID, Int)]) async -> Void) { self.pass = pass }

    nonisolated func schedule(drain: (TransferSessionID, Int)?) {
        Task { await self.request(drain: drain) }
    }

    @discardableResult
    func request(drain: (TransferSessionID, Int)?) -> Task<Void, Never> {
        if let (session, number) = drain { drains[session] = max(drains[session] ?? 0, number) }
        if let queued { return queued }
        guard !stopped else { return Task {} }
        let previous = tail
        let task = Task {
            await previous?.value
            await self.begin()
        }
        queued = task
        tail = task
        return task
    }

    private func begin() async {
        queued = nil
        guard !stopped, !Task.isCancelled else { return }
        let due = drains.map { ($0.key, $0.value) }
        drains = [:]
        await pass(due)
    }

    func stop() async {
        stopped = true
        queued?.cancel()
        await tail?.value
    }
}

// MARK: - Background windows

/// What a background window spends its time on, over the account's engine (B7's seam).
struct EngineWindowWork: BackgroundWindowWork {
    let engine: TransferEngine<ContinuousClock>
    let discovery: LibraryDiscovery
    let reconciling: @Sendable () async -> Void
    let preSync: (@Sendable () async -> Void)?
    let preferences: @Sendable () async -> TransferPreferences?

    func reconcile() async throws { await reconciling() }
    func applyOutcomes() async throws { await reconciling() }
    func submitStaged() async throws { await engine.refresh() }
    func daemonOwnsWork() async -> Bool { await engine.daemonOwnsWork() }
    func runUntilHandedOff() async -> WindowHandoff { await engine.handoff() }
    func preSyncMetadata() async throws { await preSync?() }

    /// Automatic backup looks for new photos; with it off, a window only carries on what is queued.
    func discover() async throws {
        guard await preferences()?.automatic == true else { return }
        _ = try await engine.discover(discovery)
    }

    func conditionsChanged() async { await engine.conditionsChanged() }

    func automaticTriggerDelay() async -> Duration? {
        guard let preferences = await preferences(), preferences.automatic else { return nil }
        return .seconds(max(0, preferences.triggerDelay))
    }
}

// MARK: - The screens' commands

/// TransferControlling for the backup and Shared files screens over the account's engine, with
/// each command doing what its button always did:
/// - Pause switches automatic backup off and pauses the library lane;
/// - Back up now (manual) looks for new photos in the backup albums and uploads them, retrying
///   failed photos once, then ends as a run always has;
/// - Back up selected and Upload to album start uploading the photos, even while paused, and
///   retry one that failed; a share's Upload retries a file that failed too;
/// - Retry failed uploads retries the failed photos and runs as Back up now does;
/// - switching Automatic backup on or off starts or winds down automatic backup.
/// The snapshot's remaining count includes failed photos, which the queue lists, and its activity
/// words what the engine is doing as the status line always has. The failures the backup screen
/// lists are the phone's photos', as they always were; each lane's queue lists its failed jobs,
/// which is where the Shared files sheet finds a file's error.
struct EngineBackend: TransferControlling {
    let engine: TransferEngine<ContinuousClock>
    let store: TransferStore
    let discovery: LibraryDiscovery
    let preferencesChanged: @Sendable () -> Void
    /// Wakes the post-upload work.
    var followUp: @Sendable (FollowUpTrigger) -> Void = { _ in }

    func setIntent(_ intent: RunIntent) async throws {
        switch intent {
        case .paused:
            if var preferences = try await engine.preferences(), preferences.automatic {
                preferences.automatic = false
                try await engine.setPreferences(preferences)
            }
            try await engine.setIntent(.paused)
        case .manual:
            try await engine.runManually(discovery)
        case .automatic:
            try await engine.setIntent(.automatic)
        }
    }

    func enqueue(_ requests: [TransferRequest]) async throws -> EnqueueResult {
        let result = try await engine.enqueue(requests)
        // A photo already backed up joins its album now, without an upload.
        if requests.contains(where: { $0.album != nil }) { followUp(.committed(.library)) }
        if case .queued(let count) = result, count > 0, requests.contains(where: { $0.source.lane == .library }),
           await engine.runIntent == .paused {
            // Back up selected always started backup.
            try await engine.setIntent(.manual, requeueingFailures: false)
            await engine.settleManualRun()
        }
        return result
    }

    func cancel(_ sources: [TransferSource]) async throws { try await engine.cancel(sources) }

    func setPreferences(_ preferences: TransferPreferences) async throws {
        try await engine.setPreferencesFollowingAutomatic(preferences)
        preferencesChanged()
    }

    func preferences() async throws -> TransferPreferences? { try await engine.preferences() }

    /// Named jobs are retried as they are. Retry failed uploads (nil) is a manual run, which
    /// retries every failed photo and the album adds and stacks that failed after an upload; a
    /// shared file is retried from the Shared files sheet, as it always was.
    func retry(_ sources: [TransferSource]?) async throws {
        guard sources == nil else { return try await engine.retry(sources) }
        try await engine.runManually(discovery)
    }

    func snapshots() async -> AsyncStream<TransferSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: TransferSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let engine = self.engine
        let task = Task {
            for await snapshot in await engine.snapshots() {
                let preferences = try? await engine.preferences()
                continuation.yield(Self.presented(snapshot, preferences: preferences))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func queuePage(lane: TransferLane, after seq: Int64?, limit: Int) async throws -> [TransferQueueItem] {
        try await store.listedQueuePage(lane: lane, after: seq, limit: limit)
    }

    func historyPage(offset: Int, limit: Int) async throws -> [TransferHistoryItem] { try await engine.historyPage(offset: offset, limit: limit) }
    func failures(limit: Int) async throws -> [TransferQueueItem] { try await store.failures(lane: .library, limit: limit) }
    func albumUploadCounts() async throws -> [String: AlbumUploadCount] { try await engine.albumUploadCounts() }

    /// The engine's snapshot as the backup screen shows it.
    static func presented(_ snapshot: TransferSnapshot, preferences: TransferPreferences?) -> TransferSnapshot {
        var shown = snapshot
        // Failed photos stay in the queue the screen lists, as they always did.
        shown.remaining = snapshot.remaining + snapshot.failed
        shown.activity = activity(snapshot, preferences: preferences)
        return shown
    }

    /// The status line, in the words backup always used.
    static func activity(_ snapshot: TransferSnapshot, preferences: TransferPreferences?) -> String {
        switch snapshot.phase {
        case .blocked(let restriction):
            return restriction == .readOnly ? "Backup paused" : "Backup needs attention"
        case .waiting(.deviceConditions):
            return preferences?.requireCharging == true ? "Waiting for charging and a cool device" : "Waiting for the device to cool down"
        case .waiting(.connectivity), .waiting(.unmeteredNetwork):
            return "Waiting for a network connection"
        case .waiting(.serverBackoff):
            return "Waiting for the server"
        case .discovering:
            return "Finding new photos"
        case .running:
            return "Uploading"
        case .idle:
            if snapshot.remaining > 0 { return snapshot.intent == .paused ? "Backup paused" : "Waiting to upload" }
            if snapshot.failed > 0 { return "\(snapshot.failed.formatted()) uploads need retry" }
            if preferences?.includedAlbums.isEmpty ?? true { return "Choose albums to back up" }
            return "Selected photos backed up"
        }
    }
}

// MARK: - Receipts

/// The receipts cleanup and the device index read once the engine owns the database: SQL over the
/// account's transfers database (ReceiptRepository and DeviceIndexBackupSource, DS12).
struct TransferReceiptSource: ReceiptRepository, DeviceIndexBackupSource {
    let store: TransferStore
    let broadcast: ChangeBroadcast

    func receipts(account: String) async -> [String: CleanupReceipt]? {
        try? await store.cleanupReceipts()
    }

    func recordSizes(_ sizes: [String: VerifiedSize], account: String) async {
        let measured = sizes.map { localID, size in
            VerifiedSizes(localID: localID, revision: size.receipt.revision, originalID: size.receipt.original.id, motionID: size.receipt.motion?.id,
                          originalBytes: size.original, motionBytes: size.motion)
        }
        guard !measured.isEmpty else { return }
        _ = try? await store.updateVerifiedSizes(ifUnchanged: measured, at: Date())
    }

    func markLocallyDeleted(_ localIDs: [String], account: String) async {
        let now = Date()
        if (try? await store.markLocallyDeleted(localIDs.map { LocalDeletion(localID: $0, revision: nil, date: now) })) ?? 0 > 0 {
            broadcast.send()
        }
    }

    func inputs(account: String) async -> DeviceIndexBackupInputs? {
        guard let receipts = try? await store.cleanupReceipts() else { return nil }
        let preferences = try? await store.preferences()
        return DeviceIndexBackupInputs(included: preferences?.includedAlbums ?? [], excluded: preferences?.excludedAlbums ?? [],
                                       receipts: receipts.filter { !$0.value.locallyDeleted })
    }

    func changes() async -> AsyncStream<Void> { broadcast.stream() }
}

/// Tells every subscriber that something changed, merged while unread.
final class ChangeBroadcast: Sendable {
    private struct State {
        var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
        var finished = false
    }
    private let state = Mutex(State())

    func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let finished = state.withLock { state -> Bool in
            if !state.finished { state.subscribers[id] = continuation }
            return state.finished
        }
        if finished { continuation.finish() }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) } }
        return stream
    }

    func send() {
        for subscriber in state.withLock({ Array($0.subscribers.values) }) { subscriber.yield() }
    }

    func finish() {
        let subscribers = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            state.finished = true
            defer { state.subscribers = [:] }
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.finish() }
    }
}

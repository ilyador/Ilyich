import BackgroundTasks
import Foundation
import IlyichPlatform
import IlyichShareInbox
import os
import UIKit

/// The process's backup engine: the transfer engine runs every account's backup (B9; the old
/// engine it replaced is gone since B10). iOS allows one URLSession per background identifier and
/// one launch handler per background task identifier, so the process starts the engine's sessions
/// and lifecycle once, when the first account's backup starts, and hands them to each account's
/// runtime in turn.
///
/// At launch (architecture section 4): the background task identifiers are registered at once,
/// through a router that holds a task until the engine starts; a background session's events are
/// held the same way, their completion answered at the 20 s deadline if the engine hasn't started
/// by then, and a launch for either restores the account. Starting the engine creates the sessions
/// (TransportRegistry), the completion queue (BackgroundEventAcks) and the lifecycle source, and
/// from then on hands each to the account's TransferRuntime: a session's completion is registered
/// before its session is touched and answered only after the runtime committed what it delivered.
@MainActor final class TransferHost {
    static let shared = TransferHost(scheduler: SystemBackgroundTaskScheduler(), makeRegistry: { TransportRegistry.live() })

    /// What the backup and Shared files screens send their commands to.
    let backend: BackupBackendRouter
    let tasks: BackgroundTaskRouter
    private let makeRegistry: () -> TransportRegistry
    private(set) var registry: TransportRegistry?
    private var acks: BackgroundEventAcks<ContinuousClock>?
    private(set) var source: LifecycleEventSource?
    private var inputs: SystemLifecycleInputs?
    private(set) var current: TransferRuntime?
    private var consumers: [Task<Void, Never>] = []
    /// Drains that came before a runtime could commit them.
    private var drains: [(TransferSessionID, Int)] = []
    /// Window leases that came before a runtime could use them.
    private var windows: [BGTaskLease] = []
    /// Background session events that came before the engine started.
    private var held: [(identifier: String, completion: OnceCompletion)] = []
    private var restore: (@MainActor () async -> Void)?
    private var usesDevicePhotos = false
    /// Why the signed-in account's backup can't start, for Diagnostics.
    private var unavailableReason: String?
    private static let logger = Logger(subsystem: "app.ilyich.native", category: "Transfers")

    init(scheduler: any BackgroundTaskScheduling, makeRegistry: @escaping () -> TransportRegistry) {
        self.makeRegistry = makeRegistry
        tasks = BackgroundTaskRouter(system: scheduler)
        // Commands wait for the first account's backup.
        backend = BackupBackendRouter(route: .preparing)
    }

    // MARK: Launch

    /// Opens the saved account when a background launch needs it. The app sets it as it starts.
    func setRestore(_ restore: @escaping @MainActor () async -> Void) { self.restore = restore }

    /// In didFinishLaunching, synchronously: registers both background task identifiers, holding
    /// any task until the engine starts.
    func launch(usesDevicePhotos: Bool) {
        self.usesDevicePhotos = usesDevicePhotos
        guard usesDevicePhotos else {
            // No backup runs in this process (UI tests): the screens' commands are refused.
            backend.deactivate()
            return
        }
        tasks.registerWithSystem { [weak self] in self?.restoreForBackgroundWork() }
    }

    /// iOS relaunched the app, or woke it, for a background session's events.
    func handleEvents(identifier: String, completion: @escaping @MainActor () -> Void) {
        guard registry == nil else { return deliver(identifier: identifier, completion: completion) }
        guard TransferSessionID(identifier: identifier) != nil else { return completion() }
        let once = OnceCompletion(completion)
        held.append((identifier, once))
        // Answered at iOS's deadline if the engine hasn't started by then; the session's events
        // stay with iOS until a session is made for them.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.registry == nil else { return }
            self.held.removeAll { $0.completion === once }
            once.call()
        }
        restoreForBackgroundWork()
    }

    private func restoreForBackgroundWork() {
        guard registry == nil, let restore else { return }
        Task { await restore() }
    }

    private func deliver(identifier: String, completion: @escaping @MainActor () -> Void) {
        guard let acks, let registry else { return completion() }
        acks.register(identifier: identifier, completion: completion)
        _ = registry.transport(identifier: identifier)
        source?.urlSessionEvents(identifier)
    }

    // MARK: Starting

    /// Starts the engine's sessions, completion queue and lifecycle source, once per process, and
    /// hands them the events held for them.
    func startEngine() {
        guard registry == nil else { return }
        startTransport()
        for event in held { deliver(identifier: event.identifier) { event.completion.call() } }
        held = []
    }

    /// Creates the sessions, the completion queue and the lifecycle source, and routes their
    /// events to the account's runtime.
    private func startTransport() {
        let registry = makeRegistry()
        self.registry = registry
        acks = BackgroundEventAcks(clock: ContinuousClock()) { registry.drains(identifier: $0) }
        consumers.append(Task { [weak self] in
            for await event in registry.events { self?.route(event) }
        })
        // iOS delivers what it queued for each session once the session exists.
        registry.connect()
        guard usesDevicePhotos else { return }
        let source = LifecycleEventSource(initial: SystemLifecycleInputs.current(), scheduler: tasks)
        self.source = source
        // iOS turning automatic backup's windows down shows on the backup screen.
        let backend = self.backend
        source.schedulingErrorChanged = { backend.schedulingErrorChanged($0) }
        source.register()
        let inputs = SystemLifecycleInputs()
        inputs.start(feeding: source)
        self.inputs = inputs
        consumers.append(Task { [weak self] in
            for await event in source.events { self?.route(event) }
        })
        let changes = PhotoKitAdapter.shared.changes()
        consumers.append(Task { [weak source] in
            for await _ in changes { source?.photoLibraryChanged() }
        })
    }

    private func route(_ event: TransportEvent) {
        if case .drained(let session, let drain) = event, current == nil { drains.append((session, drain)) }
        current?.receive(event)
    }

    private func route(_ event: LifecycleEvent) {
        if let current { return current.receive(event) }
        guard case .window(let lease) = event else { return }
        // Held for the runtime about to start; one that never comes leaves the task to expire.
        windows.append(lease)
        lease.onExpiration { [weak self] in Task { @MainActor in self?.windows.removeAll { $0 === lease } } }
    }

    // MARK: Accounts

    private static let engineCouldNotStart = "The transfer engine couldn’t start."
    /// What the screens say while the account's backup can't start.
    static let nextLaunchMessage = "Quit and reopen Ilyich to back up this account."

    /// The account's backup, each time it becomes active: its transfers database is readied for
    /// the engine (AccountRuntime.prepareTransfers), then the account's TransferRuntime starts. The
    /// screens' commands wait meanwhile and reach the engine once it runs.
    func activate(_ runtime: AccountRuntime) async {
        unavailableReason = nil
        backend.prepare()
        let decision = await runtime.prepareTransfers()
        // The account ended while its database was readied: nothing starts for it.
        guard !runtime.authorization.hasEnded else {
            runtime.cutover.decide(.unavailable)
            backend.deactivate()
            return
        }
        switch decision {
        case .engine:
            startEngine()
            guard let registry, let made = makeRuntime(for: runtime, registry: registry) else {
                return unavailable(runtime, reason: Self.engineCouldNotStart)
            }
            runtime.cutover.decide(.engine(made.receipts))
            attach(made)
            do {
                try await made.start()
                if current === made { backend.use(made.backend) }
            } catch {
                Self.logger.error("The transfer engine didn't start: \(String(describing: error), privacy: .public)")
                if current === made { unavailable(runtime, reason: "\(Self.engineCouldNotStart) \(error.localizedDescription)") }
            }
        case .unavailable(let reason):
            unavailable(runtime, reason: reason)
        }
    }

    /// The account's backup can't start in this process; the screens say to reopen the app, which
    /// tries again.
    private func unavailable(_ runtime: AccountRuntime, reason: String) {
        runtime.cutover.decide(.unavailable)
        unavailableReason = reason
        Self.logger.notice("This account's backup can't start: \(reason, privacy: .public)")
        backend.waitForNextLaunch(Self.nextLaunchMessage)
    }

    private func makeRuntime(for runtime: AccountRuntime, registry: TransportRegistry) -> TransferRuntime? {
        guard let transfers = runtime.transfers, let layout = try? AppGroupLayout.current(), let inbox = try? ShareInboxRepository.appGroup() else {
            return nil
        }
        var preSync: (@Sendable () async -> Void)?
        if let sync = runtime.library?.sync {
            preSync = { _ = await sync.prepareForBackgroundBackup() }
        }
        let acks = self.acks
        let acknowledge: @Sendable (TransferSessionID, Int) async -> Void = { session, drain in
            await MainActor.run { acks?.committed(identifier: session.identifier, through: drain) }
        }
        let scheduler: (any WindowScheduling)? = source
        let parts = TransferRuntime.Parts(
            account: runtime.credential.account, store: transfers.store, authorization: runtime.authorization, server: runtime.transferServer,
            registry: registry, layout: layout, inbox: inbox, staging: PhotoKitAdapter.shared, scheduler: scheduler, time: SystemBackgroundTime(),
            appActive: UIApplication.shared.applicationState == .active, preSync: preSync, acknowledge: acknowledge)
        let made = TransferRuntime(parts)
        runtime.attachTransfers(made) { [weak self] in self?.detach(made) }
        return made
    }

    /// The runtime takes the sessions' and the lifecycle's events from now on.
    private func attach(_ runtime: TransferRuntime) {
        current = runtime
        for (session, drain) in drains { runtime.receive(.drained(session, drain: drain)) }
        drains = []
        let leases = windows
        windows = []
        for lease in leases { runtime.receive(.window(lease)) }
    }

    /// The account's runtime is ending: its engine stops taking events and commands.
    func detach(_ runtime: TransferRuntime) {
        guard current === runtime else { return }
        current = nil
        backend.deactivate()
    }

    /// Photos access changed in the backup screen: automatic backup looks again.
    func accessChanged() { source?.preferencesChanged() }

    /// What Diagnostics says about the engine: whether it runs, why the account's backup can't
    /// start if it can't, and why records an older build left stay on the phone if they do.
    var summary: String {
        var text = registry == nil ? "Not started" : "Transfer engine"
        if let unavailableReason { text += ". This account’s backup can’t start: \(unavailableReason)" }
        if case .kept(let reason)? = current?.legacyRetirement { text += ". Old backup records kept: \(reason.text)" }
        return text
    }
}

// MARK: - Background task router

/// Registers the background task identifiers with iOS once, at launch, and hands each task to the
/// engine's handler; a task that comes before the engine starts is held until it does, or until
/// iOS takes its time back. To LifecycleEventSource it is the scheduler: registering a handler
/// here takes the place of registering with iOS, which happened already.
@MainActor final class BackgroundTaskRouter: BackgroundTaskScheduling {
    private let system: any BackgroundTaskScheduling
    private var launchers: [String: @MainActor (any BackgroundTaskHandle) -> Void] = [:]
    private var held: [any BackgroundTaskHandle] = []
    private var registered = false
    private var waiting: (@MainActor () -> Void)?

    init(system: any BackgroundTaskScheduling) { self.system = system }

    /// Registers both identifiers with iOS, as didFinishLaunching must. `waiting` runs when a
    /// task comes before anything handles it.
    func registerWithSystem(waiting: @escaping @MainActor () -> Void) {
        guard !registered else { return }
        registered = true
        self.waiting = waiting
        for kind in BackgroundWindowKind.allCases {
            _ = system.register(identifier: kind.identifier) { [weak self] task in self?.launched(task) }
        }
    }

    private func launched(_ task: any BackgroundTaskHandle) {
        if let launch = launchers[task.identifier] { return launch(task) }
        held.append(task)
        task.expirationHandler = { [weak self, weak task] in
            MainActor.assumeIsolated {
                guard let self, let task else { return }
                self.held.removeAll { $0 === task }
                task.setTaskCompleted(success: false)
            }
        }
        waiting?()
    }

    // MARK: BackgroundTaskScheduling

    func register(identifier: String, launch: @escaping @MainActor (any BackgroundTaskHandle) -> Void) -> Bool {
        launchers[identifier] = launch
        let due = held.filter { $0.identifier == identifier }
        held.removeAll { $0.identifier == identifier }
        for task in due {
            task.expirationHandler = nil
            launch(task)
        }
        return registered
    }

    func submit(_ request: WindowRequest, answered: @escaping @MainActor @Sendable (String?) -> Void) { system.submit(request, answered: answered) }
    func cancel(identifier: String) { system.cancel(identifier: identifier) }
    func pending() async -> [WindowRequest] { await system.pending() }
}

/// A completion handler that runs once, whichever path answers it first.
@MainActor final class OnceCompletion {
    private var completion: (@MainActor () -> Void)?
    init(_ completion: @escaping @MainActor () -> Void) { self.completion = completion }
    func call() {
        let completion = self.completion
        self.completion = nil
        completion?()
    }
}

// MARK: - The screens' backend

/// The backend the backup and Shared files screens use (BackupStore.shared, ShareInboxModel). It
/// follows the account whose backup the process runs: the account's transfer engine once that
/// runs, and nothing otherwise.
///
/// While the account's backup is prepared (its database readied, then the engine's start), a
/// command waits for it and reads find nothing. An edit of the preferences is taken only once the
/// screen has read the preferences of the backup in use: one made before, against values that
/// were never this account's, is not written (StalePreferencesEdit), and the screen shows the
/// account's instead. When no backup runs, a command is refused, saying why. The snapshots follow
/// the engine, switching as the route changes, and carry iOS's refusal to schedule automatic
/// backup when there is no other message.
@MainActor final class BackupBackendRouter: TransferControlling {
    enum Route {
        /// The account's backup is being prepared: commands wait.
        case preparing
        /// The account's transfer engine (EngineBackend).
        case engine(any TransferControlling)
        /// No backup runs: nobody is signed in, or the process runs without the phone's photos.
        case inactive
        /// The account's backup can't start until the app reopens, saying so.
        case waiting(String)
    }

    private(set) var route: Route
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var subscribers: [UUID: Subscriber] = [:]
    private var schedulingError: String?
    /// The screen read the preferences of the backup in use.
    private var preferencesRead = false

    private struct Subscriber {
        let continuation: AsyncStream<TransferSnapshot>.Continuation
        var task: Task<Void, Never>?
        /// The engine's last snapshot, as the engine sent it.
        var last: TransferSnapshot?
    }

    init(route: Route) {
        self.route = route
    }

    // MARK: Routes (TransferHost)

    /// The account's backup is being prepared.
    func prepare() { set(.preparing) }
    /// The account's transfer engine runs.
    func use(_ engine: any TransferControlling) { set(.engine(engine)) }
    /// No backup runs.
    func deactivate() { set(.inactive) }
    /// The account's backup can't start until the app reopens; `message` says so.
    func waitForNextLaunch(_ message: String) { set(.waiting(message)) }

    /// iOS turned a background window of automatic backup down, with its message, or took one
    /// again (nil).
    func schedulingErrorChanged(_ message: String?) {
        guard message != schedulingError else { return }
        schedulingError = message
        for subscriber in subscribers.values {
            if let last = subscriber.last { subscriber.continuation.yield(shown(last)) }
        }
    }

    private func set(_ route: Route) {
        self.route = route
        preferencesRead = false
        if case .preparing = route {} else {
            let resumed = waiters
            waiters = []
            for waiter in resumed { waiter.resume() }
        }
        for id in subscribers.keys { follow(id) }
    }

    // MARK: TransferControlling

    func setIntent(_ intent: RunIntent) async throws { try await target().setIntent(intent) }
    func enqueue(_ requests: [TransferRequest]) async throws -> EnqueueResult { try await target().enqueue(requests) }
    func cancel(_ sources: [TransferSource]) async throws { try await target().cancel(sources) }
    func retry(_ sources: [TransferSource]?) async throws { try await target().retry(sources) }

    func setPreferences(_ preferences: TransferPreferences) async throws {
        switch route {
        case .engine(let engine) where preferencesRead: try await engine.setPreferences(preferences)
        case .waiting(let message): throw BackupError.message(message)
        case .preparing, .inactive, .engine: throw StalePreferencesEdit()
        }
    }

    func preferences() async throws -> TransferPreferences? {
        guard let reader else { return nil }
        preferencesRead = true
        return try await reader.preferences()
    }
    func queuePage(lane: TransferLane, after seq: Int64?, limit: Int) async throws -> [TransferQueueItem] {
        try await reader?.queuePage(lane: lane, after: seq, limit: limit) ?? []
    }
    func historyPage(offset: Int, limit: Int) async throws -> [TransferHistoryItem] {
        try await reader?.historyPage(offset: offset, limit: limit) ?? []
    }
    func failures(limit: Int) async throws -> [TransferQueueItem] { try await reader?.failures(limit: limit) ?? [] }
    func albumUploadCounts() async throws -> [String: AlbumUploadCount] { try await reader?.albumUploadCounts() ?? [:] }

    func snapshots() async -> AsyncStream<TransferSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: TransferSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = Subscriber(continuation: continuation)
        continuation.onTermination = { [weak self] _ in Task { @MainActor [weak self] in self?.unsubscribe(id) } }
        follow(id)
        return stream
    }

    // MARK: Routing

    /// Where a command goes, once the account's backup is prepared.
    private func target() async throws -> any TransferControlling {
        while case .preparing = route {
            await withCheckedContinuation { waiters.append($0) }
        }
        switch route {
        case .engine(let engine): return engine
        case .waiting(let message): throw BackupError.message(message)
        case .preparing, .inactive: throw BackupError.message(AccountRestriction.signedOut.backupMessage)
        }
    }

    /// Where reads go: nowhere while no account's backup is in use.
    private var reader: (any TransferControlling)? {
        switch route {
        case .engine(let engine): engine
        case .preparing, .inactive, .waiting: nil
        }
    }

    private func follow(_ id: UUID) {
        guard let subscriber = subscribers[id] else { return }
        subscriber.task?.cancel()
        subscribers[id]?.task = nil
        subscribers[id]?.last = nil
        let continuation = subscriber.continuation
        switch route {
        case .engine(let engine):
            subscribers[id]?.task = Task { [weak self] in
                for await snapshot in await engine.snapshots() {
                    guard !Task.isCancelled, let self else { return }
                    self.subscribers[id]?.last = snapshot
                    continuation.yield(self.shown(snapshot))
                }
            }
        case .preparing, .inactive, .waiting:
            continuation.yield(Self.placeholder(route))
        }
    }

    /// The engine's snapshot, with iOS's refusal to schedule automatic backup when there is no
    /// other message.
    private func shown(_ snapshot: TransferSnapshot) -> TransferSnapshot {
        guard snapshot.lastMessage == nil, let schedulingError else { return snapshot }
        var shown = snapshot
        shown.lastMessage = schedulingError
        return shown
    }

    /// What the screens show while no account's backup is in use.
    private static func placeholder(_ route: Route) -> TransferSnapshot {
        var snapshot = TransferSnapshot(intent: .paused, phase: .idle, remaining: 0, confirmed: 0, failed: 0, fileProgress: nil,
                                        bytesSent: 0, bytesExpected: 0, bytesPerSecond: nil, lastMessage: nil)
        switch route {
        case .preparing: snapshot.activity = "Preparing backup"
        case .waiting(let message):
            snapshot.activity = "Backup paused"
            snapshot.lastMessage = message
        case .engine, .inactive: break
        }
        return snapshot
    }

    private func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.task?.cancel()
    }
}

/// An edit of the preferences made before the screen read those of the backup in use, which the
/// router doesn't write: it was made against values that were never this account's.
struct StalePreferencesEdit: Error, Equatable {}

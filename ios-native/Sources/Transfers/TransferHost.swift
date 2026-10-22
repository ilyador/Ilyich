import BackgroundTasks
import Foundation
import IlyichPlatform
import IlyichShareInbox
import os
import UIKit

/// The process's backup engine (B9): the transfer engine for an account whose backup records the
/// cutover imported, else today's BackupCoordinator, which stays as the way back if the import
/// fails (it says so in Diagnostics). iOS allows one URLSession per background identifier and one
/// launch handler per background task identifier, so a process runs exactly one of them: the
/// first account activated decides, and the choice holds until the app ends.
///
/// At launch (architecture section 4): the background task identifiers are registered at once,
/// through a router that holds a task until the engine is chosen; a background session's events
/// are held the same way, their completion answered at the 20 s deadline if nothing is chosen by
/// then, and a launch for either restores the account. Choosing the transfer engine creates the
/// sessions (TransportRegistry), the completion queue (BackgroundEventAcks) and the lifecycle
/// source, and from then on hands each to the account's TransferRuntime: a session's completion is
/// registered before its session is touched and answered only after the runtime committed what it
/// delivered.
@MainActor final class TransferHost {
    static let shared = TransferHost(legacy: .live, scheduler: SystemBackgroundTaskScheduler(), makeRegistry: { TransportRegistry.live() })

    enum Engine: Equatable, Sendable {
        case undecided
        /// The transfer engine.
        case transfer
        /// Today's BackupCoordinator, with the reason.
        case legacy(String)
    }

    /// What today's backup does at each step, for the way back.
    struct LegacyBackup {
        var coordinator: @MainActor () -> BackupCoordinator
        var inbox: @MainActor () -> ShareInboxStore
        var registerLifecycle: @MainActor (BackgroundTaskRouter) -> Void
        var handleEvents: @MainActor (String, @escaping @MainActor () -> Void) -> Void

        static let live = LegacyBackup(
            coordinator: { BackupCoordinator.shared }, inbox: { ShareInboxStore.shared },
            registerLifecycle: { router in
                // Upload progress reaches the backup and Shared files screens as the sessions report
                // it. Neither session is made here: one relaunched for its events is made once its
                // completion is in hand, or when backup or sharing first needs it.
                BackgroundUploads.observeProgress(of: BackgroundUploads.identifier) { value in
                    Task { @MainActor in BackupCoordinator.shared.applyProgress(value) }
                }
                BackgroundUploads.observeProgress(of: BackgroundUploads.shareIdentifier) { value in
                    Task { @MainActor in ShareInboxStore.shared.applyProgress(value) }
                }
                BackupLifecycle.shared.register(using: router)
            },
            handleEvents: { identifier, completion in
                let uploads: BackgroundUploads
                switch identifier {
                case BackgroundUploads.identifier: uploads = .shared
                case BackgroundUploads.shareIdentifier: uploads = .sharing
                default: completion(); return
                }
                let answer = MainActorCompletion(completion)
                uploads.handleEvents { Task { @MainActor in answer.call() } }
                if identifier == BackgroundUploads.identifier { Task { await BackupCoordinator.shared.activate() } }
            })
    }

    private(set) var engine: Engine = .undecided
    /// What the backup and Shared files screens send their commands to.
    let backend: BackupBackendRouter
    let tasks: BackgroundTaskRouter
    private let legacy: LegacyBackup
    private let makeRegistry: () -> TransportRegistry
    /// False for tests that run today's backup only.
    private let allowsTransferEngine: Bool
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
    /// Background session events that came before the engine was chosen.
    private var held: [(identifier: String, completion: OnceCompletion)] = []
    private var restore: (@MainActor () async -> Void)?
    private var usesDevicePhotos = false
    /// Why the signed-in account's backup waits for the next launch, for Diagnostics.
    private var waitingReason: String?
    private static let logger = Logger(subsystem: "app.ilyich.native", category: "Transfers")

    init(legacy: LegacyBackup, scheduler: any BackgroundTaskScheduling, makeRegistry: @escaping () -> TransportRegistry,
         allowsTransferEngine: Bool = true) {
        self.legacy = legacy
        self.makeRegistry = makeRegistry
        self.allowsTransferEngine = allowsTransferEngine
        tasks = BackgroundTaskRouter(system: scheduler)
        // Commands wait for the first account's backup; a host that runs only today's backup
        // sends them there from the start.
        backend = BackupBackendRouter(legacy: LegacyCoordinatorBackend(coordinator: legacy.coordinator(), inbox: legacy.inbox()),
                                      route: allowsTransferEngine ? .preparing : .legacy)
    }

    /// A host that only ever runs today's backup over `coordinator`, for tests of it: one per
    /// coordinator.
    static func legacyOnly(_ coordinator: BackupCoordinator) -> TransferHost {
        if let host = legacyHosts[ObjectIdentifier(coordinator)] { return host }
        var legacy = LegacyBackup.live
        legacy.coordinator = { coordinator }
        legacy.registerLifecycle = { _ in }
        let host = TransferHost(legacy: legacy, scheduler: SystemBackgroundTaskScheduler(), makeRegistry: { TransportRegistry.live() },
                                allowsTransferEngine: false)
        legacyHosts[ObjectIdentifier(coordinator)] = host
        return host
    }

    private static var legacyHosts: [ObjectIdentifier: TransferHost] = [:]

    // MARK: Launch

    /// Opens the saved account when a background launch needs it. The app sets it as it starts.
    func setRestore(_ restore: @escaping @MainActor () async -> Void) { self.restore = restore }

    /// In didFinishLaunching, synchronously: registers both background task identifiers, holding
    /// any task until the engine is chosen.
    func launch(usesDevicePhotos: Bool) {
        self.usesDevicePhotos = usesDevicePhotos
        guard usesDevicePhotos else {
            // No backup runs in this process (UI tests): the screens' commands are refused.
            if allowsTransferEngine { backend.deactivate() }
            return
        }
        tasks.registerWithSystem { [weak self] in self?.restoreForBackgroundWork() }
    }

    /// iOS relaunched the app, or woke it, for a background session's events.
    func handleEvents(identifier: String, completion: @escaping @MainActor () -> Void) {
        switch engine {
        case .transfer:
            deliver(identifier: identifier, completion: completion)
        case .legacy:
            legacy.handleEvents(identifier, completion)
        case .undecided:
            guard TransferSessionID(identifier: identifier) != nil else { return completion() }
            let once = OnceCompletion(completion)
            held.append((identifier, once))
            // Answered at iOS's deadline if no engine was chosen by then; the session's events stay
            // with iOS until a session is made for them.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, case .undecided = self.engine else { return }
                self.held.removeAll { $0.completion === once }
                once.call()
            }
            restoreForBackgroundWork()
        }
    }

    private func restoreForBackgroundWork() {
        guard case .undecided = engine, let restore else { return }
        Task { await restore() }
    }

    private func deliver(identifier: String, completion: @escaping @MainActor () -> Void) {
        guard let acks, let registry else { return completion() }
        acks.register(identifier: identifier, completion: completion)
        _ = registry.transport(identifier: identifier)
        source?.urlSessionEvents(identifier)
    }

    // MARK: Choosing

    /// Chooses the transfer engine for the process, unless today's backup already runs. Says
    /// whether the transfer engine runs.
    @discardableResult
    func chooseTransfer() -> Bool {
        switch engine {
        case .transfer: return true
        case .legacy: return false
        case .undecided:
            guard allowsTransferEngine else { return false }
            engine = .transfer
            startTransport()
            for event in held { deliver(identifier: event.identifier) { event.completion.call() } }
            held = []
            return true
        }
    }

    /// Chooses today's backup for the process, unless the transfer engine already runs. Says
    /// whether today's backup runs.
    @discardableResult
    func chooseLegacy(_ reason: String) -> Bool {
        switch engine {
        case .legacy: return true
        case .transfer: return false
        case .undecided:
            engine = .legacy(reason)
            Self.logger.notice("Backup runs on the old engine: \(reason, privacy: .public)")
            legacy.registerLifecycle(tasks)
            for event in held { legacy.handleEvents(event.identifier) { event.completion.call() } }
            held = []
            return true
        }
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
        // iOS turning automatic backup's windows down shows on the backup screen, as it did.
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

    /// What an account's backup runs on, in a process that runs one engine.
    enum Placement: Equatable {
        case transferEngine
        /// Today's backup, with the reason.
        case legacy(String)
        /// Nothing until the app's next launch, with the reason.
        case nextLaunch(String)
    }

    /// The transfer engine when the account's import handed it the database and the process may
    /// run it; today's backup when the import couldn't and the process doesn't run the transfer
    /// engine; else nothing until the next launch. An account whose records the transfer engine
    /// owns never runs on today's backup, whose state.json for it stopped at the cutover.
    static func placement(_ decision: TransferCutover, running engine: Engine, allowsTransferEngine: Bool) -> Placement {
        switch decision {
        case .engine:
            // A host that runs only today's backup, for tests of it.
            guard allowsTransferEngine else {
                if case .legacy(let reason) = engine { return .legacy(reason) }
                return .legacy(engineCouldNotStart)
            }
            if case .legacy = engine { return .nextLaunch("The old engine runs for an account signed in earlier.") }
            return .transferEngine
        case .legacy(let reason):
            if case .transfer = engine { return .nextLaunch(reason) }
            return .legacy(reason)
        }
    }

    private static let engineCouldNotStart = "The transfer engine couldn’t start."
    /// What the screens say while the account's backup waits for the next launch.
    static let nextLaunchMessage = "Quit and reopen Ilyich to back up this account."

    /// The account's backup, each time it becomes active (Placement). The screens' commands wait
    /// while the import runs and the engine starts, and reach the engine once it runs.
    func activate(_ runtime: AccountRuntime) async {
        waitingReason = nil
        if allowsTransferEngine { backend.prepare() }
        let decision = await runtime.prepareTransfers()
        // The account ended while its records were imported: nothing is chosen for it.
        guard !runtime.authorization.hasEnded else {
            runtime.cutover.decide(.unavailable)
            if allowsTransferEngine { backend.deactivate() }
            return
        }
        switch Self.placement(decision, running: engine, allowsTransferEngine: allowsTransferEngine) {
        case .transferEngine:
            guard chooseTransfer(), let registry, let made = makeRuntime(for: runtime, registry: registry) else {
                return waitForNextLaunch(runtime, reason: Self.engineCouldNotStart)
            }
            runtime.cutover.decide(.engine(made.receipts))
            attach(made)
            do {
                try await made.start()
                if current === made { backend.use(made.backend) }
            } catch {
                Self.logger.error("The transfer engine didn't start: \(String(describing: error), privacy: .public)")
                if current === made { waitForNextLaunch(runtime, reason: "\(Self.engineCouldNotStart) \(error.localizedDescription)") }
            }
        case .legacy(let reason):
            guard chooseLegacy(reason) else { return waitForNextLaunch(runtime, reason: reason) }
            runtime.cutover.decide(.legacy)
            let coordinator = legacy.coordinator()
            // Whatever wakes today's backup takes up this account only.
            coordinator.takesUp = .only(runtime.credential.scope)
            let folder = (runtime.backupContainer ?? (try? AppGroupLayout.current().container))?
                .appendingPathComponent(AccountStoragePaths(runtime.credential.account).backup, isDirectory: true)
            await coordinator.activate(runtime.credential, folder: folder)
            backend.useLegacy(LegacyCoordinatorBackend(coordinator: coordinator, inbox: legacy.inbox(), shareClient: runtime.api))
        case .nextLaunch(let reason):
            waitForNextLaunch(runtime, reason: reason)
        }
    }

    /// The account's backup waits for the next launch, which chooses its engine afresh. Today's
    /// backup, if it runs here, can't take the account up meanwhile.
    private func waitForNextLaunch(_ runtime: AccountRuntime, reason: String) {
        runtime.cutover.decide(.unavailable)
        waitingReason = reason
        Self.logger.notice("Backup waits for the next launch: \(reason, privacy: .public)")
        if case .legacy = engine { legacy.coordinator().takesUp = .only(nil) }
        if allowsTransferEngine { backend.waitForNextLaunch(Self.nextLaunchMessage) }
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

    /// Stops uploads at sign-out. The transfer engine's account already did, as its runtime ended
    /// (AccountRuntime.prepareForSignOut); today's backup stops here, as it always has.
    func stopUploads(keepingAutomaticBackup: Bool) async {
        guard reachesLegacy else { return }
        await legacy.coordinator().disconnect(keepingAutomaticBackup: keepingAutomaticBackup)
    }

    /// Uploads follow a read-only change. The transfer engine follows the account's authorization
    /// itself (TransferEngine.block); today's backup is paused here, as it always was.
    func readOnlyChanged(_ enabled: Bool) async {
        guard reachesLegacy else { return }
        await AccountRuntime.uploadsFollow(readOnly: enabled, backup: legacy.coordinator(), shares: legacy.inbox())
    }

    /// Whether a command may reach today's backup: when the process runs it, or always in a host
    /// that runs nothing else. Before the choice nothing runs, and touching today's sessions then
    /// would make them beside the transfer engine's later.
    private var reachesLegacy: Bool {
        switch engine {
        case .legacy: true
        case .transfer: false
        case .undecided: !allowsTransferEngine
        }
    }

    /// Photos access changed in the backup screen: automatic backup looks again.
    func accessChanged() {
        switch engine {
        case .transfer: source?.preferencesChanged()
        case .legacy: BackupLifecycle.shared.configure()
        case .undecided: break
        }
    }

    /// The app came forward: Photos access may have changed in Settings meanwhile.
    func becameActive() {
        if case .legacy = engine { BackupLifecycle.shared.foregroundChanged() }
    }

    /// What Diagnostics says about the engine, and why the account's backup waits, if it does.
    var summary: String {
        let process = switch engine {
        case .undecided: "Not started"
        case .transfer: "Transfer engine"
        case .legacy(let reason): "Old engine: \(reason)"
        }
        guard let waitingReason else { return process }
        return "\(process). This account’s backup waits for Ilyich to reopen: \(waitingReason)"
    }

    /// Whether today's BackupCoordinator runs backup in this process.
    var runsLegacy: Bool {
        if case .legacy = engine { return true }
        return false
    }
}

// MARK: - Background task router

/// Registers the background task identifiers with iOS once, at launch, and hands each task to the
/// engine's handler; a task that comes before the engine is chosen is held until it is, or until
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

@MainActor private final class MainActorCompletion: Sendable {
    private let completion: @MainActor () -> Void
    init(_ completion: @escaping @MainActor () -> Void) { self.completion = completion }
    func call() { completion() }
}

// MARK: - The screens' backend

/// The backend the backup and Shared files screens use (BackupStore.shared, ShareInboxModel). It
/// follows the account whose backup the process runs: the account's transfer engine once that
/// runs, today's backup once the process chose it for the account, and nothing otherwise. Today's
/// backup is reached only when the process runs it: its sessions beside the transfer engine's
/// would be a second engine in one process (BM9).
///
/// While the account's backup is prepared (its import, then the engine's start), a command waits
/// for it and reads find nothing. An edit of the preferences is taken only once the screen has
/// read the preferences of the backup in use: one made before, against values that were never
/// this account's, is not written (StalePreferencesEdit), and the screen shows the account's
/// instead. When no backup runs, a command is refused, saying why. The snapshots follow whichever
/// is in use, switching as the route changes; the engine's carry iOS's refusal to schedule
/// automatic backup, as today's backup showed it, when there is no other message.
@MainActor final class BackupBackendRouter: TransferControlling {
    enum Route {
        /// The account's backup is being prepared: commands wait.
        case preparing
        /// The account's transfer engine (EngineBackend).
        case engine(any TransferControlling)
        /// Today's backup, which the process runs for the account.
        case legacy
        /// No backup runs: nobody is signed in, or the process runs without the phone's photos.
        case inactive
        /// The account's backup waits for the app's next launch, saying so.
        case waiting(String)
    }

    private(set) var route: Route
    private var legacy: any TransferControlling
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

    init(legacy: any TransferControlling, route: Route) {
        self.legacy = legacy
        self.route = route
    }

    /// Whether the screens reach today's backup.
    var routesToLegacy: Bool {
        if case .legacy = route { return true }
        return false
    }

    // MARK: Routes (TransferHost)

    /// The account's backup is being prepared.
    func prepare() { set(.preparing) }
    /// The account's transfer engine runs.
    func use(_ engine: any TransferControlling) { set(.engine(engine)) }
    /// Today's backup runs the account's backup, reached through `backend`.
    func useLegacy(_ backend: any TransferControlling) {
        legacy = backend
        set(.legacy)
    }
    /// No backup runs.
    func deactivate() { set(.inactive) }
    /// The account's backup waits for the next launch; `message` says so.
    func waitForNextLaunch(_ message: String) { set(.waiting(message)) }

    /// iOS turned a background window of automatic backup down, with today's message, or took one
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
        case .legacy where preferencesRead: try await legacy.setPreferences(preferences)
        case .waiting(let message): throw BackupError.message(message)
        case .preparing, .inactive, .engine, .legacy: throw StalePreferencesEdit()
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
        case .legacy: return legacy
        case .waiting(let message): throw BackupError.message(message)
        case .preparing, .inactive: throw BackupError.message(AccountRestriction.signedOut.backupMessage)
        }
    }

    /// Where reads go: nowhere while no account's backup is in use.
    private var reader: (any TransferControlling)? {
        switch route {
        case .engine(let engine): engine
        case .legacy: legacy
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
        case .legacy:
            let legacy = self.legacy
            subscribers[id]?.task = Task {
                for await snapshot in await legacy.snapshots() {
                    guard !Task.isCancelled else { return }
                    continuation.yield(snapshot)
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
        case .engine, .legacy, .inactive: break
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

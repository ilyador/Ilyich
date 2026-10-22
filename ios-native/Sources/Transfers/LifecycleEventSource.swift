import BackgroundTasks
import Foundation
import Network
import UIKit

// MARK: - Seams

/// A background task iOS launched: BGTask, or a test's fake.
@MainActor protocol BackgroundTaskHandle: AnyObject {
    var identifier: String { get }
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGTask: BackgroundTaskHandle {}

/// A request for one background window, as iOS keeps it.
struct WindowRequest: Hashable, Sendable {
    /// What a request asks for, its date aside: two requests of one shape are the same window.
    struct Shape: Hashable, Sendable {
        var requiresExternalPower = false
        var requiresNetworkConnectivity = false
    }

    let kind: BackgroundWindowKind
    let shape: Shape
    let earliestBeginDate: Date?
}

/// BGTaskScheduler, or a test's fake.
@MainActor protocol BackgroundTaskScheduling: AnyObject {
    /// Registers the launch handler; iOS calls it on the main queue.
    func register(identifier: String, launch: @escaping @MainActor (any BackgroundTaskHandle) -> Void) -> Bool
    /// Replaces the kind's request. iOS answers later: `answered` gets nil once it took the request,
    /// or why it turned it down.
    func submit(_ request: WindowRequest, answered: @escaping @MainActor @Sendable (String?) -> Void)
    func cancel(identifier: String)
    /// The requests iOS holds, from this process or an earlier one.
    func pending() async -> [WindowRequest]
}

// MARK: - Source

/// The device's conditions and the app's background time, as one stream of LifecycleEvent (B7).
/// TransferHost creates it once the process runs the transfer engine (B9), over the router that
/// registered the two identifiers at launch: iOS allows one launch handler per identifier.
///
/// - Conditions fold into one EnvironmentSnapshot, and an event goes out only when the snapshot
///   changes. A reading that only says how things already are is no event: the network monitor's
///   first callback, on every launch and in the background too, only seeds the snapshot.
/// - The app coming forward or going to the background are their own events; the snapshot's
///   appActive follows them.
/// - Photos changes are passed on and never reschedule anything. Only the transfer engine
///   schedules, through schedule(_:), and only when its plan changes; a request is submitted only
///   when its shape changes or iOS used it up, so a window's start is never pushed back.
@MainActor final class LifecycleEventSource: WindowScheduling {
    let events: AsyncStream<LifecycleEvent>
    private let continuation: AsyncStream<LifecycleEvent>.Continuation
    private let scheduler: any BackgroundTaskScheduling
    private let now: @Sendable () -> Date

    private(set) var snapshot: EnvironmentSnapshot
    private var networkSeeded = false
    private var registered = false

    private var plan = SchedulePlan.none
    /// The shape of each request iOS holds, as far as this process knows.
    private var held: [BackgroundWindowKind: WindowRequest.Shape] = [:]
    /// Kinds whose last request iOS turned down. They are asked for again when the app comes
    /// forward or goes to the background, or Photos changes, as BackupLifecycle asks again today.
    private var refused: Set<BackgroundWindowKind> = []
    /// Today's message while iOS turns a window down, for the cutover to show as BackupLifecycle
    /// does; nil once iOS takes a request again.
    private(set) var schedulingError: String?
    /// Reads what iOS held at launch, once.
    private var seeding: Task<[WindowRequest], Never>?
    private var seeded = false

    /// `initial` is how things stand at launch; its network is only a placeholder until the
    /// monitor's first reading.
    init(initial: EnvironmentSnapshot, scheduler: any BackgroundTaskScheduling, now: @escaping @Sendable () -> Date = { Date() }) {
        (events, continuation) = AsyncStream.makeStream(of: LifecycleEvent.self)
        snapshot = initial
        self.scheduler = scheduler
        self.now = now
    }

    /// Registers both launch handlers. Call it synchronously in didFinishLaunching, before it
    /// returns, as iOS requires.
    @discardableResult
    func register() -> Bool {
        guard !registered else { return true }
        var all = true
        for kind in BackgroundWindowKind.allCases {
            all = scheduler.register(identifier: kind.identifier) { [weak self] task in
                guard let self else { return task.setTaskCompleted(success: false) }
                self.launched(task)
            } && all
        }
        registered = all
        return all
    }

    // MARK: Inputs

    func networkChanged(_ network: EnvironmentSnapshot.Network) {
        guard networkSeeded else {
            // The monitor's first callback says how the network is, not that it changed.
            networkSeeded = true
            snapshot.network = network
            return
        }
        update { $0.network = network }
    }

    func chargingChanged(_ charging: Bool) { update { $0.charging = charging } }
    func thermalChanged(_ thermal: ProcessInfo.ThermalState) { update { $0.thermal = thermal } }
    func lowPowerChanged(_ lowPower: Bool) { update { $0.lowPower = lowPower } }

    func applicationBecameActive() {
        guard !snapshot.appActive else { return }
        snapshot.appActive = true
        retryRefused()
        continuation.yield(.becameActive)
    }

    func applicationEnteredBackground() {
        guard snapshot.appActive else { return }
        snapshot.appActive = false
        retryRefused()
        continuation.yield(.enteredBackground)
    }

    /// PhotoKitAdapter's coalesced changes. Passed on, never a reason to reschedule a window iOS
    /// holds; only one it turned down is asked for again.
    func photoLibraryChanged() {
        retryRefused()
        continuation.yield(.photoLibraryChanged)
    }
    func urlSessionEvents(_ identifier: String) { continuation.yield(.urlSessionEvents(identifier)) }
    func preferencesChanged() { continuation.yield(.preferencesChanged) }
    func readOnlyChanged() { continuation.yield(.readOnlyChanged) }

    func finish() { continuation.finish() }

    private func update(_ change: (inout EnvironmentSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        guard next != snapshot else { return }
        snapshot = next
        continuation.yield(.environment(next))
    }

    // MARK: Windows

    /// Called by the transfer engine only, with a plan that changed.
    func schedule(_ plan: SchedulePlan) async {
        if !seeded {
            let seeding = self.seeding ?? Task { await scheduler.pending() }
            self.seeding = seeding
            let pending = await seeding.value
            if !seeded {
                seeded = true
                for request in pending { held[request.kind] = request.shape }
            }
        }
        self.plan = plan
        apply()
    }

    private func launched(_ task: any BackgroundTaskHandle) {
        let complete = CompletionBox(task)
        let lease = BGTaskLease(identifier: task.identifier) { success in complete.call(success) }
        // iOS used the request up: ask for the next window of this kind, if the plan still wants one.
        held[lease.kind] = nil
        if seeded { apply() }
        // Synchronous, so the task is completed before the handler returns.
        task.expirationHandler = { lease.expire() }
        continuation.yield(.window(lease))
    }

    private func retryRefused() {
        guard seeded, !refused.isEmpty else { return }
        apply()
    }

    private func apply() {
        for kind in BackgroundWindowKind.allCases {
            let wanted = plan.request(kind)
            guard wanted?.shape != held[kind] else { continue }
            refused.remove(kind)
            if let wanted {
                let shape = wanted.shape
                held[kind] = shape
                scheduler.submit(WindowRequest(kind: kind, shape: shape, earliestBeginDate: now().addingTimeInterval(wanted.delay))) { [weak self] error in
                    // An answer to a request since replaced or cancelled says nothing about now.
                    guard let self, self.held[kind] == shape, !self.refused.contains(kind) else { return }
                    guard let error else {
                        if self.refused.isEmpty { self.schedulingError = nil }
                        return
                    }
                    // iOS refused (too many requests, or background refresh is off): nothing is held,
                    // and the next plan, window or trigger asks again.
                    self.held[kind] = nil
                    self.refused.insert(kind)
                    self.schedulingError = "iOS could not schedule automatic backup: \(error). You can still use Back up now."
                }
            } else {
                scheduler.cancel(identifier: kind.identifier)
                held[kind] = nil
            }
        }
        if plan == .none { schedulingError = nil }
    }
}

private extension SchedulePlan {
    func request(_ kind: BackgroundWindowKind) -> (shape: WindowRequest.Shape, delay: TimeInterval)? {
        switch kind {
        case .processing:
            processing.map { (WindowRequest.Shape(requiresExternalPower: $0.requiresExternalPower, requiresNetworkConnectivity: true), $0.earliestBegin.timeInterval) }
        case .refresh:
            refresh.map { (WindowRequest.Shape(), $0.timeInterval) }
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// Completes a task from the lease, whichever thread finishes it. BGTask's setTaskCompleted is
/// safe from any thread; a fake's runs on the main thread when the lease finishes there.
private final class CompletionBox: @unchecked Sendable {
    private let task: any BackgroundTaskHandle
    init(_ task: any BackgroundTaskHandle) { self.task = task }
    func call(_ success: Bool) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { task.setTaskCompleted(success: success) }
        } else {
            let task = self
            DispatchQueue.main.async { MainActor.assumeIsolated { task.task.setTaskCompleted(success: success) } }
        }
    }
}

// MARK: - Live inputs

/// BGTaskScheduler behind the seam, for TransferHost's router.
@MainActor final class SystemBackgroundTaskScheduler: BackgroundTaskScheduling {
    func register(identifier: String, launch: @escaping @MainActor (any BackgroundTaskHandle) -> Void) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { launch(task) }
        }
    }

    func submit(_ request: WindowRequest, answered: @escaping @MainActor @Sendable (String?) -> Void) {
        let task: BGTaskRequest
        switch request.kind {
        case .processing:
            let processing = BGProcessingTaskRequest(identifier: request.kind.identifier)
            processing.requiresExternalPower = request.shape.requiresExternalPower
            processing.requiresNetworkConnectivity = request.shape.requiresNetworkConnectivity
            task = processing
        case .refresh:
            task = BGAppRefreshTaskRequest(identifier: request.kind.identifier)
        }
        task.earliestBeginDate = request.earliestBeginDate
        // A new request of a kind replaces the one iOS held.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: request.kind.identifier)
        BGTaskScheduler.shared.submitTaskRequest(task) { error in
            let message = error?.localizedDescription
            Task { @MainActor in answered(message) }
        }
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    func pending() async -> [WindowRequest] {
        let requests = await BGTaskScheduler.shared.pendingTaskRequests()
        return requests.compactMap { request in
            guard let kind = BackgroundWindowKind(identifier: request.identifier) else { return nil }
            let processing = request as? BGProcessingTaskRequest
            return WindowRequest(kind: kind, shape: WindowRequest.Shape(requiresExternalPower: processing?.requiresExternalPower ?? false,
                                                                        requiresNetworkConnectivity: processing?.requiresNetworkConnectivity ?? false),
                                 earliestBeginDate: request.earliestBeginDate)
        }
    }
}

/// Feeds the source from the network monitor, battery, temperature, Low Power Mode and the app's
/// state, for TransferHost.
@MainActor final class SystemLifecycleInputs {
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []

    /// How things stand now; the network is a placeholder until the monitor's first reading.
    static func current() -> EnvironmentSnapshot {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return EnvironmentSnapshot(appActive: UIApplication.shared.applicationState == .active, network: .none,
                                   charging: [.charging, .full].contains(UIDevice.current.batteryState),
                                   thermal: ProcessInfo.processInfo.thermalState, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    nonisolated static func network(_ path: NWPath) -> EnvironmentSnapshot.Network {
        guard path.status == .satisfied else { return .none }
        if path.isConstrained { return .constrained }
        if path.isExpensive { return .expensive }
        return .unmetered
    }

    func start(feeding source: LifecycleEventSource) {
        guard observers.isEmpty else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        monitor.pathUpdateHandler = { [weak source] path in
            let network = Self.network(path)
            MainActor.assumeIsolated { source?.networkChanged(network) }
        }
        // The main queue keeps readings in order; each is a comparison and a yield.
        monitor.start(queue: .main)
        let center = NotificationCenter.default
        let watch: [(Notification.Name, @MainActor @Sendable (LifecycleEventSource) -> Void)] = [
            (UIDevice.batteryStateDidChangeNotification, { $0.chargingChanged([.charging, .full].contains(UIDevice.current.batteryState)) }),
            (ProcessInfo.thermalStateDidChangeNotification, { $0.thermalChanged(ProcessInfo.processInfo.thermalState) }),
            (Notification.Name.NSProcessInfoPowerStateDidChange, { $0.lowPowerChanged(ProcessInfo.processInfo.isLowPowerModeEnabled) }),
            (UIApplication.didBecomeActiveNotification, { $0.applicationBecameActive() }),
            (UIApplication.didEnterBackgroundNotification, { $0.applicationEnteredBackground() }),
        ]
        for (name, read) in watch {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak source] _ in
                MainActor.assumeIsolated { if let source { read(source) } }
            })
        }
    }

    func stop() {
        monitor.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}

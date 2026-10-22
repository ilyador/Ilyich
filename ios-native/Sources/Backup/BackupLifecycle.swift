import BackgroundTasks
import UIKit
import Network

/// Today's backup's background time, the way back when an account's backup records couldn't be
/// imported (TransferHost; REBUILD_ROADMAP.md B9, retired in B10). iOS chooses background
/// execution times. A processing window discovers and prepares a file, then hands its transfer to
/// the system URLSession daemon. While automatic backup is on, each burst of changes the Photos
/// adapter reports starts it again.
@MainActor final class BackupLifecycle {
    static let shared = BackupLifecycle()
    static let identifier = "app.ilyich.native.backup.processing"
    static let refreshIdentifier = "app.ilyich.native.backup.refresh"
    private var registered = false
    private var libraryChanges: Task<Void, Never>?
    private var hasActiveTask = false
    private var backgroundPreparation: (@MainActor () async -> Bool)?
    private var delayedStart: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let network = NWPathMonitor()

    /// Takes both identifiers' tasks from the router, which registered them with iOS at launch:
    /// today's backup runs the process's background windows (TransferHost chose it).
    func register(using router: BackgroundTaskRouter) {
        guard !registered else { return }
        let processingRegistered = router.register(identifier: Self.identifier) { handle in
            guard let task = handle as? BGTask, task is BGProcessingTask else { handle.setTaskCompleted(success: false); return }
            self.process(task)
        }
        let refreshRegistered = router.register(identifier: Self.refreshIdentifier) { handle in
            guard let task = handle as? BGTask, task is BGAppRefreshTask else { handle.setTaskCompleted(success: false); return }
            self.process(task)
        }
        registered = processingRegistered && refreshRegistered
        UIDevice.current.isBatteryMonitoringEnabled = true
        network.pathUpdateHandler = { _ in Task { @MainActor in self.foregroundChanged() } }
        network.start(queue: DispatchQueue(label: "app.ilyich.backup-network"))
        for name in [UIDevice.batteryStateDidChangeNotification, ProcessInfo.thermalStateDidChangeNotification,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.foregroundChanged() }
            })
        }
    }

    func setBackgroundPreparation(_ prepare: @escaping @MainActor () async -> Bool) {
        backgroundPreparation = prepare
    }

    func configure() {
        guard registered else { return }
        delayedStart?.cancel(); delayedStart = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
        let preferences = BackupCoordinator.shared.preferences
        if !preferences.automatic {
            libraryChanges?.cancel(); libraryChanges = nil
            return
        }
        if libraryChanges == nil {
            let changes = PhotoKitAdapter.shared.changes()
            libraryChanges = Task { [weak self] in
                for await _ in changes { self?.foregroundChanged(); self?.schedule() }
            }
        }
        schedule()
        if UIApplication.shared.applicationState == .active { foregroundChanged() }
    }

    func foregroundChanged() {
        guard BackupCoordinator.shared.preferences.automatic else { return }
        delayedStart?.cancel()
        let delay = max(0, BackupCoordinator.shared.preferences.triggerDelay)
        delayedStart = Task {
            do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation() }
            catch { return }
            await BackupCoordinator.shared.startAutomatically()
        }
    }

    func conditionsPermitBackup(requireCharging: Bool) -> Bool {
        guard ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else { return false }
        return !requireCharging || [.charging, .full].contains(UIDevice.current.batteryState)
    }

    private func schedule() {
        let preferences = BackupCoordinator.shared.preferences
        guard preferences.automatic, registered else { return }
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.requiresExternalPower = preferences.requireCharging
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(max(30, preferences.triggerDelay)))
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { BackupCoordinator.shared.reportSchedulingError(error) }
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
        do { try BGTaskScheduler.shared.submit(refresh) }
        catch { BackupCoordinator.shared.reportSchedulingError(error) }
    }

    private func process(_ task: BGTask) {
        schedule()
        guard !hasActiveTask, !BackupCoordinator.shared.isRunning else { task.setTaskCompleted(success: true); return }
        hasActiveTask = true
        let window = ProcessingWindow(task) { [weak self] in self?.hasActiveTask = false }
        task.expirationHandler = { Task { @MainActor in await window.expire() } }
        window.work = Task {
            // A daemon-owned transfer must continue even if metadata sync fails.
            if !(await BackgroundUploads.shared.hasActiveTransfer()) {
                guard let backgroundPreparation, await backgroundPreparation() else {
                    window.finish(success: false)
                    return
                }
            }
            guard !Task.isCancelled else { window.finish(success: false); return }
            await BackupCoordinator.shared.startAutomatically()
            do {
                while BackupCoordinator.shared.isRunning {
                    try Task.checkCancellation()
                    if await BackgroundUploads.shared.hasActiveTransfer() { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                window.finish(success: BackupCoordinator.shared.error == nil)
            } catch { window.finish(success: false) }
        }
    }
}

@MainActor private final class ProcessingWindow {
    let task: BGTask
    var work: Task<Void, Never>?
    private let onFinish: () -> Void
    private var finished = false
    init(_ task: BGTask, onFinish: @escaping () -> Void) { self.task = task; self.onFinish = onFinish }
    func finish(success: Bool) {
        guard !finished else { return }
        finished = true; task.expirationHandler = nil
        task.setTaskCompleted(success: success)
        work = nil
        onFinish()
    }
    func expire() async {
        work?.cancel()
        if !(await BackgroundUploads.shared.hasActiveTransfer()) {
            await BackupCoordinator.shared.pause(disableAutomatic: false)
        }
        finish(success: false)
    }
}

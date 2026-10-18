import BackgroundTasks
import Photos
import UIKit
import Network

/// iOS chooses background execution times. A processing window discovers and
/// prepares a file, then hands its transfer to the system URLSession daemon.
@MainActor final class BackupLifecycle: NSObject, @preconcurrency PHPhotoLibraryChangeObserver {
    static let shared = BackupLifecycle()
    static let identifier = "app.ilyich.native.backup.processing"
    static let refreshIdentifier = "app.ilyich.native.backup.refresh"
    private var registered = false
    private var observing = false
    private var hasActiveTask = false
    private var delayedStart: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let network = NWPathMonitor()

    func register() {
        guard !registered else { return }
        let processingRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard task is BGProcessingTask else { task.setTaskCompleted(success: false); return }
                self.process(task)
            }
        }
        let refreshRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard task is BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
                self.process(task)
            }
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

    func configure() {
        guard registered else { return }
        delayedStart?.cancel(); delayedStart = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
        let preferences = BackupCoordinator.shared.preferences
        if !preferences.automatic {
            if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self); observing = false }
            return
        }
        if !observing, [.authorized, .limited].contains(DevicePhotos.authorization) {
            PHPhotoLibrary.shared().register(self); observing = true
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

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.foregroundChanged(); self.schedule() }
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

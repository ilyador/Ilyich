import BackgroundTasks
import Photos
import UIKit

/// iOS chooses background execution times. A processing window discovers and
/// prepares a file, then hands its transfer to the system URLSession daemon.
@MainActor final class BackupLifecycle: NSObject, @preconcurrency PHPhotoLibraryChangeObserver {
    static let shared = BackupLifecycle()
    static let identifier = "app.ilyich.native.backup.processing"
    private var registered = false
    private var observing = false
    private var delayedStart: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
                self.process(processing)
            }
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
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
    }

    private func process(_ task: BGProcessingTask) {
        let window = ProcessingWindow(task)
        task.expirationHandler = { Task { @MainActor in await window.expire() } }
        window.work = Task {
            await BackupCoordinator.shared.startAutomatically()
            schedule()
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
    let task: BGProcessingTask
    var work: Task<Void, Never>?
    private var finished = false
    init(_ task: BGProcessingTask) { self.task = task }
    func finish(success: Bool) {
        guard !finished else { return }
        finished = true; task.expirationHandler = nil
        task.setTaskCompleted(success: success)
        work = nil
    }
    func expire() async {
        work?.cancel()
        if !(await BackgroundUploads.shared.hasActiveTransfer()) {
            await BackupCoordinator.shared.pause(disableAutomatic: false)
        }
        finish(success: false)
    }
}

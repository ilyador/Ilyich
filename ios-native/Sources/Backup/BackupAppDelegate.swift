import UIKit

@MainActor final class BackupAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            BackupLifecycle.shared.register()
            Task { await BackupCoordinator.shared.activate() }
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        BackupLifecycle.shared.foregroundChanged()
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploads.identifier else { completionHandler(); return }
        let completion = MainActorCompletion(completionHandler)
        BackgroundUploads.shared.handleEvents { Task { @MainActor in completion.call() } }
        Task { await BackupCoordinator.shared.activate() }
    }
}

@MainActor private final class MainActorCompletion: Sendable {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func call() { completion() }
}

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
        let uploads: BackgroundUploads
        switch identifier {
        case BackgroundUploads.identifier: uploads = .shared
        case BackgroundUploads.shareIdentifier: uploads = .sharing
        default: completionHandler(); return
        }
        let completion = MainActorCompletion(completionHandler)
        uploads.handleEvents { Task { @MainActor in completion.call() } }
        if identifier == BackgroundUploads.identifier { Task { await BackupCoordinator.shared.activate() } }
    }
}

@MainActor private final class MainActorCompletion: Sendable {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func call() { completion() }
}

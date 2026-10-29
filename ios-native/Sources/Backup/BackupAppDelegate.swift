import UIKit

@MainActor final class BackupAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The app's one door to Photos, whatever launched the app: it starts the one change
        // observer and reconciles any change to Photos an earlier run left unfinished.
        let photos = PhotoKitAdapter.shared
        Task { await photos.start() }
        // Share folders a killed app left behind; no share can be open this early.
        Task.detached(priority: .utility) { DeviceShareExporter.sweep() }
        // The backup screens' store follows backup from launch, so it is current when one opens.
        _ = BackupStore.shared
        // The background task identifiers are registered now, as iOS requires, and their tasks
        // wait for the account's backup engine. UI tests run without the phone's photos and backup.
        TransferHost.shared.launch(usesDevicePhotos: AccountEnvironment.current.usesDevicePhotos)
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Photos access may have changed in Settings meanwhile.
        let photos = PhotoKitAdapter.shared
        Task { await photos.refreshAccess() }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
    /// The session's completion goes to the transfer engine, which answers it once what the session
    /// delivered is committed, or at iOS's deadline.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        let completion = SystemCompletion(completionHandler)
        TransferHost.shared.handleEvents(identifier: identifier) { completion.call() }
    }
}

/// The app stays upright. While a photo or video viewer is on screen it turns with the phone, and
/// it turns back upright once the last viewer closes.
@MainActor enum OrientationLock {
    private static var viewers = 0
    static var mask: UIInterfaceOrientationMask { viewers > 0 ? .allButUpsideDown : .portrait }

    static func viewerAppeared() { viewers += 1; update() }
    static func viewerDisappeared() { viewers = max(0, viewers - 1); update() }

    private static func update() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            if viewers == 0 { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        }
    }
}

/// iOS's completion handler for a session's events, which it may be called with on any thread.
private final class SystemCompletion: @unchecked Sendable {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func call() { completion() }
}

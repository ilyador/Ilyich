import UIKit

@MainActor final class BackupAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The app's one door to Photos, whatever launched the app: it starts the one change
        // observer and reconciles any change to Photos an earlier run left unfinished.
        let photos = PhotoKitAdapter.shared
        Task { await photos.start() }
        // UI tests run without the phone's photos and backup.
        if AccountEnvironment.current.usesDevicePhotos {
            BackupLifecycle.shared.register()
            Task { await BackupCoordinator.shared.activate() }
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Photos access may have changed in Settings meanwhile.
        let photos = PhotoKitAdapter.shared
        Task { await photos.refreshAccess() }
        BackupLifecycle.shared.foregroundChanged()
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
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

@MainActor private final class MainActorCompletion: Sendable {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func call() { completion() }
}

import Foundation
import IlyichPlatform
import UIKit
import WidgetKit

/// The device-wide services as they run in the app.
struct LiveAccountDevice: AccountDevice {
    /// The backup sign-out stops: the app's own, or in a test one over a folder of the test's.
    var backup: @MainActor @Sendable () -> BackupCoordinator = { BackupCoordinator.shared }

    /// Pauses backup, switching automatic backup off unless `keepingAutomaticBackup`, and stops
    /// shared uploads.
    func stopUploads(keepingAutomaticBackup: Bool) async {
        let coordinator = await backup()
        await coordinator.disconnect(keepingAutomaticBackup: keepingAutomaticBackup)
    }

    func endCasting() async { await CastController.shared.signOut() }

    func reloadWidgets() async { await MainActor.run { WidgetCenter.shared.reloadAllTimelines() } }

    func clearNotifications() async { await TransferNotifications.clearAll() }

    func removeLockedPIN(scope: String) async { LockedPINStore.remove(cacheScope: scope) }

    func removeNetworkSettings(server: URL) async throws { try NetworkConfigurationStore.remove(server: server) }

    func clearTimelineCaches(scope: String) async {
        await TimelineCache.shared.removeAll(scope: scope)
        await TimelinePlacesCache.shared.removeAll(scope: scope)
    }

    func clearDiagnostics() async { await DiagnosticsStore.shared.clear() }

    func readOnlyChanged(_ enabled: Bool) async { await AccountRuntime.uploadsFollow(readOnly: enabled) }

    func recordTransferImport(_ report: LegacyImportReport) async { await DiagnosticsStore.shared.recordTransferImport(report) }

    /// Each time the phone's protected data becomes available after it was locked away, as after
    /// the first unlock since the phone started.
    @MainActor static func protectedDataAvailable() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observer = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                                              object: nil, queue: nil) { _ in continuation.yield() }
        let registration = ObserverRegistration(observer)
        continuation.onTermination = { _ in registration.remove() }
        return stream
    }
}

/// A notification observer to remove when its stream ends. Removing an observer is thread-safe.
private final class ObserverRegistration: @unchecked Sendable {
    private let observer: any NSObjectProtocol

    init(_ observer: any NSObjectProtocol) { self.observer = observer }

    func remove() { NotificationCenter.default.removeObserver(observer) }
}

extension AccountDependencies {
    /// What the app works with, in `environment`.
    static func live(_ environment: AccountEnvironment) -> AccountDependencies {
        AccountDependencies(credentials: environment.credentialStore(),
                            mirror: environment.usesDeviceStorage ? AuthorizationMirror.current() : nil,
                            device: LiveAccountDevice(), clients: .live(environment),
                            unlockEvents: { await LiveAccountDevice.protectedDataAvailable() })
    }
}

extension AccountClients {
    /// Clients over the server's saved network settings, or the environment's.
    static func live(_ environment: AccountEnvironment) -> AccountClients {
        let network = environment.networkConfiguration
        return AccountClients { server, credential, purpose in
            switch purpose {
            case .session(let authorization):
                return try APIClient(baseURL: server, accessToken: credential?.token, userID: credential?.userID,
                                     networkConfiguration: network, authorization: authorization)
            case .check:
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 4
                configuration.timeoutIntervalForResource = 6
                return try APIClient(baseURL: server, accessToken: credential?.token, userID: credential?.userID,
                                     sessionConfiguration: configuration, networkConfiguration: network)
            case .signIn:
                return try APIClient(baseURL: server, networkConfiguration: network)
            }
        }
    }
}

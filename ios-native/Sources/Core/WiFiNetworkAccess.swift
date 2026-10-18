import CoreLocation
import Foundation
import NetworkExtension

enum WiFiNetworkAccessError: LocalizedError {
    case permissionRequired

    var errorDescription: String? {
        "Allow location access for Ilyich to read the current Wi-Fi name, or enter it manually."
    }
}

/// Reads only the connected Wi-Fi name. Location permission is requested only from the
/// network settings screen; background callers simply receive nil when access is unavailable.
@MainActor final class WiFiNetworkAccess: NSObject, @MainActor CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func requestCurrentName() async throws -> String? {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .notDetermined:
            try await withCheckedThrowingContinuation { continuation in
                authorizationContinuation = continuation
                locationManager.requestWhenInUseAuthorization()
            }
        default:
            throw WiFiNetworkAccessError.permissionRequired
        }
        if locationManager.accuracyAuthorization != .fullAccuracy {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "WiFiNetworkName") { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
        guard locationManager.accuracyAuthorization == .fullAccuracy else {
            throw WiFiNetworkAccessError.permissionRequired
        }
        return await Self.currentNameIfAvailable()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let continuation = authorizationContinuation else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationContinuation = nil
            continuation.resume()
        case .denied, .restricted:
            authorizationContinuation = nil
            continuation.resume(throwing: WiFiNetworkAccessError.permissionRequired)
        case .notDetermined: break
        @unknown default:
            authorizationContinuation = nil
            continuation.resume(throwing: WiFiNetworkAccessError.permissionRequired)
        }
    }

    static func currentNameIfAvailable() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }
}

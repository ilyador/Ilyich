import Foundation
import NetworkExtension

/// Supplies the connected Wi-Fi network's name, so a home address can be tried first.
public protocol WiFiNameProviding: Sendable {
    /// The network's name, or nil when there is none or reading it is not allowed.
    func currentName() async -> String?
}

/// Reads the connected network's name from the system. Location permission is requested only
/// from the app's network settings; until it is granted this returns nil.
public struct SystemWiFiName: WiFiNameProviding {
    public init() {}

    public func currentName() async -> String? { await Self.fetchCurrent() }

    @MainActor private static func fetchCurrent() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { @Sendable network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }
}

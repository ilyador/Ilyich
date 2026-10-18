import CryptoKit
import Foundation

/// Local viewing mode; it does not change account permissions on the server.
enum ReadOnlyPolicy {
    private static var defaults: UserDefaults {
        if let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String, group.hasPrefix("group."), !group.contains("$("),
           let shared = UserDefaults(suiteName: group) { return shared }
        return .standard
    }
    private static func key(server: URL, userID: String) -> String {
        let canonical = (try? ServerAddress.normalized(server)) ?? server
        return "readOnly." + SHA256.hash(data: Data((canonical.absoluteString + "|" + userID).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func isEnabled(server: URL, userID: String) -> Bool { defaults.bool(forKey: key(server: server, userID: userID)) }
    static func setEnabled(_ enabled: Bool, server: URL, userID: String) { defaults.set(enabled, forKey: key(server: server, userID: userID)) }
    static func permits(method: String, path: String) -> Bool {
        let path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch method.uppercased() {
        case "GET", "HEAD": return true
        case "POST":
            return ["search/smart", "search/metadata", "search/random", "search/explore", "auth/login", "auth/logout", "auth/validateToken", "auth/session/unlock", "auth/session/lock", "sessions"].contains(path)
        case "DELETE": return path.hasPrefix("sessions/") && path.split(separator: "/").count == 2
        default: return false
        }
    }
    static func check(enabled: Bool, method: String, path: String) throws {
        if enabled && !permits(method: method, path: path) { throw ReadOnlyError() }
    }
    struct ReadOnlyError: LocalizedError {
        var errorDescription: String? { "Read-only mode is on. Turn it off in Settings before making changes or uploading." }
    }
}

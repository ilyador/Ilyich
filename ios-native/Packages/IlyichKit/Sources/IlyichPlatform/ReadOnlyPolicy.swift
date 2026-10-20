import Foundation

/// Local viewing mode; it does not change account permissions on the server.
public enum ReadOnlyPolicy {
    private static var defaults: UserDefaults { AppGroup.defaults ?? .standard }
    private static func key(server: URL, userID: String) -> String {
        let canonical = (try? ServerAddress.normalized(server)) ?? server
        return AccountStoragePaths(AccountID(server: canonical, userID: userID)).readOnlyKey
    }
    public static func isEnabled(server: URL, userID: String) -> Bool { defaults.bool(forKey: key(server: server, userID: userID)) }
    public static func setEnabled(_ enabled: Bool, server: URL, userID: String) { defaults.set(enabled, forKey: key(server: server, userID: userID)) }
    public static func permits(method: String, path: String) -> Bool {
        let path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch method.uppercased() {
        case "GET", "HEAD": return true
        case "POST":
            return ["search/smart", "search/metadata", "search/random", "search/explore", "auth/login", "auth/logout", "auth/validateToken", "auth/session/unlock", "auth/session/lock", "sessions", "sync/stream", "sync/ack"].contains(path)
        case "DELETE": return path.hasPrefix("sessions/") && path.split(separator: "/").count == 2
        default: return false
        }
    }
    public static func check(enabled: Bool, method: String, path: String) throws {
        if enabled && !permits(method: method, path: path) { throw ReadOnlyError() }
    }
    public struct ReadOnlyError: LocalizedError {
        public init() {}
        public var errorDescription: String? { "Read-only mode is on. Turn it off in Settings before making changes or uploading." }
    }
}

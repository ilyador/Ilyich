import Foundation
import Security
import CryptoKit

struct SavedSession: Codable, Sendable {
    let server: URL
    let token: String
    let userID: String
    let name: String
    var requiresPasswordChange: Bool? = nil

    var scope: String { SHA256.hash(data: Data((server.absoluteString + "|" + userID).utf8)).map { String(format: "%02x", $0) }.joined() }
}

enum SessionKeychain {
    private static let service = "app.ilyich.native.session"
    static var appGroup: String {
        get throws {
            guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String,
                  group.hasPrefix("group."), !group.contains("$(") else {
                throw KeychainError(status: errSecMissingEntitlement)
            }
            return group
        }
    }
    private static func query() throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "current",
         kSecAttrAccessGroup as String: try appGroup]
    }
    static func read() throws -> SavedSession? {
        guard UserDefaults(suiteName: try appGroup)?.bool(forKey: "session.signedOut") != true else { return nil }
        var query = try query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(SavedSession.self, from: data)
    }
    static func save(_ session: SavedSession) throws {
        let query = try query()
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(session),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        UserDefaults(suiteName: try appGroup)?.set(false, forKey: "session.signedOut")
    }
    static func remove() throws {
        // A failed Keychain deletion must not restore a session in the app or an
        // extension. A later successful explicit sign-in clears this tombstone.
        UserDefaults(suiteName: try appGroup)?.set(true, forKey: "session.signedOut")
        let status = SecItemDelete(try query() as CFDictionary)
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: try appGroup) {
            try? FileManager.default.removeItem(at: container.appendingPathComponent("WidgetCache"))
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Ilyich couldn’t access its saved sign-in. Unlock your phone and try again." }
    }
}

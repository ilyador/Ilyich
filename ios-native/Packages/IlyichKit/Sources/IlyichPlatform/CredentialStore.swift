import Foundation
import Security

/// The signed-in session as the Keychain holds it. Its JSON is the SavedSession v1 format
/// every earlier build wrote, so the fields keep their names, types and order.
public struct StoredCredential: Codable, Equatable, Sendable {
    public let server: URL
    public let token: String
    public let userID: String
    public let name: String
    public var requiresPasswordChange: Bool? = nil

    public init(server: URL, token: String, userID: String, name: String, requiresPasswordChange: Bool? = nil) {
        self.server = server
        self.token = token
        self.userID = userID
        self.name = name
        self.requiresPasswordChange = requiresPasswordChange
    }

    public var account: AccountID { AccountID(server: server, userID: userID) }

    /// The account digest, which names the account's Backup folder.
    public var scope: String { account.digest }
}

/// Where the signed-in session is kept for the app, its extensions and upload delegates.
public protocol CredentialStore: Sendable {
    /// The saved session, or nil when there is none or the user signed out.
    func load() throws(CredentialError) -> StoredCredential?
    func save(_ credential: StoredCredential) throws(CredentialError)
    /// Signs out. Readers stop seeing the session even when the Keychain item cannot be deleted.
    func remove() throws(CredentialError)
}

public enum CredentialError: LocalizedError {
    /// The phone has not been unlocked since it started, so the Keychain is closed.
    case locked
    /// The App Group, which is also the Keychain access group, is missing from the signing.
    case missingEntitlement
    case keychain(OSStatus)
    /// The saved session could not be decoded or encoded.
    case corrupt(any Error)

    init(status: OSStatus) {
        switch status {
        case errSecInteractionNotAllowed: self = .locked
        case errSecMissingEntitlement: self = .missingEntitlement
        default: self = .keychain(status)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .corrupt(let error): error.localizedDescription
        case .locked, .missingEntitlement, .keychain: "Ilyich couldn’t access its saved sign-in. Unlock your phone and try again."
        }
    }
}

/// The session in the Keychain, shared with the extensions through the App Group. The
/// service, account, access group, accessibility and signed-out flag are those of every
/// earlier build, so an update keeps the owner signed in.
public struct KeychainCredentialStore: CredentialStore {
    static let service = "app.ilyich.native.session"
    static let account = "current"
    /// Set in the App Group's preferences before the item is deleted and cleared only by a
    /// successful save, so a failed deletion still signs out.
    static let signedOutKey = "session.signedOut"

    private let keychain: any KeychainItems
    private let group: String?

    /// The store in this bundle's App Group.
    public init() {
        keychain = SystemKeychain()
        group = nil
    }

    /// A store over other Keychain calls and App Group, for tests.
    public init(keychain: any KeychainItems, appGroup: String) {
        self.keychain = keychain
        group = appGroup
    }

    public func load() throws(CredentialError) -> StoredCredential? {
        let group = try appGroup()
        guard UserDefaults(suiteName: group)?.bool(forKey: Self.signedOutKey) != true else { return nil }
        var query = Self.query(group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else { throw CredentialError(status: status) }
        do { return try JSONDecoder().decode(StoredCredential.self, from: data) }
        catch { throw .corrupt(error) }
    }

    public func save(_ credential: StoredCredential) throws(CredentialError) {
        let group = try appGroup()
        let query = Self.query(group: group)
        let data: Data
        do { data = try JSONEncoder().encode(credential) }
        catch { throw .corrupt(error) }
        let values: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = keychain.update(query, with: values)
        if status == errSecItemNotFound {
            status = keychain.add(query.merging(values) { _, new in new })
        }
        guard status == errSecSuccess else { throw CredentialError(status: status) }
        UserDefaults(suiteName: group)?.set(false, forKey: Self.signedOutKey)
    }

    public func remove() throws(CredentialError) {
        let group = try appGroup()
        UserDefaults(suiteName: group)?.set(true, forKey: Self.signedOutKey)
        let status = keychain.delete(Self.query(group: group))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError(status: status) }
    }

    private func appGroup() throws(CredentialError) -> String {
        if let group { return group }
        do { return try AppGroup.identifier }
        catch { throw .missingEntitlement }
    }

    private static func query(group: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: group]
    }
}

/// The Keychain calls a store makes, so a test can stand in for the Keychain of a locked phone.
public protocol KeychainItems: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// The device Keychain.
public struct SystemKeychain: KeychainItems {
    public init() {}

    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }

    public func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

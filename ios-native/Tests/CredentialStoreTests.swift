import Foundation
import IlyichPlatform
import Security
import XCTest

final class CredentialStoreTests: XCTestCase {
    /// Stands in for the App Group: the tombstone lives in this suite's preferences.
    private let group = "CredentialStoreTests"
    /// What every earlier build wrote: SavedSession v1, with JSONEncoder's escaped slashes. The
    /// encoder orders keys differently from one process to the next, then and now.
    private let v1 = #"{"server":"https:\/\/photos.example\/api","token":"opaque.token","userID":"user-1","name":"Owner"}"#
    private let credential = StoredCredential(server: URL(string: "https://photos.example/api")!, token: "opaque.token", userID: "user-1", name: "Owner")

    override func setUp() { UserDefaults(suiteName: group)?.removePersistentDomain(forName: group) }
    override func tearDown() { UserDefaults(suiteName: group)?.removePersistentDomain(forName: group) }

    /// A flat JSON object's members exactly as written, whatever their order.
    private func members(_ json: String) -> Set<String> {
        guard json.hasPrefix("{"), json.hasSuffix("}") else { return [] }
        return Set(json.dropFirst().dropLast().split(separator: ",").map(String.init))
    }
    private func members(_ json: Data?) -> Set<String> { members(json.map { String(decoding: $0, as: UTF8.self) } ?? "") }

    /// The item exactly as earlier builds stored it.
    private func legacyItem(_ json: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.ilyich.native.session",
         kSecAttrAccount as String: "current", kSecAttrAccessGroup as String: group,
         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, kSecValueData as String: Data(json.utf8)]
    }

    func testV1SessionRoundTripsByteForByteInTheSameKeychainItem() throws {
        let keychain = FakeKeychain()
        keychain.seed(legacyItem(v1))
        let store = KeychainCredentialStore(keychain: keychain, appGroup: group)
        let loaded = try XCTUnwrap(store.load(), "An earlier build's session restores without signing in again.")
        XCTAssertEqual(loaded, credential)
        XCTAssertNil(loaded.requiresPasswordChange)
        XCTAssertEqual(loaded.scope, "994af023182cedb273a8fe02b007e4d7467dbb289ef99d1a028778be4e54dc49")
        try store.save(loaded)
        XCTAssertEqual(try XCTUnwrap(keychain.stored).count, v1.utf8.count)
        XCTAssertEqual(members(keychain.stored), members(v1), "The JSON is written byte for byte as before, in some key order.")

        let flagged = #"{"server":"https:\/\/photos.example\/api","token":"opaque.token","userID":"user-1","name":"Owner","requiresPasswordChange":true}"#
        keychain.seed(legacyItem(flagged))
        XCTAssertEqual(try store.load()?.requiresPasswordChange, true)
        try store.save(try XCTUnwrap(store.load()))
        XCTAssertEqual(try XCTUnwrap(keychain.stored).count, flagged.utf8.count)
        XCTAssertEqual(members(keychain.stored), members(flagged))

        let fresh = FakeKeychain()
        try KeychainCredentialStore(keychain: fresh, appGroup: group).save(credential)
        let added = try XCTUnwrap(fresh.item)
        XCTAssertEqual(added[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(added[kSecAttrService as String] as? String, "app.ilyich.native.session")
        XCTAssertEqual(added[kSecAttrAccount as String] as? String, "current")
        XCTAssertEqual(added[kSecAttrAccessGroup as String] as? String, group)
        XCTAssertEqual(added[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(members(fresh.stored), members(v1))
    }

    func testSignOutTombstoneHidesTheSessionWhenTheItemCannotBeDeleted() throws {
        let keychain = FakeKeychain()
        keychain.seed(legacyItem(v1))
        let store = KeychainCredentialStore(keychain: keychain, appGroup: group)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: group))
        keychain.failing[.delete] = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.remove())
        XCTAssertEqual(defaults.object(forKey: "session.signedOut") as? Bool, true, "The flag is set before the deletion is tried.")
        XCTAssertNotNil(keychain.stored)
        XCTAssertNil(try store.load(), "A failed deletion must not restore the session in the app or an extension.")

        keychain.failing = [:]
        try store.save(credential)
        XCTAssertEqual(defaults.object(forKey: "session.signedOut") as? Bool, false, "Signing in again clears the flag.")
        XCTAssertEqual(try store.load(), credential)
        try store.remove()
        XCTAssertNil(keychain.stored)
        XCTAssertNil(try store.load())
    }

    func testLockedKeychainIsAnErrorWhileAMissingItemIsNoSession() throws {
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(keychain: keychain, appGroup: group)
        XCTAssertNil(try store.load(), "No item means signed out.")
        keychain.seed(legacyItem(v1))
        keychain.failing[.copy] = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.load()) { error in
            guard case CredentialError.locked = error else { return XCTFail("A locked phone must not look signed out: \(error)") }
            XCTAssertEqual(error.localizedDescription, "Ilyich couldn’t access its saved sign-in. Unlock your phone and try again.")
        }
        keychain.failing[.copy] = errSecMissingEntitlement
        XCTAssertThrowsError(try store.load()) { error in
            guard case CredentialError.missingEntitlement = error else { return XCTFail("Unexpected error: \(error)") }
        }
        keychain.failing = [:]
        XCTAssertEqual(try store.load(), credential)
    }
}

/// A Keychain holding at most one item, which can be told to fail like a locked phone's.
private final class FakeKeychain: KeychainItems, @unchecked Sendable {
    enum Call { case copy, add, update, delete }
    private let lock = NSLock()
    private var current: [String: Any]?
    private var failures: [Call: OSStatus] = [:]
    private static let identity = [kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrAccessGroup].map { $0 as String }

    var item: [String: Any]? { lock.withLock { current } }
    var stored: Data? { item?[kSecValueData as String] as? Data }
    var failing: [Call: OSStatus] {
        get { lock.withLock { failures } }
        set { lock.withLock { failures = newValue } }
    }

    func seed(_ attributes: [String: Any]) { lock.withLock { current = attributes } }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.withLock {
            if let status = failures[.copy] { return (status, nil) }
            guard matches(query) else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, current?[kSecValueData as String] as? Data)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            if let status = failures[.add] { return status }
            guard !matches(attributes) else { return errSecDuplicateItem }
            current = attributes
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            if let status = failures[.update] { return status }
            guard matches(query) else { return errSecItemNotFound }
            current?.merge(attributes) { _, new in new }
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            if let status = failures[.delete] { return status }
            guard matches(query) else { return errSecItemNotFound }
            current = nil
            return errSecSuccess
        }
    }

    /// The item answers only a query naming its class, service, account and access group.
    private func matches(_ query: [String: Any]) -> Bool {
        guard let current else { return false }
        return Self.identity.allSatisfy { key in
            guard let wanted = query[key] as? String else { return false }
            return current[key] as? String == wanted
        }
    }
}

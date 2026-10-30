import Foundation
import IlyichPlatform
import Synchronization

/// How the account layer runs in this process. The app runs `live`. A DEBUG build the UI tests
/// launch runs `uiTest`, against the loopback fixture: launch arguments are read here, once, and
/// no service looks at the process itself.
struct AccountEnvironment: Sendable {
    /// Credentials are kept in the Keychain, the App Group mirror is written, and sign-out removes
    /// the server's saved network settings.
    var usesDeviceStorage = true
    /// The credential a UI test starts signed in with, instead of the Keychain's.
    var fixtureCredential: StoredCredential?
    /// The account whose UI-test state each launch starts from scratch.
    var fixtureAccount: AccountID?
    /// The network settings every client uses instead of the saved ones.
    var networkConfiguration: NetworkConfiguration?
    /// The offline library, its sync and the coverage worker run.
    var syncsLibrary = true
    /// The phone's photos join the library, and backup runs.
    var usesDevicePhotos = true
    /// The session is checked with the server when it opens and whenever the app comes forward.
    var validatesSession = true
    /// Each launch starts at the default grid density and shelf order.
    var resetsInterfaceState = false
    /// The shelves stay out after a stroke lifts, so a UI test can tap their rows.
    var keepsShelvesOpen = false
    /// Where the offline library is kept: nil for Application Support, a folder for tests.
    var libraryDirectory: URL?
    /// The account keeps a transfers database, which the transfer engine runs backup from
    /// (REBUILD_ROADMAP.md B9).
    var keepsTransfers = true
    /// Where the transfers databases are kept: nil for Application Support/IlyichTransfers, a
    /// folder for tests.
    var transfersDirectory: URL?
    /// URL protocols put in front of the media sessions (thumbnails, previews, originals): nil on
    /// the phone; a UI test can take the media offline with them.
    var mediaProtocolClasses: [AnyClass]?

    /// The app on the phone.
    static let live = AccountEnvironment()

    /// This process's environment.
    static let current: AccountEnvironment = {
        #if DEBUG
        if let test = uiTest(arguments: ProcessInfo.processInfo.arguments) { return test }
        #endif
        return .live
    }()

    #if DEBUG
    /// The fixture server the UI tests start on the loopback interface.
    static let fixtureServer = URL(string: "http://127.0.0.1:18091/api")!
    static let fixtureUserID = "00000000-0000-4000-8000-000000000001"

    /// The fixture server a launch uses: the shared one, or one of its own that
    /// `--ui-testing-fixture-port <port>` names, so a change to the fixture can be tried without
    /// restarting the server every test run shares.
    static func fixtureServer(in arguments: [String]) -> URL {
        guard let index = arguments.firstIndex(of: "--ui-testing-fixture-port"), arguments.indices.contains(index + 1),
              let port = Int(arguments[index + 1]), (1024...65535).contains(port) else { return fixtureServer }
        return URL(string: "http://127.0.0.1:\(port)/api")!
    }

    /// The environment a UI test launch asks for, or nil for any other launch. Nothing reaches the
    /// Keychain, the App Group mirror, the phone's photos, backup or its state. `--ui-testing-library` starts
    /// signed in to the fixture, with the long People shelf for `--ui-testing-many-people`, with
    /// people served a page at a time for `--ui-testing-paged-people`, and with a library of its own
    /// that remembers this launch's changes for `--ui-testing-mutable-library`, its Trash already
    /// holding photos in three months for `--ui-testing-trashed-library`.
    static func uiTest(arguments: [String]) -> AccountEnvironment? {
        guard arguments.contains("--ui-testing") else { return nil }
        var environment = AccountEnvironment()
        environment.usesDeviceStorage = false
        environment.networkConfiguration = NetworkConfiguration()
        environment.syncsLibrary = false
        environment.usesDevicePhotos = false
        environment.keepsTransfers = false
        environment.resetsInterfaceState = true
        environment.keepsShelvesOpen = arguments.contains("--ui-testing-shelves-stay-open")
        // The fixture server is shared by every test run, so a launch that wants its media
        // offline fails the requests in the app instead; the library itself still loads.
        if arguments.contains("--ui-testing-offline-media") { environment.mediaProtocolClasses = [OfflineMediaProtocol.self] }
        let server = fixtureServer(in: arguments)
        environment.fixtureAccount = AccountID(server: server, userID: fixtureUserID)
        if arguments.contains("--ui-testing-library") {
            // The fixture serves a long People shelf to this session's own token. A mutable
            // session's token is new each launch: the fixture keeps its changes for it alone, so
            // no other test, and no later launch, sees them.
            let token = arguments.contains("--ui-testing-many-people") ? "ui-test-many-people"
                : arguments.contains("--ui-testing-paged-people") ? "ui-test-paged-people"
                : arguments.contains("--ui-testing-trashed-library") ? "ui-test-mutable-trash-" + UUID().uuidString.lowercased()
                : arguments.contains("--ui-testing-mutable-library") ? "ui-test-mutable-" + UUID().uuidString.lowercased() : "ui-test-session"
            environment.fixtureCredential = StoredCredential(server: server, token: token, userID: fixtureUserID, name: "Test library")
        }
        return environment
    }
    #endif

    /// Where credentials are kept in this environment.
    func credentialStore() -> any CredentialStore {
        usesDeviceStorage ? KeychainCredentialStore() : EphemeralCredentialStore(fixtureCredential)
    }
}

#if DEBUG
/// Every media request fails as if the phone had no network, for a UI test that checks what the
/// grid shows from what it has stored (REBUILD_ROADMAP.md T3).
final class OfflineMediaProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
#endif

/// A credential kept only in memory, for UI tests and unit tests: nothing reaches the Keychain.
final class EphemeralCredentialStore: CredentialStore {
    private let state: Mutex<StoredCredential?>

    init(_ credential: StoredCredential? = nil) { state = Mutex(credential) }

    func load() throws(CredentialError) -> StoredCredential? { state.withLock { $0 } }
    func save(_ credential: StoredCredential) throws(CredentialError) { state.withLock { $0 = credential } }
    func remove() throws(CredentialError) { state.withLock { $0 = nil } }
}

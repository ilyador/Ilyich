import Foundation
import IlyichPlatform
import Synchronization

/// How the account layer runs in this process. The app runs `live`. A DEBUG build the UI tests
/// launch runs `uiTest`, against the loopback fixture: launch arguments are read here, once, and
/// no service looks at the process itself.
struct AccountEnvironment: Sendable {
    /// Credentials are kept in the Keychain, the App Group mirror is written, and sign-out removes
    /// the server's saved network settings and reloads the widgets.
    var usesDeviceStorage = true
    /// The credential a UI test starts signed in with, instead of the Keychain's.
    var fixtureCredential: StoredCredential?
    /// The account whose UI-test state each launch starts from scratch.
    var fixtureAccount: AccountID?
    /// The network settings every client uses instead of the saved ones.
    var networkConfiguration: NetworkConfiguration?
    /// The offline library, its sync and the thumbnail warmer run.
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
    /// The backup state is copied into the account's transfers database and compared with it, in
    /// shadow (REBUILD_ROADMAP.md B1). Backup itself still runs from the backup state.
    var importsBackupState = true
    /// Where the transfers databases are kept: nil for Application Support/IlyichTransfers, a
    /// folder for tests.
    var transfersDirectory: URL?
    /// The folder that holds each account's Backup/<digest>/state.json: nil for the App Group
    /// container, a folder for tests.
    var backupContainer: URL?

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

    /// The environment a UI test launch asks for, or nil for any other launch. Nothing reaches the
    /// Keychain, the App Group mirror, the phone's photos, backup or its state. `--ui-testing-library` starts
    /// signed in to the fixture, with the long People shelf for `--ui-testing-many-people`.
    static func uiTest(arguments: [String]) -> AccountEnvironment? {
        guard arguments.contains("--ui-testing") else { return nil }
        var environment = AccountEnvironment()
        environment.usesDeviceStorage = false
        environment.networkConfiguration = NetworkConfiguration()
        environment.syncsLibrary = false
        environment.usesDevicePhotos = false
        environment.importsBackupState = false
        environment.resetsInterfaceState = true
        environment.keepsShelvesOpen = arguments.contains("--ui-testing-shelves-stay-open")
        environment.fixtureAccount = AccountID(server: fixtureServer, userID: fixtureUserID)
        if arguments.contains("--ui-testing-library") {
            // The fixture serves a long People shelf to this session's own token.
            let token = arguments.contains("--ui-testing-many-people") ? "ui-test-many-people" : "ui-test-session"
            environment.fixtureCredential = StoredCredential(server: fixtureServer, token: token, userID: fixtureUserID, name: "Test library")
        }
        return environment
    }
    #endif

    /// Where credentials are kept in this environment.
    func credentialStore() -> any CredentialStore {
        usesDeviceStorage ? KeychainCredentialStore() : EphemeralCredentialStore(fixtureCredential)
    }
}

/// A credential kept only in memory, for UI tests and unit tests: nothing reaches the Keychain.
final class EphemeralCredentialStore: CredentialStore {
    private let state: Mutex<StoredCredential?>

    init(_ credential: StoredCredential? = nil) { state = Mutex(credential) }

    func load() throws(CredentialError) -> StoredCredential? { state.withLock { $0 } }
    func save(_ credential: StoredCredential) throws(CredentialError) { state.withLock { $0 = credential } }
    func remove() throws(CredentialError) { state.withLock { $0 = nil } }
}

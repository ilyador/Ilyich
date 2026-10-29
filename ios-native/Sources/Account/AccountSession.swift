import SwiftUI
import IlyichPlatform

/// What the screens show of the account, and the commands they send. Presentation only:
/// AccountManager owns the account and its runtime and publishes each change here.
@MainActor @Observable final class AccountSession {
    let environment: AccountEnvironment
    private(set) var phase: AccountPhase = .restoring
    /// The open account. Nil while nobody is signed in, and from the moment sign-out begins.
    private(set) var runtime: AccountRuntime?
    /// For the sign-in screen: why the last session ended, or why it couldn't be restored.
    private(set) var error: String?
    /// A link the app was opened with, waiting for the library to follow it. The library takes
    /// it as soon as it is up, and a link that arrives before sign-in waits for it.
    var pendingLink: AppLink?
    /// What the signed-in account may do, for views: the app puts it in the environment, where
    /// the controls that change things read it. Nil while nobody is signed in.
    private(set) var authorization: AuthorizationSnapshot?
    /// The open account's Free up space, which the app puts in the environment.
    private(set) var freeUpSpace: FreeUpSpaceStore?
    /// The open account's Locked Folder, which the app puts in the environment and which hears
    /// every scene change here first (REBUILD_ROADMAP.md N5).
    private(set) var lockedFolder: LockedFolderSession?
    @ObservationIgnored let manager: AccountManager
    @ObservationIgnored private let presence: AppPresence
    @ObservationIgnored private var following: Task<Void, Never>?

    init(environment: AccountEnvironment, dependencies: AccountDependencies, presence: AppPresence) {
        let relay = Relay()
        self.environment = environment
        self.presence = presence
        manager = AccountManager(environment: environment, dependencies: dependencies, presence: presence) { state in
            relay.session?.apply(state)
        }
        relay.session = self
    }

    /// The app's session, on the phone or in a UI test.
    convenience init(environment: AccountEnvironment) {
        self.init(environment: environment, dependencies: .live(environment),
                  presence: AppPresence(isForeground: UIApplication.shared.applicationState == .active))
    }

    /// Hands the manager's changes to the session it was made for.
    @MainActor private final class Relay {
        weak var session: AccountSession?
    }

    // MARK: What views read

    var isRestoring: Bool { phase == .restoring || phase == .waitingForUnlock }
    var isSigningOut: Bool { phase == .signingOut }
    var requiresPasswordChange: Bool { phase == .passwordChangeRequired }
    var api: APIClient? { runtime?.api }
    var pipeline: MediaPipeline? { runtime?.pipeline }
    /// The account's library reads, which the feeds plan and read through.
    var libraryRepository: LibraryRepository? { runtime?.library?.repository }
    var entities: LibraryIndex? { runtime?.library?.entities }
    /// Keeps the library's thumbnails on the phone while the app is open (REBUILD_ROADMAP.md T5).
    var coverage: CoverageWorker? { runtime?.library?.coverage }
    /// The phone's side of the merged library.
    var deviceIndex: DeviceIndexService? { runtime?.deviceIndex }
    /// The account's changes to its library on the server, which the app puts in the environment.
    var mutations: LibraryMutationService? { runtime?.mutations }
    /// The account's albums, people, partners and memories on the server, which the app puts in
    /// the environment.
    var collections: CollectionsService? { runtime?.collections }
    /// Everything that happens to the account's library, in one order, which the app puts in the
    /// environment.
    var bus: LibraryBus? { runtime?.bus }
    /// The account's own settings on the server, which the app puts in the environment.
    var settings: AccountSettingsService? { runtime?.settings }
    var isSyncing: Bool { runtime?.library?.status.status.isSyncing ?? false }
    var syncError: String? { runtime?.library?.status.status.error ?? runtime?.libraryError }
    var lastSyncDate: Date? { runtime?.library?.status.status.lastSyncDate }

    // MARK: Commands

    func restore() async { await manager.restore() }

    func signIn(server: String, email: String, password: String) async throws {
        try await manager.signIn(server: server, email: email, password: password)
    }

    func completeSSO(_ login: LoginResponse, server: URL) async throws {
        try await manager.completeSSO(login, server: server)
    }

    /// A client for signing in to `server`, made off the main actor. The caller shuts it down.
    func signInClient(for server: URL) async throws -> APIClient { try await manager.signInClient(for: server) }

    /// How `server` lets people sign in, or nil when it can't be asked.
    func serverFeatures(at server: URL) async -> ServerFeatures? { await manager.serverFeatures(at: server) }

    func signOut() async { await manager.signOut(.user) }

    func startSync() {
        guard let sync = runtime?.library?.sync else { return }
        Task { await sync.syncNow() }
    }

    func resetLibraryMetadata() async { await manager.resetLibraryMetadata() }

    func clearBrowsingCache() async { await manager.clearBrowsingCache() }

    /// Turns read-only mode on or off for the signed-in account. The setting and the write
    /// generation change at once, so the controls follow straight away and writes still waiting to
    /// be sent are refused. The transfer engine follows the account's authorization itself: turning
    /// it on pauses backup, with automatic backup off, and stops shared uploads.
    func setReadOnly(_ enabled: Bool) {
        guard let runtime, phase == .active || phase == .passwordChangeRequired,
              let snapshot = runtime.setReadOnly(enabled) else { return }
        authorization = snapshot
    }

    func sceneChanged(_ scene: ScenePhase) {
        // The Locked Folder relocks before anything else hears the app left the foreground, and
        // synchronously, whatever screen is up.
        lockedFolder?.sceneChanged(scene)
        if scene == .active {
            let cameForward = !presence.isForeground
            presence.isForeground = true
            if let runtime, phase == .active || phase == .passwordChangeRequired {
                runtime.check.validate()
                if let sync = runtime.library?.sync { Task { await sync.presenceChanged() } }
                // Only out of the background: Control Center and alerts only make the app inactive.
                if cameForward, let index = runtime.deviceIndex { Task { await index.presenceChanged() } }
                runtime.library?.coverage.conditions.setAppActive(true)
            }
            if phase == .waitingForUnlock { Task { await manager.retryRestoreIfWaiting() } }
        } else if scene == .background {
            presence.isForeground = false
            if let sync = runtime?.library?.sync { Task { await sync.presenceChanged() } }
            if let index = runtime?.deviceIndex { Task { await index.presenceChanged() } }
            runtime?.library?.coverage.conditions.setAppActive(false)
        }
    }

    func open(_ url: URL) {
        if let link = AppLink(url: url, server: api?.baseURL) { pendingLink = link }
    }

    // MARK: Changes from the manager

    private func apply(_ state: AccountState) {
        if state.runtime?.id != runtime?.id {
            following?.cancel(); following = nil
            runtime = state.runtime
            freeUpSpace?.disappear()
            freeUpSpace = state.runtime.map { FreeUpSpaceStore(service: $0.cleanup) }
            lockedFolder?.end()
            lockedFolder = state.runtime.map {
                LockedFolderSession(api: $0.api, pipeline: $0.pipeline, authorization: $0.authorization, mutations: $0.mutations)
            }
            authorization = state.runtime?.authorization.snapshot
            if let runtime = state.runtime { follow(runtime.authorization) }
        }
        if state.phase == .signingOut { pendingLink = nil }
        phase = state.phase
        error = state.message
    }

    /// Keeps the snapshot views read current, whatever moves it: an access change after a sync,
    /// a library reset. Each change reads the latest snapshot, so a late one never goes back.
    private func follow(_ authorization: AuthorizationState) {
        let updates = authorization.updates()
        following = Task { [weak self] in
            for await _ in updates {
                guard let self, !Task.isCancelled, self.runtime?.authorization === authorization else { return }
                self.authorization = authorization.hasEnded ? nil : authorization.snapshot
            }
        }
    }
}

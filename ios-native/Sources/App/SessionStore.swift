import SwiftUI
import WidgetKit
import UIKit

@MainActor @Observable final class SessionStore {
    var api: APIClient?
    var pipeline: MediaPipeline?
    var name = ""
    var isRestoring = true
    private(set) var isSigningOut = false
    var error: String?
    var requiresPasswordChange = false
    var pendingLink: AppLink?
    private(set) var libraryAPI: (any LibraryAPI)?
    private(set) var entities: EntityStore?
    /// Fills the thumbnail store with the whole library while the app is open.
    private(set) var thumbnailWarmer: ThumbnailWarmer?
    private(set) var syncError: String?
    private(set) var lastSyncDate: Date?
    private(set) var isSyncing = false
    @ObservationIgnored private var sync: NativeSync?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncShutdown: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundSyncOwner: UUID?
    @ObservationIgnored private var backgroundSyncPromoted = false
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var isResettingLibraryMetadata = false
    @ObservationIgnored private var isForeground = UIApplication.shared.applicationState == .active
    let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    func restore() async {
        if let restoreTask { await restoreTask.value; return }
        guard isRestoring else { return }
        let task = Task { @MainActor in await restoreSession() }
        restoreTask = task
        await task.value
        restoreTask = nil
    }

    private func restoreSession() async {
        defer { isRestoring = false }
        guard !isUITesting else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-library") {
                do { try connect(SavedSession(server: URL(string: "http://127.0.0.1:18091")!, token: "ui-test-session", userID: "00000000-0000-4000-8000-000000000001", name: "Test library")) }
                catch { self.error = error.localizedDescription }
            }
            #endif
            return
        }
        do {
            if var saved = try await Task.detached(priority: .userInitiated, operation: { try SessionKeychain.read() }).value {
                // Earlier native builds persisted the server flag without the
                // administrator exemption. Repair it without changing credentials.
                if saved.requiresPasswordChange == true {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 4
                    configuration.timeoutIntervalForResource = 6
                    let checkSession = URLSession(configuration: configuration, delegate: SameOriginRedirectDelegate(origin: saved.server), delegateQueue: nil)
                    defer { checkSession.invalidateAndCancel() }
                    let client = try APIClient(baseURL: saved.server, accessToken: saved.token, userID: saved.userID, session: checkSession)
                    if let user = try? await client.currentUser(), user.isAdmin == true {
                        saved.requiresPasswordChange = false
                        try? SessionKeychain.save(saved)
                    }
                }
                try connect(saved)
            }
        } catch { self.error = error.localizedDescription }
    }

    func signIn(server: String, email: String, password: String) async throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw APIError.invalidServerURL }
        let client = try APIClient(baseURL: url)
        let result = try await client.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        try acceptLogin(result, server: client.baseURL)
    }

    func acceptLogin(_ result: LoginResponse, server: URL) throws {
        guard !isSigningOut else { throw APIError.invalidResponse("Sign-out is still finishing. Try signing in again in a moment.") }
        let saved = SavedSession(server: server, token: result.accessToken, userID: result.userId, name: result.name,
                                 requiresPasswordChange: result.requiresPasswordChange)
        if !isUITesting { try SessionKeychain.save(saved) }
        if !isUITesting { WidgetCenter.shared.reloadAllTimelines() }
        try connect(saved)
    }

    private func connect(_ saved: SavedSession) throws {
        let client = try APIClient(baseURL: saved.server, accessToken: saved.token, userID: saved.userID,
                                   networkConfiguration: isUITesting ? NetworkConfiguration() : nil)
        api = client
        let pipeline = MediaPipeline(client: client)
        self.pipeline = pipeline
        thumbnailWarmer?.stop(); thumbnailWarmer = nil
        name = saved.name
        requiresPasswordChange = saved.requiresPasswordChange == true
        if !isUITesting, !requiresPasswordChange {
            do {
                let entities = try EntityStore(scope: client.cacheScope, userID: saved.userID)
                self.entities = entities
                let sync = NativeSync(api: client, store: entities)
                self.sync = sync
                libraryAPI = NativeLibraryAPI(client: client, entities: entities, sync: sync)
                let warmer = ThumbnailWarmer()
                thumbnailWarmer = warmer
                Task { if (try? await entities.isComplete()) == true { warmer.start(entities: entities, pipeline: pipeline) } }
                startSync()
            } catch { syncError = error.localizedDescription }
        }
        validateSession()
    }

    func sceneChanged(_ phase: ScenePhase) {
        if phase == .active {
            isForeground = true
            if backgroundSyncOwner != nil { backgroundSyncPromoted = true }
            validateSession(); startSync()
        }
        else if phase == .background {
            isForeground = false
            backgroundSyncPromoted = false
            syncTask?.cancel(); syncTask = nil; isSyncing = false
            if backgroundSyncOwner == nil, let sync { syncShutdown = Task { await sync.stop() } }
        }
    }

    func startSync() {
        guard isForeground, (backgroundSyncOwner == nil || backgroundSyncPromoted),
              !isResettingLibraryMetadata, syncTask == nil, let sync, let client = api, let entities else { return }
        isSyncing = true; syncError = nil
        syncTask = Task { [weak self] in
            await self?.syncShutdown?.value
            guard !Task.isCancelled else { return }
            await client.attachEntityStore(entities)
            do {
                let summary = try await sync.synchronize()
                guard !Task.isCancelled, let self, self.api === client else { return }
                await self.didSync(summary, client: client)
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, let self, self.api === client else { return }
                await self.syncFailed(error, client: client)
            }
            guard !Task.isCancelled, let self, self.api === client else { return }
            self.isSyncing = false; self.syncTask = nil
            await sync.startEvents(onChange: { [weak self] summary in
                await self?.didSync(summary, client: client)
            }, onError: { [weak self] error in
                await self?.syncFailed(error, client: client)
            })
        }
    }

    func prepareForBackgroundBackup() async -> Bool {
        guard backgroundSyncOwner == nil, !isSigningOut, !isResettingLibraryMetadata else { return false }
        let owner = UUID()
        backgroundSyncOwner = owner
        backgroundSyncPromoted = isForeground
        isSyncing = true
        defer {
            if backgroundSyncOwner == owner {
                backgroundSyncOwner = nil
                backgroundSyncPromoted = false
                if !isForeground || isSigningOut { isSyncing = false }
                else { startSync() }
            }
        }

        await restore()
        guard !Task.isCancelled, backgroundSyncOwner == owner, !isSigningOut,
              !isResettingLibraryMetadata, !requiresPasswordChange,
              let client = api, let sync, let entities else { return false }
        await syncShutdown?.value
        syncShutdown = nil
        guard !Task.isCancelled, backgroundSyncOwner == owner, api === client,
              self.sync === sync, self.entities === entities,
              !isSigningOut, !isResettingLibraryMetadata, !requiresPasswordChange else { return false }

        await client.attachEntityStore(entities)
        guard !Task.isCancelled else { return false }
        do {
            let summary = try await withTaskCancellationHandler {
                try await sync.synchronize()
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.backgroundSyncOwner == owner,
                          self.api === client, self.sync === sync,
                          !self.isForeground, !self.backgroundSyncPromoted else { return }
                    await sync.stop()
                }
            }
            try Task.checkCancellation()
            guard backgroundSyncOwner == owner, api === client, self.sync === sync,
                  self.entities === entities, !isSigningOut, !isResettingLibraryMetadata,
                  !requiresPasswordChange else { return false }
            if !backgroundSyncPromoted { await didSync(summary, client: client) }
            return true
        } catch is CancellationError {
            if backgroundSyncOwner == owner, api === client, self.sync === sync,
               !isForeground, !backgroundSyncPromoted { await sync.stop() }
            return false
        } catch {
            guard backgroundSyncOwner == owner, api === client, !isSigningOut,
                  !isResettingLibraryMetadata, !requiresPasswordChange else { return false }
            await syncFailed(error, client: client)
            return false
        }
    }

    func resetLibraryMetadata() async {
        guard !isResettingLibraryMetadata, !isSigningOut, !isSyncing, let client = api, let sync, let entities else { return }
        isResettingLibraryMetadata = true
        var resetRequested = false
        defer {
            isResettingLibraryMetadata = false
            if isForeground && !isSigningOut && (resetRequested || api !== client) { startSync() }
        }
        isSyncing = true
        syncError = nil
        let previousTask = syncTask
        syncTask?.cancel()
        syncTask = nil
        await syncShutdown?.value
        syncShutdown = nil
        await sync.stop()
        await previousTask?.value
        guard api === client, self.sync === sync, self.entities === entities else { return }
        do {
            try await entities.clear()
            resetRequested = true
            await TimelineCache.shared.removeAll(scope: client.cacheScope)
            await TimelinePlacesCache.shared.removeAll(scope: client.cacheScope)
            guard api === client else { return }
            NotificationCenter.default.post(name: .ilyichLibraryChanged, object: nil,
                                            userInfo: ["scope": client.cacheScope, "collections": true, "accessChanged": false])
        } catch {
            guard api === client else { return }
            syncError = error.localizedDescription
            isSyncing = false
        }
    }

    private func didSync(_ summary: SyncChangeSummary, client: APIClient) async {
        guard api === client, let entities else { return }
        let previousPipeline = pipeline
        let date = try? await entities.lastSyncDate()
        guard api === client else { return }
        lastSyncDate = date; syncError = nil
        await client.persistCachedServerFeatures()
        guard api === client else { return }
        if summary.completed, let pipeline { thumbnailWarmer?.start(entities: entities, pipeline: pipeline) }
        guard summary.changed || summary.completed || !summary.assetIDs.isEmpty else { return }
        let accessChanged = (try? await entities.takeAccessInvalidation()) == true
        guard api === client else { return }
        if accessChanged || summary.accessChanged || summary.reset {
            await previousPipeline?.removeAll()
            // Places are kept through ordinary syncs, but not past a change in what may be seen.
            await TimelinePlacesCache.shared.removeAll(scope: client.cacheScope)
        } else if !summary.deletedAssetIDs.isEmpty {
            // Clearing every cache for one deletion would throw away the whole offline library.
            await previousPipeline?.forget(assetIDs: summary.deletedAssetIDs)
        }
        guard api === client else { return }
        await TimelineCache.shared.removeAll(scope: client.cacheScope)
        guard api === client else { return }
        NotificationCenter.default.post(name: .ilyichLibraryChanged, object: nil,
                                        userInfo: ["scope": client.cacheScope, "collections": summary.collectionsChanged,
                                                   "accessChanged": accessChanged || summary.accessChanged])
        WidgetCenter.shared.reloadAllTimelines()
        if summary.configurationChanged { validateSession() }
    }

    private func syncFailed(_ error: any Error, client: APIClient) async {
        guard api === client, let entities else { return }
        let previousPipeline = pipeline
        let accessChanged = (try? await entities.takeAccessInvalidation()) == true
        guard api === client else { return }
        if accessChanged {
            await previousPipeline?.removeAll()
            guard api === client else { return }
            await TimelineCache.shared.removeAll(scope: client.cacheScope)
            await TimelinePlacesCache.shared.removeAll(scope: client.cacheScope)
            guard api === client else { return }
            NotificationCenter.default.post(name: .ilyichLibraryChanged, object: nil,
                                            userInfo: ["scope": client.cacheScope, "collections": true, "accessChanged": true])
        }
        if case APIError.unauthorized = error { await signOut() }
        else { syncError = error.localizedDescription }
    }

    func validateSession() {
        guard !isUITesting, let client = api else { return }
        validationTask?.cancel()
        validationTask = Task { [weak self] in
            do { try await client.validateToken() }
            catch APIError.unauthorized {
                guard !Task.isCancelled, let self, self.api === client else { return }
                await self.signOut()
                if self.api == nil { self.error = APIError.unauthorized.localizedDescription }
            } catch { /* A temporary network failure must not discard an offline session. */ }
        }
    }

    func open(_ url: URL) {
        if let link = AppLink(url: url, server: api?.baseURL) { pendingLink = link }
    }

    func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        let previous = api, previousPipeline = pipeline, previousSync = sync, previousEntities = entities
        api = nil; pipeline = nil; name = ""; requiresPasswordChange = false; pendingLink = nil; error = nil
        sync = nil; entities = nil; libraryAPI = nil; syncError = nil; lastSyncDate = nil; isSyncing = false
        thumbnailWarmer?.stop(); thumbnailWarmer = nil
        validationTask?.cancel()
        syncTask?.cancel(); syncTask = nil
        // Remove shared credentials before suspending; widgets and uploads must
        // observe sign-out even if subsequent local cleanup cannot finish.
        var cleanupError: String?
        if !isUITesting {
            do { try SessionKeychain.remove() } catch { cleanupError = error.localizedDescription }
            WidgetCenter.shared.reloadAllTimelines()
        }
        CastController.shared.signOut()
        await syncShutdown?.value
        syncShutdown = nil
        await previousSync?.stop()
        try? await previousEntities?.clear()
        await previous?.attachEntityStore(nil)
        await BackupCoordinator.shared.disconnect()
        await TransferNotifications.clearAll()
        if let previous { LockedPINStore.remove(for: previous) }
        if let previous, !isUITesting {
            do { try NetworkConfigurationStore.remove(server: previous.baseURL) }
            catch { cleanupError = cleanupError ?? error.localizedDescription }
        }
        await previousPipeline?.removeAll()
        await DiagnosticsStore.shared.clear()
        if let previous {
            await TimelineCache.shared.removeAll(scope: previous.cacheScope)
            await TimelinePlacesCache.shared.removeAll(scope: previous.cacheScope)
        }
        error = cleanupError
        isSigningOut = false
        try? await previous?.logout()
    }
}

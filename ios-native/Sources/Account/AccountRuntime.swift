import Foundation
import IlyichPlatform
import os
import Synchronization

/// One signed-in account's services. It is opened off the main actor, owns everything that
/// belongs to the account (its authorization, transport, media, offline library, sync, coverage
/// and owned work), and AccountManager tears it down in a fixed order.
final class AccountRuntime: Sendable {
    let id: UUID
    let credential: StoredCredential
    /// What the account may do. The runtime owns it: it ends when the runtime is torn down.
    let authorization: AuthorizationState
    /// The account's requests: its transport and the endpoint catalogue over it.
    let api: APIClient
    let pipeline: MediaPipeline
    /// The offline library, its sync and the coverage worker. Nil while a password change is
    /// required, when the environment runs without them, and when the database couldn't open.
    let library: LibraryServices?
    /// Why the offline library couldn't open.
    let libraryError: String?
    /// The account's transfers database, which the transfer engine runs backup from
    /// (REBUILD_ROADMAP.md B1, B9). Nil when the environment runs without it.
    let transfers: TransferServices?
    /// Whether the account's backup runs on the transfer engine, once TransferHost decided:
    /// cleanup and the device index read their receipts from it.
    let cutover: TransferCutoverState
    /// The session checks with the server.
    let check: SessionCheck
    /// The account's tasks, cancelled and waited for at shutdown.
    let work: OwnedWork
    /// The child sessions Cast receivers are given; sign-out revokes them before it logs out.
    let castGrants: CastGrantStore
    /// Free up space's checks and removals (REBUILD_ROADMAP.md P4). Shut down right after the
    /// mutations at teardown.
    let cleanup: CleanupService
    /// The phone's side of the merged library (REBUILD_ROADMAP.md P5). Nil when the environment
    /// runs without the phone's photos. It starts once the library subscribes.
    let deviceIndex: DeviceIndexService?
    /// The account's changes to its library on the server (REBUILD_ROADMAP.md N2), followed by a
    /// sync pass when the offline library syncs. Shut down first at teardown.
    let mutations: LibraryMutationService
    /// The account's albums, members, links, people, partners, memories and album activity on the
    /// server (REBUILD_ROADMAP.md N4). Shut down right after the mutations.
    let collections: CollectionsService
    /// The account's name, password, Locked Folder PIN and profile photo on the server (the
    /// critic's correction to N4). Shut down with the collections.
    let settings: AccountSettingsService
    /// Where the screens hear of everything that happens to the account's library: its sync's
    /// changes, its mutations' results, its collections' changes and a cleared cache, in one
    /// order (REBUILD_ROADMAP.md N4). Closed first at teardown.
    let bus: LibraryBus
    private let presence: AppPresence
    private let usesDevicePhotos: Bool
    /// Readying the transfers database for the engine, once per runtime.
    private let preparing = Mutex<Task<TransferCutover, Never>?>(nil)
    /// The account's transfer engine and its work, once TransferHost made it, with how to tell
    /// the host it ends.
    private let engine = Mutex<(runtime: TransferRuntime, detach: @MainActor @Sendable () -> Void)?>(nil)

    struct LibraryServices: Sendable {
        let entities: LibraryIndex
        let native: NativeSync
        let repository: LibraryRepository
        let sync: SyncEngine
        /// The sync's status, where the screens read it.
        let status: SyncStatusBoard
        /// Keeps the library's thumbnails on the phone (REBUILD_ROADMAP.md T5).
        let coverage: CoverageWorker
    }

    struct TransferServices: Sendable {
        let store: TransferStore
    }

    var requiresPasswordChange: Bool { credential.requiresPasswordChange == true }

    /// The transfer engine's server calls, over the account's one client (REBUILD_ROADMAP.md B3).
    var transferServer: APITransferServer { APITransferServer(client: api) }

    /// The account's transfer engine, while it runs.
    var transferRuntime: TransferRuntime? { engine.withLock { $0?.runtime } }

    /// What Cast works with for this account.
    var cast: CastAccount { CastAccount(scope: api.cacheScope, grants: castGrants, resolver: CastMediaResolver(api: api)) }

    private init(id: UUID, credential: StoredCredential, authorization: AuthorizationState, api: APIClient, pipeline: MediaPipeline,
                 library: LibraryServices?, libraryError: String?, transfers: TransferServices?, check: SessionCheck, work: OwnedWork,
                 cleanup: CleanupService, deviceIndex: DeviceIndexService?, mutations: LibraryMutationService, collections: CollectionsService,
                 settings: AccountSettingsService, bus: LibraryBus, presence: AppPresence,
                 cutover: TransferCutoverState, usesDevicePhotos: Bool) {
        self.id = id
        self.credential = credential
        self.authorization = authorization
        self.api = api
        self.pipeline = pipeline
        self.library = library
        self.libraryError = libraryError
        self.transfers = transfers
        self.check = check
        self.work = work
        self.castGrants = CastGrantStore(server: api)
        self.cleanup = cleanup
        self.deviceIndex = deviceIndex
        self.mutations = mutations
        self.collections = collections
        self.settings = settings
        self.bus = bus
        self.presence = presence
        self.cutover = cutover
        self.usesDevicePhotos = usesDevicePhotos
    }

    /// Opens `credential`'s services. The client reads the server's saved network settings from
    /// the Keychain and the offline library opens its database, so this never runs on the main
    /// actor; only the pieces that live there are made there. `expired` decides whether a failure
    /// that the account's work met ends the session; `refused` hears that the server the session
    /// checks with runs a release older than the app needs.
    static func open(_ credential: StoredCredential, environment: AccountEnvironment, dependencies: AccountDependencies,
                     presence: AppPresence, refused: @escaping @Sendable (UUID, UnsupportedServer) async -> Void = { _, _ in },
                     expired: @escaping @Sendable (UUID, any Error) async -> Bool) async throws -> AccountRuntime {
        let id = UUID()
        // The App Group mirror is written here for the saved credential, which stays untouched.
        let authorization = AuthorizationState(account: credential.account, token: credential.token,
                                               readOnly: ReadOnlyPolicy.isEnabled(server: credential.server, userID: credential.userID),
                                               requiresPasswordChange: credential.requiresPasswordChange == true,
                                               mirror: dependencies.mirror)
        let api: APIClient
        do { api = try dependencies.clients.make(credential.server, credential, .session(authorization)) }
        catch { authorization.end(); throw error }
        // Phone photos' grid thumbnails come from Photos through the thumbnail service (T6).
        let pipeline = MediaPipeline(client: api, protocolClasses: environment.mediaProtocolClasses,
                                     device: environment.usesDevicePhotos ? DeviceThumbnailSource(imaging: PhotoKitAdapter.thumbnails) : nil)
        let work = OwnedWork()
        let bus = LibraryBus()
        let check = SessionCheck(api: api, work: work, enabled: environment.validatesSession,
                                 refused: { unsupported in await refused(id, unsupported) }) { error in await expired(id, error) }
        var library: LibraryServices?
        var libraryError: String?
        if environment.syncsLibrary, credential.requiresPasswordChange != true {
            do {
                let entities = try LibraryIndex(scope: api.cacheScope, userID: credential.userID, directory: environment.libraryDirectory)
                // Feature tiles, globe markers and the like name their photo from the library,
                // with its revision, instead of asking the server for it first (T6).
                pipeline.setIndexedAssets { id in try? await entities.asset(id: id) }
                let native = NativeSync(api: api, store: entities)
                // Only the boards the screens observe are made on the main actor.
                let (status, board) = await MainActor.run { (SyncStatusBoard(), CoverageBoard()) }
                // The sync's changes reach media first, then the screens on the account's bus.
                let sync = SyncEngine(client: api, entities: entities, native: native, pipeline: pipeline,
                                      presence: presence, check: check, authorization: authorization, status: status,
                                      hub: LibraryChangeHub(pipeline: pipeline, bus: bus))
                let coverage = CoverageWorker(index: entities, store: pipeline.thumbnails, scheduler: pipeline.scheduler,
                                              conditions: CoverageConditions(followingSystemWithAppActive: presence.isForeground), board: board,
                                              changes: { await sync.changes() }, authorization: authorization)
                library = LibraryServices(entities: entities, native: native, repository: LibraryRepository(client: api, index: entities, sync: sync),
                                          sync: sync, status: status, coverage: coverage)
            } catch { libraryError = error.localizedDescription }
        }
        var transfers: TransferServices?
        if environment.keepsTransfers {
            // The database opens on its own queue at first use.
            transfers = TransferServices(store: TransferStore(url: TransferStore.url(for: credential.account, in: environment.transfersDirectory)))
        }
        let cutover = TransferCutoverState()
        let receipts = CutoverReceipts(cutover: cutover)
        let cleanup = makeCleanup(credential, authorization: authorization, api: api, library: library,
                                  credentials: environment.credentialStore(), receipts: receipts)
        var deviceIndex: DeviceIndexService?
        if environment.usesDevicePhotos {
            let server = library.map { library in
                LibraryIndexIdentities(entities: library.entities, libraryChanges: { await library.sync.changes() })
            }
            deviceIndex = DeviceIndexService(account: credential.account.digest, reader: PhotoKitIndexReader(adapter: .shared), server: server,
                                             backup: receipts, database: PhotoKitAdapter.shared.database, presence: presence)
        }
        // A mutation's follow-up is a pass of the account's sync, which publishes its change like any.
        var followUp: (@Sendable () async throws -> LibraryChange?)?
        if let sync = library?.sync { followUp = { try await sync.refresh() } }
        let mutations = LibraryMutationService(client: api, pipeline: pipeline, authorization: authorization, refresh: followUp, bus: bus)
        let collections = CollectionsService(client: api, authorization: authorization, bus: bus)
        let settings = AccountSettingsService(client: api, authorization: authorization)
        return AccountRuntime(id: id, credential: credential, authorization: authorization, api: api, pipeline: pipeline,
                              library: library, libraryError: libraryError, transfers: transfers, check: check, work: work,
                              cleanup: cleanup, deviceIndex: deviceIndex, mutations: mutations, collections: collections,
                              settings: settings, bus: bus, presence: presence, cutover: cutover,
                              usesDevicePhotos: environment.usesDevicePhotos)
    }

    /// Starts the account's work once the screens show it: coverage, which waits for the offline
    /// library to be complete, sync while the app is in front, and the session check. Backup
    /// starts when the account becomes active (TransferHost.activate).
    @MainActor func start() async {
        if let library {
            let entities = library.entities
            library.coverage.start()
            await library.sync.start()
            // Fills the index's derived tables for a library synced before they existed, off the
            // main thread and a batch at a time; the feeds read the server until it is done.
            entities.startBackfill()
        }
        check.validate()
    }

    /// Cancels the account's work and waits for it to end. The bus closes first, so nothing the
    /// account's work does from here on reaches a screen. Then library mutations, collection and
    /// settings changes still running, cleanup, coverage, sync and its live stream, the session
    /// check, the database's readying, and the transfer engine with everything beside it, which
    /// gives its leases back. Then the transfers database closes. It stays on disk, whatever the
    /// reason for ending, and so do the staged copies (the owner's decision).
    func cancelAndJoin() async {
        bus.close()
        await mutations.shutdown()
        await collections.shutdown()
        await settings.shutdown()
        await cleanup.shutdown()
        await deviceIndex?.shutdown()
        if let library {
            await library.coverage.stop()
            await library.sync.shutdown()
            await library.entities.stopBackfill()
        }
        await work.cancelAndJoin()
        preparing.withLock { $0?.cancel() }
        if let (transfers, detach) = engine.withLock({ $0 }) {
            await MainActor.run { detach() }
            await transfers.stop()
        }
        cutover.decide(.unavailable)
        await transfers?.store.close()
    }

    /// Sign-out, before the account's work ends: the transfer engine switches automatic backup
    /// off unless `keepingAutomaticBackup`, pauses, and cancels the account's tasks with iOS.
    func prepareForSignOut(keepingAutomaticBackup: Bool) async {
        await transferRuntime?.signOut(keepingAutomaticBackup: keepingAutomaticBackup)
    }

    // MARK: Transfers

    /// Readies the account's transfers database for the engine, once per runtime, and says whether
    /// the account's backup can run on it. A database the engine owns is used as it is: B9's
    /// import handed the phone's over. The engine claims any other as it is (claimForEngine): a new
    /// account's, or a copy B1 made that no import handed over, which waits paused with automatic
    /// backup off. Since C8 nothing reads a state.json an older build left: none is left on the
    /// one phone, and no older build will be installed again. Afterwards the photos cleanup
    /// removed are marked in the receipts, from the device journal.
    func prepareTransfers() async -> TransferCutover {
        let task = preparing.withLock { slot -> Task<TransferCutover, Never> in
            if let slot { return slot }
            let task = Task { await self.readyTransfers() }
            slot = task
            return task
        }
        return await task.value
    }

    private func readyTransfers() async -> TransferCutover {
        guard let transfers else { return .unavailable("Backup records aren’t kept here.") }
        let meta: TransferMeta
        do { meta = try await transfers.store.meta() } catch { return .unavailable("The backup records database can’t be opened.") }
        guard meta.schema <= TransferStore.schemaVersion else { return .unavailable("The backup records were written by a newer version.") }
        guard !Task.isCancelled else { return .unavailable("The account closed.") }
        if meta.engine != .transfer {
            guard (try? await transfers.store.claimForEngine()) == true else { return .unavailable("The backup records database can’t be opened.") }
            Self.logger.notice("The transfer engine took over the account's backup records")
        }
        if usesDevicePhotos { await importLocalDeletions(into: transfers.store) }
        return .engine
    }

    /// Cleanup removals Photos committed for this account before the cutover were recorded only in
    /// the device journal: each marks its receipt, where the receipt is still of the revision
    /// removed (the critic's correction for B9). Idempotent.
    private func importLocalDeletions(into store: TransferStore) async {
        guard let records = try? await PhotoKitAdapter.shared.database.records() else { return }
        _ = try? await store.markLocallyDeleted(Self.localDeletions(records, account: credential.account.digest))
    }

    static func localDeletions(_ records: [DeviceJournalRecord], account: String) -> [LocalDeletion] {
        var deletions: [LocalDeletion] = []
        for record in records {
            guard case .delete(let ids, let expected, .cleanup(_, let owner)) = record.entry.mutation, owner == account,
                  case .committed(let affected, _)? = record.outcome else { continue }
            let removed = Set(affected)
            for id in ids where removed.contains(id) {
                deletions.append(LocalDeletion(localID: id.rawValue, revision: expected[id], date: record.finishedAt ?? record.entry.createdAt))
            }
        }
        return deletions
    }

    /// TransferHost made the account's transfer engine; `detach` tells it the engine ends.
    func attachTransfers(_ runtime: TransferRuntime, detach: @escaping @MainActor @Sendable () -> Void) {
        engine.withLock { $0 = (runtime, detach) }
    }

    /// The account's cleanup service. Nothing touches Photos or the backup records until a check
    /// starts. Its receipts are the transfers database's once the engine runs the account's backup
    /// (CutoverReceipts); its server reads are strict, over the account's client; removing needs
    /// the saved credential to still be this session's.
    private static func makeCleanup(_ credential: StoredCredential, authorization: AuthorizationState, api: APIClient,
                                    library: LibraryServices?, credentials: any CredentialStore, receipts: CutoverReceipts) -> CleanupService {
        let server = APITransferServer(client: api)
        var serverChanges: (@Sendable () async -> AsyncStream<LibraryChange>)?
        if let sync = library?.sync { serverChanges = { await sync.changes() } }
        let remote: @Sendable (String) async throws -> BackupRemoteAsset = { try await server.remoteAsset(id: $0) }
        let credentialIsCurrent: @Sendable () -> Bool = {
            guard let saved = try? credentials.load() else { return false }
            return saved.scope == credential.scope && saved.token == credential.token
        }
        return CleanupService(
            account: credential.account.digest, ownerID: credential.userID, authorization: authorization, receipts: receipts,
            device: { PhotoKitCleanupDevice(adapter: .shared, reader: SystemPhotoKit()) },
            remote: remote, credentialIsCurrent: credentialIsCurrent, serverChanges: serverChanges)
    }

    /// Clears the account's downloaded previews and decoded images, and tells the screens, whose
    /// feed reads its months again. The thumbnails kept offline stay (G2).
    func clearBrowsingCache() async {
        await pipeline.clearBrowsingCache()
        bus.post(.cachesCleared)
    }

    /// Empties the offline library: entities, acknowledgements and metadata. The file stays.
    func clearLibrary() async {
        if let library { try? await library.entities.clear() }
        await api.attachEntityStore(nil)
    }

    // MARK: Read-only mode

    /// Turns read-only mode on or off. The flag and the write generation change at once, so the
    /// controls follow straight away and writes still waiting to be sent are refused. Returns the
    /// new snapshot, or nil when nothing changed.
    func setReadOnly(_ enabled: Bool) -> AuthorizationSnapshot? {
        guard !authorization.hasEnded, authorization.snapshot.readOnly != enabled else { return nil }
        ReadOnlyPolicy.setEnabled(enabled, server: api.baseURL, userID: credential.userID)
        return authorization.setReadOnly(enabled)
    }

    private static let logger = Logger(subsystem: "app.ilyich.native", category: "Transfers")
}

/// Checks the session with the server: when it opens, whenever the app comes forward and when
/// the server's configuration changes. A newer check replaces an older one. A temporary network
/// failure, a proxy or a forbidden answer keeps the session, and with it the offline library.
/// A session the server still accepts is checked against the release the server says it runs,
/// which may have been replaced by an older one; one that can't say is let be.
final class SessionCheck: Sendable {
    private let api: APIClient
    private let work: OwnedWork
    private let enabled: Bool
    private let refused: @Sendable (UnsupportedServer) async -> Void
    private let expired: @Sendable (any Error) async -> Bool

    init(api: APIClient, work: OwnedWork, enabled: Bool, refused: @escaping @Sendable (UnsupportedServer) async -> Void = { _ in },
         expired: @escaping @Sendable (any Error) async -> Bool) {
        self.api = api
        self.work = work
        self.enabled = enabled
        self.refused = refused
        self.expired = expired
    }

    func validate() {
        guard enabled else { return }
        let api = api, expired = expired, refused = refused
        let check = Task {
            do { try await api.validateToken() }
            catch {
                guard !Task.isCancelled else { return }
                _ = await expired(error)
                return
            }
            do { try await api.requireSupportedVersion() }
            catch let unsupported as UnsupportedServer where unsupported.version != nil {
                guard !Task.isCancelled else { return }
                await refused(unsupported)
            } catch {}
        }
        work.put(check, in: "validation", cancelling: true)
    }

    /// Whether a failure the account's work met ends the session; sign-out has then begun.
    func sessionEnds(after error: any Error) async -> Bool { await expired(error) }
}

/// An account's tasks that outlive the call that started them, each in a named slot. Shutdown
/// cancels them and waits for each to end, and a task handed over after that is cancelled at once.
/// Tasks are handed over synchronously, from the main actor too, so that none can slip in while
/// shutdown runs.
final class OwnedWork: Sendable {
    private struct State {
        var tasks: [String: Task<Void, Never>] = [:]
        var closed = false
    }
    private let state = Mutex(State())

    /// The task in `slot`, for a new one to wait on.
    func current(_ slot: String) -> Task<Void, Never>? { state.withLock { $0.tasks[slot] } }

    /// Puts `task` in `slot`, cancelling the task it replaces when `cancelling` is set. After
    /// shutdown the task is cancelled instead, and the answer is false.
    @discardableResult
    func put(_ task: Task<Void, Never>, in slot: String, cancelling: Bool) -> Bool {
        let (accepted, replaced) = state.withLock { state -> (Bool, Task<Void, Never>?) in
            guard !state.closed else { return (false, nil) }
            defer { state.tasks[slot] = task }
            return (true, state.tasks[slot])
        }
        guard accepted else { task.cancel(); return false }
        if cancelling { replaced?.cancel() }
        return true
    }

    func cancelAndJoin() async {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            state.closed = true
            defer { state.tasks = [:] }
            return Array(state.tasks.values)
        }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
}

/// Whether the app is in front, which every account's sync follows. The session updates it as
/// the scene changes, and sync reads it from its own actor whenever it hears of a change, so
/// changes that arrive out of order still end at the latest.
final class AppPresence: Sendable {
    private let foreground: Mutex<Bool>

    init(isForeground: Bool) { foreground = Mutex(isForeground) }

    var isForeground: Bool {
        get { foreground.withLock { $0 } }
        set { foreground.withLock { $0 = newValue } }
    }
}

import Foundation
import IlyichPlatform
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
    /// The account's transfers database and the import of today's backup state into it
    /// (REBUILD_ROADMAP.md B1, B9). Nil when the environment runs without it.
    let transfers: TransferServices?
    /// Which engine the account's backup runs on, once TransferHost decided: cleanup and the
    /// device index read their receipts from it.
    let cutover: TransferCutoverState
    /// The folder that holds each account's Backup/<digest>/state.json: nil for the App Group.
    let backupContainer: URL?
    /// The session checks with the server.
    let check: SessionCheck
    /// The account's tasks, cancelled and waited for at shutdown.
    let work: OwnedWork
    /// The child sessions Cast receivers are given; sign-out revokes them before it logs out.
    let castGrants: CastGrantStore
    /// Free up space's checks and removals (REBUILD_ROADMAP.md P4). Shut down first at teardown.
    let cleanup: CleanupService
    /// The phone's side of the merged library (REBUILD_ROADMAP.md P5). Nil when the environment
    /// runs without the phone's photos. It starts once the library subscribes.
    let deviceIndex: DeviceIndexService?
    private let device: any AccountDevice
    private let presence: AppPresence
    private let usesDevicePhotos: Bool
    /// The authoritative import, run once per runtime.
    private let importing = Mutex<Task<TransferCutover, Never>?>(nil)
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
        let importer: LegacyBackupImporter
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
                 cleanup: CleanupService, deviceIndex: DeviceIndexService?, device: any AccountDevice, presence: AppPresence,
                 cutover: TransferCutoverState, backupContainer: URL?, usesDevicePhotos: Bool) {
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
        self.device = device
        self.presence = presence
        self.cutover = cutover
        self.backupContainer = backupContainer
        self.usesDevicePhotos = usesDevicePhotos
    }

    /// Opens `credential`'s services. The client reads the server's saved network settings from
    /// the Keychain and the offline library opens its database, so this never runs on the main
    /// actor; only the pieces that live there are made there. `expired` decides whether a failure
    /// that the account's work met ends the session.
    static func open(_ credential: StoredCredential, environment: AccountEnvironment, dependencies: AccountDependencies,
                     presence: AppPresence, expired: @escaping @Sendable (UUID, any Error) async -> Bool) async throws -> AccountRuntime {
        let id = UUID()
        // The App Group mirror is written here for the saved credential, which stays untouched.
        let authorization = AuthorizationState(account: credential.account, token: credential.token,
                                               readOnly: ReadOnlyPolicy.isEnabled(server: credential.server, userID: credential.userID),
                                               requiresPasswordChange: credential.requiresPasswordChange == true,
                                               mirror: dependencies.mirror)
        let api: APIClient
        do { api = try dependencies.clients.make(credential.server, credential, .session(authorization)) }
        catch { authorization.end(); throw error }
        let pipeline = MediaPipeline(client: api)
        let work = OwnedWork()
        let check = SessionCheck(api: api, work: work, enabled: environment.validatesSession) { error in await expired(id, error) }
        var library: LibraryServices?
        var libraryError: String?
        if environment.syncsLibrary, credential.requiresPasswordChange != true {
            do {
                let entities = try LibraryIndex(scope: api.cacheScope, userID: credential.userID, directory: environment.libraryDirectory)
                let native = NativeSync(api: api, store: entities)
                let device = dependencies.device
                // Only the boards the screens observe are made on the main actor.
                let (status, board) = await MainActor.run { (SyncStatusBoard(), CoverageBoard()) }
                let sync = SyncEngine(client: api, entities: entities, native: native, pipeline: pipeline,
                                      presence: presence, check: check, authorization: authorization, device: device, status: status)
                let coverage = CoverageWorker(index: entities, store: pipeline.thumbnails, scheduler: pipeline.scheduler,
                                              conditions: CoverageConditions(followingSystemWithAppActive: presence.isForeground), board: board,
                                              changes: { await sync.changes() }, authorization: authorization)
                library = LibraryServices(entities: entities, native: native, repository: LibraryRepository(client: api, index: entities, sync: sync),
                                          sync: sync, status: status, coverage: coverage)
            } catch { libraryError = error.localizedDescription }
        }
        var transfers: TransferServices?
        if environment.importsBackupState {
            // The database opens on its own queue at first use; the App Group is only looked up here.
            let account = credential.account
            let store = TransferStore(url: TransferStore.url(for: account, in: environment.transfersDirectory))
            let container = environment.backupContainer ?? (try? AppGroupLayout.current().container)
            let folder = container?.appendingPathComponent(AccountStoragePaths(account).backup, isDirectory: true)
            transfers = TransferServices(store: store, importer: LegacyBackupImporter(mode: .authoritative, store: store, folder: folder))
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
        return AccountRuntime(id: id, credential: credential, authorization: authorization, api: api, pipeline: pipeline,
                              library: library, libraryError: libraryError, transfers: transfers, check: check, work: work,
                              cleanup: cleanup, deviceIndex: deviceIndex, device: dependencies.device, presence: presence,
                              cutover: cutover, backupContainer: environment.backupContainer, usesDevicePhotos: environment.usesDevicePhotos)
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

    /// Cancels the account's work and waits for it to end: coverage, sync and its live stream,
    /// the session check, read-only changes still on their way, the import, which rolls back, and
    /// the transfer engine with everything beside it, which gives its leases back. Then the
    /// transfers database closes. It stays on disk, whatever the reason for ending, and so do the
    /// staged copies (the owner's decision).
    func cancelAndJoin() async {
        await cleanup.shutdown()
        await deviceIndex?.shutdown()
        if let library {
            await library.coverage.stop()
            await library.sync.shutdown()
            await library.entities.stopBackfill()
        }
        await work.cancelAndJoin()
        importing.withLock { $0?.cancel() }
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

    /// Imports the account's state.json into its transfers database, authoritatively, once per
    /// runtime (BM1 to BM8), and says which engine the account's backup can run on: the transfer
    /// engine once the database is its own, whether this import or an earlier one handed it over,
    /// else today's backup, with the reason. state.json stays where it is either way. Afterwards
    /// the photos cleanup removed are marked in the receipts, from the device journal.
    func prepareTransfers() async -> TransferCutover {
        let task = importing.withLock { slot -> Task<TransferCutover, Never> in
            if let slot { return slot }
            let task = Task { await self.importBackupState() }
            slot = task
            return task
        }
        return await task.value
    }

    private func importBackupState() async -> TransferCutover {
        guard let transfers else { return .legacy("Backup records aren’t kept here.") }
        let report = await transfers.importer.run()
        if let report { await device.recordTransferImport(report) }
        guard !Task.isCancelled else { return .legacy("The account closed.") }
        if report?.outcome == .quarantined { _ = try? await transfers.store.adoptAfterQuarantine() }
        let meta: TransferMeta
        do { meta = try await transfers.store.meta() } catch { return .legacy("The backup records database can’t be opened.") }
        guard meta.schema <= TransferStore.schemaVersion else { return .legacy("The backup records were written by a newer version.") }
        guard meta.engine == .transfer else {
            let outcome = report?.outcome.rawValue ?? "cancelled"
            return .legacy("The backup records couldn’t be imported (\(outcome)); backup carries on with them as they are.")
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

    /// The account's cleanup service. Nothing touches Photos or the backup state until a check
    /// starts. Its receipts are the transfers database's once the engine runs the account's
    /// backup, else today's backup state (CutoverReceipts); its server
    /// reads are strict, over the account's client; removing needs the saved credential to still
    /// be this session's.
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

    /// Compares the transfers database with state.json again, for Diagnostics. Once the engine
    /// runs the account's backup, the comparison made at the import stands; today's backup is
    /// left alone.
    func compareBackupRecords() async {
        guard let transfers, case .engine = await prepareTransfers(), let report = await transfers.importer.run(comparing: true) else { return }
        await device.recordTransferImport(report)
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

    /// Uploads follow a read-only change, as `uploadsFollow(readOnly:)` says, after every change
    /// made before it. `then` runs once they have.
    func uploadsFollowReadOnly(_ enabled: Bool, then: @escaping @MainActor @Sendable () -> Void) {
        let previous = work.current(Self.readOnlySlot), device = device
        let change = Task {
            await previous?.value
            await device.readOnlyChanged(enabled)
            await then()
        }
        work.put(change, in: Self.readOnlySlot, cancelling: false)
    }

    private static let readOnlySlot = "readOnly"

    /// What a read-only change does to uploads, as the toggle always has: turning it on stops
    /// shared uploads and pauses backup, switching automatic backup off, and turning it off starts
    /// nothing again, so backup stays paused until it is started again. Whether turning it off
    /// should carry on with them is an owner question (REBUILD_ROADMAP.md, Open questions).
    @MainActor static func uploadsFollow(readOnly enabled: Bool, backup: BackupCoordinator = .shared,
                                         shares: ShareInboxStore = .shared) async {
        guard enabled else { return }
        shares.cancel()
        await backup.pause()
        await shares.waitUntilPaused()
    }
}

/// Checks the session with the server: when it opens, whenever the app comes forward and when
/// the server's configuration changes. A newer check replaces an older one. A temporary network
/// failure, a proxy or a forbidden answer keeps the session, and with it the offline library.
final class SessionCheck: Sendable {
    private let api: APIClient
    private let work: OwnedWork
    private let enabled: Bool
    private let expired: @Sendable (any Error) async -> Bool

    init(api: APIClient, work: OwnedWork, enabled: Bool, expired: @escaping @Sendable (any Error) async -> Bool) {
        self.api = api
        self.work = work
        self.enabled = enabled
        self.expired = expired
    }

    func validate() {
        guard enabled else { return }
        let api = api, expired = expired
        let check = Task {
            do { try await api.validateToken() }
            catch {
                guard !Task.isCancelled else { return }
                _ = await expired(error)
            }
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

import Foundation
import IlyichPlatform
import Synchronization

/// One signed-in account's services. It is opened off the main actor, owns everything that
/// belongs to the account (its authorization, transport, media, offline library, sync, warmer
/// and owned work), and AccountManager tears it down in a fixed order.
final class AccountRuntime: Sendable {
    let id: UUID
    let credential: StoredCredential
    /// What the account may do. The runtime owns it: it ends when the runtime is torn down.
    let authorization: AuthorizationState
    /// The account's requests: its transport and the endpoint catalogue over it.
    let api: APIClient
    let pipeline: MediaPipeline
    /// The offline library, its sync and the thumbnail warmer. Nil while a password change is
    /// required, when the environment runs without them, and when the database couldn't open.
    let library: LibraryServices?
    /// Why the offline library couldn't open.
    let libraryError: String?
    /// The account's transfers database, with the shadow import of today's backup state into it
    /// (REBUILD_ROADMAP.md B1). Nil when the environment runs without it. Backup still runs from
    /// the backup state; nothing reads the database's records yet.
    let transfers: TransferServices?
    /// The session checks with the server.
    let check: SessionCheck
    /// The account's tasks, cancelled and waited for at shutdown.
    let work: OwnedWork
    private let device: any AccountDevice
    private let presence: AppPresence
    private let backupStateCopyDelay: Duration

    struct LibraryServices: Sendable {
        let entities: EntityStore
        let native: NativeSync
        let libraryAPI: NativeLibraryAPI
        let sync: SyncEngine
        /// The sync's status, where the screens read it.
        let status: SyncStatusBoard
        let warmer: ThumbnailWarmer
    }

    struct TransferServices: Sendable {
        let store: TransferStore
        let importer: LegacyBackupImporter
    }

    var requiresPasswordChange: Bool { credential.requiresPasswordChange == true }

    private init(id: UUID, credential: StoredCredential, authorization: AuthorizationState, api: APIClient, pipeline: MediaPipeline,
                 library: LibraryServices?, libraryError: String?, transfers: TransferServices?, check: SessionCheck, work: OwnedWork,
                 device: any AccountDevice, presence: AppPresence, backupStateCopyDelay: Duration) {
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
        self.device = device
        self.presence = presence
        self.backupStateCopyDelay = backupStateCopyDelay
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
                let entities = try EntityStore(scope: api.cacheScope, userID: credential.userID, directory: environment.libraryDirectory)
                let native = NativeSync(api: api, store: entities)
                let device = dependencies.device
                library = await MainActor.run {
                    let warmer = ThumbnailWarmer(session: authorization)
                    let status = SyncStatusBoard()
                    let sync = SyncEngine(client: api, entities: entities, native: native, pipeline: pipeline, warmer: warmer,
                                          presence: presence, check: check, authorization: authorization, device: device, status: status)
                    return LibraryServices(entities: entities, native: native, libraryAPI: NativeLibraryAPI(client: api, entities: entities, sync: sync),
                                           sync: sync, status: status, warmer: warmer)
                }
            } catch { libraryError = error.localizedDescription }
        }
        var transfers: TransferServices?
        if environment.importsBackupState {
            // The database opens on its own queue at first use; the App Group is only looked up here.
            let account = credential.account
            let store = TransferStore(url: TransferStore.url(for: account, in: environment.transfersDirectory))
            let container = environment.backupContainer ?? (try? AppGroupLayout.current().container)
            let folder = container?.appendingPathComponent(AccountStoragePaths(account).backup, isDirectory: true)
            transfers = TransferServices(store: store, importer: LegacyBackupImporter(mode: .shadow, store: store, folder: folder))
        }
        return AccountRuntime(id: id, credential: credential, authorization: authorization, api: api, pipeline: pipeline,
                              library: library, libraryError: libraryError, transfers: transfers, check: check, work: work,
                              device: dependencies.device, presence: presence, backupStateCopyDelay: dependencies.backupStateCopyDelay)
    }

    /// Starts the account's work once the screens show it: the warmer once the offline library is
    /// complete, sync while the app is in front, the session check, and in front the shadow import
    /// of the backup state.
    @MainActor func start() async {
        if let library {
            let entities = library.entities
            library.warmer.start(when: { (try? await entities.isComplete()) == true }, entities: entities, pipeline: pipeline)
            await library.sync.start()
            // Fills the index's derived tables for a library synced before they existed, off the
            // main thread and a batch at a time; reads don't use them yet.
            entities.startBackfill()
        }
        check.validate()
        // A background launch, for a backup window or a finished upload, leaves it for the next
        // time the app comes forward.
        if presence.isForeground { importBackupStateInShadow() }
    }

    /// Cancels the account's work and waits for it to end: the warmer, sync and its live stream,
    /// the session check, read-only changes still on their way and the shadow import, which rolls
    /// back. Then the transfers database closes. It stays on disk, whatever the reason for ending.
    func cancelAndJoin() async {
        if let library {
            await library.warmer.stop()
            await library.sync.shutdown()
            await library.entities.stopBackfill()
        }
        await work.cancelAndJoin()
        await transfers?.store.close()
    }

    // MARK: Transfers

    /// Brings the transfers database's copy of the backup state up to date, if state.json changed,
    /// and compares it with the file, as owned work: when the runtime opens in front and whenever
    /// the app comes forward, a few seconds later, and at once when Diagnostics asks (`comparing`,
    /// which compares again even when nothing changed). Never on a write of state.json. Runs follow
    /// one another, and the report goes to Diagnostics and the console. Nil when there is nothing
    /// to run.
    @discardableResult
    func importBackupStateInShadow(comparing: Bool = false) -> Task<Void, Never>? {
        guard let transfers else { return nil }
        let previous = work.current(Self.shadowImportSlot), device = device
        let delay = comparing ? .zero : backupStateCopyDelay
        let run = Task {
            await withTaskCancellationHandler {
                await previous?.value
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let report = await transfers.importer.run(comparing: comparing), !Task.isCancelled else { return }
                await device.recordTransferImport(report)
            } onCancel: {
                previous?.cancel()
            }
        }
        guard work.put(run, in: Self.shadowImportSlot, cancelling: false) else { return nil }
        return run
    }

    private static let shadowImportSlot = "shadowImport"

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

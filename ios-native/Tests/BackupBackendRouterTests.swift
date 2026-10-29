import Foundation
import IlyichPlatform
import IlyichShareInbox
import XCTest
@testable import Ilyich

/// The screens' backend over the account's transfer engine (B9, B10): a command waits while the
/// account's backup is prepared, reaches the engine once it runs, and is refused, saying why,
/// when no backup can run.
@MainActor final class BackupBackendRouterTests: XCTestCase {
    private let photo = TransferRequest(source: .photo(DeviceAssetID(rawValue: "photo")), origin: .selection, revision: nil)

    /// The account's backup is prepared for a moment at launch, while the library is on screen.
    /// Back up selected tapped meanwhile waits for the account's engine and reaches it. An edit
    /// made against the screen's placeholder preferences is never written over the account's,
    /// even once the engine runs, until the screen has read the engine's.
    func testCommandsWaitForTheAccountsEngine() async throws {
        let engine = RecordingBackend()
        let router = BackupBackendRouter(route: .preparing)
        let request = photo
        let command = Task { try await router.enqueue([request]) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(engine.calls.isEmpty, "Nothing is sent while the account's backup is prepared.")
        let edit = TransferPreferences()
        do {
            try await router.setPreferences(edit)
            XCTFail("An edit made while the account's backup is prepared isn't written.")
        } catch { XCTAssertTrue(error is StalePreferencesEdit) }
        let shown = try await router.preferences()
        XCTAssertNil(shown, "No preferences are shown until the account's are known.")

        router.use(engine)
        let result = try await command.value
        XCTAssertEqual(result, .queued(1))
        do {
            try await router.setPreferences(edit)
            XCTFail("An edit made before the screen read the engine's preferences isn't written.")
        } catch { XCTAssertTrue(error is StalePreferencesEdit) }
        XCTAssertEqual(engine.calls, ["enqueue(1)"], "The waiting command reaches the engine; the edits made meanwhile don't.")
        _ = try await router.preferences()
        try await router.setPreferences(edit)
        XCTAssertEqual(engine.calls, ["enqueue(1)", "setPreferences"], "Once the screen read them, its edits are written.")

        // The account's backup can't start until the app reopens: a command is refused, saying so.
        router.waitForNextLaunch(TransferHost.nextLaunchMessage)
        do {
            _ = try await router.enqueue([request])
            XCTFail("A command is refused while the account's backup waits for the next launch.")
        } catch { XCTAssertEqual(error.localizedDescription, TransferHost.nextLaunchMessage) }
        // Nobody is signed in.
        router.deactivate()
        do {
            try await router.setIntent(.manual)
            XCTFail("A command is refused while no backup runs.")
        } catch { XCTAssertEqual(error.localizedDescription, AccountRestriction.signedOut.backupMessage) }
        XCTAssertEqual(engine.calls, ["enqueue(1)", "setPreferences"])
    }

    /// The same moment, on the backup screen: an edit made on the placeholder whose write comes
    /// once the engine runs is not written over the account's preferences, which then show.
    func testAnEditMadeWhileBackupIsPreparedNeverOverwritesTheAccountsPreferences() async throws {
        let engine = RecordingBackend()
        var imported = TransferPreferences()
        imported.includedAlbums = ["imported-album"]
        imported.automatic = true
        engine.storedPreferences = imported
        let router = BackupBackendRouter(route: .preparing)
        let store = BackupStore(backend: router, photos: .unavailable, debounce: .milliseconds(300))
        await untilTransfers("The screen says backup is being prepared.") { store.activity == "Preparing backup" }
        store.preferences.cellularVideos = true
        store.preferencesChanged()

        router.use(engine)
        await untilTransfers("The engine's snapshot shows.") { store.confirmed == 3 }
        await untilTransfers("The account's preferences show.") { store.preferences == imported }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(engine.calls.contains("setPreferences"), "The edit made on the placeholder isn't written over them.")
        XCTAssertNil(store.error)
    }

    /// iOS turning automatic backup's background windows down shows on the backup screen, as the
    /// old backup's refusal did, unless the engine has a message of its own.
    func testTheBackupScreenShowsWhenIOSRefusesAutomaticBackupsWindows() async throws {
        let engine = RecordingBackend()
        let router = BackupBackendRouter(route: .preparing)
        let log = SnapshotLog(await router.snapshots())
        defer { log.stop() }
        await untilTransfers("The screen says backup is being prepared.") { log.last?.activity == "Preparing backup" }

        router.use(engine)
        await untilTransfers("The engine's snapshot shows.") { log.last?.confirmed == 3 }
        XCTAssertNil(log.last?.lastMessage)
        let refusal = "iOS could not schedule automatic backup: Background App Refresh is off. You can still use Back up now."
        router.schedulingErrorChanged(refusal)
        await untilTransfers("The refusal shows.") { log.last?.lastMessage == refusal }
        engine.send(RecordingBackend.snapshot(lastMessage: "The server rejected IMG_0001.HEIC."))
        await untilTransfers("The engine's own message comes first.") { log.last?.lastMessage == "The server rejected IMG_0001.HEIC." }
        engine.send(RecordingBackend.snapshot(lastMessage: nil))
        await untilTransfers("The refusal shows again.") { log.last?.lastMessage == refusal }
        router.schedulingErrorChanged(nil)
        await untilTransfers("iOS took the request again.") { log.last?.lastMessage == nil }
    }

    /// The backup screens follow the account whose backup runs (the critic's correction to B8): as
    /// one account signs out and another signs in without a relaunch, they show the first
    /// account's engine, then nothing, then the second's, with no screen asking.
    func testTheScreensFollowEachAccountsEngineAcrossASignIn() async throws {
        let alice = RecordingBackend(), bob = RecordingBackend()
        alice.confirmed = 3
        bob.confirmed = 1
        var bobs = TransferPreferences()
        bobs.triggerDelay = 300
        bob.storedPreferences = bobs
        let router = BackupBackendRouter(route: .preparing)
        let store = BackupStore(backend: router, photos: .unavailable, debounce: .zero)
        router.use(alice)
        await untilTransfers("The screens show Alice's backup.") { store.confirmed == 3 }

        router.deactivate()
        await untilTransfers("Signing out empties the screens.") { store.confirmed == 0 }
        router.prepare()
        router.use(bob)
        await untilTransfers("The screens show Bob's backup.") { store.confirmed == 1 && store.preferences.triggerDelay == 300 }
        XCTAssertTrue(alice.calls.isEmpty && bob.calls.isEmpty, "Nothing was sent to either engine.")
    }

    /// The Shared files sheet over the engine's share lane: a file that failed shows its error,
    /// one that uploaded counts, and one that Pause upload stopped stays in the inbox and doesn't.
    func testThePausedFilesOfASharedUploadDontCountAsUploaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareSheet-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["first", "second", "third"]
        for name in names { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        let batch = SharedBatch(id: id, createdAt: Date(), attachments: names.map {
            SharedAttachment(original: SharedFile(name: $0, filename: "IMG_\($0).JPG", contentType: "image/jpeg", folder: folder))
        })
        let repository = ShareInboxRepository(root: root)
        try await repository.save(batch)
        let inbox = ShareInboxStore(repository: repository)
        await inbox.refresh()
        let attachments = batch.attachments.map(\.id)
        func item(_ attachment: String, failed: Bool = false) -> TransferQueueItem {
            TransferQueueItem(source: .shared(batch: id, attachment: attachment), state: failed ? .failed : .queued, seq: 0, displayName: nil,
                              message: failed ? "The server rejected it." : nil, failedAt: nil)
        }
        let engine = RecordingBackend()
        engine.sharePage = [item(attachments[0]), item(attachments[1]), item(attachments[2], failed: true)]
        let router = BackupBackendRouter(route: .engine(engine))
        let api = try APIClient(baseURL: URL(string: "https://photos.example/api")!, accessToken: "token", userID: "owner", networkConfiguration: .init())
        let model = ShareInboxModel(api: api, inbox: inbox, backend: router)
        await untilTransfers("The sheet reads the share lane.") { model.isRunning }
        XCTAssertEqual(model.errors, [attachments[2]: "The server rejected it."], "A failed file shows its error, from the share lane.")

        engine.sharePage = [item(attachments[1]), item(attachments[2], failed: true)]
        engine.send(RecordingBackend.snapshot(lastMessage: nil))
        await untilTransfers("The first file uploaded.") { model.completed == 1 }

        await model.pause()
        XCTAssertEqual(engine.calls, ["cancel"])
        engine.sharePage = [item(attachments[2], failed: true)]
        engine.send(RecordingBackend.snapshot(lastMessage: nil))
        await untilTransfers("Nothing uploads.") { !model.isRunning }
        XCTAssertEqual(model.completed, 1, "The paused file stays in the inbox and isn't counted as uploaded.")
        await api.shutdown()
    }
}

/// Every snapshot a stream sends, as it sends them.
@MainActor final class SnapshotLog {
    private(set) var values: [TransferSnapshot] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<TransferSnapshot>) {
        task = Task { [weak self] in
            for await value in stream { self?.values.append(value) }
        }
    }

    var last: TransferSnapshot? { values.last }

    func stop() { task?.cancel() }
}

/// A backend that records the commands reaching it and sends the snapshots a test gives it.
@MainActor final class RecordingBackend: TransferControlling {
    private(set) var calls: [String] = []
    var sharePage: [TransferQueueItem] = []
    var storedPreferences: TransferPreferences?
    /// The confirmed count its snapshots carry.
    var confirmed = 3
    private var continuations: [AsyncStream<TransferSnapshot>.Continuation] = []

    static func snapshot(lastMessage: String?, confirmed: Int = 3) -> TransferSnapshot {
        TransferSnapshot(intent: .automatic, phase: .idle, remaining: 0, confirmed: confirmed, failed: 0, fileProgress: nil, bytesSent: 0,
                         bytesExpected: 0, bytesPerSecond: nil, lastMessage: lastMessage)
    }

    /// Sends `snapshot` to every subscriber.
    func send(_ snapshot: TransferSnapshot) {
        for continuation in continuations { continuation.yield(snapshot) }
    }

    func setIntent(_ intent: RunIntent) async throws { calls.append("setIntent(\(intent))") }
    func enqueue(_ requests: [TransferRequest]) async throws -> EnqueueResult {
        calls.append("enqueue(\(requests.count))")
        return .queued(requests.count)
    }
    func cancel(_ sources: [TransferSource]) async throws { calls.append("cancel") }
    func setPreferences(_ preferences: TransferPreferences) async throws {
        calls.append("setPreferences")
        storedPreferences = preferences
    }
    func preferences() async throws -> TransferPreferences? { storedPreferences }
    func retry(_ sources: [TransferSource]?) async throws { calls.append("retry") }
    func snapshots() async -> AsyncStream<TransferSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: TransferSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        continuations.append(continuation)
        continuation.yield(Self.snapshot(lastMessage: nil, confirmed: confirmed))
        return stream
    }
    func queuePage(lane: TransferLane, after seq: Int64?, limit: Int) async throws -> [TransferQueueItem] { lane == .share ? sharePage : [] }
    func historyPage(offset: Int, limit: Int) async throws -> [TransferHistoryItem] { [] }
    func failures(limit: Int) async throws -> [TransferQueueItem] { [] }
    func albumUploadCounts() async throws -> [String: AlbumUploadCount] { [:] }
}

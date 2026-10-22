import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// The backup screens' store over typed commands (REBUILD_ROADMAP.md B8): each enqueue answers
/// for itself, preference edits are written once they settle and before any command, the album
/// chips count from the store, and today's coordinator reaches the store through
/// LegacyCoordinatorBackend without anything polling it.
@MainActor final class BackupStoreTests: XCTestCase {
    private typealias G = LegacyGoldens

    /// An enqueue's outcome is its own: the error the screen shows from an earlier run is never
    /// taken for it, and a refusal is this call's, not one shared with the screen.
    func testEnqueueReturnsItsOwnResult() async throws {
        let backend = FakeTransferBackend()
        backend.send(Self.snapshot(lastMessage: "Upload failed (HTTP 500). Retry after checking your server."))
        let store = BackupStore(backend: backend, photos: .unavailable, debounce: .zero)
        try await until("The store did not follow the backend.") { store.error != nil }

        backend.enqueueAnswer = .success(.queued(2))
        let queued = await store.enqueue(localIDs: ["a/L0/001", "b/L0/001"], albumID: "d4c3b2a1-0f9e-4d8c-b7a6-958473625140")
        XCTAssertEqual(queued, .queued, "An earlier run's error is not this call's.")
        XCTAssertEqual(backend.enqueued.last, [
            TransferRequest(source: .photo(DeviceAssetID(rawValue: "a/L0/001")), origin: .albumUpload, revision: nil,
                            album: "d4c3b2a1-0f9e-4d8c-b7a6-958473625140"),
            TransferRequest(source: .photo(DeviceAssetID(rawValue: "b/L0/001")), origin: .albumUpload, revision: nil,
                            album: "d4c3b2a1-0f9e-4d8c-b7a6-958473625140"),
        ])

        backend.enqueueAnswer = .success(.alreadyBackedUp(1))
        let backedUp = await store.enqueue(localIDs: ["a/L0/001"], albumID: nil)
        XCTAssertEqual(backedUp, .queued)
        XCTAssertEqual(backend.enqueued.last?.map(\.origin), [.selection])

        backend.enqueueAnswer = .failure(BackupError.message("Pause backup before adding selected photos."))
        let refused = await store.enqueue(localIDs: ["c/L0/001"], albumID: nil)
        XCTAssertEqual(refused, .failed("Pause backup before adding selected photos."))

        backend.enqueueAnswer = .success(.refused(.readOnly))
        let readOnly = await store.enqueue(localIDs: ["c/L0/001"], albumID: nil)
        XCTAssertEqual(readOnly, .failed(AccountRestriction.readOnly.backupMessage))
        XCTAssertEqual(store.error, "Upload failed (HTTP 500). Retry after checking your server.",
                       "The screen's error is still the backend's, untouched by the refusals.")
        backend.finish()
    }

    /// Edits are written once they pause, the last one only, and an edit still waiting is
    /// written before any command, so the command runs with what the screen shows.
    func testPreferencesWriteDebounced() async throws {
        let backend = FakeTransferBackend()
        backend.storedPreferences = TransferPreferences(Legacy.BackupPreferences())
        backend.send(Self.snapshot())
        let store = BackupStore(backend: backend, photos: .unavailable, debounce: .milliseconds(150))
        try await until("The store did not read the preferences.") { backend.calls.contains("preferences") }

        for delay in [30, 60, 90] {
            store.preferences.triggerDelay = delay
            store.preferencesChanged()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(backend.calls.contains("setPreferences"), "Nothing is written while edits keep coming.")
        try await until("The edits were not written.") { backend.calls.contains("setPreferences") }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(backend.written.map(\.triggerDelay), [90], "Only the last edit is written, once.")

        store.preferences.cellularVideos = true
        store.preferencesChanged()
        await store.start()
        XCTAssertEqual(backend.calls.suffix(2), ["setPreferences", "setIntent(manual)"], "A command writes the edit first.")
        XCTAssertEqual(backend.written.last?.cellularVideos, true)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(backend.written.count, 2, "The flushed edit is not written again.")

        // A preference the backend changes, as Pause switching automatic backup off, shows.
        var paused = try XCTUnwrap(backend.written.last)
        paused.automatic = false
        store.preferences.automatic = true
        store.preferencesChanged()
        await store.flushPreferences()
        backend.storedPreferences = paused
        backend.send(Self.snapshot())
        try await until("The backend's preferences did not show.") { store.preferences == paused }
        store.preferencesChanged()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(backend.written.count, 3, "Showing the backend's preferences writes nothing back.")
        backend.finish()
    }

    /// The album chips count from the store: today's backup and the transfers database's copy of
    /// it count the same photos waiting for each album, and the same that need retry.
    func testAlbumUploadCountsFromStore() async throws {
        let folder = temporaryDirectory().appendingPathComponent(AccountStoragePaths(G.account).backup, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FixtureLoader.data("backup/state-current.json").write(to: folder.appendingPathComponent("state.json"))
        let coordinator = BackupCoordinator()
        try coordinator.load(G.credential, folder: folder)
        let store = BackupStore(backend: LegacyCoordinatorBackend(coordinator: coordinator), photos: .unavailable, debounce: .zero)

        let expected = [G.serverAlbum: AlbumUploadCount(pending: 1, failed: 1), G.otherServerAlbum: AlbumUploadCount(pending: 1, failed: 1)]
        try await until("The store did not count the album uploads.") { store.albumUploads == expected }
        XCTAssertEqual(coordinator.pendingAlbumUploadCount(G.serverAlbum), 1)
        XCTAssertEqual(coordinator.failedAlbumUploadCount(G.serverAlbum), 1)

        let transfers = TransferStore(url: TransferStore.url(for: G.account, in: temporaryDirectory()))
        _ = await LegacyBackupImporter(mode: .shadow, store: transfers, folder: folder).run()
        let imported = try await transfers.albumUploadCounts()
        XCTAssertEqual(imported, expected, "The transfer engine counts as today's backup does.")
        await transfers.close()
    }

    /// Today's coordinator reaches the store as it changes, with no polling: its counts, its
    /// failures and preferences, and an upload's progress the session reports.
    func testLegacyBackendFollowsTheCoordinatorWithoutPolling() async throws {
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FixtureLoader.data("backup/state-current.json").write(to: folder.appendingPathComponent("state.json"))
        let coordinator = BackupCoordinator()
        let backend = LegacyCoordinatorBackend(coordinator: coordinator)
        let store = BackupStore(backend: backend, photos: .unavailable, debounce: .zero)
        try await until("The store did not start from the coordinator.") { store.snapshot.activity != nil }
        XCTAssertEqual(store.confirmed, 0)

        try coordinator.load(G.credential, folder: folder)
        try await until("Taking up the account did not reach the store.") { store.confirmed == 3 }
        XCTAssertEqual(store.remaining, 3)
        XCTAssertEqual(store.snapshot.failed, 1)
        XCTAssertEqual(store.error, ServerFailure.sessionExpired(nil).localizedDescription)
        XCTAssertEqual(store.failures.map(\.displayName), ["IMG_0003.HEIC"])
        XCTAssertEqual(store.preferences.triggerDelay, 120)
        XCTAssertFalse(store.isRunning)

        // The queue and the confirmed uploads, a page at a time.
        let first = try await backend.queuePage(lane: .library, after: nil, limit: 2)
        XCTAssertEqual(first.map(\.source), [.photo(DeviceAssetID(rawValue: G.l1)), .photo(DeviceAssetID(rawValue: G.l3))])
        XCTAssertEqual(first.map(\.state), [.queued, .failed])
        XCTAssertEqual(first.last?.message, "The photo uploaded but could not be added to the selected album. Check album permissions and retry.")
        let rest = try await backend.queuePage(lane: .library, after: first.last?.seq, limit: 2)
        XCTAssertEqual(rest.map(\.source), [.photo(DeviceAssetID(rawValue: G.l6))])
        let history = try await backend.historyPage(offset: 0, limit: 10)
        XCTAssertEqual(history.map(\.localID.rawValue), Self.confirmedOrder(coordinator.associations))
        let later = try await backend.historyPage(offset: 1, limit: 10)
        XCTAssertEqual(later.map(\.localID.rawValue), history.dropFirst().map(\.localID.rawValue))

        // Progress, as the backup session reports it, appears only while backup runs.
        coordinator.applyProgress(UploadProgressSnapshot(taskID: 7, sent: 512, expected: 1_024))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.snapshot.bytesSent, 0, "Nothing is sending while backup is paused.")

        // An edit made on the screen reaches the coordinator, and its file.
        store.preferences.triggerDelay = 300
        store.preferencesChanged()
        await store.flushPreferences()
        XCTAssertEqual(coordinator.preferences.triggerDelay, 300)
        let saved = try JSONDecoder().decode(BackupState.self, from: Data(contentsOf: folder.appendingPathComponent("state.json")))
        XCTAssertEqual(saved.preferences.triggerDelay, 300)
    }

    // MARK: Support

    private static func snapshot(lastMessage: String? = nil) -> TransferSnapshot {
        TransferSnapshot(intent: .paused, phase: .idle, remaining: 0, confirmed: 0, failed: 0, fileProgress: nil, bytesSent: 0,
                         bytesExpected: 0, bytesPerSecond: nil, lastMessage: lastMessage)
    }

    private static func confirmedOrder(_ receipts: [String: BackupReceipt]) -> [String] {
        receipts.sorted {
            let left = $0.value.confirmedAt ?? .distantPast, right = $1.value.confirmedAt ?? .distantPast
            return left == right ? $0.key < $1.key : left > right
        }.map(\.key)
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupStoreTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func until(_ message: String, timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A backend that records the commands it is sent and answers as the test sets.
@MainActor private final class FakeTransferBackend: TransferControlling {
    var calls: [String] = []
    var enqueued: [[TransferRequest]] = []
    var written: [TransferPreferences] = []
    var enqueueAnswer: Result<EnqueueResult, any Error> = .success(.queued(0))
    var storedPreferences: TransferPreferences?
    private let stream: AsyncStream<TransferSnapshot>
    private let continuation: AsyncStream<TransferSnapshot>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream(of: TransferSnapshot.self, bufferingPolicy: .bufferingNewest(1)) }

    func send(_ snapshot: TransferSnapshot) { continuation.yield(snapshot) }
    func finish() { continuation.finish() }

    func setIntent(_ intent: RunIntent) async throws { calls.append("setIntent(\(intent.rawValue))") }
    func enqueue(_ requests: [TransferRequest]) async throws -> EnqueueResult {
        calls.append("enqueue")
        enqueued.append(requests)
        return try enqueueAnswer.get()
    }
    func cancel(_ sources: [TransferSource]) async throws { calls.append("cancel") }
    func setPreferences(_ preferences: TransferPreferences) async throws {
        calls.append("setPreferences")
        written.append(preferences)
        storedPreferences = preferences
    }
    func preferences() async throws -> TransferPreferences? {
        calls.append("preferences")
        return storedPreferences
    }
    func retry(_ sources: [TransferSource]?) async throws { calls.append("retry") }
    func snapshots() async -> AsyncStream<TransferSnapshot> { stream }
    func queuePage(lane: TransferLane, after seq: Int64?, limit: Int) async throws -> [TransferQueueItem] { [] }
    func historyPage(offset: Int, limit: Int) async throws -> [TransferHistoryItem] { [] }
    func failures(limit: Int) async throws -> [TransferQueueItem] { [] }
    func albumUploadCounts() async throws -> [String: AlbumUploadCount] { [:] }
}

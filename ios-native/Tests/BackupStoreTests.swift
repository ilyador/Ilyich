import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// The backup screens' store over typed commands (REBUILD_ROADMAP.md B8): each enqueue answers
/// for itself, preference edits are written once they settle and before any command, and the
/// album chips count from the store.
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
        backend.storedPreferences = TransferPreferences()
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

    /// The album chips count from the store: the photos waiting for each album, and how many of
    /// them need a retry, as the transfers database counts them.
    func testAlbumUploadCountsFromStore() async throws {
        let transfers = TransferStore(url: TransferStore.url(for: G.account, in: temporaryDirectory()))
        var seed = TransferSeed()
        seed.jobs = [.init(localID: G.l1),
                     .init(localID: G.l3, state: .failed, failure: .init(message: "The server refused this file.", date: G.Dates.failure,
                                                                         filename: "IMG_0003.HEIC"))]
        seed.destinations = [(G.l3, G.serverAlbum, nil), (G.l3, G.otherServerAlbum, nil), (G.l1, G.serverAlbum, nil)]
        try await transfers.seedForTest(seed)
        let counts = try await transfers.albumUploadCounts()
        let expected = [G.serverAlbum: AlbumUploadCount(pending: 2, failed: 1), G.otherServerAlbum: AlbumUploadCount(pending: 1, failed: 1)]
        XCTAssertEqual(counts, expected)
        await transfers.close()

        let backend = FakeTransferBackend()
        backend.counts = counts
        backend.send(Self.snapshot())
        let store = BackupStore(backend: backend, photos: .unavailable, debounce: .zero)
        try await until("The store did not count the album uploads.") { store.albumUploads == expected }
        backend.finish()
    }

    // MARK: Support

    private static func snapshot(lastMessage: String? = nil) -> TransferSnapshot {
        TransferSnapshot(intent: .paused, phase: .idle, remaining: 0, confirmed: 0, failed: 0, fileProgress: nil, bytesSent: 0,
                         bytesExpected: 0, bytesPerSecond: nil, lastMessage: lastMessage)
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
    var counts: [String: AlbumUploadCount] = [:]
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
    func albumUploadCounts() async throws -> [String: AlbumUploadCount] { counts }
}

import Foundation
import Photos
import Synchronization
import XCTest
@testable import Ilyich

/// The device index (REBUILD_ROADMAP.md P5): phone photos are read once and then only as Photos
/// names them, fingerprints live in device.sqlite after the legacy files are imported, and only
/// server photos the timeline shows can claim a phone photo.
final class DeviceIndexServiceTests: XCTestCase {
    private let album = "album"
    private let taken = Date(timeIntervalSinceReferenceDate: 790_000_000)

    func testSingleAssetChangeRereadsOnlyThatAsset() async throws {
        let photos = FakeIndexReader()
        for (offset, id) in ["a", "b", "c"].enumerated() { photos.add(item(id, offset: offset), in: album) }
        let service = makeService(photos: photos, server: FakeIndexServer(rows: []))
        let snapshots = listen(await service.snapshots())

        try await until("The phone photos did not show.") { snapshots.last?.items.count == 3 }
        XCTAssertEqual(photos.reads.sorted(), ["a", "b", "c"])
        XCTAssertEqual(snapshots.last?.timeline.localOnly.values.joined().count, 3)

        photos.reads = []
        photos.add(item("b", offset: 1, favorite: true), in: album)
        photos.emit(changed: ["b"], albumsChanged: true)
        try await until("The favorite did not show.") { snapshots.last?.items["b"]?.photo.isFavorite == true }
        XCTAssertEqual(photos.reads, ["b"], "Only the asset Photos named is read again.")

        photos.reads = []
        photos.add(item("d", offset: 3), in: album)
        photos.emit(inserted: ["d"])
        try await until("The new photo did not show.") { snapshots.last?.items["d"] != nil }
        XCTAssertEqual(photos.reads, ["d"])

        photos.reads = []
        photos.remove("a")
        photos.emit(removed: ["a"])
        try await until("The removed photo stayed.") { snapshots.last?.items["a"] == nil }
        XCTAssertEqual(photos.reads, ["a"], "A removal is checked with Photos, nothing else is read.")
        await service.shutdown()
    }

    func testLegacyFingerprintCacheIsImportedAndNotRehashed() async throws {
        let caches = temporaryDirectory()
        let folder = caches.appendingPathComponent("IlyichFingerprints", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = item("a", offset: 0), b = item("b", offset: 1), c = item("c", offset: 2)
        // As LocalFingerprintCache wrote it: one file per account, JSONEncoder's defaults.
        let legacy: [String: Legacy.Fingerprint] = [
            "a": .init(modified: a.photo.modified, checksum: "hash-a"),
            "c": .init(modified: c.photo.modified, checksum: "hash-c"),
        ]
        try JSONEncoder().encode(legacy).write(to: folder.appendingPathComponent(Legacy.sha256("server|alice") + ".json"))

        let photos = FakeIndexReader()
        for value in [a, b, c] { photos.add(value, in: album) }
        photos.checksums = ["a": "hash-a", "b": "hash-b", "c": "hash-c"]
        let server = FakeIndexServer(rows: [match("server-a", checksum: "hash-a"), match("server-b", checksum: "hash-b")])
        let database = DeviceDatabase(url: temporaryDirectory().appendingPathComponent("device.sqlite"))
        let service = makeService(photos: photos, server: server, database: database, legacy: folder)
        let snapshots = listen(await service.snapshots())

        try await until("The phone photos were not matched.") {
            snapshots.last?.associations == ["a": "server-a", "b": "server-b"]
        }
        XCTAssertEqual(photos.hashed, ["b"], "Only the photo without a fingerprint is hashed.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "The imported file is deleted.")
        XCTAssertEqual(snapshots.last?.timeline.localOnly.values.joined().map(\.id), ["c"])
        await service.shutdown()
        let kept = try await database.fingerprints()
        XCTAssertEqual(kept.mapValues(\.checksum), ["a": "hash-a", "b": "hash-b", "c": "hash-c"])

        // The next launch hashes nothing.
        let next = FakeIndexReader()
        for value in [a, b, c] { next.add(value, in: album) }
        next.checksums = photos.checksums
        let relaunched = makeService(photos: next, server: server, database: database, legacy: folder)
        let again = listen(await relaunched.snapshots())
        try await until("The relaunch did not match.") { again.last?.associations == ["a": "server-a", "b": "server-b"] }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(next.hashed, [])
        await relaunched.shutdown()
    }

    func testPhoneCopyOfTrashedServerAssetStaysVisibleAsLocal() async throws {
        let entities = try LibraryIndex(scope: "server|alice", userID: "alice", directory: temporaryDirectory())
        _ = try await entities.prepare(sessionFingerprint: "session")
        _ = try await entities.apply([
            serverAsset("kept", checksum: "hash-kept"),
            serverAsset("trashed", checksum: "hash-trashed", deleted: true),
            serverAsset("archived", checksum: "hash-archived", visibility: "archive"),
            SyncEvents.complete(),
        ], epoch: entities.epoch())

        let photos = FakeIndexReader()
        for (offset, id) in ["kept", "trashed", "archived"].enumerated() { photos.add(item("phone-" + id, offset: offset), in: album) }
        photos.checksums = ["phone-kept": "hash-kept", "phone-trashed": "hash-trashed", "phone-archived": "hash-archived"]
        let server = LibraryIndexIdentities(entities: entities, libraryChanges: { AsyncStream { _ in } })
        let service = makeService(photos: photos, server: server)
        let snapshots = listen(await service.snapshots())

        try await until("The phone photos were not hashed.") { photos.hashed.count == 3 && snapshots.last?.associations.isEmpty == false }
        try await Task.sleep(for: .milliseconds(100))
        let snapshot = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(snapshot.associations, ["phone-kept": "kept"])
        XCTAssertEqual(Set(snapshot.timeline.localOnly.values.joined().map(\.id)), ["phone-trashed", "phone-archived"],
                       "A phone copy of a trashed or archived photo shows as a phone photo.")
        XCTAssertEqual(Set(snapshot.device().months.values.flatMap(\.assets).map(\.id.rawValue)), ["phone-trashed", "phone-archived"])
        await service.shutdown()
    }

    /// Receipts match first, then cloud identity for an unedited photo, as DeviceTimelineIndex did;
    /// a receipt for an older revision doesn't.
    func testReceiptsAndCloudIdentityMatchAsBefore() async throws {
        let photos = FakeIndexReader()
        let uploaded = item("uploaded", offset: 0), edited = item("edited", offset: 1)
        let cloud = DeviceTimelineItem(photo: LocalPhoto(id: "cloud", date: taken, modified: taken, latitude: 1, longitude: 2),
                                       cloudID: "cloud-1", unadjusted: true)
        for value in [uploaded, edited, cloud] { photos.add(value, in: album) }
        let server = FakeIndexServer(rows: [match("server-uploaded", checksum: "u"), match("server-edited", checksum: "e"),
                                            match("server-cloud", checksum: "c", cloudID: "cloud-1", createdAt: taken, latitude: 1, longitude: 2)])
        func receipt(_ value: DeviceTimelineItem, _ remote: String, _ checksum: String, revision: Double) -> CleanupReceipt {
            CleanupReceipt(localID: value.photo.id, revision: AssetRevision(referenceSeconds: revision),
                           original: .init(id: remote, checksum: checksum), motion: nil)
        }
        let backup = FakeBackupSource(DeviceIndexBackupInputs(included: [album], receipts: [
            "uploaded": receipt(uploaded, "server-uploaded", "u", revision: uploaded.photo.modified!.timeIntervalSinceReferenceDate),
            "edited": receipt(edited, "server-edited", "e", revision: 1),
        ]))
        photos.failing = true
        let service = makeService(photos: photos, server: server, backup: backup)
        let snapshots = listen(await service.snapshots())
        try await until("Nothing was matched.") { snapshots.last?.associations == ["uploaded": "server-uploaded", "cloud": "server-cloud"] }
        XCTAssertEqual(snapshots.last?.timeline.remoteToLocal["server-uploaded"]?.id, "uploaded")
        XCTAssertEqual(snapshots.last?.timeline.localOnly.values.joined().map(\.id), ["edited"])

        // Backup's albums changing drops what left them.
        backup.inputs = DeviceIndexBackupInputs(included: [], receipts: [:])
        try await until("Leaving every album did not empty the phone's photos.") { snapshots.last?.items.isEmpty == true }
        await service.shutdown()
    }

    func testNothingIsReadInTheBackground() async throws {
        let photos = FakeIndexReader()
        photos.add(item("a", offset: 0), in: album)
        let presence = AppPresence(isForeground: false)
        let service = makeService(photos: photos, server: nil, presence: presence)
        let snapshots = listen(await service.snapshots())
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(photos.reads, [])
        presence.isForeground = true
        await service.presenceChanged()
        try await until("The phone photos did not show once in front.") { snapshots.last?.items.count == 1 }
        await service.shutdown()
    }

    func testAJournalOnlyDatabaseGainsFingerprintsAndKeepsItsEntries() async throws {
        let url = temporaryDirectory().appendingPathComponent("device.sqlite")
        do {
            let old = try DeviceSQLite(url: url)
            try old.execute("""
                CREATE TABLE device_mutation(id TEXT PRIMARY KEY,account_digest TEXT,kind TEXT NOT NULL,origin TEXT NOT NULL,\
                asset_ids TEXT NOT NULL,expected_revisions TEXT NOT NULL,created_at REAL NOT NULL,finished_at REAL,outcome TEXT,detail TEXT)
                """)
            try old.execute(#"INSERT INTO device_mutation(id,kind,origin,asset_ids,expected_revisions,created_at) VALUES('0E9A1F3C-5B7D-4E2F-8A6C-1B3D5F7A9C2E','favorite','{"kind":"user"}','["A"]','{}',1)"#)
            try old.execute("PRAGMA user_version=1")
        }
        let database = DeviceDatabase(url: url)
        try await database.saveFingerprints(["A": DeviceFingerprint(revision: 2.5, checksum: "x")])
        let records = try await database.records()
        XCTAssertEqual(records.count, 1)
        let fingerprints = try await database.fingerprints()
        XCTAssertEqual(fingerprints, ["A": DeviceFingerprint(revision: 2.5, checksum: "x")])
        XCTAssertEqual(try DeviceSQLite(url: url).query("PRAGMA user_version").first?.first, .real(2))
    }

    // MARK: - Support

    private func makeService(photos: FakeIndexReader, server: (any DeviceIndexServer)?, backup: FakeBackupSource? = nil,
                             database: DeviceDatabase? = nil, legacy: URL? = nil,
                             presence: AppPresence = AppPresence(isForeground: true)) -> DeviceIndexService {
        DeviceIndexService(account: "digest", reader: photos, server: server,
                           backup: backup ?? FakeBackupSource(DeviceIndexBackupInputs(included: [album])),
                           database: database ?? DeviceDatabase(url: temporaryDirectory().appendingPathComponent("device.sqlite")),
                           legacyFingerprints: legacy, presence: presence, pause: .zero, coalescing: .zero, powerAllowsHashing: { true })
    }

    private func item(_ id: String, offset: Int, favorite: Bool = false) -> DeviceTimelineItem {
        let date = taken.addingTimeInterval(Double(offset) * 60)
        return DeviceTimelineItem(photo: LocalPhoto(id: id, date: date, modified: date.addingTimeInterval(0.25), isFavorite: favorite),
                                  cloudID: nil, unadjusted: false, shape: .singleOriginal, canDelete: true, canEditProperties: true)
    }

    private func match(_ id: String, checksum: String, cloudID: String? = nil, createdAt: Date? = nil,
                       latitude: Double? = nil, longitude: Double? = nil) -> LocalAssetMatch {
        LocalAssetMatch(assetID: id, checksum: checksum, cloudID: cloudID, createdAt: createdAt, adjustmentTime: nil,
                        latitude: latitude, longitude: longitude)
    }

    private func serverAsset(_ id: String, checksum: String, visibility: String = "timeline", deleted: Bool = false) -> EntitySyncEvent {
        SyncEvents.event("AssetV2", """
        {"id":"\(id)","ownerId":"alice","type":"IMAGE","originalFileName":"\(id).jpg","checksum":"\(checksum)","fileCreatedAt":"2026-02-01T05:00:00Z","localDateTime":"2026-02-01T05:00:00Z","createdAt":"2026-03-01T00:00:00Z","visibility":"\(visibility)","isFavorite":false,"deletedAt":\(deleted ? "\"2026-03-04T00:00:00Z\"" : "null"),"stackId":null,"isEdited":false,"isDeveloped":false,"mediaRevision":"r1"}
        """, ack: "AssetV2|\(id)")
    }

    private func listen(_ stream: AsyncStream<DeviceIndexSnapshot>) -> Heard {
        let heard = Heard()
        let task = Task { for await snapshot in stream { heard.append(snapshot) } }
        addTeardownBlock { task.cancel() }
        return heard
    }

    private func temporaryDirectory() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceIndexServiceTests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func until(_ message: String, within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
        throw CancellationError()
    }
}

/// The snapshots a test heard.
private final class Heard: Sendable {
    private let values = Mutex<[DeviceIndexSnapshot]>([])
    func append(_ value: DeviceIndexSnapshot) { values.withLock { $0.append(value) } }
    var last: DeviceIndexSnapshot? { values.withLock { $0.last } }
}

/// Photos as the device index reads it.
private final class FakeIndexReader: DeviceIndexReading {
    private struct State {
        var items: [String: DeviceTimelineItem] = [:]
        var albums: [String: Set<String>] = [:]
        var checksums: [String: String] = [:]
        var reads: [String] = []
        var hashed: [String] = []
        var failing = false
        var continuations: [AsyncStream<DeviceLibraryChange>.Continuation] = []
    }
    private let state = Mutex(State())
    private let accessValue = DeviceAccess(status: .authorized, generation: 1)

    func add(_ item: DeviceTimelineItem, in album: String) {
        state.withLock { $0.items[item.photo.id] = item; $0.albums[album, default: []].insert(item.photo.id) }
    }
    func remove(_ id: String) {
        state.withLock { state in
            state.items[id] = nil
            for key in state.albums.keys { state.albums[key]?.remove(id) }
        }
    }
    var reads: [String] {
        get { state.withLock { $0.reads } }
        set { state.withLock { $0.reads = newValue } }
    }
    var hashed: [String] { state.withLock { $0.hashed } }
    var checksums: [String: String] {
        get { state.withLock { $0.checksums } }
        set { state.withLock { $0.checksums = newValue } }
    }
    /// Hashing fails, as for a photo only in iCloud.
    var failing: Bool {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }

    func emit(inserted: Set<String> = [], removed: Set<String> = [], changed: Set<String> = [], albumsChanged: Bool = false) {
        var change = DeviceLibraryChange(access: accessValue)
        change.inserted = Set(inserted.map(DeviceAssetID.init(rawValue:)))
        change.removed = Set(removed.map(DeviceAssetID.init(rawValue:)))
        change.changed = Set(changed.map(DeviceAssetID.init(rawValue:)))
        change.albumsChanged = albumsChanged
        for continuation in state.withLock({ $0.continuations }) { continuation.yield(change) }
    }

    func access() async -> DeviceAccess { accessValue }
    func changes() -> AsyncStream<DeviceLibraryChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceLibraryChange.self)
        state.withLock { $0.continuations.append(continuation) }
        return stream
    }
    func members(included: Set<String>, excluded: Set<String>) async throws -> Set<String> {
        state.withLock { state in
            included.reduce(into: Set<String>()) { $0.formUnion(state.albums[$1] ?? []) }
                .subtracting(excluded.reduce(into: Set<String>()) { $0.formUnion(state.albums[$1] ?? []) })
        }
    }
    func items(_ ids: [String]) async throws -> [DeviceTimelineItem] {
        state.withLock { state in
            state.reads += ids
            return ids.compactMap { state.items[$0] }
        }
    }
    func fingerprint(of id: String) async throws -> String {
        try state.withLock { state in
            state.hashed.append(id)
            guard !state.failing, let checksum = state.checksums[id] else { throw CocoaError(.fileReadNoSuchFile) }
            return checksum
        }
    }
    func revision(of id: String) async -> Date? { state.withLock { $0.items[id]?.photo.modified } }
}

private struct FakeIndexServer: DeviceIndexServer {
    let rows: [LocalAssetMatch]
    func identities() async throws -> [LocalAssetMatch]? { rows }
    func changes() async -> AsyncStream<LibraryChange> { AsyncStream { _ in } }
}

private final class FakeBackupSource: DeviceIndexBackupSource {
    private let state: Mutex<(inputs: DeviceIndexBackupInputs, continuations: [AsyncStream<Void>.Continuation])>

    init(_ inputs: DeviceIndexBackupInputs) { state = Mutex((inputs, [])) }

    var inputs: DeviceIndexBackupInputs {
        get { state.withLock { $0.inputs } }
        set {
            let continuations = state.withLock { state in
                state.inputs = newValue
                return state.continuations
            }
            for continuation in continuations { continuation.yield() }
        }
    }

    func inputs(account: String) async -> DeviceIndexBackupInputs? { inputs }
    func changes() async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        state.withLock { $0.continuations.append(continuation) }
        return stream
    }
}

import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import Ilyich

/// Library index v1 (Q2): the derived tables, kept by the writer with every sync batch and filled
/// by a resumable backfill for a library synced before they existed, and the readers that never
/// wait for the writer.
@MainActor final class LibraryIndexTests: XCTestCase {
    // MARK: - Migration and backfill

    /// The owner's library was synced by a build without the derived tables. Opening it migrates
    /// the file in place: entities, metadata, acknowledgements and queued purges stay byte for
    /// byte, nothing asks for a re-sync, and the backfill then fills the derived tables. A kill
    /// after any batch, with sync batches landing in between, resumes where it stopped and ends
    /// with the same rows as one uninterrupted pass.
    func testBackfillResumesAfterCrashAtEveryBatch() async throws {
        let (root, scope) = (temporaryDirectory(), "server|alice")
        let file = try Self.makePreQ2Library(in: root, scope: scope, assets: 10, albumMembers: 4, faces: 6)
        let entities = try Self.dump(file, "SELECT kind,id,payload FROM entities ORDER BY kind,id")
        let kept = { try Self.dump(file, "SELECT key,value FROM metadata ORDER BY key") + Self.dump(file, "SELECT type,ack FROM acknowledgements ORDER BY type")
            + Self.dump(file, "SELECT id,revoked FROM media_purges ORDER BY id") }
        let untouched = try kept()

        var store: LibraryIndex? = try LibraryIndex(scope: scope, userID: "alice", directory: root, backfillBatchSize: 3)
        XCTAssertEqual(try Self.dump(file, "PRAGMA user_version"), [["3"]])
        let needsReset = try await store!.prepare(sessionFingerprint: "session")
        XCTAssertFalse(needsReset, "The migration never asks the server to replay the library.")
        let complete = try await store!.isComplete()
        XCTAssertTrue(complete)
        let queryable = try await store!.isQueryable()
        XCTAssertFalse(queryable, "Until the backfill finishes the index is not queryable.")
        let statistics = try await store!.statistics()
        XCTAssertEqual(statistics.counts, ["asset": 10, "albumAsset": 4, "face": 6, "album": 1, "person": 1])
        XCTAssertEqual(try Self.dump(file, "SELECT kind,id,payload FROM entities ORDER BY kind,id"), entities, "Payloads stay byte for byte.")
        XCTAssertEqual(try kept(), untouched, "Metadata, acknowledgements and queued purges stay as they were.")

        // Batches of 3: assets 3+3+3+1, album members 3+1, faces 3+3 and the empty end.
        var steps = 0
        var more = true
        while more {
            // A kill: the next batch runs in a new process, on a new connection.
            store = nil
            store = try LibraryIndex(scope: scope, userID: "alice", directory: root, backfillBatchSize: 3)
            more = try await store!.writer.backfillStep()
            steps += 1
            if steps == 2 {
                // A sync batch between two backfill batches: one asset before the cursor, one after.
                _ = try await store!.apply([SyncEvents.asset("photo-00", revision: "r2"), SyncEvents.asset("photo-99")], epoch: store!.epoch())
            }
            XCTAssertLessThan(steps, 20, "The backfill ends.")
        }
        XCTAssertEqual(steps, 9)
        let done = try await store!.isQueryable()
        XCTAssertTrue(done)
        XCTAssertEqual(try Self.dump(file, "SELECT id FROM asset_index ORDER BY id"), ((0..<10).map { String(format: "photo-%02d", $0) } + ["photo-99"]).map { [$0] })
        XCTAssertEqual(try Self.dump(file, "SELECT count(*) FROM album_member"), [["4"]])
        XCTAssertEqual(try Self.dump(file, "SELECT count(*) FROM person_member"), [["5"]], "A hidden face is not a member.")
        let resumed = try Self.derived(file)
        let onePass = try await Self.rebuilt(file, store!)
        XCTAssertEqual(resumed, onePass, "Resuming after every batch gives the rows of one pass.")

        // What the build before Q2 wrote is still there, apart from the rows of the sync batch.
        XCTAssertEqual(try Self.dump(file, "SELECT kind,id,payload FROM entities WHERE id NOT IN ('photo-00','photo-99') ORDER BY kind,id"),
                       entities.filter { $0[1] != "photo-00" })

        // Started as the app starts it, an unfinished backfill runs to its end on its own.
        try Self.execute(file, "UPDATE index_state SET backfill_kind='albumAsset',backfill_cursor=NULL,queryable=0")
        store = try LibraryIndex(scope: scope, userID: "alice", directory: root, backfillBatchSize: 3)
        store!.startBackfill(after: .zero, pause: .zero)
        await store!.backfillFinished()
        let finished = try await store!.isQueryable()
        XCTAssertTrue(finished)
    }

    /// A build before Q2, reinstalled over this one, syncs without keeping the derived tables. Its
    /// writes mark them stale, and the next open starts the backfill again, which drops the rows of
    /// what it deleted and adds what it wrote.
    func testAWriteByABuildWithoutTheIndexRestartsTheBackfill() async throws {
        let (store, file) = try makeStore()
        _ = try await store.prepare(sessionFingerprint: "session")
        _ = try await store.apply([SyncEvents.asset("kept"), SyncEvents.asset("deleted"), SyncEvents.complete()], epoch: store.epoch())
        try await Self.runBackfill(store)
        let state = try await store.writer.backfillState()
        XCTAssertEqual(state, .init(kind: nil, cursor: nil, queryable: true, stale: false, revision: state.revision))
        // Writing through this build never marks the index stale.
        try await store.acknowledged(["SyncCompleteV1|done"])
        try await store.markResetRequested()
        let unmarked = try await store.writer.backfillState()
        XCTAssertFalse(unmarked.stale)

        // The older build: an entity row and its acknowledgement, and a deletion.
        try Self.execute(file, """
        BEGIN;
        INSERT INTO entities(kind,id,payload) VALUES('asset','added','{"id":"added","ownerId":"alice","visibility":"timeline","localDateTime":"2026-01-01T00:00:00Z"}');
        DELETE FROM entities WHERE kind='asset' AND id='deleted';
        INSERT INTO acknowledgements(type,ack) VALUES('AssetV2','AssetV2|added') ON CONFLICT(type) DO UPDATE SET ack=excluded.ack;
        COMMIT;
        """)
        XCTAssertEqual(try Self.dump(file, "SELECT stale FROM index_state"), [["1"]])

        let reopened = try LibraryIndex(scope: store.scope, userID: "alice", directory: file.deletingLastPathComponent())
        let stale = try await reopened.isQueryable()
        XCTAssertFalse(stale, "Rows another build may have changed are not served.")
        try await Self.runBackfill(reopened)
        XCTAssertEqual(try Self.dump(file, "SELECT id FROM asset_index ORDER BY id"), [["added"], ["kept"]])
        let fresh = try await reopened.isQueryable()
        XCTAssertTrue(fresh)
    }

    /// A library at version 2 holds the months in the server's order. Opening it swaps only those
    /// indexes for ones in the order of the time taken (or added): the index stays queryable, and
    /// entities, metadata, acknowledgements, purges and derived rows stay byte for byte, so nothing
    /// syncs or fills again. A kill during the swap rolls it back and the next open does it again.
    func testVersion3SwapsTheMonthIndexesInPlace() async throws {
        let (store, file) = try makeStore()
        _ = try await store.prepare(sessionFingerprint: "session")
        try await store.markResetRequested()
        _ = try await store.apply([SyncEvents.asset("one"), SyncEvents.asset("two"), SyncEvents.complete()], epoch: store.epoch())
        try await Self.runBackfill(store)
        try Self.execute(file, """
        BEGIN;
        DROP INDEX asset_index_taken; DROP INDEX asset_index_added;
        CREATE INDEX asset_index_order ON asset_index(local_month,local_day,file_created_at,file_name,id);
        CREATE INDEX asset_index_created ON asset_index(created_month,created_at,file_created_at,file_name,id);
        PRAGMA user_version=2;
        COMMIT;
        """)
        let indexes = "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='asset_index' AND sql IS NOT NULL ORDER BY name"
        XCTAssertEqual(try Self.dump(file, indexes), [["asset_index_created"], ["asset_index_order"], ["asset_index_stack"]])
        let kept = {
            try ["SELECT kind,id,payload FROM entities ORDER BY kind,id", "SELECT key,value FROM metadata ORDER BY key",
                 "SELECT type,ack FROM acknowledgements ORDER BY type", "SELECT id,revoked FROM media_purges ORDER BY id",
                 "SELECT * FROM index_state", "SELECT * FROM asset_index ORDER BY id"].flatMap { try Self.dump(file, $0) }
        }
        let before = try kept()

        let reopened = try LibraryIndex(scope: store.scope, userID: "alice", directory: file.deletingLastPathComponent())
        XCTAssertEqual(try Self.dump(file, "PRAGMA user_version"), [["3"]])
        XCTAssertEqual(try Self.dump(file, indexes), [["asset_index_added"], ["asset_index_stack"], ["asset_index_taken"]])
        XCTAssertEqual(try kept(), before, "Only the indexes change.")
        let queryable = try await reopened.isQueryable()
        XCTAssertTrue(queryable, "Nothing fills again.")
        let needsReset = try await reopened.prepare(sessionFingerprint: "session")
        XCTAssertFalse(needsReset, "Nothing syncs again.")
    }

    // MARK: - Sync batches

    /// Each batch keeps the derived rows in its own transaction: assets, album members and the
    /// visible faces of people, through moves, deletions, locks and a server reset. A batch that
    /// fails leaves neither its entities nor their derived rows. A failure in the derived rows
    /// alone never stops sync: the batch commits and the index stops being queryable until the
    /// backfill has redone it.
    func testSyncBatchMaintainsDerivedRowsAtomically() async throws {
        let (store, file) = try makeStore()
        _ = try await store.prepare(sessionFingerprint: "session")
        let epoch = await store.epoch()
        _ = try await store.apply([
            SyncEvents.asset("one", taken: "2026-02-01T05:00:00Z"), SyncEvents.asset("two"), SyncEvents.asset("three"),
            SyncEvents.event("AlbumV2", #"{"id":"trip","ownerId":"alice","name":"Trip"}"#),
            SyncEvents.event("AlbumToAssetV1", #"{"albumId":"trip","assetId":"one"}"#, ack: "AlbumToAssetV1|1"),
            SyncEvents.event("AlbumToAssetV1", #"{"albumId":"trip","assetId":"two"}"#, ack: "AlbumToAssetV1|2"),
            SyncEvents.event("PersonV1", #"{"id":"maya","name":"Maya"}"#),
            SyncEvents.event("AssetFaceV3", #"{"id":"f1","assetId":"one","personId":"maya","isVisible":true,"deletedAt":null}"#, ack: "AssetFaceV3|1"),
            SyncEvents.event("AssetFaceV3", #"{"id":"f2","assetId":"two","personId":"maya","isVisible":true,"deletedAt":null}"#, ack: "AssetFaceV3|2"),
        ], epoch: epoch)
        XCTAssertEqual(try Self.dump(file, "SELECT id,local_month,local_day,file_name,owner_id,visibility,trashed FROM asset_index WHERE id='one'"),
                       [["one", "2026-02", "2026-02-01", "one.jpg", "alice", "timeline", "0"]])
        XCTAssertEqual(try Self.dump(file, "SELECT album_id,asset_id FROM album_member ORDER BY asset_id"), [["trip", "one"], ["trip", "two"]])
        XCTAssertEqual(try Self.dump(file, "SELECT person_id,asset_id FROM person_member ORDER BY asset_id"), [["maya", "one"], ["maya", "two"]])

        // Moved, deleted, locked, hidden from a person, taken out of an album.
        _ = try await store.apply([
            SyncEvents.asset("one", taken: "2025-12-24T05:00:00Z"),
            SyncEvents.event("AssetDeleteV1", #"{"assetId":"two"}"#, ack: "AssetDeleteV1|1"),
            SyncEvents.asset("three", visibility: "locked"),
            SyncEvents.event("AssetFaceV3", #"{"id":"f1","assetId":"one","personId":"maya","isVisible":false,"deletedAt":null}"#, ack: "AssetFaceV3|3"),
            SyncEvents.event("AlbumToAssetDeleteV1", #"{"albumId":"trip","assetId":"one"}"#, ack: "AlbumToAssetDeleteV1|1"),
        ], epoch: epoch)
        XCTAssertEqual(try Self.dump(file, "SELECT id,local_month FROM asset_index ORDER BY id"), [["one", "2025-12"]])
        XCTAssertEqual(try Self.dump(file, "SELECT count(*) FROM album_member"), [["0"]])
        XCTAssertEqual(try Self.dump(file, "SELECT count(*) FROM person_member"), [["0"]])
        XCTAssertEqual(try Self.dump(file, "SELECT id FROM locked_asset"), [["three"]])
        let kept = try Self.derived(file)
        let onePass = try await Self.rebuilt(file, store)
        XCTAssertEqual(kept, onePass, "The kept rows are the ones a full pass makes.")

        // A batch that fails leaves nothing behind, derived rows included.
        do {
            _ = try await store.apply([SyncEvents.asset("four"), SyncEvents.event("UnsupportedV99", "{}")], epoch: epoch)
            XCTFail("An unknown event fails the batch.")
        } catch is APIError {}
        XCTAssertEqual(try Self.dump(file, "SELECT count(*) FROM asset_index WHERE id='four'"), [["0"]])

        // The derived rows fail; the batch still commits.
        try Self.execute(file, "CREATE TRIGGER broken BEFORE INSERT ON asset_index BEGIN SELECT RAISE(ABORT,'broken'); END")
        let change = try await store.apply([SyncEvents.asset("five")], epoch: epoch)
        XCTAssertEqual(change.upserted.keys.sorted(), ["five"])
        let five = try await store.asset(id: "five")
        XCTAssertNotNil(five, "Sync goes on.")
        XCTAssertEqual(try Self.dump(file, "SELECT count(*) FROM asset_index WHERE id='five'"), [["0"]])
        let broken = try await store.isQueryable()
        XCTAssertFalse(broken)
        try Self.execute(file, "DROP TRIGGER broken")
        try await Self.runBackfill(store)
        XCTAssertEqual(try Self.dump(file, "SELECT id FROM asset_index ORDER BY id"), [["five"], ["one"]])

        // A server reset empties the derived rows with the entities, and the index stays queryable.
        _ = try await store.apply([SyncEvents.event("SyncResetV1", "{}", ack: "SyncResetV1|reset"), SyncEvents.asset("six")], epoch: epoch)
        XCTAssertEqual(try Self.dump(file, "SELECT id FROM asset_index"), [["six"]])
        let afterReset = try await store.isQueryable()
        XCTAssertTrue(afterReset)
        try await store.clear()
        XCTAssertEqual(try Self.dump(file, "SELECT count(*) FROM asset_index"), [["0"]])
    }

    /// A large library fills in short batches: 24,000 photos, each with its EXIF, a face and an
    /// album, in batches of 5,000 rows, none of them long enough to hold up a sync batch for long.
    func testBackfillOfALargeLibraryRunsInShortBatches() async throws {
        let (store, file) = try makeStore()
        _ = try await store.prepare(sessionFingerprint: "session")
        let epoch = await store.epoch()
        let clock = ContinuousClock()
        var applying = Duration.zero
        for batch in stride(from: 0, to: 24_000, by: 2_000) {
            var events: [EntitySyncEvent] = []
            for index in batch..<batch + 2_000 {
                let id = String(format: "photo-%05d", index), month = index / 100
                let taken = String(format: "%04d-%02d-%02dT10:00:00Z", 2006 + month / 12, month % 12 + 1, index % 28 + 1)
                events.append(SyncEvents.asset(id, taken: taken))
                events.append(SyncEvents.event("AssetExifV1", #"{"assetId":"\#(id)","city":"Lisbon"}"#, ack: "AssetExifV1|\(id)"))
                events.append(SyncEvents.event("AssetFaceV3", #"{"id":"face-\#(id)","assetId":"\#(id)","personId":"maya","isVisible":true,"deletedAt":null}"#, ack: "AssetFaceV3|\(id)"))
                events.append(SyncEvents.event("AlbumToAssetV1", #"{"albumId":"album-\#(index % 20)","assetId":"\#(id)"}"#, ack: "AlbumToAssetV1|\(id)"))
            }
            applying += try await clock.measure { _ = try await store.apply(events, epoch: epoch) }
        }
        let synced = try Self.derived(file)
        try Self.execute(file, """
        BEGIN; DELETE FROM asset_index; DELETE FROM album_member; DELETE FROM person_member;
        UPDATE index_state SET backfill_kind='asset',backfill_cursor=NULL,queryable=0; COMMIT;
        """)
        var batches: [Duration] = []
        var more = true
        while more { batches.append(try await clock.measure { more = try await store.writer.backfillStep() }) }
        XCTAssertEqual(batches.count, 15, "24,000 rows of each of three kinds in batches of 5,000, and the end.")
        XCTAssertEqual(try Self.derived(file), synced, "The backfill makes the rows sync kept.")
        let longest = try XCTUnwrap(batches.max())
        XCTAssertLessThan(longest, .seconds(5), "Generous: the simulator host is shared.")
        let total = batches.reduce(Duration.zero, +)
        print("INDEX BACKFILL 24,000 photos: \(batches.count) batches in \(total.formatted(.units(allowed: [.milliseconds]))), longest \(longest.formatted(.units(allowed: [.milliseconds]))); "
              + "syncing them with derived rows took \(applying.formatted(.units(allowed: [.milliseconds])))")
    }

    // MARK: - Readers

    /// Reading takes its own connection and queue: a month, an asset and the month list load
    /// A sync batch whose derived rows fail later in the session, after the launch backfill ended,
    /// starts the backfill again, so the index is queryable again without waiting for a relaunch.
    /// Once stopped, as at sign-out, it stays stopped.
    func testDerivedRowFailureRunsTheBackfillAgainThisSession() async throws {
        let (store, file) = try makeStore()
        _ = try await store.prepare(sessionFingerprint: "session")
        let epoch = await store.epoch()
        store.startBackfill(after: .zero, pause: .zero)
        await store.backfillFinished()
        let ready = try await store.isQueryable()
        XCTAssertTrue(ready)

        // Only the writer's sync batches fail; the backfill, outside them, can insert.
        try Self.execute(file, "CREATE TRIGGER broken BEFORE INSERT ON asset_index WHEN (SELECT writer_active FROM index_state WHERE id=1)=1 BEGIN SELECT RAISE(ABORT,'broken'); END")
        _ = try await store.apply([SyncEvents.asset("one")], epoch: epoch)
        await store.backfillFinished()
        let again = try await store.isQueryable()
        XCTAssertTrue(again, "The backfill ran again on its own.")
        XCTAssertEqual(try Self.dump(file, "SELECT id FROM asset_index"), [["one"]])

        await store.stopBackfill()
        _ = try await store.apply([SyncEvents.asset("two")], epoch: epoch)
        await store.backfillFinished()
        let stopped = try await store.isQueryable()
        XCTAssertFalse(stopped, "A stopped backfill does not start again.")
    }

    /// while the writer is inside a batch, from what was committed before it.
    func testViewportReadRunsWhileWriterCommits() async throws {
        let (store, file) = try makeStore()
        _ = try await store.prepare(sessionFingerprint: "session")
        let epoch = await store.epoch()
        _ = try await store.apply([SyncEvents.asset("before", taken: "2026-02-01T05:00:00Z")], epoch: epoch)

        // Another connection holds the write lock, so the writer's batch waits inside it.
        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &lock), SQLITE_OK)
        defer { sqlite3_close(lock) }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let batch = Task { try await store.apply([SyncEvents.asset("during", taken: "2026-02-02T05:00:00Z")], epoch: epoch) }
        try await Task.sleep(for: .milliseconds(150))

        let clock = ContinuousClock()
        var month: [Asset] = []
        let elapsed = try await clock.measure {
            // The feed asks whether the library is complete before every month it loads.
            _ = try await store.isComplete()
            _ = try await store.lastSyncDate()
            month = try await store.timeBucket("2026-02-01T00:00:00Z")
            _ = try await store.asset(id: "before")
            _ = try await store.timeBuckets()
            _ = try await store.statistics()
        }
        XCTAssertEqual(month.map(\.id), ["before"])
        XCTAssertLessThan(elapsed, .seconds(2), "Reads never wait for the writer.")

        XCTAssertEqual(sqlite3_exec(lock, "COMMIT", nil, nil, nil), SQLITE_OK)
        _ = try await batch.value
        let both = try await store.timeBucket("2026-02-01T00:00:00Z").map(\.id)
        XCTAssertEqual(Set(both), ["before", "during"], "Once committed, the batch is read.")
    }

    /// Every statement, read or write, runs off the main thread, even when the main actor asks.
    func testReadsNeverOnMainThread() async throws {
        let root = temporaryDirectory()
        let store = try await Task.detached { try LibraryIndex(scope: "server|alice", userID: "alice", directory: root) }.value
        let before = SQLiteConnection.statementsOnMainThread.load(ordering: .relaxed)
        _ = try await store.prepare(sessionFingerprint: "session")
        _ = try await store.apply([SyncEvents.asset("photo"), SyncEvents.complete()], epoch: store.epoch())
        _ = try await store.timeBuckets()
        _ = try await store.timeBucket("2026-02-01T00:00:00Z")
        _ = try await store.asset(id: "photo")
        _ = try await store.statistics()
        _ = try await store.albums()
        _ = try await store.people()
        _ = try await store.monthPlaces()
        _ = try await store.localAssetMatches()
        _ = try await store.isComplete()
        try await Self.runBackfill(store)
        XCTAssertEqual(SQLiteConnection.statementsOnMainThread.load(ordering: .relaxed), before)
    }

    // MARK: - Support

    private func makeStore() throws -> (LibraryIndex, URL) {
        let store = try LibraryIndex(scope: "server|alice", userID: "alice", directory: temporaryDirectory())
        return (store, URL(fileURLWithPath: store.writer.path))
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryIndexTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private static func runBackfill(_ store: LibraryIndex) async throws {
        while try await store.writer.backfillStep() {}
    }

    /// A library as builds before Q2 left it: user_version 0 and no derived tables, synced and
    /// complete, with assets, album members, faces (one of them hidden) and a queued purge.
    private static func makePreQ2Library(in root: URL, scope: String, assets: Int, albumMembers: Int, faces: Int) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent(name + ".sqlite")
        var statements = ["PRAGMA journal_mode=WAL"] + LibraryIndexSchema.base
        func entity(_ kind: String, _ id: String, _ payload: String) -> String {
            "INSERT INTO entities(kind,id,payload) VALUES('\(kind)','\(id)','\(payload)')"
        }
        for index in 0..<assets {
            let id = String(format: "photo-%02d", index)
            statements.append(entity("asset", id, #"{"id":"\#(id)","ownerId":"alice","originalFileName":"\#(id).jpg","visibility":"timeline","isFavorite":false,"deletedAt":null,"localDateTime":"2026-01-\#(String(format: "%02d", index + 1))T10:00:00Z","fileCreatedAt":"2026-01-01T10:00:00Z","createdAt":"2026-02-01T00:00:00Z"}"#))
        }
        statements.append(entity("album", "trip", #"{"id":"trip","ownerId":"alice","name":"Trip"}"#))
        statements.append(entity("person", "maya", #"{"id":"maya","name":"Maya"}"#))
        for index in 0..<albumMembers {
            statements.append(entity("albumAsset", "trip|photo-0\(index)", #"{"albumId":"trip","assetId":"photo-0\#(index)"}"#))
        }
        for index in 0..<faces {
            statements.append(entity("face", "face-\(index)", #"{"id":"face-\#(index)","assetId":"photo-0\#(index)","personId":"maya","isVisible":\#(index == 5 ? "false" : "true"),"deletedAt":null}"#))
        }
        statements += [
            "INSERT INTO metadata(key,value) VALUES('session','session'),('needsReset','0'),('complete','1'),('completedAt','2026-10-20T10:00:00Z')",
            "INSERT INTO acknowledgements(type,ack) VALUES('AssetV2','AssetV2|photo-09')",
            "INSERT INTO media_purges(id,revoked) VALUES('gone',1)",
        ]
        let connection = try SQLiteConnection(path: file.path, readOnly: false, busyTimeout: 1_000)
        for statement in statements { try connection.execute(statement) }
        connection.close()
        return file
    }

    /// The derived rows a backfill makes, compared without locked_asset, which only sync fills.
    private static func derived(_ file: URL) throws -> [[String?]] {
        try dump(file, "SELECT * FROM asset_index ORDER BY id") + [["--"]]
            + dump(file, "SELECT * FROM album_member ORDER BY entity_id") + [["--"]]
            + dump(file, "SELECT * FROM person_member ORDER BY face_id")
    }

    /// The derived rows made again from nothing by one uninterrupted backfill.
    private static func rebuilt(_ file: URL, _ store: LibraryIndex) async throws -> [[String?]] {
        try execute(file, """
        BEGIN; DELETE FROM asset_index; DELETE FROM album_member; DELETE FROM person_member;
        UPDATE index_state SET backfill_kind='asset',backfill_cursor=NULL,queryable=0; COMMIT;
        """)
        try await runBackfill(store)
        return try derived(file)
    }

    private static func dump(_ file: URL, _ sql: String) throws -> [[String?]] {
        let connection = try SQLiteConnection(path: file.path, readOnly: true, busyTimeout: 5_000)
        defer { connection.close() }
        return try connection.query(sql, cancellable: false)
    }

    private static func execute(_ file: URL, _ sql: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(file.path, &connection) == SQLITE_OK else { throw SQLiteError.open(0) }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5_000)
        let status = sqlite3_exec(connection, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw SQLiteError.statement(status, String(cString: sqlite3_errmsg(connection))) }
    }
}

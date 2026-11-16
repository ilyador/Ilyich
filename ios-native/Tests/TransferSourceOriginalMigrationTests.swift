import Foundation
import XCTest
@testable import Ilyich

final class TransferSourceOriginalMigrationTests: XCTestCase {
    func testRealVersionOneShapeAddsMissingCopiesAndSourceTablesWithoutChangingPauseHistoryOrPreferences() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TransferV1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("transfers.sqlite")
        var preferences = TransferPreferences()
        preferences.automatic = true
        preferences.downloadCloudOriginals = true
        preferences.includedAlbums = ["keep-selected-album"]
        let preferenceJSON = TransferJSON.encode(preferences)
        // Historical version 1 had neither confirmation_copies nor source-original state.
        // Build its actual persisted columns instead of initializing through today's schema.
        let old = try TransferSQLite(url: url)
        try old.transaction {
            let statements = [
                "CREATE TABLE meta(id INTEGER PRIMARY KEY CHECK(id=1),schema INTEGER NOT NULL,engine TEXT NOT NULL,legacy_import_digest TEXT,legacy_import_mode TEXT,legacy_imported_at,legacy_report_digest TEXT,legacy_report TEXT)",
                "CREATE TABLE preferences(id INTEGER PRIMARY KEY CHECK(id=1),json TEXT NOT NULL)",
                "CREATE TABLE engine_state(id INTEGER PRIMARY KEY CHECK(id=1),intent TEXT NOT NULL,blocker TEXT,last_message TEXT)",
                "CREATE TABLE confirmations(local_id TEXT PRIMARY KEY,modification_date NOT NULL,confirmed_at)",
                "CREATE TABLE receipts(local_id TEXT PRIMARY KEY,modification_date NOT NULL,original_id TEXT NOT NULL,original_checksum TEXT NOT NULL,original_bytes INTEGER,motion_id TEXT,motion_checksum TEXT,motion_bytes INTEGER,confirmed_at,verified_at,local_deleted_at)",
                "CREATE TABLE stack_tasks(id INTEGER PRIMARY KEY,local_id TEXT NOT NULL,asset_id TEXT NOT NULL,previous_asset_id TEXT NOT NULL,state TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,error TEXT)",
                "INSERT INTO meta(id,schema,engine) VALUES(1,1,'transfer')",
                "INSERT INTO engine_state VALUES(1,'paused',NULL,'Paused by the user')",
                "INSERT INTO confirmations VALUES('edit',700000000.25,700000001)",
                "INSERT INTO receipts VALUES('edit',700000000.25,'current','current-checksum',123,NULL,NULL,NULL,700000001,NULL,NULL)",
                "INSERT INTO stack_tasks VALUES(7,'edit','current','prior','failed',2,'Keep this failure')",
                "PRAGMA user_version=1",
            ]
            for statement in statements { try old.run(statement) }
            try old.run("INSERT INTO preferences VALUES(1,?)", [.text(preferenceJSON)])
        }
        old.close()
        let store = TransferStore(url: url)
        let migrated = try await store.meta()
        XCTAssertEqual(migrated, .init(schema: TransferStore.schemaVersion, engine: .transfer))
        let state = try await store.contents()
        XCTAssertEqual(state.preferences, preferences)
        XCTAssertEqual(state.engine?.intent, .paused)
        XCTAssertEqual(state.engine?.lastMessage, "Paused by the user")
        XCTAssertEqual(state.receipts.count, 1)
        XCTAssertEqual(state.receipts.first?.originalID, "current")
        XCTAssertEqual(state.confirmations.count, 1)
        let tasks = try await store.stackTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, 7)
        XCTAssertEqual(tasks.first?.state, "failed")
        XCTAssertEqual(tasks.first?.attempts, 2)
        XCTAssertEqual(tasks.first?.error, "Keep this failure")
        XCTAssertNil(tasks.first?.sourceChecksum)
        let dump = try await store.dump()
        XCTAssertNotNil(dump["confirmation_copies"])
        XCTAssertNotNil(dump["source_originals"])
        let associationWork = try await store.sourceMatchTasks()
        XCTAssertEqual(associationWork.count, 1)
        XCTAssertEqual(associationWork.first?.currentID, "current")
        XCTAssertEqual(associationWork.first?.reason, "migration")
        XCTAssertEqual(dump["preferences"], [[.integer(1), .text(preferenceJSON)]])
        await store.close()
        let reopened = TransferStore(url: url)
        let replay = try await reopened.dump()
        XCTAssertEqual(replay, dump, "Opening the migrated database again is idempotent.")
        // Both previously absent tables work before any backup is resumed.
        try await reopened.saveSourceOriginal(.init(localID: "edit", revision: .init(FakeStaging.date), checksum: "source", remoteID: "archive"))
        let current = try await reopened.receipts(for: ["edit"])
        let receipt = try XCTUnwrap(current["edit"])
        let queued = try await reopened.enqueueSourceOriginalStack(ifCurrent: receipt)
        XCTAssertTrue(queued)
        let after = try await reopened.contents()
        XCTAssertEqual(after.receipts, state.receipts)
        XCTAssertEqual(after.confirmations, state.confirmations)
        XCTAssertEqual(after.engine, state.engine)
        await reopened.close()
    }

    func testVersionTwoBackfillsOnlyExactCurrentReceiptsAndKeepsCachedSources() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TransferV2-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("transfers.sqlite")
        let old = TransferStore(url: url)
        var seed = TransferSeed()
        seed.preferences.downloadCloudOriginals = true
        seed.confirmations = [("current", FakeStaging.date), ("stale", FakeStaging.date.addingTimeInterval(1))]
        for id in ["current", "stale", "unconfirmed"] {
            seed.receipts.append(.init(localID: id, modified: FakeStaging.date, originalID: "remote-" + id, originalChecksum: "bytes-" + id))
        }
        try await old.seedForTest(seed)
        let cached = SourceOriginalAssociation(localID: "current", revision: .init(FakeStaging.date), checksum: "source", remoteID: "archive",
                                               fingerprint: .init(revision: .init(FakeStaging.date), checksum: "source"))
        try await old.saveSourceOriginal(cached)
        let before = try await old.contents()
        await old.close()
        // Restore the previous shipped schema shape in this fixture; the production migration
        // adds tables and rows only, with no destructive changes to the user's database.
        let fixture = try TransferSQLite(url: url)
        try fixture.run("DROP TABLE source_match_tasks")
        try fixture.run("UPDATE meta SET schema=2")
        try fixture.run("PRAGMA user_version=2")
        fixture.close()
        let migrated = TransferStore(url: url)
        let after = try await migrated.contents()
        XCTAssertEqual(after, before)
        let tasks = try await migrated.sourceMatchTasks()
        XCTAssertEqual(tasks.map(\.localID), ["current"])
        XCTAssertEqual(tasks.first?.reason, "migration")
        let retained = try await migrated.sourceOriginal(for: "current", revision: .init(FakeStaging.date))
        XCTAssertEqual(retained, cached)
        let dump = try await migrated.dump()
        await migrated.close()
        let reopened = TransferStore(url: url)
        let replay = try await reopened.dump()
        XCTAssertEqual(replay, dump)
        await reopened.close()
    }
}

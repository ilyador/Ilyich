import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// The import of the state.json an older build left into a transfers database the engine doesn't
/// own yet, which B10 keeps for accounts whose file no import read (the critic's correction to
/// B10): the rows B9's import wrote, exactly, from the current and the oldest shapes, dates bit
/// for bit; one transaction across crash points; an unreadable file set aside, and the copy B1 made
/// taken over paused with automatic backup off; a database the engine owns never imported into;
/// stranded album adds made runnable; 60,000 receipts off the main thread. state.json is never
/// written.
@MainActor final class LegacyBackupImportTests: XCTestCase {
    private typealias G = LegacyGoldens
    nonisolated private static let clock = Date(timeIntervalSinceReferenceDate: 800_000_000.123_456)

    /// The golden state of a backup mid-run (a queue, a Live Photo being uploaded, a suspended
    /// video, receipts, failures, album adds, a link and an ended notification batch) gives the
    /// rows B9's import wrote from it on the phone (LegacyGoldens.importedSeed), row for row, and
    /// hands the database to the engine.
    func testImportsTheCurrentStateAsB9Did() async throws {
        let data = try FixtureLoader.data("backup/state-current.json")
        let account = try makeAccount(state: data)
        let outcome = await account.importer().run()
        XCTAssertEqual(outcome, .imported)

        let reference = try makeAccount(state: nil)
        try await reference.store.seedForTest(G.importedSeed(), importedDigest: G.digest(of: data), importedAt: Self.clock)
        let imported = try await Self.rows(account.store)
        let expected = try await Self.rows(reference.store)
        XCTAssertEqual(imported, expected, "Every table, row for row.")
        let contents = try await account.store.contents()
        XCTAssertEqual(contents.confirmations.map { $0.modificationDate?.bitPattern }, [G.Bits.l4, G.Bits.l2, G.Bits.l5], "Dates bit for bit.")
        XCTAssertEqual(contents.engine?.intent, .automatic, "A running backup with automatic backup on is automatic.")

        let meta = try await account.store.meta()
        XCTAssertEqual(meta.engine, .transfer, "The engine owns the database now.")
        XCTAssertEqual(meta.legacyImportMode, .authoritative)
        XCTAssertEqual(meta.legacyImportDigest, LegacyBackupImporter.digest(data))
        XCTAssertEqual(meta.legacyImportedAt, Self.clock)
        XCTAssertEqual(try account.stateFile(), data, "state.json is only read.")
        XCTAssertEqual(try account.backupFolderContents(), ["state.json"], "Nothing is written beside it.")
        let statistics = await account.store.statistics()
        XCTAssertEqual(statistics.onMainThread, 0)
    }

    /// The first build's state.json: no receipts, links, album adds, suspended stages, failures or
    /// batch; preferences with only the first keys; a Live Photo stage without its video's checksum.
    func testImportsTheOldestShape() async throws {
        let account = try makeAccount(state: FixtureLoader.data("backup/state-9780e9625.json"))
        let outcome = await account.importer().run()
        XCTAssertEqual(outcome, .imported)
        let contents = try await account.store.contents()
        XCTAssertEqual(contents.jobs.map(\.sourceKey), [G.l1, G.l3])
        XCTAssertEqual(contents.jobs.map(\.state), ["staged", "queued"])
        XCTAssertEqual(contents.stages.count, 1)
        XCTAssertNil(contents.stages.first?.motionChecksum, "The oldest stages record no video checksum.")
        XCTAssertEqual(contents.stages.first?.motionRemoteID, G.motionAsset)
        XCTAssertNil(contents.stages.first?.sidecar)
        XCTAssertFalse(contents.stages.first?.hasSidecar ?? true)
        XCTAssertEqual(contents.attempts.map(\.part), ["original"])
        XCTAssertEqual(contents.confirmations.map(\.localID), [G.l2])
        XCTAssertEqual(contents.confirmations.first?.modificationDate?.bitPattern, G.Bits.l2)
        XCTAssertTrue(contents.receipts.isEmpty)
        XCTAssertTrue(contents.albumDestinations.isEmpty)
        XCTAssertTrue(contents.linkedAlbums.isEmpty)
        XCTAssertTrue(contents.notificationBatches.isEmpty)
        XCTAssertEqual(contents.engine, EngineStateRow(intent: .paused, blocker: nil, lastMessage: "Upload failed (HTTP 500). Retry after checking your server."))
        var preferences = Legacy.BackupPreferences()
        preferences.includedAlbums = ["3B1A8F4C-1D5E-4F7A-9C2B-6E8D0A1B2C3D/L0/040"]
        XCTAssertEqual(contents.preferences, TransferPreferences(preferences), "Keys added later take today's defaults.")
    }

    /// BM1: an import is one transaction. Whatever point the app ends at, the next launch finds
    /// either the database as it was (here the copy B1 made) or the whole import, never part of
    /// one; importing again then gives exactly what an uninterrupted import gives, and once the
    /// engine owns the database nothing imports into it again. state.json is never touched.
    func testAnImportIsOneTransactionAcrossCrashPoints() async throws {
        let current = try FixtureLoader.data("backup/state-current.json")
        let reference = try makeAccount(state: current)
        try await Self.seedCopy(reference.store)
        _ = await reference.importer().run()
        let expected = try await reference.store.dump()

        for point in LegacyImportCrashPoint.allCases {
            let account = try makeAccount(state: current)
            try await Self.seedCopy(account.store)
            let before = try await account.store.dump()

            let crashed = await account.importer(crashingAt: point).run()
            XCTAssertNil(crashed, "\(point): the app ended.")
            await account.store.close()

            // The next launch.
            let relaunched = account.reopened()
            let found = try await relaunched.store.dump()
            XCTAssertEqual(found, point == .afterCommit ? expected : before, "\(point): all or nothing.")
            let again = await relaunched.importer().run()
            XCTAssertEqual(again, point == .afterCommit ? .skipped : .imported, "\(point)")
            let imported = try await relaunched.store.dump()
            XCTAssertEqual(imported, expected, "\(point): the same rows as an import never interrupted, none twice.")

            let statements = await relaunched.store.statistics().statements
            let once = await relaunched.importer().run()
            XCTAssertEqual(once, .skipped, "\(point): the engine owns the database.")
            let added = await relaunched.store.statistics().statements - statements
            XCTAssertEqual(added, 1, "\(point): only the meta row is read.")
            let after = try await relaunched.store.dump()
            XCTAssertEqual(after, expected, "\(point)")
            XCTAssertEqual(try account.stateFile(), current, "\(point): state.json is never written.")
            XCTAssertEqual(try account.backupFolderContents(), ["state.json"], "\(point)")
        }
    }

    /// A state.json that can't be decoded is moved aside, never fatal, and the engine takes the
    /// copy B1 made as it is: its records stay, but automatic backup goes off and it waits,
    /// paused, since the copy never saw how its account's last session ended. A file that is there
    /// but can't be read now, as before the first unlock, is never moved: the account's backup
    /// waits for the next launch, and nothing is claimed.
    func testAnUnreadableStateIsSetAsideAndTheCopyIsTakenOverPaused() async throws {
        let garbage = Data(#"{"queue":["4A1C2B3D"],"receipts":{"#.utf8)
        let account = try makeAccount(state: garbage)
        try await Self.seedCopy(account.store)
        let handed = await AccountRuntime.handOver(account.store, importing: account.importer())
        XCTAssertEqual(handed, .engine)
        let stamp = Int64(Self.clock.timeIntervalSince1970)
        XCTAssertEqual(try account.backupFolderContents(), ["state.json.unreadable-\(stamp)"])
        XCTAssertEqual(try Data(contentsOf: account.backupFolder.appendingPathComponent("state.json.unreadable-\(stamp)")), garbage)
        let meta = try await account.store.meta()
        XCTAssertEqual(meta.engine, .transfer)
        XCTAssertEqual(meta.legacyImportMode, .shadow, "Its record says no import handed it over.")
        let contents = try await account.store.contents()
        XCTAssertEqual(contents.confirmations.map(\.localID), ["photo"], "The copy's records stay.")
        XCTAssertEqual(contents.preferences?.automatic, false, "Automatic backup goes off.")
        XCTAssertEqual(contents.preferences?.triggerDelay, 120, "The other preferences stay.")
        XCTAssertEqual(contents.engine?.intent, .paused, "It waits until the user starts it.")
        XCTAssertEqual(contents.engine?.lastMessage, "Uploading")
        let again = await AccountRuntime.handOver(account.store, importing: account.importer())
        XCTAssertEqual(again, .engine)
        let unchanged = try await account.store.contents()
        XCTAssertEqual(unchanged, contents, "Taking an engine's database over again changes nothing.")

        // A state.json that is there but can't be opened: try again later, move and claim nothing.
        let locked = try makeAccount(state: nil)
        try await Self.seedCopy(locked.store)
        try FileManager.default.createDirectory(at: locked.backupFolder.appendingPathComponent("state.json"), withIntermediateDirectories: true)
        let waiting = await AccountRuntime.handOver(locked.store, importing: locked.importer())
        XCTAssertEqual(waiting, .unavailable("The backup records an older version left can’t be read now."))
        XCTAssertEqual(try locked.backupFolderContents(), ["state.json"])
        let lockedMeta = try await locked.store.meta()
        XCTAssertEqual(lockedMeta.engine, .legacy, "Nothing is claimed while its file waits.")
        let nowhere = await LegacyBackupImporter(store: locked.store, folder: nil).run()
        XCTAssertEqual(nowhere, .unavailable, "Without the App Group there is nothing to read.")

        // No file at all: the engine claims the copy, paused, the same way.
        let absent = try makeAccount(state: nil)
        try await Self.seedCopy(absent.store)
        let outcome = await absent.importer().run()
        XCTAssertEqual(outcome, .absent)
        let claimed = await AccountRuntime.handOver(absent.store, importing: absent.importer())
        XCTAssertEqual(claimed, .engine)
        let absentContents = try await absent.store.contents()
        XCTAssertEqual(absentContents.preferences?.automatic, false)
        XCTAssertEqual(absentContents.engine?.intent, .paused)
    }

    /// A database the engine owns takes no import, even from a state.json an older build wrote
    /// after it (no older build will be reinstalled, so nothing merges): it stays as it is.
    func testADatabaseTheEngineOwnsTakesNoImport() async throws {
        let account = try makeAccount(state: FixtureLoader.data("backup/state-9780e9625.json"))
        try await account.store.seedForTest(G.importedSeed(), importedDigest: "state")
        let before = try await account.store.dump()
        let outcome = await account.importer().run()
        XCTAssertEqual(outcome, .skipped)
        let handed = await AccountRuntime.handOver(account.store, importing: account.importer())
        XCTAssertEqual(handed, .engine)
        let after = try await account.store.dump()
        XCTAssertEqual(after, before)
    }

    /// In state.json an album add waits for its photo to go through the queue again: one whose
    /// photo was backed up but is no longer queued never runs, and one whose photo failed only on
    /// the album waits behind that failure. Imported, each is a destination of its own: runnable
    /// at once when the server ID is known, and once its photo's job commits otherwise. A photo
    /// that never uploaded gets an album upload of its own.
    func testStrandedAlbumAddsBecomeRunnable() async throws {
        let backedUp = "BACKED-UP/L0/001", failedAlbum = "FAILED-ALBUM/L0/001", neverUploaded = "NEVER-UPLOADED/L0/001"
        let modified = Date(timeIntervalSinceReferenceDate: 780_000_000.5)
        var state = Legacy.BackupState()
        state.confirmed = [backedUp: modified]
        state.receipts = [backedUp: Legacy.BackupReceipt(modificationDate: modified, original: Legacy.RemoteFile(id: "server-backed-up", checksum: "a"),
                                                         confirmedAt: modified)]
        state.queue = [failedAlbum]
        state.suspended = [failedAlbum: Legacy.PreparedPhoto(
            localID: failedAlbum, modificationDate: modified,
            original: Legacy.UploadFile(url: G.backupFile("FOLDER", "original"), filename: "IMG_1.HEIC", contentType: "image/heic"),
            motion: nil, sidecar: nil, fields: ["isFavorite": "false"], isVideo: false, stageID: "STAGE")]
        state.failures = [failedAlbum: Legacy.BackupFailure(id: failedAlbum, filename: "IMG_1.HEIC",
                                                            message: "The photo uploaded but could not be added to the selected album. Check album permissions and retry.",
                                                            date: modified)]
        state.pendingAlbumAdds = [backedUp: ["album-1"], failedAlbum: ["album-1", "album-2"], neverUploaded: ["album-2"]]
        let account = try makeAccount(state: JSONEncoder().encode(state))
        let outcome = await account.importer().run()
        XCTAssertEqual(outcome, .imported)

        let runnable = try await account.store.runnableAlbumDestinations()
        XCTAssertEqual(runnable.map(\.localID), [backedUp], "Its photo's server copy is known, so it runs without an upload.")
        XCTAssertEqual(runnable.first?.remoteID, "server-backed-up")
        let contents = try await account.store.contents()
        XCTAssertEqual(contents.jobs.map(\.sourceKey), [failedAlbum, neverUploaded])
        XCTAssertEqual(contents.jobs.map(\.origin), ["legacy", "albumUpload"])
        XCTAssertEqual(contents.jobs.map(\.state), ["failed", "queued"])
        XCTAssertEqual(Set(contents.albumDestinations.map(\.state)), ["pending"], "The album failure stays on the photo, never the album add.")

        // The photo whose album failed commits (recovery or a retry): its albums run.
        let failedJob = contents.jobs[0]
        let committed = try await account.store.complete(TransferCompletion(
            job: failedJob.id, lease: nil, localID: failedAlbum, revision: AssetRevision(modified), assetID: "server-failed-album",
            receipt: TransferReceipt(localID: failedAlbum, revision: AssetRevision(modified),
                                     original: RemoteCopy(id: "server-failed-album", checksum: "b"), motion: nil, confirmedAt: modified),
            confirmedAt: modified))
        XCTAssertTrue(committed)
        var afterCommit = try await account.store.runnableAlbumDestinations()
        XCTAssertEqual(afterCommit.map { [$0.localID, $0.albumID, $0.remoteID ?? ""] }, [
            [backedUp, "album-1", "server-backed-up"], [failedAlbum, "album-1", "server-failed-album"], [failedAlbum, "album-2", "server-failed-album"],
        ])
        let jobs = try await account.store.contents().jobs
        let neverUploadedJob = try XCTUnwrap(jobs.first { $0.sourceKey == neverUploaded })
        _ = try await account.store.complete(TransferCompletion(job: neverUploadedJob.id, lease: nil, localID: neverUploaded,
                                                                revision: AssetRevision(modified), assetID: "server-never-uploaded", receipt: nil,
                                                                confirmedAt: modified))
        afterCommit = try await account.store.runnableAlbumDestinations()
        XCTAssertEqual(afterCommit.count, 4)
        XCTAssertTrue(afterCommit.contains { $0.localID == neverUploaded && $0.remoteID == "server-never-uploaded" })
    }

    /// 60,000 receipts and confirmations, as a large library has: imported off the main thread, in
    /// seconds.
    func testSixtyThousandReceiptsImportOffTheMainThread() async throws {
        var state = try FixtureLoader.decode(Legacy.BackupState.self, from: "backup/state-current.json")
        for index in 0..<60_000 {
            let id = String(format: "%08X-1111-4222-8333-944455566677/L0/001", index)
            let date = Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(index) * 1.000_001)
            state.confirmed?[id] = date
            state.receipts?[id] = Legacy.BackupReceipt(modificationDate: date, original: Legacy.RemoteFile(id: "asset-\(index)", checksum: "c2hhMQ==\(index)"),
                                                       motion: index.isMultiple(of: 7) ? Legacy.RemoteFile(id: "motion-\(index)", checksum: "bW90aW9u") : nil,
                                                       confirmedAt: date)
        }
        let account = try makeAccount(state: JSONEncoder().encode(state))
        let started = ContinuousClock.now
        let outcome = await account.importer().run()
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(outcome, .imported)
        XCTAssertLessThan(elapsed, .seconds(60), "Imported in \(elapsed).")
        let contents = try await account.store.contents()
        XCTAssertEqual(contents.receipts.count, 60_002)
        XCTAssertEqual(contents.confirmations.count, 60_003)
        let statistics = await account.store.statistics()
        XCTAssertEqual(statistics.onMainThread, 0, "Nothing ran on the main thread.")
    }

    // MARK: - Support

    /// The copy B1 made of the account's state.json while an older build backed up, as old as the
    /// last time the account opened in front: automatic backup on, a run under way.
    static func seedCopy(_ store: TransferStore) async throws {
        var seed = TransferSeed()
        seed.preferences.automatic = true
        seed.preferences.triggerDelay = 120
        seed.intent = .automatic
        seed.lastMessage = "Uploading"
        seed.jobs = [.init(localID: "queued")]
        seed.confirmations = [("photo", Date(timeIntervalSinceReferenceDate: 700_000_000.5))]
        try await store.seedForTest(seed, importedDigest: "older", mode: .shadow, engine: .legacy)
    }

    /// Every table's rows, each table's in a fixed order whatever order they were written in.
    static func rows(_ store: TransferStore) async throws -> [String: [String]] {
        try await store.dump().mapValues { rows in rows.map { $0.map(\.description).joined(separator: " | ") }.sorted() }
    }

    /// One account's App Group container and transfers folder, in a folder of the test's.
    struct Account {
        let container: URL
        let transfers: URL
        let store: TransferStore

        var backupFolder: URL { container.appendingPathComponent(AccountStoragePaths(G.account).backup, isDirectory: true) }

        func importer(crashingAt crash: LegacyImportCrashPoint? = nil) -> LegacyBackupImporter {
            LegacyBackupImporter(store: store, folder: backupFolder, now: { LegacyBackupImportTests.clock }, crashingAt: crash)
        }

        /// The same files, as the next launch finds them.
        func reopened() -> Account {
            Account(container: container, transfers: transfers, store: TransferStore(url: TransferStore.url(for: G.account, in: transfers)))
        }

        func stateFile() throws -> Data { try Data(contentsOf: backupFolder.appendingPathComponent("state.json")) }

        func backupFolderContents() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: backupFolder.path).sorted()
        }
    }

    private func makeAccount(state: Data?) throws -> Account {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyBackupImportTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let transfers = root.appendingPathComponent("IlyichTransfers", isDirectory: true)
        let account = Account(container: root.appendingPathComponent("AppGroup", isDirectory: true), transfers: transfers,
                              store: TransferStore(url: TransferStore.url(for: G.account, in: transfers)))
        try FileManager.default.createDirectory(at: account.backupFolder, withIntermediateDirectories: true)
        if let state { try state.write(to: account.backupFolder.appendingPathComponent("state.json"), options: .atomic) }
        addTeardownBlock { await account.store.close() }
        return account
    }
}

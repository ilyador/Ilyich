import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// The import of today's backup state, state.json, into the transfers database: the current and
/// the oldest shapes exactly, dates bit for bit; idempotent across crash points; an unreadable file
/// reported in shadow mode and set aside in authoritative mode; stranded album adds made runnable;
/// a rebuild only when the file changes; and state.json never written. The comparison that
/// Diagnostics shows is checked to see real differences.
@MainActor final class LegacyBackupImportTests: XCTestCase {
    private typealias G = LegacyGoldens
    nonisolated private static let clock = Date(timeIntervalSinceReferenceDate: 800_000_000.123_456)

    /// The golden state of a backup mid-run: a queue, a Live Photo being uploaded, a suspended
    /// video, receipts, failures, album adds, a link and an ended notification batch.
    func testImportsTheCurrentStateExactly() async throws {
        let account = try makeAccount(state: FixtureLoader.data("backup/state-current.json"))
        let untouched = try account.stateFile()
        let importer = account.importer()
        let report = try unwrapped(await importer.run())
        XCTAssertEqual(report.outcome, .imported)
        XCTAssertEqual(report.mode, .shadow)
        let comparison = try XCTUnwrap(report.comparison)
        XCTAssertEqual(comparison.total, 0, report.summary)
        XCTAssertEqual(comparison.compared, [.receipts: 2, .confirmations: 3, .queueOrder: 3, .stages: 2, .failures: 1, .albumAdds: 2,
                                             .linkedAlbums: 1, .preferences: 1, .runIntent: 1, .notificationBatch: 1])

        let contents = try await account.store.contents()
        // Receipts and confirmations, one row each, dates bit for bit.
        XCTAssertEqual(contents.receipts, [
            TransferReceiptRow(localID: G.l4, modificationDate: Double(bitPattern: G.Bits.l4), originalID: G.oldOriginalAsset,
                               originalChecksum: "fRFG0SH6nfZJt5SsRtJWzkOvsmk=", originalBytes: nil, motionID: nil, motionChecksum: nil, motionBytes: nil,
                               confirmedAt: nil, verifiedAt: nil, localDeletedAt: nil),
            TransferReceiptRow(localID: G.l2, modificationDate: Double(bitPattern: G.Bits.l2), originalID: G.originalAsset,
                               originalChecksum: "2jmj7l5rSw0yVb/vlWAYkK/YBwk=", originalBytes: 3_145_728, motionID: G.pairedMotionAsset,
                               motionChecksum: "Vtn0aoJu2VTK9bjfr/yx/SprVGo=", motionBytes: 1_843_200,
                               confirmedAt: Double(bitPattern: G.Bits.l2ConfirmedAt), verifiedAt: nil, localDeletedAt: nil),
        ])
        XCTAssertEqual(contents.confirmations.map(\.localID), [G.l4, G.l2, G.l5])
        XCTAssertEqual(contents.confirmations.map { $0.modificationDate?.bitPattern }, [G.Bits.l4, G.Bits.l2, G.Bits.l5])

        // The queue in order, the photo being uploaded first; the failure on its photo's job.
        XCTAssertEqual(contents.jobs.map(\.sourceKey), [G.l1, G.l3, G.l6])
        XCTAssertEqual(contents.jobs.map(\.origin), ["legacy", "legacy", "legacy"])
        XCTAssertEqual(contents.jobs.map(\.state), ["staged", "failed", "staged"])
        XCTAssertEqual(contents.jobs.map(\.seq), [0, 1, 2])
        let failed = contents.jobs[1]
        XCTAssertEqual(failed.errorClass, "item")
        XCTAssertEqual(failed.errorMessage, "The photo uploaded but could not be added to the selected album. Check album permissions and retry.")
        XCTAssertEqual(failed.errorAt?.bitPattern, G.Bits.failure)
        XCTAssertEqual(failed.displayName, "IMG_0003.HEIC")
        XCTAssertEqual(contents.jobs.map(\.batchID), [nil, nil, nil], "The batch ended; its final notification waits to be posted.")

        // The stages, paths relative to the App Group; each stage ID an interrupted attempt.
        let folder = "Backup/\(G.digest)/\(G.currentFolder)"
        let current = try XCTUnwrap(contents.stages.first { $0.stageID == G.currentStage })
        XCTAssertEqual(current.jobID, contents.jobs[0].id)
        XCTAssertEqual(current.folder, folder)
        XCTAssertEqual(current.original, StagedFile(path: folder + "/original", filename: "IMG_0001.HEIC", contentType: "image/heic"))
        XCTAssertEqual(current.motion, StagedFile(path: folder + "/motion", filename: "IMG_0001.MOV", contentType: "video/quicktime"))
        XCTAssertEqual(current.sidecar, StagedFile(path: folder + "/sidecar", filename: "IMG_0001.xmp", contentType: "application/rdf+xml"))
        XCTAssertEqual(current.fields, G.currentPhoto.fields)
        XCTAssertEqual(current.modificationDate?.bitPattern, G.Bits.current)
        XCTAssertEqual(current.motionRemoteID, G.motionAsset)
        XCTAssertEqual(current.motionChecksum, "q83vEjRWeJq83vEjRWeJq83vEjQ=")
        XCTAssertNil(current.originalChecksum, "Legacy stages never recorded the original's checksum.")
        XCTAssertFalse(current.isVideo)
        XCTAssertFalse(current.suspended)
        let suspended = try XCTUnwrap(contents.stages.first { $0.stageID == G.suspendedStage })
        XCTAssertEqual(suspended.jobID, contents.jobs[2].id)
        XCTAssertEqual(suspended.folder, "Backup/\(G.digest)/\(G.suspendedFolder)")
        XCTAssertTrue(suspended.suspended)
        XCTAssertTrue(suspended.isVideo)
        XCTAssertEqual(suspended.modificationDate?.bitPattern, G.Bits.l6)
        XCTAssertEqual(contents.attempts, [
            TransferAttemptRow(id: G.suspendedStage, jobID: contents.jobs[2].id, part: "original", session: "backup", state: "interrupted",
                               bodyPath: "Backup/\(G.digest)/\(G.suspendedFolder)/\(G.suspendedStage).multipart"),
            TransferAttemptRow(id: G.currentStage, jobID: contents.jobs[0].id, part: "original", session: "backup", state: "interrupted",
                               bodyPath: "\(folder)/\(G.currentStage).multipart"),
        ], "The Live Photo's video already uploaded, so its stage ID is the still's attempt.")

        // Album adds wait for their photo's job; the link, the batch, the intent and preferences.
        XCTAssertEqual(contents.albumDestinations, [
            AlbumDestinationRow(localID: G.l3, albumID: G.otherServerAlbum, remoteID: nil, state: "pending", attempts: 0, error: nil),
            AlbumDestinationRow(localID: G.l3, albumID: G.serverAlbum, remoteID: nil, state: "pending", attempts: 0, error: nil),
        ])
        XCTAssertEqual(contents.linkedAlbums, ["B7E2D9A0-55C1-4E3F-8A6B-1C2D3E4F5A6B/L0/040": G.serverAlbum])
        XCTAssertEqual(contents.notificationBatches, [NotificationBatchRow(id: G.notificationID.uuidString, kind: "backup", total: 12, completed: 9,
                                                                           failed: 2, startedPosted: true, terminalPosted: false)])
        XCTAssertEqual(contents.engine, EngineStateRow(intent: .automatic, blocker: nil, lastMessage: ServerFailure.sessionExpired(nil).localizedDescription),
                       "A running backup with automatic backup on is automatic, and its error only a message.")
        var preferences = Legacy.BackupPreferences()
        preferences.includedAlbums = G.includedAlbums; preferences.excludedAlbums = [G.excludedAlbum]
        preferences.cellularPhotos = true; preferences.downloadCloudOriginals = true; preferences.automatic = true
        preferences.requireCharging = true; preferences.triggerDelay = 120; preferences.syncAlbums = true
        XCTAssertEqual(contents.preferences, TransferPreferences(preferences))
        XCTAssertEqual(contents.stackTasks, 0)

        let meta = try await account.store.meta()
        XCTAssertEqual(meta.legacyImportDigest, LegacyBackupImporter.digest(try FixtureLoader.data("backup/state-current.json")))
        XCTAssertEqual(meta.legacyImportMode, .shadow)
        XCTAssertEqual(meta.engine, .legacy, "A shadow copy leaves BackupCoordinator in charge.")
        XCTAssertEqual(meta.legacyImportedAt, Self.clock)
        XCTAssertEqual(try account.stateFile(), untouched, "state.json is only read.")
        XCTAssertEqual(try account.backupFolderContents(), ["state.json"], "Nothing is written beside it.")
        let statistics = await account.store.statistics()
        XCTAssertEqual(statistics.onMainThread, 0)
    }

    /// The first build's state.json: no receipts, links, album adds, suspended stages, failures or
    /// batch; preferences with only the first keys; a Live Photo stage without its video's checksum.
    func testImportsTheOldestShape() async throws {
        let account = try makeAccount(state: FixtureLoader.data("backup/state-9780e9625.json"))
        let report = try unwrapped(await account.importer().run())
        XCTAssertEqual(report.outcome, .imported)
        XCTAssertEqual(report.comparison?.total, 0, report.summary)
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
    /// either the database as it was or the whole import, never part of one; importing again then
    /// gives exactly what an uninterrupted import gives, and once more changes nothing. state.json
    /// is never touched.
    func testIdempotentAcrossCrashPoints() async throws {
        let oldest = try FixtureLoader.data("backup/state-9780e9625.json")
        let current = try FixtureLoader.data("backup/state-current.json")
        let reference = try makeAccount(state: current)
        _ = try unwrapped(await reference.importer().run())
        let expected = try await reference.store.dump()

        for point in LegacyImportCrashPoint.allCases {
            let account = try makeAccount(state: oldest)
            _ = try unwrapped(await account.importer().run())
            let before = try await account.store.dump()
            try account.writeState(current)

            let crashed = await account.importer(crashingAt: point).run()
            XCTAssertNil(crashed, "\(point): the app ended.")
            await account.store.close()

            // The next launch.
            let relaunched = account.reopened()
            var found = try await relaunched.store.dump()
            if point == .afterCommit {
                // The import committed; only the comparison made after it was lost.
                found["meta"] = expected["meta"]
                XCTAssertEqual(found, expected, "\(point): the whole import is there.")
            } else {
                XCTAssertEqual(found, before, "\(point): the database is as it was.")
            }
            let again = try unwrapped(await relaunched.importer().run())
            XCTAssertEqual(again.outcome, point == .afterCommit ? .unchanged : .imported, "\(point)")
            XCTAssertEqual(again.comparison?.total, 0, "\(point): \(again.summary)")
            let imported = try await relaunched.store.dump()
            XCTAssertEqual(imported, expected, "\(point): the same rows as an import never interrupted, none twice.")

            let statements = await relaunched.store.statistics().statements
            let once = try unwrapped(await relaunched.importer().run())
            XCTAssertEqual(once.outcome, .unchanged, "\(point)")
            XCTAssertEqual(once.comparison?.total, 0)
            let added = await relaunched.store.statistics().statements - statements
            XCTAssertEqual(added, 1, "\(point): the same digest only reads the meta row.")
            let after = try await relaunched.store.dump()
            XCTAssertEqual(after, expected, "\(point)")
            XCTAssertEqual(try account.stateFile(), current, "\(point): state.json is never written.")
            XCTAssertEqual(try account.backupFolderContents(), ["state.json"], "\(point)")
        }
    }

    /// A state.json that can't be decoded. In shadow mode it is reported and left where it is,
    /// byte for byte, and the copy keeps what it had. In authoritative mode it is moved aside and
    /// the import goes on without it; either way nothing throws. A file that can't be read now,
    /// as before the first unlock, is not unreadable and is never moved.
    func testUnreadableStateIsReportedInShadowAndQuarantinedWhenAuthoritative() async throws {
        let garbage = Data(#"{"queue":["4A1C2B3D"],"receipts":{"#.utf8)

        let shadow = try makeAccount(state: FixtureLoader.data("backup/state-9780e9625.json"))
        _ = try unwrapped(await shadow.importer().run())
        let kept = try await shadow.store.dump()
        try shadow.writeState(garbage)
        let reported = try unwrapped(await shadow.importer().run())
        XCTAssertEqual(reported.outcome, .unreadable)
        XCTAssertNil(reported.comparison)
        XCTAssertEqual(try shadow.stateFile(), garbage, "Left alone, byte for byte.")
        XCTAssertEqual(try shadow.backupFolderContents(), ["state.json"])
        let afterShadow = try await shadow.store.dump()
        XCTAssertEqual(afterShadow, kept, "The copy keeps the last state it could read.")

        let authoritative = try makeAccount(state: garbage)
        let quarantined = try unwrapped(await authoritative.importer(mode: .authoritative).run())
        XCTAssertEqual(quarantined.outcome, .quarantined)
        let stamp = Int64(Self.clock.timeIntervalSince1970)
        XCTAssertEqual(try authoritative.backupFolderContents(), ["state.json.unreadable-\(stamp)"])
        XCTAssertEqual(try Data(contentsOf: authoritative.backupFolder.appendingPathComponent("state.json.unreadable-\(stamp)")), garbage)
        let meta = try await authoritative.store.meta()
        XCTAssertEqual(meta.engine, .legacy, "Nothing was imported.")
        let next = try unwrapped(await authoritative.importer(mode: .authoritative).run())
        XCTAssertEqual(next.outcome, .absent, "The engine then starts without it.")
        let started = try await authoritative.store.meta()
        XCTAssertEqual(started.engine, .transfer)

        // A state.json that is there but can't be opened: try again later, move nothing.
        let locked = try makeAccount(state: nil)
        try FileManager.default.createDirectory(at: locked.backupFolder.appendingPathComponent("state.json"), withIntermediateDirectories: true)
        let unavailable = try unwrapped(await locked.importer(mode: .authoritative).run())
        XCTAssertEqual(unavailable.outcome, .unavailable)
        XCTAssertEqual(try locked.backupFolderContents(), ["state.json"])
        let nowhere = try unwrapped(await LegacyBackupImporter(mode: .shadow, store: locked.store, folder: nil).run())
        XCTAssertEqual(nowhere.outcome, .unavailable, "Without the App Group there is nothing to read.")
    }

    /// In state.json an album add waits for its photo to go through the queue again: one whose
    /// photo was backed up but is no longer queued never runs, and one whose photo failed only on
    /// the album waits behind that failure. Imported, each is a destination of its own: runnable
    /// at once when the server ID is known, and once its photo's job commits otherwise. A photo
    /// that never uploaded gets an album upload of its own.
    func testStrandedAlbumAddsBecomeRunnable() async throws {
        let backedUp = "BACKED-UP/L0/001", failedAlbum = "FAILED-ALBUM/L0/001", neverUploaded = "NEVER-UPLOADED/L0/001"
        let modified = Date(timeIntervalSinceReferenceDate: 780_000_000.5)
        var state = BackupState()
        state.confirmed = [backedUp: modified]
        state.receipts = [backedUp: BackupReceipt(modificationDate: modified, original: BackupRemoteFile(id: "server-backed-up", checksum: "a"),
                                                  confirmedAt: modified)]
        state.queue = [failedAlbum]
        state.suspended = [failedAlbum: PreparedPhoto(
            localID: failedAlbum, modificationDate: modified,
            original: UploadFile(url: G.backupFile("FOLDER", "original"), filename: "IMG_1.HEIC", contentType: "image/heic"),
            motion: nil, sidecar: nil, fields: ["isFavorite": "false"], isVideo: false, stageID: "STAGE")]
        state.failures = [failedAlbum: BackupFailure(id: failedAlbum, filename: "IMG_1.HEIC",
                                                     message: "The photo uploaded but could not be added to the selected album. Check album permissions and retry.",
                                                     date: modified)]
        state.pendingAlbumAdds = [backedUp: ["album-1"], failedAlbum: ["album-1", "album-2"], neverUploaded: ["album-2"]]
        let account = try makeAccount(state: JSONEncoder().encode(state))
        let report = try unwrapped(await account.importer().run())
        XCTAssertEqual(report.comparison?.total, 0, report.summary)

        let runnable = try await account.store.runnableAlbumDestinations()
        XCTAssertEqual(runnable.map(\.localID), [backedUp], "Its photo's server copy is known, so it runs without an upload.")
        XCTAssertEqual(runnable.first?.remoteID, "server-backed-up")
        let contents = try await account.store.contents()
        XCTAssertEqual(contents.jobs.map(\.sourceKey), [failedAlbum, neverUploaded])
        XCTAssertEqual(contents.jobs.map(\.origin), ["legacy", "albumUpload"])
        XCTAssertEqual(contents.jobs.map(\.state), ["failed", "queued"])
        XCTAssertEqual(Set(contents.albumDestinations.map(\.state)), ["pending"], "The album failure stays on the photo, never the album add.")

        // The comparison works the jobs out from state.json, not from the plan that wrote them: a
        // photo off the queue with the wrong origin, a missing one, or one in the running batch
        // each shows as a mismatch.
        let legacy = try Legacy.decoder().decode(Legacy.BackupState.self, from: JSONEncoder().encode(state))
        func mismatches(_ change: (inout TransferStoreContents) -> Void) -> [LegacyImportCategory: Int] {
            var changed = contents
            change(&changed)
            return LegacyBackupComparison.compare(legacy, with: changed).mismatches.filter { $0.value > 0 }
        }
        XCTAssertEqual(mismatches { _ in }, [:])
        func job(_ row: TransferJobRow, origin: String? = nil, batchID: String? = nil) -> TransferJobRow {
            TransferJobRow(id: row.id, sourceKey: row.sourceKey, origin: origin ?? row.origin, state: row.state, seq: row.seq, errorClass: row.errorClass,
                           errorMessage: row.errorMessage, errorAt: row.errorAt, displayName: row.displayName, batchID: batchID ?? row.batchID)
        }
        XCTAssertEqual(mismatches { $0.jobs[1] = job($0.jobs[1], origin: "legacy") }, [.queueOrder: 1])
        XCTAssertEqual(mismatches { $0.jobs.removeLast() }, [.queueOrder: 1])
        XCTAssertEqual(mismatches { $0.jobs[0] = job($0.jobs[0], batchID: UUID().uuidString) }, [.notificationBatch: 1])

        // Recovery applies the suspended stage's outcome file and commits the photo: its albums run.
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
        let neverUploadedJob = try unwrapped(try await account.store.contents().jobs.first { $0.sourceKey == neverUploaded })
        _ = try await account.store.complete(TransferCompletion(job: neverUploadedJob.id, lease: nil, localID: neverUploaded,
                                                                revision: AssetRevision(modified), assetID: "server-never-uploaded", receipt: nil,
                                                                confirmedAt: modified))
        afterCommit = try await account.store.runnableAlbumDestinations()
        XCTAssertEqual(afterCommit.count, 4)
        XCTAssertTrue(afterCommit.contains { $0.localID == neverUploaded && $0.remoteID == "server-never-uploaded" })
    }

    /// The copy is rebuilt only when state.json's digest changes. The same file again reuses the
    /// comparison made when it was imported, unless Diagnostics asks for a new one.
    func testRebuildsOnlyWhenTheFileChanges() async throws {
        var state = G.backupState()
        let account = try makeAccount(state: JSONEncoder().encode(state))
        let first = try unwrapped(await account.importer().run())
        XCTAssertEqual(first.outcome, .imported)

        let statements = await account.store.statistics().statements
        let same = try unwrapped(await account.importer().run())
        XCTAssertEqual(same.outcome, .unchanged)
        XCTAssertEqual(same.comparison, first.comparison, "The comparison made at import is reused.")
        let reused = await account.store.statistics().statements - statements
        XCTAssertEqual(reused, 1)
        let compared = try unwrapped(await account.importer().run(comparing: true))
        XCTAssertEqual(compared.outcome, .unchanged)
        XCTAssertEqual(compared.comparison, first.comparison)
        let comparedStatements = await account.store.statistics().statements - statements - reused
        XCTAssertGreaterThan(comparedStatements, 5, "Asked for, it compares again.")

        // BackupCoordinator confirms the failed photo on a retry, and its albums with it.
        let modified = Date(timeIntervalSinceReferenceDate: 790_123_456.789)
        state.confirmed[G.l3] = modified
        state.receipts?[G.l3] = BackupReceipt(modificationDate: modified, original: BackupRemoteFile(id: "server-l3", checksum: "c"), confirmedAt: modified)
        state.failures?[G.l3] = nil
        state.pendingAlbumAdds?[G.l3] = nil
        state.queue.removeAll { $0 == G.l3 }
        try account.writeState(JSONEncoder().encode(state))
        let changed = try unwrapped(await account.importer().run())
        XCTAssertEqual(changed.outcome, .imported)
        XCTAssertEqual(changed.comparison?.total, 0, changed.summary)
        let contents = try await account.store.contents()
        XCTAssertEqual(contents.confirmations.first { $0.localID == G.l3 }?.modificationDate?.bitPattern,
                       modified.timeIntervalSinceReferenceDate.bitPattern)
        XCTAssertEqual(contents.receipts.first { $0.localID == G.l3 }?.originalID, "server-l3")
        XCTAssertEqual(contents.jobs.map(\.sourceKey), [G.l1, G.l6])
        XCTAssertTrue(contents.albumDestinations.isEmpty)

        // No state.json: the account has no backup state, and neither has its copy.
        try FileManager.default.removeItem(at: account.backupFolder.appendingPathComponent("state.json"))
        let absent = try unwrapped(await account.importer().run())
        XCTAssertEqual(absent.outcome, .absent)
        XCTAssertEqual(absent.comparison?.total, 0)
        let empty = try await account.store.contents()
        XCTAssertTrue(empty.jobs.isEmpty && empty.receipts.isEmpty && empty.confirmations.isEmpty)
        let again = try unwrapped(await account.importer().run())
        XCTAssertEqual(again.outcome, .absent)
    }

    /// Once the transfer engine owns the database (B9), a shadow import, as an older build would
    /// run, leaves it alone. Authoritatively, the same file is a no-op, and a file an older build
    /// changed since is merged into what the engine has (BM8), once.
    func testAnEngineOwnedDatabaseIsNeverRebuiltFromTheFile() async throws {
        let account = try makeAccount(state: FixtureLoader.data("backup/state-current.json"))
        let shadowCopy = try unwrapped(await account.importer().run())
        XCTAssertEqual(shadowCopy.outcome, .imported)
        let cutover = try unwrapped(await account.importer(mode: .authoritative).run())
        XCTAssertEqual(cutover.outcome, .imported, "The cutover imports the file once more, as the engine's.")
        XCTAssertEqual(cutover.comparison?.total, 0)
        let owned = try await account.store.contents()
        let meta = try await account.store.meta()
        XCTAssertEqual(meta.engine, .transfer)
        XCTAssertEqual(meta.legacyImportMode, .authoritative)

        let same = try unwrapped(await account.importer(mode: .authoritative).run())
        XCTAssertEqual(same.outcome, .unchanged)
        let compared = try unwrapped(await account.importer(mode: .authoritative).run(comparing: true))
        XCTAssertEqual(compared.comparison, cutover.comparison, "The comparison made at the cutover stands.")
        try account.writeState(FixtureLoader.data("backup/state-9780e9625.json"))
        let merge = try unwrapped(await account.importer(mode: .authoritative).run())
        XCTAssertEqual(merge.outcome, .merged)
        let again = try unwrapped(await account.importer(mode: .authoritative).run())
        XCTAssertEqual(again.outcome, .unchanged, "A file merges once.")
        let shadow = try unwrapped(await account.importer().run())
        XCTAssertEqual(shadow.outcome, .skipped)
        let after = try await account.store.contents()
        XCTAssertEqual(after.receipts, owned.receipts, "Nothing the engine had is lost.")
        XCTAssertTrue(Set(owned.confirmations.map(\.localID)).isSubset(of: Set(after.confirmations.map(\.localID))))
        XCTAssertEqual(after.preferences, owned.preferences, "The engine's preferences are newer.")
        XCTAssertEqual(after.engine, owned.engine)
    }

    /// The comparison Diagnostics shows sees every kind of difference, one per category.
    func testComparisonCountsEachDifference() async throws {
        let account = try makeAccount(state: FixtureLoader.data("backup/state-current.json"))
        _ = try unwrapped(await account.importer().run())
        let state = try FixtureLoader.decode(Legacy.BackupState.self, from: "backup/state-current.json")
        let contents = try await account.store.contents()
        XCTAssertEqual(LegacyBackupComparison.compare(state, with: contents).total, 0)

        func mismatches(_ change: (inout TransferStoreContents) -> Void) -> [LegacyImportCategory: Int] {
            var changed = contents
            change(&changed)
            return LegacyBackupComparison.compare(state, with: changed).mismatches.filter { $0.value > 0 }
        }
        // A receipt's date off by its last bit.
        XCTAssertEqual(mismatches { contents in
            let row = contents.receipts[0]
            contents.receipts[0] = TransferReceiptRow(localID: row.localID, modificationDate: row.modificationDate.map { Double(bitPattern: $0.bitPattern + 1) },
                                                      originalID: row.originalID, originalChecksum: row.originalChecksum, originalBytes: row.originalBytes,
                                                      motionID: row.motionID, motionChecksum: row.motionChecksum, motionBytes: row.motionBytes,
                                                      confirmedAt: row.confirmedAt, verifiedAt: nil, localDeletedAt: nil)
        }, [.receipts: 1])
        XCTAssertEqual(mismatches { $0.confirmations.removeLast() }, [.confirmations: 1])
        XCTAssertEqual(mismatches { $0.jobs.swapAt(1, 2) }, [.queueOrder: 2])
        XCTAssertEqual(mismatches { contents in
            guard let index = contents.stages.firstIndex(where: { $0.stageID == G.currentStage }) else { return }
            let stage = contents.stages[index]
            contents.stages[index] = TransferStageRow(stageID: stage.stageID, jobID: stage.jobID, folder: stage.folder, modificationDate: stage.modificationDate,
                                                  original: stage.original, motion: stage.motion, hasMotion: stage.hasMotion, sidecar: stage.sidecar,
                                                  hasSidecar: stage.hasSidecar, fields: stage.fields, isVideo: stage.isVideo, motionRemoteID: nil,
                                                  motionChecksum: stage.motionChecksum, originalChecksum: nil, suspended: stage.suspended)
        }, [.stages: 1])
        XCTAssertEqual(mismatches { $0.attempts.removeFirst() }, [.stages: 1])
        XCTAssertEqual(mismatches { contents in
            let job = contents.jobs[1]
            contents.jobs[1] = TransferJobRow(id: job.id, sourceKey: job.sourceKey, origin: job.origin, state: job.state, seq: job.seq,
                                              errorClass: job.errorClass, errorMessage: "Another message", errorAt: job.errorAt,
                                              displayName: job.displayName, batchID: job.batchID)
        }, [.failures: 1])
        XCTAssertEqual(mismatches { $0.albumDestinations.removeFirst() }, [.albumAdds: 1])
        XCTAssertEqual(mismatches { $0.linkedAlbums["another"] = "album" }, [.linkedAlbums: 1])
        XCTAssertEqual(mismatches { $0.preferences?.triggerDelay = 30 }, [.preferences: 1])
        XCTAssertEqual(mismatches { $0.engine = EngineStateRow(intent: .manual, blocker: nil, lastMessage: $0.engine?.lastMessage) }, [.runIntent: 1])
        XCTAssertEqual(mismatches { contents in
            let batch = contents.notificationBatches[0]
            contents.notificationBatches[0] = NotificationBatchRow(id: batch.id, kind: batch.kind, total: batch.total, completed: 8, failed: batch.failed,
                                                                   startedPosted: true, terminalPosted: false)
        }, [.notificationBatch: 1])
    }

    /// 60,000 receipts and confirmations, as the owner's library will have: imported off the main
    /// thread, in seconds, and compared without a mismatch.
    func testSixtyThousandReceiptsImportOffTheMainThread() async throws {
        var state = G.backupState()
        for index in 0..<60_000 {
            let id = String(format: "%08X-1111-4222-8333-944455566677/L0/001", index)
            let date = Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(index) * 1.000_001)
            state.confirmed[id] = date
            state.receipts?[id] = BackupReceipt(modificationDate: date, original: BackupRemoteFile(id: "asset-\(index)", checksum: "c2hhMQ==\(index)"),
                                                motion: index.isMultiple(of: 7) ? BackupRemoteFile(id: "motion-\(index)", checksum: "bW90aW9u") : nil,
                                                confirmedAt: date)
        }
        let account = try makeAccount(state: JSONEncoder().encode(state))
        let started = ContinuousClock.now
        let report = try unwrapped(await account.importer().run())
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(report.outcome, .imported)
        XCTAssertEqual(report.comparison?.total, 0, report.summary)
        XCTAssertEqual(report.comparison?.compared[.receipts], 60_002)
        XCTAssertEqual(report.comparison?.compared[.confirmations], 60_003)
        XCTAssertLessThan(elapsed, .seconds(60), "Imported and compared in \(elapsed).")
        let statistics = await account.store.statistics()
        XCTAssertEqual(statistics.onMainThread, 0, "Nothing ran on the main thread.")
    }

    // MARK: - Support

    /// XCTUnwrap for a value that takes an await, which XCTUnwrap's autoclosure can't hold.
    private func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    /// One account's App Group container and transfers folder, in a folder of the test's.
    struct Account {
        let container: URL
        let transfers: URL
        let store: TransferStore

        var backupFolder: URL { container.appendingPathComponent(AccountStoragePaths(G.account).backup, isDirectory: true) }

        func importer(mode: LegacyBackupImporter.Mode = .shadow, crashingAt crash: LegacyImportCrashPoint? = nil) -> LegacyBackupImporter {
            LegacyBackupImporter(mode: mode, store: store, folder: backupFolder, now: { LegacyBackupImportTests.clock }, crashingAt: crash)
        }

        /// The same files, as the next launch finds them.
        func reopened() -> Account {
            Account(container: container, transfers: transfers, store: TransferStore(url: TransferStore.url(for: G.account, in: transfers)))
        }

        func writeState(_ data: Data) throws {
            try data.write(to: backupFolder.appendingPathComponent("state.json"), options: .atomic)
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
        if let state { try account.writeState(state) }
        return account
    }
}

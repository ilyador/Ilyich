import Foundation
import IlyichPlatform
import Synchronization
import XCTest
@testable import Ilyich

/// Recovery's reconcile (rebuild milestone B6), on a transfers database the engine owns: legacy
/// stages from an authoritative import of state.json, or jobs an earlier run left, with the
/// background sessions faked through their TransportSession seam and a throwaway App Group.
final class RecoveryTests: XCTestCase {
    private typealias G = LegacyGoldens
    private static let current = "Backup/\(G.digest)/\(G.currentFolder)"
    private static let suspended = "Backup/\(G.digest)/\(G.suspendedFolder)"

    // MARK: R2: tasks iOS still holds

    /// A task an earlier build sent for the current stage is bound by its stage ID and waited
    /// for, never sent again; once it ends, its answer commits the photo.
    func testLegacyTaskDescriptionReattachesInsteadOfUploadingAgain() async throws {
        let descriptor = String(decoding: try FixtureLoader.data("backup/descriptor-backup.json"), as: UTF8.self)
        let h = try await RecoveryHarness.legacy(backupTasks: [SessionTask(id: 7, description: descriptor, state: .running, sent: 100, expected: 900)])
        addTeardownBlock { await h.tearDown() }

        let first = try await h.recovery.reconcile()
        XCTAssertEqual(first.bound, 1)
        XCTAssertEqual(first.cancelled, 0, "The task's attempt is known.")
        let job = try await h.job(G.l1)
        XCTAssertEqual(job?.state, .submitted, "The job waits for its task's outcome.")
        let attempt = try await h.attempt(G.currentStage)
        XCTAssertEqual(attempt?.state, .submitted)
        XCTAssertEqual(attempt?.taskID, 7)
        XCTAssertTrue(h.group.exists(Self.current + "/original"), "A bound stage is never swept.")
        XCTAssertTrue(h.backupSession.uploads.isEmpty, "Nothing is sent again.")
        XCTAssertTrue(h.backupSession.cancelled.isEmpty)

        // iOS finishes the task: the delegate writes its outcome where the legacy descriptor says.
        h.backupSession.handler.task(7, didReceive: Data(#"{"id":"\#(G.originalAsset)","status":"created"}"#.utf8))
        h.backupSession.handler.taskDidComplete(CompletedTask(id: 7, description: descriptor, httpStatus: 201, failure: nil))
        h.backupSession.forget(7)
        XCTAssertTrue(h.group.exists(Self.current + "/\(G.currentStage).receipt"))

        let stillChecksum = try UploadBody.checksum(h.group.url(Self.current + "/original"))
        let second = try await h.recovery.reconcile()
        XCTAssertEqual(second.committed, 1)
        let receipt = try await h.receipt(G.l1)
        XCTAssertEqual(receipt?.original.id, G.originalAsset)
        XCTAssertEqual(receipt?.original.checksum, stillChecksum)
        XCTAssertEqual(receipt?.motion, RemoteCopy(id: G.motionAsset, checksum: G.currentPhoto.motionChecksum!))
        XCTAssertEqual(receipt?.revision, AssetRevision(G.Dates.current))
        let gone = try await h.job(G.l1)
        XCTAssertNil(gone)
        XCTAssertFalse(h.group.exists(Self.current), "The committed stage's folder goes.")
        XCTAssertTrue(h.backupSession.uploads.isEmpty)
        XCTAssertEqual(h.hashes.value.count, 1, "A legacy stage has no checksum of its still: it is hashed once.")
    }

    /// Live tasks of the account that no unanswered attempt owns are cancelled; another account's
    /// and tasks this app did not describe are left alone. A legacy share task stays while its
    /// batch still lists files, and is cancelled once its batch is gone.
    func testOrphanTasksAreCancelledAndLegacySharesKeptWhileListed() async throws {
        let other = AccountID(server: URL(string: "https://other.example/api")!, userID: "someone")
        func v2(_ scope: String) -> String {
            TaskDescriptor.v2(attempt: AttemptID(), scope: scope, outcome: "Backup/\(scope)/\(UUID().uuidString)/x.receipt").taskDescription!
        }
        let shareText = String(decoding: try FixtureLoader.data("share/descriptor-share-var.json"), as: UTF8.self)
        let goneBatch = UUID()
        let goneShare = TaskDescriptor.legacy(id: "feed", receipt: URL(fileURLWithPath: "\(G.varContainer)/ShareInbox/\(goneBatch.uuidString)/feed.receipt"))
        let h = try await RecoveryHarness.fresh(
            backupTasks: [SessionTask(id: 1, description: v2(G.digest), state: .running, sent: 0, expected: 10),
                          SessionTask(id: 2, description: v2(other.digest), state: .running, sent: 0, expected: 10),
                          SessionTask(id: 3, description: "not ours", state: .running, sent: 0, expected: 10),
                          SessionTask(id: 4, description: v2(G.digest), state: .canceling, sent: 0, expected: 10)],
            shareTasks: [SessionTask(id: 8, description: shareText, state: .running, sent: 0, expected: 10),
                         SessionTask(id: 9, description: goneShare.taskDescription, state: .suspended, sent: 0, expected: 10)])
        addTeardownBlock { await h.tearDown() }
        try h.group.makeFolder("ShareInbox/\(G.batchID.uuidString)")
        try FixtureLoader.data("share/manifest-v2.json").write(to: h.group.url("ShareInbox/\(G.batchID.uuidString)/manifest.json"))

        let report = try await h.recovery.reconcile()
        XCTAssertEqual(h.backupSession.cancelled, [1])
        XCTAssertEqual(report.cancelled, 1)
        XCTAssertEqual(h.shareSession.cancelled, [9])
        XCTAssertEqual(report.adoptedShares, 1)
        XCTAssertEqual(report.cancelledShares, 1)
    }

    // MARK: R1: outcomes nobody applied

    /// An earlier build's receipt for the current stage commits the photo from the disk alone.
    func testLegacyReceiptOutcomeCommitsWithoutNetwork() async throws {
        let h = try await RecoveryHarness.legacy()
        addTeardownBlock { await h.tearDown() }
        try FixtureLoader.data("backup/outcome-created.json").write(to: h.group.url(Self.current + "/\(G.currentStage).receipt"))

        let report = try await h.recovery.reconcile()
        XCTAssertEqual(report.committed, 1)
        let receipt = try await h.receipt(G.l1)
        XCTAssertEqual(receipt?.original.id, G.originalAsset)
        XCTAssertEqual(receipt?.motion?.id, G.motionAsset)
        let confirmed = try await h.store.historyPage(offset: 0, limit: 10).map(\.localID.rawValue)
        XCTAssertTrue(confirmed.contains(G.l1))
        XCTAssertFalse(h.group.exists(Self.current), "The outcome and the stage go.")
        XCTAssertTrue(h.backupSession.uploads.isEmpty, "Nothing is sent.")
        // The album the photo waited for learns its server ID.
        let albums = try await h.store.runnableAlbumDestinations()
        XCTAssertFalse(albums.contains { $0.localID == G.l1 && $0.remoteID != G.originalAsset })
    }

    /// A stage an earlier build kept after its transfer completed (an album add failed after it)
    /// is finished from its outcome file, without sending the video again.
    func testSuspendedStageWithSuccessfulOutcomeFinalizesWithoutReupload() async throws {
        let h = try await RecoveryHarness.legacy()
        addTeardownBlock { await h.tearDown() }
        let id = "c0ffee00-1111-4222-8333-444455556666"
        try Data(#"{"receipt":{"status":"created","id":"\#(id)"}}"#.utf8).write(to: h.group.url(Self.suspended + "/\(G.suspendedStage).receipt"))

        let report = try await h.recovery.reconcile()
        XCTAssertEqual(report.committed, 1)
        let receipt = try await h.receipt(G.l6)
        XCTAssertEqual(receipt?.original.id, id)
        XCTAssertNil(receipt?.motion)
        XCTAssertEqual(receipt?.revision, AssetRevision(G.Dates.l6))
        let job = try await h.job(G.l6)
        XCTAssertNil(job)
        XCTAssertFalse(h.group.exists(Self.suspended))
        XCTAssertTrue(h.backupSession.uploads.isEmpty)
        let current = try await h.job(G.l1)
        XCTAssertEqual(current?.state, .staged, "The other stage stays as it was.")
    }

    /// A failed answer left on disk is no item failure: a lost connection, without a status, is
    /// an interrupted attempt, and a server error retries now. Both back up on the automatic run.
    func testStaleFailedOutcomeRetriesAutomatically() async throws {
        let h = try await RecoveryHarness.legacy()
        addTeardownBlock { await h.tearDown() }
        try FixtureLoader.data("backup/outcome-lost.json").write(to: h.group.url(Self.current + "/\(G.currentStage).receipt"))
        let attempt = AttemptID()
        let folder = try await h.seed("fresh", attempts: { folder in
            [LibraryAttempt(id: attempt, part: .original, state: .submitted, bodyPath: folder + "/\(attempt.rawValue).multipart", checksum: "sum-fresh")]
        })
        try OutcomeRecord.encoded(OutcomeRecord(error: "Service Unavailable", httpStatus: 503, v: 2))
            .write(to: h.group.url(folder + "/\(attempt.rawValue).receipt"))

        let report = try await h.recovery.reconcile()
        XCTAssertEqual(report.retrying, 1)
        XCTAssertEqual(report.failed, 0)
        let fresh = try await h.job("fresh")
        XCTAssertEqual(fresh?.state, .retryScheduled)
        XCTAssertEqual(fresh?.errorClass, "transient")
        let lost = try await h.job(G.l1)
        XCTAssertEqual(lost?.state, .staged)
        XCTAssertNil(lost?.errorClass)
        XCTAssertFalse(h.group.exists(Self.current + "/\(G.currentStage).receipt"))
        XCTAssertFalse(h.group.exists(folder + "/\(attempt.rawValue).receipt"))

        try await h.startEngine()
        try await untilTransfers("Both are backed up.") {
            let lost = try await h.receipt(G.l1), fresh = try await h.receipt("fresh")
            return lost != nil && fresh != nil
        }
        let failures = try await h.store.failures(limit: 10).map(\.source)
        XCTAssertFalse(failures.contains(.photo(DeviceAssetID(rawValue: G.l1))))
        await h.stopEngine()
    }

    /// A force quit cancels the task, and an earlier build recorded only "cancelled": the attempt is
    /// interrupted, not failed, and its body goes again under the same ID once the check accepts.
    func testForceQuitCancelledOutcomeIsResubmittedNotFailed() async throws {
        let h = try await RecoveryHarness.legacy()
        addTeardownBlock { await h.tearDown() }
        try FixtureLoader.data("backup/outcome-force-quit.json").write(to: h.group.url(Self.current + "/\(G.currentStage).receipt"))
        let body = h.group.url(Self.current + "/\(G.currentStage).multipart")
        try UploadBody.write(to: body, boundary: "Ilyich-" + G.currentStage, fields: ["livePhotoVideoId": G.motionAsset],
                             asset: UploadFile(url: h.group.url(Self.current + "/original"), filename: "IMG_0001.HEIC", contentType: "image/heic"),
                             sidecar: UploadFile(url: h.group.url(Self.current + "/sidecar"), filename: "IMG_0001.xmp", contentType: "application/rdf+xml"))

        let report = try await h.recovery.reconcile()
        XCTAssertEqual(report.resumable, 1)
        XCTAssertEqual(report.failed, 0)
        let job = try await h.job(G.l1)
        XCTAssertEqual(job?.state, .staged)
        XCTAssertNil(job?.errorClass, "Not the photo's failure.")
        let attempt = try await h.attempt(G.currentStage)
        XCTAssertEqual(attempt?.state, .interrupted)
        XCTAssertFalse(h.group.exists(Self.current + "/\(G.currentStage).receipt"), "The stale answer goes, so the body can go again.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: body.path), "The body is kept.")

        try await h.startEngine()
        try await untilTransfers("The photo is backed up.") { try await h.receipt(G.l1) != nil }
        let uploads = h.uploads.uploads.filter { $0.filename == "IMG_0001.HEIC" }
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads.first?.key.attempt.rawValue, G.currentStage, "The same attempt, with its own body.")
        XCTAssertEqual(uploads.first?.boundary, "Ilyich-" + G.currentStage)
        XCTAssertEqual(uploads.first?.fields["livePhotoVideoId"], G.motionAsset)
        XCTAssertEqual(h.server.checks.filter { $0.id == G.l1 }.count, 1, "Checked again by checksum first.")
        await h.stopEngine()
    }

    /// An earlier build's 401 replayed at launch says the session ended: the account's problem,
    /// never the photo's.
    func testReplayedHTTP401ClassifiedAsUnauthorized() async throws {
        let h = try await RecoveryHarness.legacy()
        addTeardownBlock { await h.tearDown() }
        let data = try FixtureLoader.data("backup/outcome-401.json")
        XCTAssertEqual(TransferFailureClassifier.classify(outcome: try JSONDecoder().decode(OutcomeRecord.self, from: data)), .account(.sessionExpired))
        try data.write(to: h.group.url(Self.current + "/\(G.currentStage).receipt"))

        let report = try await h.recovery.reconcile()
        XCTAssertEqual(report.restriction, .sessionExpired)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.retrying, 0)
        let job = try await h.job(G.l1)
        XCTAssertEqual(job?.state, .staged)
        XCTAssertNil(job?.errorClass)
        XCTAssertEqual(job?.retryCount, 0)
        let attempt = try await h.attempt(G.currentStage)
        XCTAssertEqual(attempt?.state, .failed)
        let status = try await h.dump("attempts").first { $0.first == .text(G.currentStage) }?[11]
        XCTAssertEqual(status, .integer(401))
        XCTAssertFalse(h.group.exists(Self.current + "/\(G.currentStage).receipt"))
    }

    // MARK: R3 and R4

    /// A new attempt's checksum is kept with its stage: resuming it after the app ended checks
    /// with that checksum and never reads the photo again.
    func testOriginalChecksumNotRecomputedOnResume() async throws {
        let h = try await RecoveryHarness.fresh()
        addTeardownBlock { await h.tearDown() }
        let attempt = AttemptID()
        let folder = try await h.seed("resumed", originalChecksum: "sum-resumed", attempts: { folder in
            [LibraryAttempt(id: attempt, part: .original, state: .submitted, bodyPath: folder + "/\(attempt.rawValue).multipart", checksum: "sum-resumed")]
        }, body: attempt)
        try await h.store.advanceForTest("resumed", to: .submitted)

        let report = try await h.recovery.reconcile()
        XCTAssertEqual(report.resumable, 1)
        let job = try await h.job("resumed")
        XCTAssertEqual(job?.state, .staged, "No task and no answer: it runs again.")
        XCTAssertTrue(h.group.exists(folder + "/\(attempt.rawValue).multipart"))

        try await h.startEngine()
        try await untilTransfers("The photo is backed up.") { try await h.receipt("resumed") != nil }
        XCTAssertEqual(h.hashes.value.count, 0, "The persisted checksum is used.")
        XCTAssertEqual(h.server.checks, [FakeTransferServer.Check(id: "resumed", checksum: "sum-resumed")])
        XCTAssertEqual(h.uploads.uploads.map(\.key.attempt), [attempt], "Its body goes again under its ID.")
        let receipt = try await h.receipt("resumed")
        XCTAssertEqual(receipt?.original.checksum, "sum-resumed")
        await h.stopEngine()
    }

    /// A body cut short is never sent: it is removed and a new one written. A job whose staged
    /// files are gone stages again from the start.
    func testCutShortBodyIsRebuiltAndMissingFilesStageAgain() async throws {
        let h = try await RecoveryHarness.fresh()
        addTeardownBlock { await h.tearDown() }
        let short = AttemptID()
        let shortFolder = try await h.seed("short", originalChecksum: "sum-short", attempts: { folder in
            [LibraryAttempt(id: short, part: .original, state: .bodyWritten, bodyPath: folder + "/\(short.rawValue).multipart", bodyBytes: 1, checksum: "sum-short")]
        }, body: short)
        let lost = AttemptID()
        let lostFolder = try await h.seed("lost", attempts: { folder in
            [LibraryAttempt(id: lost, part: .original, state: .interrupted, bodyPath: folder + "/\(lost.rawValue).multipart")]
        })
        try FileManager.default.removeItem(at: h.group.url(lostFolder + "/original"))

        let report = try await h.recovery.reconcile()
        XCTAssertEqual(report.rebuilt, 2)
        XCTAssertEqual(report.requeued, 1)
        XCTAssertFalse(h.group.exists(shortFolder + "/\(short.rawValue).multipart"), "Its recorded size doesn't match.")
        let shortAttempt = try await h.attempt(short.rawValue)
        XCTAssertEqual(shortAttempt?.state, .abandoned)
        let shortJob = try await h.job("short")
        XCTAssertEqual(shortJob?.state, .staged, "Its stage is whole: only the body is written again.")
        let lostJob = try await h.job("lost")
        XCTAssertEqual(lostJob?.state, .queued)
        XCTAssertNil(lostJob?.phase)
        let stages = try await h.dump("stages")
        XCTAssertEqual(stages.count, 1, "The lost job's stage goes.")
        XCTAssertFalse(h.group.exists(lostFolder))
    }

    /// Recovery runs only on a database the engine owns: on BackupCoordinator's shadow copy it
    /// changes nothing, on disk or with iOS.
    func testShadowCopyIsNeverReconciled() async throws {
        let descriptor = String(decoding: try FixtureLoader.data("backup/descriptor-backup.json"), as: UTF8.self)
        let h = try await RecoveryHarness.legacy(mode: .shadow, backupTasks: [
            SessionTask(id: 7, description: descriptor, state: .running, sent: 0, expected: 9),
            SessionTask(id: 8, description: TaskDescriptor.v2(attempt: AttemptID(), scope: G.digest, outcome: "Backup/x/y.receipt").taskDescription,
                        state: .running, sent: 0, expected: 9),
        ])
        addTeardownBlock { await h.tearDown() }
        try FixtureLoader.data("backup/outcome-created.json").write(to: h.group.url(Self.current + "/\(G.currentStage).receipt"))
        let orphan = "Backup/\(G.digest)/\(UUID().uuidString)"
        try h.group.write("old", to: orphan + "/original")
        let before = try await h.store.dump()

        do {
            _ = try await h.recovery.reconcile()
            XCTFail("A shadow copy is never reconciled.")
        } catch let error as Recovery.ReconcileError {
            XCTAssertEqual(error, .notOwned)
        }
        let after = try await h.store.dump()
        XCTAssertEqual(after, before)
        XCTAssertTrue(h.backupSession.cancelled.isEmpty)
        XCTAssertTrue(h.group.exists(Self.current + "/\(G.currentStage).receipt"))
        XCTAssertTrue(h.group.exists(orphan))
    }
}

// MARK: - Support

/// A transfers database the engine owns, in a throwaway App Group, with faked background sessions
/// and the library job executor on a fake server and fake uploads, for what runs after recovery.
struct RecoveryHarness {
    let group: TemporaryAppGroup
    let folder: URL
    let account: AccountID
    let store: TransferStore
    let backupSession: FakeTransportSession
    let shareSession: FakeTransportSession
    let recovery: Recovery
    let hashes = Locked<[URL]>([])
    let server = FakeTransferServer()
    let uploads: FakeUploads
    let engine: TransferEngine<TestClock>
    /// An hour from now, so files the test writes are past staging's grace period.
    let now = Date().addingTimeInterval(3_600)

    private init(account: AccountID, backupTasks: [SessionTask], shareTasks: [SessionTask],
                 prepare: (TemporaryAppGroup, TransferStore) async throws -> Void) async throws {
        group = try TemporaryAppGroup()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Recovery-" + UUID().uuidString, isDirectory: true)
        self.account = account
        store = TransferStore(url: folder.appendingPathComponent("transfers.sqlite"))
        try await prepare(group, store)
        let journal = group.journal
        backupSession = FakeTransportSession(tasks: backupTasks)
        shareSession = FakeTransportSession(tasks: shareTasks)
        let backupSession = self.backupSession, shareSession = self.shareSession
        let backup = BackgroundTransport(session: .backup, journal: journal, emit: { _ in }, uptime: { .zero }) { backupSession.attach($0) }
        let share = BackgroundTransport(session: .shareUpload, journal: journal, emit: { _ in }, uptime: { .zero }) { shareSession.attach($0) }
        let hashes = self.hashes
        let hash: @Sendable (URL) async throws -> String = { url in
            hashes.mutate { $0.append(url) }
            return try UploadBody.checksum(url)
        }
        let now = self.now
        recovery = Recovery(store: store, account: account, layout: group.layout, backup: backup, share: share, checksum: hash, now: { now })
        uploads = FakeUploads(group: group)
        let executor = LibraryJobExecutor(store: store, staging: FakeStaging(), server: server, uploader: uploads, layout: group.layout,
                                          account: account, checksum: hash)
        let clock = TestClock()
        engine = TransferEngine(store: store, executor: executor, authorization: FakeTransferAuthorization(), clock: clock,
                                concurrency: executor.concurrency,
                                now: { now.addingTimeInterval(TimeInterval(clock.now.offset.components.seconds)) }, random: { 0.5 })
    }

    /// state.json with a current Live Photo stage and a suspended video stage, imported, with the
    /// stages' files on disk.
    static func legacy(mode: LegacyBackupImporter.Mode = .authoritative, backupTasks: [SessionTask] = []) async throws -> RecoveryHarness {
        try await RecoveryHarness(account: LegacyGoldens.account, backupTasks: backupTasks, shareTasks: []) { group, store in
            let backup = group.url(AccountStoragePaths(LegacyGoldens.account).backup)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try JSONEncoder().encode(LegacyGoldens.backupState()).write(to: backup.appendingPathComponent("state.json"))
            let report = await LegacyBackupImporter(mode: mode, store: store, folder: backup).run()
            XCTAssertEqual(report?.outcome, .imported)
            let current = "Backup/\(LegacyGoldens.digest)/\(LegacyGoldens.currentFolder)"
            try group.write("still of IMG_0001", to: current + "/original")
            try group.write("video of IMG_0001", to: current + "/motion")
            try group.write("<xmp/>", to: current + "/sidecar")
            try group.write("video IMG_0006", to: "Backup/\(LegacyGoldens.digest)/\(LegacyGoldens.suspendedFolder)/original")
        }
    }

    /// A fresh database the engine claimed.
    static func fresh(backupTasks: [SessionTask] = [], shareTasks: [SessionTask] = []) async throws -> RecoveryHarness {
        try await RecoveryHarness(account: LegacyGoldens.account, backupTasks: backupTasks, shareTasks: shareTasks) { _, store in
            try await store.claimForEngine()
            try await store.savePreferences(LibraryJobHarness.preferences())
        }
    }

    /// A job with a stage of the photo's own file and the attempts `attempts` makes, as an earlier
    /// run left it, with a complete body for `body`. Returns the stage's folder.
    @discardableResult
    func seed(_ id: String, originalChecksum: String? = nil, attempts: (String) -> [LibraryAttempt] = { _ in [] },
              body: AttemptID? = nil) async throws -> String {
        _ = try await store.enqueue([TransferRequest(source: .photo(DeviceAssetID(rawValue: id)), origin: .selection)])
        let token = UUID()
        guard let job = try await store.job(lane: .library, sourceKey: id), try await store.lease(job: job.id, token: token) else {
            throw TransferEngineHarness.Missing()
        }
        let folder = AccountStoragePaths(account).backup + "/" + UUID().uuidString
        try group.write("photo " + id, to: folder + "/original")
        let original = StagedFile(path: folder + "/original", filename: id + ".HEIC", contentType: "image/heic")
        let stage = LibraryStage(stageID: UUID().uuidString, folder: folder, revision: AssetRevision(FakeStaging.date), original: original,
                                 motion: nil, sidecar: nil, fields: ["isFavorite": "false"], isVideo: false, originalChecksum: originalChecksum)
        _ = try await store.saveStage(stage, job: job.id, token: token)
        for var attempt in attempts(folder) {
            if attempt.id == body {
                let url = group.url(folder + "/\(attempt.id.rawValue).multipart")
                try UploadBody.write(to: url, boundary: LibraryJobExecutor.boundary(attempt.id), fields: stage.fields,
                                     asset: UploadFile(url: group.url(original.path), filename: original.filename, contentType: original.contentType))
                if attempt.bodyBytes == nil {
                    attempt.bodyBytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                }
            }
            _ = try await store.saveAttempt(attempt, job: job.id, token: token)
        }
        _ = try await store.advance(job: job.id, token: token, to: .staged, phase: nil)
        try await store.release(job: job.id, token: token)
        return folder
    }

    func startEngine() async throws {
        try await engine.setIntent(.automatic)
        try await engine.start()
    }

    func stopEngine() async { await engine.stop() }

    func job(_ id: String) async throws -> StoredJob? { try await store.job(lane: .library, sourceKey: id) }
    func receipt(_ id: String) async throws -> TransferReceipt? { try await store.receipts(for: [id])[id] }
    func dump(_ table: String) async throws -> [[TransferSQLite.Value]] { try await store.dump()[table] ?? [] }

    func attempt(_ id: String) async throws -> LibraryAttempt? {
        for entry in try await store.recoveryJobs() {
            if let found = entry.attempts.first(where: { $0.id.rawValue == id }) { return found }
        }
        return nil
    }

    func tearDown() async {
        await engine.stop()
        await store.close()
        try? FileManager.default.removeItem(at: folder)
        group.remove()
    }
}

extension TransferStore {
    /// Sets a job's state as an earlier run left it.
    func advanceForTest(_ id: String, to state: JobState) throws {
        try database().run("UPDATE jobs SET state=? WHERE lane='library' AND source_key=?", [.text(state.rawValue), .text(id)])
    }
}

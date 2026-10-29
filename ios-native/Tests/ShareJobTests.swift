import Foundation
import IlyichPlatform
import IlyichShareInbox
import XCTest
@testable import Ilyich

/// The share executor on an engine that owns a fresh database, with a share batch in a throwaway
/// App Group, a fake server and a fake transport.
struct ShareJobHarness {
    let group: TemporaryAppGroup
    let folder: URL
    let store: TransferStore
    let clock = TestClock()
    let authorization = FakeTransferAuthorization()
    let server = FakeTransferServer()
    let uploads: FakeUploads
    let inbox: ShareInboxRepository
    let executor: ShareJobExecutor
    let batch = UUID()
    static let account = FakeTransferAuthorization.account

    init() async throws {
        group = try TemporaryAppGroup()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShareJobs-" + UUID().uuidString, isDirectory: true)
        store = TransferStore(url: folder.appendingPathComponent("transfers.sqlite"))
        try await store.claimForEngine()
        uploads = FakeUploads(group: group)
        inbox = ShareInboxRepository(root: group.url(ShareInboxRepository.folderName))
        executor = ShareJobExecutor(store: store, inbox: inbox, server: server, uploader: uploads, layout: group.layout, account: Self.account)
    }

    func engine() -> TransferEngine<TestClock> {
        let clock = self.clock
        return TransferEngine(store: store, executor: executor, authorization: authorization, clock: clock,
                              now: { TransferEngineHarness.base.addingTimeInterval(TimeInterval(clock.now.offset.components.seconds)) },
                              random: { 0.5 })
    }

    var batchFolder: String { ShareInboxRepository.folderName + "/" + batch.uuidString }

    /// A batch of photos named `names`, as the Share extension saves it.
    func share(_ names: [String]) async throws {
        let folder = try await inbox.createFolder(for: batch)
        for name in names { try Data("shared \(name)".utf8).write(to: folder.appendingPathComponent(name)) }
        let attachments = names.map { SharedAttachment(original: SharedFile(name: $0, filename: "IMG_\($0).JPG", contentType: "image/jpeg", folder: folder)) }
        try await inbox.save(SharedBatch(id: batch, createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000), attachments: attachments))
    }

    func request(_ name: String, notification: UUID? = nil) -> TransferRequest {
        TransferRequest(source: .shared(batch: batch, attachment: name), origin: .shareApproval, displayName: "IMG_\(name).JPG", batch: notification)
    }

    /// The names the batch's manifest still lists, or nil once the batch is gone.
    func listed() async -> [String]? {
        guard case .ready(let batch)? = await inbox.batch(batch) else { return nil }
        return batch.attachments.map(\.id)
    }

    /// The file's deterministic identity.
    func identity(_ name: String) throws -> AttemptID {
        let path = batchFolder + "/" + name
        let checksum = try UploadBody.checksum(group.url(path))
        return AttemptID(legacy: ShareJobExecutor.identity(scope: Self.account.digest, path: path, checksum: checksum, sidecarChecksum: "",
                                                           livePhotoVideoID: ""))
    }

    func tearDown(_ engines: TransferEngine<TestClock>...) async {
        for engine in engines { await engine.stop() }
        await store.close()
        try? FileManager.default.removeItem(at: folder)
        group.remove()
    }
}

/// B4: shared files upload as share jobs, in place, under a deterministic identity, and their
/// manifest is rewritten after the commit.
final class ShareJobTests: XCTestCase {
    func testUploadsInPlaceAndConsumesAfterTheCommit() async throws {
        let h = try await ShareJobHarness()
        try await h.share(["a", "b"])
        let identity = try h.identity("a")
        let engine = h.engine()
        let result = try await engine.enqueue([h.request("a")])
        XCTAssertEqual(result, .queued(1))
        try await engine.start()

        try await untilTransfers("the first file consumed") { await h.listed() == ["b"] }
        let upload = try XCTUnwrap(h.uploads.uploads.first)
        XCTAssertEqual(upload.key, AttemptKey(attempt: identity, scope: ShareJobHarness.account.digest, folder: h.batchFolder))
        XCTAssertEqual(upload.boundary, identity.rawValue)
        XCTAssertEqual(upload.filename, "IMG_a.JPG")
        XCTAssertEqual(h.server.checks.map(\.id), ["a"], "the upload check is by file name")
        XCTAssertFalse(h.group.exists(h.batchFolder + "/a"))
        XCTAssertTrue(h.group.exists(h.batchFolder + "/b"))
        let consumed = try await h.store.consumedShares()
        XCTAssertTrue(consumed.isEmpty, "the record goes once the manifest is rewritten")
        let attempts = try await h.store.dump()["attempts"] ?? []
        XCTAssertTrue(attempts.isEmpty)
        await h.tearDown(engine)
    }

    func testErrorsSurviveRestart() async throws {
        let h = try await ShareJobHarness()
        try await h.share(["a"])
        let checksum = try UploadBody.checksum(h.group.url(h.batchFolder + "/a"))
        h.server.hold(checksum: checksum, as: .rejected("unsupported"))
        let engine = h.engine()
        _ = try await engine.enqueue([h.request("a")])
        try await engine.start()
        try await untilTransfers("the file failed") { try await engine.failures(limit: 10).count == 1 }
        await engine.stop()

        // A new launch: the failure is still there, with its message, and the file waits.
        let relaunched = h.engine()
        try await relaunched.start()
        let failures = try await relaunched.failures(limit: 10)
        XCTAssertEqual(failures.map(\.source), [.shared(batch: h.batch, attachment: "a")])
        XCTAssertEqual(failures.first?.message, TransferItemFailure.rejected(nil).localizedDescription)
        XCTAssertNotNil(failures.first?.failedAt)
        let listed = await h.listed()
        XCTAssertEqual(listed, ["a"])
        XCTAssertEqual(h.server.checks.count, 1, "a failed file waits for the user")
        await h.tearDown(relaunched)
    }

    func testConsumeIdempotentAfterCrash() async throws {
        let h = try await ShareJobHarness()
        try await h.share(["a", "b"])
        _ = try await h.store.enqueue([h.request("a")])
        // The upload commits, then the app ends before the manifest is rewritten.
        let token = UUID()
        let found = try await h.store.job(lane: .share, sourceKey: h.request("a").source.key)
        let job = try XCTUnwrap(found)
        _ = try await h.store.lease(job: job.id, token: token)
        let committed = try await h.store.completeShare(job: job.id, token: token, batch: h.batch, attachment: "a", remoteID: "srv-a", at: Date())
        XCTAssertTrue(committed)
        let listed = await h.listed()
        XCTAssertEqual(listed, ["a", "b"])

        // Approving it again before the replay doesn't upload it twice.
        let again = try await h.store.enqueue([h.request("a")])
        XCTAssertEqual(again.queued, 0)
        XCTAssertEqual(again.alreadyBackedUp, 1)

        let settled = await h.executor.replayConsumed()
        XCTAssertEqual(settled, 1)
        let afterReplay = await h.listed()
        XCTAssertEqual(afterReplay, ["b"])
        let replayedAgain = await h.executor.replayConsumed()
        XCTAssertEqual(replayedAgain, 0)
        let afterSecond = await h.listed()
        XCTAssertEqual(afterSecond, ["b"])

        // A crash after the rewrite but before the record went: the replay only forgets it.
        _ = try await h.store.enqueue([h.request("b")])
        let foundSecond = try await h.store.job(lane: .share, sourceKey: h.request("b").source.key)
        let second = try XCTUnwrap(foundSecond)
        _ = try await h.store.lease(job: second.id, token: token)
        _ = try await h.store.completeShare(job: second.id, token: token, batch: h.batch, attachment: "b", remoteID: "srv-b", at: Date())
        try await h.inbox.consume("b", from: h.batch)
        let last = await h.executor.replayConsumed()
        XCTAssertEqual(last, 1)
        let gone = await h.listed()
        XCTAssertNil(gone, "consuming the last file removed the batch")
        let consumed = try await h.store.consumedShares()
        XCTAssertTrue(consumed.isEmpty)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        await h.tearDown()
    }

    /// An upload of the file iOS still holds under its identity, from before a relaunch, is
    /// adopted and its answer applied, never sent again.
    func testAnUploadIOSStillHoldsIsAdopted() async throws {
        let h = try await ShareJobHarness()
        try await h.share(["a"])
        let identity = try h.identity("a")
        h.uploads.holdTask(for: identity)
        let engine = h.engine()
        _ = try await engine.enqueue([h.request("a")])
        try await engine.start()

        try await untilTransfers("the adopted upload consumed") { await h.listed() == nil }
        XCTAssertEqual(h.uploads.adopted.map(\.attempt), [identity])
        XCTAssertEqual(h.uploads.adopted.first?.folder, h.batchFolder)
        XCTAssertTrue(h.uploads.uploads.isEmpty, "nothing is sent again")
        XCTAssertTrue(h.server.checks.isEmpty)
        await h.tearDown(engine)
    }

    func testAStaleFailedOutcomeIsDeletedBeforeSendingAgain() async throws {
        let h = try await ShareJobHarness()
        try await h.share(["a"])
        let identity = try h.identity("a")
        // An earlier try of this identity failed and its answer is still on disk.
        h.uploads.record(OutcomeRecord(httpStatus: 500, v: 2), for: identity)
        let engine = h.engine()
        _ = try await engine.enqueue([h.request("a")])
        try await engine.start()

        try await untilTransfers("the file uploaded") { await h.listed() == nil }
        XCTAssertEqual(h.uploads.acknowledged.first, identity, "the stale answer went first")
        XCTAssertEqual(h.uploads.uploads.map(\.key.attempt), [identity], "then the same identity was sent once")
        await h.tearDown(engine)
    }

    func testARetryReusesTheIdentity() async throws {
        let h = try await ShareJobHarness()
        try await h.share(["a"])
        h.uploads.answer("IMG_a.JPG", .status(503))
        let engine = h.engine()
        _ = try await engine.enqueue([h.request("a")])
        try await engine.start()
        try await untilTransfers("the first try failed") {
            try await h.store.job(lane: .share, sourceKey: h.request("a").source.key)?.state == .retryScheduled
        }
        h.clock.advance(by: .seconds(60))
        try await untilTransfers("the retry uploaded") { await h.listed() == nil }
        let keys = h.uploads.uploads.map(\.key.attempt)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 1, "every retry uses the same identity")
        await h.tearDown(engine)
    }

    func testAGoneOrDamagedBatchFailsTheJob() async throws {
        let h = try await ShareJobHarness()
        try await h.share(["a"])
        try Data("{".utf8).write(to: h.group.url(h.batchFolder + "/" + ShareManifest.fileName))
        let engine = h.engine()
        _ = try await engine.enqueue([h.request("a"), TransferRequest(source: .shared(batch: UUID(), attachment: "z"), origin: .shareApproval)])
        try await engine.start()
        try await untilTransfers("both failed") { try await engine.failures(limit: 10).count == 2 }
        let messages = try await engine.failures(limit: 10).compactMap(\.message)
        XCTAssertTrue(messages.contains(ShareJobExecutor.goneMessage))
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        await h.tearDown(engine)
    }

    /// After a relaunch, recovery hands a share job the transport had back to the executor, which
    /// adopts its task, and cancels a version 2 share task of the account no share job waits for.
    func testRecoveryResumesShareJobsAndCancelsTheirOrphanTasks() async throws {
        let digest = LegacyGoldens.digest
        let bound = AttemptID(), orphan = AttemptID()
        func v2(_ attempt: AttemptID, scope: String = digest) -> String {
            TaskDescriptor.v2(attempt: attempt, scope: scope, outcome: "ShareInbox/\(UUID().uuidString)/\(attempt.rawValue).receipt").taskDescription!
        }
        let h = try await RecoveryHarness.fresh(shareTasks: [
            SessionTask(id: 1, description: v2(bound), state: .running, sent: 0, expected: 10),
            SessionTask(id: 2, description: v2(orphan), state: .running, sent: 0, expected: 10),
            SessionTask(id: 3, description: v2(AttemptID(), scope: "someone-else"), state: .running, sent: 0, expected: 10),
        ])
        addTeardownBlock { await h.tearDown() }
        let source = TransferSource.shared(batch: UUID(), attachment: "a")
        _ = try await h.store.enqueue([TransferRequest(source: source, origin: .shareApproval)])
        let token = UUID()
        let found = try await h.store.job(lane: .share, sourceKey: source.key)
        let job = try XCTUnwrap(found)
        _ = try await h.store.lease(job: job.id, token: token)
        let saved = try await h.store.saveAttempt(LibraryAttempt(id: bound, part: .original, state: .submitted, taskID: 1), session: .shareUpload,
                                                  job: job.id, token: token)
        XCTAssertTrue(saved)
        _ = try await h.store.advance(job: job.id, token: token, to: .submitted, phase: ShareJobExecutor.Phase.original)
        try await h.store.release(job: job.id, token: token)

        let report = try await h.recovery.reconcile()
        XCTAssertEqual(h.shareSession.cancelled, [2])
        XCTAssertEqual(report.adoptedShares, 1)
        XCTAssertEqual(report.cancelledShares, 1)
        XCTAssertEqual(report.resumedShares, 1)
        let resumed = try await h.store.job(lane: .share, sourceKey: source.key)
        XCTAssertEqual(resumed?.state, .staged)
        let attempts = try await h.store.dump()["attempts"] ?? []
        XCTAssertEqual(attempts.first?[3], .text(TransferSessionID.shareUpload.rawValue), "the try is recorded on the share-upload session")
    }
}

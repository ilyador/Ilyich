import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

final class LibraryPipelineOptimizationTests: XCTestCase {
    func testKnownCopyCanCompleteWhileAnUnrelatedCloudStageHoldsTheOnlyPreparationSlot() async throws {
        let h = try await LibraryJobHarness(limits: .init(staged: 1, submitted: 2))
        h.staging.add("cloud")
        h.staging.add("known")
        let cloud = TransferGate()
        h.staging.hold("cloud", at: cloud)
        let checker = ReadyCopyChecker()
        let executor = LibraryJobExecutor(store: h.store, staging: h.staging, server: h.server, uploader: h.uploads,
                                         layout: h.group.layout, account: LibraryJobHarness.account, pipeline: h.pipeline,
                                         knownBackupChecker: checker)
        let engine = makeEngine(h, executor: executor)
        _ = try await engine.enqueue([.init(source: .photo(.init(rawValue: "cloud")), origin: .selection)])
        try await engine.setIntent(.manual)
        try await engine.start()
        await untilTransfers("The cloud export holds the preparation permit.") { cloud.waiting == 1 }
        XCTAssertEqual(h.pipeline.stagedCount, 1)
        _ = try await engine.enqueue([.init(source: .photo(.init(rawValue: "known")), origin: .selection)])
        try await untilTransfers("An already-known backup bypasses the held cloud staging permit.") { try await h.receipt("known") != nil }
        XCTAssertEqual(h.staging.stagings("known"), 0)
        XCTAssertEqual(h.staging.stagings("cloud"), 1)
        XCTAssertEqual(h.pipeline.stagedCount, 1)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        try await engine.setIntent(.paused)
        cloud.open()
        await engine.stop()
        await h.tearDown()
    }

    func testSourceReadFailureCannotDelayCurrentUploadHandoffAndLeavesDurableAssociationWork() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "source-sum"))
        h.staging.failSource("edit") { CocoaError(.fileReadNoSuchFile) }
        let answer = TransferGate()
        h.uploads.hold(at: answer)
        try await h.run("edit")
        await untilTransfers("The current rendition reaches the background transport.") { h.uploads.waiting == 1 }
        let handoff = await h.engine.handoff()
        XCTAssertEqual(handoff, .handedToDaemon)
        XCTAssertEqual(h.staging.sourceProbes, 0)
        XCTAssertEqual(h.staging.sourceReads, 0)
        XCTAssertEqual(h.server.checks.count, 1, "Only the current rendition participates in the critical upload path.")
        answer.open()
        try await untilTransfers("Current upload completion leaves a durable original-matching task.") { try await h.receipt("edit") != nil }
        let pending = try await h.store.sourceMatchTasks()
        XCTAssertEqual(pending.first?.state, "pending")
        XCTAssertEqual(pending.first?.localID, "edit")
        let saved = try await h.receipt("edit")
        let receipt = try XCTUnwrap(saved)
        h.server.remote(.init(id: receipt.original.id, ownerId: "owner", checksum: receipt.original.checksum,
                              isTrashed: false, livePhotoVideoId: nil))
        h.server.hold(checksum: "source-sum", as: .duplicate("archive", trashed: false))
        let worker = PostUploadWorker(store: h.store, server: h.server, photos: h.staging, authorization: h.authorization,
                                      conditionsPermit: { _ in true })
        let deferred = await worker.runPass(linkedAlbums: false)
        XCTAssertEqual(deferred.originals.retrying, 1)
        XCTAssertEqual(deferred.originalReasons["missingOriginal"], 1)
        h.staging.clearSourceFailure("edit")
        try await h.store.requeueSourceMatches(includeFailed: true)
        let matched = await worker.runPass(linkedAlbums: false)
        XCTAssertEqual(matched.originals.done, 1)
        let finished = try await h.store.sourceMatchTasks()
        XCTAssertEqual(finished.first?.state, "done")
        XCTAssertEqual(h.uploads.uploads.count, 1, "Retrying original matching never uploads the current edit again.")
        let unchanged = try await h.receipt("edit")
        XCTAssertEqual(unchanged, receipt)
        await worker.stop()
        await h.tearDown()
    }

    func testExportedChecksumsPersistWithTheStageAndAvoidFileHashingAcrossRelaunch() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("live", .init(modified: FakeStaging.date, isLive: true, exportChecksums: true))
        let hashCalls = Locked(0)
        let first = makeEngine(h, executor: hashCountingExecutor(h, calls: hashCalls))
        h.uploads.answer("live-live.MOV", .status(503))
        _ = try await first.enqueue([.init(source: .photo(.init(rawValue: "live")), origin: .selection)])
        try await first.setIntent(.manual)
        try await first.start()
        try await untilTransfers("The first upload waits for its retry with its stage persisted.") { try await h.job("live")?.state == .retryScheduled }
        let job = try await h.job("live")
        let stage = try await h.store.libraryStage(job: try XCTUnwrap(job).id)
        let original = try XCTUnwrap(stage?.originalChecksum)
        let motion = try XCTUnwrap(stage?.motionChecksum)
        XCTAssertFalse(original.isEmpty)
        XCTAssertFalse(motion.isEmpty)
        XCTAssertNotEqual(original, motion)
        XCTAssertEqual(hashCalls.value, 0)
        await first.stop()
        h.clock.advance(by: .seconds(31))
        let relaunched = makeEngine(h, executor: hashCountingExecutor(h, calls: hashCalls))
        try await relaunched.start()
        try await untilTransfers("The resumed stage finishes using its exported byte fingerprints.") { try await h.receipt("live") != nil }
        let receipt = try await h.receipt("live")
        XCTAssertEqual(receipt?.original.checksum, original)
        XCTAssertEqual(receipt?.motion?.checksum, motion)
        XCTAssertEqual(hashCalls.value, 0, "Neither exported file is read again for its checksum, even after relaunch.")
        XCTAssertEqual(h.staging.stagings("live"), 1)
        XCTAssertEqual(h.server.checks.map(\.checksum), [motion, motion, original])
        await relaunched.stop()
        await h.tearDown()
    }

    func testDeviceConditionsAreRecheckedAfterWaitingForAStagingPermit() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("photo")
        let allowed = Locked(true)
        let checker = CountingUnknownChecker()
        let executor = LibraryJobExecutor(store: h.store, staging: h.staging, server: h.server, uploader: h.uploads,
                                         layout: h.group.layout, account: LibraryJobHarness.account, pipeline: h.pipeline,
                                         conditionsPermit: { _ in allowed.value }, knownBackupChecker: checker)
        let held = try await h.pipeline.acquireStaging()
        let engine = makeEngine(h, executor: executor)
        _ = try await engine.enqueue([.init(source: .photo(.init(rawValue: "photo")), origin: .selection)])
        try await engine.setIntent(.manual)
        try await engine.start()
        await untilTransfers("The lightweight existing-copy check runs ahead of the occupied staging permit.") { checker.calls.value == 1 }
        allowed.mutate { $0 = false }
        h.pipeline.release(held)
        await untilTransfers("Changed device conditions stop file preparation.") { await engine.currentSnapshot.phase == .waiting(.deviceConditions) }
        XCTAssertTrue(h.staging.staged.isEmpty)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        await engine.stop()
        await h.tearDown()
    }

    private func hashCountingExecutor(_ h: LibraryJobHarness, calls: Locked<Int>) -> LibraryJobExecutor {
        LibraryJobExecutor(store: h.store, staging: h.staging, server: h.server, uploader: h.uploads,
                           layout: h.group.layout, account: LibraryJobHarness.account, checksum: { _ in
                               calls.mutate { $0 += 1 }
                               throw CocoaError(.fileReadNoSuchFile)
                           })
    }

    private func makeEngine(_ h: LibraryJobHarness, executor: LibraryJobExecutor) -> TransferEngine<TestClock> {
        let clock = h.clock
        return TransferEngine(store: h.store, executor: executor, authorization: h.authorization, clock: clock,
                              concurrency: executor.concurrency,
                              now: { TransferEngineHarness.base.addingTimeInterval(TimeInterval(clock.now.offset.components.seconds)) },
                              random: { 0.5 })
    }
}

private struct ReadyCopyChecker: KnownBackupCopyChecking {
    func check(_ localID: String, context: JobContext) async throws -> KnownBackupCopyResult {
        try await context.ensureOwned()
        guard localID == "known" else { return .unknown }
        let revision = AssetRevision(FakeStaging.date)
        return .backedUp(.backedUp(revision: revision, assetID: "known-server",
                                  receipt: .init(localID: localID, revision: revision, original: .init(id: "known-server", checksum: "known-sum"),
                                                 motion: nil, confirmedAt: nil)))
    }
}

private struct CountingUnknownChecker: KnownBackupCopyChecking {
    let calls = Locked(0)
    func check(_ localID: String, context: JobContext) async throws -> KnownBackupCopyResult {
        try await context.ensureOwned()
        calls.mutate { $0 += 1 }
        return .unknown
    }
}

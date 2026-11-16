import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

final class SourceMatchFollowUpTests: XCTestCase {
    private func remote(_ id: String, checksum: String, owner: String = "owner") -> BackupRemoteAsset {
        .init(id: id, ownerId: owner, checksum: checksum, isTrashed: false, livePhotoVideoId: nil, visibility: "archive")
    }

    func testDeferredSourceThenCompletedEditRetriesThroughWorkerWithoutAnotherUpload() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "source-sum"))
        h.staging.deferSource("edit", reason: .libraryChanged)
        try await h.run("edit")
        try await untilTransfers("The current edit completes even though its source was deferred.") { try await h.receipt("edit") != nil }
        try await h.engine.setIntent(.paused)
        await h.engine.stop()
        let savedReceipt = try await h.receipt("edit")
        let receipt = try XCTUnwrap(savedReceipt)
        let before = try await h.store.contents()
        let tasks = try await h.store.sourceMatchTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.currentID, receipt.original.id)
        XCTAssertEqual(tasks.first?.state, "pending")
        let server = FakeFollowUpServer()
        server.uploads.remote(remote(receipt.original.id, checksum: receipt.original.checksum))
        server.uploads.remote(remote("archive", checksum: "source-sum"))
        server.uploads.hold(checksum: "source-sum", as: .duplicate("archive", trashed: false))
        let clock = Locked(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let worker = PostUploadWorker(store: h.store, server: server, photos: h.staging, authorization: h.authorization,
                                      now: { clock.value }, conditionsPermit: { _ in true })
        let deferred = await worker.runPass(linkedAlbums: false)
        XCTAssertEqual(deferred.originals.retrying, 1)
        XCTAssertEqual(deferred.originalReasons["libraryChanged"], 1)
        let waiting = try await h.store.sourceMatchTasks()
        XCTAssertEqual(waiting.first?.reason, "libraryChanged")
        XCTAssertEqual(waiting.first?.notBefore, clock.value.addingTimeInterval(30))
        h.staging.deferSource("edit", reason: nil)
        let tooSoon = await worker.runPass(linkedAlbums: false)
        XCTAssertEqual(tooSoon.originals.done, 0)
        clock.mutate { $0 = $0.addingTimeInterval(31) }
        let resolved = await worker.runPass(linkedAlbums: false)
        XCTAssertEqual(resolved.originals.done, 1)
        XCTAssertEqual(server.stackCalls, [[receipt.original.id, "archive"]])
        let finished = try await h.store.sourceMatchTasks()
        XCTAssertEqual(finished.first?.state, "done")
        let after = try await h.store.contents()
        XCTAssertEqual(after.receipts, before.receipts)
        XCTAssertEqual(after.confirmations, before.confirmations)
        XCTAssertEqual(after.engine, before.engine)
        XCTAssertEqual(after.preferences, before.preferences)
        XCTAssertEqual(after.jobs, before.jobs)
        XCTAssertEqual(after.attempts, before.attempts)
        XCTAssertEqual(h.uploads.uploads.count, 1)
        XCTAssertTrue(server.uploads.requests.isEmpty)
        await worker.stop()
        await h.tearDown()
    }

    func testDeferredTimingAndReasonSurviveRestartAndStartupResumesOnlyAssociationWork() async throws {
        let h = try await PostUploadHarness()
        h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "source"))
        h.staging.deferSource("edit", reason: .cloudRequired)
        try await h.backUp("edit", as: "current")
        _ = await h.worker.runPass(linkedAlbums: false)
        let before = try await h.store.contents()
        let pending = try await h.store.sourceMatchTasks()
        XCTAssertEqual(pending.first?.reason, "cloudRequired")
        await h.worker.stop()
        await h.store.close()
        let reopened = TransferStore(url: h.store.url)
        let restored = try await reopened.sourceMatchTasks()
        XCTAssertEqual(restored, pending)
        h.staging.deferSource("edit", reason: nil)
        h.server.uploads.remote(remote("current", checksum: "sum-current"))
        h.server.uploads.remote(remote("archive", checksum: "source"))
        h.server.uploads.hold(checksum: "source", as: .duplicate("archive", trashed: false))
        let clock = h.clock
        clock.mutate { $0 = $0.addingTimeInterval(31) }
        let worker = PostUploadWorker(store: reopened, server: h.server, photos: h.staging, authorization: h.authorization,
                                      now: { clock.value }, conditionsPermit: { _ in true })
        await worker.request(.started)
        await worker.idle()
        let finished = try await reopened.sourceMatchTasks()
        XCTAssertEqual(finished.first?.state, "done")
        XCTAssertEqual(h.server.stackCalls, [["current", "archive"]])
        let after = try await reopened.contents()
        XCTAssertEqual(after.receipts, before.receipts)
        XCTAssertEqual(after.confirmations, before.confirmations)
        XCTAssertEqual(after.jobs, before.jobs)
        XCTAssertEqual(after.attempts, before.attempts)
        XCTAssertTrue(h.server.uploads.requests.isEmpty)
        await worker.stop()
        await reopened.close()
        await h.tearDown()
    }

    func testUneditedTasksAreTerminalWithoutServerReadsAndPagesAreBounded() async throws {
        let h = try await PostUploadHarness()
        for n in 0..<51 {
            let id = String(format: "photo-%03d", n)
            h.staging.add(id)
            try await h.backUp(id)
        }
        let first = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(first.originals.done, 25)
        XCTAssertEqual(h.staging.sourceProbes, 25)
        _ = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(h.staging.sourceProbes, 50)
        _ = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(h.staging.sourceProbes, 51)
        _ = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(h.staging.sourceProbes, 51, "Terminal unedited revisions are not probed again on every commit.")
        let tasks = try await h.store.sourceMatchTasks()
        XCTAssertTrue(tasks.allSatisfy { $0.state == "notApplicable" && $0.reason == "unedited" })
        XCTAssertEqual(h.server.uploads.checkCallCount, 0)
        XCTAssertTrue(h.server.uploads.remoteReads.isEmpty)
        XCTAssertTrue(h.server.uploads.requests.isEmpty)
        await h.tearDown()
    }

    func testConditionsWakePolicyDeferralsButOrdinaryCommitsPreserveBackoff() async throws {
        let h = try await PostUploadHarness()
        h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "source"))
        h.staging.deferSource("edit", reason: .waitingForWiFi)
        try await h.backUp("edit", as: "current")
        _ = await h.worker.runPass(linkedAlbums: false)
        let probes = h.staging.sourceProbes
        await h.worker.request(.committed(.library))
        await h.worker.idle()
        XCTAssertEqual(h.staging.sourceProbes, probes)
        var preferences = try await h.store.preferences() ?? TransferPreferences()
        preferences.downloadCloudOriginals = true
        preferences.cellularPhotos = false
        try await h.store.savePreferences(preferences)
        h.staging.deferSource("edit", reason: nil)
        h.server.uploads.remote(remote("current", checksum: "sum-current"))
        h.server.uploads.remote(remote("archive", checksum: "source"))
        h.server.uploads.hold(checksum: "source", as: .duplicate("archive", trashed: false))
        await h.worker.request(.conditionsChanged)
        await h.worker.idle()
        XCTAssertEqual(h.server.stackCalls, [["current", "archive"]])
        XCTAssertEqual(h.staging.sourcePolicies.last?.allowCloud, true)
        XCTAssertEqual(h.staging.sourcePolicies.last?.cellularPhotos, false)
        await h.tearDown()
    }

    func testAccountAndDeviceRestrictionsLeaveTasksAndBackupProofUntouched() async throws {
        let allowed = Locked(false)
        let h = try await PostUploadHarness(conditionsPermit: { _ in allowed.value })
        h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "source"))
        try await h.backUp("edit", as: "current")
        let before = try await h.store.contents()
        let pending = try await h.store.sourceMatchTasks()
        let blocked = await h.worker.runPass(linkedAlbums: false)
        XCTAssertTrue(blocked.waitingForDevice)
        XCTAssertEqual(h.staging.sourceProbes, 0)
        let after = try await h.store.sourceMatchTasks()
        XCTAssertEqual(after, pending)
        allowed.mutate { $0 = true }
        h.authorization.setReadOnly(true)
        let restricted = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(restricted.stoppedBy, .readOnly)
        let proof = try await h.store.contents()
        XCTAssertEqual(proof.receipts, before.receipts)
        XCTAssertEqual(proof.confirmations, before.confirmations)
        XCTAssertEqual(h.staging.sourceProbes, 0)
        XCTAssertTrue(h.server.stackCalls.isEmpty)
        await h.tearDown()
    }

    func testChangedSourceCacheCannotBeQueuedOrMarkedDoneByAnOlderProof() async throws {
        for remove in [false, true] {
            let h = try await PostUploadHarness()
            try await h.backUp("edit", as: "current")
            let rows = try await h.store.sourceMatchTasks()
            let row = try XCTUnwrap(rows.first)
            let fingerprint = SourceOriginalFingerprint(revision: row.revision, checksum: "proved-source")
            let source = SourceOriginalAssociation(localID: "edit", revision: row.revision, checksum: "proved-source", remoteID: "archive", fingerprint: fingerprint)
            try await h.store.saveSourceOriginal(source)
            if remove {
                try await h.store.forgetSourceOriginal("edit", revision: row.revision)
            } else {
                try await h.store.saveSourceOriginal(.init(localID: "edit", revision: row.revision, checksum: "replacement", remoteID: "wrong-archive",
                                                         fingerprint: .init(revision: row.revision, checksum: "replacement")))
            }
            let committed = try await h.store.finishSourceMatchTask(row, .matched(source), at: h.clock.value)
            XCTAssertFalse(committed)
            let tasks = try await h.store.sourceMatchTasks()
            XCTAssertEqual(tasks.first?.state, "pending")
            XCTAssertEqual(tasks.first?.reason, "sourceEvidenceChanged")
            let stacks = try await h.store.stackTasks()
            XCTAssertTrue(stacks.isEmpty)
            await h.tearDown()
        }
    }

    func testSupersededReceiptAndRevokedTransactionCannotScheduleOldAssociation() async throws {
        let h = try await PostUploadHarness()
        try await h.backUp("edit", as: "old-current")
        let oldRows = try await h.store.sourceMatchTasks()
        let old = try XCTUnwrap(oldRows.first)
        let source = SourceOriginalAssociation(localID: "edit", revision: old.revision, checksum: "source", remoteID: "archive",
                                               fingerprint: .init(revision: old.revision, checksum: "source"))
        try await h.store.saveSourceOriginal(source)
        try await h.backUp("edit", as: "new-current")
        let stale = try await h.store.finishSourceMatchTask(old, .matched(source), at: h.clock.value)
        XCTAssertFalse(stale)
        let newRows = try await h.store.sourceMatchTasks()
        let new = try XCTUnwrap(newRows.first)
        do {
            _ = try await h.store.finishSourceMatchTask(new, .matched(source), at: h.clock.value, permits: { false })
            XCTFail("The transaction must recheck account permission.")
        } catch is CancellationError {}
        let current = try await h.store.sourceMatchTasks()
        XCTAssertEqual(current.first?.currentID, "new-current")
        XCTAssertEqual(current.first?.state, "pending")
        let stacks = try await h.store.stackTasks()
        XCTAssertFalse(stacks.contains { $0.previousAssetID == "archive" })
        await h.tearDown()
    }

    func testChangedCompleteSnapshotReprobesAndDeferredFreshProbeRetainsOldCandidate() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "new-source"))
        let revision = AssetRevision(FakeStaging.date)
        let old = SourceOriginalAssociation(localID: "edit", revision: revision, checksum: "old-source", remoteID: "old-archive",
                                            fingerprint: .init(revision: revision, checksum: "old-source"))
        try await h.store.saveSourceOriginal(old)
        h.staging.validateSource("edit", as: [.stale(.snapshotChanged)])
        h.staging.probeSource("edit", as: [.deferred(.libraryChanged)])
        let matcher = SourceOriginalArchiveMatcher(account: LibraryJobHarness.account, store: h.store, staging: h.staging, server: h.server)
        let deferred = try await matcher.attempt("edit", revision: revision, policy: .init())
        XCTAssertEqual(deferred, .deferred(.libraryChanged))
        let retained = try await h.store.sourceOriginal(for: "edit", revision: revision)
        XCTAssertEqual(retained, old)
        h.staging.validateSource("edit", as: [.stale(.snapshotChanged)])
        h.server.hold(checksum: "new-source", as: .duplicate("new-archive", trashed: false))
        h.server.remote(remote("new-archive", checksum: "new-source"))
        let resolved = try await matcher.match("edit", revision: revision, policy: .init())
        XCTAssertEqual(resolved?.checksum, "new-source")
        XCTAssertEqual(resolved?.remoteID, "new-archive")
        XCTAssertEqual(h.staging.sourceReads, 1)
        await h.tearDown()
    }
}

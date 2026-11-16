import Foundation
import Photos
import XCTest
@testable import Ilyich

final class NewPhotosBackupTests: XCTestCase {
    func testMetadataBaselineExcludesEighteenThousandExistingIDsAndOldEditsButAcceptsNewOldDatedItem() async throws {
        let h = try await LibraryJobHarness()
        for n in 0..<18_000 { h.staging.add("old-\(n)", album: nil) }
        var seed = TransferSeed()
        seed.confirmations = [("old-0", FakeStaging.date)]
        seed.receipts = [.init(localID: "old-0", modified: FakeStaging.date, originalID: "saved-copy", originalChecksum: "saved-bytes")]
        try await h.store.seedForTest(seed)
        let before = try await h.store.contents()
        try await h.engine.enableNewPhotosBackup(staging: h.staging, cancelAttempts: { _ in })
        let baseline = try await h.store.newPhotosBaselineIDs()
        XCTAssertEqual(baseline?.count, 18_000)
        let preferences = try await h.store.preferences()
        XCTAssertEqual(preferences?.newPhotosOnly, true)
        XCTAssertEqual(preferences?.automatic, true)
        XCTAssertEqual(preferences?.scope, .entireLibrary)
        XCTAssertNotNil(preferences?.newPhotosBaselineStartedAt)
        let measured = await h.engine.currentSnapshot
        XCTAssertEqual(measured.confirmed, 0, "Past confirmations remain history, not future-mode progress.")
        XCTAssertEqual(measured.selectionProgress?.total, 0)
        XCTAssertEqual(EngineBackend.presented(measured, preferences: preferences).activity, "Waiting for new photos")
        let history = try await h.store.contents()
        XCTAssertEqual(history.confirmations, before.confirmations)
        XCTAssertEqual(history.receipts, before.receipts)
        h.staging.edit("old-1", modified: FakeStaging.date.addingTimeInterval(500))
        h.staging.add("new-import-with-old-date", .init(modified: Date(timeIntervalSinceReferenceDate: -1_000_000), isVideo: true), album: nil)
        let verifies = Locked(0)
        let discovery = LibraryDiscovery(store: h.store, staging: h.staging, revalidateConfirmations: { verifies.mutate { $0 += 1 } })
        let result = try await discovery.run()
        XCTAssertEqual(result.inventory?.revisions.keys.sorted(), ["new-import-with-old-date"])
        XCTAssertEqual(result.queued, 1)
        XCTAssertEqual(verifies.value, 0)
        XCTAssertEqual(h.staging.sourceReads, 0)
        XCTAssertEqual(h.staging.sourceProbes, 0)
        XCTAssertTrue(h.staging.staged.isEmpty)
        XCTAssertEqual(h.server.checkCallCount, 0)
        XCTAssertTrue(h.server.remoteReads.isEmpty)
        XCTAssertTrue(h.server.requests.isEmpty)
        await h.tearDown()
    }

    func testReenableAndRestartPreserveOriginalBaselineAndStartDate() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("old")
        try await h.engine.enableNewPhotosBackup(staging: h.staging, cancelAttempts: { _ in })
        let first = try await h.store.newPhotosBaselineIDs()
        let date = try await h.store.newPhotosBaselineStartedAt()
        h.staging.add("new")
        try await h.engine.enableNewPhotosBackup(staging: h.staging, cancelAttempts: { _ in XCTFail("Already enabled mode needs no new cutover.") })
        let second = try await h.store.newPhotosBaselineIDs()
        XCTAssertEqual(second, first)
        var preferences = try await h.store.preferences() ?? TransferPreferences()
        preferences.newPhotosOnly = false
        preferences.automatic = false
        try await h.engine.setIntent(.paused)
        try await h.engine.setPreferences(preferences)
        try await h.engine.enableNewPhotosBackup(staging: h.staging, cancelAttempts: { _ in })
        let reenabled = try await h.store.newPhotosBaselineIDs()
        let sameDate = try await h.store.newPhotosBaselineStartedAt()
        XCTAssertEqual(reenabled, first)
        XCTAssertEqual(sameDate, date)
        await h.engine.stop()
        await h.store.close()
        let reopened = TransferStore(url: h.store.url)
        let persisted = try await reopened.newPhotosBaselineIDs()
        let persistedDate = try await reopened.newPhotosBaselineStartedAt()
        XCTAssertEqual(persisted, first)
        XCTAssertEqual(persistedDate, date)
        let eligible = try await reopened.filterNewPhotosCandidates([.init(id: "old", modified: FakeStaging.date), .init(id: "new", modified: FakeStaging.date)])
        XCTAssertEqual(eligible.map(\.id), ["new"])
        await reopened.close()
        await h.tearDown()
    }

    func testCutoverCancelsAllOldLibraryJobsAndCollectsSubmittedAttemptsWhilePreservingShares() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("old-submitted")
        h.staging.add("old-failed")
        let attempt = AttemptID()
        try await h.seed("old-submitted", stage: { folder in
            LibraryStage(stageID: UUID().uuidString, folder: folder, revision: .init(FakeStaging.date),
                         original: try! h.stagedFile(folder, "original", filename: "old.JPG", contents: "old bytes"),
                         motion: nil, sidecar: nil, fields: [:], isVideo: false)
        }, attempts: [.init(id: attempt, part: .original, state: .submitted, taskID: 42)])
        let ghostAttempt = AttemptID()
        // The asset has left Photos, but its staged body can still be held by iOS.
        try await h.seed("gone-from-photos", stage: { folder in
            LibraryStage(stageID: UUID().uuidString, folder: folder, revision: .init(FakeStaging.date),
                         original: try! h.stagedFile(folder, "original", filename: "gone.JPG", contents: "gone bytes"),
                         motion: nil, sidecar: nil, fields: [:], isVideo: false)
        }, attempts: [.init(id: ghostAttempt, part: .original, state: .submitted, taskID: 43)])
        var seed = TransferSeed()
        seed.jobs = [.init(localID: "old-failed", origin: .albumUpload, state: .failed)]
        try await h.store.seedForTest(seed)
        let share = TransferSource.shared(batch: UUID(), attachment: "keep.jpg")
        _ = try await h.store.enqueue([.init(source: share, origin: .shareApproval)])
        let cancelled = Locked<[AttemptID]>([])
        try await h.engine.enableNewPhotosBackup(staging: h.staging, cancelAttempts: { ids in cancelled.mutate { $0 += ids } })
        XCTAssertEqual(Set(cancelled.value), [attempt, ghostAttempt])
        let remaining = try await h.store.contents()
        XCTAssertTrue(remaining.jobs.isEmpty)
        XCTAssertTrue(remaining.attempts.isEmpty)
        XCTAssertTrue(remaining.stages.isEmpty)
        let shareJob = try await h.store.job(lane: .share, sourceKey: share.key)
        XCTAssertNotNil(shareJob)
        // A late completion cannot resurrect an excluded job or its receipt.
        let receipt = TransferReceipt(localID: "old-submitted", revision: .init(FakeStaging.date), original: .init(id: "late", checksum: "sum"), motion: nil, confirmedAt: nil)
        let late = try await h.store.complete(.init(job: 1, lease: nil, localID: "old-submitted", revision: .init(FakeStaging.date), assetID: "late", receipt: receipt, confirmedAt: Date()))
        XCTAssertFalse(late)
        let saved = try await h.store.receipts(for: ["old-submitted"])
        XCTAssertTrue(saved.isEmpty)
        let state = try await h.store.engineState()
        XCTAssertEqual(state?.intent, .automatic)
        await h.tearDown()
    }

    func testFullPhotosAccessAndAccountEpochAreFencedWithoutOriginalOrServerReads() async throws {
        for reason in ["limited", "access-cycle", "account"] {
            let h = try await LibraryJobHarness()
            h.staging.add("old")
            if reason == "limited" { h.staging.setAccess(.limited) }
            let gate = TransferGate()
            if reason != "limited" { h.staging.holdDiscovery(at: gate) }
            let activating = Task { try await h.engine.enableNewPhotosBackup(staging: h.staging, cancelAttempts: { _ in }) }
            if reason != "limited" {
                await untilTransfers("Baseline metadata capture reaches its fence.") { h.staging.discoveryWaits }
                if reason == "account" { h.authorization.accessChanged() }
                else { h.staging.setAccess(.limited); h.staging.setAccess(.authorized) }
                gate.open()
            }
            do { try await activating.value; XCTFail("A changed or limited access snapshot cannot create a baseline.") } catch {}
            let baseline = try await h.store.newPhotosBaselineIDs()
            XCTAssertNil(baseline, reason)
            let preferences = try await h.store.preferences()
            XCTAssertEqual(preferences?.newPhotosOnly, false, reason)
            XCTAssertEqual(preferences?.automatic, false, reason)
            XCTAssertTrue(h.staging.staged.isEmpty)
            XCTAssertEqual(h.staging.sourceReads, 0)
            XCTAssertTrue(h.server.remoteReads.isEmpty)
            XCTAssertEqual(h.server.checkCallCount, 0)
            await h.tearDown()
        }
    }

    func testPendingOldDiscoveryCannotMergeOrVerifyAfterActivation() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("old")
        let gate = TransferGate()
        h.staging.holdDiscovery(at: gate)
        let verifies = Locked(0)
        let discovery = LibraryDiscovery(store: h.store, staging: h.staging, revalidateConfirmations: { verifies.mutate { $0 += 1 } })
        let oldPass = Task { try await discovery.run() }
        await untilTransfers("The old discovery is waiting on Photos metadata.") { h.staging.discoveryWaits }
        h.staging.clearDiscoveryHold()
        try await h.engine.enableNewPhotosBackup(staging: h.staging, cancelAttempts: { _ in })
        gate.open()
        do { _ = try await oldPass.value; XCTFail("The previous discovery belongs to the old policy.") } catch {}
        XCTAssertEqual(verifies.value, 0)
        let jobs = try await h.store.contents().jobs
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertEqual(h.staging.sourceProbes, 0)
        await h.tearDown()
    }

    func testAutomaticRequeueCannotBypassBaselineButLaterExplicitManualUploadCan() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("old")
        try await h.engine.enableNewPhotosBackup(staging: h.staging, cancelAttempts: { _ in })
        let automatic = try await h.store.enqueue([.init(source: .photo(.init(rawValue: "old")), origin: .discovery)])
        XCTAssertEqual(automatic.queued, 0)
        let explicit = try await h.store.enqueue([.init(source: .photo(.init(rawValue: "old")), origin: .selection)])
        XCTAssertEqual(explicit.queued, 1)
        let job = try await h.store.reserve(lane: .library, now: Date(), token: UUID(), epoch: 1)
        XCTAssertEqual(job?.origin, .selection)
        await h.tearDown()
    }

    func testInterruptedCaptureCanBeRetriedAndMissingReadyBaselineFailsClosed() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("old")
        try await h.store.beginNewPhotosPolicyChange(UUID(), permits: { true })
        try await h.engine.enableNewPhotosBackup(staging: h.staging, cancelAttempts: { _ in })
        let changing = try await h.store.newPhotosPolicyChanging()
        XCTAssertFalse(changing)
        let baseline = try await h.store.newPhotosBaselineIDs()
        XCTAssertEqual(baseline, ["old"])
        try await h.store.removeReadyNewPhotosMarkerForTest()
        do {
            _ = try await LibraryDiscovery(store: h.store, staging: h.staging).run()
            XCTFail("Missing baseline metadata must never expose past photos to backup.")
        } catch {}
        do {
            _ = try await h.store.reserve(lane: .library, now: Date(), token: UUID(), epoch: 1)
            XCTFail("A missing baseline cannot reserve automatic work.")
        } catch {}
        XCTAssertTrue(h.staging.staged.isEmpty)
        XCTAssertEqual(h.staging.sourceReads, 0)
        XCTAssertEqual(h.server.checkCallCount, 0)
        await h.tearDown()
    }
}

private extension TransferStore {
    func removeReadyNewPhotosMarkerForTest() throws { try database().run("DELETE FROM new_photos_baseline_state") }
}

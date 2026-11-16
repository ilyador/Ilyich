import Foundation
import XCTest
@testable import Ilyich

final class PhotoBackupStatusTests: XCTestCase {
    func testGridBadgeUsesSharedPresentationAndKeepsServerPresenceSeparate() {
        let revision = AssetRevision(referenceSeconds: 700_000_000.25)
        let completed = PhotoBackupStatus(localID: "phone", revision: revision, phase: .completed)
        let outside = PhotoBackupStatus(localID: "old", revision: revision, phase: .outsideAutomaticBackup)
        let notQueued = PhotoBackupStatus(localID: "unscheduled", revision: revision, phase: .notQueued)

        XCTAssertEqual(PhotoGridBackupBadge(hasLocalPhoto: false, isServerAsset: false, status: nil).symbol, nil)
        XCTAssertEqual(PhotoGridBackupBadge(hasLocalPhoto: true, isServerAsset: false, status: nil).symbol, "icloud")
        XCTAssertEqual(PhotoGridBackupBadge(hasLocalPhoto: false, isServerAsset: true, status: nil).accessibilityText, "On server")
        XCTAssertEqual(PhotoGridBackupBadge(hasLocalPhoto: true, isServerAsset: false, status: completed).accessibilityText, "Backed up")
        XCTAssertEqual(PhotoGridBackupBadge(hasLocalPhoto: true, isServerAsset: false, status: outside).symbol, "icloud.slash")
        XCTAssertEqual(PhotoGridBackupBadge(hasLocalPhoto: true, isServerAsset: false, status: notQueued).symbol, "icloud")
        XCTAssertEqual(PhotoGridBackupBadge(hasLocalPhoto: true, isServerAsset: true, status: notQueued).accessibilityText, "On server")
    }

    func testExactRevisionCompletionStaleRevisionAndPausedQueue() async throws {
        let h = try await TransferEngineHarness()
        let current = AssetRevision(referenceSeconds: 700_000_000.25)
        let older = AssetRevision(referenceSeconds: 700_000_000.0)
        var seed = TransferSeed()
        seed.confirmations = [("confirmed", current.date)]
        seed.jobs = [.init(localID: "queued", state: .queued), .init(localID: "waiting", state: .waiting)]
        try await h.store.seedForTest(seed)

        let statuses = try await h.engine.photoBackupStatuses(for: [
            .init(localID: "confirmed", revision: current),
            .init(localID: "queued", revision: current),
            .init(localID: "waiting", revision: current),
            .init(localID: "missing", revision: current),
            .init(localID: "unknown", revision: nil)
        ])
        XCTAssertEqual(statuses["confirmed"]?.phase, .completed)
        XCTAssertEqual(statuses["waiting"]?.phase, .paused, "A paused run takes precedence over a persisted waiting reason.")
        let stale = try await h.engine.photoBackupStatus(localID: "confirmed", revision: older)
        XCTAssertNotEqual(stale.phase, .completed, "A confirmation for a different revision is not completion proof.")
        XCTAssertEqual(statuses["queued"]?.phase, .paused)
        XCTAssertEqual(statuses["missing"]?.phase, .notQueued)
        XCTAssertEqual(statuses["unknown"]?.phase, .unknown)
        await h.tearDown()
    }

    func testBaselineExclusionAndFailureAreReportedAfterCurrentProofCheck() async throws {
        let h = try await TransferEngineHarness()
        let revision = AssetRevision(referenceSeconds: 700_000_000.25)
        let prefs = try await h.store.preferences() ?? TransferPreferences()
        let futurePreferences = try await h.store.commitNewPhotosBackupBaseline(["old", "old-confirmed"],
            startedAt: TransferEngineHarness.base, expectedPreferences: prefs, permits: { true })
        var seed = TransferSeed()
        seed.preferences = futurePreferences
        seed.confirmations = [("old-confirmed", revision.date)]
        seed.jobs = [.init(localID: "failed", state: .failed,
                           failure: .init(message: "Upload rejected", date: TransferEngineHarness.base, filename: "IMG_1.HEIC"))]
        try await h.store.seedForTest(seed)

        let statuses = try await h.engine.photoBackupStatuses(for: [
            .init(localID: "old", revision: revision),
            .init(localID: "old-confirmed", revision: revision),
            .init(localID: "failed", revision: revision)
        ])
        XCTAssertEqual(statuses["old"]?.phase, .outsideAutomaticBackup)
        XCTAssertEqual(statuses["old-confirmed"]?.phase, .completed, "A matching confirmation outranks baseline exclusion.")
        XCTAssertEqual(statuses["failed"]?.phase, .needsAttention(message: "Upload rejected"))
        await h.tearDown()
    }

    func testUploadingUsesOnlyMatchingJobsRealProgress() async throws {
        let h = try await TransferEngineHarness()
        let gate = TransferGate()
        h.executor.script("upload", .report(count: 4, gate))
        _ = try await h.engine.enqueue([h.photo("upload"), h.photo("second")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The item reports upload bytes.") { gate.waiting == 1 }

        let statuses = try await h.engine.photoBackupStatuses(for: [
            .init(localID: "upload", revision: AssetRevision(referenceSeconds: 700_000_000.25)),
            .init(localID: "second", revision: AssetRevision(referenceSeconds: 700_000_000.25))
        ])
        XCTAssertEqual(statuses["upload"]?.phase, .uploading(progress: 1))
        XCTAssertEqual(statuses["second"]?.phase, .waiting(message: nil), "Bytes from one active job never appear on another item's status.")
        gate.open()
        await h.engine.stop()
        await h.tearDown()
    }

    func testOldStagedRevisionDoesNotDescribeCurrentEditAndSubmittedJobSurvivesWithoutLease() async throws {
        let h = try await TransferEngineHarness()
        let current = AssetRevision(referenceSeconds: 700_000_000.25)
        let old = AssetRevision(referenceSeconds: 700_000_000.0)
        var seed = TransferSeed()
        seed.jobs = [.init(localID: "edited", state: .submitting), .init(localID: "submitted", state: .submitted)]
        seed.stages = [
            Self.stage(localID: "edited", revision: old, stageID: "stage-edited"),
            Self.stage(localID: "submitted", revision: current, stageID: "stage-submitted")
        ]
        try await h.store.seedForTest(seed)

        let statuses = try await h.engine.photoBackupStatuses(for: [
            .init(localID: "edited", revision: current),
            .init(localID: "submitted", revision: current)
        ])
        XCTAssertEqual(statuses["edited"]?.phase, .unknown)
        XCTAssertEqual(statuses["submitted"]?.phase, .uploading(progress: nil), "A background-owned task can upload without an in-memory lease.")
        await h.tearDown()
    }

    private static func stage(localID: String, revision: AssetRevision, stageID: String) -> TransferSeed.Stage {
        let folder = "Backup/test/\(stageID)"
        return TransferSeed.Stage(localID: localID, stageID: stageID, folder: folder, modified: revision.date,
            original: StagedFile(path: folder + "/original", filename: "IMG_1.HEIC", contentType: "image/heic"))
    }
}

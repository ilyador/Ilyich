import Foundation
import XCTest
import UIKit
@testable import Ilyich

final class PhotoBackupStatusTests: XCTestCase {
    func testFinishedAndInactiveItemsHaveNoOverlay() {
        let inactive: [PhotoBackupPhase] = [.completed, .outsideAutomaticBackup, .notQueued, .unknown,
                                           .waiting(message: nil), .paused, .needsAttention(message: "Retry needed")]
        for phase in inactive {
            let status = PhotoBackupStatus(localID: "phone", revision: nil, phase: phase)
            for onServer in [false, true] {
                let badge = PhotoGridBackupBadge(hasLocalPhoto: true, isServerAsset: onServer, status: status)
                XCTAssertNil(badge.symbol, "Only active work belongs over an image: \(phase)")
                XCTAssertNil(badge.accessibilityText)
                XCTAssertFalse(PhotoBackupPresentation(status: status, isServerAsset: onServer).isActive)
            }
        }
        XCTAssertNil(PhotoGridBackupBadge(hasLocalPhoto: false, isServerAsset: true, status: nil).symbol)
        XCTAssertNil(PhotoGridBackupBadge(hasLocalPhoto: true, isServerAsset: false, status: nil).symbol)
        // Saved backup information is still available in the Info sheet.
        XCTAssertEqual(PhotoBackupPresentation(status: nil, isServerAsset: true).title, "On server")
    }

    func testOnlyActiveItemCarriesItsMeasuredProgress() {
        for phase in [PhotoBackupPhase.uploading(progress: 0.42), .preparing(progress: 0.42)] {
            let status = PhotoBackupStatus(localID: "active", revision: nil, phase: phase)
            let presentation = PhotoBackupPresentation(status: status, isServerAsset: false)
            let badge = PhotoGridBackupBadge(hasLocalPhoto: true, isServerAsset: false, status: status)
            XCTAssertTrue(presentation.isActive)
            XCTAssertEqual(presentation.progress, 0.42)
            XCTAssertEqual(badge.progress, 0.42)
            XCTAssertEqual(badge.accessibilityText, presentation.title)
        }
        let unknown = PhotoBackupPresentation(status: .init(localID: "active", revision: nil,
            phase: .uploading(progress: nil)), isServerAsset: false)
        XCTAssertTrue(unknown.isActive)
        XCTAssertNil(unknown.progress, "Unknown byte counts must stay indeterminate.")
    }

    @MainActor func testThumbnailProgressIsVisibleOnlyUntilCompletionAndCellReuse() {
        let cell = PhotoCell(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        func overlay() -> UIView? { cell.contentView.subviews.first { $0.accessibilityIdentifier == "library.backupProgress" } }
        func capture(_ name: String) {
            cell.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: cell.bounds).image { cell.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
        }
        cell.setBackupStatus(.init(localID: "active", revision: nil, phase: .uploading(progress: 0.42)),
                             isServerAsset: false, hasLocalPhoto: true)
        XCTAssertNotNil(overlay())
        let title = PhotoBackupPresentation(status: .init(localID: "active", revision: nil,
            phase: .uploading(progress: 0.42)), isServerAsset: false).title
        XCTAssertTrue(cell.accessibilityLabel?.contains(title) == true)
        capture("Thumbnail — uploading 42 percent")
        cell.setBackupStatus(.init(localID: "active", revision: nil, phase: .preparing(progress: nil)),
                             isServerAsset: false, hasLocalPhoto: true)
        XCTAssertNotNil(overlay())
        capture("Thumbnail — preparing without percentage")
        cell.setBackupStatus(.init(localID: "active", revision: nil, phase: .completed),
                             isServerAsset: true, hasLocalPhoto: true)
        XCTAssertNil(overlay(), "Completion removes the overlay, including its spinner.")
        cell.setBackupStatus(.init(localID: "active", revision: nil, phase: .uploading(progress: 0.2)),
                             isServerAsset: false, hasLocalPhoto: true)
        cell.prepareForReuse()
        XCTAssertNil(overlay(), "An unrelated photo must never inherit the prior upload indicator.")
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

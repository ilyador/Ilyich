import Foundation
import XCTest
@testable import Ilyich

final class FutureBackupSuppressionTests: XCTestCase {
    private func activate(_ h: PostUploadHarness, baseline: Set<String>) async throws {
        let preferences = try await h.store.preferences() ?? TransferPreferences()
        _ = try await h.store.commitNewPhotosBackupBaseline(baseline, startedAt: h.clock.value,
                                                           expectedPreferences: preferences, permits: { true })
    }

    private func remote(_ id: String, checksum: String) -> BackupRemoteAsset {
        .init(id: id, ownerId: "owner", checksum: checksum, isTrashed: false, livePhotoVideoId: nil, visibility: "archive")
    }

    func testBaselineFollowUpsNeverHashOrReadServerWhileFutureSourceWorkStillRuns() async throws {
        let h = try await PostUploadHarness()
        h.staging.add("old", .init(modified: FakeStaging.date, sourceChecksum: "past-source"))
        try await h.backUp("old", as: "past-copy", album: PostUploadHarness.albumA)
        try await h.backUp("old", as: "past-edit", album: PostUploadHarness.albumA)
        let before = try await h.store.contents()
        try await activate(h, baseline: ["old"])
        _ = await h.worker.runPass(linkedAlbums: true)
        XCTAssertEqual(h.staging.sourceProbes, 0)
        XCTAssertEqual(h.staging.sourceReads, 0)
        XCTAssertTrue(h.server.uploads.remoteReads.isEmpty)
        XCTAssertEqual(h.server.uploads.checkCallCount, 0)
        XCTAssertTrue(h.server.stackCalls.isEmpty)
        XCTAssertTrue(h.server.albumCalls.isEmpty)
        let due = try await h.store.nextSourceMatchDue()
        XCTAssertNil(due, "Excluded past tasks cannot keep scheduling retry wakeups.")
        let after = try await h.store.contents()
        XCTAssertEqual(after.confirmations, before.confirmations)
        XCTAssertEqual(after.receipts, before.receipts)

        h.staging.add("new", .init(modified: FakeStaging.date, sourceChecksum: "new-source"))
        try await h.backUp("new", as: "new-edit")
        h.server.uploads.hold(checksum: "new-source", as: .duplicate("new-original", trashed: false))
        h.server.uploads.remote(remote("new-original", checksum: "new-source"))
        h.server.uploads.remote(remote("new-edit", checksum: "sum-new-edit"))
        let result = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(result.originals.done, 1)
        XCTAssertEqual(h.staging.sourceProbes, 1)
        XCTAssertEqual(h.server.stackCalls, [["new-edit", "new-original"]])
        XCTAssertTrue(h.server.uploads.remoteReads.allSatisfy { $0 == "new-original" || $0 == "new-edit" })
        XCTAssertTrue(h.server.albumCalls.isEmpty)
        XCTAssertTrue(h.server.uploads.requests.isEmpty)
        await h.tearDown()
    }

    func testLinkedAlbumCopiesOnlyFutureReceipts() async throws {
        let h = try await PostUploadHarness()
        var preferences = LibraryJobHarness.preferences()
        preferences.syncAlbums = true
        try await h.store.savePreferences(preferences)
        h.staging.add("old")
        try await h.backUp("old", as: "past-copy")
        try await activate(h, baseline: ["old"])
        let pastOnly = await h.worker.runPass(linkedAlbums: true)
        XCTAssertEqual(pastOnly.linkedAlbums, 0)
        XCTAssertTrue(h.server.created.isEmpty)
        XCTAssertTrue(h.server.albumCalls.isEmpty)
        h.staging.add("new")
        try await h.backUp("new", as: "new-copy")
        let future = await h.worker.runPass(linkedAlbums: true)
        XCTAssertEqual(future.linkedAlbums, 1)
        XCTAssertEqual(h.server.albumCalls.count, 1)
        XCTAssertEqual(h.server.albumCalls.first?.ids, ["new-copy"])
        XCTAssertTrue(h.server.uploads.remoteReads.isEmpty, "Unedited future items do not need source proof reads.")
        await h.tearDown()
    }

    func testWorkerSuspensionHoldsWakeRequestsUntilPolicyCommit() async throws {
        let h = try await PostUploadHarness()
        h.staging.add("old", .init(modified: FakeStaging.date, sourceChecksum: "past-source"))
        try await h.backUp("old", as: "past-copy")
        await h.worker.suspendForNewPhotosPolicyChange()
        await h.worker.request(.committed(.library))
        XCTAssertEqual(h.staging.sourceProbes, 0)
        try await activate(h, baseline: ["old"])
        await h.worker.resumeAfterNewPhotosPolicyChange()
        await h.worker.idle()
        XCTAssertEqual(h.staging.sourceProbes, 0)
        XCTAssertTrue(h.server.uploads.remoteReads.isEmpty)
        XCTAssertTrue(h.server.stackCalls.isEmpty)
        await h.tearDown()
    }

    func testOldStackPageCannotStarveAFutureStack() async throws {
        let h = try await PostUploadHarness()
        let old = Set((0..<501).map { "old-\($0)" })
        try await activate(h, baseline: old)
        try await h.store.seedSuppressedStackPage(old: old.sorted(), future: "new")
        _ = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(h.server.stackCalls, [["new-current", "new-prior"]])
        XCTAssertTrue(h.server.uploads.remoteReads.isEmpty)
        XCTAssertEqual(h.staging.sourceProbes, 0)
        await h.tearDown()
    }
}

private extension TransferStore {
    func seedSuppressedStackPage(old: [String], future: String) throws {
        let db = try database()
        try db.transaction {
            for id in old + [future] {
                try db.run("INSERT INTO stack_tasks(local_id,asset_id,previous_asset_id,state,attempts) VALUES(?,?,?,'pending',0)",
                           [.text(id), .text(id + "-current"), .text(id + "-prior")])
            }
        }
    }
}

import Foundation
import XCTest
@testable import Ilyich

final class SelectionProgressTests: XCTestCase {
    func testMeasuredInventoryUnionsAlbumsSubtractsExclusionsAndRequiresCurrentRevisions() async throws {
        let h = try await TransferEngineHarness()
        let photos = FakeStaging()
        photos.add("current", album: "a")
        photos.add("current", album: "b")
        photos.add("edited", album: "a")
        photos.add("new", album: "b")
        photos.add("excluded", album: "a")
        photos.add("excluded", album: "exclude")
        photos.add("outside", album: "outside")
        var seed = TransferSeed()
        seed.preferences.includedAlbums = ["a", "b"]
        seed.preferences.excludedAlbums = ["exclude"]
        seed.confirmations = [("current", FakeStaging.date), ("edited", Date(timeIntervalSinceReferenceDate: 1)),
                              ("outside", FakeStaging.date), ("historical-only", FakeStaging.date)]
        seed.jobs = [.init(localID: "new", state: .failed)]
        try await h.store.seedForTest(seed)
        try await h.engine.start()
        _ = try await h.engine.discover(LibraryDiscovery(store: h.store, staging: photos))
        let snapshot = await h.engine.currentSnapshot
        let progress = try XCTUnwrap(snapshot.selectionProgress)
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.backedUp, 1)
        XCTAssertEqual(progress.remaining, 2)
        XCTAssertEqual(progress.unchecked, 2)
        XCTAssertEqual(progress.pending, 0)
        XCTAssertNil(progress.fraction, "Unconfirmed items are unchecked, not proven absent from Immich.")
        XCTAssertEqual(progress.checkedAt, TransferEngineHarness.base)
        XCTAssertEqual(snapshot.confirmed, 4, "Historical confirmations remain separate from selected inventory.")
        XCTAssertEqual(snapshot.failed, 1)
        await h.tearDown()
    }

    func testOutsideUploadsDoNotAdvanceSelectionAndDuplicateCompletionsCountOnce() async throws {
        let h = try await TransferEngineHarness()
        let photos = FakeStaging()
        photos.add("selected")
        var preferences = TransferPreferences()
        preferences.includedAlbums = [FakeStaging.album]
        try await h.store.savePreferences(preferences)
        try await h.engine.start()
        _ = try await h.engine.discover(LibraryDiscovery(store: h.store, staging: photos))
        // Cancel the selected job while preserving the measured selection: an explicit upload
        // outside it must not become selected progress just because the historical count grows.
        try await h.engine.cancel([h.photo("selected").source])
        _ = try await h.engine.enqueue([h.photo("outside")])
        try await h.engine.setIntent(.automatic)
        try await untilTransfers("The outside upload commits.") { try await h.confirmed("outside") }
        let outside = await h.engine.currentSnapshot
        XCTAssertEqual(outside.selectionProgress?.total, 1)
        XCTAssertEqual(outside.selectionProgress?.backedUp, 0)

        _ = try await h.engine.enqueue([h.photo("selected")])
        try await untilTransfers("The selected upload commits.") { try await h.confirmed("selected") }
        await untilTransfers("Its accepted exact revision advances the measured selection.") {
            await h.engine.currentSnapshot.selectionProgress?.backedUp == 1
        }
        _ = try await h.engine.enqueue([h.photo("selected"), h.photo("selected")])
        await h.engine.refresh()
        let repeated = await h.engine.currentSnapshot
        XCTAssertEqual(repeated.selectionProgress?.backedUp, 1)
        XCTAssertEqual(repeated.selectionProgress?.remaining, 0)
        XCTAssertEqual(repeated.selectionProgress?.fraction, 1)

        // Discovery of an edit invalidates the old version's credit. The fake executor still
        // returns the old staged revision; even its accepted commit must not credit the edit.
        photos.edit("selected", modified: FakeStaging.date.addingTimeInterval(10))
        _ = try await h.engine.discover(LibraryDiscovery(store: h.store, staging: photos))
        try await untilTransfers("The old revision's result finishes.") {
            let job = try await h.job("selected")
            return h.executor.calls("selected") == 2 && job == nil
        }
        await h.engine.refresh()
        let edited = await h.engine.currentSnapshot
        XCTAssertEqual(edited.selectionProgress?.backedUp, 0)
        XCTAssertEqual(edited.selectionProgress?.remaining, 1)
        await h.tearDown()
    }

    func testUnknownRevisionsAndRepeatedCandidateIDsNeverInventConfirmedInventory() async throws {
        let h = try await TransferEngineHarness()
        var seed = TransferSeed()
        seed.confirmations = [("unknown", FakeStaging.date), ("known", FakeStaging.date)]
        try await h.store.seedForTest(seed)
        let merge = try await h.store.mergeDiscovery([
            DeviceCandidate(id: "known", modified: FakeStaging.date), DeviceCandidate(id: "known", modified: FakeStaging.date),
            DeviceCandidate(id: "unknown", modified: nil),
        ], gone: [])
        XCTAssertEqual(merge.inventory?.revisions.count, 2)
        XCTAssertEqual(merge.inventory?.confirmed, ["known"])
        XCTAssertTrue(merge.inventory?.revisions.keys.contains("unknown") == true)
        await h.tearDown()
    }

    func testServerDuplicatePreflightAdvancesMeasuredProgressWithoutSendingTheFileAgain() async throws {
        var preferences = TransferPreferences()
        preferences.scope = .entireLibrary
        let h = try await LibraryJobHarness(preferences: preferences)
        h.staging.add("duplicate", album: nil)
        let probe = h.folder.appendingPathComponent("probe")
        let prepared = try await h.staging.stage("duplicate", into: probe, stageID: "probe", policy: StagingPolicy()) { _ in }
        h.server.hold(checksum: try UploadBody.checksum(prepared.original.url), as: .duplicate("existing-server-copy", trashed: false))
        try await h.engine.start()
        _ = try await h.discover()
        let measured = await h.engine.currentSnapshot
        XCTAssertEqual(measured.selectionProgress?.total, 1)
        XCTAssertEqual(measured.selectionProgress?.backedUp, 0)
        try await h.engine.setIntent(.automatic)
        await untilTransfers("The server's duplicate answer confirms the measured photo.") {
            await h.engine.currentSnapshot.selectionProgress?.backedUp == 1
        }
        XCTAssertTrue(h.uploads.uploads.isEmpty, "The exact server duplicate requires no new media upload.")
        let completed = await h.engine.currentSnapshot
        XCTAssertEqual(completed.selectionProgress?.fraction, 1)
        _ = try await h.discover()
        let checkedAgain = await h.engine.currentSnapshot
        XCTAssertEqual(checkedAgain.selectionProgress?.backedUp, 1)
        XCTAssertEqual(checkedAgain.selectionProgress?.total, 1)
        await h.tearDown()
    }

    func testRecoveredOutcomeRefreshesOnlyItsExactSelectedRevisionAndCannotCountTwice() async throws {
        let h = try await TransferEngineHarness()
        let photos = FakeStaging()
        photos.add("selected")
        var preferences = TransferPreferences()
        preferences.includedAlbums = [FakeStaging.album]
        try await h.store.savePreferences(preferences)
        try await h.engine.start()
        _ = try await h.engine.discover(LibraryDiscovery(store: h.store, staging: photos))
        let job = try await h.requireJob("selected")
        let completion = TransferCompletion(job: job.id, lease: nil, localID: "selected", revision: AssetRevision(FakeStaging.date),
                                            assetID: "server", receipt: nil, confirmedAt: TransferEngineHarness.base)
        let committed = try await h.store.complete(completion)
        XCTAssertTrue(committed)
        await h.engine.refresh()
        let recovered = await h.engine.currentSnapshot
        XCTAssertEqual(recovered.selectionProgress?.backedUp, 1)
        let duplicate = try await h.store.complete(completion)
        XCTAssertFalse(duplicate)
        await h.engine.refresh()
        let replayed = await h.engine.currentSnapshot
        XCTAssertEqual(replayed.selectionProgress?.backedUp, 1)
        XCTAssertEqual(replayed.selectionProgress?.total, 1)
        await h.tearDown()
    }

    func testMeasurementIsUnknownUntilCheckedAndClearsOnScopeChangeFailureAndRelaunch() async throws {
        let h = try await TransferEngineHarness()
        let photos = FakeStaging()
        var preferences = TransferPreferences()
        preferences.scope = .entireLibrary
        try await h.store.savePreferences(preferences)
        try await h.engine.start()
        let initial = await h.engine.currentSnapshot
        XCTAssertNil(initial.selectionProgress)
        _ = try await h.engine.discover(LibraryDiscovery(store: h.store, staging: photos))
        let empty = await h.engine.currentSnapshot
        XCTAssertEqual(empty.selectionProgress?.total, 0)
        XCTAssertNil(empty.selectionProgress?.fraction, "An empty measured selection is not a fabricated zero-percent run.")
        preferences.excludedAlbums = ["new-exclusion"]
        try await h.engine.setPreferences(preferences)
        let changed = await h.engine.currentSnapshot
        XCTAssertNil(changed.selectionProgress)
        _ = try await h.engine.discover(LibraryDiscovery(store: h.store, staging: photos))
        photos.setAccess(.denied)
        do { _ = try await h.engine.discover(LibraryDiscovery(store: h.store, staging: photos)) } catch {}
        let failed = await h.engine.currentSnapshot
        XCTAssertNil(failed.selectionProgress)
        photos.setAccess(.authorized)
        _ = try await h.engine.discover(LibraryDiscovery(store: h.store, staging: photos))
        await h.engine.stop()
        let relaunched = TransferEngineHarness.engine(store: h.store, clock: h.clock, authorization: h.authorization, executor: h.executor)
        try await relaunched.start()
        let next = await relaunched.currentSnapshot
        XCTAssertNil(next.selectionProgress)
        await relaunched.stop()
        await h.tearDown()
    }
}

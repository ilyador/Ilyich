import Foundation
import XCTest
@testable import Ilyich

@MainActor final class BackupStatisticsTests: XCTestCase {
    func testCloudDownloadProgressDoesNotBecomeUploadBytesAndOnlyShowsDuringActiveBackup() {
        var snapshot = Self.snapshot(remaining: 1, confirmed: 0)
        snapshot.phase = .running
        snapshot.backupPreparationFraction = 0.42
        let preparing = BackupStatistics(snapshot: snapshot)
        XCTAssertEqual(preparing.preparationFraction, 0.42)
        XCTAssertNil(preparing.currentTransfer)
        XCTAssertEqual(preparing.backedUp, 0)
        snapshot.backupPreparationFraction = .nan
        XCTAssertNil(BackupStatistics(snapshot: snapshot).preparationFraction)
        snapshot.backupPreparationFraction = 0.42
        snapshot.backupPhase = .idle
        XCTAssertNil(BackupStatistics(snapshot: snapshot).preparationFraction)
    }

    func testPreparationIsVisibleWhileWaitingButNeverOverridesUserPause() {
        var snapshot = Self.snapshot(remaining: 100, confirmed: 0)
        snapshot.intent = .manual
        snapshot.preparingServerLibrary = true
        XCTAssertTrue(BackupStatistics(snapshot: snapshot).preparingServerLibrary)
        snapshot.intent = .paused
        XCTAssertFalse(BackupStatistics(snapshot: snapshot).preparingServerLibrary)
    }

    func testDiscoveryGrowthNeverTurnsHistoricalConfirmationsIntoRunProgress() {
        var snapshot = Self.snapshot(remaining: 2, confirmed: 10_000, failed: 1)
        snapshot.phase = .discovering
        let before = BackupStatistics(snapshot: EngineBackend.presented(snapshot, preferences: nil))
        snapshot.remaining = 200
        let after = BackupStatistics(snapshot: EngineBackend.presented(snapshot, preferences: nil))
        XCTAssertEqual(before.remaining, 3)
        XCTAssertEqual(after.remaining, 201)
        XCTAssertEqual(after.queued, 200)
        XCTAssertEqual(after.backedUp, 10_000)
        XCTAssertNil(before.currentTransfer)
        XCTAssertNil(after.currentTransfer, "Discovery cannot establish a run total from historical confirmations.")
    }

    func testRetryAndDuplicateCompletionKeepAccountStatisticsAcrossRelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BackupStats-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("transfers.sqlite")
        let store = TransferStore(url: url)
        var seed = TransferSeed()
        seed.confirmations = [("already-backed-up", FakeStaging.date)]
        seed.jobs = [.init(localID: "retry", state: .failed), .init(localID: "new")]
        try await store.seedForTest(seed)
        let initial = try await statistics(store)
        XCTAssertEqual(initial.backedUp, 1)
        XCTAssertEqual(initial.remaining, 2, "Failed photos are unfinished and must be included once.")
        XCTAssertEqual(initial.failed, 1)
        XCTAssertEqual(initial.queued, 1)

        _ = try await store.requeueFailed(lane: .library)
        let retry = try await statistics(store)
        XCTAssertEqual(retry.remaining, 2, "Retry moves a failed job back to the queue without growing it.")
        XCTAssertEqual(retry.failed, 0)
        XCTAssertEqual(retry.queued, 2)
        let storedJob = try await store.job(lane: .library, sourceKey: "new")
        let job = try XCTUnwrap(storedJob)
        let completion = TransferCompletion(job: job.id, lease: nil, localID: "new", revision: AssetRevision(FakeStaging.date),
                                            assetID: "duplicate-on-server", receipt: nil, confirmedAt: Date())
        let first = try await store.complete(completion)
        let duplicate = try await store.complete(completion)
        XCTAssertTrue(first, "A server duplicate still confirms this device's photo.")
        XCTAssertFalse(duplicate, "Replaying a consumed outcome never confirms twice.")
        let completed = try await statistics(store)
        XCTAssertEqual(completed.backedUp, 2)
        XCTAssertEqual(completed.remaining, 1)
        XCTAssertNil(completed.currentTransfer)
        await store.close()

        let reopened = TransferStore(url: url)
        let relaunched = try await statistics(reopened)
        XCTAssertEqual(relaunched, completed, "Relaunch reads durable account counts, without inventing a new run's uploads.")
        await reopened.close()
    }

    func testCurrentPartProgressIsBoundedAndUnavailableWhilePausedOrDiscovering() {
        var snapshot = Self.snapshot(remaining: 1, confirmed: 500)
        snapshot.phase = .running
        snapshot.backupPhase = .running
        snapshot.backupProgress = TransferProgress(activeFileCount: 1, sentBytes: 50, expectedBytes: 100)
        XCTAssertEqual(BackupStatistics(snapshot: snapshot).currentTransfer?.fraction, 0.5)
        snapshot.backupProgress = TransferProgress(activeFileCount: 2, sentBytes: 50, expectedBytes: nil)
        XCTAssertNil(BackupStatistics(snapshot: snapshot).currentTransfer?.fraction, "A missing active file size makes the byte total unknown.")
        snapshot.backupProgress = TransferProgress(activeFileCount: 1, sentBytes: 150, expectedBytes: 100)
        XCTAssertEqual(BackupStatistics(snapshot: snapshot).currentTransfer?.fraction, 1)
        snapshot.backupPhase = .idle
        snapshot.intent = .paused
        XCTAssertNil(BackupStatistics(snapshot: snapshot).currentTransfer, "A paused backup never retains an old file's progress.")
        snapshot.backupPhase = .discovering
        XCTAssertNil(BackupStatistics(snapshot: snapshot).currentTransfer)
    }

    func testShareProgressNeverBecomesPhotoBackupProgress() async throws {
        let h = try await TransferEngineHarness()
        let gate = TransferGate()
        let batch = UUID()
        let request = TransferRequest(source: .shared(batch: batch, attachment: "attachment"), origin: .shareApproval, revision: nil)
        h.executor.script(request.source.key, .report(count: 3, gate))
        _ = try await h.engine.enqueue([request])
        try await h.engine.start()
        await untilTransfers("The shared file reports progress.") { gate.waiting == 1 }
        let snapshot = await h.engine.currentSnapshot
        XCTAssertEqual(snapshot.phase, .running)
        XCTAssertEqual(snapshot.bytesSent, 300)
        XCTAssertEqual(snapshot.backupPhase, .idle)
        XCTAssertNil(snapshot.backupProgress)
        let shown = EngineBackend.presented(snapshot, preferences: nil)
        XCTAssertEqual(shown.activity, "Choose photos to back up")
        XCTAssertNil(BackupStatistics(snapshot: shown).currentTransfer)
        gate.open()
        await h.tearDown()
    }

    func testPausingAnActivePhotoClearsItsBytesAndPreservesItsUnfinishedCount() async throws {
        let h = try await TransferEngineHarness()
        let gate = TransferGate()
        h.executor.script("photo", .report(count: 3, gate))
        _ = try await h.engine.enqueue([h.photo("photo")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The photo reports its current part's bytes.") { gate.waiting == 1 }
        let running = await h.engine.currentSnapshot
        XCTAssertEqual(running.backupProgress?.sentBytes, 300)
        XCTAssertEqual(running.backupProgress?.expectedBytes, 300)
        try await h.engine.setIntent(.paused)
        let paused = await h.engine.currentSnapshot
        XCTAssertEqual(paused.backupPhase, .idle)
        XCTAssertNil(paused.backupProgress)
        XCTAssertEqual(paused.remaining, 1)
        XCTAssertEqual(paused.confirmed, 0)
        gate.open()
        await h.tearDown()
    }

    func testShareOnlyWaitDoesNotMakeBackupAppearActiveOrWaiting() async throws {
        let h = try await TransferEngineHarness()
        let request = TransferRequest(source: .shared(batch: UUID(), attachment: "attachment"), origin: .shareApproval, revision: nil)
        h.executor.script(request.source.key, .fail { TransferDeferral.deviceConditions })
        _ = try await h.engine.enqueue([request])
        try await h.engine.start()
        await untilTransfers("The shared file waits for device conditions.") { await h.engine.currentSnapshot.phase == .waiting(.deviceConditions) }
        let snapshot = await h.engine.currentSnapshot
        XCTAssertEqual(snapshot.backupPhase, .idle)
        XCTAssertNil(snapshot.backupProgress)
        let shown = EngineBackend.presented(snapshot, preferences: nil)
        XCTAssertEqual(shown.activity, "Choose photos to back up")
        XCTAssertEqual(BackupStatistics(snapshot: shown).phase, .idle)
        await h.tearDown()
    }

    func testAnOldDiscoveryCannotMarkAChangedSelectionCheckedAndRelaunchRequiresANewCheck() async throws {
        let h = try await TransferEngineHarness()
        let staging = FakeStaging()
        staging.add("photo")
        let gate = TransferGate()
        staging.holdDiscovery(at: gate)
        try await h.engine.start()
        var preferences = TransferPreferences()
        preferences.scope = .entireLibrary
        try await h.engine.setPreferences(preferences)
        let discovery = LibraryDiscovery(store: h.store, staging: staging)
        let oldScan = Task { try await h.engine.discover(discovery) }
        await untilTransfers("The first selection's scan is still reading Photos.") { staging.discoveryWaits }
        preferences.scope = .selectedAlbums
        preferences.includedAlbums = ["another-album"]
        try await h.engine.setPreferences(preferences)
        // Even switching back cannot let the old pass stand in for checking the new settings.
        preferences.scope = .entireLibrary
        try await h.engine.setPreferences(preferences)
        gate.open()
        _ = try await oldScan.value
        let stale = await h.engine.currentSnapshot
        XCTAssertFalse(stale.backupSelectionChecked)

        _ = try await h.engine.discover(discovery)
        let checked = await h.engine.currentSnapshot
        XCTAssertTrue(checked.backupSelectionChecked)
        staging.setAccess(.denied)
        do {
            _ = try await h.engine.discover(discovery)
            XCTFail("A permission failure must not preserve a completed check.")
        } catch {}
        let failed = await h.engine.currentSnapshot
        XCTAssertFalse(failed.backupSelectionChecked)
        staging.setAccess(.authorized)
        _ = try await h.engine.discover(discovery)
        let retried = await h.engine.currentSnapshot
        XCTAssertTrue(retried.backupSelectionChecked)

        await h.engine.stop()
        let relaunched = TransferEngineHarness.engine(store: h.store, clock: h.clock, authorization: h.authorization, executor: h.executor)
        try await relaunched.start()
        let initial = await relaunched.currentSnapshot
        XCTAssertFalse(initial.backupSelectionChecked, "Previous-process confirmations cannot prove the current Photos selection was checked.")
        await relaunched.stop()
        await h.tearDown()
    }

    func testAnUncheckedEmptyQueueNeverClaimsTheSelectionIsBackedUp() {
        var preferences = TransferPreferences()
        preferences.scope = .entireLibrary
        var snapshot = Self.snapshot(confirmed: 500)
        XCTAssertEqual(EngineBackend.presented(snapshot, preferences: preferences).activity, "Ready to back up")
        preferences.automatic = true
        snapshot.intent = .automatic
        XCTAssertEqual(EngineBackend.presented(snapshot, preferences: preferences).activity, "Waiting to check Photos")
        snapshot.backupSelectionChecked = true
        XCTAssertEqual(EngineBackend.presented(snapshot, preferences: preferences).activity, "Photo library backed up")
    }

    func testSupersededDiscoveryReturnsNilWhileCallerCancellationStillThrows() async throws {
        let h = try await TransferEngineHarness()
        try await h.engine.start()
        var preferences = TransferPreferences()
        preferences.scope = .entireLibrary
        try await h.engine.setPreferences(preferences)
        let first = FakeStaging()
        first.add("old-selection-photo")
        let oldGate = TransferGate()
        first.holdDiscovery(at: oldGate)
        let oldScan = Task { try await h.engine.discover(LibraryDiscovery(store: h.store, staging: first)) }
        await untilTransfers("The superseded discovery reaches its metadata gate.") { first.discoveryWaits }
        preferences.scope = .selectedAlbums
        preferences.includedAlbums = ["another-album"]
        try await h.engine.setPreferences(preferences)
        oldGate.open()
        let superseded = try await oldScan.value
        XCTAssertNil(superseded)
        let after = try await h.store.contents()
        XCTAssertTrue(after.jobs.isEmpty, "A cancelled old selection must not leave upload jobs behind.")
        let stale = await h.engine.currentSnapshot
        XCTAssertFalse(stale.backupSelectionChecked)
        XCTAssertNil(stale.lastMessage)

        preferences.scope = .entireLibrary
        try await h.engine.setPreferences(preferences)
        let second = FakeStaging()
        second.add("current-selection-photo")
        let cancellationGate = TransferGate()
        second.holdDiscovery(at: cancellationGate)
        let cancelled = Task { try await h.engine.discover(LibraryDiscovery(store: h.store, staging: second)) }
        await untilTransfers("The caller's cancellable discovery reaches its metadata gate.") { second.discoveryWaits }
        cancelled.cancel()
        cancellationGate.open()
        do {
            _ = try await cancelled.value
            XCTFail("Cancellation of the requesting task must still propagate.")
        } catch is CancellationError {}
        await h.tearDown()
    }

    private func statistics(_ store: TransferStore) async throws -> BackupStatistics {
        let counts = try await store.counts()
        return BackupStatistics(snapshot: EngineBackend.presented(
            Self.snapshot(remaining: counts.remaining, confirmed: counts.confirmed, failed: counts.failed), preferences: nil))
    }

    private static func snapshot(remaining: Int = 0, confirmed: Int = 0, failed: Int = 0) -> TransferSnapshot {
        TransferSnapshot(intent: .paused, phase: .idle, remaining: remaining, confirmed: confirmed, failed: failed,
                         fileProgress: nil, bytesSent: 0, bytesExpected: 0, bytesPerSecond: nil, lastMessage: nil)
    }
}

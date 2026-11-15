import Foundation
import XCTest
@testable import Ilyich

/// The Settings command follows the same backend, lifecycle, discovery and upload executor as
/// the app. Denied background scheduling cannot prevent a foreground scan or upload.
@MainActor final class AutomaticBackupStartTests: XCTestCase {
    func testEnablingAutomaticBackupForTheWholeLibraryStartsImmediatelyWithBackgroundRefreshDenied() async throws {
        try await assertAutomaticStart(enablingBeforeScopeChange: false)
    }

    func testChangingAutomaticBackupFromEmptyAlbumsToTheWholeLibraryStartsImmediately() async throws {
        try await assertAutomaticStart(enablingBeforeScopeChange: true)
    }

    private func assertAutomaticStart(enablingBeforeScopeChange: Bool) async throws {
        let h = try await LibraryJobHarness(preferences: TransferPreferences())
        h.staging.add("new-photo", album: nil)
        let discoveryGate = TransferGate()
        h.staging.holdDiscovery(at: discoveryGate)
        let scheduler = FakeTaskScheduler()
        scheduler.availability = .denied
        let source = LifecycleEventSource(initial: .launch(active: true), scheduler: scheduler)
        let engine = TransferEngine(store: h.store, executor: h.executor, authorization: h.authorization,
                                    clock: ContinuousClock(), concurrency: h.executor.concurrency, scheduler: source)
        try await engine.start()
        let discovery = LibraryDiscovery(store: h.store, staging: h.staging)
        let work = EngineWindowWork(engine: engine, discovery: discovery, reconciling: {}, preSync: nil,
                                    preferences: { try? await engine.preferences() })
        let lifecycle = TransferLifecycle(work: work, time: FakeBackgroundTime(), clock: h.clock, appActive: true)
        let (events, continuation) = AsyncStream.makeStream(of: LifecycleEvent.self)
        await lifecycle.start(events)
        let backend = EngineBackend(engine: engine, store: h.store, discovery: discovery,
                                    preferencesChanged: { continuation.yield(.preferencesChanged) })
        let log = SnapshotLog(await backend.snapshots())
        await untilTransfers("The initial empty selection is shown.") { log.last?.activity == "Choose photos to back up" }
        let initialIntent = await engine.runIntent
        XCTAssertEqual(initialIntent, .paused)
        var preferences = TransferPreferences()
        preferences.automatic = true
        preferences.triggerDelay = 3_600
        if enablingBeforeScopeChange {
            try await backend.setPreferences(preferences)
            await untilTransfers("Automatic intent is enabled with no selected albums.") { await engine.runIntent == .automatic }
        }
        preferences.scope = .entireLibrary
        try await backend.setPreferences(preferences)
        await untilTransfers("The explicit settings change immediately scans the whole library.") { h.staging.discoveryWaits }
        await untilTransfers("The scan has a truthful visible status.") { log.last?.activity == "Finding new photos" }
        XCTAssertEqual(h.clock.sleeperCount, 0, "The settings command never waits for the one-hour Photos trigger delay.")
        await untilTransfers("The background restriction is reported independently.") { source.schedulingIssue == .refreshDisabled }
        XCTAssertTrue(scheduler.submitted.isEmpty)
        discoveryGate.open()
        try await untilTransfers("The discovered photo uploads and commits.") { try await h.backedUp("new-photo") }
        await untilTransfers("The screen reports the scope that was actually saved.") { log.last?.activity == "Photo library backed up" }
        XCTAssertEqual(h.uploads.uploads(of: "new-photo.HEIC").count, 1)
        XCTAssertEqual(log.last?.confirmed, 1)
        XCTAssertEqual(log.last?.remaining, 0)
        log.stop()
        continuation.finish()
        await lifecycle.stop()
        await engine.stop()
        source.finish()
        await h.tearDown()
    }

    func testSavedScopeChangesRefreshActivityEvenWhenEveryQueueCountAndPhaseStayTheSame() async throws {
        let h = try await LibraryJobHarness(preferences: TransferPreferences())
        let engine = TransferEngine(store: h.store, executor: h.executor, authorization: h.authorization, clock: ContinuousClock())
        try await engine.start()
        let backend = EngineBackend(engine: engine, store: h.store, discovery: LibraryDiscovery(store: h.store, staging: h.staging),
                                    preferencesChanged: {})
        let log = SnapshotLog(await backend.snapshots())
        await untilTransfers("The initial empty selection is shown.") { log.last?.activity == "Choose photos to back up" }
        var preferences = TransferPreferences()
        preferences.scope = .entireLibrary
        try await backend.setPreferences(preferences)
        await untilTransfers("An unchecked scope is ready, without claiming a completed scan.") { log.last?.activity == "Ready to back up" }
        XCTAssertEqual(log.last?.backupSelectionChecked, false)
        XCTAssertEqual(log.last?.preferencesRevision, 1)
        try await backend.setPreferences(preferences)
        let snapshot = await engine.currentSnapshot
        XCTAssertEqual(snapshot.preferencesRevision, 1, "Saving unchanged preferences does not create a new revision.")
        log.stop()
        await engine.stop()
        await h.tearDown()
    }

    func testBackUpNowScansAndUploadsImmediatelyWithAutomaticBackupOffAndBackgroundRefreshDenied() async throws {
        var preferences = TransferPreferences()
        preferences.scope = .entireLibrary
        preferences.triggerDelay = 3_600
        let h = try await LibraryJobHarness(preferences: preferences)
        h.staging.add("manual-photo", album: nil)
        let scheduler = FakeTaskScheduler()
        scheduler.availability = .denied
        let source = LifecycleEventSource(initial: .launch(active: true), scheduler: scheduler)
        let engine = TransferEngine(store: h.store, executor: h.executor, authorization: h.authorization,
                                    clock: ContinuousClock(), scheduler: source)
        try await engine.start()
        let backend = EngineBackend(engine: engine, store: h.store, discovery: LibraryDiscovery(store: h.store, staging: h.staging),
                                    preferencesChanged: {})
        try await backend.setIntent(.manual)
        try await untilTransfers("Back up now discovers and uploads without an automatic trigger or background window.") {
            try await h.backedUp("manual-photo")
        }
        XCTAssertEqual(h.uploads.uploads(of: "manual-photo.HEIC").count, 1)
        XCTAssertTrue(scheduler.submitted.isEmpty)
        let saved = try await engine.preferences()
        XCTAssertEqual(saved?.automatic, false)
        await engine.stop()
        source.finish()
        await h.tearDown()
    }

    func testAutomaticDiscoveryPermissionFailureIsVisibleAndSuccessfulRetryClearsIt() async throws {
        let h = try await LibraryJobHarness(preferences: TransferPreferences())
        h.staging.add("retry-photo", album: nil)
        h.staging.setAccess(.denied)
        let engine = TransferEngine(store: h.store, executor: h.executor, authorization: h.authorization, clock: ContinuousClock())
        try await engine.start()
        let discovery = LibraryDiscovery(store: h.store, staging: h.staging)
        let work = EngineWindowWork(engine: engine, discovery: discovery, reconciling: {}, preSync: nil,
                                    preferences: { try? await engine.preferences() })
        let lifecycle = TransferLifecycle(work: work, time: FakeBackgroundTime(), clock: h.clock, appActive: true)
        let (events, continuation) = AsyncStream.makeStream(of: LifecycleEvent.self)
        await lifecycle.start(events)
        let backend = EngineBackend(engine: engine, store: h.store, discovery: discovery,
                                    preferencesChanged: { continuation.yield(.preferencesChanged) })
        let log = SnapshotLog(await backend.snapshots())
        var preferences = TransferPreferences()
        preferences.scope = .entireLibrary
        preferences.automatic = true
        try await backend.setPreferences(preferences)
        await untilTransfers("An automatic scan's permission error reaches the backup screen.") {
            log.last?.lastMessage != nil && log.last?.activity == "Backup needs attention"
        }
        XCTAssertEqual(log.last?.backupPhase, .idle, "A discovery failure must not block the shared-file lane.")
        XCTAssertEqual(log.last?.backupSelectionChecked, false)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        h.staging.setAccess(.authorized)
        try await backend.setPreferences(preferences)
        try await untilTransfers("The explicit retry scans and uploads after Photos access returns.") { try await h.backedUp("retry-photo") }
        await untilTransfers("A successful retry clears the discovery error.") {
            log.last?.lastMessage == nil && log.last?.activity == "Photo library backed up"
        }
        XCTAssertEqual(log.last?.backupSelectionChecked, true)
        log.stop()
        continuation.finish()
        await lifecycle.stop()
        await engine.stop()
        await h.tearDown()
    }
}

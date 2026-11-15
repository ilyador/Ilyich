import Foundation
import Synchronization
import XCTest
@testable import Ilyich

final class KnownBackupCopyTests: XCTestCase {
    func testCloudIdentityReconciliationNeverStagesOrUploadsAndPreservesPauseUntilExplicitResume() async throws {
        var preferences = TransferPreferences()
        preferences.scope = .entireLibrary
        let h = try await LibraryJobHarness(preferences: preferences)
        let reader = ProofReader(items: [item("a"), item("b")])
        for id in ["a", "b"] {
            h.staging.add(id, album: nil)
            h.staging.fail(id) { BackupError.item("An iCloud original must not be requested for this known copy.") }
            h.server.remote(remote(id, visibility: id == "b" ? "archive" : "timeline"))
        }
        let identities = MutableProofIdentities(rows: [match("a"), match("b", visible: false)], complete: true)
        let checker = KnownBackupCopyChecker(account: LibraryJobHarness.account, reader: reader,
                                            database: DeviceDatabase(url: h.folder.appendingPathComponent("device.sqlite")),
                                            identities: identities, server: h.server)
        let engine = makeEngine(h, checker: checker)
        try await engine.start()
        _ = try await engine.discover(LibraryDiscovery(store: h.store, staging: h.staging))
        let measured = await engine.currentSnapshot
        XCTAssertEqual(measured.intent, .paused)
        XCTAssertEqual(measured.selectionProgress?.unchecked, 2)
        XCTAssertEqual(measured.selectionProgress?.pending, 0)
        XCTAssertNil(measured.selectionProgress?.fraction)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reader.readCount, 0, "Discovery or installing the checker cannot resume paused work.")
        XCTAssertTrue(h.staging.staged.isEmpty)

        try await engine.setIntent(.manual)
        await untilTransfers("The two exact existing server copies are reconciled.") { await engine.currentSnapshot.selectionProgress?.backedUp == 2 }
        let completed = await engine.currentSnapshot
        XCTAssertEqual(completed.selectionProgress?.unchecked, 0)
        XCTAssertEqual(completed.selectionProgress?.pending, 0)
        XCTAssertEqual(completed.selectionProgress?.fraction, 1)
        XCTAssertTrue(h.staging.staged.isEmpty)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        let receipts = try await h.store.receipts(for: ["a", "b"])
        XCTAssertTrue(receipts.isEmpty, "Cloud metadata can confirm presence but cannot manufacture cleanup checksum proof.")
        XCTAssertEqual(identities.fullReads, 1, "The selected photos share one cached identity catalog instead of rescanning it per item.")
        await engine.stop()
        await h.tearDown()
    }

    func testCurrentStoredChecksumConfirmsDuplicateBeforeStagingAndKeepsExactCleanupReceipt() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("a")
        h.staging.fail("a") { BackupError.item("Staging must not be called.") }
        let database = DeviceDatabase(url: h.folder.appendingPathComponent("device.sqlite"))
        try await database.saveFingerprints(["a": DeviceFingerprint(modified: FakeStaging.date, checksum: "checksum-a")])
        h.server.hold(checksum: "checksum-a", as: .duplicate("server-a", trashed: false))
        h.server.remote(remote("a"))
        let checker = KnownBackupCopyChecker(account: LibraryJobHarness.account, reader: ProofReader(items: [item("a")]), database: database,
                                            identities: ProofIdentities(rows: []), server: h.server)
        let engine = makeEngine(h, checker: checker)
        try await engine.start()
        _ = try await engine.discover(LibraryDiscovery(store: h.store, staging: h.staging))
        try await engine.setIntent(.manual)
        await untilTransfers("The exact checksum duplicate is confirmed.") { await engine.currentSnapshot.selectionProgress?.backedUp == 1 }
        let receipts = try await h.store.receipts(for: ["a"])
        XCTAssertEqual(receipts["a"]?.original.checksum, "checksum-a")
        XCTAssertTrue(h.staging.staged.isEmpty)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        await engine.stop()
        await h.tearDown()
    }

    func testOnlyAnAcceptedExactOriginalCheckMovesUncheckedToPending() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("a")
        let gate = TransferGate()
        h.staging.hold("a", at: gate)
        let database = DeviceDatabase(url: h.folder.appendingPathComponent("device.sqlite"))
        try await database.saveFingerprints(["a": DeviceFingerprint(modified: FakeStaging.date, checksum: "not-on-server")])
        let checker = KnownBackupCopyChecker(account: LibraryJobHarness.account, reader: ProofReader(items: [item("a")]), database: database,
                                            identities: ProofIdentities(rows: []), server: h.server)
        let engine = makeEngine(h, checker: checker)
        try await engine.start()
        _ = try await engine.discover(LibraryDiscovery(store: h.store, staging: h.staging))
        try await engine.setIntent(.manual)
        await untilTransfers("The verified missing original reaches staging.") { gate.waiting == 1 }
        let checked = await engine.currentSnapshot
        XCTAssertEqual(checked.selectionProgress?.pending, 1)
        XCTAssertEqual(checked.selectionProgress?.unchecked, 0)
        XCTAssertEqual(checked.selectionProgress?.backedUp, 0)
        XCTAssertEqual(checked.selectionProgress?.fraction, 0)
        try await engine.setIntent(.paused)
        gate.open()
        await engine.stop()
        await h.tearDown()
    }

    func testEditedAmbiguousStaleForeignAndTrashedEvidenceCannotSkipTheStrictPath() async throws {
        for reason in ["edited", "ambiguous", "stale", "foreign", "trashed", "locked", "live"] {
            let h = try await LibraryJobHarness()
            h.staging.add("a")
            h.staging.fail("a") { BackupError.item("Strict staging is required for unverified resource identity.") }
            var local = item("a")
            if reason == "edited" { local = item("a", unadjusted: false, shape: .edited) }
            if reason == "live" { local = item("a", shape: .livePhoto) }
            var rows = [match("a")]
            if reason == "ambiguous" { rows.append(match("a", serverID: "another-copy")) }
            if reason == "stale" { rows = [match("a", created: FakeStaging.date.addingTimeInterval(-10))] }
            h.server.remote(remote("a", owner: reason == "foreign" ? "another-owner" : "owner", trashed: reason == "trashed",
                                   visibility: reason == "locked" ? "locked" : "timeline"))
            let checker = KnownBackupCopyChecker(account: LibraryJobHarness.account, reader: ProofReader(items: [local]),
                                                database: DeviceDatabase(url: h.folder.appendingPathComponent("device.sqlite")),
                                                identities: ProofIdentities(rows: rows), server: h.server)
            let engine = makeEngine(h, checker: checker)
            try await engine.start()
            _ = try await engine.discover(LibraryDiscovery(store: h.store, staging: h.staging))
            try await engine.setIntent(.manual)
            await untilTransfers("Unsafe \(reason) evidence reaches the strict path.") { await engine.currentSnapshot.failed == 1 }
            let snapshot = await engine.currentSnapshot
            XCTAssertEqual(snapshot.selectionProgress?.backedUp, 0, reason)
            XCTAssertEqual(snapshot.selectionProgress?.unchecked, 1, reason)
            XCTAssertEqual(snapshot.selectionProgress?.pending, 0, reason)
            XCTAssertEqual(h.staging.staged.count, 1, reason)
            XCTAssertTrue(h.uploads.uploads.isEmpty)
            await engine.stop()
            await h.tearDown()
        }
    }

    func testIncompleteCatalogDefersWithoutStagingKeepsSharesWorkingAndCannotResumeAPause() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("a")
        h.staging.fail("a") { BackupError.item("The original must not be downloaded while identities are incomplete.") }
        h.server.remote(remote("a"))
        let identities = MutableProofIdentities(rows: [match("a")], complete: false)
        let checker = KnownBackupCopyChecker(account: LibraryJobHarness.account, reader: ProofReader(items: [item("a")]),
                                            database: DeviceDatabase(url: h.folder.appendingPathComponent("device.sqlite")),
                                            identities: identities, server: h.server)
        let engine = makeEngine(h, checker: checker)
        try await engine.start()
        _ = try await engine.discover(LibraryDiscovery(store: h.store, staging: h.staging))
        let due = TransferRequest(source: .photo(.init(rawValue: "old-retry")), origin: .selection, revision: AssetRevision(FakeStaging.date))
        _ = try await h.store.enqueue([due])
        let retry = try await h.store.job(lane: .library, sourceKey: "old-retry")
        let retryJob = try XCTUnwrap(retry)
        let token = UUID()
        _ = try await h.store.lease(job: retryJob.id, token: token)
        _ = try await h.store.scheduleRetry(job: retryJob.id, token: token, notBefore: TransferEngineHarness.base.addingTimeInterval(-1),
                                          message: "A retry already due when the catalog wait starts.", at: TransferEngineHarness.base)
        try await engine.setIntent(.manual)
        await untilTransfers("The library waits for its complete server catalog.") {
            await engine.currentSnapshot.backupPhase == .waiting(.serverBackoff)
        }
        try await h.clock.waitForSleepers(1)
        XCTAssertTrue(h.staging.staged.isEmpty)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        XCTAssertEqual(identities.fullReads, 0, "Incomplete checks use the cheap catalog-completion query.")
        let waiting = await engine.currentSnapshot
        XCTAssertEqual(waiting.failed, 0)
        XCTAssertEqual(waiting.selectionProgress?.unchecked, 1)
        XCTAssertEqual(waiting.selectionProgress?.pending, 0)

        let shared = TransferRequest(source: .shared(batch: UUID(), attachment: "shared-file"), origin: .shareApproval, revision: nil)
        _ = try await engine.enqueue([shared])
        try await untilTransfers("Approved shared uploads are not blocked by the library's metadata wait.") {
            try await h.store.job(lane: .share, sourceKey: shared.source.key) == nil
        }
        try await engine.setIntent(.paused)
        try await engine.cancel([due.source])
        identities.complete = true
        h.clock.advance(by: .seconds(5))
        await engine.conditionsChanged()
        try await Task.sleep(for: .milliseconds(50))
        let paused = await engine.currentSnapshot
        XCTAssertEqual(paused.intent, .paused)
        XCTAssertEqual(paused.selectionProgress?.backedUp, 0)
        XCTAssertEqual(identities.fullReads, 0)
        XCTAssertTrue(h.staging.staged.isEmpty)

        try await engine.setIntent(.manual)
        await untilTransfers("Only the explicit resume checks the now-complete catalog.") { await engine.currentSnapshot.selectionProgress?.backedUp == 1 }
        XCTAssertEqual(identities.fullReads, 1)
        XCTAssertTrue(h.staging.staged.isEmpty)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        await engine.stop()
        await h.tearDown()
    }

    func testExternalContentDuplicateSkipsStagingAndRecordsActualFileDigest() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("a")
        let database = DeviceDatabase(url: h.folder.appendingPathComponent("device.sqlite"))
        try await database.saveFingerprints(["a": DeviceFingerprint(modified: FakeStaging.date, checksum: "file-sha1")])
        h.server.prepareExternalFiles(pending: 18_000)
        h.server.hold(checksum: "file-sha1", as: .duplicate("external-a", trashed: false))
        h.server.remote(BackupRemoteAsset(id: "external-a", ownerId: "owner", checksum: "path-sha1", isTrashed: false, livePhotoVideoId: nil,
                                         visibility: "archive", checksumAlgorithm: "sha1-path", contentChecksum: "file-sha1", isExternal: true))
        let checker = KnownBackupCopyChecker(account: LibraryJobHarness.account, reader: ProofReader(items: [item("a")]), database: database,
                                            identities: ProofIdentities(rows: []), server: h.server)
        let engine = makeEngine(h, checker: checker)
        try await engine.start()
        _ = try await engine.discover(LibraryDiscovery(store: h.store, staging: h.staging))
        try await engine.setIntent(.manual)
        await untilTransfers("External content proof is reconciled.") { await engine.currentSnapshot.selectionProgress?.backedUp == 1 }
        let receipt = try await h.receipt("a")
        XCTAssertEqual(receipt?.original.checksum, "file-sha1")
        XCTAssertEqual(receipt?.original.id, "external-a")
        XCTAssertEqual(h.server.preparationCallCount, 0, "Exact known content matches bypass preparation for unrelated archive files.")
        XCTAssertTrue(h.staging.staged.isEmpty)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        await engine.stop()
        await h.tearDown()
    }

    func testExternalPreparationHoldsWholeLaneAndNeverProvesMissingOrOverridesPause() async throws {
        let h = try await LibraryJobHarness()
        let database = DeviceDatabase(url: h.folder.appendingPathComponent("device.sqlite"))
        let ids = (0..<100).map { "photo-\($0)" }
        for id in ids { h.staging.add(id) }
        try await database.saveFingerprints(Dictionary(uniqueKeysWithValues: ids.map { ($0, DeviceFingerprint(modified: FakeStaging.date, checksum: "sum-" + $0)) }))
        h.server.failChecks(.externalContentFingerprintsPending)
        let checker = KnownBackupCopyChecker(account: LibraryJobHarness.account, reader: ProofReader(items: ids.map { item($0) }), database: database,
                                            identities: ProofIdentities(rows: []), server: h.server)
        let engine = makeEngine(h, checker: checker)
        try await engine.start()
        _ = try await engine.discover(LibraryDiscovery(store: h.store, staging: h.staging))
        try await engine.setIntent(.manual)
        await untilTransfers("A single preparation hold stops the selected library lane.") { await engine.currentSnapshot.preparingServerLibrary }
        await engine.conditionsChanged()
        let waiting = await engine.currentSnapshot
        XCTAssertEqual(waiting.intent, .manual)
        XCTAssertEqual(waiting.selectionProgress?.pending, 0)
        XCTAssertEqual(waiting.selectionProgress?.unchecked, 100)
        XCTAssertEqual(h.server.checkCallCount, 1, "One server preparation response holds all 100 queued photos.")
        XCTAssertEqual(EngineBackend.activity(waiting, preferences: nil), "Preparing server library")
        XCTAssertTrue(h.staging.staged.isEmpty)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        let jobs = try await h.store.queuePage(lane: .library, after: nil, limit: 200)
        XCTAssertEqual(jobs.count, 100)
        XCTAssertTrue(jobs.allSatisfy { $0.state == .queued })
        try await engine.setIntent(.paused)
        h.clock.advance(by: .seconds(120))
        await engine.conditionsChanged()
        let paused = await engine.currentSnapshot
        XCTAssertEqual(paused.intent, .paused)
        XCTAssertEqual(paused.selectionProgress?.pending, 0)
        XCTAssertEqual(h.server.checkCallCount, 1)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        await engine.stop()
        await h.tearDown()
    }

    func testUnknownOriginalPreparationProbeStopsCloudStagingAndIsCachedAcrossPhotos() async throws {
        let h = try await LibraryJobHarness()
        let ids = (0..<100).map { "unknown-\($0)" }
        for id in ids { h.staging.add(id) }
        h.server.prepareExternalFiles(pending: 18_000)
        let checker = KnownBackupCopyChecker(account: LibraryJobHarness.account, reader: ProofReader(items: ids.map { item($0) }),
                                            database: DeviceDatabase(url: h.folder.appendingPathComponent("device.sqlite")),
                                            identities: ProofIdentities(rows: []), server: h.server)
        let engine = makeEngine(h, checker: checker)
        try await engine.start()
        _ = try await engine.discover(LibraryDiscovery(store: h.store, staging: h.staging))
        try await engine.setIntent(.manual)
        await untilTransfers("Unknown resources wait before their first iCloud download.") { await engine.currentSnapshot.preparingServerLibrary }
        XCTAssertTrue(h.staging.staged.isEmpty)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        XCTAssertEqual(h.server.preparationCallCount, 1)
        XCTAssertEqual(h.server.checkCallCount, 0, "No original was downloaded just to compute a bulk-check hash.")
        let status = await engine.currentSnapshot
        XCTAssertEqual(status.selectionProgress?.pending, 0)
        let gate = BackupPreparationGate()
        for _ in 0..<100 {
            do { try await gate.ensureReady(server: h.server); XCTFail("Pending preparation must hold unknown resources.") }
            catch { XCTAssertEqual(error as? ServerFailure, .externalContentFingerprintsPending) }
        }
        XCTAssertEqual(h.server.preparationCallCount, 2, "The extra gate shares one probe across another 100 checks.")
        await engine.stop()
        await h.tearDown()
    }

    func testPreparationProbeWithoutNewServerFieldKeepsLegacyStagingBehavior() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("a")
        let checker = KnownBackupCopyChecker(account: LibraryJobHarness.account, reader: ProofReader(items: [item("a")]),
                                            database: DeviceDatabase(url: h.folder.appendingPathComponent("device.sqlite")),
                                            identities: ProofIdentities(rows: []), server: h.server)
        let engine = makeEngine(h, checker: checker)
        try await engine.start()
        _ = try await engine.discover(LibraryDiscovery(store: h.store, staging: h.staging))
        try await engine.setIntent(.manual)
        await untilTransfers("An older server without preparation status still backs up unknown originals.") { await engine.currentSnapshot.selectionProgress?.backedUp == 1 }
        XCTAssertEqual(h.server.preparationCallCount, 1)
        XCTAssertEqual(h.staging.staged.count, 1)
        XCTAssertEqual(h.uploads.uploads.count, 1)
        let oldResponse = try JSONDecoder().decode(UploadCheckResponse.self, from: Data(#"{"results":[]}"#.utf8))
        XCTAssertNil(oldResponse.contentFingerprintStatus)
        let gate = BackupPreparationGate()
        for _ in 0..<100 { try await gate.ensureReady(server: h.server) }
        XCTAssertEqual(h.server.preparationCallCount, 2)
        await engine.stop()
        await h.tearDown()
    }

    func testPausedCatalogChangesRemove52DeletedCopiesWithoutStartingBackup() async throws {
        let h = try await LibraryJobHarness()
        let ids = (0..<58).map { "history-\($0)" }
        var seed = TransferSeed()
        seed.preferences = LibraryJobHarness.preferences()
        for id in ids {
            h.staging.add(id)
            seed.confirmations.append((id, FakeStaging.date))
            seed.receipts.append(.init(localID: id, modified: FakeStaging.date, originalID: "server-" + id, originalChecksum: "checksum-" + id))
        }
        try await h.store.seedForTest(seed)
        try await h.engine.setPreferences(seed.preferences)
        _ = try await h.engine.discover(LibraryDiscovery(store: h.store, staging: h.staging))
        let initial = await h.engine.currentSnapshot
        XCTAssertEqual(initial.confirmed, 58)
        XCTAssertEqual(initial.selectionProgress?.backedUp, 58)
        let rows = ids.map { match($0) }
        let catalog = ObservedProofIdentities(rows: rows)
        let reader = ProofReader(items: [])
        let checker = KnownBackupCopyChecker(account: LibraryJobHarness.account, reader: reader,
                                            database: DeviceDatabase(url: h.folder.appendingPathComponent("device.sqlite")),
                                            identities: catalog, server: h.server)
        let observer = BackupConfirmationObserver(checker: checker, store: h.store, refreshed: { await h.engine.refresh() })
        await observer.start(changes: catalog.stream)
        await untilTransfers("The read-only startup pass checked the saved catalog.") { catalog.reads > 0 }
        var changed = rows
        for index in 0..<52 { changed[index].backupAvailable = false; changed[index].visible = false }
        catalog.replace(changed)
        await untilTransfers("A paused account adopts the server's 52 trashed-copy updates.") { await h.engine.currentSnapshot.confirmed == 6 }
        let updated = await h.engine.currentSnapshot
        XCTAssertEqual(updated.intent, .paused)
        XCTAssertEqual(updated.selectionProgress?.backedUp, 6)
        XCTAssertEqual(updated.selectionProgress?.unchecked, 52)
        XCTAssertEqual(updated.selectionProgress?.pending, 0)
        let savedPreferences = try await h.store.preferences()
        XCTAssertEqual(savedPreferences?.automatic, false)
        XCTAssertEqual(reader.readCount, 0)
        XCTAssertTrue(h.staging.staged.isEmpty)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        XCTAssertEqual(h.server.checkCallCount, 0)
        XCTAssertEqual(h.server.preparationCallCount, 0)
        let history = try await h.store.historyPage(offset: 0, limit: 100)
        XCTAssertEqual(history.count, 6)
        await observer.stop()
        await h.tearDown()
    }

    func testReadOnlyConfirmationStartupDropsKnownTrashAndOfflineFailurePreservesHistory() async throws {
        for offline in [false, true] {
            let h = try await LibraryJobHarness()
            var seed = TransferSeed()
            seed.confirmations.append(("a", FakeStaging.date))
            seed.receipts.append(.init(localID: "a", modified: FakeStaging.date, originalID: "server-a", originalChecksum: "checksum-a"))
            try await h.store.seedForTest(seed)
            var trashed = match("a")
            trashed.backupAvailable = false
            let catalog = ObservedProofIdentities(rows: [trashed], offline: offline)
            let checker = KnownBackupCopyChecker(account: LibraryJobHarness.account, reader: ProofReader(items: []),
                                                database: DeviceDatabase(url: h.folder.appendingPathComponent("device.sqlite")),
                                                identities: catalog, server: h.server)
            let observer = BackupConfirmationObserver(checker: checker, store: h.store, refreshed: { await h.engine.refresh() })
            await observer.start(changes: catalog.stream)
            await untilTransfers("The read-only account startup pass finishes.") { catalog.reads > 0 }
            if !offline { await untilTransfers("Saved trash cannot remain a current confirmation.") { try await h.store.historyPage(offset: 0, limit: 10).isEmpty } }
            await observer.stop()
            let history = try await h.store.historyPage(offset: 0, limit: 10)
            XCTAssertEqual(history.count, offline ? 1 : 0)
            let state = try await h.store.engineState()
            XCTAssertEqual(state?.intent, .paused)
            XCTAssertTrue(h.staging.staged.isEmpty)
            XCTAssertTrue(h.uploads.uploads.isEmpty)
            await h.tearDown()
        }
    }

    private func makeEngine(_ h: LibraryJobHarness, checker: any KnownBackupCopyChecking) -> TransferEngine<TestClock> {
        let executor = LibraryJobExecutor(store: h.store, staging: h.staging, server: h.server, uploader: h.uploads,
                                         layout: h.group.layout, account: LibraryJobHarness.account, knownBackupChecker: checker)
        let clock = h.clock
        return TransferEngine(store: h.store, executor: LaneJobExecutor(library: executor, share: FakeJobExecutor()),
                              authorization: h.authorization, clock: clock,
                              now: { TransferEngineHarness.base.addingTimeInterval(TimeInterval(clock.now.offset.components.seconds)) })
    }

    private func item(_ id: String, unadjusted: Bool = true, shape: ResourceShape = .singleOriginal) -> DeviceTimelineItem {
        DeviceTimelineItem(photo: LocalPhoto(id: id, date: FakeStaging.date, modified: FakeStaging.date), cloudID: "cloud-" + id,
                           unadjusted: unadjusted, shape: shape)
    }
    private func match(_ id: String, serverID: String? = nil, created: Date = FakeStaging.date, visible: Bool = true) -> LocalAssetMatch {
        LocalAssetMatch(assetID: serverID ?? "server-" + id, checksum: "checksum-" + id, cloudID: "cloud-" + id,
                        createdAt: created, adjustmentTime: nil, latitude: nil, longitude: nil, visible: visible)
    }
    private func remote(_ id: String, owner: String = "owner", trashed: Bool = false, visibility: String = "timeline") -> BackupRemoteAsset {
        BackupRemoteAsset(id: "server-" + id, ownerId: owner, checksum: "checksum-" + id, isTrashed: trashed,
                          livePhotoVideoId: nil, visibility: visibility)
    }
}

private final class ProofReader: DeviceIndexReading {
    private let values: [String: DeviceTimelineItem]
    private let reads = Mutex(0)
    init(items: [DeviceTimelineItem]) { values = Dictionary(uniqueKeysWithValues: items.map { ($0.photo.id, $0) }) }
    var readCount: Int { reads.withLock { $0 } }
    func access() async -> DeviceAccess { DeviceAccess(status: .authorized, generation: 1) }
    func changes() -> AsyncStream<DeviceLibraryChange> { AsyncStream { _ in } }
    func members(scope: PhotoSelectionScope, included: Set<String>, excluded: Set<String>) async throws -> Set<String> { Set(values.keys) }
    func items(_ ids: [String]) async throws -> [DeviceTimelineItem] { reads.withLock { $0 += ids.count }; return ids.compactMap { values[$0] } }
    func fingerprint(of id: String) async throws -> String { throw CocoaError(.fileReadNoSuchFile) }
    func revision(of id: String) async -> Date? { values[id]?.photo.modified }
}

private struct ProofIdentities: DeviceIndexServer {
    let rows: [LocalAssetMatch]
    func identities() async throws -> [LocalAssetMatch]? { rows }
    func changes() async -> AsyncStream<LibraryChange> { AsyncStream { _ in } }
}

private final class MutableProofIdentities: DeviceIndexServer {
    private let rows: [LocalAssetMatch]
    private let state: Mutex<(complete: Bool, reads: Int)>
    init(rows: [LocalAssetMatch], complete: Bool) { self.rows = rows; state = Mutex((complete, 0)) }
    var complete: Bool {
        get { state.withLock { $0.complete } }
        set { state.withLock { $0.complete = newValue } }
    }
    var fullReads: Int { state.withLock { $0.reads } }
    func identityIndexComplete() async throws -> Bool { complete }
    func identities() async throws -> [LocalAssetMatch]? {
        state.withLock { $0.reads += 1; return $0.complete ? rows : nil }
    }
    func changes() async -> AsyncStream<LibraryChange> { AsyncStream { _ in } }
}

private final class ObservedProofIdentities: DeviceIndexServer {
    private struct State { var rows: [LocalAssetMatch]; var reads = 0; var offline: Bool }
    private let state: Mutex<State>
    let stream: AsyncStream<LibraryChange>
    private let continuation: AsyncStream<LibraryChange>.Continuation

    init(rows: [LocalAssetMatch], offline: Bool = false) {
        state = Mutex(State(rows: rows, offline: offline))
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    var reads: Int { state.withLock { $0.reads } }
    func replace(_ rows: [LocalAssetMatch]) {
        state.withLock { $0.rows = rows }
        let account = LibraryJobHarness.account
        var change = LibraryChange(account: account, authorization: AuthorizationEpoch(account: account, value: 1), indexRevision: 2, origin: .sync)
        change.upserted = Dictionary(uniqueKeysWithValues: rows.map { ($0.assetID, LibraryChange.MonthMove(from: nil, to: nil)) })
        continuation.yield(change)
    }
    func identities() async throws -> [LocalAssetMatch]? {
        try state.withLock { state in
            state.reads += 1
            if state.offline { throw URLError(.notConnectedToInternet) }
            return state.rows
        }
    }
    func identityIndexComplete() async throws -> Bool { true }
    func changes() async -> AsyncStream<LibraryChange> { stream }
}

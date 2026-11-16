import Foundation
import IlyichPlatform
import Photos
import Synchronization
import XCTest
@testable import Ilyich

final class SourceOriginalArchiveTests: XCTestCase {
    private let revision = AssetRevision(FakeStaging.date)
    private let policy = StagingPolicy()

    func testSourceAssociationCannotConfirmOrCreateCleanupReceiptAndReusesValidatedCache() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "source-bytes"))
        h.server.hold(checksum: "source-bytes", as: .duplicate("archive", trashed: false))
        h.server.remote(remote("archive", checksum: "path-id", algorithm: "sha1-path", content: "source-bytes"))
        let matcher = SourceOriginalArchiveMatcher(account: LibraryJobHarness.account, store: h.store, staging: h.staging, server: h.server)
        let first = try await matcher.match("edit", revision: revision, policy: policy)
        XCTAssertEqual(first?.remoteID, "archive")
        XCTAssertEqual(h.staging.sourceReads, 1)
        let second = try await matcher.match("edit", revision: revision, policy: policy)
        XCTAssertEqual(second?.remoteID, "archive")
        XCTAssertEqual(h.staging.sourceReads, 1, "A current persisted resource snapshot reuses its source checksum.")
        XCTAssertEqual(h.server.checkCallCount, 1, "A cached association is freshly read, without another bulk search.")
        let state = try await h.store.contents()
        XCTAssertTrue(state.confirmations.isEmpty)
        XCTAssertTrue(state.receipts.isEmpty)
        XCTAssertEqual(state.stackTasks, 0)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        await h.tearDown()
    }

    func testPathChecksumUnknownBytesAndUnavailableForeignOrChangedSourcesNeverAssociate() async throws {
        for reason in ["path", "changed", "owner", "trashed", "locked", "offline", "missing", "ambiguous"] {
            let h = try await LibraryJobHarness()
            h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "source-bytes"))
            let server = SourceProofServer()
            server.answer = [duplicate("archive")]
            if reason == "ambiguous" { server.answer = [duplicate("archive"), duplicate("another")] }
            server.asset = remote("archive", checksum: reason == "changed" ? "changed-bytes" : "source-bytes",
                                  algorithm: reason == "path" ? "sha1-path" : "sha1",
                                  owner: reason == "owner" ? "someone-else" : "owner", trashed: reason == "trashed",
                                  visibility: reason == "locked" ? "locked" : "archive", offline: reason == "offline")
            if reason == "missing" { server.failure = .notFound }
            let matcher = SourceOriginalArchiveMatcher(account: LibraryJobHarness.account, store: h.store, staging: h.staging, server: server)
            let result = try await matcher.match("edit", revision: revision, policy: policy)
            XCTAssertNil(result, reason)
            let stored = try await h.store.sourceOriginal(for: "edit", revision: revision)
            XCTAssertNil(stored?.remoteID, reason)
            let receipts = try await h.store.receipts(for: ["edit"])
            XCTAssertTrue(receipts.isEmpty, reason)
            await h.tearDown()
        }
    }

    func testSourceChangesWhileServerChecksCannotPersistAssociationAndTransportFailureCannotConfirm() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "source-bytes"))
        let server = SourceProofServer()
        server.answer = [duplicate("archive")]
        server.asset = remote("archive", checksum: "source-bytes")
        server.onRead = { h.staging.edit("edit", modified: FakeStaging.date.addingTimeInterval(1)) }
        let matcher = SourceOriginalArchiveMatcher(account: LibraryJobHarness.account, store: h.store, staging: h.staging, server: server)
        let stale = try await matcher.match("edit", revision: revision, policy: policy)
        XCTAssertNil(stale)
        let source = try await h.store.sourceOriginal(for: "edit", revision: revision)
        XCTAssertNil(source)
        h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "source-bytes"))
        server.onRead = nil
        server.failure = .http(503, nil)
        do {
            _ = try await matcher.match("edit", revision: revision, policy: policy)
            XCTFail("Transport failure must preserve uncertainty.")
        } catch {}
        let state = try await h.store.contents()
        XCTAssertTrue(state.confirmations.isEmpty)
        XCTAssertTrue(state.receipts.isEmpty)
        XCTAssertEqual(state.stackTasks, 0)
        await h.tearDown()
    }

    func testConfirmedEditsReconcileWhilePausedWithoutUploadsOrConfirmationChangesAndDoNotReplayFinishedTasks() async throws {
        let h = try await LibraryJobHarness()
        var seed = TransferSeed()
        for id in ["a", "b"] {
            seed.confirmations.append((id, FakeStaging.date))
            seed.receipts.append(.init(localID: id, modified: FakeStaging.date, originalID: "edit-" + id, originalChecksum: "edit-bytes-" + id))
            h.staging.add(id, .init(modified: FakeStaging.date, sourceChecksum: "source-" + id))
            h.server.hold(checksum: "source-" + id, as: .duplicate("archive-" + id, trashed: false))
            h.server.remote(remote("archive-" + id, checksum: "source-" + id))
            h.server.remote(remote("edit-" + id, checksum: "edit-bytes-" + id))
        }
        try await h.store.seedForTest(seed)
        let before = try await h.store.contents()
        let service = SourceOriginalArchiveReconciler(account: LibraryJobHarness.account, store: h.store, staging: h.staging, server: h.server)
        let first = try await service.reconcile(limit: 1, policy: policy)
        XCTAssertEqual(first, .init(scanned: 1, matched: 1, scheduled: 1, after: "a", hasMore: true))
        let second = try await service.reconcile(after: first.after, limit: 2, policy: policy)
        XCTAssertEqual(second, .init(scanned: 1, matched: 1, scheduled: 1, after: "b", hasMore: false))
        let tasks = try await h.store.stackTasks()
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks.first?.sourceChecksum, "source-a")
        XCTAssertEqual(tasks.first?.currentChecksum, "edit-bytes-a")
        for task in tasks { try await h.store.finishStackTask(task.id, .done) }
        let replay = try await service.reconcile(policy: policy)
        XCTAssertEqual(replay.matched, 2)
        XCTAssertEqual(replay.scheduled, 0)
        let after = try await h.store.contents()
        XCTAssertEqual(after.confirmations, before.confirmations)
        XCTAssertEqual(after.receipts, before.receipts)
        XCTAssertEqual(after.engine, before.engine)
        XCTAssertEqual(after.engine?.intent, .paused)
        XCTAssertEqual(after.stackTasks, 0)
        XCTAssertTrue(h.staging.staged.isEmpty)
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        XCTAssertTrue(h.server.requests.isEmpty)
        await h.tearDown()
    }

    func testReconciliationRequiresExactCurrentReceiptProofAndKeepsStaleConfirmationsUntouched() async throws {
        for reason in ["changed", "foreign", "stale-revision", "unconfirmed", "cancelled"] {
            let h = try await LibraryJobHarness()
            var seed = TransferSeed()
            if reason != "unconfirmed" { seed.confirmations.append(("edit", FakeStaging.date)) }
            seed.receipts = [.init(localID: "edit", modified: FakeStaging.date, originalID: "current", originalChecksum: "current-bytes")]
            try await h.store.seedForTest(seed)
            h.staging.add("edit", .init(modified: reason == "stale-revision" ? FakeStaging.date.addingTimeInterval(1) : FakeStaging.date,
                                       sourceChecksum: "source-bytes"))
            h.server.hold(checksum: "source-bytes", as: .duplicate("archive", trashed: false))
            h.server.remote(remote("archive", checksum: "source-bytes"))
            h.server.remote(remote("current", checksum: reason == "changed" ? "changed" : "current-bytes",
                                   owner: reason == "foreign" ? "another-owner" : "owner"))
            let before = try await h.store.contents()
            let permitted = reason != "cancelled"
            let service = SourceOriginalArchiveReconciler(account: LibraryJobHarness.account, store: h.store, staging: h.staging,
                                                          server: h.server, permits: { permitted })
            do {
                let result = try await service.reconcile(policy: policy)
                XCTAssertEqual(result.scheduled, 0, reason)
            } catch { XCTAssertEqual(reason, "cancelled") }
            let after = try await h.store.contents()
            XCTAssertEqual(after.confirmations, before.confirmations, reason)
            XCTAssertEqual(after.receipts, before.receipts, reason)
            XCTAssertEqual(after.stackTasks, 0, reason)
            XCTAssertTrue(h.server.requests.isEmpty)
            await h.tearDown()
        }
    }

    func testCurrentEditedDuplicateLinksWithoutUploadAndCompletionUsesBothPreviousAndSourceAssociations() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "source-bytes"))
        // Seed a completed stage so its current checksum is deterministic.
        try await h.seed("edit") { folder in
            LibraryStage(stageID: UUID().uuidString, folder: folder, revision: revision,
                         original: try! h.stagedFile(folder, "original", filename: "edit.JPG", contents: "current-edit"),
                         motion: nil, sidecar: nil, fields: [:], isVideo: false, originalChecksum: "edit-bytes")
        }
        var seed = TransferSeed()
        seed.receipts = [.init(localID: "edit", modified: FakeStaging.date.addingTimeInterval(-1), originalID: "prior-edit", originalChecksum: "prior-bytes")]
        try await h.store.seedForTest(seed)
        h.server.hold(checksum: "source-bytes", as: .duplicate("archive", trashed: false))
        h.server.remote(remote("archive", checksum: "source-bytes"))
        h.server.hold(checksum: "edit-bytes", as: .duplicate("current-edit", trashed: false))
        h.server.remote(remote("current-edit", checksum: "edit-bytes"))
        try await h.engine.setIntent(.manual)
        try await h.engine.start()
        try await untilTransfers("The current duplicate is confirmed without uploading bytes.") { try await h.receipt("edit")?.original.id == "current-edit" }
        let receipt = try await h.receipt("edit")
        XCTAssertEqual(receipt?.original.checksum, "edit-bytes", "Only current rendition bytes belong in a cleanup receipt.")
        let tasks = try await h.store.stackTasks()
        XCTAssertEqual(Set(tasks.map(\.previousAssetID)), ["prior-edit"])
        let originalWork = try await h.store.sourceMatchTasks()
        XCTAssertEqual(originalWork.first?.state, "pending", "Source association requires a fresh post-upload proof pass.")
        XCTAssertTrue(tasks.allSatisfy { $0.assetID == "current-edit" })
        XCTAssertEqual(tasks.first { $0.previousAssetID == "prior-edit" }?.sourceChecksum, "prior-bytes")
        XCTAssertTrue(tasks.allSatisfy { $0.currentChecksum == "edit-bytes" })
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        XCTAssertTrue(h.server.requests.isEmpty)
        await h.tearDown()
    }

    func testOriginalMatchDoesNotSkipUploadingTheCurrentEditAndQueuesOnlyAfterItsCompletion() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "source-bytes"))
        h.server.hold(checksum: "source-bytes", as: .duplicate("archive", trashed: false))
        h.server.remote(remote("archive", checksum: "source-bytes"))
        let gate = TransferGate()
        h.uploads.hold(at: gate)
        try await h.run("edit")
        await untilTransfers("The current rendition has reached its own upload.") { h.uploads.waiting == 1 }
        let before = try await h.store.contents()
        XCTAssertTrue(before.confirmations.isEmpty)
        XCTAssertTrue(before.receipts.isEmpty)
        XCTAssertEqual(before.stackTasks, 0)
        gate.open()
        try await untilTransfers("Only the current rendition's upload can confirm this edit.") { try await h.receipt("edit") != nil }
        let receipt = try await h.receipt("edit")
        XCTAssertNotEqual(receipt?.original.id, "archive")
        XCTAssertNotEqual(receipt?.original.checksum, "source-bytes")
        let tasks = try await h.store.stackTasks()
        XCTAssertTrue(tasks.isEmpty, "Completion cannot queue a retained source candidate without fresh proof.")
        let originalWork = try await h.store.sourceMatchTasks()
        XCTAssertEqual(originalWork.first?.currentID, receipt?.original.id)
        XCTAssertEqual(originalWork.first?.state, "pending")
        XCTAssertEqual(h.uploads.uploads.count, 1)
        await h.tearDown()
    }

    func testUnavailableOptionalSourceDoesNotBlockCurrentEditBackupAndRetainsCachedCandidate() async throws {
        for code in [PHPhotosError.Code.networkAccessRequired, .missingResource] {
            let h = try await LibraryJobHarness()
            h.staging.add("edit", .init(modified: FakeStaging.date))
            h.staging.failSource("edit") { NSError(domain: PHPhotosErrorDomain, code: code.rawValue) }
            try await h.store.saveSourceOriginal(.init(localID: "edit", revision: revision, checksum: "old-source", remoteID: "old-archive"))
            try await h.run("edit")
            try await untilTransfers("A local current rendition can back up while its optional original is unavailable.") { try await h.receipt("edit") != nil }
            let source = try await h.store.sourceOriginal(for: "edit", revision: revision)
            XCTAssertEqual(source?.checksum, "old-source", "Unavailable source reads retain evidence as an unverified candidate.")
            let tasks = try await h.store.stackTasks()
            XCTAssertTrue(tasks.isEmpty)
            XCTAssertEqual(h.uploads.uploads.count, 1)
            await h.tearDown()
        }
    }

    func testOptionalSourceFailureNeverSwallowsCancellationLeaseAccountOrPreparationErrors() async throws {
        let failures: [@Sendable () -> any Error] = [
            { CancellationError() }, { LeaseLost() }, { PurchaseAccessRequired() },
            { ServerFailure.forbidden(nil) }, { ServerFailure.sessionExpired(nil) },
            { ServerFailure.externalContentFingerprintsPending },
        ]
        for failure in failures {
            let h = try await LibraryJobHarness()
            h.staging.add("edit", .init(modified: FakeStaging.date, sourceChecksum: "source"))
            h.staging.failSource("edit", failure)
            let matcher = SourceOriginalArchiveMatcher(account: LibraryJobHarness.account, store: h.store, staging: h.staging, server: h.server)
            do {
                _ = try await matcher.match("edit", revision: revision, policy: policy)
                XCTFail("Cancellation and authorization errors must propagate.")
            } catch {}
            XCTAssertEqual(h.server.checkCallCount, 0)
            let tasks = try await h.store.stackTasks()
            XCTAssertTrue(tasks.isEmpty)
            await h.tearDown()
        }
    }

    func testExplicitReconciliationSkipsUnavailableSourcesAndRetriesOnlyFailedVerifiedProofTasks() async throws {
        let h = try await LibraryJobHarness()
        var seed = TransferSeed()
        for id in ["a-unavailable", "b-available"] {
            seed.confirmations.append((id, FakeStaging.date))
            seed.receipts.append(.init(localID: id, modified: FakeStaging.date, originalID: "edit-" + id, originalChecksum: "edit-bytes"))
            h.staging.add(id, .init(modified: FakeStaging.date, sourceChecksum: "source-" + id))
            h.server.hold(checksum: "source-" + id, as: .duplicate("archive-" + id, trashed: false))
            h.server.remote(remote("archive-" + id, checksum: "source-" + id))
            h.server.remote(remote("edit-" + id, checksum: "edit-bytes"))
        }
        h.staging.failSource("a-unavailable") { BackupDeferral.waitingForWiFi }
        try await h.store.seedForTest(seed)
        let service = SourceOriginalArchiveReconciler(account: LibraryJobHarness.account, store: h.store, staging: h.staging, server: h.server)
        let first = try await service.reconcile(policy: policy)
        XCTAssertEqual(first.scanned, 2)
        XCTAssertEqual(first.scheduled, 1)
        let firstTasks = try await h.store.stackTasks()
        let task = try XCTUnwrap(firstTasks.first)
        try await h.store.finishStackTask(task.id, .failed("Server stack conflict"))
        let replay = try await service.reconcile(policy: policy)
        XCTAssertEqual(replay.scheduled, 1, "An explicit fresh proof rematch retries the failed task.")
        let replayTasks = try await h.store.stackTasks()
        XCTAssertEqual(replayTasks.count, 1)
        XCTAssertEqual(replayTasks.first?.id, task.id)
        XCTAssertEqual(replayTasks.first?.state, "pending")
        XCTAssertEqual(replayTasks.first?.attempts, 0)
        XCTAssertNil(replayTasks.first?.error)
        try await h.store.finishStackTask(task.id, .done)
        let finished = try await service.reconcile(policy: policy)
        XCTAssertEqual(finished.scheduled, 0, "A completed link stays remembered after manual unstacking.")
        let after = try await h.store.contents()
        XCTAssertEqual(after.engine?.intent, .paused)
        XCTAssertEqual(after.confirmations.count, 2)
        XCTAssertTrue(h.server.requests.isEmpty)
        await h.tearDown()
    }

    func testQueueTransactionChecksCurrentAuthorizationBeforeSchedulingProofTask() async throws {
        let h = try await LibraryJobHarness()
        var seed = TransferSeed()
        seed.confirmations = [("edit", FakeStaging.date)]
        seed.receipts = [.init(localID: "edit", modified: FakeStaging.date, originalID: "current", originalChecksum: "current-bytes")]
        try await h.store.seedForTest(seed)
        try await h.store.saveSourceOriginal(.init(localID: "edit", revision: revision, checksum: "source", remoteID: "archive"))
        let current = try await h.store.receipts(for: ["edit"])
        let receipt = try XCTUnwrap(current["edit"])
        do {
            _ = try await h.store.enqueueSourceOriginalStack(ifCurrent: receipt, permits: { false }, retryFailed: true)
            XCTFail("Revoked authorization must be checked inside the store transaction.")
        } catch is CancellationError {}
        let tasks = try await h.store.stackTasks()
        XCTAssertTrue(tasks.isEmpty)
        let allowed = try await h.store.enqueueSourceOriginalStack(ifCurrent: receipt, permits: { true }, retryFailed: true)
        XCTAssertTrue(allowed, "The refused transaction did not mark the association scheduled.")
        await h.tearDown()
    }

    func testReceiptCASAndSameArchiveHistoryDoNotScheduleWrongOrDuplicatePairs() async throws {
        let h = try await LibraryJobHarness()
        var seed = TransferSeed()
        seed.confirmations = [("edit", FakeStaging.date)]
        seed.receipts = [.init(localID: "edit", modified: FakeStaging.date, originalID: "current", originalChecksum: "current-bytes")]
        try await h.store.seedForTest(seed)
        try await h.store.saveSourceOriginal(.init(localID: "edit", revision: revision, checksum: "source", remoteID: "archive"))
        let stale = TransferReceipt(localID: "edit", revision: revision, original: .init(id: "previous-current", checksum: "current-bytes"),
                                    motion: nil, confirmedAt: nil)
        let acceptedStale = try await h.store.enqueueSourceOriginalStack(ifCurrent: stale)
        XCTAssertFalse(acceptedStale)
        let current = try await h.store.receipts(for: ["edit"])
        let receipt = try XCTUnwrap(current["edit"])
        let once = try await h.store.enqueueSourceOriginalStack(ifCurrent: receipt)
        let twice = try await h.store.enqueueSourceOriginalStack(ifCurrent: receipt)
        XCTAssertTrue(once)
        XCTAssertFalse(twice)
        let tasks = try await h.store.stackTasks()
        XCTAssertEqual(tasks.count, 1)
        await h.tearDown()
    }

    private func remote(_ id: String, checksum: String, algorithm: String = "sha1", content: String? = nil,
                        owner: String = "owner", trashed: Bool = false, visibility: String = "archive", offline: Bool = false) -> BackupRemoteAsset {
        .init(id: id, ownerId: owner, checksum: checksum, isTrashed: trashed, livePhotoVideoId: nil, visibility: visibility,
              isOffline: offline, checksumAlgorithm: algorithm, contentChecksum: content, isExternal: algorithm == "sha1-path")
    }

    private func duplicate(_ id: String) -> UploadCheckResponse.Result {
        let data = Data("{\"id\":\"edit\",\"action\":\"reject\",\"reason\":\"duplicate\",\"assetId\":\"\(id)\",\"isTrashed\":false}".utf8)
        return try! JSONDecoder().decode(UploadCheckResponse.Result.self, from: data)
    }
}

/// Scripted only for exact proof reads; no upload capability exists on this reconciliation fake.
private final class SourceProofServer: TransferServerAPI, @unchecked Sendable {
    var answer: [UploadCheckResponse.Result] = []
    var asset: BackupRemoteAsset?
    var failure: ServerFailure?
    var onRead: (@Sendable () -> Void)?
    func bulkUploadCheck(_ items: [UploadCheck.Item]) async throws -> [UploadCheckResponse.Result] { answer }
    func remoteAsset(id: String) async throws -> BackupRemoteAsset {
        if let failure { throw failure }
        onRead?()
        return asset!
    }
    func uploadRequest(boundary: String, allowsCellular: Bool) async throws -> URLRequest { throw URLError(.unsupportedURL) }
    func livePhotoVideoID(of assetID: String) async throws -> String? { nil }
    func setLivePhotoVideo(assetID: String, motionID: String) async throws { throw URLError(.unsupportedURL) }
    func createStack(_ assetIDs: [String]) async throws { throw URLError(.unsupportedURL) }
    func addToAlbum(_ albumID: String, assetIDs: [String]) async throws -> [BulkResult] { throw URLError(.unsupportedURL) }
    func ownedAlbums() async throws -> [Album] { [] }
    func createAlbum(name: String) async throws -> Album { throw URLError(.unsupportedURL) }
}

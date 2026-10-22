import Foundation
import IlyichPlatform
import Synchronization
import XCTest
@testable import Ilyich

/// The server's albums and stacks as the post-upload work sees them. Uploads go to the plain fake.
final class FakeFollowUpServer: TransferServerAPI {
    struct AlbumCall: Equatable, Sendable {
        let album: String
        let ids: [String]
    }

    private struct State {
        var albumCalls: [AlbumCall] = []
        var stackCalls: [[String]] = []
        var albumErrors: [String: @Sendable () -> any Error] = [:]
        var duplicates: Set<String> = []
        var stackError: (@Sendable () -> any Error)?
        var owned: [Album] = []
        var created: [String] = []
    }

    private let state = Mutex(State())
    let uploads = FakeTransferServer()

    var albumCalls: [AlbumCall] { state.withLock { $0.albumCalls } }
    var stackCalls: [[String]] { state.withLock { $0.stackCalls } }
    var created: [String] { state.withLock { $0.created } }
    func failAlbum(_ album: String, _ error: @escaping @Sendable () -> any Error) { state.withLock { $0.albumErrors[album] = error } }
    func clearAlbumFailures() { state.withLock { $0.albumErrors = [:] } }
    /// The album already holds the asset.
    func holdInAlbum(_ asset: String) { state.withLock { _ = $0.duplicates.insert(asset) } }
    func failStacks(_ error: @escaping @Sendable () -> any Error) { state.withLock { $0.stackError = error } }
    func own(_ album: Album) { state.withLock { $0.owned.append(album) } }

    static func album(_ id: String, name: String) -> Album {
        Album(id: id, albumName: name, description: nil, albumThumbnailAssetId: nil, assetCount: 0, shared: false, albumUsers: nil, startDate: nil,
              endDate: nil, updatedAt: nil, order: nil)
    }

    func bulkUploadCheck(_ items: [UploadCheck.Item]) async throws -> [UploadCheckResponse.Result] { try await uploads.bulkUploadCheck(items) }
    func uploadRequest(boundary: String, allowsCellular: Bool) async throws -> URLRequest {
        try await uploads.uploadRequest(boundary: boundary, allowsCellular: allowsCellular)
    }
    func remoteAsset(id: String) async throws -> BackupRemoteAsset { try await uploads.remoteAsset(id: id) }
    func livePhotoVideoID(of assetID: String) async throws -> String? { try await uploads.livePhotoVideoID(of: assetID) }
    func setLivePhotoVideo(assetID: String, motionID: String) async throws { try await uploads.setLivePhotoVideo(assetID: assetID, motionID: motionID) }

    func createStack(_ assetIDs: [String]) async throws {
        let error = state.withLock { state in
            state.stackCalls.append(assetIDs)
            return state.stackError
        }
        if let error { throw error() }
    }

    func addToAlbum(_ albumID: String, assetIDs: [String]) async throws -> [BulkResult] {
        let (error, duplicates) = state.withLock { state in
            state.albumCalls.append(AlbumCall(album: albumID, ids: assetIDs))
            return (state.albumErrors[albumID], state.duplicates)
        }
        if let error { throw error() }
        return assetIDs.map { id in
            duplicates.contains(id) ? BulkResult(id: id, success: false, error: "duplicate", errorMessage: nil)
                : BulkResult(id: id, success: true, error: nil, errorMessage: nil)
        }
    }

    func ownedAlbums() async throws -> [Album] { state.withLock { $0.owned } }

    func createAlbum(name: String) async throws -> Album {
        state.withLock { state in
            let album = Self.album("server-" + name, name: name)
            state.created.append(name)
            state.owned.append(album)
            return album
        }
    }
}

/// A transfers database the engine owns, with the post-upload work on fakes.
struct PostUploadHarness {
    let folder: URL
    let store: TransferStore
    let server = FakeFollowUpServer()
    let staging = FakeStaging()
    let authorization = FakeTransferAuthorization()
    let worker: PostUploadWorker
    static let albumA = "11111111-1111-4111-8111-111111111111"
    static let albumB = "22222222-2222-4222-8222-222222222222"
    static let revision = AssetRevision(referenceSeconds: 700_000_000.25)

    /// The worker's clock, which a test moves.
    let clock = Locked(Date(timeIntervalSinceReferenceDate: 800_000_000))

    init(conditionsPermit: @escaping @Sendable (Bool) async -> Bool = { _ in true }) async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PostUpload-" + UUID().uuidString, isDirectory: true)
        store = TransferStore(url: folder.appendingPathComponent("transfers.sqlite"))
        try await store.claimForEngine()
        try await store.savePreferences(LibraryJobHarness.preferences())
        let clock = clock
        worker = PostUploadWorker(store: store, server: server, photos: staging, authorization: authorization, now: { clock.value },
                                  conditionsPermit: conditionsPermit)
    }

    /// Queues the photo, with the album if any, and commits its upload as the engine would.
    func backUp(_ id: String, as assetID: String? = nil, album: String? = nil) async throws {
        _ = try await store.enqueue([TransferRequest(source: .photo(DeviceAssetID(rawValue: id)), origin: .albumUpload, album: album)])
        guard let job = try await store.job(lane: .library, sourceKey: id) else { throw TransferEngineHarness.Missing() }
        let asset = assetID ?? "asset-" + id
        let receipt = TransferReceipt(localID: id, revision: Self.revision, original: RemoteCopy(id: asset, checksum: "sum-" + asset), motion: nil,
                                      confirmedAt: nil)
        let committed = try await store.complete(TransferCompletion(job: job.id, lease: nil, localID: id, revision: Self.revision, assetID: asset,
                                                                    receipt: receipt, confirmedAt: Date()))
        XCTAssertTrue(committed)
    }

    func confirmed(_ id: String) async throws -> Bool {
        try await store.historyPage(offset: 0, limit: 10_000).contains { $0.localID.rawValue == id }
    }

    func tearDown() async {
        await worker.stop()
        await store.close()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// B4: the work an upload leaves (albums, stacks, linked albums) never un-confirms a backup and
/// never stops the run.
final class PostUploadTests: XCTestCase {
    func testAlbum403KeepsReceiptAndConfirmation() async throws {
        let h = try await PostUploadHarness()
        try await h.backUp("p1", album: PostUploadHarness.albumA)
        try await h.backUp("p2", album: PostUploadHarness.albumB)
        h.server.failAlbum(PostUploadHarness.albumA) { ServerFailure.forbidden("No permission") }

        let report = await h.worker.runPass(linkedAlbums: false)

        XCTAssertEqual(report.albums.failed, 1)
        XCTAssertEqual(report.albums.done, 1)
        XCTAssertEqual(report.failedAlbums, [PostUploadHarness.albumA])
        // The photo stays backed up, with its receipt; only the album add failed.
        let receipt = try await h.store.receipts(for: ["p1"])["p1"]
        XCTAssertEqual(receipt?.original.id, "asset-p1")
        let confirmed = try await h.confirmed("p1")
        XCTAssertTrue(confirmed)
        let rows = try await h.store.albumDestinations()
        XCTAssertEqual(rows.map(\.localID), ["p1"], "the other album's add went ahead and is done")
        XCTAssertEqual(rows.first?.state, "failed")
        XCTAssertEqual(rows.first?.error, PostUploadWorker.albumMessage)
        let counts = try await h.store.failedAlbumDestinationCounts()
        XCTAssertEqual(counts, [PostUploadHarness.albumA: 1])

        // Only the user retries a failed add.
        _ = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(h.server.albumCalls.filter { $0.album == PostUploadHarness.albumA }.count, 1)
        let requeued = try await h.store.requeueFailedFollowUps()
        XCTAssertEqual(requeued, 1)
        h.server.failAlbum(PostUploadHarness.albumA) { URLError(.timedOut) }
        let retried = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(retried.albums.retrying, 1)
        let pending = try await h.store.albumDestinations()
        XCTAssertEqual(pending.first?.state, "pending")
        await h.tearDown()
    }

    func testAlbumDestinationsWaitForTheServerIDAndSendAtMost500IDs() async throws {
        let h = try await PostUploadHarness()
        // Queued, not yet uploaded: nothing to add.
        _ = try await h.store.enqueue([TransferRequest(source: .photo(DeviceAssetID(rawValue: "waiting")), origin: .albumUpload,
                                                       album: PostUploadHarness.albumA)])
        let idle = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(idle.albums.done + idle.albums.failed + idle.albums.retrying, 0)
        XCTAssertTrue(h.server.albumCalls.isEmpty)

        let ids = (0..<501).map { String(format: "p%04d", $0) }
        for id in ids { try await h.backUp(id, album: PostUploadHarness.albumA) }
        h.server.holdInAlbum("asset-p0000")
        let report = await h.worker.runPass(linkedAlbums: false)

        XCTAssertEqual(h.server.albumCalls.map(\.ids.count), [500, 1])
        XCTAssertEqual(report.albums.done, 501, "an asset the album already had counts as added")
        let left = try await h.store.albumDestinations()
        XCTAssertEqual(left.map(\.localID), ["waiting"])
        await h.tearDown()
    }

    func testAPhotoAlreadyBackedUpJoinsTheAlbumWithoutUploading() async throws {
        let h = try await PostUploadHarness()
        try await h.backUp("p1")
        let result = try await h.store.enqueue([TransferRequest(source: .photo(DeviceAssetID(rawValue: "p1")), origin: .albumUpload,
                                                                revision: PostUploadHarness.revision, album: PostUploadHarness.albumA)])
        XCTAssertEqual(result.queued, 0)
        XCTAssertEqual(result.alreadyBackedUp, 1)
        _ = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(h.server.albumCalls, [FakeFollowUpServer.AlbumCall(album: PostUploadHarness.albumA, ids: ["asset-p1"])])
        await h.tearDown()
    }

    func testAStaleReceiptDoesNotNameTheAlbumsServerCopy() async throws {
        let h = try await PostUploadHarness()
        try await h.backUp("p1")
        // p1 is edited and backed up again, committed without a receipt: the old receipt stays.
        let edited = AssetRevision(referenceSeconds: 700_000_100)
        _ = try await h.store.enqueue([TransferRequest(source: .photo(DeviceAssetID(rawValue: "p1")), origin: .selection, revision: edited)])
        let job = try await h.store.job(lane: .library, sourceKey: "p1")
        let committed = try await h.store.complete(TransferCompletion(job: try XCTUnwrap(job).id, lease: nil, localID: "p1", revision: edited,
                                                                      assetID: "asset-p1-edited", receipt: nil, confirmedAt: Date()))
        XCTAssertTrue(committed)

        let result = try await h.store.enqueue([TransferRequest(source: .photo(DeviceAssetID(rawValue: "p1")), origin: .albumUpload,
                                                                revision: edited, album: PostUploadHarness.albumA)])
        XCTAssertEqual(result.queued, 1, "the server ID comes from uploading again, not from the pre-edit receipt")
        let rows = try await h.store.albumDestinations()
        XCTAssertEqual(rows.map(\.remoteID), [nil])
        _ = await h.worker.runPass(linkedAlbums: false)
        XCTAssertTrue(h.server.albumCalls.isEmpty, "the pre-edit copy never joins the album")
        await h.tearDown()
    }

    func testAFailureThatMayPassBacksOffInsteadOfUsingUpItsTries() async throws {
        let h = try await PostUploadHarness()
        try await h.backUp("p1", album: PostUploadHarness.albumA)
        h.server.failAlbum(PostUploadHarness.albumA) { ServerFailure.http(500, nil) }

        let first = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(first.albums.retrying, 1)
        // The passes after the next commits leave it alone while it backs off.
        for _ in 0..<6 { _ = await h.worker.runPass(linkedAlbums: false) }
        XCTAssertEqual(h.server.albumCalls.count, 1)
        var rows = try await h.store.albumDestinations()
        XCTAssertEqual(rows.first?.state, "pending")
        XCTAssertEqual(rows.first?.attempts, 1)

        // Once the backoff runs out it is tried again, and the outage is over.
        h.clock.mutate { $0 += PostUploadWorker.backoffDelay(afterAttempts: 1) + 1 }
        h.server.failAlbum(PostUploadHarness.albumA) { ServerFailure.http(500, nil) }
        let second = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(second.albums.retrying, 1)
        XCTAssertEqual(h.server.albumCalls.count, 2)
        XCTAssertGreaterThan(PostUploadWorker.backoffDelay(afterAttempts: 2), PostUploadWorker.backoffDelay(afterAttempts: 1))
        h.clock.mutate { $0 += PostUploadWorker.backoffDelay(afterAttempts: 2) + 1 }
        h.server.clearAlbumFailures()
        let third = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(third.albums.done, 1)
        rows = try await h.store.albumDestinations()
        XCTAssertTrue(rows.isEmpty)

        // A manual run tries at once what backs off.
        try await h.backUp("p2", album: PostUploadHarness.albumB)
        h.server.failAlbum(PostUploadHarness.albumB) { ServerFailure.http(500, nil) }
        _ = await h.worker.runPass(linkedAlbums: false)
        let calls = h.server.albumCalls.count
        await h.worker.request(.manualRun)
        await h.worker.idle()
        XCTAssertEqual(h.server.albumCalls.count, calls + 1)
        await h.tearDown()
    }

    func testRequireChargingStopsThePassUnplugged() async throws {
        let plugged = Locked(false)
        let asked = Locked<[Bool]>([])
        let h = try await PostUploadHarness(conditionsPermit: { requireCharging in
            asked.mutate { $0.append(requireCharging) }
            return !requireCharging || plugged.value
        })
        var preferences = LibraryJobHarness.preferences()
        preferences.requireCharging = true
        preferences.includedAlbums = ["trips"]
        preferences.syncAlbums = true
        try await h.store.savePreferences(preferences)
        h.staging.add("t1", album: "trips")
        try await h.backUp("t1", album: PostUploadHarness.albumA)

        let unplugged = await h.worker.runPass(linkedAlbums: true)
        XCTAssertTrue(unplugged.stopped)
        XCTAssertTrue(unplugged.waitingForDevice)
        XCTAssertNil(unplugged.stoppedBy)
        XCTAssertTrue(h.server.albumCalls.isEmpty)
        XCTAssertTrue(h.server.created.isEmpty)
        let rows = try await h.store.albumDestinations()
        XCTAssertEqual(rows.first?.attempts, 0, "waiting blames nothing")
        XCTAssertEqual(Set(asked.value), [true])

        plugged.mutate { $0 = true }
        let charging = await h.worker.runPass(linkedAlbums: true)
        XCTAssertFalse(charging.stopped)
        XCTAssertEqual(charging.albums.done, 1)
        XCTAssertEqual(charging.linkedAlbums, 1)
        await h.tearDown()
    }

    func testStackFailureDoesNotStopTheRun() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PostUploadRun-" + UUID().uuidString, isDirectory: true)
        let store = TransferStore(url: folder.appendingPathComponent("transfers.sqlite"))
        try await store.claimForEngine()
        try await store.savePreferences(LibraryJobHarness.preferences())
        let server = FakeFollowUpServer()
        server.failStacks { ServerFailure.http(400, "Not an asset of yours") }
        let authorization = FakeTransferAuthorization()
        let worker = PostUploadWorker(store: store, server: server, photos: FakeStaging(), authorization: authorization)
        let clock = TestClock()
        let executor = FakeJobExecutor()
        let engine = TransferEngine(store: store, executor: executor, authorization: authorization, clock: clock,
                                    followUp: { worker.wake($0) }, now: { TransferEngineHarness.base }, random: { 0.5 })

        // p1 was backed up before under another server ID: its new upload is stacked on that one.
        _ = try await store.enqueue([TransferRequest(source: .photo(DeviceAssetID(rawValue: "p1")), origin: .legacy)])
        let earlier = try await store.job(lane: .library, sourceKey: "p1")
        let earlierID = try XCTUnwrap(earlier).id
        _ = try await store.complete(TransferCompletion(
            job: earlierID, lease: nil, localID: "p1", revision: AssetRevision(referenceSeconds: 1),
            assetID: "old-p1", receipt: TransferReceipt(localID: "p1", revision: AssetRevision(referenceSeconds: 1),
                                                        original: RemoteCopy(id: "old-p1", checksum: "old"), motion: nil, confirmedAt: nil),
            confirmedAt: Date()))
        _ = try await engine.enqueue(["p1", "p2", "p3"].map {
            TransferRequest(source: .photo(DeviceAssetID(rawValue: $0)), origin: .selection, album: PostUploadHarness.albumA)
        })
        try await engine.setIntent(.automatic)
        try await engine.start()

        try await untilTransfers("every photo backed up and added") {
            let left = try await store.albumDestinations()
            let stacks = try await store.stackTasks()
            return try await store.receipts(for: ["p1", "p2", "p3"]).count == 3 && left.isEmpty && stacks.first?.state == "failed"
        }
        XCTAssertEqual(server.stackCalls, [["asset-p1", "old-p1"]])
        let receipt = try await store.receipts(for: ["p1"])["p1"]
        XCTAssertEqual(receipt?.original.id, "asset-p1", "the new upload stays confirmed")
        let stacks = try await store.stackTasks()
        XCTAssertEqual(stacks.first?.error, PostUploadWorker.stackMessage)
        let counts = try await store.counts()
        XCTAssertEqual(counts.remaining, 0)
        XCTAssertEqual(counts.failed, 0)

        await engine.stop()
        await worker.stop()
        await store.close()
        try? FileManager.default.removeItem(at: folder)
    }

    func testAnExpiredSessionStopsThePassWithoutBlamingAnything() async throws {
        let h = try await PostUploadHarness()
        try await h.backUp("p1", album: PostUploadHarness.albumA)
        h.server.failAlbum(PostUploadHarness.albumA) { ServerFailure.sessionExpired(nil) }
        let report = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(report.stoppedBy, .sessionExpired)
        let rows = try await h.store.albumDestinations()
        XCTAssertEqual(rows.first?.state, "pending")
        XCTAssertEqual(rows.first?.attempts, 0)

        // Read-only mode: nothing is sent at all.
        h.authorization.setReadOnly(true)
        let readOnly = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(readOnly.stoppedBy, .readOnly)
        XCTAssertEqual(h.server.albumCalls.count, 1)
        await h.tearDown()
    }

    func testLinkedAlbumsFailPerAlbum() async throws {
        let h = try await PostUploadHarness()
        var preferences = LibraryJobHarness.preferences()
        preferences.includedAlbums = ["trips", "pets"]
        preferences.syncAlbums = true
        try await h.store.savePreferences(preferences)
        h.staging.add("t1", album: "trips")
        h.staging.add("t2", album: "trips")
        h.staging.add("d1", album: "pets")
        for id in ["t1", "t2", "d1"] { try await h.backUp(id) }
        // "pets" is already on the server under its name; "trips" is made.
        h.server.own(FakeFollowUpServer.album("server-pets", name: "pets"))
        h.server.failAlbum("server-pets") { ServerFailure.forbidden(nil) }

        let skipped = await h.worker.runPass(linkedAlbums: false)
        XCTAssertEqual(skipped.linkedAlbums, 0, "linked albums sync only after a run")
        let report = await h.worker.runPass(linkedAlbums: true)

        XCTAssertEqual(report.linkedAlbums, 1)
        XCTAssertEqual(Set(report.linkedFailures.keys), ["pets"])
        XCTAssertEqual(h.server.created, ["trips"])
        let trips = h.server.albumCalls.first { $0.album == "server-trips" }
        XCTAssertEqual(trips?.ids, ["asset-t1", "asset-t2"])
        let linked = try await h.store.linkedAlbums()
        XCTAssertEqual(linked, ["trips": "server-trips", "pets": "server-pets"])
        for id in ["t1", "t2", "d1"] {
            let confirmed = try await h.confirmed(id)
            XCTAssertTrue(confirmed)
        }

        // Linked albums are off: nothing syncs.
        preferences.syncAlbums = false
        try await h.store.savePreferences(preferences)
        let calls = h.server.albumCalls.count
        _ = await h.worker.runPass(linkedAlbums: true)
        XCTAssertEqual(h.server.albumCalls.count, calls)
        await h.tearDown()
    }
}

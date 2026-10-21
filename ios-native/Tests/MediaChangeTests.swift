import IlyichPlatform
import UIKit
import XCTest
@testable import Ilyich

/// Library changes reach the media caches precisely: only the photos a change names lose their
/// images, and nothing the user can still see is purged.
@MainActor final class MediaChangeTests: XCTestCase {
    private let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
        UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    private func makePipeline(server: StubServer? = nil) throws -> (APIClient, MediaPipeline) {
        let api: APIClient
        if let server {
            api = try APIClient(baseURL: server.baseURL, accessToken: "media-session", userID: "media-" + UUID().uuidString,
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        } else {
            api = try APIClient(baseURL: XCTUnwrap(URL(string: "https://media-change.example")), accessToken: "media-session",
                                userID: "media-" + UUID().uuidString)
        }
        let pipeline = MediaPipeline(client: api, protocolClasses: server == nil ? nil : [StubURLProtocol.self], earlierURLCacheEntries: false)
        addTeardownBlock { await pipeline.removeAll(); await api.shutdown() }
        return (api, pipeline)
    }

    /// Stores each photo's thumbnail and decodes it at two cell sizes.
    private func cache(_ assets: [Asset], in pipeline: MediaPipeline, scope: String) async {
        let disk = ThumbnailStore(scope: scope)
        for asset in assets { await disk.store(png, assetID: asset.id, revision: asset.cacheRevision) }
        for asset in assets {
            for size in [8, 6] {
                let image = await pipeline.storedThumbnail(for: asset, pixelSize: size)
                XCTAssertNotNil(image, asset.id)
            }
        }
    }

    private func isCached(_ asset: Asset, in pipeline: MediaPipeline) -> Bool {
        pipeline.hasStoredThumbnail(asset) || pipeline.cachedImage(for: asset, pixelSize: 8) != nil
            || pipeline.cachedImage(for: asset, pixelSize: 6) != nil || pipeline.latestImage(assetID: asset.id, size: .thumbnail) != nil
    }

    private func isFullyCached(_ asset: Asset, in pipeline: MediaPipeline) -> Bool {
        pipeline.hasStoredThumbnail(asset) && pipeline.cachedImage(for: asset, pixelSize: 8) != nil
            && pipeline.cachedImage(for: asset, pixelSize: 6) != nil && pipeline.latestImage(assetID: asset.id, size: .thumbnail) != nil
    }

    /// Locking one photo removes its thumbnail file, every decoded size of it and its previews in
    /// the URL cache. Every other photo keeps all of them: thumbnail usage drops by about one file.
    func testLockingOnePhotoPurgesOnlyThatPhotosMedia() async throws {
        let (api, pipeline) = try makePipeline()
        let locked = Asset(id: "locked", mediaRevision: "r1"), kept = Asset(id: "kept", mediaRevision: "r1")
        await cache([locked, kept], in: pipeline, scope: api.cacheScope)
        for asset in [locked, kept] { try await pipeline.cacheForTesting(png, asset: asset, size: .preview) }
        let held = try await pipeline.urlCacheHolds(kept, size: .preview)
        XCTAssertTrue(held, "The preview is in the URL cache.")
        let before = await pipeline.cacheUsage().diskBytes

        await pipeline.forget(assetIDs: ["locked"], revoked: true)

        XCTAssertFalse(isCached(locked, in: pipeline), "Nothing of the locked photo stays, on disk or in memory.")
        let lockedPreview = try await pipeline.urlCacheHolds(locked, size: .preview)
        XCTAssertFalse(lockedPreview, "Its preview leaves the URL cache.")
        XCTAssertTrue(isFullyCached(kept, in: pipeline), "Every other photo stays, at every size.")
        let keptPreview = try await pipeline.urlCacheHolds(kept, size: .preview)
        XCTAssertTrue(keptPreview, "The URL cache is not cleared for one photo.")
        let after = await pipeline.cacheUsage().diskBytes
        XCTAssertLessThanOrEqual(before - after, 8 * 1024, "About one file goes, not the store.")
        XCTAssertGreaterThan(after, 0)
    }

    /// The URL cache may hold previews from an earlier launch, which can't be found by photo: the
    /// first revocation then clears the URL cache, never the thumbnails, and later ones are precise.
    func testARevocationClearsTheURLCacheOnlyWhenItCannotFindTheEntries() async throws {
        let api = try APIClient(baseURL: XCTUnwrap(URL(string: "https://media-change.example")), accessToken: "media-session",
                                userID: "media-" + UUID().uuidString)
        let pipeline = MediaPipeline(client: api, earlierURLCacheEntries: true)
        addTeardownBlock { await pipeline.removeAll(); await api.shutdown() }
        let assets = ["first", "second", "kept"].map { Asset(id: $0, mediaRevision: "r1") }
        await cache(assets, in: pipeline, scope: api.cacheScope)
        for asset in assets { try await pipeline.cacheForTesting(png, asset: asset, size: .preview) }

        await pipeline.forget(assetIDs: ["first"], revoked: true)
        let clearedOnce = try await pipeline.urlCacheHolds(assets[2], size: .preview)
        XCTAssertFalse(clearedOnce, "Entries it can't find may be the photo's, so the URL cache goes.")
        XCTAssertTrue(isFullyCached(assets[2], in: pipeline), "Thumbnails stay.")

        try await pipeline.cacheForTesting(png, asset: assets[2], size: .preview)
        await pipeline.forget(assetIDs: ["second"], revoked: true)
        let kept = try await pipeline.urlCacheHolds(assets[2], size: .preview)
        XCTAssertTrue(kept, "Now every entry can be found, so only the photo's go.")
    }

    /// Locking, deleting for good from Trash or Duplicates forget only the photos named.
    func testLockingOrTrashingFromTheAppForgetsOnlyThoseIDs() async throws {
        let (api, pipeline) = try makePipeline()
        let assets = ["locked-1", "locked-2", "deleted", "kept-1", "kept-2"].map { Asset(id: $0) }
        await cache(assets, in: pipeline, scope: api.cacheScope)

        await pipeline.forget(assetIDs: ["locked-1", "locked-2"], revoked: true)
        await pipeline.forget(assetIDs: ["deleted"])

        for asset in assets.prefix(3) { XCTAssertFalse(isCached(asset, in: pipeline), asset.id) }
        for asset in assets.suffix(2) { XCTAssertTrue(isFullyCached(asset, in: pipeline), asset.id) }
    }

    /// A photo edited elsewhere comes back with a new media revision: its old thumbnail leaves
    /// memory and disk so the new one is shown, and no other photo is touched.
    func testAnEditRefreshesOnlyThatPhotosThumbnail() async throws {
        let (api, pipeline) = try makePipeline()
        let edited = Asset(id: "edited", mediaRevision: "r1"), other = Asset(id: "other", mediaRevision: "r1")
        await cache([edited, other], in: pipeline, scope: api.cacheScope)
        let account = AccountID(server: api.baseURL, userID: "media")
        var change = LibraryChange(account: account, authorization: AuthorizationEpoch(account: account, value: 1), indexRevision: 2, origin: .sync)
        change.mediaRevisions = ["edited": "r2"]

        await pipeline.apply(change)

        XCTAssertFalse(isCached(edited, in: pipeline), "The old revision is neither shown nor kept.")
        XCTAssertTrue(isFullyCached(other, in: pipeline), "Other photos keep everything.")
    }

    /// A thumbnail download that ends after its photo was locked is neither stored nor remembered,
    /// and a download that starts later is stored again.
    func testThumbnailFinishingAfterRevocationIsNotStored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaChangeTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ThumbnailStore(scope: "scope", root: root)
        let token = store.fence.token()
        store.fence.forget(["photo"])
        await store.store(png, assetID: "photo", revision: "r1", token: token)
        XCTAssertFalse(store.contains(assetID: "photo", revision: "r1"), "A download from before the lock is not written.")
        await store.store(png, assetID: "photo", revision: "r1", token: store.fence.token())
        XCTAssertTrue(store.contains(assetID: "photo", revision: "r1"), "One begun after it is, as for a photo unlocked again.")

        let server = makeStubServer()
        let gate = StubServer.Gate()
        server.route("GET", "assets/locked/thumbnail", StubServer.Response(status: 200, headers: ["Content-Type": "image/png"], body: png).waiting(for: gate))
        let (_, pipeline) = try makePipeline(server: server)
        let locked = Asset(id: "locked", mediaRevision: "r1")
        let download = Task { try await pipeline.image(for: locked, pixelSize: 8) }
        let deadline = Date().addingTimeInterval(5)
        while server.requests("GET", "assets/locked/thumbnail").isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(server.requests("GET", "assets/locked/thumbnail").count, 1, "The download started.")

        await pipeline.forget(assetIDs: ["locked"], revoked: true)
        gate.open()
        _ = try? await download.value
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(pipeline.hasStoredThumbnail(locked), "The download is not stored.")
        XCTAssertNil(pipeline.cachedImage(for: locked, pixelSize: 8), "Nor remembered.")
    }

    /// Work asked for before a photo was locked, still waiting for its request when the lock
    /// lands, neither downloads nor keeps anything: not a grid thumbnail, not the warmer's, not a
    /// preview. A request made after the lock is served as before.
    func testMediaAskedForBeforeALockIsNotKept() async throws {
        let server = makeStubServer()
        server.route("GET", "assets/locked/thumbnail", StubServer.Response(status: 200, headers: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"], body: png))
        let (_, pipeline) = try makePipeline(server: server)
        let locked = Asset(id: "locked", mediaRevision: "r1")
        let token = pipeline.mediaToken()

        await pipeline.forget(assetIDs: ["locked"], revoked: true)
        _ = try? await pipeline.image(for: locked, pixelSize: 8, token: token)
        try? await pipeline.storeThumbnail(locked, token: token)
        _ = try? await pipeline.image(for: locked, size: .preview, pixelSize: 8, token: token)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(server.requests("GET", "assets/locked/thumbnail").isEmpty, "Nothing is downloaded.")
        XCTAssertFalse(pipeline.hasStoredThumbnail(locked), "No thumbnail is stored.")
        XCTAssertNil(pipeline.cachedImage(for: locked, pixelSize: 8), "None is remembered.")
        XCTAssertNil(pipeline.latestImage(assetID: locked.id, size: .preview), "No preview is remembered.")
        let held = try await pipeline.urlCacheHolds(locked, size: .preview)
        XCTAssertFalse(held, "No preview is in the URL cache.")

        try await pipeline.storeThumbnail(locked, token: pipeline.mediaToken())
        // The file is written just after the bytes are handed back.
        let stored = Date().addingTimeInterval(5)
        while !pipeline.hasStoredThumbnail(locked) && Date() < stored { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(pipeline.hasStoredThumbnail(locked), "A request made after the lock is stored, as for a photo unlocked again.")
    }

    /// A preview whose download was under way when its photo was deleted is not remembered and
    /// does not stay in the URL cache.
    func testPreviewFinishingAfterDeletionIsNotKept() async throws {
        let server = makeStubServer()
        let gate = StubServer.Gate()
        server.route("GET", "assets/gone/thumbnail", StubServer.Response(status: 200, headers: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"], body: png).waiting(for: gate))
        let (_, pipeline) = try makePipeline(server: server)
        let gone = Asset(id: "gone", mediaRevision: "r1")
        let download = Task { try await pipeline.image(for: gone, size: .preview, pixelSize: 8) }
        let deadline = Date().addingTimeInterval(5)
        while server.requests("GET", "assets/gone/thumbnail").isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(server.requests("GET", "assets/gone/thumbnail").count, 1, "The download started.")

        // A deletion leaves previews in flight running; only the fence keeps them out.
        await pipeline.forget(assetIDs: ["gone"])
        gate.open()
        let result = try? await download.value

        XCTAssertNil(result, "The finished preview is refused.")
        XCTAssertNil(pipeline.latestImage(assetID: gone.id, size: .preview), "It is not remembered.")
        let held = try await pipeline.urlCacheHolds(gone, size: .preview)
        XCTAssertFalse(held, "Nor left in the URL cache.")
    }

    /// More than 2,000 photos (2,100 here) deleted on the server in one pass all lose their thumbnails, and
    /// the photo left keeps its own.
    func testMoreThan2000DeletionsAreAllForgotten() async throws {
        let harness = try makeSyncHarness()
        // Spread over the store's folders, as server IDs are.
        let ids = (0..<2_100).map { String(format: "%02x-gone-%d", $0 % 256, $0) }
        try await harness.primeIndex(ids.map { SyncEvents.asset($0) } + [SyncEvents.asset("kept")])
        let disk = ThumbnailStore(scope: harness.api.cacheScope)
        for id in ids + ["kept"] { await disk.store(png, assetID: id, revision: "r1") }
        harness.server.route("POST", "sync/stream", SyncEvents.stream(ids.map {
            SyncEvents.event("AssetDeleteV1", #"{"assetId":"\#($0)"}"#, ack: "AssetDeleteV1|\($0)")
        } + [SyncEvents.complete()]))

        let change = try await harness.engine.refresh()

        XCTAssertEqual(change.removed.count, ids.count)
        let left = ids.filter { disk.contains(assetID: $0, revision: "r1") }
        XCTAssertEqual(left, [], "Every deleted photo's thumbnail is gone.")
        XCTAssertTrue(disk.contains(assetID: "kept", revision: "r1"), "The photo left keeps its thumbnail.")
        let queued = try await harness.entities.pendingMediaPurges()
        XCTAssertEqual(queued, [], "Nothing waits to be forgotten.")
    }

    /// When the server resets the library, the grid thumbnails of photos that come back at the same
    /// revision stay, so the offline library needs no downloads; a photo that came back at a new
    /// revision, or not at all, loses its file once the index is complete again.
    func testSyncResetKeepsRevisionValidThumbnails() async throws {
        let harness = try makeSyncHarness()
        try await harness.primeIndex([SyncEvents.asset("same"), SyncEvents.asset("edited"), SyncEvents.asset("gone")])
        let disk = ThumbnailStore(scope: harness.api.cacheScope)
        for id in ["same", "edited", "gone"] { await disk.store(png, assetID: id, revision: "r1") }
        harness.server.route("POST", "sync/stream",
                             SyncEvents.stream([SyncEvents.event("SyncResetV1", "{}", ack: "SyncResetV1|reset")]),
                             SyncEvents.stream([SyncEvents.asset("same"), SyncEvents.asset("edited", revision: "r2"), SyncEvents.complete()]))

        let change = try await harness.engine.refresh()

        XCTAssertTrue(change.reset, "The feeds reload.")
        XCTAssertTrue(disk.contains(assetID: "same", revision: "r1"), "A photo back at its revision keeps its thumbnail.")
        XCTAssertFalse(disk.contains(assetID: "edited", revision: "r1"), "A photo back at another revision loses the old one.")
        XCTAssertFalse(disk.contains(assetID: "gone", revision: "r1"), "A photo that did not come back leaves nothing.")
        let pending = try await harness.entities.accessInvalidationPending()
        XCTAssertFalse(pending, "The reset is reconciled.")
    }

    /// A subscriber that falls behind gets the changes it missed folded into one, never dropped.
    func testASlowSubscriberSeesEveryChange() async throws {
        let (api, pipeline) = try makePipeline()
        let hub = LibraryChangeHub(pipeline: pipeline, scope: api.cacheScope)
        let stream = await hub.subscribe()
        let account = AccountID(server: api.baseURL, userID: "media")
        for id in ["a", "b", "c"] {
            var change = LibraryChange(account: account, authorization: AuthorizationEpoch(account: account, value: 1), indexRevision: 1, origin: .sync)
            change.removed = [id]
            await hub.publish(change, accessChanged: false)
        }
        await hub.close()
        var received: [Set<String>] = []
        for await change in stream { received.append(change.removed) }
        XCTAssertEqual(received, [["a", "b", "c"]])
    }
}

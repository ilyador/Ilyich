import IlyichPlatform
import UIKit
import XCTest
@testable import Ilyich

final class MediaPipelineTests: XCTestCase {
    /// Clear browsing cache (G2) empties the URL cache and every decoded image, and keeps the grid
    /// thumbnails on disk with the work that keeps them: the grid draws them from the disk again
    /// without a download, a thumbnail coverage is downloading is still stored, and coverage's
    /// position stays good, so nothing kept offline is downloaded again.
    func testClearingTheBrowsingCacheKeepsTheThumbnailsOnDisk() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let server = makeStubServer()
        let gate = StubServer.Gate()
        server.route("GET", "assets/coming/thumbnail", StubServer.Response(status: 200, headers: ["Content-Type": "image/png"], body: png).waiting(for: gate))
        let api = try APIClient(baseURL: server.baseURL, accessToken: "media-session", userID: "media-" + UUID().uuidString,
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        let pipeline = MediaPipeline(client: api, protocolClasses: [StubURLProtocol.self], earlierURLCacheEntries: false)
        addTeardownBlock { gate.open(); await pipeline.removeAll(); await api.shutdown() }
        let kept = Asset(id: "kept", mediaRevision: "r1"), coming = Asset(id: "coming", mediaRevision: "r1")
        await pipeline.thumbnails.store(png, assetID: kept.id, revision: kept.cacheRevision)
        let decoded = await pipeline.storedThumbnail(for: kept, pixelSize: 8)
        XCTAssertNotNil(decoded)
        try await pipeline.cacheForTesting(png, asset: kept, size: .preview)
        let token = pipeline.mediaToken()
        let position = CoverageState(cursor: "page", mark: 7, policyHash: "policy", total: 2, stored: 1)
        let saved = await pipeline.thumbnails.saveCoverageState(position, token: token)
        XCTAssertTrue(saved)
        let usage = await pipeline.cacheUsage().thumbnailBytes
        // Coverage is downloading another photo's thumbnail.
        let coverage = Task { try await pipeline.scheduler.store(assetID: coming.id, revision: coming.cacheRevision, band: .coverage, token: token) }
        let deadline = Date().addingTimeInterval(5)
        while server.requests("GET", "assets/coming/thumbnail").isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(server.requests("GET", "assets/coming/thumbnail").count, 1, "The download started.")

        await pipeline.clearBrowsingCache()

        XCTAssertNil(pipeline.cachedImage(for: kept, pixelSize: 8), "Decoded thumbnails go.")
        XCTAssertNil(pipeline.latestImage(assetID: kept.id, size: .thumbnail))
        let held = try await pipeline.urlCacheHolds(kept, size: .preview)
        XCTAssertFalse(held, "So does the URL cache.")
        XCTAssertTrue(pipeline.hasStoredThumbnail(kept), "The thumbnail stays on disk.")
        let after = await pipeline.cacheUsage().thumbnailBytes
        XCTAssertEqual(after, usage)
        let state = await pipeline.thumbnails.coverageState()
        XCTAssertEqual(state, position, "Coverage's position and counts stay.")
        XCTAssertTrue(pipeline.thumbnails.fence.admits(since: token), "And its next save is taken.")
        gate.open()
        try await coverage.value
        XCTAssertTrue(pipeline.hasStoredThumbnail(coming), "The thumbnail coverage was downloading is stored.")
        let redrawn = await pipeline.storedThumbnail(for: kept, pixelSize: 8)
        XCTAssertNotNil(redrawn, "The grid draws the kept thumbnail from the disk.")
        XCTAssertTrue(server.requests("GET", "assets/kept/thumbnail").isEmpty, "Nothing kept offline is downloaded.")
    }

    /// Forgetting the photos that left the library keeps every other photo's thumbnail in memory
    /// and on disk, so scrolling after a sync needs no downloads.
    func testForgettingRemovedPhotosKeepsTheRestOfTheLibrary() async throws {
        let api = try APIClient(baseURL: XCTUnwrap(URL(string: "https://media.example")), accessToken: "media-session",
                                userID: "media-" + UUID().uuidString)
        let pipeline = MediaPipeline(client: api)
        addTeardownBlock { await pipeline.removeAll() }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let kept = Asset(id: "kept"), gone = Asset(id: "gone")
        let disk = ThumbnailDiskStore.shared(scope: api.cacheScope)
        for asset in [kept, gone] { await disk.store(png, assetID: asset.id, revision: asset.cacheRevision) }
        for asset in [kept, gone] {
            let image = await pipeline.storedThumbnail(for: asset, pixelSize: 8)
            XCTAssertNotNil(image, asset.id)
        }

        await pipeline.forget(assetIDs: ["gone"])

        XCTAssertFalse(pipeline.hasStoredThumbnail(gone), "The removed photo leaves the disk.")
        XCTAssertNil(pipeline.latestImage(assetID: "gone", size: .thumbnail))
        XCTAssertTrue(pipeline.hasStoredThumbnail(kept), "Every other photo stays on disk.")
        XCTAssertNotNil(pipeline.cachedImage(for: kept, pixelSize: 8), "And in memory.")
        XCTAssertNotNil(pipeline.latestImage(assetID: "kept", size: .thumbnail))
    }

    /// Photos about to scroll in reach memory from disk, so they draw in their first frame.
    func testPrefetchedThumbnailsReachMemory() async throws {
        let api = try APIClient(baseURL: XCTUnwrap(URL(string: "https://media.example")), accessToken: "media-session",
                                userID: "media-" + UUID().uuidString)
        let pipeline = MediaPipeline(client: api)
        addTeardownBlock { await pipeline.removeAll() }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let asset = Asset(id: "ahead")
        await ThumbnailDiskStore.shared(scope: api.cacheScope).store(png, assetID: asset.id, revision: asset.cacheRevision)

        let item = ViewportDemand.Item(request: ThumbnailRequest(key: .server(assetID: asset.id, revision: asset.cacheRevision),
                                                                 thumbhash: nil, shortSide: 8), band: .ahead, rank: 0)
        pipeline.scheduler.submit(ViewportDemand(generation: pipeline.mediaToken(), items: [item], motion: .scrubbing), from: UUID())

        let deadline = Date().addingTimeInterval(5)
        while pipeline.cachedImage(for: asset, pixelSize: 8) == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(pipeline.cachedImage(for: asset, pixelSize: 8))
    }
}

import UIKit
import XCTest
@testable import Ilyich

final class MediaPipelineTests: XCTestCase {
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
        let disk = ThumbnailStore(scope: api.cacheScope)
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
        await ThumbnailStore(scope: api.cacheScope).store(png, assetID: asset.id, revision: asset.cacheRevision)

        pipeline.prefetchThumbnails([asset], pixelSize: 8)

        let deadline = Date().addingTimeInterval(5)
        while pipeline.cachedImage(for: asset, pixelSize: 8) == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(pipeline.cachedImage(for: asset, pixelSize: 8))
    }
}

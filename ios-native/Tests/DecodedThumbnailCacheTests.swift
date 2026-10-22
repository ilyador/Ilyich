import UIKit
import XCTest
@testable import Ilyich

final class DecodedThumbnailCacheTests: XCTestCase {
    private static func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private static func image(_ side: Int) throws -> PreparedImage {
        try MediaPipeline.downsampleThumbnail(png(width: side, height: side), shortSide: side)
    }

    /// A thumbnail fills its cell: its short side reaches the cell's, so aspect-fill crops instead
    /// of stretching, and it is never decoded larger than the file.
    func testAspectFillDecodeCoversTheCell() throws {
        let landscape = Self.png(width: 400, height: 200), portrait = Self.png(width: 150, height: 300)
        let filled = try MediaPipeline.downsampleThumbnail(landscape, shortSide: 120)
        XCTAssertGreaterThanOrEqual(filled.cgImage.height, 120, "The short side covers the cell.")
        XCTAssertGreaterThanOrEqual(filled.cgImage.width, 240)
        XCTAssertLessThan(filled.cgImage.width, 400, "Smaller than the file when the cell is.")
        let tall = try MediaPipeline.downsampleThumbnail(portrait, shortSide: 100)
        XCTAssertGreaterThanOrEqual(tall.cgImage.width, 100)
        XCTAssertGreaterThanOrEqual(tall.cgImage.height, 200)
        let native = try MediaPipeline.downsampleThumbnail(landscape, shortSide: 390)
        XCTAssertEqual(native.cgImage.width, 400, "Never upscaled.")
        XCTAssertEqual(native.cgImage.height, 200)
        let fitted = try MediaPipeline.downsample(landscape, pixelSize: 120)
        XCTAssertLessThan(fitted.cgImage.height, 120, "The fit decode previews use would leave the cell short.")
    }

    /// One image serves every cell up to its size; a smaller copy is never kept beside it.
    func testALargerImageServesASmallerCell() throws {
        let cache = DecodedThumbnailCache(budget: 64 * 1024 * 1024)
        cache.insert(try MediaPipeline.downsampleThumbnail(Self.png(width: 400, height: 300), shortSide: 200), assetID: "a", revision: "1", shortSide: 200)
        XCTAssertNotNil(cache.image(assetID: "a", revision: "1", shortSide: 120), "A denser grid reuses it.")
        XCTAssertNil(cache.image(assetID: "a", revision: "1", shortSide: 260), "A larger cell needs a sharper decode.")
        XCTAssertNil(cache.image(assetID: "a", revision: "2", shortSide: 120), "Another revision is another thumbnail.")
        cache.insert(try MediaPipeline.downsampleThumbnail(Self.png(width: 400, height: 300), shortSide: 120), assetID: "a", revision: "1", shortSide: 120)
        XCTAssertEqual(cache.count, 1, "The smaller decode is not kept.")
        cache.insert(try MediaPipeline.downsampleThumbnail(Self.png(width: 400, height: 300), shortSide: 600), assetID: "a", revision: "1", shortSide: 600)
        XCTAssertEqual(cache.count, 1, "The file's own size replaces it.")
        XCTAssertNotNil(cache.image(assetID: "a", revision: "1", shortSide: 2_000), "Decoded at the file's size, it serves every cell.")
        XCTAssertEqual(cache.largest(assetID: "a", revision: nil)?.cgImage.width, 400)
    }

    /// Forgetting a photo removes only its images. A memory warning empties everything but the
    /// photos on screen, and the budget evicts the least recently used around them.
    func testForgetKeepsUnrelatedImagesAndMemoryWarningKeepsPins() throws {
        let image = try Self.image(32)
        let cache = DecodedThumbnailCache(budget: image.byteCost * 3)
        for id in ["shown", "forgotten", "other"] { cache.insert(image, assetID: id, revision: "1", shortSide: 32) }
        cache.pin("shown")

        cache.forget(["forgotten"])
        XCTAssertNil(cache.image(assetID: "forgotten", revision: "1", shortSide: 32))
        XCTAssertNotNil(cache.image(assetID: "other", revision: "1", shortSide: 32), "Unrelated photos stay.")
        XCTAssertNotNil(cache.image(assetID: "shown", revision: "1", shortSide: 32))

        for id in ["b", "c", "d"] { cache.insert(image, assetID: id, revision: "1", shortSide: 32) }
        XCTAssertNotNil(cache.image(assetID: "shown", revision: "1", shortSide: 32), "The budget evicts around pins.")
        XCTAssertNil(cache.image(assetID: "other", revision: "1", shortSide: 32), "The least recently used goes first.")
        XCTAssertLessThanOrEqual(cache.cost, image.byteCost * 3)

        cache.trimUnpinned()
        XCTAssertNotNil(cache.image(assetID: "shown", revision: "1", shortSide: 32), "A memory warning keeps the photos on screen.")
        XCTAssertEqual(cache.count, 1)
        cache.unpin("shown")
        cache.trimUnpinned()
        XCTAssertEqual(cache.count, 0)
    }

    /// An image the fence refuses, because its photo was forgotten after the decode began, is not kept.
    func testAFencedImageIsNotKept() throws {
        let cache = DecodedThumbnailCache()
        let fence = MediaFence()
        let token = fence.token()
        fence.forget(["locked"])
        cache.insert(try Self.image(16), assetID: "locked", revision: "1", shortSide: 16) { fence.admits("locked", since: token) }
        XCTAssertNil(cache.largest(assetID: "locked", revision: nil))
    }

    /// The pipeline's grid thumbnails come from the decoded cache, and a pinned one survives a memory warning.
    func testPipelineMemoryWarningKeepsPinnedThumbnails() async throws {
        let api = try APIClient(baseURL: XCTUnwrap(URL(string: "https://decoded.example")), accessToken: "media-session",
                                userID: "decoded-" + UUID().uuidString)
        let pipeline = MediaPipeline(client: api)
        addTeardownBlock { await pipeline.removeAll() }
        let shown = Asset(id: "shown"), hidden = Asset(id: "hidden")
        let disk = ThumbnailDiskStore.shared(scope: api.cacheScope)
        for asset in [shown, hidden] {
            await disk.store(Self.png(width: 16, height: 16), assetID: asset.id, revision: asset.cacheRevision)
            let image = await pipeline.storedThumbnail(for: asset, pixelSize: 16)
            XCTAssertNotNil(image)
        }
        pipeline.pinThumbnail(shown.id)
        await pipeline.trimMemory()
        XCTAssertNotNil(pipeline.cachedImage(for: shown, pixelSize: 16))
        XCTAssertNotNil(pipeline.latestImage(assetID: shown.id, size: .thumbnail, revision: shown.cacheRevision), "The viewer opens on it.")
        XCTAssertNil(pipeline.cachedImage(for: hidden, pixelSize: 16))
        pipeline.unpinThumbnail(shown.id)
    }
}

import Synchronization
import UIKit
import XCTest
@testable import Ilyich

final class ThumbnailDecoderTests: XCTestCase {
    private var root: URL!
    private let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
        UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbnailDecoderTests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// Records the order photos decode in, and holds the first decode until the test lets it go,
    /// so a queue can be arranged behind it.
    private final class Recorder: Sendable {
        let order = Mutex<[String]>([])
        let delivered = Mutex<[String]>([])
        let gate = DispatchSemaphore(value: 0)
        func willDecode(_ identity: MediaCacheIdentity) {
            let first = order.withLock { order in order.append(String(identity.resource.dropFirst(7))); return order.count == 1 }
            if first { gate.wait() }
        }
        func decoded(_ identity: MediaCacheIdentity) { delivered.withLock { $0.append(String(identity.resource.dropFirst(7))) } }
        var decodedOrder: [String] { order.withLock { $0 } }
        var deliveredPhotos: [String] { delivered.withLock { $0 } }
    }

    private func makeDecoder(storing ids: [String]) async -> (ThumbnailDecoder, Recorder) {
        let store = ThumbnailDiskStore.shared(scope: "scope", root: root)
        for id in ids { await store.store(png, assetID: id, revision: "1") }
        let recorder = Recorder()
        let decoder = ThumbnailDecoder(store: store, lanes: 1, decoded: { _, request in recorder.decoded(request.identity) },
                                       willDecode: { recorder.willDecode($0) })
        return (decoder, recorder)
    }

    private static func request(_ id: String) -> ThumbnailDecoder.Request {
        .init(identity: MediaCacheIdentity(scope: "scope", asset: Asset(id: id), size: .thumbnail, pixelSize: 8), assetID: id, revision: "1")
    }

    private func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// While a scrub passes photos faster than they decode, the newest go first, and a photo that
    /// scrolled away before its turn is never decoded.
    func testTheNewestRequestGoesFirstAndAnAbandonedOneNever() async throws {
        let (decoder, recorder) = await makeDecoder(storing: ["a", "b", "c", "d"])
        let a = Task { await decoder.image(ThumbnailDecoderTests.request("a")) }
        try await until("The first decode did not start.") { recorder.decodedOrder == ["a"] }
        let b = Task { await decoder.image(ThumbnailDecoderTests.request("b")) }
        try await until("b was not queued.") { decoder.pendingCount == 1 }
        let c = Task { await decoder.image(ThumbnailDecoderTests.request("c")) }
        try await until("c was not queued.") { decoder.pendingCount == 2 }
        let d = Task { await decoder.image(ThumbnailDecoderTests.request("d")) }
        try await until("d was not queued.") { decoder.pendingCount == 3 }
        c.cancel()
        try await until("The abandoned request stayed queued.") { decoder.pendingCount == 2 }
        recorder.gate.signal()

        let (imageA, imageB, imageC, imageD) = (await a.value, await b.value, await c.value, await d.value)
        XCTAssertNotNil(imageA); XCTAssertNotNil(imageB); XCTAssertNotNil(imageD)
        XCTAssertNil(imageC, "The abandoned request gets nothing.")
        XCTAssertEqual(recorder.decodedOrder, ["a", "d", "b"], "Newest first, and the abandoned photo never decodes.")
    }

    /// Photos about to scroll in decode only after the ones on screen, still reach memory with
    /// nobody waiting for them, and are skipped once they won't scroll in after all.
    func testPrefetchedPhotosWaitForTheOnesOnScreen() async throws {
        let (decoder, recorder) = await makeDecoder(storing: ["shown", "ahead", "skipped", "next"])
        let shown = Task { await decoder.image(ThumbnailDecoderTests.request("shown")) }
        try await until("The first decode did not start.") { recorder.decodedOrder == ["shown"] }
        decoder.prefetch([Self.request("ahead"), Self.request("skipped")])
        decoder.cancelPrefetch([Self.request("skipped").identity])
        let next = Task { await decoder.image(ThumbnailDecoderTests.request("next")) }
        try await until("The visible request was not queued.") { decoder.pendingCount == 2 }
        recorder.gate.signal()

        _ = await shown.value; _ = await next.value
        try await until("The prefetched photo did not reach memory.") { recorder.deliveredPhotos.contains("ahead") }
        XCTAssertEqual(recorder.decodedOrder, ["shown", "next", "ahead"])
    }

    /// Clearing the caches drops every queued decode, and one already running never reaches memory.
    func testResetDropsQueuedDecodes() async throws {
        let (decoder, recorder) = await makeDecoder(storing: ["running", "queued"])
        let running = Task { await decoder.image(ThumbnailDecoderTests.request("running")) }
        try await until("The first decode did not start.") { recorder.decodedOrder == ["running"] }
        let queued = Task { await decoder.image(ThumbnailDecoderTests.request("queued")) }
        try await until("The second request was not queued.") { decoder.pendingCount == 1 }
        decoder.reset()
        let (dropped, interrupted) = (await queued.value, await running.value)
        recorder.gate.signal()

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(dropped); XCTAssertNil(interrupted)
        XCTAssertEqual(recorder.decodedOrder, ["running"], "The queued photo never decodes.")
        XCTAssertEqual(recorder.deliveredPhotos, [], "The running decode never reaches memory.")
    }

    /// A photo missing from the store comes back empty, so the cell can download it.
    func testAPhotoMissingFromTheStoreReturnsNothing() async {
        let store = ThumbnailDiskStore.shared(scope: "scope", root: root)
        let decoder = ThumbnailDecoder(store: store, decoded: { _, _ in })
        let image = await decoder.image(ThumbnailDecoderTests.request("missing"))
        XCTAssertNil(image)
    }
}

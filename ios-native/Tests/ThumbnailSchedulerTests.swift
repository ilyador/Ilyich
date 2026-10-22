import Synchronization
import UIKit
import XCTest
@testable import Ilyich

/// The one thumbnail scheduler: bands share download slots so the screen always gets one, photos
/// that scrolled away never decode, downloaded bytes reach the screen before the disk, failing
/// photos wait longer each time, and the newest photo on screen decodes first while scrubbing.
final class ThumbnailSchedulerTests: XCTestCase {
    private static let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
        UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    /// A disk in memory whose writes finish only when the test says so, and whose reads the test
    /// can count.
    private final class FakeStore: ThumbnailStoring {
        let fence = MediaFence()
        let files = Mutex<[String: Data]>([:])
        let pendingWrites = Mutex<[String: Data]>([:])

        init(storing ids: [String] = []) {
            files.withLock { files in for id in ids { files[id + "|1"] = ThumbnailSchedulerTests.png } }
        }
        func contains(assetID: String, revision: String) -> Bool {
            files.withLock { $0[assetID + "|" + revision] != nil }
        }
        func data(assetID: String, revision: String) -> Data? {
            files.withLock { $0[assetID + "|" + revision] }
        }
        func enqueueWrite(_ data: Data, assetID: String, revision: String, token: UInt64) {
            guard fence.admits(assetID, since: token) else { return }
            pendingWrites.withLock { $0[assetID + "|" + revision] = data }
        }
    }

    /// Records the photos that decode, in order, and holds the first decode until released.
    private final class Recorder: Sendable {
        let order = Mutex<[String]>([])
        let gate = DispatchSemaphore(value: 0)
        let holdsFirst: Bool
        init(holdsFirst: Bool = true) { self.holdsFirst = holdsFirst }
        func willDecode(_ id: String) {
            let first = order.withLock { order in order.append(id); return order.count == 1 }
            if first && holdsFirst { gate.wait() }
        }
        var decoded: [String] { order.withLock { $0 } }
    }

    /// Downloads that wait until the test releases them, counted by photo.
    private final class FakeServer: Sendable {
        let calls = Mutex<[String]>([])
        let released = Atomic<Bool>(false)
        let fails: Bool
        init(holds: Bool = true, fails: Bool = false) {
            released.store(!holds, ordering: .relaxed)
            self.fails = fails
        }
        func load(_ id: String) async throws -> Data {
            calls.withLock { $0.append(id) }
            while !released.load(ordering: .relaxed) {
                try await Task.sleep(for: .milliseconds(5))
            }
            if fails { throw URLError(.badServerResponse) }
            return ThumbnailSchedulerTests.png
        }
        var requested: [String] { calls.withLock { $0 } }
    }

    private final class Clock: Sendable {
        let now = Mutex<TimeInterval>(1_000)
        func advance(_ seconds: TimeInterval) { now.withLock { $0 += seconds } }
    }

    private final class Deliveries: Sendable {
        let received = Mutex<[ThumbnailDelivery]>([])
        var all: [ThumbnailDelivery] { received.withLock { $0 } }
    }

    private func listen(_ scheduler: ThumbnailScheduler) -> Deliveries {
        let deliveries = Deliveries()
        _ = scheduler.addListener { batch in deliveries.received.withLock { $0 += batch } }
        return deliveries
    }

    private static func demand(_ items: [(String, DemandBand)], motion: Motion = .idle(since: 0), token: UInt64 = 0) -> ViewportDemand {
        ViewportDemand(generation: token, items: items.enumerated().map { rank, item in
            ViewportDemand.Item(request: ThumbnailRequest(key: .server(assetID: item.0, revision: "1"), thumbhash: nil, shortSide: 8),
                                band: item.1, rank: rank)
        }, motion: motion)
    }

    private func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Downloads

    func testVisibleDemandGetsASlotWhileCoverageIsFetching() async throws {
        let server = FakeServer()
        let store = FakeStore()
        let scheduler = ThumbnailScheduler(store: store, memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { id, _, _ in try await server.load(id) }))
        let coverage = ["c1", "c2", "c3", "c4"].map { id in
            Task { try await scheduler.store(assetID: id, revision: "1", token: store.fence.token()) }
        }
        try await until("Coverage did not start.") { server.requested.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(server.requested.count, 2, "Coverage keeps to its ceiling of two downloads.")

        let source = UUID()
        scheduler.submit(Self.demand([("shown", .visible)]), from: source)
        try await until("The photo on screen got no download slot.") { server.requested.contains("shown") }
        XCTAssertEqual(server.requested.count, 3, "The queued coverage still waits.")

        server.released.store(true, ordering: .relaxed)
        for task in coverage { try await task.value }
        XCTAssertEqual(store.pendingWrites.withLock { $0.count }, 5, "Every download reaches the disk.")
        scheduler.withdraw(source)
    }

    func testFetchedBytesAreDeliveredBeforeTheDiskWriteFinishes() async throws {
        let store = FakeStore()
        let memory = DecodedThumbnailCache()
        let server = FakeServer(holds: false)
        let scheduler = ThumbnailScheduler(store: store, memory: memory,
                                           fetcher: ThumbnailFetcher(load: { id, _, _ in try await server.load(id) }))
        let deliveries = listen(scheduler)
        let source = UUID()
        scheduler.submit(Self.demand([("new", .visible)]), from: source)

        try await until("The download never reached the screen.") { deliveries.all.contains { $0.assetID == "new" } }
        let delivery = try XCTUnwrap(deliveries.all.first)
        XCTAssertNotNil(delivery.image)
        XCTAssertTrue(delivery.fromNetwork)
        XCTAssertNotNil(memory.image(assetID: "new", revision: "1", shortSide: 8), "It is in memory.")
        XCTAssertNotNil(store.pendingWrites.withLock { $0["new|1"] }, "Its write was handed to the store…")
        XCTAssertNil(store.data(assetID: "new", revision: "1"), "…which has not finished it.")
        scheduler.withdraw(source)
    }

    func testFailingThumbnailBacksOff() async throws {
        let clock = Clock()
        let server = FakeServer(holds: false, fails: true)
        let fetcher = ThumbnailFetcher(load: { id, _, _ in try await server.load(id) }, baseDelay: 2,
                                       now: { clock.now.withLock { $0 } })
        let scheduler = ThumbnailScheduler(store: FakeStore(), memory: DecodedThumbnailCache(), fetcher: fetcher)
        let deliveries = listen(scheduler)
        let source = UUID()
        scheduler.submit(Self.demand([("broken", .visible)]), from: source)
        try await until("The failure was not shown.") { deliveries.all.contains { $0.assetID == "broken" && $0.image == nil } }
        XCTAssertEqual(server.requested, ["broken"])

        // Asked again at once, as a grid does while it scrolls, the photo waits.
        scheduler.submit(Self.demand([("broken", .visible)]), from: source)
        scheduler.pump()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requested.count, 1, "A failed photo is not asked for again straight away.")

        clock.advance(2.5)
        scheduler.pump()
        try await until("The photo was not tried again after its wait.") { server.requested.count == 2 }

        // The second failure waits twice as long.
        try await until("The second failure was not recorded.") { fetcher.retryTime(assetID: "broken", revision: "1") != nil }
        clock.advance(2.5)
        scheduler.pump()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requested.count, 2, "The wait doubles after another failure.")
        clock.advance(2)
        scheduler.pump()
        try await until("The photo was not tried a third time.") { server.requested.count == 3 }
        scheduler.withdraw(source)
    }

    /// While the gate is closed, as when the rail scrubs, the screen is served from disk only.
    func testScrubbingNeverDownloads() async throws {
        let server = FakeServer(holds: false)
        let scheduler = ThumbnailScheduler(store: FakeStore(storing: ["stored"]), memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { id, _, _ in try await server.load(id) }))
        let deliveries = listen(scheduler)
        let source = UUID()
        scheduler.submit(Self.demand([("stored", .visible), ("missing", .visible)], motion: .scrubbing), from: source)
        try await until("The stored photo was not shown.") { deliveries.all.contains { $0.assetID == "stored" } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requested, [], "Nothing downloads while scrubbing.")

        scheduler.submit(Self.demand([("stored", .visible), ("missing", .visible)], motion: .idle(since: 0)), from: source)
        try await until("The grid at rest did not download what it shows.") { deliveries.all.contains { $0.assetID == "missing" } }
        XCTAssertEqual(server.requested, ["missing"])
        scheduler.withdraw(source)
    }

    // MARK: - Decodes

    func testObsoleteDiskDecodesNeverStart() async throws {
        let recorder = Recorder()
        let scheduler = ThumbnailScheduler(store: FakeStore(storing: ["a", "b", "c", "d", "e"]), memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { _, _, _ in throw URLError(.notConnectedToInternet) }),
                                           lanes: 1, willDecode: { recorder.willDecode($0) })
        let source = UUID()
        scheduler.submit(Self.demand([("a", .visible), ("b", .visible), ("c", .visible), ("d", .ahead)], motion: .scrubbing), from: source)
        try await until("The first decode did not start.") { recorder.decoded == ["a"] }
        try await until("The rest were not queued.") { scheduler.pendingCount == 3 }
        // The grid moved on: only a and e are wanted now.
        scheduler.submit(Self.demand([("a", .visible), ("e", .visible)], motion: .scrubbing), from: source)
        try await until("The photos that left were not dropped.") { scheduler.pendingCount == 1 }
        recorder.gate.signal()
        try await until("The new photo did not decode.") { recorder.decoded.contains("e") }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.decoded, ["a", "e"], "Photos that scrolled away never decode.")
        scheduler.withdraw(source)
    }

    /// While scrubbing, the photo that came on screen last decodes first; photos about to scroll
    /// in wait for every photo on screen.
    func testScrubbingDecodesTheNewestPhotoOnScreenFirst() async throws {
        let recorder = Recorder()
        let scheduler = ThumbnailScheduler(store: FakeStore(storing: ["a", "b", "c", "next"]), memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { _, _, _ in throw URLError(.notConnectedToInternet) }),
                                           lanes: 1, willDecode: { recorder.willDecode($0) })
        let source = UUID()
        scheduler.submit(Self.demand([("a", .visible)], motion: .scrubbing), from: source)
        try await until("The first decode did not start.") { recorder.decoded == ["a"] }
        scheduler.submit(Self.demand([("a", .visible), ("next", .ahead), ("b", .visible)], motion: .scrubbing), from: source)
        try await until("b was not queued.") { scheduler.pendingCount == 2 }
        scheduler.submit(Self.demand([("a", .visible), ("next", .ahead), ("b", .visible), ("c", .visible)], motion: .scrubbing), from: source)
        try await until("c was not queued.") { scheduler.pendingCount == 3 }
        recorder.gate.signal()
        try await until("Not everything decoded.") { recorder.decoded.count == 4 }
        XCTAssertEqual(recorder.decoded, ["a", "c", "b", "next"])
        scheduler.withdraw(source)
    }

    func testResetDropsQueuedWorkAndRunningWorkIsNotKept() async throws {
        let recorder = Recorder()
        let store = FakeStore(storing: ["running", "queued"])
        let memory = DecodedThumbnailCache()
        let scheduler = ThumbnailScheduler(store: store, memory: memory,
                                           fetcher: ThumbnailFetcher(load: { _, _, _ in throw URLError(.notConnectedToInternet) }),
                                           lanes: 1, willDecode: { recorder.willDecode($0) })
        let token = store.fence.token()
        let running = Task { try await scheduler.image(assetID: "running", revision: "1", shortSide: 8, network: false, token: token) }
        try await until("The first decode did not start.") { recorder.decoded == ["running"] }
        let queued = Task { try await scheduler.image(assetID: "queued", revision: "1", shortSide: 8, network: false, token: token) }
        try await until("The second request was not queued.") { scheduler.pendingCount == 1 }
        scheduler.reset()
        do { _ = try await queued.value; XCTFail("A dropped request has no image.") } catch {}
        do { _ = try await running.value; XCTFail("An interrupted request has no image.") } catch {}
        recorder.gate.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.decoded, ["running"], "The queued photo never decodes.")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testAPhotoMissingFromTheStoreReturnsNothingWithoutTheNetwork() async throws {
        let server = FakeServer(holds: false)
        let store = FakeStore()
        let scheduler = ThumbnailScheduler(store: store, memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { id, _, _ in try await server.load(id) }))
        let image = try await scheduler.image(assetID: "missing", revision: "1", shortSide: 8, network: false, token: store.fence.token())
        XCTAssertNil(image)
        XCTAssertEqual(server.requested, [])
        let fetched = try await scheduler.image(assetID: "missing", revision: "1", shortSide: 8, network: true, token: store.fence.token())
        XCTAssertNotNil(fetched, "The viewer and feature tiles may download.")
    }

    /// A photo forgotten while its download runs is neither stored nor shown.
    func testAForgottenPhotoIsNotStored() async throws {
        let server = FakeServer()
        let store = FakeStore()
        let scheduler = ThumbnailScheduler(store: store, memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { id, _, _ in try await server.load(id) }))
        let deliveries = listen(scheduler)
        let source = UUID()
        scheduler.submit(Self.demand([("gone", .visible)], token: store.fence.token()), from: source)
        try await until("The download did not start.") { server.requested == ["gone"] }
        store.fence.forget(["gone"])
        scheduler.forget(["gone"])
        server.released.store(true, ordering: .relaxed)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(store.pendingWrites.withLock { $0["gone|1"] })
        XCTAssertTrue(deliveries.all.isEmpty)
        scheduler.withdraw(source)
    }

    // MARK: - Requests and binding

    func testTheRequestTemplateNamesEachPhoto() throws {
        var template = URLRequest(url: try XCTUnwrap(URL(string:
            "https://photos.example/api/assets/ilyich-thumbnail-asset/thumbnail?size=thumbnail&edited=true&c=ilyich-thumbnail-revision")))
        template.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        let request = try ThumbnailRequestTemplate.specialize(template, assetID: "6f1c-42", revision: "a+b/c=")
        let components = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(components.path, "/api/assets/6f1c-42/thumbnail")
        XCTAssertEqual(components.queryItems?.first { $0.name == "c" }?.value, "a+b/c=")
        XCTAssertTrue(components.percentEncodedQuery?.contains("%2B") == true, "A plus is not read as a space.")
        XCTAssertEqual(components.queryItems?.first { $0.name == "size" }?.value, "thumbnail")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testCrossfadeOnlyOverAPlaceholderAndNeverUnderReduceMotion() {
        for stage in [ThumbnailBinder.Stage.empty, .color, .sketch, .failed] {
            XCTAssertTrue(ThumbnailBinder.crossfades(over: stage, reduceMotion: false), "\(stage)")
            XCTAssertFalse(ThumbnailBinder.crossfades(over: stage, reduceMotion: true), "No crossfade under Reduce Motion.")
        }
        for stage in [ThumbnailBinder.Stage.other, .exact] {
            XCTAssertFalse(ThumbnailBinder.crossfades(over: stage, reduceMotion: false), "A sharper copy replaces a photo without a fade.")
        }
    }
}

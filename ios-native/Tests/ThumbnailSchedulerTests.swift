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
    /// A photo large enough to decode at several sizes.
    private static let largePNG: Data = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).pngData { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }()

    /// A disk in memory whose writes finish only when the test says so, and whose reads the test
    /// can count.
    private final class FakeStore: ThumbnailStoring {
        let fence = MediaFence()
        let files = Mutex<[String: Data]>([:])
        let pendingWrites = Mutex<[String: Data]>([:])

        init(storing ids: [String] = [], data: Data = ThumbnailSchedulerTests.png) {
            files.withLock { files in for id in ids { files[id + "|1"] = data } }
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

    private final class Count: Sendable {
        let value = Atomic<Int>(0)
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

    private static func demand(_ items: [(String, DemandBand)], motion: Motion = .idle(since: 0), token: UInt64 = 0,
                               shortSide: Int = 8) -> ViewportDemand {
        ViewportDemand(generation: token, items: items.enumerated().map { rank, item in
            ViewportDemand.Item(request: ThumbnailRequest(key: .server(assetID: item.0, revision: "1"), thumbhash: nil, shortSide: shortSide),
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
        // Nothing waits on the photo on screen, so its write may land just after coverage's.
        try await until("Every download reaches the disk.") { store.pendingWrites.withLock { $0.count } == 5 }
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

    /// The viewer, a feature tile or the info view asking for a photo the grid failed to load
    /// tries at once instead of waiting out the grid's backoff.
    func testASinglePhotoRequestDoesNotWaitOutTheBackoff() async throws {
        let clock = Clock()
        let server = FakeServer(holds: false, fails: true)
        let fetcher = ThumbnailFetcher(load: { id, _, _ in try await server.load(id) }, baseDelay: 60,
                                       now: { clock.now.withLock { $0 } })
        let store = FakeStore()
        let scheduler = ThumbnailScheduler(store: store, memory: DecodedThumbnailCache(), fetcher: fetcher)
        let deliveries = listen(scheduler)
        let source = UUID()
        scheduler.submit(Self.demand([("broken", .visible)]), from: source)
        try await until("The failure was not shown.") { deliveries.all.contains { $0.assetID == "broken" && $0.image == nil } }
        try await until("The failure was not recorded.") { fetcher.retryTime(assetID: "broken", revision: "1") != nil }

        let asked = Task { try await scheduler.image(assetID: "broken", revision: "1", shortSide: 8, network: true, token: store.fence.token()) }
        try await until("The single photo waited out the backoff.") { server.requested.count == 2 }
        do { _ = try await asked.value; XCTFail("The server still fails.") } catch {}
        scheduler.withdraw(source)
    }

    /// Photos that failed while the network was gone are tried again as soon as it is back.
    func testTheNetworkComingBackRetriesFailedPhotosAtOnce() async throws {
        let clock = Clock()
        let server = FakeServer(holds: false, fails: true)
        let fetcher = ThumbnailFetcher(load: { id, _, _ in try await server.load(id) }, baseDelay: 60,
                                       now: { clock.now.withLock { $0 } })
        let scheduler = ThumbnailScheduler(store: FakeStore(), memory: DecodedThumbnailCache(), fetcher: fetcher)
        let deliveries = listen(scheduler)
        let source = UUID()
        scheduler.submit(Self.demand([("offline", .visible)]), from: source)
        try await until("The failure was not shown.") { deliveries.all.contains { $0.assetID == "offline" && $0.image == nil } }
        try await until("The failure was not recorded.") { fetcher.retryTime(assetID: "offline", revision: "1") != nil }
        scheduler.pump()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(server.requested.count, 1, "The photo waits while nothing has changed.")

        scheduler.networkReturned()
        try await until("The photo was not tried again when the network came back.") { server.requested.count == 2 }
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

    /// Passing photos faster than they could arrive, the grid is served from the disk; between the
    /// policy's two speeds the decision stands, and under the slow mark the screen downloads.
    func testAFastGridUsesTheDiskUntilItSlows() async throws {
        let server = FakeServer(holds: false)
        let scheduler = ThumbnailScheduler(store: FakeStore(storing: ["stored"]), memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { id, _, _ in try await server.load(id) }))
        let deliveries = listen(scheduler)
        let source = UUID()
        scheduler.submit(Self.demand([("stored", .visible), ("missing", .visible)], motion: .flinging(speed: 4)), from: source)
        try await until("The stored photo was not shown.") { deliveries.all.contains { $0.assetID == "stored" } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requested, [], "Nothing downloads at four screens a second.")

        scheduler.submit(Self.demand([("stored", .visible), ("missing", .visible)], motion: .flinging(speed: 2)), from: source)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requested, [], "Slowing to two screens a second, the grid is still fast.")

        scheduler.submit(Self.demand([("stored", .visible), ("missing", .visible)], motion: .flinging(speed: 1)), from: source)
        try await until("The slowing grid did not download what it shows.") { deliveries.all.contains { $0.assetID == "missing" } }
        XCTAssertEqual(server.requested, ["missing"])
        scheduler.withdraw(source)
    }

    /// Where a fling lands downloads while the grid is still fast; the photos passing by wait.
    func testTheFlingTargetDownloadsWhileTheGridIsFast() async throws {
        let server = FakeServer(holds: false)
        let scheduler = ThumbnailScheduler(store: FakeStore(), memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { id, _, _ in try await server.load(id) }))
        let deliveries = listen(scheduler)
        let source = UUID()
        scheduler.submit(Self.demand([("passing", .visible), ("coming", .ahead), ("landing", .target)], motion: .flinging(speed: 5)), from: source)
        try await until("The landing photo did not download.") { deliveries.all.contains { $0.assetID == "landing" } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requested, ["landing"])
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

    /// Someone asking for a larger copy while the grid's smaller one decodes gets the size asked for.
    func testALargerRequestDuringAGridDecodeGetsItsOwnSize() async throws {
        let recorder = Recorder()
        let store = FakeStore(storing: ["photo"], data: Self.largePNG)
        let scheduler = ThumbnailScheduler(store: store, memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { _, _, _ in throw URLError(.notConnectedToInternet) }),
                                           lanes: 1, willDecode: { recorder.willDecode($0) })
        let deliveries = listen(scheduler)
        let source = UUID()
        scheduler.submit(Self.demand([("photo", .visible)], shortSide: 16), from: source)
        try await until("The grid's decode did not start.") { recorder.decoded == ["photo"] }
        let large = Task { try await scheduler.image(assetID: "photo", revision: "1", shortSide: 48, network: false, token: store.fence.token()) }
        try await Task.sleep(for: .milliseconds(50))
        recorder.gate.signal()
        let result = try await large.value
        let image = try XCTUnwrap(result)
        XCTAssertGreaterThanOrEqual(min(image.cgImage.width, image.cgImage.height), 48, "The larger request got the grid's smaller copy.")
        try await until("The grid's copy was not delivered.") { deliveries.all.contains { $0.assetID == "photo" } }
        let grid = try XCTUnwrap(deliveries.all.first { $0.assetID == "photo" }?.image)
        XCTAssertLessThan(min(grid.cgImage.width, grid.cgImage.height), 48, "The grid's own copy came first, at its size.")
        scheduler.withdraw(source)
    }

    /// After everything is dropped, as by a sync reset, the grids are asked to say again what they want.
    func testResetAsksTheGridsAgain() async throws {
        let scheduler = ThumbnailScheduler(store: FakeStore(), memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { _, _, _ in throw URLError(.notConnectedToInternet) }))
        let asked = Count()
        let listener = scheduler.addListener({ _ in }, reset: { asked.value.add(1, ordering: .relaxed) })
        scheduler.reset()
        try await until("The grid was not asked again.") { asked.value.load(ordering: .relaxed) == 1 }
        scheduler.removeListener(listener)
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

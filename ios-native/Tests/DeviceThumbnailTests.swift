import IlyichPlatform
import Synchronization
import UIKit
import XCTest
@testable import Ilyich

/// Phone photos and feature tiles through the thumbnail service (REBUILD_ROADMAP.md T6): Photos'
/// caching manager follows the grid's window by diff and at the cell's size, stops on a density
/// change, a memory warning and the background, phone photos reach the grid like server photos,
/// one Photos cannot render waits before Photos is asked again, and a tile that knows only an ID
/// names its photo from the library instead of the server.
final class DeviceThumbnailTests: XCTestCase {
    /// Photos' caching image manager, recording every call. A photo it was given renders at the
    /// size asked, as Photos' aspect-fill does; one marked in iCloud is unavailable with that
    /// reason; an unknown one is simply gone.
    private final class FakeImaging: DeviceThumbnailImaging {
        struct Call: Equatable { let ids: [String]; let pixels: Int }
        private struct State {
            var started: [Call] = []
            var stopped: [Call] = []
            var stoppedAll = 0
            var requested: [(id: String, pixels: Int)] = []
        }
        private let state = Mutex(State())
        private let photos: Set<String>
        private let inCloud: Set<String>
        /// With `holdsFirstStart`, the first start blocks the source's queue until `release()`.
        private let holdsFirstStart: Bool
        private let gate = DispatchSemaphore(value: 0)

        init(photos: [String], inCloud: [String] = [], holdsFirstStart: Bool = false) {
            self.photos = Set(photos)
            self.inCloud = Set(inCloud)
            self.holdsFirstStart = holdsFirstStart
        }
        func startCaching(_ ids: [DeviceAssetID], pixels: Int) {
            let first = state.withLock { state in
                state.started.append(Call(ids: ids.map(\.rawValue).sorted(), pixels: pixels))
                return state.started.count == 1
            }
            if first && holdsFirstStart { gate.wait() }
        }
        func release() { gate.signal() }
        func stopCaching(_ ids: [DeviceAssetID], pixels: Int) {
            state.withLock { $0.stopped.append(Call(ids: ids.map(\.rawValue).sorted(), pixels: pixels)) }
        }
        func stopCachingAll() { state.withLock { $0.stoppedAll += 1 } }
        func thumbnail(_ id: DeviceAssetID, pixels: Int) -> DeviceThumbnailResult {
            state.withLock { $0.requested.append((id.rawValue, pixels)) }
            if inCloud.contains(id.rawValue) { return .unavailable(inCloud: true) }
            guard photos.contains(id.rawValue) else { return .unavailable(inCloud: false) }
            return .image(DeviceThumbnailTests.image(side: pixels))
        }
        var started: [Call] { state.withLock { $0.started } }
        var stopped: [Call] { state.withLock { $0.stopped } }
        var stoppedAll: Int { state.withLock { $0.stoppedAll } }
        var requested: [(id: String, pixels: Int)] { state.withLock { $0.requested } }
    }

    /// A store with nothing on disk: phone photos never go there.
    private final class EmptyStore: ThumbnailStoring {
        let fence = MediaFence()
        func contains(assetID: String, revision: String) -> Bool { false }
        func data(assetID: String, revision: String) -> Data? { nil }
        func enqueueWrite(_ data: Data, assetID: String, revision: String, token: UInt64) {}
    }

    private final class Deliveries: Sendable {
        let received = Mutex<[ThumbnailDelivery]>([])
        var all: [ThumbnailDelivery] { received.withLock { $0 } }
    }

    private final class Count: Sendable {
        let value = Atomic<Int>(0)
    }

    private final class Clock: Sendable {
        let now = Mutex<TimeInterval>(1_000)
        func advance(_ seconds: TimeInterval) { now.withLock { $0 += seconds } }
        var time: TimeInterval { now.withLock { $0 } }
    }

    /// A square bitmap of `side` pixels, as Photos renders an aspect-filled thumbnail.
    nonisolated static func image(side: Int) -> PreparedImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return PreparedImage(cgImage: image.cgImage!)
    }

    private static func device(_ id: String, modified: Double? = 700_000_000) -> ThumbnailKey {
        .device(DeviceAssetID(rawValue: id), modified: modified.map { AssetRevision(referenceSeconds: $0) })
    }

    private static func demand(_ items: [(ThumbnailKey, DemandBand)], shortSide: Int, motion: Motion = .idle(since: 0)) -> ViewportDemand {
        ViewportDemand(generation: 0, items: items.enumerated().map { rank, item in
            ViewportDemand.Item(request: ThumbnailRequest(key: item.0, thumbhash: nil, shortSide: shortSide), band: item.1, rank: rank)
        }, motion: motion)
    }

    private func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeScheduler(_ imaging: FakeImaging, memory: DecodedThumbnailCache = DecodedThumbnailCache(),
                               notifications: NotificationCenter = NotificationCenter(),
                               fetcher: ThumbnailFetcher = ThumbnailFetcher(load: { _, _, _ in throw URLError(.notConnectedToInternet) }))
        -> (ThumbnailScheduler, DeviceThumbnailSource, Deliveries) {
        let source = DeviceThumbnailSource(imaging: imaging, notifications: notifications)
        let scheduler = ThumbnailScheduler(store: EmptyStore(), memory: memory, fetcher: fetcher, device: source, lanes: 1)
        let deliveries = Deliveries()
        _ = scheduler.addListener { batch in deliveries.received.withLock { $0 += batch } }
        return (scheduler, source, deliveries)
    }

    // MARK: - Preheating

    /// Scrolling one row costs Photos the new row: only the photos that came into the window are
    /// started and only those that left are stopped.
    func testPreheatFollowsTheWindowByDiff() async throws {
        let imaging = FakeImaging(photos: ["a", "b", "c", "d"])
        let source = DeviceThumbnailSource(imaging: imaging, notifications: NotificationCenter())
        source.preheat([DeviceAssetID(rawValue: "a"), DeviceAssetID(rawValue: "b"), DeviceAssetID(rawValue: "c")], pixels: 128)
        try await until("The first window was not started.") { imaging.started.count == 1 }
        XCTAssertEqual(imaging.started, [.init(ids: ["a", "b", "c"], pixels: 128)])

        source.preheat([DeviceAssetID(rawValue: "b"), DeviceAssetID(rawValue: "c"), DeviceAssetID(rawValue: "d")], pixels: 128)
        try await until("The row that came in was not started.") { imaging.started.count == 2 }
        XCTAssertEqual(imaging.started.last, .init(ids: ["d"], pixels: 128), "Only the photo that came in is started.")
        XCTAssertEqual(imaging.stopped, [.init(ids: ["a"], pixels: 128)], "Only the photo that left is stopped.")
        XCTAssertEqual(imaging.stoppedAll, 0)

        // The same window again changes nothing.
        source.preheat([DeviceAssetID(rawValue: "b"), DeviceAssetID(rawValue: "c"), DeviceAssetID(rawValue: "d")], pixels: 128)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(imaging.started.count, 2)
        XCTAssertEqual(imaging.stopped.count, 1)
        XCTAssertEqual(source.cachedWindow, Set(["b", "c", "d"].map { DeviceAssetID(rawValue: $0) }))
    }

    /// The grid's demand drives the window: the phone photos it wants that memory lacks, on
    /// screen and about to scroll in, are the window Photos caches ahead.
    func testTheGridsDemandIsTheWindowPhotosCachesAhead() async throws {
        let imaging = FakeImaging(photos: ["a", "b", "c"])
        let (scheduler, source, deliveries) = makeScheduler(imaging)
        let grid = UUID()
        scheduler.submit(Self.demand([(Self.device("a"), .visible), (Self.device("b"), .ahead),
                                      (.server(assetID: "s", revision: "1"), .visible)], shortSide: 128), from: grid)
        try await until("The window was not cached.") { imaging.started.count == 1 }
        XCTAssertEqual(imaging.started, [.init(ids: ["a", "b"], pixels: 128)], "Server photos are no business of Photos.")
        try await until("The phone photos did not reach the grid.") { deliveries.all.count { $0.image != nil } == 2 }

        // Once rendered, they are in memory and leave the window; a new photo joins it.
        scheduler.submit(Self.demand([(Self.device("a"), .visible), (Self.device("b"), .visible), (Self.device("c"), .ahead)], shortSide: 128), from: grid)
        try await until("The new photo was not cached.") { imaging.started.count == 2 }
        XCTAssertEqual(imaging.started.last, .init(ids: ["c"], pixels: 128))
        XCTAssertEqual(imaging.stopped, [.init(ids: ["a", "b"], pixels: 128)], "Photos in memory need no caching.")

        scheduler.withdraw(grid)
        try await until("The grid's leaving did not empty the window.") { source.cachedWindow.isEmpty }
        XCTAssertEqual(imaging.stopped.last, .init(ids: ["c"], pixels: 128))
    }

    /// Photos caches and renders at the cell's own pixel size, and a density change starts the
    /// window over at the new size instead of adding to the old one.
    func testRequestsUseCellPixelSize() async throws {
        let imaging = FakeImaging(photos: ["a", "b"])
        let memory = DecodedThumbnailCache()
        let (scheduler, _, deliveries) = makeScheduler(imaging, memory: memory)
        let grid = UUID()
        scheduler.submit(Self.demand([(Self.device("a"), .visible), (Self.device("b"), .ahead)], shortSide: 144), from: grid)
        try await until("The photos were not rendered.") { deliveries.all.count == 2 }
        try await until("The window was not cached.") { imaging.started.count == 1 }
        XCTAssertEqual(imaging.started, [.init(ids: ["a", "b"], pixels: 144)])
        XCTAssertEqual(imaging.requested.map(\.pixels), [144, 144], "Photos renders at the cell's size.")
        let rendered = try XCTUnwrap(memory.image(assetID: Self.device("a").assetID, revision: Self.device("a").revision, shortSide: 144))
        XCTAssertEqual(min(rendered.cgImage.width, rendered.cgImage.height), 144)
        XCTAssertNil(memory.image(assetID: Self.device("a").assetID, revision: Self.device("a").revision, shortSide: 200),
                     "A larger cell needs a sharper copy.")

        // Fewer, larger cells: the window starts over at the new size.
        scheduler.submit(Self.demand([(Self.device("a"), .visible), (Self.device("b"), .visible)], shortSide: 200), from: grid)
        try await until("The sharper copies were not rendered.") { deliveries.all.count == 4 }
        try await until("The new window was not cached.") { imaging.started.count == 2 }
        XCTAssertEqual(imaging.stoppedAll, 1, "The old size is dropped as a whole.")
        XCTAssertEqual(imaging.started.last, .init(ids: ["a", "b"], pixels: 200))
        XCTAssertEqual(imaging.requested.suffix(2).map(\.pixels), [200, 200])
        XCTAssertNotNil(memory.image(assetID: Self.device("a").assetID, revision: Self.device("a").revision, shortSide: 200))
        scheduler.withdraw(grid)
    }

    /// A memory warning and the background stop Photos caching; nothing is started again until
    /// the app is forward and the grid says what it wants.
    func testPreheatStopsOnMemoryWarningAndInTheBackground() async throws {
        let imaging = FakeImaging(photos: ["a", "b"])
        let notifications = NotificationCenter()
        let source = DeviceThumbnailSource(imaging: imaging, notifications: notifications)
        let ids: Set<DeviceAssetID> = [DeviceAssetID(rawValue: "a"), DeviceAssetID(rawValue: "b")]
        source.preheat(ids, pixels: 128)
        try await until("The window was not started.") { imaging.started.count == 1 }

        notifications.post(name: DeviceThumbnailSource.memoryWarning, object: nil)
        try await until("The memory warning did not stop Photos.") { imaging.stoppedAll == 1 }
        XCTAssertTrue(source.cachedWindow.isEmpty)
        // The next window starts from nothing.
        source.preheat(ids, pixels: 128)
        try await until("The window was not started again.") { imaging.started.count == 2 }
        XCTAssertEqual(imaging.started.last, .init(ids: ["a", "b"], pixels: 128))

        notifications.post(name: DeviceThumbnailSource.didEnterBackground, object: nil)
        try await until("The background did not stop Photos.") { imaging.stoppedAll == 2 }
        source.preheat(ids, pixels: 128)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(imaging.started.count, 2, "Nothing is cached in the background.")

        notifications.post(name: DeviceThumbnailSource.willEnterForeground, object: nil)
        source.preheat(ids, pixels: 128)
        try await until("The window was not started after coming forward.") { imaging.started.count == 3 }
        XCTAssertEqual(imaging.stopped, [], "Stopping everything at once stops nothing one by one.")
    }

    /// A memory warning while a window waits its turn on the source's queue: the window started
    /// after the warning was posted is stopped with everything else, and the source knows it, so
    /// the next window starts from nothing instead of only its newcomers.
    func testAWindowStartedBeforeAClearIsWorkedInIsKnownToBeStopped() async throws {
        let imaging = FakeImaging(photos: ["a", "b", "c", "d"], holdsFirstStart: true)
        let notifications = NotificationCenter()
        let source = DeviceThumbnailSource(imaging: imaging, notifications: notifications)
        func ids(_ names: String...) -> Set<DeviceAssetID> { Set(names.map { DeviceAssetID(rawValue: $0) }) }
        source.preheat(ids("a"), pixels: 128)
        try await until("The first window was not started.") { imaging.started.count == 1 }

        // Photos holds the first start, so these line up behind it on the queue in this order:
        // the second window, the warning's stop, and a third window that only replaces the second.
        source.preheat(ids("a", "b"), pixels: 128)
        notifications.post(name: DeviceThumbnailSource.memoryWarning, object: nil)
        source.preheat(ids("a", "b", "c"), pixels: 128)
        imaging.release()
        try await until("The memory warning did not stop Photos.") { imaging.stoppedAll == 1 }
        XCTAssertEqual(imaging.started.count, 2, "The window queued before the warning was started…")
        XCTAssertTrue(source.cachedWindow.isEmpty, "…and is known to be stopped with the rest.")

        source.preheat(ids("a", "b", "c", "d"), pixels: 128)
        try await until("The next window was not started.") { imaging.started.count == 3 }
        XCTAssertEqual(imaging.started.last, .init(ids: ["a", "b", "c", "d"], pixels: 128), "The next window starts from nothing.")
        XCTAssertEqual(source.cachedWindow, ids("a", "b", "c", "d"))
    }

    // MARK: - Deliveries

    /// A phone photo reaches the grid as a server photo does, by the key it was bound with, from
    /// Photos and never the network; one Photos holds only in iCloud, or no longer has, is told
    /// so the cell shows why.
    func testPhonePhotosReachTheGridAndUnavailableOnesSayWhy() async throws {
        let imaging = FakeImaging(photos: ["here"], inCloud: ["cloud"])
        let memory = DecodedThumbnailCache()
        let (scheduler, _, deliveries) = makeScheduler(imaging, memory: memory)
        let grid = UUID()
        let here = Self.device("here"), cloud = Self.device("cloud"), gone = Self.device("gone", modified: nil)
        scheduler.submit(Self.demand([(here, .visible), (cloud, .visible), (gone, .visible)], shortSide: 128, motion: .scrubbing), from: grid)
        try await until("Not every photo was answered.") { deliveries.all.count == 3 }
        let byKey = Dictionary(deliveries.all.map { ($0.assetID + "|" + $0.revision, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = try XCTUnwrap(byKey[here.assetID + "|" + here.revision])
        XCTAssertNotNil(shown.image)
        XCTAssertFalse(shown.fromNetwork)
        XCTAssertFalse(shown.inCloud)
        XCTAssertTrue(here.assetID.hasPrefix(ThumbnailKey.devicePrefix), "Phone photos are filed apart from server photos.")
        XCTAssertEqual(here.revision, String((700_000_000 as Double).bitPattern), "The revision is the modification date, bit for bit.")
        XCTAssertNotNil(memory.image(assetID: here.assetID, revision: here.revision, shortSide: 128), "It stays in memory for the next bind.")

        let inCloud = try XCTUnwrap(byKey[cloud.assetID + "|" + cloud.revision])
        XCTAssertNil(inCloud.image)
        XCTAssertTrue(inCloud.inCloud)
        let missing = try XCTUnwrap(byKey[gone.assetID + "|" + gone.revision])
        XCTAssertNil(missing.image)
        XCTAssertFalse(missing.inCloud)
        XCTAssertEqual(gone.revision, "-", "A photo without a modification date has a revision all the same.")
        XCTAssertEqual(scheduler.pendingCount, 0, "Nothing waits on the server for a phone photo.")
        scheduler.withdraw(grid)
    }

    /// A phone photo Photos cannot render is in every demand the grid sends while it scrolls, as
    /// its cell shows the failure; Photos is not asked for it again on each one. Like a failing
    /// download it waits, twice as long after each failure, and leaves the preheat window.
    func testAPhonePhotoPhotosCannotRenderWaitsBeforeItIsAskedAgain() async throws {
        let imaging = FakeImaging(photos: ["here"], inCloud: ["cloud"])
        let clock = Clock()
        let fetcher = ThumbnailFetcher(load: { _, _, _ in throw URLError(.notConnectedToInternet) }, baseDelay: 2,
                                       now: { clock.time })
        let (scheduler, source, deliveries) = makeScheduler(imaging, fetcher: fetcher)
        let grid = UUID()
        let cloud = Self.device("cloud"), here = Self.device("here")
        func asked() -> Int { imaging.requested.count { $0.id == "cloud" } }
        scheduler.submit(Self.demand([(cloud, .visible), (here, .visible)], shortSide: 128), from: grid)
        try await until("The photos were not answered.") { deliveries.all.count == 2 }
        XCTAssertEqual(asked(), 1)
        try await until("The window was not cached.") { imaging.started.count == 1 }
        XCTAssertEqual(imaging.started, [.init(ids: ["cloud", "here"], pixels: 128)], "Nothing is known against the photo yet.")

        // Asked again at once, as the grid does on every scroll with the failed cell on screen.
        for _ in 0..<3 {
            scheduler.submit(Self.demand([(cloud, .visible), (here, .visible)], shortSide: 128), from: grid)
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(asked(), 1, "Photos is not asked again straight away for a photo it could not render.")
        try await until("The photo Photos could not render stayed in the window.") { source.cachedWindow.isEmpty }
        XCTAssertEqual(imaging.started.count, 1)

        clock.advance(2.5)
        scheduler.pump()
        try await until("Photos was not asked again after the wait.") { asked() == 2 }
        try await until("The second failure was not recorded.") {
            fetcher.retryTime(assetID: cloud.assetID, revision: cloud.revision).map { $0 > clock.time } ?? false
        }

        // The second failure waits twice as long.
        scheduler.submit(Self.demand([(cloud, .visible)], shortSide: 128), from: grid)
        clock.advance(2.5)
        scheduler.pump()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(asked(), 2, "The wait doubles after another failure.")
        clock.advance(2)
        scheduler.pump()
        try await until("Photos was not asked a third time.") { asked() == 3 }
        XCTAssertEqual(imaging.requested.count { $0.id == "here" }, 1, "A photo Photos rendered is in memory and never asked again.")
        scheduler.withdraw(grid)
    }

    /// Without a device source, as in a build that leaves the phone's photos out, phone photos in
    /// a demand are left alone and server photos are served as before.
    func testWithoutADeviceSourcePhonePhotosAreLeftAlone() async throws {
        let scheduler = ThumbnailScheduler(store: EmptyStore(), memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { _, _, _ in throw URLError(.notConnectedToInternet) }))
        let deliveries = Deliveries()
        _ = scheduler.addListener { batch in deliveries.received.withLock { $0 += batch } }
        let grid = UUID()
        scheduler.submit(Self.demand([(Self.device("a"), .visible)], shortSide: 128), from: grid)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertTrue(deliveries.all.isEmpty)
        scheduler.withdraw(grid)
    }

    // MARK: - Feature tiles

    /// A tile that knows only an ID gets its thumbnail through the library's record of the photo,
    /// with the revision the server's thumbnail is cached under, and never asks the server for the
    /// asset first. Only a photo the library lacks is fetched.
    func testNoAssetFetchBeforeThumbnailWhenIndexHasRevision() async throws {
        let server = makeStubServer()
        let api = try APIClient(baseURL: server.baseURL, accessToken: "tile-session", userID: "tile-" + UUID().uuidString,
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        let pipeline = MediaPipeline(client: api, protocolClasses: [StubURLProtocol.self], earlierURLCacheEntries: false)
        addTeardownBlock { await pipeline.removeAll(); await api.shutdown() }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        for id in ["indexed", "unknown"] {
            server.route("GET", "assets/\(id)/thumbnail", StubServer.Response(status: 200, headers: ["Content-Type": "image/png"], body: png))
        }
        let fetches = Count()
        pipeline.setIndexedAssets { id in id == "indexed" ? Asset(id: id, mediaRevision: "rev-7") : nil }

        let image = try await pipeline.thumbnail(assetID: "indexed", shortSide: 8) { id in
            fetches.value.add(1, ordering: .relaxed)
            return Asset(id: id, mediaRevision: "from-server")
        }
        XCTAssertEqual(min(image.cgImage.width, image.cgImage.height), 8)
        XCTAssertEqual(fetches.value.load(ordering: .relaxed), 0, "The library names the photo; the server is not asked for it.")
        let thumbnails = server.requests("GET", "assets/indexed/thumbnail")
        XCTAssertEqual(thumbnails.count, 1)
        XCTAssertEqual(thumbnails.first?.query.first { $0.name == "c" }?.value, "rev-7", "The thumbnail is cached under the library's revision.")
        XCTAssertTrue(server.requests("GET", "assets/indexed").isEmpty, "No GET assets/{id} round trip.")

        _ = try await pipeline.thumbnail(assetID: "unknown", shortSide: 8) { id in
            fetches.value.add(1, ordering: .relaxed)
            return Asset(id: id, mediaRevision: "from-server")
        }
        XCTAssertEqual(fetches.value.load(ordering: .relaxed), 1, "A photo the library lacks is fetched once.")
        XCTAssertEqual(server.requests("GET", "assets/unknown/thumbnail").first?.query.first { $0.name == "c" }?.value, "from-server")
    }

    /// A tile decodes to cover its long side: a photo of unknown shape aspect-fills the shelf's
    /// wide, low row without being stretched, and a square tile still shares the grid's copy.
    @MainActor func testTilesDecodeToCoverTheirLongSide() {
        XCTAssertEqual(tilePixels(CGSize(width: 244, height: 56), scale: 3), 732, "The shelf row's cover covers its width.")
        XCTAssertEqual(tilePixels(CGSize(width: 56, height: 56), scale: 3), 168)
        XCTAssertEqual(tilePixels(CGSize(width: 38, height: 38), scale: 3), 128, "No less than the grid's smallest cell.")
    }
}

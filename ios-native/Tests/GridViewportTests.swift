import Synchronization
import UIKit
import XCTest
@testable import Ilyich

/// The viewport motion policy (REBUILD_ROADMAP.md T3): the grid's speed decides what may
/// download, a fling's target is prepared while it still decelerates, the rail's scrub holds
/// coverage, and a month becoming ready asks for its thumbnails without a scroll.
@MainActor final class GridViewportTests: XCTestCase {
    private static let screen = CGSize(width: 390, height: 844)

    @MainActor private final class DataSource: NSObject, UICollectionViewDataSource {
        let sections: Int
        let perSection: Int
        init(sections: Int, perSection: Int) { self.sections = sections; self.perSection = perSection }
        func numberOfSections(in collectionView: UICollectionView) -> Int { sections }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { perSection }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }
    }

    /// Frames the test fires by hand.
    @MainActor private final class ManualFrames: ViewportFrames {
        var onFrame: ((TimeInterval) -> Void)?
        private(set) var isRunning = false
        func start() { isRunning = true }
        func stop() { isRunning = false }
        func fire(_ time: TimeInterval) { if isRunning { onFrame?(time) } }
    }

    /// A grid of months, its viewport on hand-driven frames, and every demand it sent.
    @MainActor private final class Harness {
        let collection: UICollectionView
        let layout = VirtualPhotoLayout()
        let dataSource: DataSource
        let frames = ManualFrames()
        let viewport: GridViewport
        var time: TimeInterval = 1_000
        var windows: [GridViewport.Windows] = []
        /// The months whose photos are known; the others have no entries yet.
        var loaded: Set<Int>
        /// The rail's finger is down, as the rail tells the viewport.
        var scrubbing = false {
            didSet { if scrubbing { viewport.beginScrub() } else { viewport.endScrub() } }
        }

        init(sections: Int = 40, perSection: Int = 100, loaded: Set<Int>? = nil) {
            layout.columns = 4
            collection = UICollectionView(frame: CGRect(origin: .zero, size: GridViewportTests.screen), collectionViewLayout: layout)
            collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
            dataSource = DataSource(sections: sections, perSection: perSection)
            collection.dataSource = dataSource
            collection.reloadData()
            collection.layoutIfNeeded()
            self.loaded = loaded ?? Set(0..<sections)
            let frames = self.frames
            viewport = GridViewport(frames: frames, now: { 0 })
            viewport.attach(collection)
            viewport.entry = { [unowned self] path in
                self.loaded.contains(path.section) ? .remote(Asset(id: Harness.id(path), mediaRevision: "1")) : nil
            }
            viewport.shortSide = { 128 }
            viewport.submit = { [unowned self] windows in self.windows.append(windows) }
        }

        static func id(_ path: IndexPath) -> String { "s\(path.section)-\(path.item)" }
        static func path(_ id: String) -> IndexPath {
            let parts = id.dropFirst().split(separator: "-")
            return IndexPath(item: Int(parts[1])!, section: Int(parts[0])!)
        }

        var screen: CGFloat { collection.bounds.height }

        /// Moves the grid `points` over `seconds`, a frame at a time, as a drag or the rail would.
        func scroll(by points: CGFloat, over seconds: TimeInterval, frames count: Int) {
            for _ in 0..<count {
                collection.contentOffset.y += points / CGFloat(count)
                viewport.didScroll()
                tick(seconds / Double(count))
            }
        }

        /// Frames pass with the grid still.
        func hold(for seconds: TimeInterval, frames count: Int = 6) {
            for _ in 0..<count { tick(seconds / Double(count)) }
        }

        func tick(_ seconds: TimeInterval) {
            time += seconds
            frames.fire(time)
        }

        /// The photos the layout puts on the screen `rect`, as the binder would read them off its cells.
        func visibleIDs(in rect: CGRect) -> [String] {
            (layout.layoutAttributesForElements(in: rect) ?? [])
                .filter { $0.representedElementCategory == .cell }
                .compactMap { loaded.contains($0.indexPath.section) ? Harness.id($0.indexPath) : nil }
        }

        /// The demand the grid would send for `windows`: what is on screen, then the windows.
        func demand(_ windows: GridViewport.Windows, token: UInt64) -> ViewportDemand {
            var items: [ViewportDemand.Item] = []
            var seen = Set<String>()
            for (rank, id) in visibleIDs(in: windows.visible).enumerated() {
                seen.insert(id)
                items.append(.init(request: ThumbnailRequest(key: .server(assetID: id, revision: "1"), thumbhash: nil, shortSide: 128),
                                   band: windows.visibleBand, rank: rank))
            }
            let bands: [(DemandBand, [ThumbnailBinder.Ahead])] = [(.target, windows.target), (.ahead, windows.ahead), (.behind, windows.behind)]
            for (band, photos) in bands {
                for (rank, photo) in photos.enumerated() where !seen.contains(photo.key.assetID) {
                    seen.insert(photo.key.assetID)
                    items.append(.init(request: ThumbnailRequest(key: photo.key, thumbhash: nil, shortSide: 128), band: band, rank: rank))
                }
            }
            return ViewportDemand(generation: token, items: items, motion: windows.motion)
        }
    }

    /// A disk with nothing on it.
    private final class EmptyStore: ThumbnailStoring {
        let fence = MediaFence()
        func contains(assetID: String, revision: String) -> Bool { false }
        func data(assetID: String, revision: String) -> Data? { nil }
        func enqueueWrite(_ data: Data, assetID: String, revision: String, token: UInt64) {}
    }

    /// A server that answers every thumbnail and remembers what was asked.
    private final class Server: Sendable {
        let calls = Mutex<[String]>([])
        static let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        func load(_ id: String) async throws -> Data {
            calls.withLock { $0.append(id) }
            return Self.png
        }
        var requested: [String] { calls.withLock { $0 } }
    }

    private func makeScheduler(_ server: Server, store: EmptyStore = EmptyStore()) -> ThumbnailScheduler {
        ThumbnailScheduler(store: store, memory: DecodedThumbnailCache(),
                           fetcher: ThumbnailFetcher(load: { id, _, _ in try await server.load(id) }))
    }

    private func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func kind(_ motion: Motion) -> String {
        switch motion {
        case .idle: "idle"
        case .tracking: "tracking"
        case .flinging: "flinging"
        case .scrubbing: "scrubbing"
        }
    }

    // MARK: - Policy

    func testThePolicyHoldsItsDecisionBetweenTheTwoSpeeds() {
        XCTAssertTrue(ViewportPolicy.isFast(.scrubbing, wasFast: false))
        XCTAssertFalse(ViewportPolicy.isFast(.idle(since: 0), wasFast: true))
        XCTAssertTrue(ViewportPolicy.isFast(.flinging(speed: 3), wasFast: false))
        XCTAssertTrue(ViewportPolicy.isFast(.tracking(speed: 2), wasFast: true), "Between the speeds a fast grid stays fast…")
        XCTAssertFalse(ViewportPolicy.isFast(.tracking(speed: 2), wasFast: false), "…and a slow one stays slow.")
        XCTAssertFalse(ViewportPolicy.isFast(.flinging(speed: 1), wasFast: true))
        XCTAssertTrue(ViewportPolicy.allowsNetwork(.target, fast: true), "Where the grid lands may always download.")
        for band in [DemandBand.visible, .ahead, .behind, .explicit, .coverage] {
            XCTAssertFalse(ViewportPolicy.allowsNetwork(band, fast: true), "\(band)")
            XCTAssertTrue(ViewportPolicy.allowsNetwork(band, fast: false), "\(band)")
        }
        XCTAssertEqual(ViewportPolicy.aheadScreens(at: 0), 1)
        XCTAssertEqual(ViewportPolicy.aheadScreens(at: 2), 2)
        XCTAssertEqual(ViewportPolicy.aheadScreens(at: 9), 3)
        XCTAssertTrue(ViewportPolicy.prefetchesSketchesAhead(.idle(since: 0)))
        XCTAssertTrue(ViewportPolicy.prefetchesSketchesAhead(.tracking(speed: 2)), "Up to the fast mark the photos ahead will be shown.")
        XCTAssertFalse(ViewportPolicy.prefetchesSketchesAhead(.flinging(speed: 3)), "Past it they pass before they could be.")
        XCTAssertFalse(ViewportPolicy.prefetchesSketchesAhead(.scrubbing))
        XCTAssertEqual(ViewportPolicy.coverageHold, CoveragePolicy.today.motionHold, "Coverage waits the same hold the worker was built with.")
    }

    // MARK: - Motion

    /// The rail scrubs three screens in a third of a second: the screen is served from the disk
    /// and nothing downloads. The finger lifts, and with no further gesture the grid is at rest
    /// and the photos on screen download.
    func testCellsLoadAfterAFastScrubStopsWithoutAnotherGesture() async throws {
        let h = Harness()
        let server = Server()
        let store = EmptyStore()
        let scheduler = makeScheduler(server, store: store)
        let source = UUID()
        h.scrubbing = true
        h.scroll(by: h.screen * 3, over: 0.3, frames: 20)
        let fast = try XCTUnwrap(h.windows.last)
        XCTAssertEqual(fast.motion, .scrubbing)
        XCTAssertEqual(fast.visibleBand, .visible)
        XCTAssertGreaterThan(h.viewport.speed, ViewportPolicy.fastSpeed)
        let rowsPerScreen = Int(h.screen / (h.layout.itemSide + 1))
        XCTAssertGreaterThan(fast.ahead.count, 2 * rowsPerScreen * 4, "Three screens ahead are asked for at this speed.")
        // The first frame is the finger touching the rail with the grid still, whose month may
        // download; from the first move on, nothing does.
        XCTAssertEqual(h.windows.first?.visibleBand, .target)
        for windows in h.windows.dropFirst() {
            XCTAssertEqual(windows.visibleBand, .visible)
            scheduler.submit(h.demand(windows, token: store.fence.token()), from: source)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requested, [], "Nothing downloads while the rail scrubs.")

        // The finger lifts. Nothing else happens; the grid stands still for the policy's rest.
        h.scrubbing = false
        let before = h.windows.count
        h.hold(for: 0.15, frames: 9)
        let rested = try XCTUnwrap(h.windows.last)
        XCTAssertGreaterThan(h.windows.count, before, "Coming to rest sends a demand of its own.")
        XCTAssertEqual(Self.kind(rested.motion), "idle")
        XCTAssertEqual(rested.visibleBand, .visible)
        XCTAssertEqual(h.viewport.speed, 0)
        XCTAssertFalse(h.frames.isRunning, "At rest with nothing waiting, the frames stop.")
        scheduler.submit(h.demand(rested, token: store.fence.token()), from: source)
        let visible = Set(h.visibleIDs(in: rested.visible))
        let slots = ThumbnailScheduler.ceiling(.visible)
        try await until("The photos on screen did not download once the grid rested.") { server.requested.count >= visible.count + slots }
        // Downloads start in band order; the first few of a batch may reach the server in any order.
        XCTAssertTrue(visible.isSubset(of: Set(server.requested.prefix(visible.count + slots))),
                      "The screen downloads first: \(visible.subtracting(server.requested.prefix(visible.count + slots)))")
        scheduler.withdraw(source)
    }

    /// A drag that stops with the finger down waits out the policy's rest and then downloads.
    func testADragThatStopsIsAtRestAfterATenthOfASecond() throws {
        let h = Harness()
        h.viewport.willBeginDragging()
        h.scroll(by: h.screen * 2, over: 0.25, frames: 15)
        guard case .tracking(let speed)? = h.windows.last?.motion else { return XCTFail("A drag tracks: \(String(describing: h.windows.last?.motion)).") }
        XCTAssertGreaterThan(speed, ViewportPolicy.fastSpeed)
        // The finger holds still. Not yet at rest…
        h.hold(for: 0.05, frames: 3)
        XCTAssertEqual(Self.kind(try XCTUnwrap(h.windows.last).motion), "tracking")
        // …and then it is.
        h.hold(for: 0.1, frames: 6)
        XCTAssertEqual(Self.kind(try XCTUnwrap(h.windows.last).motion), "idle")
        XCTAssertFalse(h.frames.isRunning, "At rest the frames stop, finger down or not; the delegate reports the lift.")
        let count = h.windows.count
        h.viewport.didEndDragging(decelerate: false)
        XCTAssertTrue(h.frames.isRunning)
        h.hold(for: 0.02, frames: 1)
        XCTAssertEqual(h.windows.count, count + 1, "The lift sends one demand.")
        XCTAssertFalse(h.frames.isRunning)
    }

    /// A fling's landing screen is asked for on the target band, which may download while the
    /// grid is still fast, so its photos are there when the deceleration ends.
    func testFlingTargetIsPreparedBeforeDecelerationEnds() async throws {
        let h = Harness()
        let server = Server()
        let store = EmptyStore()
        let scheduler = makeScheduler(server, store: store)
        let source = UUID()
        h.viewport.willBeginDragging()
        h.scroll(by: h.screen * 0.8, over: 0.2, frames: 12)
        let landing = h.collection.contentOffset.y + h.screen * 3
        // Four screens a second, in points per millisecond as UIKit reports it.
        h.viewport.willEndDragging(velocity: CGPoint(x: 0, y: 4 * h.screen / 1_000), target: CGPoint(x: 0, y: landing))
        h.viewport.didEndDragging(decelerate: true)
        // The deceleration begins: the grid is still far from the landing screen.
        h.scroll(by: h.screen * 0.5, over: 0.1, frames: 6)
        let windows = try XCTUnwrap(h.windows.last)
        guard case .flinging(let speed) = windows.motion else { return XCTFail("A fling is flinging: \(windows.motion).") }
        XCTAssertGreaterThan(speed, ViewportPolicy.fastSpeed)
        XCTAssertFalse(windows.target.isEmpty, "The landing screen is known from the delegate's target.")
        let landingRect = CGRect(x: 0, y: landing, width: h.collection.bounds.width, height: h.screen)
        for photo in windows.target {
            let frame = try XCTUnwrap(h.layout.layoutAttributesForItem(at: Harness.path(photo.key.assetID))?.frame)
            XCTAssertTrue(frame.intersects(landingRect), "\(photo.key.assetID) is not where the fling lands.")
        }
        XCTAssertFalse(windows.ahead.isEmpty)

        scheduler.submit(h.demand(windows, token: store.fence.token()), from: source)
        let targets = Set(windows.target.map(\.key.assetID))
        try await until("The landing screen did not download during the deceleration.") { server.requested.count >= min(6, targets.count) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(server.requested.allSatisfy(targets.contains),
                      "Only where the fling lands downloads while it is fast: \(server.requested.filter { !targets.contains($0) })")
        XCTAssertFalse(server.requested.contains(where: Set(h.visibleIDs(in: windows.visible)).contains), "The photos passing by wait for the disk.")

        // The deceleration ends on the landing screen: it is at rest and may download in full.
        h.collection.contentOffset.y = landing
        h.viewport.didScroll()
        h.viewport.didEndDecelerating()
        h.hold(for: 0.02, frames: 1)
        let rested = try XCTUnwrap(h.windows.last)
        XCTAssertEqual(Self.kind(rested.motion), "idle")
        XCTAssertTrue(rested.target.isEmpty, "At rest there is no target: the screen itself is wanted.")
        scheduler.withdraw(source)
    }

    /// The rail grabbed while a fling still coasts: setContentOffset stops the deceleration, UIKit
    /// reports no end, and the fling's landing screen is forgotten, since the grid goes where the
    /// finger says. When the finger lifts the grid is at rest after the policy's tenth of a second,
    /// not the half second a fling whose end was never reported waits.
    func testARailScrubInterruptingAFlingDropsTheFlingsTarget() throws {
        let h = Harness()
        h.viewport.willBeginDragging()
        h.scroll(by: h.screen * 0.8, over: 0.2, frames: 12)
        let landing = h.collection.contentOffset.y + h.screen * 3
        h.viewport.willEndDragging(velocity: CGPoint(x: 0, y: 4 * h.screen / 1_000), target: CGPoint(x: 0, y: landing))
        h.viewport.didEndDragging(decelerate: true)
        h.scroll(by: h.screen * 0.5, over: 0.1, frames: 6)
        XCTAssertFalse(try XCTUnwrap(h.windows.last).target.isEmpty, "The fling's landing screen is wanted while it coasts.")

        h.scrubbing = true
        h.scroll(by: h.screen * 5, over: 0.1, frames: 6)
        let scrubbed = try XCTUnwrap(h.windows.last)
        XCTAssertEqual(scrubbed.motion, .scrubbing)
        XCTAssertTrue(scrubbed.target.isEmpty, "The fling's landing screen is not where the grid goes any more.")

        h.scrubbing = false
        h.hold(for: 0.15, frames: 9)
        XCTAssertEqual(Self.kind(try XCTUnwrap(h.windows.last).motion), "idle")
        XCTAssertFalse(h.frames.isRunning)
    }

    /// A jump after a rest (the rail tapped, a date, Show in timeline, a perf scenario's jump) is
    /// not a fast scroll: no frame ran across the rest to measure it over, so the screen it lands
    /// on may download at once, and the grid is at rest again a tenth of a second later.
    func testAJumpAfterARestIsNotMeasuredAsAFastScroll() throws {
        let h = Harness()
        h.viewport.setNeedsDemand()
        h.hold(for: 0.02, frames: 1)
        XCTAssertEqual(Self.kind(try XCTUnwrap(h.windows.last).motion), "idle")
        XCTAssertFalse(h.frames.isRunning)

        // A second and a half of rest, then twenty screens in one frame.
        h.time += 1.5
        h.collection.contentOffset.y += h.screen * 20
        h.viewport.didScroll()
        h.tick(1 / 60)
        let landed = try XCTUnwrap(h.windows.last)
        guard case .tracking(let speed) = landed.motion else { return XCTFail("A jump tracks until it has rested: \(landed.motion).") }
        XCTAssertEqual(speed, 0, "Twenty screens over the rest is no speed.")
        XCTAssertFalse(ViewportPolicy.isFast(landed.motion, wasFast: false), "The screen the jump lands on may download at once.")
        XCTAssertEqual(h.viewport.direction, 1, "The jump went down the library.")
        XCTAssertFalse(landed.ahead.isEmpty)
        for photo in landed.ahead {
            let frame = try XCTUnwrap(h.layout.layoutAttributesForItem(at: Harness.path(photo.key.assetID))?.frame)
            XCTAssertLessThan(frame.minY, landed.visible.maxY + h.screen, "One screen ahead at a jump, not three: \(photo.key.assetID)")
        }

        h.hold(for: 0.15, frames: 9)
        XCTAssertEqual(Self.kind(try XCTUnwrap(h.windows.last).motion), "idle")
        XCTAssertFalse(h.frames.isRunning)
    }

    /// The rail's finger holds coverage while it is down and for the policy's hold after; the
    /// month it rests on may download meanwhile, since that is where the scrub lands.
    func testRailScrubHoldsCoverage() throws {
        let h = Harness()
        let clock = Mutex(1_000.0)
        let conditions = CoverageConditions(now: { clock.withLock { $0 } })
        h.viewport.onMotionChange = { conditions.setMoving($0) }
        let policy = CoveragePolicy.today
        XCTAssertNil(policy.hold(conditions.snapshot, now: clock.withLock { $0 }))

        // The finger touches the rail and scrubs.
        h.scrubbing = true
        XCTAssertEqual(policy.hold(conditions.snapshot, now: clock.withLock { $0 }), .moving)
        h.scroll(by: h.screen * 4, over: 0.4, frames: 24)
        clock.withLock { $0 += 0.4 }
        XCTAssertEqual(h.windows.last?.motion, .scrubbing)
        XCTAssertEqual(h.windows.last?.visibleBand, .visible, "While the finger moves, the screen is served from the disk.")

        // It rests on a month, still down: that month may download, and coverage still waits.
        h.hold(for: 0.15, frames: 9)
        clock.withLock { $0 += 0.15 }
        XCTAssertEqual(h.windows.last?.motion, .scrubbing)
        XCTAssertEqual(h.windows.last?.visibleBand, .target, "The month under a resting finger is where the scrub lands.")
        XCTAssertEqual(policy.hold(conditions.snapshot, now: clock.withLock { $0 }), .moving)
        XCTAssertTrue(h.frames.isRunning, "The finger is still down; a lift must be noticed.")

        // The finger lifts: the grid is at rest, and coverage waits the hold out.
        h.scrubbing = false
        let lifted = clock.withLock { $0 }
        h.hold(for: 0.02, frames: 1)
        XCTAssertEqual(Self.kind(try XCTUnwrap(h.windows.last).motion), "idle")
        XCTAssertEqual(policy.hold(conditions.snapshot, now: lifted + 1), .settling(until: lifted + ViewportPolicy.coverageHold))
        XCTAssertNil(policy.hold(conditions.snapshot, now: lifted + ViewportPolicy.coverageHold))
    }

    /// The phase stands in for the store's old isScrolling (T4): a drag and its coast are
    /// scrolling, for the rail's puck; a drag, a coast and the rail's finger are moving, for
    /// coverage. A finger held still is still a drag. The rail taking a coasting grid ends the
    /// coast, and a coast whose end UIKit never reports ends once the grid has stood still for
    /// half a second.
    func testThePhaseFollowsTheDragTheCoastAndTheRail() {
        let h = Harness()
        var scrolling: [Bool] = [], moving: [Bool] = []
        h.viewport.onScrollingChange = { scrolling.append($0) }
        h.viewport.onMotionChange = { moving.append($0) }
        h.viewport.willBeginDragging()
        XCTAssertEqual(h.viewport.phase, .dragging)
        h.scroll(by: h.screen, over: 0.2, frames: 12)
        h.hold(for: 0.2, frames: 12)
        XCTAssertEqual(Self.kind(h.viewport.motion), "idle", "The photos on screen may download…")
        XCTAssertEqual(h.viewport.phase, .dragging, "…but the finger is still down: the puck stays.")
        h.viewport.didEndDragging(decelerate: true)
        XCTAssertEqual(h.viewport.phase, .decelerating)
        h.scroll(by: h.screen, over: 0.2, frames: 12)
        // The rail takes the coasting grid, and lets go.
        h.scrubbing = true
        XCTAssertEqual(h.viewport.phase, .scrubbing)
        h.scrubbing = false
        XCTAssertEqual(h.viewport.phase, .idle)
        XCTAssertEqual(scrolling, [true, false])
        XCTAssertEqual(moving, [true, false])

        // A coast a jump took the grid from: UIKit never reports its end.
        h.viewport.willBeginDragging()
        h.scroll(by: h.screen, over: 0.2, frames: 12)
        h.viewport.didEndDragging(decelerate: true)
        h.scroll(by: h.screen / 2, over: 0.1, frames: 6)
        h.hold(for: 0.3, frames: 18)
        XCTAssertEqual(h.viewport.phase, .decelerating, "Still for under half a second, the coast may go on.")
        h.hold(for: 0.3, frames: 18)
        XCTAssertEqual(h.viewport.phase, .idle)
        XCTAssertEqual(scrolling, [true, false, true, false])
        XCTAssertEqual(moving, [true, false, true, false])
    }

    /// The month on screen becomes ready: its photos, and those ahead, are asked for at once,
    /// without the grid moving.
    func testVisibleMonthReadinessDemandsThumbnailsWithoutAScroll() throws {
        let h = Harness(loaded: [])
        h.viewport.setNeedsDemand()
        h.hold(for: 0.02, frames: 1)
        let empty = try XCTUnwrap(h.windows.last)
        XCTAssertTrue(empty.ahead.isEmpty, "Nothing is known of the months yet.")
        XCTAssertFalse(h.frames.isRunning)
        let offset = h.collection.contentOffset.y

        // The first months arrive.
        h.loaded = [0, 1]
        h.viewport.contentChanged()
        XCTAssertTrue(h.frames.isRunning, "A demand waits for the next frame.")
        h.hold(for: 0.02, frames: 1)
        let ready = try XCTUnwrap(h.windows.last)
        XCTAssertEqual(h.windows.count, 2, "One demand, on the next frame.")
        XCTAssertEqual(Self.kind(ready.motion), "idle")
        XCTAssertFalse(ready.ahead.isEmpty, "The photos below the screen are asked for.")
        XCTAssertTrue(ready.ahead.allSatisfy { Harness.path($0.key.assetID).section == 0 }, "One screen ahead at rest, within the first month.")
        XCTAssertTrue(ready.behind.isEmpty, "Nothing lies above the top of the library.")
        XCTAssertEqual(h.collection.contentOffset.y, offset, "The grid did not move.")
        XCTAssertFalse(h.frames.isRunning)
    }

    /// Reversing direction turns the ahead window around, and the photos just passed are behind.
    func testTheWindowsFollowTheDirectionOfTravel() throws {
        let h = Harness()
        h.collection.contentOffset.y = h.screen * 10
        h.viewport.willBeginDragging()
        h.scroll(by: h.screen, over: 0.5, frames: 30)
        let down = try XCTUnwrap(h.windows.last)
        func frame(_ photo: ThumbnailBinder.Ahead) throws -> CGRect {
            try XCTUnwrap(h.layout.layoutAttributesForItem(at: Harness.path(photo.key.assetID))?.frame)
        }
        XCTAssertFalse(down.ahead.isEmpty)
        XCTAssertFalse(down.behind.isEmpty)
        XCTAssertTrue(try down.ahead.allSatisfy { try frame($0).maxY > down.visible.maxY }, "Ahead lies below the screen going down.")
        XCTAssertTrue(try down.behind.allSatisfy { try frame($0).minY < down.visible.minY }, "Behind lies above.")
        XCTAssertEqual(try down.ahead.map { try frame($0).minY }, try down.ahead.map { try frame($0).minY }.sorted(), "Nearest the screen first.")
        XCTAssertLessThanOrEqual(down.behind.count, GridViewport.behindLimit)

        h.scroll(by: -h.screen, over: 0.5, frames: 30)
        let up = try XCTUnwrap(h.windows.last)
        XCTAssertFalse(up.ahead.isEmpty)
        XCTAssertTrue(try up.ahead.allSatisfy { try frame($0).minY < up.visible.minY }, "Ahead lies above the screen going up.")
        XCTAssertTrue(try up.behind.allSatisfy { try frame($0).maxY > up.visible.maxY }, "Behind lies below.")
    }

    /// A slow scroll within the same rows sends no demand of its own; crossing into new rows does.
    func testDemandsGoOutOnlyWhenTheRowsOrTheMotionChange() {
        let h = Harness()
        h.viewport.willBeginDragging()
        h.scroll(by: 10, over: 0.2, frames: 12)
        let within = h.windows.count
        XCTAssertLessThanOrEqual(within, 2, "Ten points at a crawl: the first frame's demand, and the speed settling under the slow mark at most.")
        h.scroll(by: h.layout.itemSide + 1, over: 0.2, frames: 12)
        XCTAssertGreaterThan(h.windows.count, within, "Crossing a row asks for the new row.")
    }
}

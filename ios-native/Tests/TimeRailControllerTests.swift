import UIKit
import XCTest
@testable import Ilyich

/// The rail and the grid share one interaction model (REBUILD_ROADMAP.md T4): the edge pan hands
/// each move to the rail's controller in its own callback, and once the rail is open the grid has
/// moved before the callback returns, with no view update in between. The rail still opens before
/// the photos move (DESIGN 9).
@MainActor final class TimeRailControllerTests: XCTestCase {
    private static let screen = CGSize(width: 390, height: 844)

    /// The feed the rail scrubs: its months, and where the grid last said it was.
    @MainActor private final class Feed: TimeRailFeed {
        let buckets: [TimeBucket]
        let navigation = TimelinePosition()
        var cancelledNavigations = 0
        var requested: [(index: Int, item: Int)] = []
        init(buckets: [TimeBucket]) { self.buckets = buckets }
        func cancelPendingNavigation() { cancelledNavigations += 1 }
        func scrollToBucket(_ index: Int, item: Int) { requested.append((index, item)) }
    }

    /// Frames the test fires by hand, if at all.
    @MainActor private final class ManualFrames: ViewportFrames {
        var onFrame: ((TimeInterval) -> Void)?
        func start() {}
        func stop() {}
    }

    /// A grid of the feed's months that reports where it is on every scroll, as the library's
    /// grid does: the viewport hears of the scroll and the feed of the month on screen.
    @MainActor private final class Grid: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        let feed: Feed
        let viewport: GridViewport
        let collection: UICollectionView
        private(set) var scrolls = 0

        init(feed: Feed) {
            self.feed = feed
            let layout = VirtualPhotoLayout()
            layout.columns = 4
            collection = UICollectionView(frame: CGRect(origin: .zero, size: TimeRailControllerTests.screen), collectionViewLayout: layout)
            viewport = GridViewport(frames: ManualFrames(), now: { 0 })
            super.init()
            collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
            collection.dataSource = self
            collection.delegate = self
            collection.reloadData()
            collection.layoutIfNeeded()
            viewport.attach(collection)
        }

        func numberOfSections(in collectionView: UICollectionView) -> Int { feed.buckets.count }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { feed.buckets[section].count }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            scrolls += 1
            viewport.didScroll()
            let top = collection.contentOffset.y + collection.adjustedContentInset.top
            let rect = CGRect(x: 0, y: top, width: collection.bounds.width, height: collection.bounds.height)
            guard let first = (collection.collectionViewLayout.layoutAttributesForElements(in: rect) ?? [])
                .filter({ $0.representedElementCategory == .cell && $0.frame.maxY > top }).map(\.indexPath).min() else { return }
            feed.navigation.section = first.section
            feed.navigation.item = first.item
        }
    }

    /// Forty months of a hundred photos, newest first.
    private static func months() -> [TimeBucket] {
        (0..<40).map { index in
            TimeBucket(timeBucket: String(format: "%04d-%02d-01T00:00:00Z", 2026 - index / 12, 12 - index % 12), count: 100)
        }
    }

    /// The rail's layout: its top in the library and its tape's length.
    private static let layout = TimeRailController.Layout(top: 100, height: 600)

    /// The pan on the rail at `fraction` of the way down its tape.
    private static func pan(_ phase: UIGestureRecognizer.State, at fraction: CGFloat) -> LibraryEdgePan {
        let y = layout.top + 24 + fraction * layout.height
        return LibraryEdgePan(edge: .trailing, phase: phase, start: CGPoint(x: 380, y: y), location: CGPoint(x: 360, y: y),
                              translation: .zero)
    }

    /// A rail on screen whose opening the test finishes by hand.
    private func makeRail(_ grid: Grid) -> (TimeRailController, () -> Void) {
        let rail = TimeRailController(feed: grid.feed, viewport: grid.viewport)
        var openings: [() -> Void] = []
        rail.animateOpening = { _, change, completion in change(); openings.append(completion) }
        rail.layout = Self.layout
        rail.setBuckets(grid.feed.buckets)
        rail.appeared(UUID())
        return (rail, {
            let finished = openings
            openings.removeAll()
            finished.forEach { $0() }
        })
    }

    private func offset(_ grid: Grid, at fraction: CGFloat) throws -> CGFloat {
        try XCTUnwrap(grid.viewport.scroller.offset(atFraction: fraction)).rounded(.toNearestOrEven)
    }

    func testRailPanMovesTheGridSynchronously() throws {
        let grid = Grid(feed: Feed(buckets: Self.months()))
        let (rail, finishOpening) = makeRail(grid)
        let start = grid.collection.contentOffset.y

        // The finger touches the rail halfway down: the lens and the column open on the month
        // there, and the photos stay where they are until they are open.
        rail.handle(Self.pan(.began, at: 0.5))
        XCTAssertTrue(rail.expanded)
        XCTAssertEqual(grid.viewport.phase, .scrubbing, "The grid is the rail's while the finger is down.")
        XCTAssertEqual(grid.collection.contentOffset.y, start, "The photos wait for the rail to open.")
        let previewed = try XCTUnwrap(rail.selected, "The lens shows the month under the finger at once.")
        XCTAssertGreaterThan(previewed, 0)

        // Open: the photos go to the month under the finger at once.
        finishOpening()
        XCTAssertEqual(grid.collection.contentOffset.y, try offset(grid, at: 0.5))
        XCTAssertEqual(rail.selected, grid.feed.navigation.section, "The month shown is the one the grid reported.")

        // Each move of the finger has moved the grid before its callback returns: no run loop
        // turn, no view update, no frame in between.
        for fraction in [0.62, 0.8, 0.31, 0.05] as [CGFloat] {
            let scrolls = grid.scrolls
            rail.handle(Self.pan(.changed, at: fraction))
            XCTAssertEqual(grid.collection.contentOffset.y, try offset(grid, at: fraction), "At \(fraction) of the rail.")
            XCTAssertGreaterThan(grid.scrolls, scrolls, "The grid's own scroll delegate heard of it in the same callback.")
            XCTAssertEqual(rail.fingerY, 24 + fraction * Self.layout.height)
            XCTAssertEqual(rail.selected, grid.feed.navigation.section, "The month under the finger is the grid's month at \(fraction).")
            XCTAssertEqual(grid.viewport.phase, .scrubbing)
        }

        // The finger lifts: the grid stays where it was, and is the rail's no more.
        let lifted = grid.collection.contentOffset.y
        rail.handle(Self.pan(.ended, at: 0.05))
        XCTAssertEqual(grid.viewport.phase, .idle)
        XCTAssertFalse(rail.isScrubbing)
        XCTAssertEqual(grid.collection.contentOffset.y, lifted)
    }

    /// A touch lifted before the rail has opened moves nothing, even when the opening ends later.
    func testATouchLiftedBeforeTheRailOpensLeavesThePhotos() throws {
        let grid = Grid(feed: Feed(buckets: Self.months()))
        let (rail, finishOpening) = makeRail(grid)
        let start = grid.collection.contentOffset.y
        rail.handle(Self.pan(.began, at: 0.7))
        rail.handle(Self.pan(.changed, at: 0.72))
        XCTAssertEqual(grid.collection.contentOffset.y, start, "Before the rail is open only the lens follows the finger.")
        rail.handle(Self.pan(.ended, at: 0.72))
        finishOpening()
        XCTAssertEqual(grid.collection.contentOffset.y, start, "Letting go before the rail is open leaves the photos where they were.")
        XCTAssertEqual(grid.viewport.phase, .idle)
        XCTAssertEqual(grid.feed.cancelledNavigations, 0, "Nothing was dropped for a move that never happened.")
    }

    /// The perf scenarios scrub as a finger does once the rail is open, without waiting for it to
    /// open, so the grid moves on the frames it always did.
    func testADrivenScrubMovesTheGridAtOnce() throws {
        let grid = Grid(feed: Feed(buckets: Self.months()))
        let (rail, _) = makeRail(grid)
        var moving: [Bool] = []
        grid.viewport.onMotionChange = { moving.append($0) }
        rail.beginDrivenScrub(atFraction: 0.4)
        XCTAssertEqual(grid.collection.contentOffset.y, try offset(grid, at: 0.4))
        XCTAssertTrue(rail.expanded, "The lens follows a driven scrub as it does a finger.")
        XCTAssertEqual(rail.selected, grid.feed.navigation.section)
        XCTAssertEqual(grid.feed.cancelledNavigations, 1, "A jump on its way is dropped, as the rail drops one for a finger.")
        rail.drive(toFraction: 0.9)
        XCTAssertEqual(grid.collection.contentOffset.y, try offset(grid, at: 0.9))
        rail.endDrivenScrub()
        XCTAssertEqual(moving, [true, false], "Coverage waits while the driven finger is down, as for a real one.")
        XCTAssertEqual(grid.viewport.phase, .idle)
    }

    /// Without the grid on screen the rail asks the feed for the month under the finger.
    func testWithoutAGridTheRailAsksForTheMonth() {
        let feed = Feed(buckets: Self.months())
        let rail = TimeRailController(feed: feed, viewport: GridViewport(frames: ManualFrames(), now: { 0 }))
        rail.animateOpening = { _, change, completion in change(); completion() }
        rail.layout = Self.layout
        rail.setBuckets(feed.buckets)
        rail.appeared(UUID())
        rail.handle(Self.pan(.began, at: 0.5))
        XCTAssertEqual(feed.requested.map(\.index), [20], "Halfway down forty equal months is the twenty-first.")
        rail.handle(Self.pan(.ended, at: 0.5))
    }

    /// A pan that goes on after the rail left the screen is not the rail's any more, and the scrub
    /// it had ends with it.
    func testARailThatLeavesTheScreenLetsGoOfTheGrid() throws {
        let grid = Grid(feed: Feed(buckets: Self.months()))
        let (rail, finishOpening) = makeRail(grid)
        rail.handle(Self.pan(.began, at: 0.3))
        finishOpening()
        let shown = grid.collection.contentOffset.y
        rail.disappeared()
        XCTAssertEqual(grid.viewport.phase, .idle, "The grid is free again.")
        rail.handle(Self.pan(.changed, at: 0.9))
        XCTAssertEqual(grid.collection.contentOffset.y, shown, "A move after the rail left goes nowhere.")
    }
}

import UIKit

/// Frames for the viewport: the display link in the app, a clock a test drives by hand.
@MainActor protocol ViewportFrames: AnyObject {
    /// Called once per frame while running, with the frame's time on the display clock.
    var onFrame: ((TimeInterval) -> Void)? { get set }
    func start()
    func stop()
}

/// A display link that runs only while the viewport has something to do.
@MainActor final class DisplayLinkFrames: ViewportFrames {
    var onFrame: ((TimeInterval) -> Void)?
    /// Set and cleared on the main actor; read by deinit once nothing else holds this.
    private nonisolated(unsafe) var link: CADisplayLink?

    /// The link holds its target strongly, so it targets this stand-in and not the frames.
    @MainActor private final class Target: NSObject {
        weak var frames: DisplayLinkFrames?
        @objc func fire(_ link: CADisplayLink) { frames?.onFrame?(link.timestamp) }
    }

    func start() {
        guard link == nil else { return }
        let target = Target()
        target.frames = self
        let link = CADisplayLink(target: target, selector: #selector(Target.fire(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    deinit { link?.invalidate() }
}

/// How the grid moves and what it is about to show, for the thumbnail demand (REBUILD_ROADMAP.md
/// T3). The scroll delegate and the rail feed it: the rail's finger scrubs the grid through it
/// (T4), in the same gesture callback, so a drag and a scrub are one interaction model. It
/// measures the speed as a moving average in screens per second, knows where a fling will land
/// from the delegate's target, and asks the layout which photos are ahead in the direction of
/// travel (one to three screens, more the faster the grid moves), just behind (one screen) and
/// where the grid will land; the photos on screen come from the cells, through the binder. The
/// demand goes out at most once per frame, on a display link that runs only while the grid moves
/// or a demand waits, and again when the rows change under the grid without a scroll, as when a
/// month becomes ready. Where each band may come from is ViewportPolicy's, decided in the
/// scheduler from the motion the demand carries: while the rail scrubs or the grid is fast, only
/// where it will land may download.
@MainActor final class GridViewport {
    /// What moves the grid: nothing, a finger dragging it, the coast after a fling, or the rail.
    /// Unlike the motion, which is idle once the grid has stood still a moment, the phase lasts
    /// until the finger lifts or the coast ends.
    enum Phase: Equatable {
        case idle
        case dragging
        case decelerating
        case scrubbing
    }

    /// What the grid wants, as the layout lays it out.
    struct Windows {
        /// The screen, in the collection view's coordinates.
        let visible: CGRect
        /// The band the photos on screen are wanted on: visible, or target while the rail's finger
        /// rests on them, since that month is where the scrub lands.
        let visibleBand: DemandBand
        /// Ahead in the direction of travel, nearest the screen first.
        let ahead: [ThumbnailBinder.Ahead]
        /// Just passed, nearest the screen first.
        let behind: [ThumbnailBinder.Ahead]
        /// Where a fling will land, nearest its middle first.
        let target: [ThumbnailBinder.Ahead]
        /// The cell's short side in pixels, for the photos not on screen yet.
        let shortSide: Int
        let motion: Motion
    }

    /// The photo at an index path, as the grid's rows name it.
    var entry: (IndexPath) -> LibraryEntry? = { _ in nil }
    /// The cell's short side in pixels.
    var shortSide: () -> Int = { 128 }
    /// Receives the demand, at most once per frame.
    var submit: ((Windows) -> Void)?
    /// Told when the grid starts or stops moving by a drag, a fling or the rail, for work that
    /// waits for it to rest (coverage).
    var onMotionChange: ((Bool) -> Void)?
    /// Told when a drag or the fling after it starts or ends, for the rail's puck.
    var onScrollingChange: ((Bool) -> Void)?

    /// The grid's position, and moving it directly: the rail, the perf driver and the viewer's
    /// zoom go through this.
    let scroller = GridScrollController()

    /// How quickly the speed follows a change of pace.
    static let speedWindow: TimeInterval = 0.08
    /// A stop the delegate did not report (a fling whose end was missed) counts after this long.
    static let unreportedRestAfter: TimeInterval = 0.5
    /// Caps per window, nearest the screen first.
    static let aheadLimit = 150
    static let behindLimit = 60
    static let targetLimit = 80

    private weak var collection: UICollectionView?
    private let frames: any ViewportFrames
    private let now: () -> TimeInterval

    /// What moves the grid now.
    private(set) var phase: Phase = .idle
    /// A finger drags the grid, or it coasts after one: the puck shows.
    var isScrolling: Bool { phase == .dragging || phase == .decelerating }
    /// How the grid moves, as of the last frame.
    private(set) var motion: Motion = .idle(since: 0)
    /// Screens per second, averaged over about `speedWindow`.
    private(set) var speed = 0.0
    /// Down the library, toward older photos, is positive.
    private(set) var direction: CGFloat = 1
    private var lastOffset: CGFloat?
    private var lastTime: TimeInterval?
    /// When the offset last stopped changing; nil while it changes.
    private var stillSince: TimeInterval?
    /// The delegate said the grid stopped, or it has never moved: the next frame is idle without
    /// waiting out `restAfter`.
    private var stopped = true
    /// Where the fling in progress lands, as a content offset.
    private var flingTarget: CGFloat?
    private var demandPending = false
    private var lastSignature: Signature?
    private var running = false

    init(frames: any ViewportFrames = DisplayLinkFrames(), now: @escaping () -> TimeInterval = { CACurrentMediaTime() }) {
        self.frames = frames
        self.now = now
        frames.onFrame = { [weak self] time in self?.tick(time) }
    }

    func attach(_ collection: UICollectionView) {
        self.collection = collection
        scroller.collection = collection
    }

    /// Whether the frames run: while the grid moves, the rail scrubs or a demand waits.
    var isRunning: Bool { running }

    // MARK: Scroll delegate

    func didScroll() { wake() }

    func willBeginDragging() {
        flingTarget = nil
        stopped = false
        setPhase(.dragging)
        wake()
    }

    /// UIKit's velocity is in points per millisecond; `target` is where the deceleration ends.
    func willEndDragging(velocity: CGPoint, target: CGPoint) {
        guard let collection else { return }
        let pointsPerSecond = Double(velocity.y) * 1_000
        if abs(pointsPerSecond) > 1 {
            // The fling's own speed, instead of waiting for the average to catch up with it.
            speed = abs(pointsPerSecond) / Double(max(1, collection.bounds.height))
            direction = pointsPerSecond > 0 ? 1 : -1
        }
        flingTarget = abs(target.y - collection.contentOffset.y) > 1 ? target.y : nil
    }

    func didEndDragging(decelerate: Bool) {
        if phase != .scrubbing { setPhase(decelerate ? .decelerating : .idle) }
        if decelerate { wake() } else { rest() }
    }

    func didEndDecelerating() {
        if phase == .decelerating { setPhase(.idle) }
        rest()
    }

    func didEndScrollingAnimation() { rest() }

    // MARK: Rail

    /// The rail's finger is down: the grid is the rail's until it lifts. A fling it interrupts
    /// ends here, since setContentOffset stops a deceleration without the delegate saying so.
    func beginScrub() { setPhase(.scrubbing) }

    /// The finger moves the grid to `fraction` of the way down the library, at once, in the
    /// gesture's own callback.
    func scrub(toFraction fraction: CGFloat) { scroller.scroll(toFraction: fraction) }

    /// The finger lifted.
    func endScrub() {
        if phase == .scrubbing { setPhase(.idle) }
    }

    private func setPhase(_ next: Phase) {
        let previous = phase
        guard next != previous else { return }
        phase = next
        let wasScrolling = previous == .dragging || previous == .decelerating
        if wasScrolling != isScrolling { onScrollingChange?(isScrolling) }
        if (previous != .idle) != (next != .idle) { onMotionChange?(next != .idle) }
    }

    // MARK: Content

    /// The rows changed under the grid without a scroll (a month became ready, a reload, a new
    /// density): the windows are read again.
    func contentChanged() {
        lastSignature = nil
        setNeedsDemand()
    }

    /// Sends the demand on the next frame, however many cells changed before it.
    func setNeedsDemand() {
        demandPending = true
        wake()
    }

    // MARK: Frames

    private func wake() {
        guard !running else { return }
        running = true
        frames.start()
    }

    private func sleep() {
        running = false
        // The speed is measured over frames the link ran. The next frame has no time to measure
        // over, so a jump after a rest (the rail, a date, Show in timeline) is not a fast scroll.
        lastTime = nil
        frames.stop()
    }

    /// The delegate says the grid came to rest: whatever is on screen downloads now.
    private func rest() {
        stopped = true
        speed = 0
        flingTarget = nil
        lastOffset = collection?.contentOffset.y
        if stillSince == nil { stillSince = now() }
        setNeedsDemand()
    }

    private struct Signature: Equatable {
        var firstRow: Int
        var lastRow: Int
        var kind: Int
        var speedBand: Int
        var direction: CGFloat
        var aheadHalfScreens: Int
        var targetRow: Int?
        var visibleBand: DemandBand
        var shortSide: Int
    }

    private func tick(_ time: TimeInterval) {
        guard let collection, let layout = collection.collectionViewLayout as? VirtualPhotoLayout else { sleep(); return }
        let offset = collection.contentOffset.y
        let screen = Double(max(1, collection.bounds.height))
        if let lastOffset {
            let delta = Double(offset - lastOffset)
            if delta != 0 {
                direction = delta > 0 ? 1 : -1
                stillSince = nil
                stopped = false
            } else if stillSince == nil {
                stillSince = time
            }
            // Only across a frame the link ran: a jump across a sleep moved the grid, not fast.
            if let lastTime, time > lastTime {
                let dt = time - lastTime
                let alpha = 1 - exp(-dt / Self.speedWindow)
                speed += (abs(delta) / dt / screen - speed) * alpha
            }
        }
        lastOffset = offset
        lastTime = time

        let scrubbing = phase == .scrubbing
        let stillFor = stillSince.map { time - $0 } ?? 0
        let still = stopped || stillFor >= ViewportPolicy.restAfter
        let next: Motion
        if scrubbing {
            // The rail has the grid. A fling it interrupted ended without the delegate saying so
            // (setContentOffset stops a deceleration silently), and its landing screen is not where
            // the grid goes any more.
            flingTarget = nil
            next = .scrubbing
        } else if still && (phase != .decelerating || stillFor >= Self.unreportedRestAfter) {
            speed = 0
            flingTarget = nil
            // A coast whose end was never reported (a jump took the grid from it) is over.
            if phase == .decelerating { setPhase(.idle) }
            next = .idle(since: stillSince ?? time)
        } else if phase == .dragging {
            next = .tracking(speed: speed)
        } else if phase == .decelerating {
            next = .flinging(speed: speed)
        } else {
            // Moved by the rail, a jump or a perf scenario.
            next = .tracking(speed: speed)
        }
        motion = next
        // The month under a resting finger is where the scrub lands: it may download.
        let visibleBand: DemandBand = scrubbing && still ? .target : .visible

        let pitch = Double(max(1, layout.itemSide + 1))
        let bounds = collection.bounds
        let signature = Signature(
            firstRow: Int((Double(bounds.minY) / pitch).rounded(.down)), lastRow: Int((Double(bounds.maxY) / pitch).rounded(.down)),
            kind: Self.kind(next), speedBand: speed > ViewportPolicy.fastSpeed ? 2 : speed < ViewportPolicy.slowSpeed ? 0 : 1,
            direction: direction, aheadHalfScreens: Int((ViewportPolicy.aheadScreens(at: speed) * 2).rounded()),
            targetRow: flingTarget.map { Int((Double($0) / pitch).rounded(.down)) }, visibleBand: visibleBand, shortSide: shortSide())
        if demandPending || signature != lastSignature {
            demandPending = false
            lastSignature = signature
            submit?(windows(layout: layout, bounds: bounds, motion: next, visibleBand: visibleBand))
        }
        if case .idle = next, !scrubbing, !demandPending { sleep() }
    }

    private static func kind(_ motion: Motion) -> Int {
        switch motion {
        case .idle: 0
        case .tracking: 1
        case .flinging: 2
        case .scrubbing: 3
        }
    }

    // MARK: Windows

    private func windows(layout: VirtualPhotoLayout, bounds visible: CGRect, motion: Motion, visibleBand: DemandBand) -> Windows {
        let screen = max(1, visible.height)
        let ahead = CGFloat(ViewportPolicy.aheadScreens(at: speed)) * screen
        let behind = CGFloat(ViewportPolicy.behindScreens) * screen
        let aheadRect = direction > 0
            ? CGRect(x: 0, y: visible.maxY, width: visible.width, height: ahead)
            : CGRect(x: 0, y: visible.minY - ahead, width: visible.width, height: ahead)
        let behindRect = direction > 0
            ? CGRect(x: 0, y: visible.minY - behind, width: visible.width, height: behind)
            : CGRect(x: 0, y: visible.maxY, width: visible.width, height: behind)
        let center = CGPoint(x: visible.midX, y: visible.midY)
        let target = flingTarget.map { CGRect(x: 0, y: $0, width: visible.width, height: visible.height) }
        return Windows(visible: visible, visibleBand: visibleBand,
                       ahead: photos(in: aheadRect, layout: layout, from: center, limit: Self.aheadLimit),
                       behind: photos(in: behindRect, layout: layout, from: center, limit: Self.behindLimit),
                       target: target.map { photos(in: $0, layout: layout, from: CGPoint(x: $0.midX, y: $0.midY), limit: Self.targetLimit) } ?? [],
                       shortSide: shortSide(), motion: motion)
    }

    /// The photos the layout puts in `rect`, nearest `center` first, at most `limit`.
    private func photos(in rect: CGRect, layout: VirtualPhotoLayout, from center: CGPoint, limit: Int) -> [ThumbnailBinder.Ahead] {
        guard rect.height > 0, let attributes = layout.layoutAttributesForElements(in: rect) else { return [] }
        var result: [ThumbnailBinder.Ahead] = []
        for attribute in attributes where attribute.representedElementCategory == .cell && attribute.frame.intersects(rect) {
            guard let entry = entry(attribute.indexPath),
                  let photo = ThumbnailBinder.Ahead(entry, distance: hypot(attribute.frame.midX - center.x, attribute.frame.midY - center.y)) else { continue }
            result.append(photo)
        }
        result.sort { $0.distance < $1.distance }
        if result.count > limit { result.removeLast(result.count - limit) }
        return result
    }
}

import SwiftUI
import UIKit

/// What the rail needs of the feed it scrubs: its months, where the grid is, and its jumps.
@MainActor protocol TimeRailFeed: AnyObject {
    var buckets: [TimeBucket] { get }
    /// The month and photo at the top of the screen, as the grid last reported them.
    var navigation: TimelinePosition { get }
    /// Drops a jump still on its way, such as Show in timeline, before the rail moves the grid.
    func cancelPendingNavigation()
    /// Asks for a month by name, for when the grid is not there to be moved directly.
    func scrollToBucket(_ index: Int, item: Int)
}

extension LibraryStore: TimeRailFeed {}

/// The time rail's interaction (REBUILD_ROADMAP.md T4): where the finger is, the month under it,
/// whether the lens and the column are out, and the hold where the finger stops. The library's
/// edge pan hands each move to `handle` in the gesture's own callback, and once the rail is open
/// the move goes on to the grid at once (`GridViewport.scrub(toFraction:)`), so the rail and a
/// drag move the grid the same way, with no view update in between. The view draws this state
/// and sends taps; it holds none of it.
///
/// The behavior is DESIGN 9's: touching the rail opens the lens and the column first, showing the
/// month under the finger while the photos stay put, and the photos follow the finger only once
/// they are open; where the finger stops, the photos stay (TimeRailRest); lifting closes the rail
/// sooner and quicker than the puck leaves after scrolling, and the puck shows while the grid is
/// dragged or coasts.
@MainActor @Observable final class TimeRailController {
    /// Where the rail sits, in the library's coordinates, as its view last laid it out.
    struct Layout: Equatable {
        /// The rail's top, which the finger's height is measured from.
        var top: CGFloat = 0
        /// The tape's length: the rail's height less its 24-point ends.
        var height: CGFloat = 1
    }

    /// The lens and the column are out.
    private(set) var expanded = false
    /// The rail shows: the puck after a scroll, or the open column.
    private(set) var visible = true
    /// The finger's height on the rail while the lens follows it.
    private(set) var fingerY: CGFloat?
    /// The month under the finger, or chosen; nil follows the grid.
    private(set) var selected: Int?
    /// A year chosen on the column; the lens then shows the year.
    private(set) var yearSelection: Int?
    /// The feed's months, scaled by photo count.
    private(set) var scale = TimeRailScale(buckets: [])

    @ObservationIgnored let feed: any TimeRailFeed
    @ObservationIgnored let viewport: GridViewport
    @ObservationIgnored var layout = Layout()
    /// Set from the view's environment.
    @ObservationIgnored var reduceMotion = false
    /// Opens the lens and the column with the rail's spring, and calls back once they are out.
    /// Tests open them by hand.
    @ObservationIgnored var animateOpening: (_ animation: Animation?, _ change: () -> Void, _ completion: @escaping () -> Void) -> Void = { animation, change, completion in
        withAnimation(animation, change, completion: completion)
    }
    /// Takes the lens, the column and the puck away, and calls back once what melts back into the
    /// rail has gone. Tests close them by hand.
    @ObservationIgnored var animateClosing: (_ animation: Animation?, _ change: () -> Void, _ completion: @escaping () -> Void) -> Void = { animation, change, completion in
        withAnimation(animation, completionCriteria: .removed, change, completion: completion)
    }
    @ObservationIgnored var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// The finger is on the rail.
    @ObservationIgnored private(set) var isScrubbing = false
    /// The lens and the column have finished opening, so a move of the finger moves the photos.
    @ObservationIgnored private var railOpen = false
    /// Holds the place where the finger stops, so lifting it does not move the photos.
    @ObservationIgnored private var rest = TimeRailRest()
    @ObservationIgnored private var restTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    /// Counts the rail's closings, so a closing forgets the finger only if none came after it.
    @ObservationIgnored private var closings = 0
    /// The rail is on screen. A pan that goes on after it left is not its own any more.
    @ObservationIgnored private var presented = false
    /// The rail view last shown, which lives as long as the rail's own state used to.
    @ObservationIgnored private var shownView: UUID?

    init(feed: any TimeRailFeed, viewport: GridViewport) {
        self.feed = feed
        self.viewport = viewport
        viewport.onScrollingChange = { [weak self] scrolling in self?.gridScrolling(scrolling) }
    }

    isolated deinit {
        restTask?.cancel()
        dismissTask?.cancel()
    }

    private var showMotion: Animation? { reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.78) }

    // MARK: The view

    /// The rail view `view` came on screen. A rail put on screen anew (shelves or search closed)
    /// starts as a new one does, its puck out; one that only came back (the viewer closed over
    /// it) keeps where it was. Either way the puck fades after the usual pause.
    func appeared(_ view: UUID) {
        presented = true
        if view != shownView {
            shownView = view
            dismissTask?.cancel()
            restTask?.cancel(); restTask = nil
            expanded = false; visible = true; railOpen = false
            fingerY = nil; selected = nil; yearSelection = nil
            isScrubbing = false; rest = TimeRailRest()
        }
        scheduleDismiss()
    }

    /// The rail left the screen, perhaps under the finger, whose scrub ends there.
    func disappeared() {
        presented = false
        dismissTask?.cancel()
        restTask?.cancel(); restTask = nil
        guard isScrubbing else { return }
        isScrubbing = false
        rest.end()
        fingerY = nil
        viewport.endScrub()
    }

    func setBuckets(_ buckets: [TimeBucket]) { scale = TimeRailScale(buckets: buckets) }

    /// The month the lens shows: the one under the finger or chosen, or else the grid's.
    var activeIndex: Int { min(max(0, selected ?? feed.navigation.section), max(0, feed.buckets.count - 1)) }

    /// Where the accent line marks the position: under the finger while scrubbing, the grid's own
    /// position otherwise. What reads it (the lens, its bridge, the line and the trips) reads it
    /// while it melts back into the rail too, so it does not change as the rail closes: neither
    /// with the rail's state, nor before what places it has gone (`close`).
    func currentY(height: CGFloat) -> CGFloat { fingerY ?? puckY(height: height) }

    /// The lens and its bridge follow the finger, clear of the rail's ends.
    func lensY(_ y: CGFloat, size: CGSize) -> CGFloat { min(max(78, fingerY ?? y), size.height - 78) }

    /// Where the puck sits: on the grid's position, or a chosen month's. It never shows under a
    /// finger, so it does not follow one: a finger landing as it slides out leaves it in place.
    func puckY(height: CGFloat) -> CGFloat { puckFraction * height + 24 }

    /// Where a chosen month or year sits, while no finger is on the rail.
    private var chosenFraction: CGFloat? { selected != nil && fingerY == nil ? fraction(activeIndex) : nil }

    private var puckFraction: CGFloat { chosenFraction ?? gridFraction }

    /// How far down the timeline the grid is. The position is read so that a view reading this
    /// updates as the grid moves; the grid's own offset places it.
    var gridFraction: CGFloat {
        let before = scale.count(before: feed.navigation.section) + feed.navigation.item
        return viewport.scroller.fraction ?? min(1, max(0, CGFloat(before) / CGFloat(max(1, scale.totalCount))))
    }

    /// Months sit where the grid's layout puts them, so the rail and the photos agree.
    func fraction(_ index: Int) -> CGFloat { viewport.scroller.fraction(ofSection: index) ?? CGFloat(scale.fraction(before: index)) }

    func monthCenter(_ index: Int, height: CGFloat) -> CGFloat {
        let top = fraction(index), bottom = index + 1 < feed.buckets.count ? fraction(index + 1) : 1
        return 24 + (top + bottom) / 2 * height
    }

    // MARK: The finger

    /// One move of the finger on the rail, from the library's edge pan, in its own callback.
    func handle(_ pan: LibraryEdgePan) {
        guard presented else { return }
        let y = pan.location.y - layout.top
        switch pan.phase {
        case .began:
            Haptics.grabbed()
            RailScrubProbe.began()
            isScrubbing = true
            viewport.beginScrub()
            rest = TimeRailRest()
            _ = rest.move(to: y, at: now())
            // The lens and the column open first, showing the month under the finger, and the
            // photos move only once they are open, so you see where you are going.
            preview(at: y)
            open { [weak self] in
                guard let self, isScrubbing, let fingerY else { return }
                feed.cancelPendingNavigation()
                scrub(at: fingerY)
            }
        case .changed:
            guard isScrubbing else { return }
            // Once the finger has stopped, a small move waits a moment, and lifting the finger
            // meanwhile drops it: that is the roll of a lifting finger.
            guard let shown = rest.move(to: y, at: now()) else { holdMoves(); return }
            follow(shown)
        case .ended:
            // Lifting the finger closes it sooner and quicker than the rail fades after scrolling.
            lift(dismissAfter: .milliseconds(400), duration: 0.24)
        default:
            lift(dismissAfter: .zero, duration: 0.35)
        }
    }

    private func lift(dismissAfter delay: Duration, duration: TimeInterval) {
        RailScrubProbe.ended()
        isScrubbing = false
        viewport.endScrub()
        rest.end(); restTask?.cancel(); restTask = nil
        scheduleDismiss(delay: delay, duration: duration)
    }

    // MARK: Taps and choices

    /// A tap shows the rail on the grid's month for a few seconds.
    func tap() {
        reopen()
        visible = true
        open { }
        scheduleDismiss(delay: .seconds(3))
    }

    /// A year tapped on the column.
    func chooseYear(_ index: Int, year: Int) {
        Haptics.itemChosen()
        choose(index, year: year)
        scheduleDismiss(delay: .seconds(2))
    }

    /// VoiceOver's swipe up or down moves a month.
    func adjust(_ direction: AccessibilityAdjustmentDirection) {
        choose(min(feed.buckets.count - 1, max(0, activeIndex + (direction == .increment ? 1 : -1))))
    }

    private func choose(_ index: Int, year: Int? = nil) {
        guard feed.buckets.indices.contains(index) else { return }
        reopen()
        selected = index; yearSelection = year; expanded = true; visible = true
        if viewport.scroller.collection != nil {
            feed.cancelPendingNavigation()
            viewport.scroller.scroll(toSection: index, animated: false)
        } else { feed.scrollToBucket(index, item: 0) }
    }

    // MARK: Driven scrubs

    /// A scrub the perf scenarios make with their finger drive (-IlyichPerfDrive finger), as a
    /// finger's goes once the rail is open: the rail opens at once, the grid is the rail's, a jump
    /// on its way is dropped, and the grid goes to `fraction` of the way down the library, the
    /// lens and the month following as they do for a finger. Nothing waits for the opening, so the
    /// grid moves on the frames it always did.
    func beginDrivenScrub(atFraction fraction: CGFloat) {
        let y = 24 + min(1, max(0, fraction)) * layout.height
        RailScrubProbe.began()
        isScrubbing = true
        viewport.beginScrub()
        rest = TimeRailRest()
        restTask?.cancel(); restTask = nil
        preview(at: y)
        railOpen = true
        feed.cancelPendingNavigation()
        scrub(at: y)
    }

    /// The driven finger moves on.
    func drive(toFraction fraction: CGFloat) {
        guard isScrubbing else { return }
        scrub(at: 24 + min(1, max(0, fraction)) * layout.height)
    }

    /// The driven finger lifts.
    func endDrivenScrub() {
        guard isScrubbing else { return }
        lift(dismissAfter: .milliseconds(400), duration: 0.24)
    }

    // MARK: Opening, following and closing

    /// Opens the lens and the column, then runs `opened` once they are fully out.
    private func open(_ opened: @escaping () -> Void) {
        dismissTask?.cancel(); visible = true
        guard !expanded else { railOpen = true; opened(); return }
        animateOpening(showMotion, { self.expanded = true }) { [weak self] in
            guard let self, expanded else { return }
            railOpen = true; opened()
        }
    }

    /// While the lens opens it follows the finger and shows the month there, leaving the photos
    /// where they are.
    private func preview(at y: CGFloat) {
        reopen()
        dismissTask?.cancel(); visible = true
        fingerY = min(layout.height + 24, max(24, y))
        yearSelection = nil
        let target = monthIndex(atFraction: min(1, max(0, (y - 24) / layout.height)))
        if let target, selected != target { selected = target; Haptics.selectionChanged() }
    }

    /// The month whose stretch of the rail holds this fraction.
    private func monthIndex(atFraction value: CGFloat) -> Int? {
        guard !feed.buckets.isEmpty else { return nil }
        var low = 0, high = feed.buckets.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if fraction(middle) <= value { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Before the rail is open only the lens follows the finger; once it is, the photos do.
    private func follow(_ y: CGFloat) {
        if railOpen { scrub(at: y) } else { preview(at: y) }
    }

    /// A move held back after a stop is followed once it has waited, if the finger is still down.
    private func holdMoves() {
        guard restTask == nil else { return }
        restTask = Task { [weak self] in
            while let self, let due = rest.nextDue {
                try? await Task.sleep(for: .seconds(max(0, due - now())))
                guard !Task.isCancelled else { return }
                if let y = rest.due(at: now()) { follow(y) }
            }
            self?.restTask = nil
        }
    }

    /// The finger's height on the rail is the grid's position, continuously: no snapping to rows.
    private func scrub(at y: CGFloat) {
        dismissTask?.cancel(); visible = true
        if !expanded { withAnimation(showMotion) { expanded = true } }
        fingerY = min(layout.height + 24, max(24, y))
        let fraction = min(1, max(0, (y - 24) / layout.height))
        guard viewport.scroller.collection != nil else {
            if let position = scale.position(at: Double(fraction)) { feed.scrollToBucket(position.index, item: position.item) }
            return
        }
        if selected == nil { feed.cancelPendingNavigation() }
        viewport.scrub(toFraction: fraction)
        let index = feed.navigation.section
        if selected != index { selected = index; Haptics.selectionChanged() }
        yearSelection = nil
    }

    /// A drag of the grid shows the puck; once the grid rests, it fades.
    private func gridScrolling(_ scrolling: Bool) {
        guard presented else { return }
        if scrolling && !expanded {
            dismissTask?.cancel(); selected = nil; yearSelection = nil
            if !visible { withAnimation(showMotion) { visible = true } }
        } else if !scrolling && !isScrubbing { scheduleDismiss() }
    }

    private func scheduleDismiss(delay: Duration = .milliseconds(800), duration: TimeInterval = 0.35) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.close(duration: duration)
        }
    }

    /// The lens, the column and the puck go. The lens, its bridge, the line and the trips read the
    /// finger and the month themselves while they melt back into the rail, so those are forgotten
    /// only once they have gone: forgetting them first would move what is melting (DESIGN 9).
    private func close(duration: TimeInterval) {
        let melting = expanded
        closings += 1
        let closing = closings
        animateClosing(reduceMotion ? nil : .smooth(duration: duration), {
            self.expanded = false; self.visible = false
        }) { [weak self] in
            guard let self, closing == closings, !expanded else { return }
            forgetPosition()
        }
        railOpen = false
        if !melting { forgetPosition() }
    }

    /// The finger, the month under it or chosen, and a chosen year go: the rail shows the grid's.
    private func forgetPosition() {
        selected = nil; yearSelection = nil; fingerY = nil
    }

    /// The rail is used again, perhaps before its last closing ended: what that closing would
    /// have forgotten goes now, so the rail opens on the grid's position as after any closing.
    private func reopen() {
        if !expanded { forgetPosition() }
    }
}

/// Where the finger stops on the rail, the photos stay. Once it has rested a moment, a move close
/// by reaches the photos only after waiting a little with the finger still down, so the roll of a
/// lifting finger never moves them. A move further away is followed at once.
struct TimeRailRest {
    /// A rest this long holds the place. It is longer than a glance at the lens mid-scrub, which
    /// takes about a quarter of a second, and shorter than a long press (0.4 to 0.5 s), so a stop
    /// holds even when the finger lifts soon after it.
    static let holdAfter: TimeInterval = 0.35
    /// Moves this close to where the finger stopped still count as resting: tremor and touch noise,
    /// about a millimeter.
    static let restRadius: CGFloat = 6
    /// After a rest, moves this close wait before the photos follow. A lifting finger's contact
    /// rolls a few millimeters at most; this is about four.
    static let holdRadius: CGFloat = 24
    /// How long such a move waits. A lifting finger rolls off well within it.
    static let delay: TimeInterval = 0.15

    private var restY: CGFloat?
    private var restSince: TimeInterval = 0
    private var waiting: [(time: TimeInterval, y: CGFloat)] = []

    /// The finger moved to `y`. Returns where to follow it now, or nil while the move waits.
    mutating func move(to y: CGFloat, at time: TimeInterval) -> CGFloat? {
        if let restY, time - restSince >= Self.holdAfter, abs(y - restY) <= Self.holdRadius {
            waiting.append((time, y))
            return nil
        }
        waiting.removeAll()
        if restY.map({ abs(y - $0) > Self.restRadius }) ?? true { restY = y; restSince = time }
        return y
    }

    /// When the next waiting move is due.
    var nextDue: TimeInterval? { waiting.first.map { $0.time + Self.delay } }

    /// The latest waiting move that has waited long enough, if any.
    mutating func due(at time: TimeInterval) -> CGFloat? {
        guard let index = waiting.lastIndex(where: { $0.time + Self.delay <= time }) else { return nil }
        let move = waiting[index]
        waiting.removeFirst(index + 1)
        // Settling further off starts a new rest there.
        if let restY, abs(move.y - restY) > Self.restRadius { self.restY = move.y; restSince = move.time }
        return move.y
    }

    /// The finger lifted: what still waits is the roll of the lift, and is dropped.
    mutating func end() {
        restY = nil
        waiting.removeAll()
    }
}

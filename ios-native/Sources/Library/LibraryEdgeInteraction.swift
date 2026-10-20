import SwiftUI
import UIKit

enum LibraryEdge: Equatable, Sendable { case leading, trailing }

struct LibraryEdgePan: Equatable {
    let edge: LibraryEdge
    let phase: UIGestureRecognizer.State
    let start: CGPoint
    let location: CGPoint
    let translation: CGSize
    var velocity: CGSize = .zero
}

/// What a move of the finger asks the shelves to do.
enum LibraryShelfEvent: Equatable {
    case none
    /// The glow at this row's tip peaked.
    case open(Int)
    /// The finger reached the left edge inside a group, or while reordering.
    case back
}

/// The row carried by its handle while reordering, and the place it would drop into.
struct LibraryShelfCarry: Equatable {
    let from: Int
    var to: Int
    var y: CGFloat
}

/// The shelves are one swiper under one finger: sliding along the edge highlights rows, staying by
/// a row's tip builds a glow that opens it, and the left edge goes back or puts the shelves away.
/// Lifting over the reorder button past a row's tip reorders people or albums; lifting anywhere
/// else puts the shelves away.
@MainActor @Observable final class LibraryEdgeInteraction {
    /// Center of the first shelf row. Shelves open with the starting row under the finger.
    var shelfTop: CGFloat = 0
    /// The wave stays where the finger last was.
    var shelfFinger: CGPoint?
    var highlighted: Int?
    var shelfReveal: CGFloat = 1
    var isShelfDragging = false
    /// The finger moved in and came back over the left edge. Lifting there puts the shelves away.
    var isCancelling = false
    /// The blue glow at the highlighted row's tip. It builds while the finger stays near the tip,
    /// falls away when the finger moves back, and opens the row at its peak.
    var openProgress: CGFloat = 0
    /// How near the highlighted row's tip the finger is, for a faint hint before the glow builds.
    var tipNearness: CGFloat = 0
    /// Set when a row's glow peaks; the library opens that row and clears this.
    var openReady: Int?
    /// The row a sideways push has taken hold of; the wave stays on it while the finger drifts.
    var selectionHold: Int?
    /// People or albums at one level with drag handles.
    var isRearranging = false
    /// The finger is over the reorder button past the focused row's tip; lifting there reorders.
    var overReorder = false
    /// The person or album row rising into the filter tag as the shelves close, and the tag's
    /// size it takes on the way.
    var morphingID: String?
    var morphSize: CGSize?
    var carried: LibraryShelfCarry?
    var timePan: LibraryEdgePan?
    @ObservationIgnored private var stroke: LibraryShelfStroke?
    @ObservationIgnored private var glowTask: Task<Void, Never>?
    @ObservationIgnored private var glowEnabled = false
    @ObservationIgnored private var lastLayout: LibraryShelfGeometry?
    /// Scrolls a long list while a carried row is held near the top or bottom of the band.
    @ObservationIgnored private var carryScroll: Task<Void, Never>?
    /// A long list being reordered coasts after a flick and springs back from past its ends.
    @ObservationIgnored private var momentum: LibraryShelfMomentum?
    private let frames = LibraryShelfFrameClock()
    /// Scrolls a long list while the finger stays near the top or bottom of the band.
    private let edgeScroll = LibraryShelfFrameClock()
    /// The last finger to land stopped a coasting list, so its tap does nothing else.
    @ObservationIgnored private var caughtScroll = false

    func beginStroke(at point: CGPoint) {
        stroke = LibraryShelfStroke(startY: point.y, startTop: shelfTop, anchorX: point.x)
        isShelfDragging = true
        selectionHold = nil
    }

    /// Continues the stroke on a level that just opened or closed under the finger. The row now
    /// under the finger is highlighted at once, but cannot open until it is swiped again.
    /// A level that opened under the finger near a row's tip makes that row wait for the finger
    /// to come back before it glows; going back to the edge does not.
    func rebase(at point: CGPoint, armed: Bool, in layout: LibraryShelfGeometry, needsReturn: Bool = true) {
        edgeScroll.stop()
        var layout = layout
        layout.top = shelfTop
        lastLayout = layout
        highlighted = layout.pickedRow(atY: point.y)
        shelfFinger = point
        stroke = LibraryShelfStroke(startY: point.y, startTop: shelfTop, isArmed: armed, row: highlighted,
                                    anchorX: point.x, highX: point.x, needsReturn: needsReturn)
        isShelfDragging = true
        selectionHold = nil
        resetGlow()
    }

    /// `reorder` offers the reorder button past the focused row's tip, in People and Albums.
    /// `selected` is the row already chosen, which never activates again.
    func moveStroke(to point: CGPoint, in layout: LibraryShelfGeometry, nested: Bool, reorder: Bool = false, selected: Int? = nil) -> LibraryShelfEvent {
        guard var stroke else { return .none }
        var layout = layout
        // The way the finger is going, smoothed over the last few moves, so a push toward the
        // tips reads as sideways even when the thumb arcs a little.
        if let last = stroke.last {
            stroke.motion = CGVector(dx: stroke.motion.dx * 0.6 + (point.x - last.x) * 0.4,
                                     dy: stroke.motion.dy * 0.6 + (point.y - last.y) * 0.4)
        }
        stroke.last = point
        // The rows stand still under the finger, so it moves one row per row height anywhere in
        // the list; only holding it near the band's top or bottom scrolls them.
        layout.top = shelfTop
        lastLayout = layout
        shelfFinger = point
        // A stroke that begins near the band's top or bottom scrolls only once the finger goes
        // deeper, so a list never runs off under a finger that has not moved.
        let depth = layout.scrollDepth(fingerY: point.y)
        stroke.topFloor = LibraryShelfGeometry.scrollFloor(stroke.topFloor, depth: depth.top)
        stroke.bottomFloor = LibraryShelfGeometry.scrollFloor(stroke.bottomFloor, depth: depth.bottom)
        if point.x > LibraryShelfGeometry.cancelWidth + 24 { stroke.isArmed = true }
        let atEdge = stroke.isArmed && point.x < LibraryShelfGeometry.cancelWidth
        if atEdge && nested {
            // Inside a group the edge goes back a level; moving in again re-arms it.
            stroke.isArmed = false
            self.stroke = stroke
            overReorder = false
            return .back
        }
        if atEdge != isCancelling {
            isCancelling = atEdge
            // The fan folds back toward the edge while lifting would put it away.
            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .snappy(duration: 0.2)) { shelfReveal = atEdge ? 0.4 : 1 }
        }
        var row = atEdge ? nil : layout.pickedRow(atY: point.y)
        // A held row stays chosen while the finger drifts, until it is a row away or the finger
        // moves back from the tip.
        if let held = stroke.held {
            if row == nil || point.x < stroke.highX - 12 || !layout.indices.contains(held)
                || abs(point.y - layout.center(held)) > layout.step * LibraryShelfGeometry.holdReach {
                stroke.held = nil
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .snappy(duration: 0.18)) { selectionHold = nil }
            } else {
                row = held
            }
        }
        row = settle(row, at: point, in: layout, stroke: &stroke)
        // Moving back lets the glow fall away; a fresh push toward the tip starts it again.
        if point.x < stroke.highX - 12 {
            stroke.anchorX = point.x; stroke.highX = point.x
            stroke.pushed = false; stroke.opened = false; stroke.needsReturn = false
        }
        stroke.anchorX = min(stroke.anchorX, point.x)
        stroke.highX = max(stroke.highX, point.x)
        // A push toward the tip arms the glow, so sliding up and down never opens rows. Right after
        // a level opens under the finger, its row waits for the finger to come back first.
        if !stroke.needsReturn, point.x - stroke.anchorX >= 24 { stroke.pushed = true }
        let tip = layout.maximumWidth
        // A push toward the tips, more sideways than up or down, along a row's outer part takes
        // hold of that row and starts its selection at once; a scrolling list waits for it.
        let sideways = stroke.motion.dx > 0 && stroke.motion.dx >= abs(stroke.motion.dy)
        if stroke.held == nil, sideways, let row, row != selected, !stroke.needsReturn, !stroke.opened,
           point.x >= tip * LibraryShelfGeometry.holdZoneStart, point.x <= tip + LibraryShelfGeometry.tipSlack {
            stroke.held = row
            stroke.pushed = true
            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .snappy(duration: 0.18)) { selectionHold = row }
        }
        // Past the row's right edge the row stays focused but its glow ends.
        glowEnabled = row != nil && row != selected && stroke.pushed && !stroke.opened && point.x <= tip + LibraryShelfGeometry.tipSlack
        tipNearness = glowEnabled ? LibraryShelfGeometry.tipNearness(fingerX: point.x, tip: tip) : 0
        if tipNearness > 0 || openProgress > 0 { startGlow() }
        let over = reorder && row.map { LibraryShelfGeometry.isOverReorderButton(point, tip: tip, rowCenter: layout.center($0)) } == true
        if over != overReorder {
            overReorder = over
            if over { Haptics.selectionChanged() }
        }
        self.stroke = stroke
        updateEdgeScroll()
        return .none
    }

    /// Highlights `row`, the one under the finger. The current row holds a little past its edge,
    /// so a long list can be read one row at a time, and a new row starts its swipe afresh.
    private func settle(_ row: Int?, at point: CGPoint, in layout: LibraryShelfGeometry, stroke: inout LibraryShelfStroke) -> Int? {
        var row = row
        if stroke.held == nil, let current = highlighted, row != nil, row != current, layout.indices.contains(current),
           abs(point.y - layout.center(current)) < layout.step * (0.5 + LibraryShelfGeometry.rowLock) { row = current }
        if row != highlighted {
            highlighted = row
            Haptics.selectionChanged()
        }
        if row != stroke.row {
            stroke.row = row; stroke.anchorX = point.x; stroke.highX = point.x
            stroke.pushed = false; stroke.opened = false; stroke.needsReturn = false
            resetGlow()
        }
        return row
    }

    func endStroke() {
        stroke = nil; isShelfDragging = false; isCancelling = false
        selectionHold = nil
        resetGlow()
        overReorder = false
        carryScroll?.cancel(); carryScroll = nil
        edgeScroll.stop()
        stopCoasting()
    }

    // MARK: Scrolling a long list

    /// The list's speed with the finger where it is, in points per second: only near the band's
    /// top or bottom with the finger over the rows, and never while a row is held.
    private func edgeScrollVelocity() -> CGFloat {
        guard let stroke, stroke.held == nil, !isCancelling, let finger = shelfFinger, let layout = lastLayout,
              finger.x >= LibraryShelfGeometry.cancelWidth, finger.x <= layout.maximumWidth + LibraryShelfGeometry.tipSlack else { return 0 }
        return layout.scrollVelocity(fingerY: finger.y, topFloor: stroke.topFloor ?? 0, bottomFloor: stroke.bottomFloor ?? 0)
    }

    private func updateEdgeScroll() {
        guard edgeScrollVelocity() != 0 else { edgeScroll.stop(); return }
        edgeScroll.run { [weak self] seconds in self?.scrollFrame(seconds) ?? false }
    }

    /// Moves the list on by one frame, highlighting the rows in turn as they pass under the still
    /// finger. False once it stops.
    private func scrollFrame(_ seconds: CGFloat) -> Bool {
        let velocity = edgeScrollVelocity()
        guard velocity != 0, var stroke, let finger = shelfFinger, var layout = lastLayout else { return false }
        let top = layout.clampedTop(shelfTop + velocity * seconds)
        guard top != shelfTop else { return false }
        shelfTop = top
        layout.top = top
        lastLayout = layout
        _ = settle(layout.pickedRow(atY: finger.y), at: finger, in: layout, stroke: &stroke)
        self.stroke = stroke
        return true
    }

    private func placeCarry(at point: CGPoint, in layout: LibraryShelfGeometry) {
        guard var carry = carried else { return }
        let target = min(max(0, Int(((point.y - layout.top) / layout.step).rounded())), max(0, layout.count - 1))
        carry.y = min(max(point.y, layout.minCenter), layout.maxCenter)
        if target != carry.to { carry.to = target; Haptics.selectionChanged() }
        carried = carry
    }

    private func updateCarryScroll(at point: CGPoint, in layout: LibraryShelfGeometry) {
        let edge: CGFloat = 70
        let speed: CGFloat = point.y < layout.minCenter + edge ? (layout.minCenter + edge - point.y) / edge
            : point.y > layout.maxCenter - edge ? -(point.y - (layout.maxCenter - edge)) / edge : 0
        guard speed != 0, !layout.fits else { carryScroll?.cancel(); carryScroll = nil; return }
        guard carryScroll == nil else { return }
        carryScroll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled, let finger = self.shelfFinger, var layout = self.lastLayout else { return }
                let near: CGFloat = finger.y < layout.minCenter + edge ? min(1, (layout.minCenter + edge - finger.y) / edge)
                    : finger.y > layout.maxCenter - edge ? -min(1, (finger.y - (layout.maxCenter - edge)) / edge) : 0
                guard near != 0 else { self.carryScroll = nil; return }
                self.shelfTop = layout.clampedTop(self.shelfTop + near * 9)
                layout.top = self.shelfTop
                self.placeCarry(at: finger, in: layout)
            }
        }
    }

    // MARK: The glow at a row's tip

    private func resetGlow() {
        glowTask?.cancel(); glowTask = nil
        glowEnabled = false
        if tipNearness != 0 { tipNearness = 0 }
        if openProgress != 0 { openProgress = 0 }
        Haptics.stopBuildUp()
    }

    /// The glow runs on its own clock, so it keeps building while the finger holds still.
    private func startGlow() {
        guard glowTask == nil else { return }
        glowTask = Task { [weak self] in
            var last = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                let now = CACurrentMediaTime()
                if self.stepGlow(seconds: CGFloat(min(0.1, now - last))) { return }
                last = now
            }
        }
    }

    /// Returns true when the glow has nothing more to do.
    private func stepGlow(seconds: CGFloat) -> Bool {
        let building = glowEnabled && tipNearness > 0
        openProgress = LibraryShelfGeometry.nextGlow(openProgress, nearness: tipNearness, building: building, seconds: seconds)
        if openProgress >= 1, let row = highlighted {
            stroke?.opened = true
            glowEnabled = false; tipNearness = 0; openProgress = 0
            glowTask = nil
            Haptics.released()
            openReady = row
            return true
        }
        // The rumble follows the glow up, and down as it falls away.
        Haptics.buildUp(openProgress)
        if openProgress == 0 && !building { glowTask = nil; return true }
        return false
    }

    // MARK: Reordering

    /// While reordering, a stroke that starts on a row's handle carries that row.
    func beginRearrangeStroke(at point: CGPoint, in layout: LibraryShelfGeometry) {
        stopCoasting()
        var layout = layout
        layout.top = shelfTop
        lastLayout = layout
        // A list caught past an end picks up as far out as the finger would have pulled it.
        stroke = LibraryShelfStroke(startY: point.y, startTop: layout.unbandedTop(shelfTop), anchorX: point.x)
        isShelfDragging = true
        if point.x < LibraryShelfGeometry.handleWidth, let row = layout.row(atY: point.y) {
            carried = LibraryShelfCarry(from: row, to: row, y: point.y)
            Haptics.grabbed()
        }
    }

    /// A carried row follows the finger and the rest make room for it; any other stroke scrolls
    /// the list, and the left edge finishes reordering.
    func moveRearrangeStroke(to point: CGPoint, in layout: LibraryShelfGeometry) -> LibraryShelfEvent {
        guard var stroke else { return .none }
        var layout = layout
        layout.top = shelfTop
        lastLayout = layout
        shelfFinger = point
        if carried != nil {
            // The list holds still under a carried row and scrolls by itself near the band's ends.
            placeCarry(at: point, in: layout)
            updateCarryScroll(at: point, in: layout)
            return .none
        }
        // Reordering scrolls like any list: the rows move with the finger and stretch past the ends.
        shelfTop = layout.rubberBandedTop(stroke.startTop + point.y - stroke.startY)
        if point.x > LibraryShelfGeometry.cancelWidth + 24 { stroke.isArmed = true }
        if stroke.isArmed && point.x < LibraryShelfGeometry.cancelWidth {
            stroke.isArmed = false
            self.stroke = stroke
            return .back
        }
        self.stroke = stroke
        return .none
    }

    /// Lifting the finger from a list being scrolled lets it coast on and slow down as a scroll
    /// view does, or spring back from past an end.
    func releaseRearrangeStroke(velocity: CGFloat) {
        endStroke()
        guard let layout = lastLayout, !layout.fits else { return }
        coast(LibraryShelfMomentum(top: shelfTop, velocity: velocity, range: layout.scrollRange))
    }

    /// A finger landing while reordering stops a coasting list where it is, as on a scroll view.
    func touchDown() {
        caughtScroll = momentum != nil
        stopCoasting()
    }

    /// With no stroke under way, a list left stretched past an end springs back.
    func settleScroll() {
        guard stroke == nil, momentum == nil, let layout = lastLayout, !layout.fits,
              !layout.scrollRange.contains(shelfTop) else { return }
        coast(LibraryShelfMomentum(top: shelfTop, velocity: 0, range: layout.scrollRange))
    }

    /// True once after a finger stopped a coasting list, so its tap does nothing else.
    func consumeScrollCatch() -> Bool {
        defer { caughtScroll = false }
        return caughtScroll
    }

    private func coast(_ start: LibraryShelfMomentum) {
        momentum = start
        frames.run { [weak self] seconds in
            guard let self, var momentum = self.momentum else { return false }
            let moving = momentum.step(seconds)
            self.shelfTop = momentum.top
            self.momentum = moving ? momentum : nil
            return moving
        }
    }

    private func stopCoasting() {
        frames.stop()
        momentum = nil
    }
}

/// A reordering list let go keeps coasting and slows down as a scroll view does, and springs back
/// to its end when it is let go, or coasts, past one.
struct LibraryShelfMomentum {
    private(set) var top: CGFloat
    private(set) var velocity: CGFloat
    let range: ClosedRange<CGFloat>

    /// A scroll view's normal deceleration: the speed kept after each millisecond.
    static let deceleration: CGFloat = 0.998
    /// The spring back to an end, critically damped: it settles in about half a second.
    static let springRate: CGFloat = 16

    init(top: CGFloat, velocity: CGFloat, range: ClosedRange<CGFloat>) {
        self.top = top
        self.range = range
        // Let go past an end, a flick farther out does not stretch the list more.
        let end = Self.end(of: top, in: range)
        self.velocity = end.map { (top - $0) * velocity > 0 ? 0 : velocity } ?? velocity
    }

    /// Moves on by `seconds`; false once the list has come to rest. Small fixed steps keep the
    /// motion the same at any frame rate.
    mutating func step(_ seconds: CGFloat) -> Bool {
        var left = seconds
        while left > 0 {
            let slice = min(left, 1.0 / 240)
            if !advance(slice) { return false }
            left -= slice
        }
        return true
    }

    private mutating func advance(_ seconds: CGFloat) -> Bool {
        if let end = Self.end(of: top, in: range) {
            let rate = Self.springRate
            velocity += (-rate * rate * (top - end) - 2 * rate * velocity) * seconds
            top += velocity * seconds
            if abs(top - end) < 0.5 && abs(velocity) < 20 { top = end; velocity = 0; return false }
            return true
        }
        velocity *= pow(Self.deceleration, seconds * 1000)
        top += velocity * seconds
        // Coasting past an end, the list runs on a little before springing back.
        if Self.end(of: top, in: range) != nil { velocity = min(max(velocity, -2500), 2500); return true }
        if abs(velocity) < 10 { velocity = 0; return false }
        return true
    }

    private static func end(of top: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat? {
        top > range.upperBound ? range.upperBound : top < range.lowerBound ? range.lowerBound : nil
    }
}

/// Ticks once per screen refresh while a reordering list coasts.
@MainActor private final class LibraryShelfFrameClock: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frame: ((CGFloat) -> Bool)?

    /// `frame` gets the seconds since the last tick and returns false once nothing moves.
    func run(_ frame: @escaping (CGFloat) -> Bool) {
        self.frame = frame
        guard link == nil else { return }
        last = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate(); link = nil; frame = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let seconds = last == 0 ? 1.0 / 60 : min(0.05, link.timestamp - last)
        last = link.timestamp
        if frame?(CGFloat(seconds)) != true { stop() }
    }
}

/// Every finger landing on the shelves while reordering, as a scroll view feels it: it stops a
/// coasting list, and lifting lets a stretched one spring back. It never takes the touch.
struct LibraryShelfTouch: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let onDown: () -> Void
    let onUp: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let touch = UILongPressGestureRecognizer()
        touch.minimumPressDuration = 0
        touch.allowableMovement = .greatestFiniteMagnitude
        touch.cancelsTouchesInView = false
        touch.delaysTouchesBegan = false
        touch.delaysTouchesEnded = false
        touch.delegate = context.coordinator
        updateUIGestureRecognizer(touch, context: context)
        return touch
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began: onDown()
        case .ended, .cancelled, .failed: onUp()
        default: break
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

/// A directional native pan rejects vertical scrolling before recognition.
/// It observes the library itself, so a transparent overlay cannot eat photo taps.
struct LibraryEdgePanGesture: UIGestureRecognizerRepresentable {
    /// Matches the time rail's width, so starting anywhere on the visible rail works.
    static let edgeWidth: CGFloat = 44
    let size: CGSize
    let activeY: ClosedRange<CGFloat>
    let leadingEnabled: Bool
    let trailingEnabled: Bool
    let enabled: Bool
    let onChange: (LibraryEdgePan) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        updateUIGestureRecognizer(pan, context: context)
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
        context.coordinator.size = size
        context.coordinator.activeY = activeY
        context.coordinator.leadingEnabled = leadingEnabled
        context.coordinator.trailingEnabled = trailingEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard let edge = context.coordinator.edge,
              let points = context.coordinator.points(for: recognizer) else { return }
        let location = points.location
        let start = points.start
        let velocity = recognizer.view.map { recognizer.velocity(in: $0) } ?? .zero
        onChange(.init(edge: edge, phase: recognizer.state,
                       start: start, location: location,
                       translation: CGSize(width: location.x - start.x, height: location.y - start.y),
                       velocity: CGSize(width: velocity.x, height: velocity.y)))
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let converter: CoordinateSpaceConverter
        var size = CGSize.zero
        var activeY: ClosedRange<CGFloat> = 0...0
        var leadingEnabled = false
        var trailingEnabled = false
        var edge: LibraryEdge?
        init(converter: CoordinateSpaceConverter) { self.converter = converter }

        func points(for pan: UIPanGestureRecognizer) -> (start: CGPoint, location: CGPoint)? {
            guard let view = pan.view else { return nil }
            let location = pan.location(in: view)
            let translation = pan.translation(in: view)
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            // The bridge's gesture-derived translation need not be populated
            // during shouldBegin. Convert the native recognizer's own points.
            return (converter.convert(globalPoint: view.convert(start, to: nil)),
                    converter.convert(globalPoint: view.convert(location, to: nil)))
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let points = points(for: pan) else { return false }
            let start = points.start
            let movement = CGPoint(x: points.location.x - start.x, y: points.location.y - start.y)
            guard activeY.contains(start.y) else { return false }
            // Only an inward move opens the shelves; sliding along the edge first scrolls the grid.
            if leadingEnabled, start.x <= LibraryEdgePanGesture.edgeWidth, movement.x > 0, movement.x >= abs(movement.y) * 0.7 {
                edge = .leading; return true
            }
            if trailingEnabled, start.x >= size.width - LibraryEdgePanGesture.edgeWidth,
               movement.x < 0 || abs(movement.y) > abs(movement.x) { edge = .trailing; return true }
            edge = nil
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Edge pans get the first directional decision. A vertical pan fails
            // immediately above, leaving the collection view's scrolling intact.
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}

struct LibraryShelfGeometry {
    let count: Int
    let step: CGFloat
    /// Row centers stay inside this band, clear of the header and the search bar.
    let minCenter: CGFloat
    let maxCenter: CGFloat
    /// Center of the first row.
    var top: CGFloat
    let maximumWidth: CGFloat
    let restingWidth: CGFloat

    init(count: Int, size: CGSize, topInset: CGFloat, bottomInset: CGFloat, top: CGFloat? = nil, rowStep: CGFloat? = nil) {
        self.count = count
        let available = max(44, size.height - topInset - bottomInset)
        step = rowStep ?? min(60, max(44, available / CGFloat(max(1, count))))
        minCenter = topInset + 28
        maxCenter = max(topInset + 28, size.height - bottomInset - 28)
        self.top = top ?? topInset + 28
        // Short enough that the thumb reaches past a row's tip without stretching to the far edge.
        maximumWidth = min(244, size.width * 0.62)
        restingWidth = min(64, maximumWidth)
    }

    var span: CGFloat { CGFloat(max(0, count - 1)) * step }

    /// Keeps a scrolled list's ends inside the band; a list that fits stays where it is.
    func clampedTop(_ value: CGFloat) -> CGFloat {
        guard !fits else { return top }
        return min(max(value, maxCenter - span), minCenter)
    }

    /// Where a long list comes to rest: its first row no lower than the band's top, its last no
    /// higher than the band's bottom.
    var scrollRange: ClosedRange<CGFloat> { min(maxCenter - span, minCenter)...minCenter }

    /// Past either end a list follows the finger ever less, as a scroll view's content stretches.
    /// A list that fits stays where it is.
    func rubberBandedTop(_ value: CGFloat) -> CGFloat {
        guard !fits else { return top }
        let range = scrollRange, length = stretchLength
        if value > range.upperBound { return range.upperBound + Self.stretch(value - range.upperBound, over: length) }
        if value < range.lowerBound { return range.lowerBound - Self.stretch(range.lowerBound - value, over: length) }
        return value
    }

    /// The unstretched position of a list shown at `shown`, the inverse of `rubberBandedTop`.
    func unbandedTop(_ shown: CGFloat) -> CGFloat {
        guard !fits else { return shown }
        let range = scrollRange, length = stretchLength
        if shown > range.upperBound { return range.upperBound + Self.unstretch(shown - range.upperBound, over: length) }
        if shown < range.lowerBound { return range.lowerBound - Self.unstretch(range.lowerBound - shown, over: length) }
        return shown
    }

    private var stretchLength: CGFloat { maxCenter - minCenter + step }

    /// A scroll view's rubber band: pulled `distance` past an end, the content moves this far.
    static func stretch(_ distance: CGFloat, over length: CGFloat) -> CGFloat {
        (1 - 1 / (distance * 0.55 / length + 1)) * length
    }

    static func unstretch(_ stretched: CGFloat, over length: CGFloat) -> CGFloat {
        let fraction = min(stretched / length, 0.99)
        return fraction * length / (0.55 * (1 - fraction))
    }

    /// With nothing chosen, shelves open with about a quarter of the rows in view above the
    /// finger, never with the first row under it.
    var openingRow: Int {
        let inView = min(count, Int((maxCenter - minCenter) / step) + 1)
        return Int((CGFloat(max(0, inView - 1)) * 0.25).rounded())
    }
    var fits: Bool { span <= maxCenter - minCenter }

    /// Puts row `index` under `y`. A list that fits then shifts only as far as it must to stay
    /// on screen. A longer one keeps up to two neighbors visible around that row and leaves no
    /// empty band above or below itself.
    func top(placing index: Int, at y: CGFloat) -> CGFloat {
        if fits { return min(max(y - CGFloat(index) * step, minCenter), maxCenter - span) }
        let above = CGFloat(min(index, 2)) * step
        let below = CGFloat(min(max(0, count - 1 - index), 2)) * step
        let anchor = min(max(y, minCenter + above), max(minCenter + above, maxCenter - below))
        return min(max(anchor - CGFloat(index) * step, maxCenter - span), minCenter)
    }

    func center(_ index: Int) -> CGFloat { top + CGFloat(index) * step }

    /// Rows fade out as they leave the band.
    func visibility(_ index: Int) -> CGFloat {
        let y = center(index)
        return max(0, 1 - max(0, minCenter - y, y - maxCenter) / (step * 0.75))
    }

    /// The row under the finger. Past the first or last row, or far right of the fan, there is
    /// none.
    func row(at point: CGPoint) -> Int? {
        guard point.x <= maximumWidth + 30 else { return nil }
        return row(atY: point.y)
    }

    /// The row level with the finger, wherever the finger is across the screen, so a swipe past
    /// a row's tip keeps that row.
    func row(atY y: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        let index = Int(((y - top) / step).rounded())
        guard (0..<count).contains(index), visibility(index) > 0.5 else { return nil }
        return index
    }

    /// The row the finger picks: the one level with it, or, past the band's top or bottom in a
    /// list that does not fit, the outermost row at least half in view, so the rows scrolling in
    /// under the finger are highlighted in turn.
    func pickedRow(atY y: CGFloat) -> Int? { row(atY: pickY(y)) }

    /// Where the finger picks rows: level with it, but in a list that does not fit, no further out
    /// than the outermost row at least half in view.
    func pickY(_ y: CGFloat) -> CGFloat {
        guard !fits else { return y }
        let edge = step * 0.13
        return min(max(y, minCenter + edge), maxCenter - edge)
    }

    /// After moving in, bringing the finger back within this distance of the left edge cancels
    /// or, inside a group, goes back.
    static let cancelWidth: CGFloat = 20.5
    /// Past this much beyond a row's tip, the finger leaves the row's activation.
    static let tipSlack: CGFloat = 8
    /// The focused row's full height, which the reorder button matches.
    static let focusedHeight: CGFloat = 65

    /// The reorder button sits just past the focused row's tip, as tall as the row.
    static func reorderButtonCenter(tip: CGFloat, rowCenter: CGFloat) -> CGPoint {
        CGPoint(x: tip + 12 + focusedHeight / 2, y: rowCenter)
    }

    /// A forgiving reach past the row's right edge: anywhere within a row's height of the
    /// button's center.
    static func isOverReorderButton(_ point: CGPoint, tip: CGFloat, rowCenter: CGFloat) -> Bool {
        let center = reorderButtonCenter(tip: tip, rowCenter: rowCenter)
        return point.x > tip + tipSlack && hypot(point.x - center.x, point.y - center.y) <= focusedHeight
    }
    /// How far past a row's edge, in rows, the finger goes before the next row takes over: a
    /// light hold, since a sideways push now holds a row firmly.
    static let rowLock: CGFloat = 0.06
    /// A push toward the tips takes hold of a row from this far along it.
    static let holdZoneStart: CGFloat = 0.38
    /// A held row lets go once the finger is this many rows from its center.
    static let holdReach: CGFloat = 1.0
    /// A long list scrolls only while the finger stays near the band's top or bottom: from half a
    /// row inside its end, reaching full speed two rows further out.
    static let scrollZoneInset: CGFloat = 0.5
    static let scrollZoneLength: CGFloat = 2
    /// Rows per second where scrolling starts and at full speed, so rows pass the finger at the
    /// same pace whatever their height.
    static let scrollRates: ClosedRange<CGFloat> = 1.5...28
    /// The focused row's extra height: 50 points becomes 65.
    static let focusGrowth: CGFloat = 15

    var indices: Range<Int> { 0..<count }

    /// How far into the top and bottom scroll zones `y` is: 0 outside them, 1 at full speed.
    func scrollDepth(fingerY y: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let inset = Self.scrollZoneInset * step, length = Self.scrollZoneLength * step
        return (max(0, (minCenter + inset - y) / length), max(0, (y - (maxCenter - inset)) / length))
    }

    /// The list's speed with the finger at `y`, in points per second: down near the band's top, up
    /// near its bottom, faster the further the finger is past each zone's `floor`. Elsewhere, and
    /// in a list that fits, the rows stand still.
    func scrollVelocity(fingerY y: CGFloat, topFloor: CGFloat = 0, bottomFloor: CGFloat = 0) -> CGFloat {
        guard !fits else { return 0 }
        let depth = scrollDepth(fingerY: y)
        if depth.bottom > bottomFloor { return -Self.scrollRate(depth.bottom - bottomFloor) * step }
        if depth.top > topFloor { return Self.scrollRate(depth.top - topFloor) * step }
        return 0
    }

    /// How deep into a scroll zone scrolling starts for a stroke, given its `floor` so far. Begun
    /// inside the zone, it starts a fifth of a row deeper than the finger and follows the finger
    /// back toward the middle, so a resting thumb never sets the list off; once the finger has been
    /// outside, it starts where the zone does.
    static func scrollFloor(_ floor: CGFloat?, depth: CGFloat) -> CGFloat {
        guard depth > 0 else { return 0 }
        let slack = 0.2 / scrollZoneLength
        return min(floor ?? depth + slack, depth + slack)
    }

    /// Rows per second `depth` into a scroll zone: slow where it starts, so a passing row can still
    /// be caught, and quickly faster toward full speed.
    static func scrollRate(_ depth: CGFloat) -> CGFloat {
        let t = min(1, max(0, depth))
        return scrollRates.lowerBound + (scrollRates.upperBound - scrollRates.lowerBound) * t * t
    }

    /// Rows keep their wave heights, 56 points far out and 50 near the finger; only the row the
    /// finger is on grows, smoothly as the finger nears its center, as the widths do.
    func height(_ index: Int, fingerY: CGFloat?) -> CGFloat {
        56 - 6 * focusStrength(index, fingerY: fingerY) + growth(index, fingerY: fingerY)
    }

    func growth(_ index: Int, fingerY: CGFloat?) -> CGFloat {
        guard let fingerY else { return 0 }
        let t = max(0, 1 - abs(fingerY - center(index)) / (step * 0.8))
        return Self.focusGrowth * t * t * (3 - 2 * t)
    }

    /// The rows around the growing one move apart by half its growth each way, so its gaps stay
    /// clear while the outer rows keep merging.
    func shift(_ index: Int, fingerY: CGFloat?) -> CGFloat {
        guard let fingerY, count > 0 else { return 0 }
        let near = Int(((fingerY - top) / step).rounded())
        let low = max(0, near - 2), high = min(count - 1, near + 2)
        guard low <= high else { return 0 }
        var above: CGFloat = 0, below: CGFloat = 0
        for other in low...high where other != index {
            let room = growth(other, fingerY: fingerY)
            if other < index { above += room } else { below += room }
        }
        return (above - below) / 2
    }

    /// Near a highlighted row's center the wave leans toward it, a soft detent rather than a
    /// snap. The lean fades out before the row hands over, so the wave never jumps.
    static func detent(_ fingerY: CGFloat, toward center: CGFloat, step: CGFloat) -> CGFloat {
        let offset = fingerY - center
        let t = min(1, abs(offset) / (step * (0.5 - rowLock)))
        return fingerY - offset * 0.3 * (1 - t * t * (3 - 2 * t))
    }
    /// While reordering, a stroke that starts this close to the edge grabs the row's handle.
    static let handleWidth: CGFloat = 56
    /// Rows all share this width while reordering.
    var rearrangeWidth: CGFloat { min(270, maximumWidth) }

    /// Where along a row the glow's zone begins; it reaches full strength just short of the tip.
    static let glowZoneStart: CGFloat = 0.46

    /// How near its tip the finger is along a row: nothing before the zone, full just short of
    /// the tip and beyond.
    static func tipNearness(fingerX x: CGFloat, tip: CGFloat) -> CGFloat {
        let t = min(1, max(0, (x - tip * glowZoneStart) / (tip * (0.94 - glowZoneStart))))
        return t * t * (3 - 2 * t)
    }

    /// While a push holds anywhere in the zone the glow builds, slowly then faster, and quicker
    /// the nearer the tip: about a third of a second at the tip, two thirds at the zone's start.
    /// Moving back lets it fall away quickly and completely.
    static func nextGlow(_ glow: CGFloat, nearness: CGFloat, building: Bool, seconds: CGFloat) -> CGFloat {
        let change = building ? 3.9 * (0.35 + glow) * (0.55 + 0.45 * nearness) : -9 * (glow + 0.15)
        return min(1, max(0, glow + change * seconds))
    }

    /// A compact Gaussian gives the focused row the largest width, then returns
    /// exactly to the common resting width outside its local neighborhood.
    func focusStrength(_ index: Int, fingerY: CGFloat?) -> CGFloat {
        guard count > 0, let fingerY else { return 0 }
        let distance = abs(fingerY - center(index)) / step
        let radius: CGFloat = 3.25
        guard distance < radius else { return 0 }
        let gaussian = exp(-0.5 * pow(distance / 1.4, 2))
        let taper = max(0, (distance - 1.5) / (radius - 1.5))
        let compactWindow = 0.5 + 0.5 * cos(.pi * taper)
        return gaussian * compactWindow
    }

    /// Rows nearer the finger lead the pop-out; distant rows follow a beat
    /// later without changing their left anchor based on their width.
    func revealProgress(_ index: Int, fingerY: CGFloat?, reveal: CGFloat) -> CGFloat {
        revealProgress(focus: focusStrength(index, fingerY: fingerY), reveal: reveal)
    }

    private func revealProgress(focus: CGFloat, reveal: CGFloat) -> CGFloat {
        let startDelay = 0.45 * (1 - focus)
        let progress = min(1, max(0, (reveal - startDelay) / (1 - startDelay)))
        return progress * progress * (3 - 2 * progress)
    }

    func width(_ index: Int, fingerY: CGFloat?, reveal: CGFloat = 1) -> CGFloat {
        width(focus: focusStrength(index, fingerY: fingerY), reveal: reveal)
    }

    private func width(focus: CGFloat, reveal: CGFloat) -> CGFloat {
        restingWidth + (maximumWidth - restingWidth) * focus * revealProgress(focus: focus, reveal: reveal)
    }

    func horizontalOffset(_ index: Int, fingerY: CGFloat?, reveal: CGFloat) -> CGFloat {
        let focus = focusStrength(index, fingerY: fingerY)
        return -(1 - revealProgress(focus: focus, reveal: reveal)) * width(focus: focus, reveal: reveal)
    }
}

/// One finger drives the shelf without lifting. The rows stand still under it, and a long list
/// scrolls only while the finger stays near the band's top or bottom.
struct LibraryShelfStroke: Equatable {
    /// Where a reordering list's scroll is measured from.
    var startY: CGFloat
    var startTop: CGFloat
    /// Set once the finger has moved in past the edge, so the swipe that opens the shelves
    /// never cancels them on its way in.
    var isArmed = false
    /// The row the open swipe is measured on.
    var row: Int?
    /// The leftmost point since the finger came onto `row` or last moved back.
    var anchorX: CGFloat = 0
    /// The rightmost point since then; coming back from it lets the glow fall.
    var highX: CGFloat = 0
    /// The finger pushed toward the tip, so staying in the zone builds the glow.
    var pushed = false
    /// `row` opened during this pass, so it does not open again until the finger comes back.
    var opened = false
    /// A level just opened under the finger; its row arms only after the finger comes back.
    var needsReturn = false
    /// The last point and the smoothed way the finger is going.
    var last: CGPoint?
    var motion = CGVector.zero
    /// The row a sideways push took hold of.
    var held: Int?
    /// How deep into the top and bottom scroll zones scrolling starts for this stroke.
    var topFloor: CGFloat?
    var bottomFloor: CGFloat?
}

@MainActor struct LibraryShelfItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var detail: String? = nil
    var person: Person? = nil
    var assetID: String? = nil
    var isSelected = false
    let action: () -> Void
}

/// The feed stays sharp while the fan tracks the finger. Only its glass refracts it.
struct LibraryShelfBackdrop: View {
    let interaction: LibraryEdgeInteraction
    let onClose: () -> Void
    var body: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.8), location: 0),
                               .init(color: .black.opacity(0.5), location: 0.55),
                               .init(color: .black.opacity(0.3), location: 1)], startPoint: .leading, endPoint: .trailing)
            .opacity(interaction.shelfReveal)
            .ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: onClose)
    }
}

struct LibraryShelfFan: View {
    let items: [LibraryShelfItem]
    /// Band and row sizes; the list position comes from the interaction.
    let geometry: LibraryShelfGeometry
    let interaction: LibraryEdgeInteraction
    let size: CGSize
    let chromeY: CGFloat
    /// Inside a group, VoiceOver can go back with a row action; the edge swipe does it by touch.
    let nested: Bool
    let onBack: () -> Void
    let onClose: () -> Void
    let onDrag: (DragGesture.Value) -> Void
    let onDragEnd: (DragGesture.Value) -> Void
    let api: APIClient
    let pipeline: MediaPipeline
    /// People and albums can be put in order; VoiceOver reaches it as a row action.
    var onReorder: (() -> Void)? = nil
    var reorderTitle = "Reorder"
    /// Moves a row while reordering, for VoiceOver's Move up and Move down.
    var onMove: (Int, Int) -> Void = { _, _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Namespace private var glass

    private var layout: LibraryShelfGeometry {
        var layout = geometry
        layout.top = interaction.shelfTop
        return layout
    }

    /// Where each row sits while one is carried: the rest close the gap it left and open one
    /// where it would drop.
    private func slot(_ index: Int) -> Int {
        guard let carried = interaction.carried, index != carried.from else { return index }
        if carried.from < carried.to, index > carried.from, index <= carried.to { return index - 1 }
        if carried.from > carried.to, index >= carried.to, index < carried.from { return index + 1 }
        return index
    }

    var body: some View {
        let layout = self.layout
        let rearranging = interaction.isRearranging
        // Past the band's ends of a long list, the wave stays on the outermost row in view.
        let fingerY = interaction.shelfFinger.map { layout.pickY($0.y) }
        let morphing = interaction.morphingID
        // While a chosen row rises into the filter tag, the wave settles and only it stays out.
        // A row held by a sideways push keeps the wave while the finger drifts.
        let waveY: CGFloat? = rearranging || morphing != nil ? nil
            : interaction.selectionHold.map { layout.center($0) }
                ?? fingerY.map { y in interaction.highlighted.map { LibraryShelfGeometry.detent(y, toward: layout.center($0), step: layout.step) } ?? y }
                ?? layout.center(items.firstIndex(where: \.isSelected) ?? 0)
        // Long lists draw only the rows near the band; VoiceOver still reaches every row.
        let rows = Array(items.enumerated()).filter {
            voiceOver || layout.visibility(slot($0.offset)) > 0 || interaction.carried?.from == $0.offset || $0.element.id == morphing
        }
        GlassEffectContainer(spacing: 8) {
            ZStack(alignment: .topLeading) {
                // Tapping empty space or swiping off the left edge closes; there is no close
                // button. A drag anywhere drives the highlight.
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: onClose).accessibilityHidden(true)
                if rearranging {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Done", systemImage: "checkmark", action: onBack)
                            .buttonStyle(.glass).controlSize(.large)
                            .accessibilityLabel("Done reordering")
                            .accessibilityIdentifier("library.reorderDone")
                    }
                    .padding(.horizontal, 16)
                    .frame(width: size.width)
                    .position(x: size.width / 2, y: chromeY)
                }
                ForEach(rows, id: \.element.id) { index, item in
                    let carried = interaction.carried?.from == index ? interaction.carried : nil
                    let rising = item.id == morphing
                    let width = rising ? interaction.morphSize?.width ?? layout.maximumWidth
                        : rearranging ? layout.rearrangeWidth : layout.width(index, fingerY: waveY, reveal: interaction.shelfReveal)
                    // Only the row under the finger grows, and its neighbors make room so its gaps
                    // stay clear; outer rows nearly touch and their glass merges into one wave.
                    let height = rising ? interaction.morphSize?.height ?? 50 : rearranging ? 50 : layout.height(index, fingerY: waveY)
                    let shift = rearranging ? 0 : layout.shift(index, fingerY: waveY)
                    let highlighted = !rearranging && interaction.highlighted == index
                    shelfButton(item, index: index, width: width, height: height, highlighted: highlighted,
                                glow: highlighted ? max(interaction.openProgress, 0.3 * interaction.tipNearness) : 0,
                                rearranging: rearranging)
                        .scaleEffect(carried == nil ? 1 : 1.04, anchor: .leading)
                        .shadow(color: .black.opacity(carried == nil ? 0 : 0.4), radius: 14, y: 6)
                        .offset(x: rearranging || rising ? 0 : layout.horizontalOffset(index, fingerY: waveY, reveal: interaction.shelfReveal),
                                y: (carried?.y ?? layout.center(slot(index)) + shift) - height / 2)
                        .opacity(carried == nil && !rising ? layout.visibility(slot(index)) : 1)
                        .allowsHitTesting(layout.visibility(slot(index)) > 0.5)
                        .zIndex(carried == nil ? 0 : 1)
                }
                // Past the focused row's tip in People and Albums, fading in as the finger nears it.
                if !rearranging, let onReorder, let row = interaction.highlighted, let finger = interaction.shelfFinger {
                    let tip = layout.maximumWidth
                    let reach = min(1, max(0, (finger.x - tip * 0.6) / (tip * 0.4)))
                    LibraryShelfReorderButton(active: interaction.overReorder, size: LibraryShelfGeometry.focusedHeight,
                                              shown: reach * reach * (3 - 2 * reach), action: onReorder)
                        .position(LibraryShelfGeometry.reorderButtonCenter(tip: tip, rowCenter: layout.center(row) + layout.shift(row, fingerY: waveY)))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // VoiceOver's escape gesture puts the shelves away, in place of a close button.
        .accessibilityAction(.escape, onClose)
        // Wins over the row buttons once the finger moves, so a drag never also taps a row.
        .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("library"))
            .onChanged(onDrag).onEnded(onDragEnd))
        // While reordering, a finger landing stops a coasting list, as on any scroll view.
        .gesture(LibraryShelfTouch(enabled: rearranging, onDown: { interaction.touchDown() }, onUp: { interaction.settleScroll() }))
        .animation(reduceMotion || interaction.isShelfDragging ? nil : .snappy(duration: 0.2), value: items.map(\.id))
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: interaction.carried?.to)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: rearranging)
        // Changing the reveal in the same update that inserts the fan would draw it open at once.
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84)) { interaction.shelfReveal = 1 }
        }
    }

    private func shelfButton(_ item: LibraryShelfItem, index: Int, width: CGFloat, height: CGFloat, highlighted: Bool,
                             glow: CGFloat, rearranging: Bool) -> some View {
        Button(action: rearranging ? {} : item.action) {
            LibraryShelfRowLabel(item: item, width: width, height: height, highlighted: highlighted, glow: glow,
                                 handle: rearranging, becomingTag: item.id == interaction.morphingID, api: api, pipeline: pipeline)
                .glassEffectID(item.id, in: glass)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
        .accessibilityActions {
            if rearranging {
                if index > 0 { Button("Move up") { onMove(index, index - 1) } }
                if index < items.count - 1 { Button("Move down") { onMove(index, index + 1) } }
            } else {
                if nested { Button("Back to shelves", action: onBack) }
                if let onReorder { Button(reorderTitle, action: onReorder) }
            }
        }
    }
}

/// Past the focused row's tip in People and Albums: lifting the finger over it, or tapping it,
/// puts them in order. Glass ignores an opacity around it, so the button has no glass while the
/// finger is away and fades its symbol and outline as the finger nears it.
struct LibraryShelfReorderButton: View {
    let active: Bool
    let size: CGFloat
    /// How far it has faded in, from 0 to 1.
    let shown: CGFloat
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: "line.3.horizontal").font(.title3.weight(.semibold))
                .opacity(shown)
                .frame(width: size, height: size)
                .glassEffect(shown > 0 ? .clear.tint(active ? .cyan.opacity(0.35) : .black.opacity(0.18)).interactive() : .identity, in: .circle)
                .overlay(Circle().strokeBorder(active ? Color.cyan : .white.opacity(0.22), lineWidth: active ? 1.5 : 0.75).opacity(shown))
                .shadow(color: .cyan.opacity(active ? 0.7 : 0), radius: active ? 14 : 0)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: shown > 0)
        .accessibilityLabel("Reorder")
        .accessibilityIdentifier("library.reorderButton")
    }
}

/// A shelf row's glass: flat on the screen edge, round at its tip, with its title, count, and
/// face or cover.
struct LibraryShelfRowLabel: View {
    let item: LibraryShelfItem
    let width: CGFloat
    let height: CGFloat
    var highlighted = false
    /// The blue glow gathering at the tip as the row nears opening.
    var glow: CGFloat = 0
    /// A drag handle on the edge side of the row while reordering.
    var handle = false
    /// Rising into the filter tag: on the way the row takes the tag's own layout, its face sliding
    /// to the front and its title following, so it arrives as the tag.
    var becomingTag = false
    let api: APIClient
    let pipeline: MediaPipeline
    @Namespace private var morph

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: height / 2, topTrailingRadius: height / 2)
        Group {
            if becomingTag { tagContent } else { rowContent }
        }
        .frame(width: width, height: height)
        .background {
            // An album's cover fills its row; in the tag it is the round icon.
            if let assetID = item.assetID, !becomingTag {
                FeatureThumbnail(api: api, pipeline: pipeline, assetID: assetID)
                    .overlay(.black.opacity(0.25))
            }
        }
        // Blue light gathers at the tip, spreading back along the row as it builds.
        .overlay(alignment: .trailing) {
            if glow > 0 {
                RadialGradient(colors: [.cyan.opacity(0.95 * glow), .cyan.opacity(0.4 * glow), .cyan.opacity(0)],
                               center: .trailing, startRadius: 0, endRadius: height * 0.8 + width * 0.9 * glow)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(shape)
        .contentShape(.rect)
        .glassEffect(.clear.tint(.black.opacity(becomingTag ? 0.22 : 0.18)).interactive(), in: shape)
        .overlay(shape.strokeBorder(item.isSelected || highlighted ? .cyan.opacity(0.85) : .white.opacity(0.22), lineWidth: 0.75))
        .shadow(color: .cyan.opacity(0.9 * glow), radius: 6 + 20 * glow)
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            if handle {
                Image(systemName: "line.3.horizontal").font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85)).frame(width: 30)
                    .padding(.leading, 14)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 10)
            if width >= 100 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.title).font((width < 150 ? Font.subheadline : .body).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                        .matchedGeometryEffect(id: "title", in: morph, properties: .position)
                    if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }.opacity(min(1, max(0, (width - 100) / 30)))
            }
            if let person = item.person {
                PersonThumbnail(pipeline: pipeline, person: person, pixelSize: PersonThumbnail.small).frame(width: 38, height: 38)
                    .overlay(Circle().stroke(.cyan, lineWidth: item.isSelected ? 1.5 : 0))
                    .matchedGeometryEffect(id: "face", in: morph)
            } else if item.assetID == nil {
                Image(systemName: item.symbol).font(.title3).frame(width: 28)
            }
        }
        .padding(.trailing, 12)
    }

    /// The filter tag's own layout: face or cover, then title.
    private var tagContent: some View {
        HStack(spacing: 10) {
            Group {
                if let person = item.person {
                    PersonThumbnail(pipeline: pipeline, person: person, pixelSize: PersonThumbnail.small)
                } else if let assetID = item.assetID {
                    FeatureThumbnail(api: api, pipeline: pipeline, assetID: assetID).clipShape(.circle)
                } else {
                    Image(systemName: item.symbol).font(.body.weight(.semibold))
                }
            }
            .frame(width: 34, height: 34)
            .matchedGeometryEffect(id: "face", in: morph)
            // Worded as the tag words it, so nothing changes when the tag takes over.
            Text(item.person.map { $0.name.isEmpty ? "Person" : $0.name } ?? item.title)
                .font(.subheadline.weight(.semibold)).lineLimit(1)
                .matchedGeometryEffect(id: "title", in: morph, properties: .position)
        }
        .padding(.leading, 16).padding(.trailing, 18)
        // No spacer, whose spacing would take room from the title; the tag has none either.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

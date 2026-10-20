import SwiftUI

/// The time rail of the design. A faint tape at the right edge is scaled by photo count, with a
/// tick per month and a longer one per year. Scrolling brings a puck, which fades 800 ms after
/// the grid stops. Dragging opens a glass column with the years and the trips on it, and a lens
/// on the month under the finger, joined to the column by a small glass bridge.
struct TimeRail: View {
    let store: LibraryStore
    let pipeline: MediaPipeline
    let viewportWidth: CGFloat
    let interaction: LibraryEdgeInteraction
    @State private var selected: Int?
    @State private var yearSelection: Int?
    @State private var expanded = false
    @State private var visible = true
    @State private var dismissTask: Task<Void, Never>?
    @State private var fingerY: CGFloat?
    @State private var isScrubbing = false
    /// The lens and the column have finished opening, so a drag may move the photos.
    @State private var railOpen = false
    /// Holds the place where the finger stops, so lifting it does not move the photos.
    @State private var rest = TimeRailRest()
    @State private var restTask: Task<Void, Never>?
    @State private var scale = TimeRailScale(buckets: [])
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var buckets: [TimeBucket] { store.buckets }
    private var total: Int { max(1, scale.totalCount) }
    private var activeIndex: Int { min(max(0, selected ?? store.navigation.section), max(0, buckets.count - 1)) }

    private static let accent = Color(red: 0.44, green: 0.86, blue: 1)
    /// The tape's x inside the 44-point rail; ticks hang to its left.
    private static let tapeX: CGFloat = 37
    private static let lensWidth: CGFloat = 210
    /// The lens, the column and the years slide out of the rail as their glass forms, and back
    /// into it as the glass melts away. Glass ignores opacity, so it forms and melts by being
    /// added to and removed from a glass container.
    private static let fromRail = AnyTransition.offset(x: 26).combined(with: .opacity)
    /// The puck slides in from the screen edge the same way.
    private static let puckFromEdge = AnyTransition.offset(x: 16).combined(with: .opacity)
    private var showMotion: Animation? { reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.78) }

    var body: some View {
        GeometryReader { geometry in
            let height = max(1, geometry.size.height - 48)
            // The line marks where you are: under the finger while scrubbing, the grid's own
            // position otherwise.
            let currentY = fingerY ?? puckFraction * height + 24
            ZStack(alignment: .topLeading) {
                if expanded {
                    // The grid darkens toward the rail, so the lens and the years read clearly.
                    LinearGradient(stops: [.init(color: .black.opacity(0.12), location: 0), .init(color: .black.opacity(0.22), location: 0.4),
                                           .init(color: .black.opacity(0.62), location: 1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: viewportWidth, height: geometry.size.height + 1_200)
                        .position(x: 44 - viewportWidth / 2, y: geometry.size.height / 2)
                        .allowsHitTesting(false).transition(.opacity)
                }
                Canvas { context, _ in drawTape(context, height: height) }
                    .frame(width: 44, height: geometry.size.height).allowsHitTesting(false)
                // Glass forms and melts only inside a container that stays on screen, so the
                // containers stay and only what is in them comes and goes.
                GlassEffectContainer(spacing: 14) {
                    ZStack(alignment: .topLeading) {
                        if expanded {
                            Group {
                                Capsule().fill(.clear).glassEffect(.clear.tint(.black.opacity(0.18)), in: .capsule)
                                    .frame(width: 54, height: geometry.size.height).position(x: 9, y: geometry.size.height / 2)
                                if buckets.indices.contains(activeIndex) {
                                    // The bridge between the lens and the column sits on the month under the finger.
                                    Circle().fill(.clear).glassEffect(.clear.tint(.black.opacity(0.18)), in: .circle)
                                        .frame(width: 26, height: 26).position(x: -23, y: lensY(currentY, size: geometry.size))
                                    lens(index: activeIndex)
                                        .frame(width: Self.lensWidth, alignment: .leading)
                                        .position(x: -30 - Self.lensWidth / 2, y: lensY(currentY, size: geometry.size))
                                }
                            }
                            .transition(Self.fromRail)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
                .allowsHitTesting(false)
                GlassEffectContainer(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        if expanded { tripMarks(height: height, currentY: currentY).transition(Self.fromRail) }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
                .allowsHitTesting(false)
                if expanded {
                    yearLabels(height: height).transition(Self.fromRail)
                    // The month under the finger, across the column.
                    Capsule().fill(Self.accent).frame(width: 46, height: 2).shadow(color: Self.accent.opacity(0.95), radius: 5)
                        .position(x: 9, y: currentY).allowsHitTesting(false)
                        .transition(.opacity)
                }
                GlassEffectContainer {
                    ZStack(alignment: .topLeading) {
                        if !expanded && visible {
                            puck.position(x: 24, y: fingerY ?? (puckFraction * height + 24))
                                .transition(Self.puckFromEdge)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
            }
            .contentShape(Rectangle())
            .onChange(of: interaction.timePan) { _, value in
                guard let value else { return }
                let y = value.location.y - geometry.frame(in: .named("library")).minY
                let now = ProcessInfo.processInfo.systemUptime
                switch value.phase {
                case .began:
                    Haptics.grabbed()
                    RailScrubProbe.began()
                    isScrubbing = true; store.navigation.isScrubbing = true
                    rest = TimeRailRest()
                    _ = rest.move(to: y, at: now)
                    // The lens and the column open first, showing the month under the finger, and
                    // the photos move only once they are open, so you see where you are going.
                    preview(at: y, height: height)
                    open {
                        guard isScrubbing, let fingerY else { return }
                        store.cancelPendingNavigation()
                        scrub(at: fingerY, height: height)
                    }
                case .changed:
                    // Once the finger has stopped, a small move waits a moment, and lifting the
                    // finger meanwhile drops it: that is the roll of a lifting finger.
                    guard let shown = rest.move(to: y, at: now) else { holdMoves(height: height); return }
                    follow(shown, height: height)
                case .ended:
                    RailScrubProbe.ended()
                    isScrubbing = false; store.navigation.isScrubbing = false
                    rest.end(); restTask?.cancel(); restTask = nil
                    // Lifting the finger closes it sooner and quicker than the rail fades after scrolling.
                    scheduleDismiss(delay: .milliseconds(400), duration: 0.24)
                default:
                    RailScrubProbe.ended()
                    isScrubbing = false; store.navigation.isScrubbing = false
                    rest.end(); restTask?.cancel(); restTask = nil
                    scheduleDismiss(delay: .zero)
                }
            }
            .onTapGesture { visible = true; open { }; scheduleDismiss(delay: .seconds(3)) }
            .accessibilityElement(children: expanded ? .contain : .ignore)
            .accessibilityLabel("Timeline month")
            .accessibilityValue(buckets.indices.contains(activeIndex) ? month(scale.date(at: activeIndex)) : "Library")
            .accessibilityAdjustableAction { direction in
                choose(min(buckets.count - 1, max(0, activeIndex + (direction == .increment ? 1 : -1))))
            }.accessibilityIdentifier("library.timeRail")
        }
        .task { scheduleDismiss() }
        .onChange(of: store.buckets, initial: true) { _, buckets in
            scale = TimeRailScale(buckets: buckets)
        }
        .onChange(of: store.navigation.isScrolling) { _, scrolling in
            if scrolling && !expanded {
                dismissTask?.cancel(); selected = nil; yearSelection = nil
                if !visible { withAnimation(showMotion) { visible = true } }
            }
            else if !scrolling && !isScrubbing { scheduleDismiss() }
        }
        .onDisappear { dismissTask?.cancel(); store.navigation.isScrubbing = false }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Pieces

    /// A glass puck with arrows above and below a glowing line that marks the position.
    private var puck: some View {
        VStack(spacing: 4) {
            Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
            Capsule().fill(Self.accent).frame(width: 10, height: 2).shadow(color: Self.accent.opacity(0.9), radius: 4)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(width: 30, height: 58)
        .glassEffect(.clear.tint(.black.opacity(0.18)).interactive(), in: .capsule)
    }

    /// The tape and its ticks: short for months, longer for years, and the month under the finger
    /// longest and in the accent color while the rail is open.
    private func drawTape(_ context: GraphicsContext, height: CGFloat) {
        var tape = Path()
        tape.move(to: CGPoint(x: Self.tapeX + 0.75, y: 24)); tape.addLine(to: CGPoint(x: Self.tapeX + 0.75, y: 24 + height))
        context.stroke(tape, with: .color(.white.opacity(expanded ? 0.24 : 0.14)), lineWidth: 1.5)
        let years = Set(scale.yearStartIndices)
        let current = expanded ? activeIndex : -1
        for index in buckets.indices {
            let y = (24 + fraction(index) * height).rounded() + 0.5
            let isYear = years.contains(index)
            let width: CGFloat = index == current ? 14 : isYear ? (expanded ? 9 : 11) : 4
            let color: Color = index == current ? Self.accent : .white.opacity(isYear ? (expanded ? 0.62 : 0.55) : (expanded ? 0.3 : 0.24))
            var tick = Path()
            tick.move(to: CGPoint(x: Self.tapeX - width, y: y)); tick.addLine(to: CGPoint(x: Self.tapeX, y: y))
            context.stroke(tick, with: .color(color), lineWidth: 1)
        }
    }

    private func yearLabels(height: CGFloat) -> some View {
        let currentYear = scale.year(at: activeIndex)
        return ForEach(yearMarkers(height: height), id: \.index) { marker in
            let chosen = yearSelection == marker.year
            Button { Haptics.itemChosen(); choose(marker.index, year: marker.year); scheduleDismiss(delay: .seconds(2)) } label: {
                Text(String(marker.year))
                    .font(.system(size: 9.5, weight: chosen ? .semibold : .medium, design: .monospaced))
                    .foregroundStyle(chosen ? Color(red: 0.02, green: 0.02, blue: 0.04) : .white.opacity(marker.year == currentYear ? 1 : 0.56))
                    .padding(.horizontal, chosen ? 4 : 0).padding(.vertical, chosen ? 3 : 0)
                    .background { if chosen { Capsule().fill(Self.accent).shadow(color: Self.accent.opacity(0.7), radius: 7) } }
                    .frame(width: 44, height: 28)
            }
            .buttonStyle(.plain)
            .position(x: 6, y: marker.y + 24 + 7)
            .accessibilityLabel("Jump to \(String(marker.year))")
        }
    }

    /// Trips marked on the tape, kept clear of the lens and of each other.
    private func tripMarks(height: CGFloat, currentY: CGFloat) -> some View {
        var lastY = -CGFloat.infinity
        var marks: [(id: String, label: String, y: CGFloat)] = []
        for index in buckets.indices {
            guard let label = store.trips[buckets[index].id] else { continue }
            let y = monthCenter(index, height: height)
            guard abs(y - currentY) > 84, y - lastY >= 26 else { continue }
            marks.append((buckets[index].id, label, y)); lastY = y
        }
        return ForEach(marks, id: \.id) { mark in
            HStack(spacing: 6) {
                Circle().fill(.white.opacity(0.7)).frame(width: 5, height: 5)
                Text(mark.label.uppercased()).font(.system(size: 9.5, weight: .medium, design: .monospaced)).tracking(0.8).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 9).frame(height: 22)
            .glassEffect(.clear.tint(.black.opacity(0.2)), in: .capsule)
            .fixedSize()
            .frame(width: 220, alignment: .trailing)
            .position(x: -26 - 110, y: mark.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func lens(index: Int) -> some View {
        let bucket = buckets[index]
        let count = yearSelection.map { scale.count(for: $0) } ?? bucket.count
        let places = yearSelection.map { store.placeSummary(year: $0) } ?? store.placeSummary(section: index)
        let previews = (0..<min(4, bucket.count)).compactMap { store.asset(section: index, item: $0) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(yearSelection.map(String.init) ?? abbreviatedMonth(scale.date(at: index)))
                    .font(.system(size: 44, weight: .heavy)).fontWidth(.expanded).lineLimit(1).minimumScaleFactor(0.7)
                if yearSelection == nil, let year = scale.year(at: index) {
                    Text(String(year)).font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundStyle(Self.accent)
                }
            }
            HStack(spacing: 8) {
                Text(places ?? " ").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.78)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count.formatted()) items").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.66))
            }
            HStack(spacing: 6) {
                ForEach(previews) { asset in
                    FeatureAssetImage(pipeline: pipeline, asset: asset)
                        .frame(width: 38, height: 38).clipShape(.rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.16), lineWidth: 1))
                }
                if previews.isEmpty { ProgressView().controlSize(.mini).frame(height: 38) }
            }.frame(height: 38)
        }
        .foregroundStyle(.white)
        .padding(.leading, 20).padding(.trailing, 18).padding(.top, 16).padding(.bottom, 14)
        .glassEffect(.clear.tint(.black.opacity(0.22)), in: .rect(cornerRadius: 30))
        .accessibilityIdentifier("library.scrubLens")
    }

    // MARK: Geometry

    private var puckFraction: CGFloat {
        if selected != nil && fingerY == nil { return fraction(activeIndex) }
        // Read the position so the rail redraws as the grid moves; the grid's offset places the puck.
        let before = scale.count(before: store.navigation.section) + store.navigation.item
        return store.scroller.fraction ?? min(1, max(0, CGFloat(before) / CGFloat(total)))
    }
    /// Months sit where the grid's layout puts them, so the rail and the photos agree.
    private func fraction(_ index: Int) -> CGFloat { store.scroller.fraction(ofSection: index) ?? CGFloat(scale.fraction(before: index)) }
    private func monthCenter(_ index: Int, height: CGFloat) -> CGFloat {
        let top = fraction(index), bottom = index + 1 < buckets.count ? fraction(index + 1) : 1
        return 24 + (top + bottom) / 2 * height
    }
    private func lensY(_ y: CGFloat, size: CGSize) -> CGFloat { min(max(78, fingerY ?? y), size.height - 78) }

    private func yearMarkers(height: CGFloat) -> [(index: Int, year: Int, y: CGFloat)] {
        var result: [(index: Int, year: Int, y: CGFloat)] = []
        let starts = scale.yearStartIndices
        for (position, index) in starts.enumerated() {
            guard let value = scale.year(at: index) else { continue }
            let y = fraction(index) * height
            let end = position + 1 < starts.count ? fraction(starts[position + 1]) * height : height
            // A year needs room for its label, and labels need room from each other.
            guard end - y >= 13, y - (result.last?.y ?? -44) >= 28 else { continue }
            result.append((index, value, y))
        }
        return result
    }
    private func abbreviatedMonth(_ date: Date?) -> String {
        guard let date else { return "" }
        var style = Date.FormatStyle().month(.abbreviated); style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style).uppercased()
    }
    private func month(_ date: Date?) -> String {
        guard let date else { return "Library" }
        var style = Date.FormatStyle().month(.abbreviated).year(); style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }

    // MARK: Actions

    private func choose(_ index: Int, year: Int? = nil) {
        guard buckets.indices.contains(index) else { return }
        selected = index; yearSelection = year; expanded = true; visible = true
        if store.scroller.collection != nil {
            store.cancelPendingNavigation()
            store.scroller.scroll(toSection: index, animated: false)
        } else { store.scrollToBucket(index) }
    }
    /// Opens the lens and the column, then runs `opened` once they are fully out.
    private func open(_ opened: @escaping () -> Void) {
        dismissTask?.cancel(); visible = true
        guard !expanded else { railOpen = true; opened(); return }
        withAnimation(showMotion) { expanded = true } completion: {
            guard expanded else { return }
            railOpen = true; opened()
        }
    }

    /// While the lens opens it follows the finger and shows the month there, leaving the photos
    /// where they are.
    private func preview(at y: CGFloat, height: CGFloat) {
        dismissTask?.cancel(); visible = true
        fingerY = min(height + 24, max(24, y))
        yearSelection = nil
        let target = monthIndex(atFraction: min(1, max(0, (y - 24) / height)))
        if let target, selected != target { selected = target; Haptics.selectionChanged() }
    }

    /// The month whose stretch of the rail holds this fraction.
    private func monthIndex(atFraction value: CGFloat) -> Int? {
        guard !buckets.isEmpty else { return nil }
        var low = 0, high = buckets.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if fraction(middle) <= value { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Before the rail is open only the lens follows the finger; once it is, the photos do.
    private func follow(_ y: CGFloat, height: CGFloat) {
        if railOpen { scrub(at: y, height: height) } else { preview(at: y, height: height) }
    }

    /// A move held back after a stop is followed once it has waited, if the finger is still down.
    private func holdMoves(height: CGFloat) {
        guard restTask == nil else { return }
        restTask = Task {
            while let due = rest.nextDue {
                try? await Task.sleep(for: .seconds(max(0, due - ProcessInfo.processInfo.systemUptime)))
                guard !Task.isCancelled else { return }
                if let y = rest.due(at: ProcessInfo.processInfo.systemUptime) { follow(y, height: height) }
            }
            restTask = nil
        }
    }

    /// The finger's height on the rail is the grid's position, continuously: no snapping to rows.
    private func scrub(at y: CGFloat, height: CGFloat) {
        dismissTask?.cancel(); visible = true
        if !expanded { withAnimation(showMotion) { expanded = true } }
        fingerY = min(height + 24, max(24, y))
        let fraction = min(1, max(0, (y - 24) / height))
        guard store.scroller.collection != nil else {
            if let position = scale.position(at: Double(fraction)) { store.scrollToBucket(position.index, item: position.item) }
            return
        }
        if selected == nil { store.cancelPendingNavigation() }
        store.scroller.scroll(toFraction: fraction)
        let index = store.navigation.section
        if selected != index { selected = index; Haptics.selectionChanged() }
        yearSelection = nil
    }
    private func scheduleDismiss(delay: Duration = .milliseconds(800), duration: TimeInterval = 0.35) {
        dismissTask?.cancel()
        dismissTask = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: duration)) { expanded = false; visible = false }
            railOpen = false
            selected = nil; yearSelection = nil; fingerY = nil
        }
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

import SwiftUI

/// The time rail of the design. A faint tape at the right edge is scaled by photo count, with a
/// tick per month and a longer one per year. Scrolling brings a puck, which fades 800 ms after
/// the grid stops. Dragging opens a glass column with the years and the trips on it, and a lens
/// on the month under the finger, joined to the column by a small glass bridge.
///
/// What the rail does is TimeRailController's (T4); this draws its state. The finger moves on
/// every frame of a scrub, so only what it places reads it: the lens and its bridge, the accent
/// line and the trips kept clear of the lens. The tape, the years and what the lens shows are
/// drawn again only when the month, or what is known of it, changes. What reads the controller
/// itself keeps reading it while it melts away, so the controller holds the finger and the month
/// until the closing rail's lens and line have gone.
struct TimeRail: View {
    let store: LibraryFeedStore
    let rail: TimeRailController
    let pipeline: MediaPipeline
    let viewportWidth: CGFloat
    /// Lives as long as this rail view, as the rail's own state used to: a rail put back on
    /// screen starts afresh, one that only reappears keeps where it was.
    @State private var identity = UUID()
    /// Until it has appeared, this rail view draws a new rail, whatever an earlier one left open.
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var buckets: [TimeBucket] { store.buckets }
    private var isOpen: Bool { shown && rail.expanded }
    private var showsPuck: Bool { !isOpen && (!shown || rail.visible) }

    fileprivate static let accent = Color(red: 0.44, green: 0.86, blue: 1)
    /// The tape's x inside the 44-point rail; ticks hang to its left.
    private static let tapeX: CGFloat = 37
    fileprivate static let lensWidth: CGFloat = 210
    /// The lens, the column and the years slide out of the rail as their glass forms, and back
    /// into it as the glass melts away. Glass ignores opacity, so it forms and melts by being
    /// added to and removed from a glass container.
    private static let fromRail = AnyTransition.offset(x: 26).combined(with: .opacity)
    /// The puck slides in from the screen edge the same way.
    private static let puckFromEdge = AnyTransition.offset(x: 16).combined(with: .opacity)

    var body: some View {
        GeometryReader { geometry in
            let height = max(1, geometry.size.height - 48)
            let activeIndex = rail.activeIndex
            let scale = rail.scale
            let expanded = isOpen
            ZStack(alignment: .topLeading) {
                if expanded {
                    // The grid darkens toward the rail, so the lens and the years read clearly.
                    LinearGradient(stops: [.init(color: .black.opacity(0.12), location: 0), .init(color: .black.opacity(0.22), location: 0.4),
                                           .init(color: .black.opacity(0.62), location: 1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: viewportWidth, height: geometry.size.height + 1_200)
                        .position(x: 44 - viewportWidth / 2, y: geometry.size.height / 2)
                        .allowsHitTesting(false).transition(.opacity)
                }
                Canvas { context, _ in drawTape(context, height: height, scale: scale, current: expanded ? activeIndex : -1, expanded: expanded) }
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
                                        .frame(width: 26, height: 26)
                                        .modifier(TimeRailFollowsFinger(rail: rail, x: -23, height: height, clearOfEndsIn: geometry.size))
                                    TimeRailLens(store: store, rail: rail, pipeline: pipeline, index: activeIndex, yearSelection: rail.yearSelection)
                                        .frame(width: Self.lensWidth, alignment: .leading)
                                        .modifier(TimeRailFollowsFinger(rail: rail, x: -30 - Self.lensWidth / 2, height: height, clearOfEndsIn: geometry.size))
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
                        if expanded { TimeRailTripMarks(store: store, rail: rail, height: height).transition(Self.fromRail) }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
                .allowsHitTesting(false)
                if expanded {
                    yearLabels(height: height, scale: scale, activeIndex: activeIndex).transition(Self.fromRail)
                    // The month under the finger, across the column.
                    Capsule().fill(Self.accent).frame(width: 46, height: 2).shadow(color: Self.accent.opacity(0.95), radius: 5)
                        .modifier(TimeRailFollowsFinger(rail: rail, x: 9, height: height, clearOfEndsIn: nil)).allowsHitTesting(false)
                        .transition(.opacity)
                }
                GlassEffectContainer {
                    ZStack(alignment: .topLeading) {
                        if showsPuck {
                            TimeRailPuck(rail: rail, height: height)
                                .transition(Self.puckFromEdge)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { rail.tap() }
            .accessibilityElement(children: expanded ? .contain : .ignore)
            .accessibilityLabel("Timeline month")
            .accessibilityValue(buckets.indices.contains(activeIndex) ? TimeRail.month(scale.date(at: activeIndex)) : "Library")
            .accessibilityAdjustableAction { direction in rail.adjust(direction) }
            .accessibilityIdentifier("library.timeRail")
        }
        // The finger's height is measured from the rail's top, in the library's coordinates,
        // where the edge pan reports it.
        .onGeometryChange(for: TimeRailController.Layout.self) { proxy in
            let frame = proxy.frame(in: .named("library"))
            return TimeRailController.Layout(top: frame.minY, height: max(1, frame.height - 48))
        } action: { layout in rail.layout = layout }
        .onChange(of: reduceMotion, initial: true) { _, reduce in rail.reduceMotion = reduce }
        .onChange(of: store.buckets, initial: true) { _, buckets in rail.setBuckets(buckets) }
        .onAppear { shown = true; rail.appeared(identity) }
        .onDisappear { rail.disappeared() }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Pieces

    /// The tape and its ticks: short for months, longer for years, and the month under the finger
    /// longest and in the accent color while the rail is open.
    private func drawTape(_ context: GraphicsContext, height: CGFloat, scale: TimeRailScale, current: Int, expanded: Bool) {
        var tape = Path()
        tape.move(to: CGPoint(x: Self.tapeX + 0.75, y: 24)); tape.addLine(to: CGPoint(x: Self.tapeX + 0.75, y: 24 + height))
        context.stroke(tape, with: .color(.white.opacity(expanded ? 0.24 : 0.14)), lineWidth: 1.5)
        let years = Set(scale.yearStartIndices)
        for index in buckets.indices {
            let y = (24 + rail.fraction(index) * height).rounded() + 0.5
            let isYear = years.contains(index)
            let width: CGFloat = index == current ? 14 : isYear ? (expanded ? 9 : 11) : 4
            let color: Color = index == current ? Self.accent : .white.opacity(isYear ? (expanded ? 0.62 : 0.55) : (expanded ? 0.3 : 0.24))
            var tick = Path()
            tick.move(to: CGPoint(x: Self.tapeX - width, y: y)); tick.addLine(to: CGPoint(x: Self.tapeX, y: y))
            context.stroke(tick, with: .color(color), lineWidth: 1)
        }
    }

    private func yearLabels(height: CGFloat, scale: TimeRailScale, activeIndex: Int) -> some View {
        let currentYear = scale.year(at: activeIndex)
        return ForEach(yearMarkers(height: height, scale: scale), id: \.index) { marker in
            let chosen = rail.yearSelection == marker.year
            Button { rail.chooseYear(marker.index, year: marker.year) } label: {
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

    // MARK: Geometry

    private func yearMarkers(height: CGFloat, scale: TimeRailScale) -> [(index: Int, year: Int, y: CGFloat)] {
        var result: [(index: Int, year: Int, y: CGFloat)] = []
        let starts = scale.yearStartIndices
        for (position, index) in starts.enumerated() {
            guard let value = scale.year(at: index) else { continue }
            let y = rail.fraction(index) * height
            let end = position + 1 < starts.count ? rail.fraction(starts[position + 1]) * height : height
            // A year needs room for its label, and labels need room from each other.
            guard end - y >= 13, y - (result.last?.y ?? -44) >= 28 else { continue }
            result.append((index, value, y))
        }
        return result
    }
    fileprivate static func abbreviatedMonth(_ date: Date?) -> String {
        guard let date else { return "" }
        var style = Date.FormatStyle().month(.abbreviated); style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style).uppercased()
    }
    fileprivate static func month(_ date: Date?) -> String {
        guard let date else { return "Library" }
        var style = Date.FormatStyle().month(.abbreviated).year(); style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }
}

/// Places what it modifies where the accent line marks the position, reading the finger itself,
/// so following the finger moves it without drawing again what it places.
private struct TimeRailFollowsFinger: ViewModifier {
    let rail: TimeRailController
    let x: CGFloat
    let height: CGFloat
    /// The lens and its bridge keep clear of the ends of a rail this size; nil sits on the line.
    let clearOfEndsIn: CGSize?

    func body(content: Content) -> some View {
        let y = rail.currentY(height: height)
        return content.position(x: x, y: clearOfEndsIn.map { rail.lensY(y, size: $0) } ?? y)
    }
}

/// The month or year under the finger: its name, places, count and four of its photos.
private struct TimeRailLens: View {
    let store: LibraryFeedStore
    let rail: TimeRailController
    let pipeline: MediaPipeline
    let index: Int
    let yearSelection: Int?

    var body: some View {
        if store.buckets.indices.contains(index) {
            let bucket = store.buckets[index]
            let scale = rail.scale
            let count = yearSelection.map { scale.count(for: $0) } ?? bucket.count
            let places = yearSelection.map { store.placeSummary(year: $0) } ?? store.placeSummary(section: index)
            let previews = (0..<min(4, bucket.count)).compactMap { store.asset(section: index, item: $0) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(yearSelection.map(String.init) ?? TimeRail.abbreviatedMonth(scale.date(at: index)))
                        .font(.system(size: 44, weight: .heavy)).fontWidth(.expanded).lineLimit(1).minimumScaleFactor(0.7)
                    if yearSelection == nil, let year = scale.year(at: index) {
                        Text(String(year)).font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundStyle(TimeRail.accent)
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
    }
}

/// Trips marked on the tape, kept clear of the lens and of each other. They move aside as the
/// lens passes, so they follow the finger too.
private struct TimeRailTripMarks: View {
    let store: LibraryFeedStore
    let rail: TimeRailController
    let height: CGFloat

    var body: some View {
        ForEach(marks(), id: \.id) { mark in
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

    private func marks() -> [(id: String, label: String, y: CGFloat)] {
        let currentY = rail.currentY(height: height)
        // Read once, not once per month: a scrub draws these on every frame.
        let trips = store.trips, buckets = store.buckets
        var lastY = -CGFloat.infinity
        var marks: [(id: String, label: String, y: CGFloat)] = []
        for index in buckets.indices {
            guard let label = trips[buckets[index].id] else { continue }
            let y = rail.monthCenter(index, height: height)
            guard abs(y - currentY) > 84, y - lastY >= 26 else { continue }
            marks.append((buckets[index].id, label, y)); lastY = y
        }
        return marks
    }
}

/// A glass puck with arrows above and below a glowing line that marks the position. It follows the
/// grid on every scrolled frame, so it watches the grid's position itself and the rest of the rail
/// is left alone. It slides out where it was when a finger lands on the rail.
private struct TimeRailPuck: View {
    let rail: TimeRailController
    let height: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
            Capsule().fill(TimeRail.accent).frame(width: 10, height: 2).shadow(color: TimeRail.accent.opacity(0.9), radius: 4)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(width: 30, height: 58)
        .glassEffect(.clear.tint(.black.opacity(0.18)).interactive(), in: .capsule)
        .position(x: 24, y: rail.puckY(height: height))
    }
}

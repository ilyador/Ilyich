import SwiftUI

struct TimeRail: View {
    let store: LibraryStore
    let viewportWidth: CGFloat
    @State private var selected: Int?
    @State private var yearSelection: Int?
    @State private var expanded = false
    @State private var visible = true
    @State private var dismissTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var buckets: [TimeBucket] { store.buckets }
    private var total: Int { max(1, buckets.reduce(0) { $0 + $1.count }) }
    private var activeIndex: Int { min(max(0, selected ?? store.navigation.section), max(0, buckets.count - 1)) }

    var body: some View {
        GeometryReader { geometry in
            let height = max(1, geometry.size.height - 48)
            ZStack(alignment: .trailing) {
                if expanded {
                    Capsule().fill(.clear).glassEffect(in: .capsule).frame(width: 62)
                    ForEach(yearMarkers(height: height), id: \.index) { marker in
                        Button(String(marker.year)) { choose(marker.index, year: marker.year); scheduleDismiss() }
                            .font(.caption2.monospacedDigit().weight(.semibold)).frame(width: 62, height: 44)
                            .position(x: 13, y: marker.y + 24)
                            .accessibilityLabel("Jump to \(String(marker.year))")
                    }
                    if buckets.indices.contains(activeIndex) {
                        lens(index: activeIndex)
                            .frame(width: max(120, min(250, viewportWidth - 110)), alignment: .leading)
                            .offset(x: -66)
                            .position(x: -60, y: min(max(100, fraction(activeIndex) * height + 24), geometry.size.height - 100))
                            .allowsHitTesting(false)
                    }
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.bold))
                    .frame(width: 36, height: 48).glassEffect(.regular.interactive())
                    .overlay(alignment: .center) { Capsule().fill(.cyan).frame(width: 18, height: 2) }
                    .position(x: 24, y: puckFraction * height + 24)
                    .opacity(visible || expanded ? 1 : 0)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                dismissTask?.cancel(); visible = true; expanded = true
                let target = Int(min(1, max(0, (value.location.y - 24) / height)) * Double(total))
                var sum = 0
                let index = buckets.firstIndex { sum += $0.count; return sum > target } ?? max(0, buckets.count - 1)
                if selected != index { choose(index); UISelectionFeedbackGenerator().selectionChanged() }
            }.onEnded { _ in scheduleDismiss() })
            .onTapGesture { expanded = true; visible = true; scheduleDismiss(delay: .seconds(3)) }
            .accessibilityElement(children: expanded ? .contain : .ignore)
            .accessibilityLabel("Timeline month")
            .accessibilityValue(buckets.indices.contains(activeIndex) ? month(buckets[activeIndex].date) : "Library")
            .accessibilityAdjustableAction { direction in
                choose(min(buckets.count - 1, max(0, activeIndex + (direction == .increment ? 1 : -1))))
            }.accessibilityIdentifier("library.timeRail")
        }
        .task { scheduleDismiss() }
        .onChange(of: store.navigation.isScrolling) { _, scrolling in
            if scrolling { dismissTask?.cancel(); visible = true; selected = nil; yearSelection = nil }
            else { scheduleDismiss() }
        }
        .onDisappear { dismissTask?.cancel() }
    }

    private var puckFraction: CGFloat {
        if selected != nil { return fraction(activeIndex) }
        let before = buckets.prefix(max(0, store.navigation.section)).reduce(0) { $0 + $1.count }
        return min(1, max(0, CGFloat(before + store.navigation.item) / CGFloat(total)))
    }
    private func fraction(_ index: Int) -> CGFloat { CGFloat(buckets.prefix(index).reduce(0) { $0 + $1.count }) / CGFloat(total) }
    private func year(_ bucket: TimeBucket) -> Int? {
        guard let date = bucket.date else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.component(.year, from: date)
    }
    private func yearMarkers(height: CGFloat) -> [(index: Int, year: Int, y: CGFloat)] {
        var result: [(index: Int, year: Int, y: CGFloat)] = []
        var previous: Int?
        for (index, bucket) in buckets.enumerated() {
            guard let value = year(bucket), value != previous else { continue }
            previous = value
            let y = fraction(index) * height
            if y - (result.last?.y ?? -44) >= 44 { result.append((index, value, y)) }
        }
        return result
    }
    private func lens(index: Int) -> some View {
        let bucket = buckets[index]
        let count = yearSelection.map { y in buckets.filter { year($0) == y }.reduce(0) { $0 + $1.count } } ?? bucket.count
        let places = yearSelection == nil ? store.placeSummary(section: index) : nil
        return VStack(alignment: .leading, spacing: 10) {
            Text(yearSelection.map(String.init) ?? month(bucket.date)).font(.title2.bold()).lineLimit(2)
            if let places { Text(places).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            Text("\(count.formatted()) items").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(16).glassEffect(in: .rect(cornerRadius: 24))
    }
    private func month(_ date: Date?) -> String {
        guard let date else { return "Library" }
        var style = Date.FormatStyle().month(.abbreviated).year(); style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }
    private func choose(_ index: Int, year: Int? = nil) {
        guard buckets.indices.contains(index) else { return }
        selected = index; yearSelection = year; expanded = true; visible = true
        store.scrollToBucket(index)
    }
    private func scheduleDismiss(delay: Duration = .milliseconds(800)) {
        dismissTask?.cancel()
        dismissTask = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expanded = false; visible = false }
            selected = nil; yearSelection = nil
        }
    }
}

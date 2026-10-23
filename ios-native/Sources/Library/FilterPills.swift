import SwiftUI

/// A filter pill's face: a person's face or an album's cover as a round icon, or a symbol, then the
/// title, a search's match count and the small X (REBUILD_ROADMAP.md N6). Drawn alike in the pill
/// and in a shelf row rising into it, so the row arrives as the pill with nothing left to change.
/// The X is only drawn here; the pill lays its button over it.
struct FilterPillLabel: View {
    let icon: FilterPill.Icon
    let title: String
    var count: Int? = nil
    let api: APIClient
    let pipeline: MediaPipeline
    /// A shelf row rising into the pill matches its face and title to the row's own, so the face
    /// slides to the front and the title follows.
    var morph: Namespace.ID? = nil

    /// A capsule's height, as the search chips under the bar have.
    static let height: CGFloat = 44
    /// The round icon, inset so its circle shares the capsule's center of curvature.
    static let iconSide: CGFloat = 32
    static let iconInset: CGFloat = 6
    /// The X's column at the trailing end, which its button covers: its glyph sits where a search
    /// chip's does.
    static let removeWidth: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            iconView
                .frame(width: Self.iconSide, height: Self.iconSide)
                .modifier(Matched(id: "face", namespace: morph, properties: .frame))
                .padding(.leading, Self.iconInset)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                .modifier(Matched(id: "title", namespace: morph, properties: .position))
                .padding(.leading, 8)
            if let count {
                Text(count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.cyan)
                    .padding(.leading, 6)
                    .accessibilityLabel("\(count.formatted()) matches")
            }
            Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                .frame(width: Self.removeWidth, height: Self.height)
                .accessibilityHidden(true)
        }
        .frame(height: Self.height)
    }

    /// A matched geometry effect, only in a namespace given.
    private struct Matched: ViewModifier {
        let id: String
        let namespace: Namespace.ID?
        let properties: MatchedGeometryProperties
        func body(content: Content) -> some View {
            if let namespace { content.matchedGeometryEffect(id: id, in: namespace, properties: properties) } else { content }
        }
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case .person(let person):
            PersonThumbnail(pipeline: pipeline, person: person, pixelSize: PersonThumbnail.small).clipShape(.circle)
        case .cover(let assetID):
            FeatureThumbnail(api: api, pipeline: pipeline, assetID: assetID).clipShape(.circle)
        case .symbol(let name):
            Image(systemName: name).font(.subheadline.weight(.semibold))
        }
    }
}

/// One filter pill at the top of the feed (REBUILD_ROADMAP.md N6): a glass capsule tinted with the
/// cyan a choice in force wears, as the search chips under the bar are. Its X removes only its
/// layer; a tap or a drag on the rest brings back the shelves of its group with its row under the
/// finger. While the shelves are out it is hidden completely, glass included, and its X leaves the
/// hierarchy, yet it keeps its place, which a chosen row rises into.
struct FilterPillView: View {
    let pill: FilterPill
    let hidden: Bool
    /// After a row has risen into the pill it shows at once, as the row already showed it.
    let instant: Bool
    let api: APIClient
    let pipeline: MediaPipeline
    let onRemove: () -> Void
    let onOpen: () -> Void
    let onDrag: (DragGesture.Value) -> Void
    let onDragEnd: (DragGesture.Value) -> Void
    let onFrame: (CGRect) -> Void

    /// The search chips' glass, which a rising row takes on as it becomes the pill.
    static let glass = Glass.clear.tint(.cyan.opacity(0.2)).interactive()

    var body: some View {
        FilterPillLabel(icon: pill.icon, title: pill.title, count: pill.count, api: api, pipeline: pipeline)
            .opacity(hidden ? 0 : 1)
            .animation(hidden || instant ? nil : .easeOut(duration: 0.2), value: hidden)
            // Glass ignores an opacity around it, so a hidden pill has none.
            .glassEffect(hidden ? .identity : Self.glass, in: .capsule)
            .overlay(Capsule().strokeBorder(.cyan.opacity(hidden ? 0 : 0.85), lineWidth: 0.75))
            // The glass itself, which a rising row matches exactly.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("library")) } action: { onFrame($0) }
            .contentShape(.capsule)
            .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("library")).onChanged(onDrag).onEnded(onDragEnd))
            .onTapGesture(perform: onOpen)
            .overlay(alignment: .trailing) {
                if !hidden {
                    // A full 44 points, reaching a little over the title's end.
                    Button(action: onRemove) {
                        Color.clear.frame(width: 44, height: FilterPillLabel.height).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(pill.title)")
                    .accessibilityIdentifier("library.pill.\(pill.id).remove")
                }
            }
            .allowsHitTesting(!hidden)
            // Hidden, its title and face leave accessibility with its X.
            .accessibilityElement(children: hidden ? .ignore : .contain)
            .accessibilityIdentifier("library.pill.\(pill.id)")
            .accessibilityAction(named: "Show shelves", onOpen)
    }
}

/// Pills in lines from the leading edge (REBUILD_ROADMAP.md N6): in the order the filters were
/// chosen, a pill that doesn't fit starting the next line, so every layer stays in view. A new
/// filter's pill takes the next place, where its row rises to.
struct FilterPillFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = Self.frames(subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }, width: width, spacing: spacing)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) }
        for (subview, frame) in zip(subviews, Self.frames(sizes, width: bounds.width, spacing: spacing)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// Where each pill goes, in order along a line, wrapping when the next one doesn't fit; a pill
    /// wider than the line takes the line and its title shortens. Pure.
    static func frames(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for size in sizes {
            let size = CGSize(width: min(size.width, width), height: size.height)
            if x > 0, x + size.width > width {
                x = 0; y += line + spacing; line = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            line = max(line, size.height)
        }
        return frames
    }
}

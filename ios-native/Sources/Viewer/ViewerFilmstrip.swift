import SwiftUI
import UIKit

/// The Photos thumbnail strip: every photo the viewer can page through, with the one on screen
/// drawn wider. Swiping the strip scrubs through the photos and tapping one jumps to it; paging
/// the photos moves the strip along. Thumbnails come from memory first and from the media
/// pipeline otherwise, which decodes off the main thread. While the strip is being scrubbed only
/// stored thumbnails load, so the server is asked only for what the strip stops on.
///
/// Every thumbnail takes the same room in the layout, so a scroll offset always names one photo
/// and the strip snaps to whole thumbnails. The photo in the middle is only drawn wider, pushing
/// the others aside; mid-swipe the width passes from one thumbnail to the next as the middle moves.
struct ViewerFilmstrip: View {
    let pipeline: MediaPipeline
    let assets: [Asset]
    let replacements: [String: Asset]
    let selectedID: String
    /// The strip moved the selection, by a swipe or a tap on a thumbnail.
    let onSelect: (String) -> Void
    /// Scrubbing started or ended, so the viewer can hold slow work back while it lasts.
    let onScrubbingChange: (Bool) -> Void

    static let height = FilmstripGeometry.height

    @State private var position: ScrollPosition
    @State private var scrubbing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(pipeline: MediaPipeline, assets: [Asset], replacements: [String: Asset], selectedID: String,
         onSelect: @escaping (String) -> Void, onScrubbingChange: @escaping (Bool) -> Void) {
        self.pipeline = pipeline; self.assets = assets; self.replacements = replacements; self.selectedID = selectedID
        self.onSelect = onSelect; self.onScrubbingChange = onScrubbingChange
        _position = State(initialValue: ScrollPosition(id: selectedID, anchor: .center))
    }

    private var selectedIndex: Int { assets.firstIndex { $0.id == selectedID } ?? 0 }

    var body: some View {
        let shapes = FilmstripGeometry.Shapes(assets.map { (replacements[$0.id] ?? $0).aspectRatio })
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: FilmstripGeometry.spacing) {
                    ForEach(Array(assets.enumerated()), id: \.element.id) { index, summary in
                        FilmstripCell(pipeline: pipeline, asset: replacements[summary.id] ?? summary, index: index, shapes: shapes, settled: !scrubbing)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectHidden(true, for: .all)
            // Margins let the first and last thumbnails reach the middle, where the current one sits.
            .contentMargins(.horizontal, max(0, (proxy.size.width - FilmstripGeometry.width) / 2), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition($position, anchor: .center)
            .onScrollGeometryChange(for: Int.self) { geometry in
                // The offset counts from the leading margin, so a thumbnail sits in the middle when
                // the offset plus that margin is a whole number of thumbnails.
                Int(((geometry.contentOffset.x + geometry.contentInsets.leading) / FilmstripGeometry.pitch).rounded())
            } action: { _, index in
                // Only the finger moves the selection; the strip following the photos does not.
                guard scrubbing, assets.indices.contains(index), assets[index].id != selectedID else { return }
                onSelect(assets[index].id)
            }
            .onScrollPhaseChange { _, phase in
                let now = phase == .interacting || phase == .decelerating
                guard now != scrubbing else { return }
                scrubbing = now
                onScrubbingChange(now)
            }
            .onChange(of: selectedID) { _, id in
                guard !scrubbing else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { position.scrollTo(id: id, anchor: .center) }
            }
            // The strip opens, and stays after turning the phone, on the photo shown.
            .onChange(of: proxy.size.width, initial: true) { position.scrollTo(id: selectedID, anchor: .center) }
            // Thumbnails are drawn away from their layout slots, so a tap is matched to what is drawn.
            .contentShape(.rect)
            .onTapGesture { location in tap(at: location.x - proxy.size.width / 2, shapes: shapes) }
        }
        .frame(height: FilmstripGeometry.height)
        .accessibilityHidden(true)
        // One element the size of the strip on screen, which VoiceOver adjusts photo by photo.
        .overlay {
            Color.clear
                .accessibilityElement()
                .accessibilityLabel("Photo strip")
                .accessibilityValue("\(selectedIndex + 1) of \(assets.count)")
                .accessibilityIdentifier("viewer.strip")
                .accessibilityAdjustableAction { direction in
                    let next = selectedIndex + (direction == .increment ? 1 : -1)
                    if assets.indices.contains(next) { onSelect(assets[next].id) }
                }
        }
        .onDisappear { if scrubbing { scrubbing = false; onScrubbingChange(false) } }
    }

    /// The thumbnail drawn under a tap `x` points from the middle, as the strip rests on the
    /// current photo.
    private func tap(at x: CGFloat, shapes: FilmstripGeometry.Shapes) {
        guard !assets.isEmpty else { return }
        let middle = CGFloat(selectedIndex)
        let nearby = max(0, selectedIndex - 20)...min(assets.count - 1, selectedIndex + 20)
        guard let index = nearby.min(by: {
            abs(FilmstripGeometry.drawnCenter($0, middle: middle, shapes) - x) < abs(FilmstripGeometry.drawnCenter($1, middle: middle, shapes) - x)
        }), assets[index].id != selectedID else { return }
        onSelect(assets[index].id)
    }
}

/// Where the strip draws each thumbnail. Pure arithmetic, used while drawing as well as for taps.
enum FilmstripGeometry {
    static let width: CGFloat = 21
    static let height: CGFloat = 34
    static let spacing: CGFloat = 2
    static let pitch: CGFloat = width + spacing
    /// Extra black space either side of the photo in the middle.
    static let margin: CGFloat = 3

    /// Each photo's shape, width over height.
    struct Shapes: Sendable {
        let ratios: [CGFloat]
        init(_ ratios: [Double]) { self.ratios = ratios.map { CGFloat($0) } }

        /// The width photo `index` is drawn at in the middle, at its own shape within reason.
        func fullWidth(_ index: Int) -> CGFloat {
            guard ratios.indices.contains(index) else { return width }
            return max(width, height * min(1.8, max(0.55, ratios[index])))
        }

        /// The room photo `index` takes beyond an ordinary thumbnail when it is in the middle.
        func extraRoom(_ index: Int) -> CGFloat {
            ratios.indices.contains(index) ? fullWidth(index) + 2 * margin - width : 0
        }
    }

    /// How far thumbnail `index` is moved from its layout slot when the strip's middle is at
    /// `middle`, counted in thumbnails: whole at rest, between two mid-swipe. The two thumbnails
    /// either side of the middle share the extra room as the middle passes from one to the other.
    static func offset(_ index: Int, middle: CGFloat, _ shapes: Shapes) -> CGFloat {
        let left = Int(middle.rounded(.down)), progress = middle - CGFloat(left)
        let leftRoom = shapes.extraRoom(left) * (1 - progress), rightRoom = shapes.extraRoom(left + 1) * progress
        if index < left { return -(leftRoom + rightRoom) / 2 }
        if index == left { return -rightRoom / 2 }
        if index == left + 1 { return leftRoom / 2 }
        return (leftRoom + rightRoom) / 2
    }

    /// How wide thumbnail `index` is drawn: full width in the middle, ordinary a thumbnail away.
    static func drawnWidth(_ index: Int, middle: CGFloat, _ shapes: Shapes) -> CGFloat {
        let closeness = max(0, 1 - abs(CGFloat(index) - middle))
        return width + (shapes.fullWidth(index) - width) * closeness
    }

    /// Thumbnail `index`'s drawn center, in points from the middle of the strip.
    static func drawnCenter(_ index: Int, middle: CGFloat, _ shapes: Shapes) -> CGFloat {
        (CGFloat(index) - middle) * pitch + offset(index, middle: middle, shapes)
    }

    /// Where the strip's middle is, in thumbnails, seen from thumbnail `index` while drawing.
    static func middle(seenFrom index: Int, _ proxy: GeometryProxy) -> CGFloat? {
        guard let visible = proxy.bounds(of: .scrollView)?.width, visible > 0 else { return nil }
        let distance = (proxy.frame(in: .scrollView).midX - visible / 2) / pitch
        return CGFloat(index) - distance
    }
}

/// One thumbnail in its uniform slot, drawn wider and moved aside according to where the strip's
/// middle is. Both happen while drawing, so scrolling never lays the strip out again.
private struct FilmstripCell: View {
    let pipeline: MediaPipeline
    let asset: Asset
    let index: Int
    let shapes: FilmstripGeometry.Shapes
    let settled: Bool
    @State private var image: UIImage?
    @State private var imageKey: String?

    /// The grid's usual thumbnail size, so the strip mostly finds what the grid already decoded.
    private static let pixels = 300

    init(pipeline: MediaPipeline, asset: Asset, index: Int, shapes: FilmstripGeometry.Shapes, settled: Bool) {
        self.pipeline = pipeline; self.asset = asset; self.index = index; self.shapes = shapes; self.settled = settled
        let memory = Self.memory(pipeline, asset)
        _image = State(initialValue: memory)
        _imageKey = State(initialValue: memory == nil ? nil : Self.key(asset))
    }

    private static func key(_ asset: Asset) -> String { asset.id + "|" + asset.cacheRevision }

    /// Memory only: an exact match first, then the newest thumbnail of this photo at any size.
    private static func memory(_ pipeline: MediaPipeline, _ asset: Asset) -> UIImage? {
        (pipeline.cachedImage(for: asset, size: .thumbnail, pixelSize: pixels)
            ?? pipeline.latestImage(assetID: asset.id, size: .thumbnail, revision: asset.cacheRevision))?.uiImage
    }

    var body: some View {
        let index = index, shapes = shapes
        thumbnail
            .frame(width: shapes.fullWidth(index), height: FilmstripGeometry.height)
            .mask {
                Rectangle()
                    .frame(width: FilmstripGeometry.width, height: FilmstripGeometry.height)
                    .visualEffect { content, proxy in
                        let middle = FilmstripGeometry.middle(seenFrom: index, proxy) ?? CGFloat(index) + 1
                        return content.scaleEffect(x: FilmstripGeometry.drawnWidth(index, middle: middle, shapes) / FilmstripGeometry.width, y: 1)
                    }
            }
            .frame(width: FilmstripGeometry.width, height: FilmstripGeometry.height)
            .visualEffect { content, proxy in
                let middle = FilmstripGeometry.middle(seenFrom: index, proxy) ?? CGFloat(index)
                return content.offset(x: FilmstripGeometry.offset(index, middle: middle, shapes))
            }
            .task(id: Self.key(asset) + (settled ? "|settled" : "")) { await load() }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color(white: 0.16) }
    }

    private func load() async {
        let key = Self.key(asset)
        guard imageKey != key else { return }
        if let memory = Self.memory(pipeline, asset) { image = memory; imageKey = key; return }
        if let stored = await pipeline.storedThumbnail(for: asset, pixelSize: Self.pixels) {
            guard !Task.isCancelled else { return }
            image = stored.uiImage; imageKey = key; return
        }
        guard settled, !Task.isCancelled else { return }
        guard let fetched = try? await pipeline.image(for: asset, size: .thumbnail, pixelSize: Self.pixels), !Task.isCancelled else { return }
        image = fetched.uiImage; imageKey = key
    }
}

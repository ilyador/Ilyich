import SwiftUI
import UIKit

/// The Photos thumbnail strip: every photo the viewer can page through, with the one on screen
/// drawn wider. Swiping the strip scrubs through the photos and tapping one jumps to it; paging
/// the photos moves the strip along. Thumbnails come from memory first and from the media
/// pipeline otherwise, which decodes off the main thread. While the strip is being scrubbed only
/// stored thumbnails load, so the server is asked only for what the strip stops on.
struct ViewerFilmstrip: View {
    let pipeline: MediaPipeline
    let assets: [Asset]
    let replacements: [String: Asset]
    let selectedID: String
    /// The strip moved the selection, by a swipe or a tap on a thumbnail.
    let onSelect: (String) -> Void
    /// Scrubbing started or ended, so the viewer can hold slow work back while it lasts.
    let onScrubbingChange: (Bool) -> Void

    static let cell = CGSize(width: 21, height: 34)
    static let spacing: CGFloat = 2
    private static var pitch: CGFloat { cell.width + spacing }

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
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: Self.spacing) {
                    ForEach(assets) { summary in
                        let current = summary.id == selectedID
                        FilmstripCell(pipeline: pipeline, asset: replacements[summary.id] ?? summary, current: current, settled: !scrubbing)
                            .frame(width: Self.cell.width, height: Self.cell.height)
                            .zIndex(current ? 1 : 0)
                            .contentShape(.rect)
                            .onTapGesture { if summary.id != selectedID { onSelect(summary.id) } }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectHidden(true, for: .all)
            // Margins let the first and last thumbnails reach the middle, where the current one sits.
            .contentMargins(.horizontal, max(0, (proxy.size.width - Self.cell.width) / 2), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition($position, anchor: .center)
            .onScrollGeometryChange(for: Int.self) { geometry in
                // The offset counts from the leading margin, so a thumbnail sits in the middle when
                // the offset plus that margin is a whole number of thumbnails.
                Int(((geometry.contentOffset.x + geometry.contentInsets.leading) / Self.pitch).rounded())
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
        }
        .frame(height: Self.cell.height)
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
}

/// One thumbnail. The current photo is drawn over its neighbors at its own shape, set apart by a
/// black margin, so the strip's spacing never changes under the finger.
private struct FilmstripCell: View {
    let pipeline: MediaPipeline
    let asset: Asset
    let current: Bool
    let settled: Bool
    @State private var image: UIImage?
    @State private var imageKey: String?

    /// The grid's usual thumbnail size, so the strip mostly finds what the grid already decoded.
    private static let pixels = 300

    init(pipeline: MediaPipeline, asset: Asset, current: Bool, settled: Bool) {
        self.pipeline = pipeline; self.asset = asset; self.current = current; self.settled = settled
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
        thumbnail
            .frame(width: ViewerFilmstrip.cell.width, height: ViewerFilmstrip.cell.height)
            .clipped()
            .overlay {
                if current {
                    thumbnail
                        .frame(width: expandedWidth, height: ViewerFilmstrip.cell.height)
                        .clipShape(.rect(cornerRadius: 2))
                        .padding(.horizontal, 3)
                        .background(.black)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.2), value: current)
            .task(id: Self.key(asset) + (settled ? "|settled" : "")) { await load() }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color(white: 0.16) }
    }

    /// The current photo shows its own shape, within reason.
    private var expandedWidth: CGFloat {
        ViewerFilmstrip.cell.height * min(1.8, max(0.55, asset.aspectRatio))
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

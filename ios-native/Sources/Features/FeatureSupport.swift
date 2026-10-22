import SwiftUI

struct FeatureFailure: Identifiable {
    let id = UUID()
    let message: String
    init(_ error: Error) { message = error.localizedDescription }
}

struct FeatureEmpty: View {
    let title: String
    let symbol: String
    let description: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(description))
            .padding(.vertical, 36)
    }
}

/// The pixels a tile of `size` points decodes its thumbnail at: its short side, and no less than
/// the grid's smallest cell, so tiles and cells share one decoded copy.
@MainActor func tilePixels(_ size: CGSize, scale: CGFloat) -> Int {
    max(128, Int((min(size.width, size.height) * scale).rounded(.up)))
}

/// A tile that knows its photo only by ID: an album cover, a place, a memory. The offline library
/// names the photo and its revision, so the thumbnail comes through the thumbnail service with no
/// asset round trip; only a photo the library lacks is fetched first (T6).
struct FeatureThumbnail: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let assetID: String?
    /// Reloads the tile when it changes, as an album's cover may with its update time.
    var revision: String = ""
    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.displayScale) private var scale
    init(api: APIClient, pipeline: MediaPipeline, assetID: String?, revision: String = "") {
        self.api = api; self.pipeline = pipeline; self.assetID = assetID; self.revision = revision
        _image = State(initialValue: assetID.flatMap { pipeline.latestImage(assetID: $0, size: .thumbnail) }?.uiImage)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.secondary.opacity(0.12)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            .task(id: (assetID ?? "") + "|" + revision + "|" + String(tilePixels(geometry.size, scale: scale))) {
                failed = false
                guard let assetID else { image = nil; return }
                if let cached = pipeline.latestImage(assetID: assetID, size: .thumbnail) { image = cached.uiImage }
                guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                do {
                    let result = try await pipeline.thumbnail(assetID: assetID, shortSide: tilePixels(geometry.size, scale: scale),
                                                              fetch: { try await api.asset(id: $0) })
                    try Task.checkCancellation()
                    image = result.uiImage
                } catch is CancellationError { } catch { if image == nil { failed = true } }
            }
        }
        .accessibilityHidden(true)
    }
}

struct PersonThumbnail: View {
    let pipeline: MediaPipeline
    let person: Person
    let pixelSize: Int
    @State private var image: UIImage?
    /// Faces about 40 points across: shelf rows, the filter shelf and photo info. They share a
    /// cache that the photo grid cannot empty.
    static let small = 120
    init(pipeline: MediaPipeline, person: Person, pixelSize: Int = 360) {
        self.pipeline = pipeline; self.person = person; self.pixelSize = pixelSize
        // A face scrolled back into view draws at once instead of blank, then reloading.
        _image = State(initialValue: pipeline.cachedPersonImage(person: person, pixelSize: pixelSize)?.uiImage)
    }
    var body: some View {
        ZStack {
            Circle().fill(.secondary.opacity(0.12))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .clipShape(Circle())
        .task(id: person.id + (person.updatedAt?.description ?? "")) {
            do {
                let result = try await pipeline.personImage(person: person, pixelSize: pixelSize)
                try Task.checkCancellation()
                image = result.uiImage
            } catch is CancellationError { } catch { image = nil }
        }
        .accessibilityHidden(true)
    }
}

/// A tile for a photo it already has, such as the rail's lens or a duplicate: the thumbnail at the
/// tile's own size, through the thumbnail service.
struct FeatureAssetImage: View {
    let pipeline: MediaPipeline
    let asset: Asset
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale
    init(pipeline: MediaPipeline, asset: Asset) {
        self.pipeline = pipeline; self.asset = asset
        _image = State(initialValue: pipeline.latestImage(assetID: asset.id, size: .thumbnail, revision: asset.cacheRevision)?.uiImage)
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.secondary.opacity(0.12)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            .task(id: asset.id + "|" + asset.cacheRevision + "|" + String(tilePixels(geometry.size, scale: scale))) {
                guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                do {
                    let result = try await pipeline.image(for: asset, size: .thumbnail, pixelSize: tilePixels(geometry.size, scale: scale))
                    try Task.checkCancellation(); image = result.uiImage
                } catch { }
            }
        }.accessibilityHidden(true)
    }
}

struct FeatureAssetGrid: View {
    let pipeline: MediaPipeline
    let assets: [Asset]
    let onOpenAsset: (Asset) -> Void
    var body: some View {
        LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 2), count: 3), spacing: 2) {
            ForEach(assets) { asset in
                Button { onOpenAsset(asset) } label: {
                    FeatureAssetImage(pipeline: pipeline, asset: asset).aspectRatio(1, contentMode: .fit)
                        .overlay(alignment: .bottomTrailing) { if asset.isVideo { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(7).shadow(radius: 2) } }
                }.buttonStyle(.plain).accessibilityLabel(asset.displayName)
            }
        }
    }
}

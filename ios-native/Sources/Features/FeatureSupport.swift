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

/// The pixels a tile of `size` points decodes its thumbnail at: its long side, so a photo of any
/// shape aspect-fills it without being stretched (a shelf row is wide and low, and the photo's
/// shape is unknown here), and no less than the grid's smallest cell. Square tiles, which most
/// are, share one decoded copy with the grid's cells.
@MainActor func tilePixels(_ size: CGSize, scale: CGFloat) -> Int {
    max(128, Int((max(size.width, size.height) * scale).rounded(.up)))
}

/// The pixels a tile asks its thumbnail for: `tilePixels` rounded up to a power of two, and never
/// less than `requested`, what the tile asked for before. A tile whose frame follows the finger (a
/// shelf row grows from 64 to 244 points as the finger nears it) asks a few times on the way up
/// and never on the way back, instead of on every frame; a copy decoded for a larger size serves
/// the smaller, and a decode past the file's own size costs no more than the file.
@MainActor func tileRequest(_ size: CGSize, scale: CGFloat, atLeast requested: Int) -> Int {
    let pixels = tilePixels(size, scale: scale)
    var step = 128
    while step < pixels { step *= 2 }
    return max(step, requested)
}

/// What a feature tile shows and asks for, apart from SwiftUI so tests can drive it. The image is
/// of the photo the tile names: when the tile's photo changes, the old image goes at once and the
/// new one's copy in memory, if any, takes its place; a failure shows only while nothing of the
/// photo shows, so a sharper copy that fails to load leaves the one on screen. The size asked for
/// only rises (`tileRequest`).
@MainActor struct FeatureTileImage {
    private(set) var image: UIImage?
    private(set) var failed = false
    /// The photo `image` is of.
    private(set) var shownID: String?
    /// The largest size asked for so far, in pixels.
    private(set) var requested = 0
    /// The photo as the library or the server named it, kept for the sizes asked after the first.
    var named: (key: String, asset: Asset)?

    init(assetID: String?, cached: UIImage?) {
        shownID = assetID
        image = cached
    }

    /// A load of `assetID` at `pixels` begins; `cached` is its copy in memory, if any.
    mutating func begin(assetID: String?, pixels: Int, cached: UIImage?) {
        failed = false
        requested = max(requested, pixels)
        if assetID != shownID {
            shownID = assetID
            image = cached
        } else if let cached {
            image = cached
        }
    }

    /// The thumbnail of `assetID` arrived.
    mutating func loaded(_ image: UIImage, of assetID: String) {
        guard assetID == shownID else { return }
        self.image = image
        failed = false
    }

    /// The load failed: the tile says so only when it shows nothing of the photo.
    mutating func failedToLoad() {
        failed = image == nil
    }
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
    @State private var tile: FeatureTileImage
    @Environment(\.displayScale) private var scale
    init(api: APIClient, pipeline: MediaPipeline, assetID: String?, revision: String = "") {
        self.api = api; self.pipeline = pipeline; self.assetID = assetID; self.revision = revision
        _tile = State(initialValue: FeatureTileImage(assetID: assetID, cached: assetID.flatMap { pipeline.latestImage(assetID: $0, size: .thumbnail) }?.uiImage))
    }

    var body: some View {
        GeometryReader { geometry in
            let pixels = tileRequest(geometry.size, scale: scale, atLeast: tile.requested)
            let key = (assetID ?? "") + "|" + revision
            ZStack {
                Color.secondary.opacity(0.12)
                if let image = tile.image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if tile.failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            .task(id: key + "|" + String(pixels)) {
                tile.begin(assetID: assetID, pixels: pixels, cached: assetID.flatMap { pipeline.latestImage(assetID: $0, size: .thumbnail) }?.uiImage)
                guard let assetID, geometry.size.width > 0, geometry.size.height > 0 else { return }
                do {
                    // The library names the photo once; the sizes asked after the first reuse the name.
                    let asset: Asset
                    if let named = tile.named, named.key == key {
                        asset = named.asset
                    } else {
                        asset = try await pipeline.namedAsset(assetID, fetch: { try await api.asset(id: $0) })
                        try Task.checkCancellation()
                        tile.named = (key, asset)
                    }
                    let result = try await pipeline.image(for: asset, size: .thumbnail, pixelSize: pixels)
                    try Task.checkCancellation()
                    tile.loaded(result.uiImage, of: assetID)
                } catch is CancellationError { } catch { tile.failedToLoad() }
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
    @State private var tile: FeatureTileImage
    @Environment(\.displayScale) private var scale
    init(pipeline: MediaPipeline, asset: Asset) {
        self.pipeline = pipeline; self.asset = asset
        _tile = State(initialValue: FeatureTileImage(assetID: asset.id, cached: pipeline.latestImage(assetID: asset.id, size: .thumbnail, revision: asset.cacheRevision)?.uiImage))
    }
    var body: some View {
        GeometryReader { geometry in
            let pixels = tileRequest(geometry.size, scale: scale, atLeast: tile.requested)
            ZStack {
                Color.secondary.opacity(0.12)
                if let image = tile.image { Image(uiImage: image).resizable().scaledToFill() }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            .task(id: asset.id + "|" + asset.cacheRevision + "|" + String(pixels)) {
                tile.begin(assetID: asset.id, pixels: pixels,
                           cached: pipeline.latestImage(assetID: asset.id, size: .thumbnail, revision: asset.cacheRevision)?.uiImage)
                guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                do {
                    let result = try await pipeline.image(for: asset, size: .thumbnail, pixelSize: pixels)
                    try Task.checkCancellation(); tile.loaded(result.uiImage, of: asset.id)
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

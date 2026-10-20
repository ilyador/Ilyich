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

struct FeatureThumbnail: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let assetID: String?
    var revision: String = ""
    @State private var image: UIImage?
    @State private var failed = false
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
        }
        .task(id: (assetID ?? "") + revision) {
            failed = false
            guard let assetID else { image = nil; return }
            image = pipeline.latestImage(assetID: assetID, size: .thumbnail)?.uiImage
            do {
                let asset = try await api.asset(id: assetID)
                let result = try await pipeline.image(for: asset, size: .thumbnail, pixelSize: 600)
                try Task.checkCancellation()
                image = result.uiImage
            } catch is CancellationError { } catch { failed = true }
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

struct FeatureAssetImage: View {
    let pipeline: MediaPipeline
    let asset: Asset
    @State private var image: UIImage?
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
        }
        .task(id: asset.id + asset.cacheRevision) {
            do {
                let result = try await pipeline.image(for: asset, size: .thumbnail, pixelSize: 500)
                try Task.checkCancellation(); image = result.uiImage
            } catch is CancellationError { } catch { image = nil }
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

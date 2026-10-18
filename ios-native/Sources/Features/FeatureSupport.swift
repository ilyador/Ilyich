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
            image = nil; failed = false
            guard let assetID else { return }
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
    @State private var image: UIImage?
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
                let result = try await pipeline.personImage(person: person, pixelSize: 360)
                try Task.checkCancellation()
                image = result.uiImage
            } catch { image = nil }
        }
        .accessibilityHidden(true)
    }
}

struct FeatureAssetImage: View {
    let pipeline: MediaPipeline
    let asset: Asset
    @State private var image: UIImage?
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
            } catch { image = nil }
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

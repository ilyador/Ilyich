import SwiftUI
import UIKit

/// A small explanation over the existing preview; waiting never replaces the photo with a panel.
struct ViewerMediaNotice: View {
    let title: String
    var message: String? = nil
    var isLoading = false
    var progress: Double? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if isLoading { ProgressView().controlSize(.small).tint(.white) }
                Text(title).font(.subheadline.weight(.medium))
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            if let progress { ProgressView(value: progress).tint(.white) }
            if let retry {
                Button("Retry", action: retry).buttonStyle(.glass).frame(minHeight: 44)
                    .accessibilityIdentifier("viewer.mediaRetry")
            }
        }
        .padding(16).frame(maxWidth: 340)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
    }
}

/// Local-only preview, seeded from the same thumbnail cache as the feed. This never requests an
/// original, calculates a fingerprint or enables iCloud networking just to open a viewer.
struct ViewerLocalPoster: View {
    let photo: LocalPhoto
    var pipeline: MediaPipeline? = nil
    @State private var loaded: (key: ThumbnailKey, image: UIImage)?

    private var key: ThumbnailKey { .device(DeviceAssetID(rawValue: photo.id), modified: photo.modified.map(AssetRevision.init)) }
    private var image: UIImage? {
        if let loaded, loaded.key == key { return loaded.image }
        return pipeline?.latestImage(assetID: key.assetID, size: .thumbnail, revision: key.revision)?.uiImage
    }

    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityIdentifier("viewer.localPoster")
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .task(id: key) {
            let requestKey = key
            for await event in PhotoKitAdapter.shared.media(photo.id, .thumbnail(pixels: 1_280)) {
                guard !Task.isCancelled else { return }
                if case .image(let image, _) = event { loaded = (requestKey, image) }
            }
        }
    }
}

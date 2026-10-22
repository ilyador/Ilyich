import Foundation
@preconcurrency import Photos
import Synchronization
import UIKit

extension PhotoKitAdapter {
    /// Grid thumbnails of phone photos, over the app's one image manager (REBUILD_ROADMAP.md T6).
    nonisolated(unsafe) static let thumbnails = PhotoKitThumbnailImaging(manager: imageManager)
}

/// The app's one PHCachingImageManager as the thumbnail source drives it. The PHAssets of the
/// window Photos is caching are kept here, looked up in one fetch per batch off the main thread,
/// so stopping them needs no fetch and a thumbnail request for a photo in the window fetches
/// nothing at all. PhotoKit allows reading a PHAsset from any thread.
final class PhotoKitThumbnailImaging: DeviceThumbnailImaging, @unchecked Sendable {
    private let manager: PHCachingImageManager
    private let window = Mutex<[DeviceAssetID: PHAsset]>([:])

    init(manager: PHCachingImageManager) { self.manager = manager }

    /// The same options for caching and for requests, or Photos' cache never answers a request.
    private static func options() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return options
    }

    private static func size(_ pixels: Int) -> CGSize { CGSize(width: pixels, height: pixels) }

    func startCaching(_ ids: [DeviceAssetID], pixels: Int) {
        let missing = window.withLock { window in ids.filter { window[$0] == nil } }
        if !missing.isEmpty {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: missing.map(\.rawValue), options: nil)
            var found: [DeviceAssetID: PHAsset] = [:]
            fetched.enumerateObjects { asset, _, _ in found[DeviceAssetID(rawValue: asset.localIdentifier)] = asset }
            window.withLock { window in window.merge(found) { _, new in new } }
        }
        let assets = window.withLock { window in ids.compactMap { window[$0] } }
        guard !assets.isEmpty else { return }
        manager.startCachingImages(for: assets, targetSize: Self.size(pixels), contentMode: .aspectFill, options: Self.options())
    }

    func stopCaching(_ ids: [DeviceAssetID], pixels: Int) {
        let assets = window.withLock { window in ids.compactMap { window.removeValue(forKey: $0) } }
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(for: assets, targetSize: Self.size(pixels), contentMode: .aspectFill, options: Self.options())
    }

    func stopCachingAll() {
        window.withLock { $0 = [:] }
        manager.stopCachingImagesForAllAssets()
    }

    /// Synchronous, on the decode lane that asked: Photos answers from its cache at once for a
    /// photo it preheated, and renders the others on its own threads while the lane waits, as the
    /// lane waits for ImageIO on a server thumbnail.
    func thumbnail(_ id: DeviceAssetID, pixels: Int) -> DeviceThumbnailResult {
        let asset = window.withLock { $0[id] } ?? PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject
        guard let asset else { return .unavailable(inCloud: false) }
        let options = Self.options()
        options.isSynchronous = true
        let result = Mutex<DeviceThumbnailResult>(.unavailable(inCloud: false))
        manager.requestImage(for: asset, targetSize: Self.size(pixels), contentMode: .aspectFill, options: options) { image, info in
            let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
            let prepared = image.flatMap(PreparedImage.init(upright:))
            result.withLock { $0 = prepared.map(DeviceThumbnailResult.image) ?? .unavailable(inCloud: inCloud) }
        }
        return result.withLock { $0 }
    }
}

extension PreparedImage {
    /// Photos' image as the grid draws it, into a layer with no view to turn it: its bitmap when
    /// it is already upright, which Photos' renders are, else drawn upright here. Any thread.
    init?(upright image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        if image.imageOrientation == .up { self.init(cgImage: cgImage); return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let drawn = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let turned = drawn.cgImage else { return nil }
        self.init(cgImage: turned)
    }
}

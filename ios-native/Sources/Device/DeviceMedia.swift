import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Photos
import Synchronization
import UIKit

/// A photo or video on this phone, as screens show it.
struct LocalPhoto: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date?
    let modified: Date?
    let video: Bool
    let live: Bool
    let duration: Double
    let width: Int
    let height: Int
    let isFavorite: Bool
    let latitude: Double?
    let longitude: Double?
    var title: String { date?.formatted(date: .abbreviated, time: .shortened) ?? (video ? "Video" : "Photo") }
    init(_ asset: PHAsset) {
        id = asset.localIdentifier; date = asset.creationDate; modified = asset.modificationDate
        video = asset.mediaType == .video; live = asset.mediaSubtypes.contains(.photoLive); duration = asset.duration
        width = asset.pixelWidth; height = asset.pixelHeight; isFavorite = asset.isFavorite
        latitude = asset.location?.coordinate.latitude; longitude = asset.location?.coordinate.longitude
    }
    init(id: String, date: Date?, modified: Date? = nil, video: Bool = false, live: Bool = false,
         duration: Double = 0, width: Int = 0, height: Int = 0, isFavorite: Bool = false,
         latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id; self.date = date; self.modified = modified; self.video = video; self.live = live
        self.duration = duration; self.width = width; self.height = height; self.isFavorite = isFavorite
        self.latitude = latitude; self.longitude = longitude
    }
}

/// What a screen asks Photos to draw or play.
enum DeviceMediaRequest: Hashable, Sendable {
    /// A grid cell: a fast, square-filling image at about `pixels`, never from iCloud.
    case thumbnail(pixels: CGFloat)
    /// A viewer page: the current version fitted in `pixels`, or at full size when nil.
    case image(pixels: CGFloat?, network: Bool)
    case video(network: Bool)
    case livePhoto(pixels: CGFloat, network: Bool)
}

/// What a media request delivers. Photos may send a degraded image first, then the final one.
/// A request that ends without media sends `unavailable` last. Delivered once and then used only
/// by the screen that asked, so the media itself crosses no other thread.
enum DeviceMediaEvent: @unchecked Sendable {
    case image(UIImage, final: Bool)
    case player(AVPlayerItem)
    case livePhoto(PHLivePhoto, final: Bool)
    /// `message` is Photos' own reason, when it gave one.
    case unavailable(inCloud: Bool, message: String?)
}

/// A still Photos rendered for sharing, with the name of the file it came from.
struct DeviceStill: @unchecked Sendable {
    let image: UIImage
    let filename: String
}

/// Resumes a share's still exactly once: with Photos' answer, or on cancellation, whichever
/// comes first, even before the request starts.
private final class StillResult: Sendable {
    private let state = Mutex<(waiting: CheckedContinuation<DeviceStill, any Error>?, result: Result<DeviceStill, any Error>?)>((nil, nil))

    /// Keeps `continuation` for the answer. False when the answer came first; it is resumed then.
    func wait(_ continuation: CheckedContinuation<DeviceStill, any Error>) -> Bool {
        let early = state.withLock { state -> Result<DeviceStill, any Error>? in
            if state.result == nil { state.waiting = continuation }
            return state.result
        }
        if let early { continuation.resume(with: early); return false }
        return true
    }

    func finish(_ result: Result<DeviceStill, any Error>) {
        let waiting = state.withLock { state -> CheckedContinuation<DeviceStill, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(with: result)
    }
}

/// The Photos request behind a media stream, cancelled when the stream ends however it ends.
private final class MediaRequestHandle: Sendable {
    private let state = Mutex<(id: PHImageRequestID?, cancelled: Bool)>((nil, false))

    func started(_ id: PHImageRequestID) {
        let cancelled = state.withLock { state -> Bool in
            if !state.cancelled { state.id = id }
            return state.cancelled
        }
        if cancelled { PhotoKitAdapter.imageManager.cancelImageRequest(id) }
    }

    func cancel() {
        let id = state.withLock { state -> PHImageRequestID? in
            state.cancelled = true
            defer { state.id = nil }
            return state.id
        }
        if let id { PhotoKitAdapter.imageManager.cancelImageRequest(id) }
    }
}

extension PhotoKitAdapter {
    /// The app's one image manager (architecture section 1). PhotoKit allows it on any thread.
    nonisolated(unsafe) static let imageManager = PHCachingImageManager()

    static let unavailableMessage = "This item is no longer available to Ilyich."

    /// Media for one asset, as Photos delivers it. The asset is looked up off the main thread, and
    /// dropping the stream cancels the request.
    nonisolated func media(_ localID: String, _ request: DeviceMediaRequest) -> AsyncStream<DeviceMediaEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceMediaEvent.self)
        let handle = MediaRequestHandle()
        let starter = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else {
                continuation.yield(.unavailable(inCloud: false, message: Self.unavailableMessage)); continuation.finish(); return
            }
            handle.started(Self.start(request, asset: asset, continuation: continuation))
        }
        continuation.onTermination = { _ in starter.cancel(); handle.cancel() }
        return stream
    }

    private nonisolated static func start(_ request: DeviceMediaRequest, asset: PHAsset,
                                          continuation: AsyncStream<DeviceMediaEvent>.Continuation) -> PHImageRequestID {
        let manager = imageManager
        switch request {
        case .video(let network):
            let options = PHVideoRequestOptions(); options.version = .current; options.deliveryMode = .automatic; options.isNetworkAccessAllowed = network
            return manager.requestPlayerItem(forVideo: asset, options: options) { item, info in
                let outcome = Outcome(info)
                guard !outcome.cancelled else { continuation.finish(); return }
                if let item { continuation.yield(.player(item)) }
                else { continuation.yield(.unavailable(inCloud: outcome.inCloud, message: outcome.error)) }
                continuation.finish()
            }
        case .livePhoto(let pixels, let network):
            let options = PHLivePhotoRequestOptions(); options.version = .current; options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = network
            return manager.requestLivePhoto(for: asset, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFit, options: options) { live, info in
                let outcome = Outcome(info)
                guard !outcome.cancelled else { continuation.finish(); return }
                if let live { continuation.yield(.livePhoto(live, final: !outcome.degraded)) }
                guard !outcome.degraded else { return }
                if live == nil { continuation.yield(.unavailable(inCloud: outcome.inCloud, message: outcome.error)) }
                continuation.finish()
            }
        case .thumbnail, .image:
            let options = PHImageRequestOptions(); options.version = .current; options.deliveryMode = .opportunistic
            let targetSize: CGSize, contentMode: PHImageContentMode
            switch request {
            case .thumbnail(let pixels):
                options.resizeMode = .fast; options.isNetworkAccessAllowed = false
                targetSize = CGSize(width: pixels, height: pixels); contentMode = .aspectFill
            case .image(let pixels, let network):
                options.resizeMode = pixels == nil ? .none : .fast; options.isNetworkAccessAllowed = network
                targetSize = pixels.map { CGSize(width: $0, height: $0) } ?? PHImageManagerMaximumSize; contentMode = .aspectFit
            default: fatalError("Handled above.")
            }
            return manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
                let outcome = Outcome(info)
                guard !outcome.cancelled else { continuation.finish(); return }
                if let image { continuation.yield(.image(image, final: !outcome.degraded)) }
                guard !outcome.degraded else { return }
                if image == nil { continuation.yield(.unavailable(inCloud: outcome.inCloud, message: outcome.error)) }
                continuation.finish()
            }
        }
    }

    /// The still a share sends in place of the original: the current version fitted in 2048
    /// pixels, at full quality, with the name of the file it came from.
    nonisolated func shareStill(of localID: String, allowCloud: Bool,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> DeviceStill {
        try Task.checkCancellation()
        let found = try await Task.detached(priority: .userInitiated) { () -> (PHAsset, String)? in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return nil }
            let name = ((PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Photo") as NSString).lastPathComponent
            return (asset, name)
        }.value
        guard let (asset, filename) = found else {
            throw BackupError.item("This photo is no longer available to Ilyich. Check Photos access and retry.")
        }
        let handle = MediaRequestHandle()
        let result = StillResult()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<DeviceStill, any Error>) in
                guard result.wait(done) else { return }
                let options = PHImageRequestOptions(); options.version = .current; options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = allowCloud; options.progressHandler = { value, _, _, _ in progress(value) }
                handle.started(Self.imageManager.requestImage(for: asset, targetSize: CGSize(width: 2048, height: 2048), contentMode: .aspectFit, options: options) { image, info in
                    let outcome = Outcome(info)
                    guard !outcome.degraded else { return }
                    if let image { result.finish(.success(DeviceStill(image: image, filename: filename))) }
                    else if outcome.cancelled { result.finish(.failure(CancellationError())) }
                    else { result.finish(.failure(BackupError.message("This photo could not be prepared. If it is stored in iCloud, allow iCloud downloads and retry."))) }
                })
            }
        } onCancel: {
            handle.cancel(); result.finish(.failure(CancellationError()))
        }
    }

    /// What Photos' info dictionary says about one delivery.
    private struct Outcome {
        let cancelled: Bool
        let degraded: Bool
        let inCloud: Bool
        let error: String?
        init(_ info: [AnyHashable: Any]?) {
            cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
            error = (info?[PHImageErrorKey] as? any Error)?.localizedDescription
        }
    }
}

import Foundation
import IlyichPlatform
import AVFoundation
import Photos

/// Offline fallback is allowed only for a direct network failure on unedited server media whose
/// matched Photos asset still shows what it showed when matched. A favorite or another change
/// that leaves the photo itself alone keeps the match.
enum LocalMediaFallback {
    enum Kind { case video, motion }

    @MainActor
    static func photo(after error: Error, asset: Asset, matched: LocalPhoto?, active: Bool, kind: Kind? = nil,
                      device: PhotoKitAdapter = .shared) async -> LocalPhoto? {
        guard TransportFailure.isDefinite(error) else { return nil }
        return await matchedPhoto(asset: asset, matched: matched, active: active, kind: kind, device: device)
    }

    /// A proven local rendition may play while the remote video is being prepared. This does
    /// not turn an HTTP refusal into permission: the caller admits and fences account access.
    @MainActor
    static func matchedPhoto(asset: Asset, matched: LocalPhoto?, active: Bool, kind: Kind? = nil,
                             device: PhotoKitAdapter = .shared) async -> LocalPhoto? {
        guard active, asset.visibility != .locked, !asset.isTrashed,
              asset.hasKnownEditState, !asset.isDeveloped, !asset.isEdited, !asset.isAnimatedImage,
              let photo = matched else { return nil }
        switch kind {
        case .video: guard photo.video else { return nil }
        case .motion: guard photo.live else { return nil }
        case nil: break
        }
        return await isUnchanged(photo, device: device) ? photo : nil
    }

    static func isUnchanged(_ photo: LocalPhoto, device: PhotoKitAdapter = .shared) async -> Bool {
        await device.contentUnchanged(of: photo.id, since: photo.modified)
    }
}

/// Local playback never initiates an iCloud download, and checks the match again after Photos
/// delivers its player item. Account/request guards are supplied by the owning viewer page.
@MainActor enum MatchedVideoPlayback {
    enum Media {
        case player(AVPlayerItem)
        case livePhoto(PHLivePhoto)
    }

    static func load(photo: LocalPhoto, motion: Bool, device: any DeviceMediaProviding = PhotoKitAdapter.shared,
                     unchanged: () async -> Bool, permits: () -> Bool) async -> Media? {
        guard motion ? photo.live : photo.video else { return nil }
        guard permits(), !Task.isCancelled, await unchanged(), permits(), !Task.isCancelled else { return nil }
        let kind: DeviceMediaRequest = motion ? .livePhoto(pixels: 1600, network: false) : .video(network: false)
        for await event in device.media(photo.id, kind) {
            guard permits(), !Task.isCancelled else { return nil }
            let media: Media
            switch event {
            case .player(let item) where !motion: media = .player(item)
            case .livePhoto(let live, _) where motion: media = .livePhoto(live)
            case .unavailable: return nil
            default: continue
            }
            guard await unchanged(), permits(), !Task.isCancelled else { return nil }
            return media
        }
        return nil
    }
}

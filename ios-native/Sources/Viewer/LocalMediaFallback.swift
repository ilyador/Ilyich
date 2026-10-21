import Foundation
import IlyichPlatform

/// Offline fallback is allowed only for a direct network failure on unedited server media whose
/// matched Photos asset still shows what it showed when matched. A favorite or another change
/// that leaves the photo itself alone keeps the match.
enum LocalMediaFallback {
    enum Kind { case video, motion }

    @MainActor
    static func photo(after error: Error, asset: Asset, matched: LocalPhoto?, active: Bool, kind: Kind? = nil,
                      device: PhotoKitAdapter = .shared) async -> LocalPhoto? {
        guard active, TransportFailure.isDefinite(error),
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

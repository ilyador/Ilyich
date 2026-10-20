import Foundation
import IlyichPlatform

/// Offline fallback is allowed only for a direct network failure on unedited
/// server media whose matched Photos asset has not been modified since matching.
enum LocalMediaFallback {
    enum Kind { case video, motion }

    @MainActor
    static func photo(after error: Error, asset: Asset, matched: LocalPhoto?, active: Bool, kind: Kind? = nil) -> LocalPhoto? {
        guard active, TransportFailure.isDefinite(error),
              asset.hasKnownEditState, !asset.isDeveloped, !asset.isEdited, !asset.isAnimatedImage,
              let photo = matched, isUnchanged(photo) else { return nil }
        switch kind {
        case .video: guard photo.video else { return nil }
        case .motion: guard photo.live else { return nil }
        case nil: break
        }
        return photo
    }

    @MainActor
    static func isUnchanged(_ photo: LocalPhoto) -> Bool { DevicePhotos.modificationDate(for: photo.id) == photo.modified }
}

import Foundation

struct CleanupPolicy: Equatable, Sendable {
    let cutoff: Date
    let keepFavorites: Bool
    /// "none" keeps neither type, "photos" keeps photos, "videos" keeps videos.
    let keepMediaType: String

    func allows(date: Date?, favorite: Bool, video: Bool, inKeptAlbum: Bool) -> Bool {
        guard let date, date < cutoff, !inKeptAlbum else { return false }
        if keepFavorites && favorite { return false }
        if keepMediaType == "photos" && !video { return false }
        if keepMediaType == "videos" && video { return false }
        // Unknown persisted settings must not broaden deletion eligibility.
        return ["none", "photos", "videos"].contains(keepMediaType)
    }
}

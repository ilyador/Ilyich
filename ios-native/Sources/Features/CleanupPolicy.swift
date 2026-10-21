import Foundation

/// Whether Free up space may remove photos from the phone. It stays off until P4's cleanup service,
/// which checks every candidate against the deletion-safety rules. Until then only the legacy
/// verifier would guard a removal, on a phone that installs every build. Checking still lists what
/// would be removed. P4 turns this on, then deletes it and its test.
enum CleanupRemoval {
    static let isEnabled = false
}

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

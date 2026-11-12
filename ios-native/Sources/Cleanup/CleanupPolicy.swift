import Foundation

/// Release switch for Free up space. The owner-attended 30-photo PhotoKit acceptance passed
/// on iPhone 13 Pro Max on 2026-11-11; see REVIEW_FIXES_2026-11-11.md for evidence and scope.
/// Every removal still needs fresh backup verification, current permissions and Photos consent.
enum CleanupRemovalGate {
    static let isOpen = true
}

struct CleanupPolicy: Equatable, Sendable {
    let cutoff: Date
    let keepFavorites: Bool
    /// "none" keeps neither type, "photos" keeps photos, "videos" keeps videos.
    let keepMediaType: String

    func allows(date: Date?, favorite: Bool, video: Bool, inKeptAlbum: Bool) -> Bool {
        exclusion(date: date, favorite: favorite, video: video, inKeptAlbum: inKeptAlbum) == nil
    }

    /// Why the settings keep this photo, or nil when they let it go. Unknown persisted settings
    /// must not broaden deletion eligibility, so they keep everything.
    func exclusion(date: Date?, favorite: Bool, video: Bool, inKeptAlbum: Bool) -> CleanupExclusion? {
        guard ["none", "photos", "videos"].contains(keepMediaType) else { return .settingsUnreadable }
        guard let date, date < cutoff else { return .tooRecent }
        if inKeptAlbum { return .keptAlbum }
        if keepFavorites && favorite { return .favorite }
        if keepMediaType == "photos" && !video { return .keptMediaType }
        if keepMediaType == "videos" && video { return .keptMediaType }
        return nil
    }
}

/// Why a backed-up phone photo is not offered for removal. Every one keeps the photo.
enum CleanupExclusion: String, CaseIterable, Hashable, Sendable {
    // On the phone
    case changedSinceBackup
    case edited
    case multipleOriginals
    case unsupportedShape
    case livePhotoWithoutVideoBackup
    case notDeletable
    // Settings
    case tooRecent
    case favorite
    case keptMediaType
    case keptAlbum
    case settingsUnreadable
    // On the server
    case notOnServer
    case otherOwner
    case checksumMismatch
    case inServerTrash
    case inLockedFolder
    case serverCopyOffline
    case livePairMismatch
    case serverRefused
    case serverError
    case unreachable
    case unreadableAnswer

    /// What the screen says, in plain words.
    var reason: String {
        switch self {
        case .changedSinceBackup: "Changed on this phone since its backup"
        case .edited: "Edited in Photos"
        case .multipleOriginals: "Has more than one original, such as RAW and JPEG"
        case .unsupportedShape: "Made of files Ilyich can’t check"
        case .livePhotoWithoutVideoBackup: "Live Photo whose video isn’t backed up"
        case .notDeletable: "Photos doesn’t allow removing it, as in a shared album"
        case .tooRecent: "Taken on or after the date chosen"
        case .favorite: "Favorite"
        case .keptMediaType: "Media type you keep"
        case .keptAlbum: "In an album you keep"
        case .settingsUnreadable: "Your keep settings couldn’t be read"
        case .notOnServer: "Not found on your server"
        case .otherOwner: "Server copy belongs to another user"
        case .checksumMismatch: "Server copy is a different file"
        case .inServerTrash: "Server copy is in the trash"
        case .inLockedFolder: "Server copy is in the Locked Folder"
        case .serverCopyOffline: "Server copy is offline"
        case .livePairMismatch: "Server copy’s Live Photo video doesn’t match"
        case .serverRefused: "Your server refused to show the copy"
        case .serverError: "Your server couldn’t check the copy"
        case .unreachable: "Couldn’t reach your server"
        case .unreadableAnswer: "Couldn’t read your server’s answer"
        }
    }
}

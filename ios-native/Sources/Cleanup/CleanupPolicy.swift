import Foundation

/// The one switch that lets Free up space remove photos from the phone. It stays closed until the
/// owner has run P4's device acceptance gate with 30 disposable photos (REBUILD_ROADMAP.md P4):
/// a photo removed here may have its only other copy on the server. While it is closed, checking
/// still lists the real candidates and why every other backed-up photo stays, Remove stays
/// unavailable, and CleanupService refuses to ask Photos for anything. Opening it is a one-line
/// change here, plus deleting testFreeUpSpaceRemoveStaysClosedUntilTheDeviceGate.
enum CleanupRemovalGate {
    static let isOpen = false
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

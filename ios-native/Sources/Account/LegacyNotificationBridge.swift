import Foundation

/// Re-posts the account's changes as the notifications LibraryView, AssetViewer and Diagnostics
/// still observe, with the names and keys they always had. A temporary adapter: N4 deletes it
/// together with the notifications (architecture section 9).
@MainActor enum LegacyNotificationBridge {
    /// The library of the account `scope` names changed. `collections` asks for the shelves to
    /// reload; `accessChanged` says photos may have become unavailable.
    static func libraryChanged(scope: String, collections: Bool, accessChanged: Bool) {
        NotificationCenter.default.post(name: .ilyichLibraryChanged, object: nil,
                                        userInfo: ["scope": scope, "collections": collections, "accessChanged": accessChanged])
    }

    /// What the account `scope` names keeps on the phone was cleared or changed, so the feed reloads.
    static func cachesReset(scope: String) {
        NotificationCenter.default.post(name: .ilyichCachesReset, object: nil, userInfo: ["scope": scope])
    }
}

extension Notification.Name {
    static let ilyichLibraryChanged = Notification.Name("ilyich.libraryChanged")
    static let ilyichCachesReset = Notification.Name("IlyichCachesReset")
}

import Foundation

/// Re-posts the account's changes as the notifications LibraryView, AssetViewer and Diagnostics
/// still observe, with the names and keys they always had. A temporary adapter: N4 deletes it
/// together with the notifications (architecture section 9).
@MainActor enum LegacyNotificationBridge {
    /// The library of the account `scope` names changed. `collections` asks for the shelves to
    /// reload; `accessChanged` says photos may have become unavailable.
    /// `change`, when the sync published one, rides along so search results can drop its deletions.
    static func libraryChanged(scope: String, collections: Bool, accessChanged: Bool, change: LibraryChange? = nil) {
        var info: [String: Any] = ["scope": scope, "collections": collections, "accessChanged": accessChanged]
        if let change { info["change"] = change }
        NotificationCenter.default.post(name: .ilyichLibraryChanged, object: nil, userInfo: info)
    }

    /// A change the account's sync published. The shelves reload for albums, people, partners,
    /// memories, a configuration change or a reset; a change to photos alone reloads the feed.
    static func libraryChanged(_ change: LibraryChange, scope: String, accessChanged: Bool) {
        let collections = !change.albums.isEmpty || !change.people.isEmpty || change.partnersChanged || change.memoriesChanged
            || change.configurationChanged || change.reset || change.overflow
        libraryChanged(scope: scope, collections: collections, accessChanged: accessChanged, change: change)
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

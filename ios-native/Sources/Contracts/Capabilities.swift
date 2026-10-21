import Foundation

/// An action the viewer, the selection actions, the info sheet or a stack can offer for an asset.
enum AssetAction: String, CaseIterable, Hashable, Sendable {
    case favorite, archive, lock, trash, deletePermanently, restore
    case addToAlbum, albumCover, profilePhoto, sharedLink, stack
    case edit, findSimilar, cast, openInBrowser, comments
    case download, share, saveToPhotos
    /// Reading the photo's text.
    case selectText
    /// Changing what the info sheet shows: date, location, caption, rating, faces and tags.
    case editInfo
}

enum ActionAvailability: Hashable, Sendable {
    case offered
    /// Shown but unavailable, with the reason to give.
    case disabled(String)
    case hidden
}

/// What every action is for one asset, or for a selection.
struct AssetCapabilities: Hashable, Sendable {
    /// Hidden actions have no entry, so two equal sets of capabilities compare equal.
    private var availability: [AssetAction: ActionAvailability] = [:]

    init() {}

    subscript(action: AssetAction) -> ActionAvailability {
        get { availability[action] ?? .hidden }
        set { availability[action] = newValue == .hidden ? nil : newValue }
    }

    /// Whether the action appears, perhaps disabled.
    func shows(_ action: AssetAction) -> Bool { self[action] != .hidden }
    /// Whether the action can be used now.
    func offers(_ action: AssetAction) -> Bool { self[action] == .offered }

    /// What both allow: an action either hides is hidden, and one either disables is disabled.
    func intersection(_ other: AssetCapabilities) -> AssetCapabilities {
        var result = AssetCapabilities()
        for action in AssetAction.allCases {
            switch (self[action], other[action]) {
            case (.hidden, _), (_, .hidden): result[action] = .hidden
            case (.disabled(let reason), _), (_, .disabled(let reason)): result[action] = .disabled(reason)
            case (.offered, .offered): result[action] = .offered
            }
        }
        return result
    }
}

/// What an asset's actions depend on besides the asset.
struct CapabilityContext: Sendable {
    /// The signed-in user. Only an asset's owner changes it.
    let viewerID: String?
    /// Whether the account may change anything now, which read-only mode stops. Once C6's
    /// authorization state exists this is its snapshot's `allows(.write)`.
    let writable: Bool
    /// The server's features; nil while they load, when the actions that need one stay hidden.
    let features: ServerFeatures?
    /// The album the photo was opened from, for its cover and its comments.
    let album: String?
}

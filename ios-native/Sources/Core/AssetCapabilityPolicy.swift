import Foundation
import IlyichPlatform

/// What can be done with a server asset, so the viewer, the selection actions, the info sheet and
/// a stack offer the same things for the same photo, and nothing the server would refuse.
///
/// An action is hidden where it doesn't apply to the asset at all, and disabled where it applies
/// but not now: read-only mode is on, or the photo's details are still loading.
enum AssetCapabilityPolicy {
    static let readOnlyReason = ReadOnlyPolicy.ReadOnlyError().localizedDescription
    static let loadingReason = "This photo’s details are still loading."

    static func evaluate(_ asset: Asset, context: CapabilityContext) -> AssetCapabilities {
        let owns = asset.ownerId != nil && asset.ownerId == context.viewerID
        // A locked photo stays private: the server keeps it out of albums and links, and the app
        // keeps it off TVs, the browser, similar photos and the profile.
        let locked = asset.visibility == .locked
        let trashed = asset.isTrashed
        var result = AssetCapabilities()
        /// Something that changes the library or Photos: disabled while changes aren't allowed.
        func change(_ action: AssetAction, when applies: Bool) {
            result[action] = !applies ? .hidden : context.writable ? .offered : .disabled(readOnlyReason)
        }
        func view(_ action: AssetAction, when applies: Bool) { result[action] = applies ? .offered : .hidden }

        change(.favorite, when: owns)
        change(.archive, when: owns && !trashed && !locked)
        change(.lock, when: owns && !trashed)
        // Until the server's features arrive, deleting assumes a Trash; the viewer checks again
        // before it asks.
        change(.trash, when: owns && !trashed && context.features?.trash != false)
        change(.deletePermanently, when: owns && (trashed || context.features?.trash == false))
        change(.restore, when: owns && trashed && context.features?.trash == true)
        change(.editInfo, when: owns)
        // Only the owner can read or change a stack.
        change(.stack, when: owns && !locked)
        change(.addToAlbum, when: !locked)
        change(.sharedLink, when: !locked)
        change(.albumCover, when: context.album != nil && !locked)
        change(.profilePhoto, when: asset.type == .image && !locked)
        view(.comments, when: context.album != nil && !locked)
        view(.openInBrowser, when: !locked)
        view(.findSimilar, when: context.features?.smartSearch == true && !locked)
        view(.selectText, when: context.features?.ocr == true && asset.type == .image)
        // Locked photos keep these, the roadmap's default until the owner decides otherwise.
        view(.share, when: true)
        view(.download, when: true)
        // Read-only mode keeps the app from writing to Photos too.
        change(.saveToPhotos, when: true)

        if !owns || !isEditable(asset) { result[.edit] = .hidden }
        else if !context.writable { result[.edit] = .disabled(readOnlyReason) }
        // A timeline row has no file name or projection, so it can't say whether the server
        // would edit it.
        else if !asset.hasKnownEditState { result[.edit] = .disabled(loadingReason) }
        else { result[.edit] = .offered }
        return result
    }

    /// What every photo of a selection allows. One photo gets what it gets alone.
    static func evaluate(selection assets: [Asset], context: CapabilityContext) -> AssetCapabilities {
        guard let first = assets.first else { return AssetCapabilities() }
        return assets.dropFirst().reduce(evaluate(first, context: context)) { $0.intersection(evaluate($1, context: context)) }
    }

    /// The server's own rule: a 360° photo, by its projection or as an Insta360 file.
    static func isPanorama(_ asset: Asset) -> Bool {
        asset.exifInfo?.projectionType?.uppercased() == "EQUIRECTANGULAR" || fileExtension(asset) == "insp"
    }

    /// The photos the server's editor accepts: still images, not Live Photos, panoramas, GIFs or
    /// SVGs, and not in Trash.
    private static func isEditable(_ asset: Asset) -> Bool {
        asset.type == .image && !asset.isAnimatedImage && asset.livePhotoVideoId == nil && !asset.isTrashed
            && !isPanorama(asset) && !["gif", "svg"].contains(fileExtension(asset))
    }

    private static func fileExtension(_ asset: Asset) -> String {
        (asset.originalFileName as NSString).pathExtension.lowercased()
    }
}

/// What a selection of server photos offers (REBUILD_ROADMAP.md N2): what every photo in it
/// allows, except that a Trash selection offers only Restore and Delete permanently, as Immich does
/// in its Trash.
enum SelectionCapabilities {
    static func evaluate(_ assets: [Asset], context: CapabilityContext) -> AssetCapabilities {
        let every = AssetCapabilityPolicy.evaluate(selection: assets, context: context)
        guard isTrash(assets) else { return every }
        var trash = AssetCapabilities()
        for action in [AssetAction.restore, .deletePermanently] { trash[action] = every[action] }
        return trash
    }

    /// Every photo selected is in the Trash.
    static func isTrash(_ assets: [Asset]) -> Bool { !assets.isEmpty && assets.allSatisfy(\.isTrashed) }
}

extension ActionAvailability {
    /// Unavailable only until the photo's details arrive.
    var awaitsDetails: Bool { self == .disabled(AssetCapabilityPolicy.loadingReason) }
}

extension CapabilityContext {
    /// The context a screen has today: the client's user and read-only mode.
    init(api: APIClient, features: ServerFeatures?, album: String? = nil) {
        self.init(viewerID: api.userID, writable: !api.isReadOnly, features: features, album: album)
    }
}

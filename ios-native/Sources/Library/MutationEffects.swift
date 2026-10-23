import Foundation

/// What a mutation's result means for the photos each screen shows (REBUILD_ROADMAP.md N2): the
/// feed, and every collection screen that keeps its own list (the critic's correction). Pure.
extension MutationRequest {
    /// The photos the request names, in its order.
    var assetIDs: [String] {
        switch self {
        case .favorite(let ids, _), .visibility(let ids, _), .trash(let ids), .deletePermanently(let ids), .restore(let ids),
             .rating(let ids, _), .tag(let ids, _), .stack(let ids):
            ids
        case .addToAlbum(_, let ids), .removeFromAlbum(_, let ids), .createAlbum(_, let ids), .removeFromStack(_, let ids): ids
        case .setAlbumCover(_, let id), .setStackCover(_, let id), .update(let id, _), .edits(let id, _): [id]
        case .resolveDuplicate(_, let keep, let trash): keep + trash
        case .restoreAllTrash, .emptyTrash, .unstack, .reassignFace, .removeFace, .dismissDuplicate: []
        }
    }

    /// `asset` as this change, once made, leaves it, for a photo whose new record isn't at hand:
    /// nil when the photo is gone for good. What the change can't say on the record (an album, a
    /// stack, a face) leaves it as it was.
    func applied(to asset: Asset) -> Asset? {
        var asset = asset
        switch self {
        case .favorite(_, let value): asset.isFavorite = value
        case .visibility(_, let visibility): asset.visibility = visibility
        case .trash: asset.isTrashed = true
        case .resolveDuplicate(_, _, let trash): if trash.contains(asset.id) { asset.isTrashed = true }
        case .restore, .restoreAllTrash: asset.isTrashed = false
        case .deletePermanently, .emptyTrash: return nil
        default: break
        }
        return asset
    }

    /// Whether the change deletes its photos for good, so no screen shows them again.
    var removesForGood: Bool {
        switch self {
        case .deletePermanently, .emptyTrash: true
        default: false
        }
    }
}

extension MutationResult {
    /// The photos this mutation changed, by ID, as it left them: the result's record of each, or
    /// else the screen's own (`shown`, asked only then) changed as the server changed it. A photo
    /// deleted for good, or one neither has a record of, has none. One pass over the photos the
    /// mutation changed, so a bulk change costs a screen no more than the photos it names.
    func records(updating shown: (String) -> Asset?) -> [String: Asset] {
        guard !request.removesForGood else { return [:] }
        var records: [String: Asset] = [:]
        for id in succeeded {
            if let record = fresh[id] ?? shown(id).flatMap(request.applied(to:)) { records[id] = record }
        }
        return records
    }

    /// `asset` as this mutation left it: the result's record of the photo, or the screen's own
    /// changed as the server changed it; nil when the photo is gone for good. A photo the
    /// mutation didn't change comes back as it was.
    private func record(for asset: Asset, changed: Set<String>) -> Asset? {
        guard changed.contains(asset.id) else { return asset }
        if request.removesForGood { return nil }
        return fresh[asset.id] ?? request.applied(to: asset)
    }

    /// The photos a screen shows, in their order, as this mutation leaves them: a photo deleted
    /// for good goes, a photo whose new record the screen doesn't show (`keeps` says what it
    /// shows) goes, and every other photo the mutation changed takes its new record.
    func applied(to assets: [Asset], keeping keeps: (Asset) -> Bool) -> [Asset] {
        let changed = Set(succeeded)
        guard !changed.isEmpty else { return assets }
        return assets.compactMap { asset in
            guard let record = record(for: asset, changed: changed) else { return nil }
            return changed.contains(asset.id) && !keeps(record) ? nil : record
        }
    }

    /// Whether the mutation changed any photo, or the Trash as a whole.
    var changedPhotos: Bool {
        if !succeeded.isEmpty { return true }
        switch request {
        case .restoreAllTrash, .emptyTrash: return true
        default: return false
        }
    }
}

/// Which photos a collection screen shows, by their own record, so a photo a mutation takes out
/// of it leaves at once (the critic's correction to N2).
enum CollectionMembership {
    /// A folder: timeline photos, out of the Trash (the server's view/folder).
    static func folder(_ asset: Asset) -> Bool { asset.visibility == .timeline && !asset.isTrashed }
    /// The Locked Folder: locked photos out of the Trash.
    static func lockedFolder(_ asset: Asset) -> Bool { asset.visibility == .locked && !asset.isTrashed }
    /// The Trash.
    static func trash(_ asset: Asset) -> Bool { asset.isTrashed }
    /// A search or a duplicate group: timeline and archived photos out of the Trash.
    static func searched(_ asset: Asset) -> Bool { (asset.visibility == .timeline || asset.visibility == .archive) && !asset.isTrashed }
}

/// What the feed does with a mutation's result, through its own commands (F4's entry points):
/// photos whose records it shows anew, and photos it takes out of every feed of the trash state
/// it shows, so no month read before the server has the change brings them back.
struct FeedMutationEffect: Equatable {
    var records: [Asset] = []
    var removed: Set<String> = []

    var isEmpty: Bool { records.isEmpty && removed.isEmpty }

    /// `showingTrash` says whether the feed shows the Trash. A photo put in Trash leaves the feeds
    /// of photos out of it, and one restored leaves the Trash; when the feed shows the other side,
    /// the photo isn't in it, and its record goes to the feed instead, which keeps the library a
    /// filter clears back to right. A photo locked or deleted for good leaves every feed.
    static func of(_ result: MutationResult, showingTrash: Bool) -> FeedMutationEffect {
        var effect = FeedMutationEffect()
        let ids = result.succeeded
        guard !ids.isEmpty else { return effect }
        func records(_ ids: [String]) -> [Asset] { ids.compactMap { result.fresh[$0] } }
        switch result.request {
        case .deletePermanently, .emptyTrash, .visibility(_, .locked):
            effect.removed = Set(ids)
        case .trash:
            if showingTrash { effect.records = records(ids) } else { effect.removed = Set(ids) }
        case .resolveDuplicate(_, _, let trash):
            let trashed = ids.filter(trash.contains)
            if showingTrash { effect.records = records(trashed) } else { effect.removed = Set(trashed) }
        case .restore, .restoreAllTrash:
            if showingTrash { effect.removed = Set(ids) } else { effect.records = records(ids) }
        case .favorite, .visibility, .update, .rating, .edits:
            effect.records = records(ids)
        case .addToAlbum, .removeFromAlbum, .setAlbumCover, .createAlbum, .stack, .unstack, .removeFromStack, .setStackCover,
             .tag, .reassignFace, .removeFace, .dismissDuplicate:
            // Albums, stacks, tags and faces aren't on the record: the sync's change reconciles them.
            break
        }
        return effect
    }
}

/// The duplicate groups Duplicates shows, as a mutation leaves them: a group resolved or
/// dismissed goes, a photo put in Trash, locked or deleted leaves its group, and a group left with
/// fewer than two photos goes.
enum DuplicateGroups {
    static func applying(_ result: MutationResult, to groups: [DuplicateGroup]) -> [DuplicateGroup] {
        switch result.request {
        // Only a group the server resolved or dismissed has a result.
        case .resolveDuplicate(let id, _, _), .dismissDuplicate(let id):
            return groups.filter { $0.id != id }
        default:
            guard result.changedPhotos else { return groups }
            return groups.compactMap { group in
                let assets = result.applied(to: group.assets, keeping: CollectionMembership.searched)
                guard assets.count > 1 else { return nil }
                return DuplicateGroup(duplicateId: group.duplicateId, assets: assets,
                                      suggestedKeepAssetIds: group.suggestedKeepAssetIds.filter { id in assets.contains { $0.id == id } })
            }
        }
    }
}

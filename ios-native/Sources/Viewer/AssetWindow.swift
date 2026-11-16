import Foundation

/// The photos a screen keeps a list of and opens a viewer over: an Info collection, a stack, the
/// Locked Folder (REBUILD_ROADMAP.md N3). The screen and its viewer read the same list, so the
/// viewer pages through what the screen shows as it changes, and the screen hears what the viewer
/// learns of a photo.
@MainActor @Observable final class AssetList {
    var assets: [Asset]
    /// Bumped each time a viewer finds one of the photos gone from the server, or out of the
    /// account's reach, so a screen that must can read its list again.
    private(set) var losses = 0
    /// Which photos the screen shows, by their own record: a fresher record that no longer
    /// belongs takes its photo out.
    @ObservationIgnored private let keeps: (Asset) -> Bool
    /// Told after each loss, for an owner that reads the list again itself whether or not its
    /// screen is being drawn, as the Locked Folder's session does (N5).
    @ObservationIgnored var onLoss: (() -> Void)?

    init(_ assets: [Asset] = [], keeps: @escaping (Asset) -> Bool = { _ in true }) {
        self.assets = assets
        self.keeps = keeps
    }

    /// A fresher record of a photo in the list: it shows, or the photo leaves once it no longer belongs.
    func take(_ asset: Asset) {
        guard let index = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        if keeps(asset) { assets[index] = asset } else { assets.remove(at: index) }
    }

    /// A sync's change: the photos the offline library let go, deleted, locked or out of reach
    /// elsewhere, leave the list at once (G1). Photos it names otherwise stay until read again.
    func drop(_ change: LibraryChange) {
        let gone = change.removed.union(change.accessLost)
        guard !gone.isEmpty, assets.contains(where: { gone.contains($0.id) }) else { return }
        assets.removeAll { gone.contains($0.id) }
    }

    /// A photo is gone from the server, or out of the account's reach: it leaves the list.
    func lose(_ id: String) {
        assets.removeAll { $0.id == id }
        losses += 1
        onLoss?()
    }
}

/// Which photos a viewer pages through, one variant per screen a viewer opens from
/// (REBUILD_ROADMAP.md N3). The viewer always asks about the photo on screen, never the one it
/// opened on, so a reload of the source keeps that photo, and it hands the source what it learns
/// of a photo: a fresher record that changes what the source shows, or a photo that has gone.
/// Its own changes reach every screen through the account's mutations instead (N2).
@MainActor enum AssetWindowProvider {
    /// The library's feed: the photo's month and the months beside it, as the feed has them.
    case feed(LibraryFeedStore)
    /// An Info collection: the photos of a person, an album, a place or a text.
    case collection(AssetList)
    /// A stack's photos.
    case stack(AssetList)
    /// The photos found similar to one.
    case similar(LibraryFeedStore)
    /// One photo alone.
    case single(Asset)
    /// The Locked Folder's photos.
    case locked(AssetList)

    /// The Locked Folder's photos, which no library cache holds (N5): the viewer reads them from
    /// the server alone.
    var isPrivate: Bool {
        if case .locked = self { true } else { false }
    }

    /// The photos to page through around the photo `id`, in their order: empty when the source
    /// doesn't hold it.
    func window(around id: String) -> [Asset] {
        switch self {
        case .feed(let store), .similar(let store): store.availableAssets(around: id)
        case .collection(let list), .stack(let list), .locked(let list): list.assets
        case .single(let asset): asset.id == id ? [asset] : []
        }
    }

    /// The source's mixed viewer entries. Local Photos identifiers are returned as local records
    /// and are never turned into server asset identifiers.
    func entries(around id: String) -> [LibraryEntry] {
        switch self {
        case .feed(let store), .similar(let store): store.availableEntries(around: id)
        case .collection(let list), .stack(let list), .locked(let list): list.assets.map { .remote($0) }
        case .single(let asset): asset.id == id ? [.remote(asset)] : []
        }
    }

    /// A fresher record of a photo, read from the server, that changes what the source shows of
    /// it (`Asset.changesListing(from:)`).
    func publish(_ asset: Asset) {
        switch self {
        case .feed(let store), .similar(let store): store.update(asset)
        case .collection(let list), .stack(let list), .locked(let list): list.take(asset)
        case .single: break
        }
    }

    /// The photo is gone from the server, or the account may no longer see it: the deleted, the
    /// locked and those put in Trash elsewhere. The feed takes it out at once and asks the sync,
    /// as after a change made here.
    func lose(_ id: String) {
        switch self {
        case .feed(let store):
            store.removeLocally([id])
            Task { await store.refreshAfterMutation() }
        case .similar(let store): store.removeLocally([id])
        case .collection(let list), .stack(let list), .locked(let list): list.lose(id)
        case .single: break
        }
    }
}

/// How a viewer's photos follow their source (REBUILD_ROADMAP.md N3). Pure.
enum AssetWindow {
    /// Reconciles mixed entries while preserving the selected page. If a local entry becomes
    /// associated with a server asset, the association replaces it only when that page is selected.
    static func merged(shown: [LibraryEntry], offered: [LibraryEntry], selected: String) -> [LibraryEntry] {
        let uniqueOffered = distinct(offered)
        if let promoted = uniqueOffered.first(where: { sameItem($0, id: selected) }),
           let shownSelected = shown.first(where: { $0.id == selected }),
           shownSelected.id != promoted.id {
            // The caller only invokes this reconciliation after the pager rests.
            return uniqueOffered
        }
        if uniqueOffered.contains(where: { $0.id == selected }) { return uniqueOffered }
        guard let index = shown.firstIndex(where: { $0.id == selected }) else { return uniqueOffered.isEmpty ? shown : uniqueOffered }
        let positions = positions(of: uniqueOffered)
        if let before = shown[..<index].last(where: { matchingIndex($0, positions: positions) != nil }),
           let at = matchingIndex(before, positions: positions) {
            var merged = uniqueOffered
            merged.insert(shown[index], at: at + 1)
            return merged
        }
        if let after = shown[(index + 1)...].first(where: { matchingIndex($0, positions: positions) != nil }),
           let at = matchingIndex(after, positions: positions) {
            var merged = uniqueOffered
            merged.insert(shown[index], at: at)
            return merged
        }
        return shown
    }

    static func resolvedID(shown: [LibraryEntry], offered: [LibraryEntry], selected: String) -> String {
        distinct(offered).first(where: { sameItem($0, id: selected) })?.id ?? selected
    }

    private static func positions(of entries: [LibraryEntry]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            result["entry:" + entry.id] = index
            if let local = entry.local { result["local:" + local.id] = index }
        }
        return result
    }

    private static func matchingIndex(_ entry: LibraryEntry, positions: [String: Int]) -> Int? {
        positions["entry:" + entry.id] ?? entry.local.flatMap { positions["local:" + $0.id] }
    }

    private static func sameItem(_ entry: LibraryEntry, id: String) -> Bool {
        entry.id == id || (id.hasPrefix("local:") && entry.local?.id == String(id.dropFirst("local:".count)))
    }

    private static func sameItem(_ lhs: LibraryEntry, as rhs: LibraryEntry) -> Bool {
        lhs.id == rhs.id || (lhs.local != nil && lhs.local?.id == rhs.local?.id)
    }

    private static func distinct(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        var result: [LibraryEntry] = []
        var remotes: [String: (asset: Asset, local: LocalPhoto?)] = [:]
        var localToRemote: [String: String] = [:]
        for entry in entries {
            guard case .remote(let asset, let local) = entry else { continue }
            if let previous = remotes[asset.id] {
                if previous.local == nil, let local { remotes[asset.id] = (asset, local) }
            } else {
                remotes[asset.id] = (asset, local)
            }
            if let local, localToRemote[local.id] == nil { localToRemote[local.id] = asset.id }
        }

        var seenRemoteIDs = Set<String>()
        var seenLocalIDs = Set<String>()
        for entry in entries {
            switch entry {
            case .remote(let asset, _):
                guard seenRemoteIDs.insert(asset.id).inserted, let canonical = remotes[asset.id] else { continue }
                if let local = canonical.local, !seenLocalIDs.insert(local.id).inserted { continue }
                result.append(.remote(canonical.asset, local: canonical.local))
            case .local(let photo):
                guard seenLocalIDs.insert(photo.id).inserted else { continue }
                if let remoteID = localToRemote[photo.id], let canonical = remotes[remoteID] {
                    guard seenRemoteIDs.insert(remoteID).inserted else { continue }
                    result.append(.remote(canonical.asset, local: canonical.local))
                } else {
                    result.append(.local(photo))
                }
            }
        }
        return result
    }

    /// The photos to page through once the source offers `offered` while `shown` is on screen,
    /// `selected` among them. Where the source holds the photo on screen, its window. Where it no
    /// longer does (a photo archived from this viewer, or deleted elsewhere and yet to be read
    /// again), the photo stays where it was among the photos the source still has, so nothing
    /// slides under the viewer; where the source has none of them (a month let go, a feed being
    /// replaced) the window stays as it was. A photo listed twice, as a month read again after its
    /// date changed can, shows once.
    static func merged(shown: [Asset], offered: [Asset], selected: String) -> [Asset] {
        let offered = distinct(offered)
        if offered.contains(where: { $0.id == selected }) { return offered }
        guard let index = shown.firstIndex(where: { $0.id == selected }) else { return offered.isEmpty ? shown : offered }
        let positions = Dictionary(offered.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let before = shown[..<index].last(where: { positions[$0.id] != nil }), let at = positions[before.id] {
            var merged = offered
            merged.insert(shown[index], at: at + 1)
            return merged
        }
        if let after = shown[(index + 1)...].first(where: { positions[$0.id] != nil }), let at = positions[after.id] {
            var merged = offered
            merged.insert(shown[index], at: at)
            return merged
        }
        return shown
    }

    private static func distinct(_ assets: [Asset]) -> [Asset] {
        var seen = Set<String>()
        seen.reserveCapacity(assets.count)
        let unique = assets.filter { seen.insert($0.id).inserted }
        return unique.count == assets.count ? assets : unique
    }
}

extension Asset {
    /// Whether this record differs from `other`, an earlier record of the same photo, in what a
    /// screen listing photos shows or keeps them by: the media's revision, the visibility, the
    /// Trash or the favorite (N3). A detailed record differs from a timeline row in much else,
    /// which no list shows.
    func changesListing(from other: Asset) -> Bool {
        visibility != other.visibility || isTrashed != other.isTrashed || isFavorite != other.isFavorite || revisionChanged(from: other)
    }

    /// The media changed, as far as both records say: their revisions where both carry one, else
    /// their thumbhashes. A timeline row may carry only a thumbhash.
    private func revisionChanged(from other: Asset) -> Bool {
        if let revision = mediaRevision, let earlier = other.mediaRevision { return revision != earlier }
        if let hash = thumbhash, let earlier = other.thumbhash { return hash != earlier }
        return false
    }
}

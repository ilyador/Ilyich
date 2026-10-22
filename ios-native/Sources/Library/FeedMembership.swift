import Foundation

/// Whether a photo belongs to a feed, as far as its own record can tell (F4). The record decides
/// the visibility, the trash state, favorite, the owner and the developed state a feed asks for.
/// An album, a person, a place, a partner's sharing or what a search matched is not on it, so a
/// photo that passes the rest is kept as it is and its month is read again to be sure. Pure.
enum FeedMembership: Equatable, Sendable {
    /// The photo belongs to the feed.
    case member
    /// The photo is not in the feed: it leaves at once.
    case excluded
    /// The photo passes everything its record can say, and only the source can say the rest.
    case reconcile

    /// `userID` names the account's own photos; nil when it is not known.
    static func of(_ asset: Asset, in query: LibraryQuery, userID: String?) -> FeedMembership {
        // Locked and hidden photos are in no feed, whatever the feed asks for.
        switch asset.visibility {
        case .timeline: guard query.visibility.contains(.timeline) else { return .excluded }
        case .archive: guard query.visibility.contains(.archive) else { return .excluded }
        case .hidden, .locked: return .excluded
        }
        guard asset.isTrashed == (query.trash == .trashed) else { return .excluded }
        let predicates = query.predicates
        if let favorite = predicates.favorite, asset.isFavorite != favorite { return .excluded }
        if let developed = predicates.developed, asset.isDeveloped != developed { return .excluded }
        var decided = true
        switch query.scope {
        case .library:
            // The account's own photos are in it; anyone else's may be a partner's the timeline shows.
            if userID == nil || asset.ownerId != userID { decided = false }
        case .mine:
            guard let userID, let owner = asset.ownerId else { decided = false; break }
            if owner != userID { return .excluded }
        case .partner(let id):
            // Someone else's photo is never in it; whether the partner still shares is the source's to say.
            if let owner = asset.ownerId, owner != id { return .excluded }
            decided = false
        }
        // What the record doesn't hold, or a search matched.
        if case .relevance = query.ranking { decided = false }
        if !predicates.albums.isEmpty || !predicates.people.isEmpty || predicates.place != nil || !predicates.tags.isEmpty
            || predicates.inAnyAlbum != nil || predicates.rating != nil || predicates.taken != nil || predicates.camera != nil
            || predicates.location != nil || predicates.text != nil || predicates.kind != nil || predicates.motion != nil {
            decided = false
        }
        return decided ? .member : .reconcile
    }
}

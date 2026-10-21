import Foundation

/// What the planner knows about the account when it plans. Nothing else reaches it, so a plan
/// depends only on the query and this.
struct PlannerContext: Hashable, Sendable {
    /// The offline index finished its first sync and its derived tables are queryable.
    var indexReadable: Bool
    /// Set when the index serves while the server can't be reached: when it last finished syncing.
    var indexStaleSince: Date? = nil
}

/// Chooses the backend for a query, and says what that backend can't do for it. Pure.
///
/// - The index lays out every scope by month, places included, and filters by favorite and
///   developed. It serves whenever it is readable.
/// - The server timeline lays out the library, the account's own photos, a partner, an album and a
///   person by month, with the same two filters. It never sees a place.
/// - Server search serves everything else, as one list: relevance, the other predicates, and a
///   place before the index is complete. It can't order by date added.
///
/// Every predicate combines with every other by AND, so stacked shelf filters need no new case:
/// any combination with favorite and developed alone is a timeline; anything more is a search.
enum QueryPlanner {
    /// The photos the phone looks through when a filter runs after the server answered.
    static let postFilterScanBudget = 20_000

    static func plan(_ query: LibraryQuery, context: PlannerContext) throws(Unsupported) -> QueryPlan {
        guard !query.visibility.isEmpty else { throw .predicate("visibility") }
        if case .chronological = query.ranking, timelinePredicatesOnly(query.predicates) {
            if context.indexReadable {
                var plan = QueryPlan(backend: .index)
                if let since = context.indexStaleSince { plan.limitations.insert(.indexStale(since: since)) }
                return plan
            }
            if query.scope.isServerTimelineScope { return QueryPlan(backend: .serverTimeline) }
        }
        if case .chronological(.createdAt, _) = query.ranking { throw .orderNotSearchable }
        return QueryPlan(backend: .serverSearch, limitations: searchLimitations(query))
    }

    /// What server search can't do for the query.
    static func searchLimitations(_ query: LibraryQuery) -> Set<Limitation> {
        var limitations: Set<Limitation> = [.noMonths]
        if query.stacks == .primaryOnly { limitations.insert(.includesStackMembers) }
        switch query.scope {
        case .mine, .partner: limitations.insert(.ownerPostFilter)
        // Search reaches the account's and its partners' photos; an album search reaches the album.
        case .person: limitations.insert(.excludesSharedAlbumMembers)
        case .library, .album, .place: break
        }
        if query.predicates.developed != nil { limitations.insert(.developedPostFilter(scanBudget: postFilterScanBudget)) }
        return limitations
    }

    /// Favorite and developed are the only filters a timeline, on the index or the server, applies.
    private static func timelinePredicatesOnly(_ predicates: LibraryQuery.Predicates) -> Bool {
        var rest = predicates
        rest.favorite = nil; rest.developed = nil
        return rest == LibraryQuery.Predicates()
    }
}

extension LibraryQuery.Scope {
    var isServerTimelineScope: Bool {
        if case .place = self { return false }
        return true
    }
}

// MARK: Timeline translation

extension TimelineFilter {
    /// The timeline filter that serves a query on the index or the server timeline, as today's
    /// feeds write it: the account's own photos name its user, and only they ask for active
    /// photos explicitly. Partners are sent only where ServerTimelineRequest allows them.
    init(_ query: LibraryQuery, userID: String?, includesPartners: Bool = false) throws(Unsupported) {
        guard case .chronological(let field, let ascending) = query.ranking else { throw .predicate("relevance") }
        self.init()
        if query.visibility == .timeline { visibility = .timeline }
        else if query.visibility == .archive { visibility = .archive }
        else if query.visibility == [.timeline, .archive] { visibility = nil }
        else { throw .predicate("visibility") }
        switch query.scope {
        case .library: break
        case .mine:
            guard let userID else { throw .predicate("owner") }
            self.userID = userID
        case .partner(let id): self.userID = id
        case .album(let id): albumID = id
        case .person(let id): personID = id
        case .place(let membership): place = TimelinePlace(membership)
        }
        if query.trash == .trashed { isTrashed = true } else if query.scope == .mine { isTrashed = false }
        isFavorite = query.predicates.favorite
        isDeveloped = query.predicates.developed
        withStacked = query.stacks == .primaryOnly
        order = ascending ? "asc" : "desc"
        orderBy = field.rawValue
        withPartners = includesPartners && ServerTimelineRequest.allowsPartners(query)
    }
}

extension LibraryQuery {
    /// Today's feed filter as a query. The account's own user is the mine scope; any other user
    /// is a partner. The Locked Folder and hidden photos have no query.
    init?(_ filter: TimelineFilter, userID: String?) {
        self.init()
        switch filter.visibility {
        case .timeline: visibility = .timeline
        case .archive: visibility = .archive
        case nil: visibility = [.timeline, .archive]
        case .hidden, .locked: return nil
        }
        if let album = filter.albumID { scope = .album(album) }
        else if let person = filter.personID { scope = .person(person) }
        else if let place = filter.place { scope = .place(place.membership) }
        else if let user = filter.userID { scope = user == userID ? .mine : .partner(user) }
        trash = filter.isTrashed == true ? .trashed : .active
        ranking = .chronological(filter.orderBy == "createdAt" ? .createdAt : .takenAt, ascending: filter.order == "asc")
        stacks = filter.withStacked ? .primaryOnly : .all
        predicates.favorite = filter.isFavorite
        predicates.developed = filter.isDeveloped
    }

    /// A search filter from Search options or a media shelf, as a query. The ID list of a place
    /// can't name its place, so a place is kept from `base` when the filter still lists photos.
    init(_ filter: SearchFilter, base: LibraryQuery? = nil) {
        self.init()
        if let visibility = filter.visibility {
            let names = visibility.eq.map { [$0] } ?? visibility.in ?? []
            var set: Visibility = []
            if names.contains("timeline") { set.insert(.timeline) }
            if names.contains("archive") { set.insert(.archive) }
            self.visibility = set
        } else {
            visibility = [.timeline, .archive]
        }
        trash = filter.trashedAt?.isSet == true ? .trashed : .active
        if let albums = filter.albumIds?.all, albums.count == 1 { scope = .album(albums[0]) }
        else if filter.id != nil || filter.or != nil, let base, case .place = base.scope { scope = base.scope }
        else if let id = filter.id?.eq { scope = .place(PlaceMembership(placeID: "photos", assetIDs: [id], markerQuery: "")) }
        else if let alternatives = filter.or {
            scope = .place(PlaceMembership(placeID: "photos", assetIDs: alternatives.compactMap(\.id.eq), markerQuery: ""))
        }
        predicates.people = Set(filter.personIds?.all ?? [])
        predicates.tags = Set(filter.tagIds?.all ?? [])
        predicates.kind = filter.type?.eq.flatMap(AssetKind.init(rawValue:))
        predicates.favorite = filter.isFavorite?.eq
        predicates.motion = filter.isMotion?.eq
        predicates.inAnyAlbum = filter.hasAlbums?.eq
        // An unrated filter is rating 0.
        predicates.rating = filter.rating.map { $0.eq ?? 0 }
        if let taken = filter.takenAt {
            predicates.taken = DateInterval(start: taken.gte ?? .distantPast, end: max(taken.gte ?? .distantPast, taken.lt ?? .distantFuture))
        }
        if filter.make != nil || filter.model != nil { predicates.camera = Camera(make: filter.make?.eq, model: filter.model?.eq) }
        if filter.country != nil || filter.state != nil || filter.city != nil {
            predicates.location = Location(country: filter.country?.eq, state: filter.state?.eq, city: filter.city?.eq)
        }
    }
}

/// A query on the server timeline: GET timeline/buckets and timeline/bucket.
struct ServerTimelineRequest: Hashable, Sendable {
    let filter: TimelineFilter
    var queryItems: [URLQueryItem] { filter.queryItems }

    /// `includesPartners` asks for the partners shown in the timeline; it is sent only where
    /// the server accepts it.
    init(_ query: LibraryQuery, userID: String?, includesPartners: Bool = false) throws(Unsupported) {
        if case .place = query.scope { throw .placeNeedsIndex }
        var rest = query.predicates
        rest.favorite = nil; rest.developed = nil
        guard rest == LibraryQuery.Predicates() else { throw .predicate("search") }
        filter = try TimelineFilter(query, userID: userID, includesPartners: includesPartners)
    }

    /// The server answers 400 when withPartners comes with the archive, favorites or the trash, and
    /// it means nothing for any scope but the library.
    static func allowsPartners(_ query: LibraryQuery) -> Bool {
        query.scope == .library && query.visibility == .timeline && query.predicates.favorite == nil && query.trash == .active
    }
}

// MARK: Search translation

/// A query on server search: POST search/smart or search/metadata, and the filters the phone
/// applies to what comes back.
///
/// Every request states its visibility (timeline, archive or both, never locked or hidden) and
/// its trash with an explicit null. A metadata search is ordered by the time taken. Owner and
/// developed are applied on the phone, within a scan budget, and a defensive filter drops any
/// locked, hidden or trash-mismatched photo the server returns anyway.
struct ServerSearchRequest: Sendable {
    enum Endpoint: Hashable, Sendable { case smart, metadata }

    let query: LibraryQuery
    let endpoint: Endpoint
    let filter: SearchFilter
    let order: SearchOrder?
    /// The owner the phone keeps, for the account's own photos or a partner's.
    let owner: String?
    let limitations: Set<Limitation>

    init(_ query: LibraryQuery, userID: String?) throws(Unsupported) {
        guard !query.visibility.isEmpty else { throw .predicate("visibility") }
        self.query = query
        filter = Self.filter(for: query)
        switch query.ranking {
        case .relevance: endpoint = .smart; order = nil
        case .chronological(.createdAt, _): throw .orderNotSearchable
        case .chronological(.takenAt, let ascending):
            endpoint = .metadata; order = SearchOrder(field: .localDateTime, direction: ascending ? "asc" : "desc")
        }
        switch query.scope {
        case .mine: owner = userID
        case .partner(let id): owner = id
        default: owner = nil
        }
        limitations = QueryPlanner.searchLimitations(query)
    }

    /// The search filter that states the query. The relevance text and similar photo go in the
    /// request's own fields.
    static func filter(for query: LibraryQuery) -> SearchFilter {
        var filter = SearchFilter()
        filter.visibility = StringFilter(in: [(LibraryQuery.Visibility.timeline, "timeline"), (.archive, "archive")]
            .filter { query.visibility.contains($0.0) }.map(\.1))
        filter.trashedAt = query.trash == .trashed ? .set : .unset
        switch query.scope {
        case .album(let id): filter.albumIds = IDsFilter(all: [id])
        case .person(let id): filter.personIds = IDsFilter(all: [id])
        case .place(let membership):
            if membership.assetIDs.count == 1 { filter.id = IDFilter(eq: membership.assetIDs[0]) }
            else { filter.or = membership.assetIDs.map { SearchIDAlternative(id: IDFilter(eq: $0)) } }
        case .library, .mine, .partner: break
        }
        let predicates = query.predicates
        if !predicates.people.isEmpty {
            filter.personIds = IDsFilter(all: (Set(filter.personIds?.all ?? []).union(predicates.people)).sorted())
        }
        if !predicates.tags.isEmpty { filter.tagIds = IDsFilter(all: predicates.tags.sorted()) }
        if let kind = predicates.kind { filter.type = StringFilter(eq: kind.rawValue) }
        if let favorite = predicates.favorite { filter.isFavorite = BoolFilter(eq: favorite) }
        if let motion = predicates.motion { filter.isMotion = BoolFilter(eq: motion) }
        if let inAnyAlbum = predicates.inAnyAlbum { filter.hasAlbums = BoolFilter(eq: inAnyAlbum) }
        if let rating = predicates.rating { filter.rating = RatingFilter(eq: rating == 0 ? nil : rating) }
        if let taken = predicates.taken {
            filter.takenAt = DateFilter(gte: taken.start == .distantPast ? nil : taken.start, lt: taken.end == .distantFuture ? nil : taken.end)
        }
        if let camera = predicates.camera {
            filter.make = camera.make.map { StringFilter(eq: $0) }; filter.model = camera.model.map { StringFilter(eq: $0) }
        }
        if let location = predicates.location {
            filter.country = location.country.map { StringFilter(eq: $0) }
            filter.state = location.state.map { StringFilter(eq: $0) }
            filter.city = location.city.map { StringFilter(eq: $0) }
        }
        if let text = predicates.text {
            switch text.field {
            case .filename: filter.originalFileName = .containing(text.value)
            case .description: filter.description = .containing(text.value)
            case .textInPhoto: filter.ocr = OCRFilter(matches: text.value)
            }
        }
        return filter
    }

    /// How many photos the phone may look through when it filters what the server returns.
    var scanBudget: Int? {
        owner != nil || query.predicates.developed != nil ? QueryPlanner.postFilterScanBudget : nil
    }

    func smartBody(cursor: String?) -> SearchQuery {
        var body = SearchQuery(filter: filter, cursor: cursor)
        switch query.ranking {
        case .relevance(.text(let text, let language)):
            body.query = text
            if let language { body.language = language }
        case .relevance(.similar(let id)): body.queryAssetId = id
        case .chronological: break
        }
        return body
    }

    func metadataBody(cursor: String?, size: Int) -> MetadataQuery {
        MetadataQuery(filter: filter, cursor: cursor, size: size, orderBy: order)
    }

    /// Whether a photo the server returned belongs to the query: its visibility is asked for (so
    /// never locked or hidden), its trash state matches, and the post-filters hold.
    func accepts(_ asset: Asset) -> Bool {
        switch asset.visibility {
        case .timeline: guard query.visibility.contains(.timeline) else { return false }
        case .archive: guard query.visibility.contains(.archive) else { return false }
        case .hidden, .locked: return false
        }
        guard asset.isTrashed == (query.trash == .trashed) else { return false }
        if let owner, asset.ownerId != owner { return false }
        if let developed = query.predicates.developed, asset.isDeveloped != developed { return false }
        return true
    }

    /// The page with only the photos that belong to the query; the cursor and verification are
    /// the server's.
    func page(_ response: SearchResponse) -> SearchResponse {
        let kept = response.assets.items.filter(accepts)
        guard kept.count != response.assets.items.count else { return response }
        return SearchResponse(assets: SearchAssets(items: kept, count: kept.count, nextCursor: response.assets.nextCursor,
                                                   nextPage: response.assets.nextPage),
                              verification: response.verification)
    }
}

extension Unsupported: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .placeNeedsIndex: "This place's photos can be shown by month once the offline library has synced."
        case .orderNotSearchable: "Search can't order photos by the date they were added."
        case .predicate: "Search can't filter photos this way."
        }
    }
}

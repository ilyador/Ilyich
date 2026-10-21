import XCTest
@testable import Ilyich

final class QueryPlannerTests: XCTestCase {
    private let me = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let partner = "3f2e1d0c-9b8a-4f7e-8d6c-5b4a39281706"
    private let album = "d4c3b2a1-0f9e-4d8c-b7a6-958473625140"
    private let person = "7c6b5a49-3827-4165-9f8e-7d6c5b4a3928"
    private let lisbon = PlaceMembership(placeID: "Lisbon", assetIDs: ["a", "b"], markerQuery: "withPartners=false&withSharedAlbums=false")

    private let online = PlannerContext(indexReadable: false)
    private let indexed = PlannerContext(indexReadable: true)
    private let searched: Set<Limitation> = [.noMonths, .includesStackMembers]

    // MARK: Planner

    /// Each preset with and without a readable index: the backend and what it can't do.
    func testPerPresetTable() throws {
        let table: [(String, LibraryQuery, QueryPlan, QueryPlan)] = [
            ("library", .library, .init(backend: .index), .init(backend: .serverTimeline)),
            ("favorites", .favorites, .init(backend: .index), .init(backend: .serverTimeline)),
            ("archive", .archive, .init(backend: .index), .init(backend: .serverTimeline)),
            ("trash", .trash, .init(backend: .index), .init(backend: .serverTimeline)),
            ("recently taken", .recentlyTaken, .init(backend: .index), .init(backend: .serverTimeline)),
            ("recently added", .recentlyAdded, .init(backend: .index), .init(backend: .serverTimeline)),
            ("lightroom", .lightroom, .init(backend: .index), .init(backend: .serverTimeline)),
            ("partner", .partner(partner), .init(backend: .index), .init(backend: .serverTimeline)),
            ("album", .album(album), .init(backend: .index), .init(backend: .serverTimeline)),
            ("album, oldest first", .album(album, ascending: true), .init(backend: .index), .init(backend: .serverTimeline)),
            ("person", .person(person), .init(backend: .index), .init(backend: .serverTimeline)),
            ("place", .place(lisbon), .init(backend: .index), .init(backend: .serverSearch, limitations: searched)),
            ("videos", .videos, .init(backend: .serverSearch, limitations: searched), .init(backend: .serverSearch, limitations: searched)),
            ("motion", .motion, .init(backend: .serverSearch, limitations: searched), .init(backend: .serverSearch, limitations: searched)),
        ]
        for (name, query, withIndex, withoutIndex) in table {
            XCTAssertEqual(try QueryPlanner.plan(query, context: indexed), withIndex, name)
            XCTAssertEqual(try QueryPlanner.plan(query, context: online), withoutIndex, name)
        }
    }

    /// DESIGN 11: until the offline library has synced, a place's photos are found by search.
    func testAPlaceBeforeTheIndexIsCompleteFallsBackToSearchWithNoMonthsNeverUnsupported() throws {
        let plan = try QueryPlanner.plan(.place(lisbon), context: online)
        XCTAssertEqual(plan.backend, .serverSearch)
        XCTAssertTrue(plan.limitations.contains(.noMonths))
        var favoritePlace = LibraryQuery.place(lisbon); favoritePlace.predicates.favorite = true
        XCTAssertEqual(try QueryPlanner.plan(favoritePlace, context: online).backend, .serverSearch)
        XCTAssertEqual(try QueryPlanner.plan(favoritePlace, context: indexed).backend, .index, "A place stacks with favorites on the index.")
    }

    func testSearchesSayWhatThePhoneFiltersAndWhatSearchMisses() throws {
        let lightroom = try QueryPlanner.plan(LibraryQuery.lightroom.refined(text: "IMG_", mode: .filename), context: indexed)
        XCTAssertEqual(lightroom.limitations, searched.union([.developedPostFilter(scanBudget: 20_000)]))
        let mine = try QueryPlanner.plan(LibraryQuery.recentlyTaken.refined(text: "beach", mode: .context), context: indexed)
        XCTAssertEqual(mine.limitations, searched.union([.ownerPostFilter]))
        let partnerSearch = try QueryPlanner.plan(LibraryQuery.partner(partner).similar(to: "photo"), context: indexed)
        XCTAssertTrue(partnerSearch.limitations.contains(.ownerPostFilter))
        let personSearch = try QueryPlanner.plan(LibraryQuery.person(person).refined(text: "beach", mode: .context), context: online)
        XCTAssertTrue(personSearch.limitations.contains(.excludesSharedAlbumMembers))
        var everything = LibraryQuery.library.refined(text: "beach", mode: .context); everything.stacks = .all
        XCTAssertEqual(try QueryPlanner.plan(everything, context: online).limitations, [.noMonths])
    }

    func testStackedShelfFiltersCombineByAnd() throws {
        // Favorites in an album, by a person, developed: still a timeline.
        var stacked = LibraryQuery.album(album); stacked.predicates.favorite = true; stacked.predicates.developed = true
        XCTAssertEqual(try QueryPlanner.plan(stacked, context: online).backend, .serverTimeline)
        // Add a person or a kind and only search can serve it, with every filter kept.
        stacked.predicates.people = [person]; stacked.predicates.kind = .video
        let plan = try QueryPlanner.plan(stacked, context: indexed)
        XCTAssertEqual(plan.backend, .serverSearch)
        let filter = try ServerSearchRequest(stacked, userID: me).filter
        XCTAssertEqual(filter.albumIds, IDsFilter(all: [album]))
        XCTAssertEqual(filter.personIds, IDsFilter(all: [person]))
        XCTAssertEqual(filter.type, StringFilter(eq: "VIDEO"))
        XCTAssertEqual(filter.isFavorite, BoolFilter(eq: true))
    }

    /// Every shelf facet stacks with every other by AND: an owner, albums, people and a place.
    /// The planner says which stacks the timelines lay out by month and sends the rest to search.
    func testEveryShelfFacetStacksWithEveryOther() throws {
        func query(_ scope: LibraryQuery.Scope = .library, albums: Set<String> = [], people: Set<String> = [],
                   place: PlaceMembership? = nil) -> LibraryQuery {
            LibraryQuery(scope: scope, predicates: LibraryQuery.Predicates(people: people, albums: albums, place: place))
        }
        let table: [(String, LibraryQuery, QueryPlan.Backend, QueryPlan.Backend)] = [
            ("place and album", query(albums: [album], place: lisbon), .index, .serverSearch),
            ("place and person", query(people: [person], place: lisbon), .index, .serverSearch),
            ("place and partner", query(.partner(partner), place: lisbon), .index, .serverSearch),
            ("album and partner", query(.partner(partner), albums: [album]), .index, .serverSearch),
            ("album and mine", query(.mine, albums: [album]), .index, .serverSearch),
            ("album and person", query(albums: [album], people: [person]), .index, .serverSearch),
            ("person and partner", query(.partner(partner), people: [person]), .serverSearch, .serverSearch),
            ("two albums", query(albums: [album, "other"]), .serverSearch, .serverSearch),
            ("two people", query(people: [person, "other"]), .serverSearch, .serverSearch),
        ]
        for (name, stacked, withIndex, withoutIndex) in table {
            XCTAssertEqual(try QueryPlanner.plan(stacked, context: indexed).backend, withIndex, name)
            XCTAssertEqual(try QueryPlanner.plan(stacked, context: online).backend, withoutIndex, name)
            if withIndex == .index {
                let filter = try TimelineFilter(stacked, userID: me)
                XCTAssertEqual(filter.albumID, stacked.predicates.albums.first, name)
                XCTAssertEqual(filter.personID, stacked.predicates.people.first, name)
                XCTAssertEqual(filter.place, stacked.predicates.place.map(TimelinePlace.init), name)
            } else {
                XCTAssertThrowsError(try TimelineFilter(stacked, userID: me), name)
            }
            XCTAssertThrowsError(try ServerTimelineRequest(stacked, userID: me), name)
            // Search keeps every facet.
            let search = try ServerSearchRequest(stacked, userID: me)
            XCTAssertEqual(Set(search.filter.albumIds?.all ?? []), stacked.predicates.albums, name)
            XCTAssertEqual(Set(search.filter.personIds?.all ?? []), stacked.predicates.people, name)
            XCTAssertEqual(search.filter.or?.compactMap(\.id.eq), stacked.predicates.place?.assetIDs, name)
            if case .partner(let id) = stacked.scope { XCTAssertEqual(search.owner, id, name) }
        }
        let placeAndAlbum = try ServerSearchRequest(query(albums: [album], place: lisbon), userID: me)
        XCTAssertFalse(placeAndAlbum.limitations.contains(.excludesSharedAlbumMembers), "An album search reaches the album.")
    }

    func testDateAddedCantBeSearched() {
        var videosByAdded = LibraryQuery.recentlyAdded; videosByAdded.predicates.kind = .video
        XCTAssertThrowsError(try QueryPlanner.plan(videosByAdded, context: indexed)) { XCTAssertEqual($0 as? Unsupported, .orderNotSearchable) }
        XCTAssertThrowsError(try ServerSearchRequest(.recentlyAdded, userID: me)) { XCTAssertEqual($0 as? Unsupported, .orderNotSearchable) }
        // A smart search ranks by relevance, so it doesn't care how the feed was ordered.
        XCTAssertNoThrow(try ServerSearchRequest(LibraryQuery.recentlyAdded.refined(text: "beach", mode: .context), userID: me))
    }

    func testAnIndexServingOfflineSaysHowStaleItIs() throws {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = try QueryPlanner.plan(.library, context: PlannerContext(indexReadable: true, indexStaleSince: since))
        XCTAssertEqual(plan, QueryPlan(backend: .index, limitations: [.indexStale(since: since)]))
    }

    // MARK: Server timeline

    func testWithPartnersNeverSentWithArchiveFavoritesOrTrash() throws {
        func sendsPartners(_ query: LibraryQuery) throws -> Bool {
            try ServerTimelineRequest(query, userID: me, includesPartners: true).queryItems.contains(URLQueryItem(name: "withPartners", value: "true"))
        }
        XCTAssertTrue(try sendsPartners(.library))
        for (name, query) in [("archive", LibraryQuery.archive), ("favorites", .favorites), ("trash", .trash),
                              ("recently taken", .recentlyTaken), ("partner", .partner(partner)), ("album", .album(album)),
                              ("person", .person(person)), ("recently added", .recentlyAdded)] {
            XCTAssertFalse(try sendsPartners(query), name)
        }
        var bothVisibilities = LibraryQuery.library; bothVisibilities.visibility = [.timeline, .archive]
        XCTAssertFalse(try sendsPartners(bothVisibilities))
        var trashedLibrary = LibraryQuery.library; trashedLibrary.trash = .trashed
        XCTAssertFalse(try sendsPartners(trashedLibrary))
        var notFavorites = LibraryQuery.library; notFavorites.predicates.favorite = false
        XCTAssertFalse(try sendsPartners(notFavorites))
        // An album or a person in the library is no longer the whole library.
        var albumInLibrary = LibraryQuery.library; albumInLibrary.predicates.albums = [album]
        XCTAssertFalse(ServerTimelineRequest.allowsPartners(albumInLibrary))
        XCTAssertFalse(ServerTimelineRequest.allowsPartners(.person(person)))
        XCTAssertFalse(ServerTimelineRequest.allowsPartners(.place(lisbon)))
        // Until Q5 decides it, the library leaves partners out.
        XCTAssertFalse(try ServerTimelineRequest(.library, userID: me).queryItems.contains { $0.name == "withPartners" })
    }

    /// The server timeline is asked exactly as today's feeds ask it, so their caches keep their names.
    func testTimelineRequestsKeepTodaysQueryItems() throws {
        var recentlyTaken = TimelineFilter(); recentlyTaken.userID = me; recentlyTaken.isTrashed = false
        var recentlyAdded = TimelineFilter(); recentlyAdded.userID = me; recentlyAdded.visibility = nil; recentlyAdded.isTrashed = false
        recentlyAdded.orderBy = "createdAt"
        var partnerFeed = TimelineFilter(); partnerFeed.userID = partner; partnerFeed.visibility = nil
        var oldestFirst = TimelineFilter(albumID: album); oldestFirst.order = "asc"
        let table: [(LibraryQuery, TimelineFilter)] = [
            (.library, TimelineFilter()), (.favorites, TimelineFilter(isFavorite: true)), (.archive, TimelineFilter(visibility: .archive)),
            (.trash, TimelineFilter(visibility: nil, isTrashed: true)), (.lightroom, TimelineFilter(isDeveloped: true)),
            (.recentlyTaken, recentlyTaken), (.recentlyAdded, recentlyAdded), (.partner(partner), partnerFeed),
            (.album(album), TimelineFilter(albumID: album)), (.album(album, ascending: true), oldestFirst),
            (.person(person), TimelineFilter(personID: person)),
        ]
        for (query, filter) in table {
            let request = try ServerTimelineRequest(query, userID: me)
            XCTAssertEqual(request.queryItems, filter.queryItems, query.stableKey)
            XCTAssertEqual(request.filter.cacheKey, filter.cacheKey)
            XCTAssertEqual(LibraryQuery(filter, userID: me), query, "Today's feed reads back as its preset: \(query.stableKey)")
        }
        XCTAssertEqual(try TimelineFilter(.place(lisbon), userID: me), TimelineFilter(place: TimelinePlace(lisbon)))
        XCTAssertThrowsError(try ServerTimelineRequest(.place(lisbon), userID: me)) { XCTAssertEqual($0 as? Unsupported, .placeNeedsIndex) }
        XCTAssertThrowsError(try ServerTimelineRequest(.videos, userID: me))
        var locked = TimelineFilter(); locked.visibility = .locked
        XCTAssertNil(LibraryQuery(locked, userID: me), "The Locked Folder has no library query.")
    }

    // MARK: Server search

    /// Every search states its visibility and trash; locked and hidden are never asked for.
    func testEverySearchStatesTrashAndVisibility() throws {
        let presets: [LibraryQuery] = [.library, .favorites, .archive, .trash, .recentlyTaken, .lightroom, .videos, .motion,
                                       .partner(partner), .album(album), .person(person), .place(lisbon)]
        for preset in presets {
            for query in [preset, preset.refined(text: "beach", mode: .context), preset.refined(text: "IMG", mode: .filename), preset.similar(to: "photo")] {
                let request = try ServerSearchRequest(query, userID: me)
                let body = try JSONSerialization.jsonObject(with: try APIJSON.encoder().encode(request.metadataBody(cursor: nil, size: 100))) as? [String: Any]
                let filter = try XCTUnwrap(body?["filter"] as? [String: Any], query.stableKey)
                let visibility = try XCTUnwrap((filter["visibility"] as? [String: Any])?["in"] as? [String], query.stableKey)
                XCTAssertFalse(visibility.isEmpty)
                XCTAssertTrue(Set(visibility).isSubset(of: ["timeline", "archive"]), query.stableKey)
                let trashedAt = try XCTUnwrap(filter["trashedAt"] as? [String: Any], query.stableKey)
                XCTAssertEqual(trashedAt.count, 1)
                XCTAssertTrue(trashedAt[query.trash == .trashed ? "ne" : "eq"] is NSNull, "\(query.stableKey): an explicit null.")
            }
        }
        XCTAssertThrowsError(try ServerSearchRequest(LibraryQuery(visibility: []), userID: me))
    }

    func testMetadataSearchIsOrderedByTheTimeTaken() throws {
        let request = try ServerSearchRequest(LibraryQuery.library.refined(text: "IMG", mode: .filename), userID: me)
        XCTAssertEqual(request.endpoint, .metadata)
        XCTAssertEqual(request.metadataBody(cursor: "next", size: 100).orderBy, SearchOrder(field: .localDateTime, direction: "desc"))
        let oldestFirst = try ServerSearchRequest(LibraryQuery.album(album, ascending: true).refined(text: "IMG", mode: .filename), userID: me)
        XCTAssertEqual(oldestFirst.order, SearchOrder(field: .localDateTime, direction: "asc"), "A field search keeps the feed's order.")
        let smart = try ServerSearchRequest(LibraryQuery.library.refined(text: "beach", mode: .context, language: "de"), userID: me)
        XCTAssertEqual(smart.endpoint, .smart)
        XCTAssertEqual(smart.smartBody(cursor: nil).query, "beach")
        XCTAssertEqual(smart.smartBody(cursor: nil).language, "de")
        XCTAssertEqual(try ServerSearchRequest(LibraryQuery.library.similar(to: "photo"), userID: me).smartBody(cursor: nil).queryAssetId, "photo")
    }

    func testTheDefensiveFilterDropsLockedHiddenAndTrashMismatchedPhotos() throws {
        func photo(_ id: String, _ visibility: AssetVisibility = .timeline, trashed: Bool = false, owner: String? = nil, developed: Bool = false) -> Asset {
            var asset = Asset(id: id, ownerId: owner, isDeveloped: developed)
            asset.visibility = visibility; asset.isTrashed = trashed
            return asset
        }
        var library = LibraryQuery.library; library.visibility = [.timeline, .archive]
        let search = try ServerSearchRequest(library.refined(text: "beach", mode: .context), userID: me)
        let page = SearchResponse(assets: SearchAssets(items: [photo("kept"), photo("archived", .archive), photo("locked", .locked),
                                                               photo("hidden", .hidden), photo("trashed", trashed: true)],
                                                       count: 5, nextCursor: "next", nextPage: nil), verification: nil)
        let kept = search.page(page)
        XCTAssertEqual(kept.assets.items.map(\.id), ["kept", "archived"])
        XCTAssertEqual(kept.assets.nextCursor, "next", "The cursor stays the server's.")
        let trash = try ServerSearchRequest(LibraryQuery.trash.refined(text: "beach", mode: .context), userID: me)
        XCTAssertEqual(trash.page(page).assets.items.map(\.id), ["trashed"])
        let archive = try ServerSearchRequest(LibraryQuery.archive.refined(text: "beach", mode: .context), userID: me)
        XCTAssertEqual(archive.page(page).assets.items.map(\.id), ["archived"])

        let mine = try ServerSearchRequest(LibraryQuery.recentlyTaken.refined(text: "beach", mode: .context), userID: me)
        XCTAssertTrue(mine.accepts(photo("own", owner: me)))
        XCTAssertFalse(mine.accepts(photo("partner's", owner: partner)))
        XCTAssertEqual(mine.scanBudget, 20_000)
        let lightroom = try ServerSearchRequest(LibraryQuery.lightroom.refined(text: "beach", mode: .context), userID: me)
        XCTAssertTrue(lightroom.accepts(photo("developed", developed: true)))
        XCTAssertFalse(lightroom.accepts(photo("straight from the camera")))
        XCTAssertNil(search.scanBudget)
    }

    /// Search options and media shelves give a search filter; read back as a query, it searches
    /// the same photos.
    func testSearchFiltersReadBackAsQueries() throws {
        var options = SearchFilter(type: StringFilter(eq: "IMAGE"), isMotion: BoolFilter(eq: true), personIds: IDsFilter(all: [person]),
                                   city: StringFilter(eq: "Lisbon"), country: StringFilter(eq: "Portugal"),
                                   takenAt: DateFilter(gte: Date(timeIntervalSince1970: 1_700_000_000), lt: Date(timeIntervalSince1970: 1_700_086_400)),
                                   visibility: StringFilter(eq: "archive"), isFavorite: BoolFilter(eq: true), make: StringFilter(eq: "Leica"),
                                   rating: RatingFilter(eq: nil), hasAlbums: BoolFilter(eq: false), tagIds: IDsFilter(all: ["tag"]))
        options.trashedAt = .set
        let query = LibraryQuery(options)
        XCTAssertEqual(query.trash, .trashed)
        XCTAssertEqual(query.visibility, .archive)
        XCTAssertEqual(query.predicates.rating, 0, "Unrated.")
        let filter = ServerSearchRequest.filter(for: query)
        XCTAssertEqual(filter.visibility, StringFilter(in: ["archive"]))
        for path in [\SearchFilter.type, \.city, \.country, \.make] as [KeyPath<SearchFilter, StringFilter?>] {
            XCTAssertEqual(filter[keyPath: path], options[keyPath: path])
        }
        XCTAssertEqual(filter.personIds, options.personIds)
        XCTAssertEqual(filter.tagIds, options.tagIds)
        XCTAssertEqual(filter.takenAt, options.takenAt)
        XCTAssertEqual(filter.isFavorite, options.isFavorite)
        XCTAssertEqual(filter.isMotion, options.isMotion)
        XCTAssertEqual(filter.hasAlbums, options.hasAlbums)
        XCTAssertEqual(filter.rating, options.rating)
        XCTAssertEqual(filter.trashedAt, .set)
        // Reset clears everything: the library and the archive, active photos only.
        XCTAssertEqual(ServerSearchRequest.filter(for: LibraryQuery(SearchFilter())), SearchFilter(visibility: StringFilter(in: ["timeline", "archive"]), trashedAt: .unset))
        // A place's ID list keeps its place.
        let place = ServerSearchRequest.filter(for: .place(lisbon))
        XCTAssertEqual(LibraryQuery(place, base: .place(lisbon)).predicates.place, lisbon)
        // Several albums read back as several albums.
        XCTAssertEqual(LibraryQuery(SearchFilter(albumIds: IDsFilter(all: [album, "other"]))).predicates.albums, [album, "other"])
    }
}

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
            // N6: the index lays kinds out by month too, as every facet the shelves stack.
            ("videos", .videos, .init(backend: .index), .init(backend: .serverSearch, limitations: searched)),
            ("motion", .motion, .init(backend: .index), .init(backend: .serverSearch, limitations: searched)),
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
        // Add a person or a kind and the server serves it only by search, with every filter kept;
        // the index lays it out by month (N6).
        stacked.predicates.people = [person]; stacked.predicates.kind = .video
        XCTAssertEqual(try QueryPlanner.plan(stacked, context: indexed).backend, .index)
        let plan = try QueryPlanner.plan(stacked, context: online)
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
            // N6: the index serves every stack of the shelves' facets.
            ("person and partner", query(.partner(partner), people: [person]), .index, .serverSearch),
            ("two albums", query(albums: [album, "other"]), .index, .serverSearch),
            ("two people", query(people: [person, "other"]), .index, .serverSearch),
        ]
        for (name, stacked, withIndex, withoutIndex) in table {
            XCTAssertEqual(try QueryPlanner.plan(stacked, context: indexed).backend, withIndex, name)
            XCTAssertEqual(try QueryPlanner.plan(stacked, context: online).backend, withoutIndex, name)
            let feed = try IndexFeedRequest(stacked, userID: me)
            XCTAssertEqual(feed.albumIDs, stacked.predicates.albums.sorted(), name)
            XCTAssertEqual(feed.personIDs, stacked.predicates.people.sorted(), name)
            XCTAssertEqual(feed.placeAssetIDs, stacked.predicates.place?.assetIDs, name)
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

    func testDateAddedCantBeSearched() throws {
        // Recently added and Videos stacked (N6): search can't order it and the timeline can't
        // filter it, so only the index serves it, and says so without one.
        var videosByAdded = LibraryQuery.recentlyAdded; videosByAdded.predicates.kind = .video
        XCTAssertEqual(try QueryPlanner.plan(videosByAdded, context: indexed).backend, .index)
        XCTAssertThrowsError(try QueryPlanner.plan(videosByAdded, context: online)) { XCTAssertEqual($0 as? Unsupported, .needsIndex) }
        // A filter only search knows, in date-added order, no backend can serve.
        var taggedByAdded = LibraryQuery.recentlyAdded; taggedByAdded.predicates.tags = ["tag"]
        XCTAssertThrowsError(try QueryPlanner.plan(taggedByAdded, context: indexed)) { XCTAssertEqual($0 as? Unsupported, .orderNotSearchable) }
        XCTAssertThrowsError(try ServerSearchRequest(.recentlyAdded, userID: me)) { XCTAssertEqual($0 as? Unsupported, .orderNotSearchable) }
        // A smart search ranks by relevance, so it doesn't care how the feed was ordered.
        XCTAssertNoThrow(try ServerSearchRequest(LibraryQuery.recentlyAdded.refined(text: "beach", mode: .context), userID: me))
    }

    /// N6: every stack the shelves and the Earth can make. The server serves it by month where the
    /// timeline can (one owner, album or person, with favorites and Lightroom), as one list by
    /// search where only search can, and nowhere when Recently added meets what the timeline can't
    /// filter: those are index-only, Unsupported.needsIndex without a readable index. With one,
    /// the index lays every stack out by month.
    func testTheServerServesWhatItCanAndTheRestIsIndexOnly() throws {
        let maya = Person(id: person, name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: false, isFavorite: nil)
        let noah = Person(id: "noah", name: "Noah", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: false, isFavorite: nil)
        let coast = Album(id: album, albumName: "Coast", assetCount: 1, shared: false, albumUsers: nil, startDate: nil, endDate: nil,
                          updatedAt: nil, order: "desc")
        let place = FilterLayer.place(lisbon, title: "Lisbon")
        func layers(_ collections: [LibraryCollection], place: FilterLayer? = nil) -> FilterStack {
            FilterStack(collections.map(FilterLayer.collection) + [place].compactMap { $0 })
        }
        enum Served: Equatable { case timeline, search, indexOnly }
        let table: [(String, FilterStack, Served)] = [
            ("person and favorites", layers([.person(maya), .favorites]), .timeline),
            ("album and Lightroom", layers([.album(coast), .lightroom]), .timeline),
            ("archive and trash", layers([.archive, .trash]), .timeline),
            ("recently taken and favorites", layers([.recentlyTaken, .favorites]), .timeline),
            ("recently added and archive", layers([.recentlyAdded, .archive]), .timeline),
            ("place and person", layers([.person(maya)], place: place), .search),
            ("two people", layers([.person(maya), .person(noah)]), .search),
            ("person and album", layers([.person(maya), .album(coast)]), .search),
            ("videos and favorites", layers([.videos, .favorites]), .search),
            ("motion and person", layers([.motion, .person(maya)]), .search),
            ("recently taken and person", layers([.recentlyTaken, .person(maya)]), .search),
            ("recently added and person", layers([.recentlyAdded, .person(maya)]), .indexOnly),
            ("recently added and album", layers([.recentlyAdded, .album(coast)]), .indexOnly),
            ("recently added and place", layers([.recentlyAdded], place: place), .indexOnly),
            ("recently added and videos", layers([.recentlyAdded, .videos]), .indexOnly),
            ("recently added and motion", layers([.recentlyAdded, .motion]), .indexOnly),
        ]
        for (name, stack, served) in table {
            let query = stack.query
            XCTAssertEqual(try QueryPlanner.plan(query, context: indexed).backend, .index, "\(name): the index lays every stack out by month.")
            XCTAssertEqual(QueryPlanner.needsIndex(query), served == .indexOnly, name)
            switch served {
            case .timeline:
                XCTAssertEqual(try QueryPlanner.plan(query, context: online).backend, .serverTimeline, name)
                XCTAssertNoThrow(try ServerTimelineRequest(query, userID: me), name)
            case .search:
                let plan = try QueryPlanner.plan(query, context: online)
                XCTAssertEqual(plan.backend, .serverSearch, name)
                XCTAssertTrue(plan.limitations.contains(.noMonths), name)
                // Search keeps every layer in its filter.
                let filter = try ServerSearchRequest(query, userID: me).filter
                XCTAssertEqual(Set(filter.personIds?.all ?? []), query.predicates.people, name)
                XCTAssertEqual(Set(filter.albumIds?.all ?? []), query.predicates.albums, name)
                XCTAssertEqual(filter.type?.eq, query.predicates.kind?.rawValue, name)
                XCTAssertEqual(filter.isMotion?.eq, query.predicates.motion, name)
                XCTAssertEqual(filter.isFavorite?.eq, query.predicates.favorite, name)
            case .indexOnly:
                XCTAssertThrowsError(try QueryPlanner.plan(query, context: online), name) { XCTAssertEqual($0 as? Unsupported, .needsIndex) }
                XCTAssertThrowsError(try ServerTimelineRequest(query, userID: me), name)
                XCTAssertThrowsError(try ServerSearchRequest(query, userID: me), name) { XCTAssertEqual($0 as? Unsupported, .orderNotSearchable) }
            }
        }
        // A stack is never the whole library, so none asks for the partners shown in the timeline.
        for (name, stack, _) in table { XCTAssertFalse(ServerTimelineRequest.allowsPartners(stack.query), name) }
    }

    /// N6: search reaches the partners shown in the timeline, so a stacked feed only search serves
    /// (before the offline library is readable) keeps on the phone to the photos the index shows of
    /// it: the account's own, but for an album's photos and a place alone's, which are whoever's.
    /// A search typed reaches the partners, as it always has.
    func testAStackOnlySearchServesKeepsToTheLibrarysPhotos() throws {
        let maya = Person(id: person, name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: false, isFavorite: nil)
        let coast = Album(id: album, albumName: "Coast", assetCount: 1, shared: false, albumUsers: nil, startDate: nil, endDate: nil,
                          updatedAt: nil, order: "desc")
        let place = FilterLayer.place(lisbon, title: "Lisbon")
        let table: [(String, FilterStack, Bool)] = [
            ("favorites and videos", FilterStack([.collection(.favorites), .collection(.videos)]), true),
            ("videos", FilterStack([.collection(.videos)]), true),
            ("a place and favorites", FilterStack([place, .collection(.favorites)]), true),
            ("a place and a person", FilterStack([place, .collection(.person(maya))]), true),
            ("a place in the archive", FilterStack([place, .collection(.archive)]), true),
            ("a place alone", FilterStack([place]), false),
            ("a place and an album", FilterStack([place, .collection(.album(coast))]), false),
            ("an album and a person", FilterStack([.collection(.album(coast)), .collection(.person(maya))]), false),
        ]
        /// A photo the feed's visibility holds.
        func photo(owner: String, in query: LibraryQuery = .library) -> Asset {
            var asset = Asset(id: owner + "-photo", ownerId: owner)
            if !query.visibility.contains(.timeline) { asset.visibility = .archive }
            return asset
        }
        for (name, stack, ownOnly) in table {
            let query = stack.query
            XCTAssertEqual(QueryPlanner.keepsToOwnPhotos(query), ownOnly, name)
            // As the index lays the stack out (IndexReader's owner rule).
            let index = try IndexFeedRequest(query, userID: me)
            XCTAssertEqual(ownOnly, index.albumIDs.isEmpty && !index.placeAlone, name)
            let feed = try ServerSearchRequest(stack.searchScope, userID: me, keepsToOwnPhotos: QueryPlanner.keepsToOwnPhotos(query))
            XCTAssertEqual(feed.owner, ownOnly ? me : nil, name)
            XCTAssertEqual(feed.limitations.contains(.ownerPostFilter), ownOnly, name)
            XCTAssertTrue(feed.accepts(photo(owner: me, in: query)), name)
            XCTAssertEqual(feed.accepts(photo(owner: partner, in: query)), !ownOnly, name)
        }
        let favoriteVideos = FilterStack([.collection(.favorites), .collection(.videos)]).query
        XCTAssertEqual(try QueryPlanner.plan(favoriteVideos, context: online).backend, .serverSearch)
        let typed = try ServerSearchRequest(favoriteVideos.refined(text: "beach", mode: .context), userID: me)
        XCTAssertNil(typed.owner, "A search typed reaches the partners.")
        XCTAssertTrue(typed.accepts(photo(owner: partner)))
        XCTAssertFalse(QueryPlanner.keepsToOwnPhotos(.partner(partner)), "A partner's feed keeps to the partner's photos itself.")
        XCTAssertEqual(try ServerSearchRequest(.partner(partner), userID: me, keepsToOwnPhotos: true).owner, partner)
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
        // Until the owner decides it (QUERY-1), the library leaves partners out.
        XCTAssertFalse(try ServerTimelineRequest(.library, userID: me).queryItems.contains { $0.name == "withPartners" })
    }

    /// The server timeline is asked exactly as the feeds asked it before Q5, so their caches keep
    /// their names: these strings are what TimelineFilter wrote, pinned.
    func testTimelineRequestsKeepTodaysQueryItems() throws {
        let table: [(LibraryQuery, String)] = [
            (.library, "order=desc&orderBy=takenAt&withStacked=true&visibility=timeline"),
            (.favorites, "order=desc&orderBy=takenAt&withStacked=true&visibility=timeline&isFavorite=true"),
            (.archive, "order=desc&orderBy=takenAt&withStacked=true&visibility=archive"),
            (.trash, "order=desc&orderBy=takenAt&withStacked=true&isTrashed=true"),
            (.lightroom, "order=desc&orderBy=takenAt&withStacked=true&visibility=timeline&isDeveloped=true"),
            (.recentlyTaken, "order=desc&orderBy=takenAt&withStacked=true&visibility=timeline&userId=\(me)&isTrashed=false"),
            (.recentlyAdded, "order=desc&orderBy=createdAt&withStacked=true&userId=\(me)&isTrashed=false"),
            (.partner(partner), "order=desc&orderBy=takenAt&withStacked=true&userId=\(partner)"),
            (.album(album), "order=desc&orderBy=takenAt&withStacked=true&visibility=timeline&albumId=\(album)"),
            (.album(album, ascending: true), "order=asc&orderBy=takenAt&withStacked=true&visibility=timeline&albumId=\(album)"),
            (.person(person), "order=desc&orderBy=takenAt&withStacked=true&visibility=timeline&personId=\(person)"),
        ]
        func written(_ request: ServerTimelineRequest) -> String {
            request.queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        }
        for (query, expected) in table {
            XCTAssertEqual(written(try ServerTimelineRequest(query, userID: me)), expected, query.stableKey)
        }
        // The library's cache key is the request it sends; the own-photo feeds say userId=me.
        XCTAssertEqual(LibraryQuery.library.stableKey, written(try ServerTimelineRequest(.library, userID: me)))
        XCTAssertThrowsError(try ServerTimelineRequest(.place(lisbon), userID: me)) { XCTAssertEqual($0 as? Unsupported, .placeNeedsIndex) }
        XCTAssertThrowsError(try ServerTimelineRequest(.videos, userID: me))
        // The Locked Folder has its own query, every photo on its own.
        XCTAssertEqual(written(ServerTimelineRequest(LockedFolderQuery())), "order=desc&orderBy=takenAt&withStacked=false&visibility=locked")
        // Trash and album editing open stacks, as their screens always asked.
        var trash = LibraryQuery.trash; trash.stacks = .all
        XCTAssertEqual(written(try ServerTimelineRequest(trash, userID: me)), "order=desc&orderBy=takenAt&withStacked=false&isTrashed=true")
        var albumPhotos = LibraryQuery.album(album); albumPhotos.visibility = [.timeline, .archive]; albumPhotos.stacks = .all
        XCTAssertEqual(written(try ServerTimelineRequest(albumPhotos, userID: me)), "order=desc&orderBy=takenAt&withStacked=false&albumId=\(album)")
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

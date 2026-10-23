import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// N6: the feed shows the filters stacked. A place then a person shows that person's photos in
/// that place; each pill's X removes only its layer, keeping a search typed in the others; Clear
/// removes them all; an album deleted or left goes alone from a stack. The shelves and the Earth
/// narrow to the stack from the index's counts.
@MainActor final class StackedFiltersTests: XCTestCase {
    private let maya = Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: false, isFavorite: nil)
    private let coast = Album(id: "coast", albumName: "Coast", description: nil, albumThumbnailAssetId: nil, assetCount: 3, shared: false,
                              albumUsers: nil, startDate: nil, endDate: nil, updatedAt: nil, order: "desc")
    private let lisbon = PlaceMembership(placeID: "Portugal||Lisbon", assetIDs: ["l1", "lm1", "lm2"], markerQuery: "")

    // MARK: Feed

    func testAPlaceThenAPersonShowsTheirIntersectionAndEachPillRemovesOnlyItsLayer() async throws {
        let library = StackLibrary()
        let store = LibraryFeedStore(source: library)
        defer { store.stop() }
        await store.reload()
        try await until("The library did not load.") { shown(store) == StackLibrary.all }
        store.position = GridPosition(section: "2026-03-01T00:00:00Z", item: 0, offset: 11, assetID: "m3")

        store.add(.place(lisbon, title: "Lisbon"))
        try await until("Lisbon did not show.") { !store.isReplacingFeed && shown(store) == ["l1", "lm1", "lm2"] }
        store.add(.collection(.person(maya)))
        try await until("Maya in Lisbon did not show.") { !store.isReplacingFeed && shown(store) == ["lm1", "lm2"] }
        XCTAssertEqual(store.stack.layers.map(\.id), ["place", "person-maya"])
        XCTAssertEqual(store.filterTitle, "Lisbon · Maya", "The search bar names the stack.")
        XCTAssertEqual(store.feedQuery.predicates.place, lisbon)
        XCTAssertEqual(store.feedQuery.predicates.people, ["maya"])
        XCTAssertEqual(store.searchScope.visibility, [.timeline, .archive], "A search inside a person in a place looks in the archive too.")

        store.remove(FilterLayer.placeID)
        try await until("Removing the place did not leave Maya's photos.") { !store.isReplacingFeed && shown(store) == ["lm1", "lm2", "m3"] }
        XCTAssertEqual(store.stack.layers.map(\.id), ["person-maya"], "Only the place went.")
        XCTAssertEqual(store.feedQuery, .person("maya"))

        store.remove("person-maya")
        XCTAssertTrue(store.stack.isEmpty)
        XCTAssertFalse(store.isFiltered)
        XCTAssertEqual(store.feedQuery, .library)
        XCTAssertEqual(store.restorePosition?.assetID, "m3", "The last layer gone brings the library back where it was left, as Clear does.")
    }

    func testClearEmptiesTheStack() async throws {
        let store = LibraryFeedStore(source: StackLibrary())
        defer { store.stop() }
        await store.reload()
        store.add(.collection(.person(maya)))
        store.add(.collection(.favorites))
        store.add(.place(lisbon, title: "Lisbon"))
        XCTAssertEqual(store.stack.layers.count, 3)
        store.search("beach")
        store.clearFilters()
        XCTAssertTrue(store.stack.isEmpty)
        XCTAssertEqual(store.feedQuery, .library)
        XCTAssertEqual(store.query, "", "Clear ends a search too.")
        XCTAssertNil(store.filterTitle)
        XCTAssertEqual(store.shelfSelection, ShelfSelection())
    }

    /// Removing a layer keeps a search typed in the others, which runs again in what is left;
    /// choosing a filter ends one, as it always did.
    func testRemovingALayerKeepsASearchTypedInTheOthers() async throws {
        let library = StackLibrary()
        let store = LibraryFeedStore(source: library)
        defer { store.stop() }
        await store.reload()
        store.add(.place(lisbon, title: "Lisbon"))
        store.add(.collection(.person(maya)))
        store.search("beach")
        try await until("The search in the stack did not run.") { await library.searches.count == 1 && !store.isSearching }
        let firstSearches = await library.searches
        let first = try XCTUnwrap(firstSearches.first)
        XCTAssertEqual(first.personIds?.all, ["maya"])
        XCTAssertEqual(first.or?.compactMap(\.id.eq), lisbon.assetIDs)

        store.remove(FilterLayer.placeID)
        try await until("The search did not run again without the place.") { await library.searches.count == 2 && !store.isSearching }
        let secondSearches = await library.searches
        let second = try XCTUnwrap(secondSearches.last)
        XCTAssertEqual(store.query, "beach", "The search stays.")
        XCTAssertEqual(second.personIds?.all, ["maya"])
        XCTAssertNil(second.or)
        XCTAssertNil(second.id)

        store.remove("person-maya")
        try await until("The search did not run again in the library.") { await library.searches.count == 3 && !store.isSearching }
        XCTAssertEqual(store.query, "beach")
        XCTAssertTrue(store.isFiltered, "The search alone still filters.")
        let third = await library.searches.last
        XCTAssertNil(third?.personIds)

        store.add(.collection(.favorites))
        XCTAssertEqual(store.query, "", "Choosing a filter ends the search, as before.")
    }

    /// More's filtered view of a stack stays when a pill is removed, over what is left; with no
    /// layer left it is the filtered library.
    func testRemovingALayerKeepsMoresFilteredView() async throws {
        let library = StackLibrary()
        let store = LibraryFeedStore(source: library)
        defer { store.stop() }
        await store.reload()
        store.add(.place(lisbon, title: "Lisbon"))
        store.add(.collection(.person(maya)))
        store.applySearchOptions(mode: .context, filter: SearchFilter(type: StringFilter(eq: "VIDEO")))
        try await until("More's filtered view did not open.") { await library.searches.count == 1 && !store.isSearching }
        XCTAssertTrue(store.isBrowsingChoices)

        store.remove(FilterLayer.placeID)
        try await until("The filtered view did not run again without the place.") { await library.searches.count == 2 && !store.isSearching }
        XCTAssertTrue(store.isBrowsingChoices, "The filtered view stays.")
        let searches = await library.searches
        XCTAssertEqual(searches.last?.type?.eq, "VIDEO")
        XCTAssertEqual(searches.last?.personIds?.all, ["maya"])
        XCTAssertNil(searches.last?.or)
        XCTAssertEqual(store.searchPlaceTitle, "Maya")

        store.remove("person-maya")
        try await until("The filtered library did not show.") { await library.searches.count == 3 && !store.isSearching }
        XCTAssertTrue(store.isBrowsingChoices)
        XCTAssertTrue(store.stack.isEmpty)
        XCTAssertEqual(store.filterTitle, "Filtered library")
        let last = await library.searches.last
        XCTAssertEqual(last?.type?.eq, "VIDEO")
        XCTAssertNil(last?.personIds)
    }

    /// A layer already shown stays as it is; a new place takes the old one's place; a partner's
    /// feed, which is no layer, gives way to the first layer chosen.
    func testALayerShownAgainStaysAndAPartnersFeedGivesWay() async throws {
        let store = LibraryFeedStore(source: StackLibrary())
        defer { store.stop() }
        await store.reload()
        store.add(.collection(.person(maya)))
        let feed = store.feedQuery
        store.add(.collection(.person(maya)))
        XCTAssertEqual(store.feedQuery, feed)
        XCTAssertEqual(store.stack.layers.map(\.id), ["person-maya"])
        let porto = PlaceMembership(placeID: "Portugal||Porto", assetIDs: ["p1"], markerQuery: "")
        store.add(.place(lisbon, title: "Lisbon"))
        store.add(.place(porto, title: "Porto"))
        XCTAssertEqual(store.stack.layers.map(\.title), ["Maya", "Porto"])
        XCTAssertEqual(store.feedQuery.predicates.place, porto)

        store.setFeed(.partner("bob"), title: "Bob")
        XCTAssertTrue(store.stack.isEmpty, "A partner's feed is no layer.")
        XCTAssertEqual(store.feedQuery.scope, .partner("bob"))
        store.add(.collection(.favorites))
        XCTAssertEqual(store.stack.layers.map(\.id), ["favorites"])
        XCTAssertEqual(store.feedQuery, .favorites, "The library's favorites, without the partner.")
        // Browse more's collections are the shelf's own layers.
        store.clearFilters()
        store.setFeed(.favorites, title: "Favorites")
        XCTAssertEqual(store.stack.layers.map(\.id), ["favorites"])
    }

    /// Show in timeline (a memory's, the viewer's) leaves every filter stacked, as Clear does: no
    /// pill stays over the library, no shelf row stays marked, and the next filter chosen is alone.
    func testShowingAPhotoInTheTimelineLeavesEveryFilterStacked() async throws {
        let store = LibraryFeedStore(source: StackLibrary())
        defer { store.stop() }
        await store.reload()
        try await until("The library did not load.") { shown(store) == StackLibrary.all }
        store.add(.collection(.person(maya)))
        store.add(.place(lisbon, title: "Lisbon"))
        XCTAssertEqual(store.stack.layers.count, 2)

        store.showInTimeline(Asset(id: "m3", localDateTime: Date(timeIntervalSince1970: 1_770_000_000)))
        XCTAssertTrue(store.stack.isEmpty, "The stack goes with the filter.")
        XCTAssertEqual(store.feedQuery, .library)
        XCTAssertNil(store.filterTitle)
        XCTAssertEqual(store.shelfSelection, ShelfSelection(), "No shelf row stays marked.")
        XCTAssertTrue(FilterPill.pills(stack: store.stack, feedTitle: store.filterTitle, feedSymbol: "line.3.horizontal.decrease",
                                       search: store.query, matches: nil).isEmpty, "No pill stays over the library.")

        store.add(.collection(.favorites))
        XCTAssertEqual(store.stack.layers.map(\.id), ["favorites"], "The next filter chosen is alone.")
        XCTAssertEqual(store.feedQuery, .favorites)
    }

    /// Before the offline library is readable, a stack only search serves keeps to the library's
    /// photos, as the index and the server timeline do: search reaches the partners shown in the
    /// timeline too, so a partner's favorite video stays out of Favorites with Videos. A search
    /// typed in the stack reaches them, as every search does; a place alone is the map's photos
    /// there, whoever's.
    func testAStackOnlySearchServesKeepsToTheLibrarysPhotos() async throws {
        let library = PartnerSearchLibrary()
        let store = LibraryFeedStore(source: library)
        defer { store.stop() }
        await store.reload()
        store.add(.collection(.favorites))
        store.add(.collection(.videos))
        try await until("Favorite videos did not show.") { await library.searches.count == 1 && !store.isSearching && !store.isReplacingFeed }
        XCTAssertEqual(store.feedPlan?.backend, .serverSearch)
        XCTAssertEqual(store.results.map(\.id), ["alice-video"], "The partner's favorite video stays out.")

        store.search("beach")
        try await until("The search in the stack did not run.") { await library.searches.count == 2 && !store.isSearching }
        XCTAssertEqual(store.results.map(\.id), ["alice-video", "bob-video"], "A search typed reaches the partners, as it always has.")

        store.clearFilters()
        store.add(.place(lisbon, title: "Lisbon"))
        try await until("Lisbon did not show.") { await library.searches.count == 3 && !store.isSearching && !store.isReplacingFeed }
        XCTAssertEqual(store.results.map(\.id), ["alice-video", "bob-video"], "A place alone is the map's photos there, whoever's.")
        store.add(.collection(.favorites))
        try await until("Favorites in Lisbon did not show.") { await library.searches.count == 4 && !store.isSearching && !store.isReplacingFeed }
        XCTAssertEqual(store.results.map(\.id), ["alice-video"], "Stacked, the place keeps to the library's photos.")
    }

    /// N4 with N6: an album deleted or left goes from a stack alone; alone, it clears the filter.
    func testDeletingAStackedAlbumRemovesOnlyItsLayer() async throws {
        let store = LibraryFeedStore(source: StackLibrary())
        defer { store.stop() }
        await store.reload()
        store.add(.collection(.person(maya)))
        store.add(.collection(.album(coast)))
        XCTAssertFalse(store.apply(.albumDeleted("harbor")))
        var renamed = coast; renamed.albumName = "Coast at dusk"
        XCTAssertFalse(store.apply(.albumUpdated(renamed)))
        XCTAssertEqual(store.filterTitle, "Maya · Coast at dusk", "A rename names its layer anew.")
        XCTAssertFalse(store.apply(.albumLeft("coast")), "Stacked, only the album's layer goes.")
        XCTAssertEqual(store.stack.layers.map(\.id), ["person-maya"])
        XCTAssertEqual(store.feedQuery, .person("maya"))
        XCTAssertTrue(store.isFiltered)
    }

    // MARK: Narrowing

    func testTheShelvesNarrowToTheNewestStack() async throws {
        let source = FacetSource()
        let narrowing = ShelfNarrowing(source: source)
        let lisbonStack = FilterStack([.place(lisbon, title: "Lisbon")])
        XCTAssertNil(narrowing.facets(for: FilterStack()), "With no filter nothing narrows.")
        narrowing.show(lisbonStack)
        try await until("Lisbon was not counted.") { narrowing.facets(for: lisbonStack) != nil }
        XCTAssertEqual(narrowing.facets(for: lisbonStack)?.people, ["maya": 2])
        XCTAssertNil(narrowing.facets(for: FilterStack([.collection(.person(maya))])), "Counts are only for the stack they were made for.")

        // A count for a stack left behind that comes back after the newer stack's never lands: it
        // is held at the gate, cancelled or not, until the newer one is in.
        let gate = StubServer.Gate()
        await source.hold(gate)
        let mayaStack = FilterStack([.collection(.person(maya))])
        narrowing.show(mayaStack)
        try await until("Maya's count did not start.") { gate.waiting == 1 }
        narrowing.show(lisbonStack)
        try await until("Lisbon was not counted again.") { narrowing.facets(for: lisbonStack) != nil }
        gate.open()
        try await until("Maya's count did not come back.") { await source.heldReturned == 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(narrowing.facets(for: lisbonStack), "The newer stack's counts stay.")
        XCTAssertNil(narrowing.facets(for: mayaStack), "The late count for the stack left behind never lands.")

        // Without a readable index nothing narrows.
        await source.setReadable(false)
        let favorites = FilterStack([.collection(.favorites)])
        narrowing.show(favorites)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(narrowing.facets(for: favorites))
    }

    /// A sync's change makes the counts stale; they are read again the next time the shelves open,
    /// never on each change.
    func testASyncChangeIsCountedAgainOnlyWhenTheShelvesOpen() async throws {
        let source = FacetSource()
        let narrowing = ShelfNarrowing(source: source)
        let bus = LibraryBus()
        defer { bus.close() }
        narrowing.follow(bus)
        let stack = FilterStack([.collection(.person(maya))])
        narrowing.show(stack)
        try await until("The stack was not counted.") { narrowing.facets(for: stack) != nil }
        let counted = await source.facetCalls
        narrowing.shelvesOpened()
        try await Task.sleep(for: .milliseconds(50))
        let unchanged = await source.facetCalls
        XCTAssertEqual(unchanged, counted, "Nothing changed: the counts stand.")
        let account = AccountID(server: URL(string: "https://photos.example/api")!, userID: "me")
        let change = LibraryChange(account: account, authorization: AuthorizationEpoch(account: account, value: 1), indexRevision: 1, origin: .sync)
        bus.post(.changed(change, accessChanged: false))
        bus.post(.changed(change, accessChanged: false))
        try await Task.sleep(for: .milliseconds(100))
        let afterChanges = await source.facetCalls
        XCTAssertEqual(afterChanges, counted, "A change alone counts nothing.")
        narrowing.shelvesOpened()
        try await until("Opening the shelves did not count again.") { await source.facetCalls == counted + 1 }
    }

    /// The Earth narrows to the stack without its place, so another place stays to choose.
    func testTheEarthNarrowsByEverythingButItsPlace() async throws {
        let source = FacetSource()
        let narrowing = ShelfNarrowing(source: source)
        narrowing.show(FilterStack([.place(lisbon, title: "Lisbon")]))
        narrowing.earthShown(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(narrowing.earth, "A place alone leaves the Earth whole.")
        narrowing.show(FilterStack([.place(lisbon, title: "Lisbon"), .collection(.person(maya))]))
        try await until("The Earth did not narrow.") { narrowing.earth != nil }
        XCTAssertEqual(narrowing.earth?.ids, ["lm1", "lm2", "m3"], "Maya's photos everywhere, not only in Lisbon.")
        let asked = await source.feedQueries
        XCTAssertEqual(asked.last?.predicates.place, nil)
        narrowing.earthShown(false)
        XCTAssertNil(narrowing.earth)
    }

    /// While the Earth is up, the shelves opening after a sync count its photos again for the same
    /// stack. Other photos reach the Earth as a new revision, which arranges its places again; the
    /// same photos leave it as it is.
    func testTheEarthTakesACountAgainForTheSameStack() async throws {
        let source = FacetSource()
        let narrowing = ShelfNarrowing(source: source)
        let bus = LibraryBus()
        defer { bus.close() }
        narrowing.follow(bus)
        narrowing.show(FilterStack([.place(lisbon, title: "Lisbon"), .collection(.person(maya))]))
        narrowing.earthShown(true)
        try await until("The Earth did not narrow.") { narrowing.earth != nil }
        let first = try XCTUnwrap(narrowing.earth)
        XCTAssertEqual(first.ids, ["lm1", "lm2", "m3"])

        let account = AccountID(server: URL(string: "https://photos.example/api")!, userID: "me")
        let change = LibraryChange(account: account, authorization: AuthorizationEpoch(account: account, value: 1), indexRevision: 1, origin: .sync)
        func countAgainAfterASync() async throws {
            let asked = await source.feedQueries.count
            bus.post(.changed(change, accessChanged: false))
            try await until("Opening the shelves did not count the Earth again.") {
                narrowing.shelvesOpened()
                return await source.feedQueries.count == asked + 1
            }
        }

        try await countAgainAfterASync()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(narrowing.earth, first, "The same photos leave the Earth as it is.")
        XCTAssertEqual(narrowing.earth?.identity, first.identity)

        await source.setMayaIDs(["lm1", "m3"])
        try await countAgainAfterASync()
        try await until("The Earth did not take the count again.") { narrowing.earth?.ids == ["lm1", "m3"] }
        XCTAssertEqual(narrowing.earth?.key, first.key, "The same stack.")
        XCTAssertNotEqual(narrowing.earth, first, "A new revision, which the Earth arranges its places for again.")
        XCTAssertNotEqual(narrowing.earth?.identity, first.identity)
    }

    // MARK: Support

    /// Every photo of the feed, in its order, its months all asked for as a grid showing them would.
    private func shown(_ store: LibraryFeedStore) -> [String] {
        store.visibleSections(Set(store.sections.indices))
        return store.sections.compactMap(\.month).flatMap { store.rows[$0] ?? [] }.map(\.id)
    }

    private func until(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }
}

/// A small library the offline index lays out by month, whatever the stack: photos with people,
/// albums and places. Searches are recorded and find one photo.
private actor StackLibrary: FakeFeedSource {
    struct Photo {
        let id: String
        let month: String
        let day: Int
        var people: Set<String> = []
        var albums: Set<String> = []
        var favorite = false
    }
    nonisolated let cacheScope = "test-stacks-" + UUID().uuidString
    static let photos: [Photo] = [
        Photo(id: "l1", month: "2026-03", day: 9),
        Photo(id: "lm1", month: "2026-03", day: 8, people: ["maya"], favorite: true),
        Photo(id: "lm2", month: "2026-03", day: 7, people: ["maya"], albums: ["coast"]),
        Photo(id: "m3", month: "2026-02", day: 3, people: ["maya"]),
        Photo(id: "x1", month: "2026-01", day: 2, albums: ["coast"]),
    ]
    static let all = photos.map(\.id)
    var searches: [SearchFilter] = []

    func plan(_ query: LibraryQuery) async throws -> QueryPlan {
        try QueryPlanner.plan(query, context: PlannerContext(indexReadable: true))
    }
    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] {
        let months = Dictionary(grouping: Self.photos.filter { matches($0, query) }, by: \.month)
        return months.keys.sorted(by: >).map { TimeBucket(timeBucket: $0 + "-01T00:00:00Z", count: months[$0]?.count ?? 0) }
    }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] {
        Self.photos.filter { $0.month == String(bucket.prefix(7)) && matches($0, query) }.map { photo in
            Asset(id: photo.id, isFavorite: photo.favorite, timelineRatio: 1)
        }
    }
    func search(_ query: SearchQuery) async throws -> SearchResponse { record(query.filter) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { record(query.filter) }

    private func record(_ filter: SearchFilter) -> SearchResponse {
        searches.append(filter)
        return SearchResponse(assets: .init(items: [Asset(id: "found")], count: 1, nextCursor: nil, nextPage: nil), verification: nil)
    }

    private func matches(_ photo: Photo, _ query: LibraryQuery) -> Bool {
        let predicates = query.predicates
        if let place = predicates.place, !place.assetIDs.contains(photo.id) { return false }
        guard predicates.people.isSubset(of: photo.people), predicates.albums.isSubset(of: photo.albums) else { return false }
        if let favorite = predicates.favorite, favorite != photo.favorite { return false }
        return true
    }
}

/// A library before the offline index is readable, with a partner shown in Alice's timeline: search
/// answers every request with Alice's favorite video and her partner Bob's, as the server's search
/// reaches them both.
private actor PartnerSearchLibrary: FakeFeedSource {
    nonisolated let cacheScope = "test-partner-search-" + UUID().uuidString
    nonisolated let userID: String? = "alice"
    var searches: [SearchFilter] = []

    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] { [TimeBucket(timeBucket: "2026-03-01T00:00:00Z", count: 1)] }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] { [Asset(id: "alice-photo", ownerId: "alice", timelineRatio: 1)] }
    func search(_ query: SearchQuery) async throws -> SearchResponse { answer(query.filter) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { answer(query.filter) }

    private func answer(_ filter: SearchFilter) -> SearchResponse {
        searches.append(filter)
        let items = [Asset(id: "alice-video", type: .video, ownerId: "alice", isFavorite: true),
                     Asset(id: "bob-video", type: .video, ownerId: "bob", isFavorite: true)]
        return SearchResponse(assets: .init(items: items, count: items.count, nextCursor: nil, nextPage: nil), verification: nil)
    }
}

/// The index's counts for the shelves, as told, recording what it was asked.
private actor FacetSource: ShelfFacetSource {
    private var readable = true
    /// Holds the counts of a stack with a person until it opens, cancelled or not.
    private var gate: StubServer.Gate?
    private var mayaIDs: Set<String> = ["lm1", "lm2", "m3"]
    var facetCalls = 0
    /// Counts held at the gate that have come back.
    var heldReturned = 0
    var feedQueries: [LibraryQuery] = []
    func hold(_ gate: StubServer.Gate?) { self.gate = gate }
    func setReadable(_ readable: Bool) { self.readable = readable }
    func setMayaIDs(_ ids: Set<String>) { mayaIDs = ids }
    func isReadable() async throws -> Bool { readable }
    func facets(_ query: LibraryQuery) async throws -> ShelfFacets {
        facetCalls += 1
        if let gate, !query.predicates.people.isEmpty {
            await gate.wait()
            heldReturned += 1
        }
        return ShelfFacets(people: ["maya": query.predicates.people.isEmpty ? 2 : 3], albums: [:])
    }
    func feedIDs(_ query: LibraryQuery) async throws -> Set<String> {
        feedQueries.append(query)
        return query.predicates.people.contains("maya") ? mayaIDs : []
    }
}

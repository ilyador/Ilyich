import CoreGraphics
import XCTest
@testable import Ilyich

/// N6: filters stack. Each layer chosen on the shelves or the Earth narrows the feed further by
/// AND, its pill's X removes only it, and Clear removes them all.
final class FilterStackTests: XCTestCase {
    private let maya = Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: false, isFavorite: nil)
    private let noah = Person(id: "noah", name: "", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: false, isFavorite: nil)
    private let coast = Album(id: "coast", albumName: "Coast", albumThumbnailAssetId: "cover", assetCount: 10, shared: false, order: "asc")
    private let harbor = Album(id: "harbor", albumName: "Harbor", albumThumbnailAssetId: nil, assetCount: 3, shared: false, order: nil)
    private let lisbon = PlaceMembership(placeID: "Portugal||Lisbon", assetIDs: ["l1", "l2"], markerQuery: "")
    private let porto = PlaceMembership(placeID: "Portugal||Porto", assetIDs: ["p1"], markerQuery: "")

    // MARK: Algebra

    func testAddingRemovingAMiddleLayerAndClearing() {
        var stack = FilterStack()
        XCTAssertTrue(stack.isEmpty)
        XCTAssertNil(stack.title)
        XCTAssertTrue(stack.add(.place(lisbon, title: "Lisbon")))
        XCTAssertTrue(stack.add(.collection(.person(maya))))
        XCTAssertTrue(stack.add(.collection(.favorites)))
        XCTAssertEqual(stack.layers.map(\.id), ["place", "person-maya", "favorites"], "Layers keep the order they were chosen in.")
        XCTAssertEqual(stack.title, "Lisbon · Maya · Favorites")

        XCTAssertFalse(stack.add(.collection(.person(maya))), "A layer already there stays where it is.")
        XCTAssertFalse(stack.add(.place(lisbon, title: "Lisbon")))
        XCTAssertTrue(stack.add(.place(porto, title: "Porto")), "A new place takes the place of the one there.")
        XCTAssertEqual(stack.layers.map(\.id), ["place", "person-maya", "favorites"])
        XCTAssertEqual(stack.query.predicates.place, porto)

        XCTAssertTrue(stack.remove("person-maya"), "The middle layer goes alone.")
        XCTAssertEqual(stack.layers.map(\.id), ["place", "favorites"], "The others keep their order.")
        XCTAssertFalse(stack.remove("person-maya"))
        XCTAssertEqual(stack.query.predicates.people, [], "Its predicate went with it.")
        XCTAssertEqual(stack.query.predicates.favorite, true)

        XCTAssertFalse(stack.update(.collection(.album(coast))), "Only a layer there takes a newer record.")
        stack.add(.collection(.album(coast)))
        var renamed = coast; renamed.albumName = "Coast at dusk"
        XCTAssertTrue(stack.update(.collection(.album(renamed))))
        XCTAssertEqual(stack.layers.last?.title, "Coast at dusk", "A rename stays where the layer is.")

        stack.clear()
        XCTAssertTrue(stack.isEmpty)
        XCTAssertEqual(stack.query, .library, "Clearing brings the library back.")
    }

    /// A layer alone is exactly the feed its row showed before N6, and is searched as it was.
    func testEachLayerAloneIsTheFeedItsRowShowed() {
        XCTAssertEqual(FilterStack([.collection(.person(maya))]).query, .person("maya"))
        XCTAssertEqual(FilterStack([.collection(.album(coast))]).query, .album("coast", ascending: true), "An album keeps its order.")
        XCTAssertEqual(FilterStack([.collection(.album(harbor))]).query, .album("harbor"))
        XCTAssertEqual(FilterStack([.place(lisbon, title: "Lisbon")]).query, .place(lisbon))
        let presets: [LibraryCollection: LibraryQuery] = [.recentlyTaken: .recentlyTaken, .recentlyAdded: .recentlyAdded, .videos: .videos,
                                                          .motion: .motion, .lightroom: .lightroom, .favorites: .favorites,
                                                          .archive: .archive, .trash: .trash]
        for (collection, preset) in presets {
            XCTAssertEqual(FilterStack([.collection(collection)]).query, preset, collection.title)
            XCTAssertEqual(FilterStack([.collection(collection)]).searchScope, preset, "\(collection.title) is searched in its own scope.")
            XCTAssertEqual(LibraryCollection.more(showing: preset), collection, "Browse more's \(collection.title) is the shelf's.")
        }
        XCTAssertNil(LibraryCollection.more(showing: .partner("bob")), "A partner's feed is no layer.")
        // People, albums and places are searched in the archive too, as the library is.
        for stack in [FilterStack(), FilterStack([.collection(.person(maya))]), FilterStack([.collection(.album(coast))]),
                      FilterStack([.place(lisbon, title: "Lisbon"), .collection(.person(maya))])] {
            XCTAssertEqual(stack.searchScope.visibility, [.timeline, .archive])
            XCTAssertEqual(stack.searchScope.trash, .active)
        }
        XCTAssertEqual(FilterStack([.collection(.person(maya))]).searchScope.predicates, LibraryQuery.person("maya").predicates)
        // A person without a name is "Person" on the pill, as the filter always named one.
        XCTAssertEqual(FilterLayer.collection(.person(noah)).title, "Person")
    }

    func testLayersCombineByAnd() {
        let everything = FilterStack([.place(lisbon, title: "Lisbon"), .collection(.person(maya)), .collection(.person(noah)),
                                      .collection(.album(harbor)), .collection(.favorites), .collection(.videos), .collection(.lightroom)])
        let query = everything.query
        XCTAssertEqual(query.predicates.place, lisbon)
        XCTAssertEqual(query.predicates.people, ["maya", "noah"], "Two people show the photos with both.")
        XCTAssertEqual(query.predicates.albums, ["harbor"])
        XCTAssertEqual(query.predicates.favorite, true)
        XCTAssertEqual(query.predicates.kind, .video)
        XCTAssertEqual(query.predicates.developed, true)
        XCTAssertEqual(query.scope, .library)
        XCTAssertEqual(query.visibility, .timeline)
        XCTAssertEqual(query.trash, .active)
        XCTAssertEqual(everything.searchScope, query, "With one of More's collections a search keeps its scope.")

        // Visibilities intersect: the trashed archive, whichever came first.
        for stack in [FilterStack([.collection(.archive), .collection(.trash)]), FilterStack([.collection(.trash), .collection(.archive)])] {
            XCTAssertEqual(stack.query.visibility, .archive)
            XCTAssertEqual(stack.query.trash, .trashed)
        }
        // Recently added orders by the date added, over an album's own order, on the account's photos.
        let added = FilterStack([.collection(.album(coast)), .collection(.recentlyAdded)]).query
        XCTAssertEqual(added.ranking, .chronological(.createdAt, ascending: false))
        XCTAssertEqual(added.scope, .mine)
        XCTAssertEqual(added.visibility, [.timeline, .archive])
        XCTAssertEqual(added.predicates.albums, ["coast"])
        // Two albums keep the library's order.
        XCTAssertEqual(FilterStack([.collection(.album(coast)), .collection(.album(harbor))]).query.ranking, LibraryQuery.library.ranking)
        XCTAssertEqual(FilterStack([.collection(.recentlyTaken), .collection(.person(maya))]).query.scope, .mine)
        // The Earth narrows by everything but its own place.
        XCTAssertEqual(everything.withoutPlace.layers.map(\.id), everything.layers.map(\.id).filter { $0 != "place" })
        XCTAssertTrue(FilterStack([.place(lisbon, title: "Lisbon")]).withoutPlace.isEmpty)
    }

    // MARK: Pills

    func testEachLayerHasAPillAndASearchTypedHasItsOwn() {
        let stack = FilterStack([.place(lisbon, title: "Lisbon"), .collection(.person(maya)), .collection(.album(coast)),
                                 .collection(.album(harbor)), .collection(.favorites)])
        let pills = FilterPill.pills(stack: stack, feedTitle: stack.title, feedSymbol: "person.2", search: "beach", matches: 12)
        XCTAssertEqual(pills.map(\.id), ["place", "person-maya", "album-coast", "album-harbor", "favorites", "search"])
        XCTAssertEqual(pills.map(\.title), ["Lisbon", "Maya", "Coast", "Harbor", "Favorites", "beach"])
        XCTAssertEqual(pills.map(\.icon), [.symbol("mappin.and.ellipse"), .person(maya), .cover("cover"), .symbol("rectangle.stack"),
                                           .symbol("heart"), .symbol("magnifyingglass")])
        XCTAssertEqual(pills.map(\.removal), [.layer("place"), .layer("person-maya"), .layer("album-coast"), .layer("album-harbor"),
                                              .layer("favorites"), .search])
        XCTAssertEqual(pills.map(\.shelf), [.root, .people, .albums, .albums, .more, .root], "A pill brings back its own group.")
        XCTAssertEqual(pills.map(\.count), [nil, nil, nil, nil, nil, 12], "Only the search counts its matches.")

        // A feed that is no layer has one pill of its own; the library has none.
        let partner = FilterPill.pills(stack: FilterStack(), feedTitle: "Sam", feedSymbol: "person.2", search: "", matches: nil)
        XCTAssertEqual(partner.map(\.id), ["feed"])
        XCTAssertEqual(partner.first?.removal, .feed)
        XCTAssertEqual(partner.first?.icon, .symbol("person.2"))
        XCTAssertTrue(FilterPill.pills(stack: FilterStack(), feedTitle: nil, feedSymbol: "", search: "", matches: nil).isEmpty)
    }

    /// The pills run in lines from the leading edge; a new filter's pill takes the next place along
    /// the line, where its row rises to, or starts the next line when it doesn't fit.
    func testTheNextPillTakesTheNextPlaceAndWrapsWhenItDoesntFit() {
        let first = CGSize(width: 120, height: 44), second = CGSize(width: 90, height: 44)
        var frames = FilterPillFlow.frames([first, second], width: 343, spacing: 8)
        XCTAssertEqual(frames, [CGRect(x: 0, y: 0, width: 120, height: 44), CGRect(x: 128, y: 0, width: 90, height: 44)])
        frames = FilterPillFlow.frames([first, second, CGSize(width: 140, height: 44)], width: 343, spacing: 8)
        XCTAssertEqual(frames.last, CGRect(x: 0, y: 52, width: 140, height: 44), "A pill that doesn't fit starts the next line.")
        frames = FilterPillFlow.frames([CGSize(width: 500, height: 44), second], width: 343, spacing: 8)
        XCTAssertEqual(frames, [CGRect(x: 0, y: 0, width: 343, height: 44), CGRect(x: 0, y: 52, width: 90, height: 44)],
                       "A pill wider than the line takes the line and shortens its title.")
        XCTAssertEqual(FilterPillFlow.frames([], width: 343, spacing: 8), [])
    }
}

private extension Album {
    init(id: String, albumName: String, albumThumbnailAssetId: String?, assetCount: Int, shared: Bool, order: String?) {
        self.init(id: id, albumName: albumName, description: nil, albumThumbnailAssetId: albumThumbnailAssetId, assetCount: assetCount,
                  shared: shared, albumUsers: nil, startDate: nil, endDate: nil, updatedAt: nil, order: order)
    }
}

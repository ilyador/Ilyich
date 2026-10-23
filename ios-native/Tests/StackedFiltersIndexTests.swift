import Foundation
import XCTest
@testable import Ilyich

/// N6: the offline index lays every stack of the shelves' facets out by month, and counts the
/// people, albums and places under a stack for the shelves and the Earth. Partners never come in.
final class StackedFiltersIndexTests: XCTestCase {
    private let maya = Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: false, isFavorite: nil)
    private let noah = Person(id: "noah", name: "Noah", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: false, isFavorite: nil)
    private let coast = Album(id: "coast", albumName: "Coast", description: nil, albumThumbnailAssetId: nil, assetCount: 0, shared: false,
                              albumUsers: nil, startDate: nil, endDate: nil, updatedAt: nil, order: "desc")
    private let harbor = Album(id: "harbor", albumName: "Harbor", description: nil, albumThumbnailAssetId: nil, assetCount: 0, shared: true,
                               albumUsers: nil, startDate: nil, endDate: nil, updatedAt: nil, order: "desc")
    /// Lisbon's photos on the map: Alice's, and one of her partner Bob's.
    private let lisbon = PlaceMembership(placeID: "Portugal||Lisbon", assetIDs: ["a1", "a2", "a3", "v1", "b1"], markerQuery: "")

    /// Alice's library: photos a1 to a6, a video v1 and a Live Photo m1; Bob's partner photos b1
    /// and b2 (Bob shows in her timeline); Carol's c1 in the album Harbor, which Carol shares with
    /// her. Maya is in a1, a2, v1, m1, b1 and c1; Noah in a2, a3 and m1.
    private func makeIndex() async throws -> LibraryIndex {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StackedFiltersIndexTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let index = try LibraryIndex(scope: "server|alice", userID: "alice", directory: root)
        var events: [EntitySyncEvent] = [
            SyncEvents.event("PartnerV1", #"{"sharedById":"bob","sharedWithId":"alice","inTimeline":true}"#, ack: "PartnerV1|bob"),
            SyncEvents.event("PersonV1", #"{"id":"maya","name":"Maya","isHidden":false}"#, ack: "PersonV1|maya"),
            SyncEvents.event("PersonV1", #"{"id":"noah","name":"Noah","isHidden":false}"#, ack: "PersonV1|noah"),
            SyncEvents.event("AlbumV2", #"{"id":"coast","ownerId":"alice","name":"Coast","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":null,"isActivityEnabled":true,"order":"desc"}"#, ack: "AlbumV2|coast"),
            SyncEvents.event("AlbumV2", #"{"id":"harbor","ownerId":"carol","name":"Harbor","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":null,"isActivityEnabled":true,"order":"desc"}"#, ack: "AlbumV2|harbor"),
            SyncEvents.event("AlbumUserV1", #"{"albumId":"harbor","userId":"alice","role":"viewer"}"#, ack: "AlbumUserV1|harbor"),
            asset("a1", taken: "2026-03-05T10:00:00Z", favorite: true),
            asset("a2", taken: "2026-03-04T10:00:00Z", created: "2026-03-20T00:00:00Z"),
            asset("a3", taken: "2026-02-10T10:00:00Z", favorite: true),
            asset("a4", taken: "2026-02-09T10:00:00Z", visibility: "archive"),
            asset("a5", taken: "2026-02-08T10:00:00Z", trashed: true),
            asset("a6", taken: "2026-01-02T10:00:00Z"),
            asset("v1", taken: "2026-03-01T10:00:00Z", created: "2026-03-25T00:00:00Z", kind: "VIDEO"),
            asset("m1", taken: "2026-01-05T10:00:00Z", motion: "m1-motion"),
            asset("b1", owner: "bob", taken: "2026-03-03T10:00:00Z", favorite: true, type: "PartnerAssetV2"),
            asset("b2", owner: "bob", taken: "2026-03-02T10:00:00Z", kind: "VIDEO", type: "PartnerAssetV2"),
            asset("c1", owner: "carol", taken: "2026-02-01T10:00:00Z", type: "AlbumAssetCreateV2"),
        ]
        for (album, photo) in [("coast", "a1"), ("coast", "a2"), ("coast", "v1"), ("harbor", "a2"), ("harbor", "c1")] {
            events.append(SyncEvents.event("AlbumToAssetV1", #"{"albumId":"\#(album)","assetId":"\#(photo)"}"#, ack: "AlbumToAssetV1|\(album)\(photo)"))
        }
        for (person, photo) in [("maya", "a1"), ("maya", "a2"), ("maya", "v1"), ("maya", "m1"), ("maya", "b1"), ("maya", "c1"),
                                ("noah", "a2"), ("noah", "a3"), ("noah", "m1")] {
            events.append(IndexReadsTests.face("face-\(person)-\(photo)", asset: photo, person: person))
        }
        _ = try await index.apply(events + [SyncEvents.complete()], epoch: index.epoch())
        let readable = try await index.isReadable()
        XCTAssertTrue(readable)
        return index
    }

    private func asset(_ id: String, owner: String = "alice", taken: String, created: String = "2026-03-01T00:00:00Z", visibility: String = "timeline",
                       trashed: Bool = false, favorite: Bool = false, kind: String = "IMAGE", motion: String? = nil,
                       type: String = "AssetV2") -> EntitySyncEvent {
        SyncEvents.event(type, """
        {"id":"\(id)","ownerId":"\(owner)","type":"\(kind)","originalFileName":"\(id).jpg","checksum":"AQIDBA==","fileCreatedAt":"\(taken)","localDateTime":"\(taken)","createdAt":"\(created)","visibility":"\(visibility)","isFavorite":\(favorite),"deletedAt":\(trashed ? "\"2026-03-04T00:00:00Z\"" : "null"),"stackId":null,"livePhotoVideoId":\(motion.map { "\"\($0)\"" } ?? "null"),"isEdited":false,"isDeveloped":false,"mediaRevision":"r1"}
        """, ack: "\(type)|\(id)")
    }

    /// Every photo of a feed from the index, month by month, in the feed's order.
    private func photos(_ stack: FilterStack, in index: LibraryIndex) async throws -> [String] {
        let query = stack.query
        XCTAssertEqual(try QueryPlanner.plan(query, context: PlannerContext(indexReadable: true)).backend, .index)
        var ids: [String] = []
        for month in try await index.timeBuckets(query) {
            ids += try await index.timeBucket(month.timeBucket + "T00:00:00Z", of: query).map(\.id)
        }
        return ids
    }

    func testEveryStackIsLaidOutByMonthFromTheIndex() async throws {
        let index = try await makeIndex()
        let place = FilterLayer.place(lisbon, title: "Lisbon")
        let table: [(String, FilterStack, [String])] = [
            // A person in the library takes the albums shared with the account, as the server's does.
            ("Maya", FilterStack([.collection(.person(maya))]), ["a1", "a2", "v1", "c1", "m1"]),
            ("a place then a person", FilterStack([place, .collection(.person(maya))]), ["a1", "a2", "v1"]),
            ("two people", FilterStack([.collection(.person(maya)), .collection(.person(noah))]), ["a2", "m1"]),
            ("two albums", FilterStack([.collection(.album(coast)), .collection(.album(harbor))]), ["a2"]),
            ("an album and a person", FilterStack([.collection(.album(harbor)), .collection(.person(maya))]), ["a2", "c1"]),
            ("videos", FilterStack([.collection(.videos)]), ["v1"]),
            ("videos of Maya in Lisbon", FilterStack([place, .collection(.videos), .collection(.person(maya))]), ["v1"]),
            ("motion", FilterStack([.collection(.motion)]), ["m1"]),
            ("motion of Noah", FilterStack([.collection(.motion), .collection(.person(noah))]), ["m1"]),
            // A place alone shows every photo the map has there, Bob's too, as it always did; stacked
            // with the library's filters it keeps to the library's photos, so Bob's favorite stays out.
            ("Lisbon", FilterStack([place]), ["a1", "a2", "b1", "v1", "a3"]),
            ("favorites in Lisbon", FilterStack([place, .collection(.favorites)]), ["a1", "a3"]),
            ("favorites of Maya", FilterStack([.collection(.favorites), .collection(.person(maya))]), ["a1"]),
            // Recently taken keeps to Alice's own photos, so Carol's shared photo of Maya leaves.
            ("Maya's, mine", FilterStack([.collection(.recentlyTaken), .collection(.person(maya))]), ["a1", "a2", "v1", "m1"]),
            // Index-only: Recently added with a person, newest added first.
            ("recently added of Maya", FilterStack([.collection(.recentlyAdded), .collection(.person(maya))]), ["v1", "a2", "a1", "m1"]),
            ("recently added videos", FilterStack([.collection(.recentlyAdded), .collection(.videos)]), ["v1"]),
            ("archived", FilterStack([.collection(.archive)]), ["a4"]),
            ("archived in the trash", FilterStack([.collection(.archive), .collection(.trash)]), []),
            ("the trash", FilterStack([.collection(.trash)]), ["a5"]),
        ]
        for (name, stack, expected) in table {
            let shown = try await photos(stack, in: index)
            XCTAssertEqual(shown, expected, name)
        }
        // Partners stay out of the library and every stack on it (QUERY-1 waits for the owner).
        let library = try await photos(FilterStack(), in: index)
        XCTAssertFalse(library.contains { $0.hasPrefix("b") })
        let videos = try await photos(FilterStack([.collection(.videos)]), in: index)
        XCTAssertFalse(videos.contains("b2"), "Bob's video stays out of Videos.")
    }

    /// People, albums and places under a stack are counted from the index: with Lisbon chosen,
    /// People lists only the people in Lisbon's photos, each with how many of them they are in.
    func testPeopleAlbumAndPlaceCountsUnderAStack() async throws {
        let index = try await makeIndex()
        let place = FilterLayer.place(lisbon, title: "Lisbon")
        let inLisbon = try await index.facets(FilterStack([place]).query)
        XCTAssertEqual(inLisbon.people, ["maya": 4, "noah": 2], "Counted over what the place shows.")
        XCTAssertEqual(inLisbon.albums, ["coast": 3, "harbor": 1])

        let mayaInLisbon = try await index.facets(FilterStack([place, .collection(.person(maya))]).query)
        XCTAssertEqual(mayaInLisbon.people, ["maya": 3, "noah": 1], "Under a person, the people in their photos.")
        XCTAssertEqual(mayaInLisbon.albums, ["coast": 3, "harbor": 1])

        let videos = try await index.facets(FilterStack([.collection(.videos)]).query)
        XCTAssertEqual(videos.people, ["maya": 1])
        XCTAssertEqual(videos.albums, ["coast": 1])

        let empty = try await index.facets(FilterStack([.collection(.archive), .collection(.trash)]).query)
        XCTAssertEqual(empty, ShelfFacets())

        // The Earth keeps of its places only the stack's photos: Maya's, with no partner among them.
        let mayas = try await index.feedIDs(FilterStack([.collection(.person(maya))]).query)
        XCTAssertEqual(mayas, ["a1", "a2", "v1", "m1", "c1"])
        let places = PlacesView.arrange([
            MapMarker(id: "a1", lat: 38.72, lon: -9.14, city: "Lisbon", state: nil, country: "Portugal"),
            MapMarker(id: "b1", lat: 38.72, lon: -9.14, city: "Lisbon", state: nil, country: "Portugal"),
            MapMarker(id: "a6", lat: 41.15, lon: -8.61, city: "Porto", state: nil, country: "Portugal"),
        ], markerQuery: "", narrowing: PlaceNarrowing(key: "maya", ids: mayas))
        XCTAssertEqual(places.all.map(\.title), ["Lisbon", "Porto"], "Every place is kept whole for choosing.")
        XCTAssertEqual(places.shown.map(\.title), ["Lisbon"], "A place without Maya's photos leaves the Earth.")
        XCTAssertEqual(places.shown.first?.assetIDs, ["a1"], "Lisbon counts only Maya's photo.")
        XCTAssertEqual(places.all.first?.assetIDs, ["a1", "b1"])
        XCTAssertEqual(places.lights.total, 1)
    }

    /// A stack with a kind on a 60,000-photo library, as on the owner's phone: its months and its
    /// newest month, and the shelves' counts, come from the index within budget.
    func testAStackedFeedOnALargeLibraryStaysWithinBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StackedFiltersIndexTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let index = try IndexReadsTests.makeLargeLibrary(in: root, photos: 60_000)
        while try await index.writer.backfillStep() {}
        let clock = ContinuousClock()
        // Every photo there is an image: Maya's images look up each of her 15,000 photos' kind.
        var images = FilterStack([.collection(.person(maya))]).query
        images.predicates.kind = .image
        var months: [TimeBucket] = []
        let listing = try await clock.measure { months = try await index.timeBuckets(images) }
        let loading = try await clock.measure { _ = try await index.timeBucket(months.first.map { $0.timeBucket + "T00:00:00Z" } ?? "2026-01-01T00:00:00Z", of: images) }
        var mayas: [TimeBucket] = []
        _ = try await clock.measure { mayas = try await index.timeBuckets(FilterStack([.collection(.person(maya))]).query) }
        var facets = ShelfFacets()
        let counting = try await clock.measure { facets = try await index.facets(FilterStack([.collection(.person(maya))]).query) }
        print("STACKED 60,000 photos: months \(listing.formatted(.units(allowed: [.milliseconds]))), newest month \(loading.formatted(.units(allowed: [.milliseconds]))), shelf counts \(counting.formatted(.units(allowed: [.milliseconds])))")
        XCTAssertEqual(months.reduce(0) { $0 + $1.count }, 15_000)
        XCTAssertEqual(mayas.reduce(0) { $0 + $1.count }, 15_000)
        XCTAssertEqual(facets.people, ["maya": 15_000])
        XCTAssertLessThan(listing + loading, .milliseconds(800), "A stack's months and newest month load within budget.")
        XCTAssertLessThan(counting, .milliseconds(800), "The shelves' counts under a stack come within budget.")
    }

    /// The month's query of a stack with two people and a kind looks a kind up by key, never by
    /// scanning the entities.
    func testAStackedMonthReadsByTheMonthIndex() async throws {
        let index = try await makeIndex()
        let query = FilterStack([.collection(.person(maya)), .collection(.person(noah)), .collection(.videos)]).query
        let plan = try await index.timeBucketPlan("2026-03-01T00:00:00Z", of: query).joined(separator: "\n")
        XCTAssertFalse(plan.contains("SCAN entities"), "A kind is looked up by key, never by scanning the entities:\n\(plan)")
    }
}

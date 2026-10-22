import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// The library's searches through ServerSearchRequest, the place identity and the offline fallbacks.
@MainActor final class LibraryRepositoryTests: XCTestCase {
    private static let maya = Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: nil, isFavorite: nil)

    /// A search inside a feed searches that feed: Trash, a person, an album, Favorites, the archive,
    /// Lightroom and Recently taken keep their scope, trash and filters.
    func testSearchingInsideAFeedKeepsItsScope() async throws {
        let api = SearchRecorder(userID: "alice", items: [
            photo("own", owner: "alice", developed: true), photo("partner's", owner: "bob"), photo("trashed", owner: "alice", trashed: true),
        ])
        let store = LibraryStore(source: api, placesDelay: .zero)
        defer { store.stop() }
        removeCachesAfterwards(api.cacheScope)

        func search(_ text: String = "beach") async throws -> SearchQuery {
            let before = await api.smart.count
            store.search(text)
            try await until("The search was not sent.") { await api.smart.count > before && !store.isSearching }
            let last = await api.smart.last
            return try XCTUnwrap(last)
        }

        store.setFeed(.trash, title: "Trash")
        var body = try await search()
        XCTAssertEqual(body.filter.trashedAt, .set, "A search inside Trash keeps to the trash.")
        XCTAssertEqual(store.results.map(\.id), ["trashed"])

        store.setPerson(Self.maya)
        body = try await search()
        XCTAssertEqual(body.filter.personIds, IDsFilter(all: ["maya"]))
        XCTAssertEqual(body.filter.trashedAt, .unset)
        XCTAssertEqual(body.filter.visibility, StringFilter(in: ["timeline", "archive"]))
        XCTAssertEqual(Set(store.results.map(\.id)), ["own", "partner's"])

        store.setAlbum(Album(id: "coast", albumName: "Coast", assetCount: 1, shared: false, albumUsers: nil,
                             startDate: nil, endDate: nil, updatedAt: nil, order: "desc"))
        body = try await search()
        XCTAssertEqual(body.filter.albumIds, IDsFilter(all: ["coast"]))

        store.setFeed(.favorites, title: "Favorites")
        body = try await search()
        XCTAssertEqual(body.filter.isFavorite, BoolFilter(eq: true))
        XCTAssertEqual(body.filter.visibility, StringFilter(in: ["timeline"]))

        store.setFeed(.archive, title: "Archive")
        body = try await search()
        XCTAssertEqual(body.filter.visibility, StringFilter(in: ["archive"]))

        store.setDeveloped(title: "Lightroom")
        _ = try await search()
        XCTAssertEqual(store.results.map(\.id), ["own"], "Lightroom keeps to developed photos.")

        store.setFeed(.recentlyTaken, title: "Recently taken")
        _ = try await search()
        XCTAssertEqual(store.results.map(\.id), ["own"], "Recently taken keeps to the account's own photos.")

        // A filename search inside Recently added is ordered by the time taken, which search can do.
        // A mode chosen alone sends nothing; it changes what the next search looks in.
        store.applySearchOptions(mode: .filename, filter: SearchFilter())
        store.setFeed(.recentlyAdded, title: "Recently added")
        store.search("beach")
        try await until("The filename search was not sent.") { await api.metadata.count == 1 && !store.isSearching }
        XCTAssertNil(store.error)
        let lastField = await api.metadata.last
        let field = try XCTUnwrap(lastField)
        XCTAssertEqual(field.orderBy, SearchOrder(field: .localDateTime, direction: "desc"))
        XCTAssertEqual(field.filter.originalFileName, .containing("beach"))
        XCTAssertEqual(field.filter.visibility, StringFilter(in: ["timeline", "archive"]))
        XCTAssertEqual(store.results.map(\.id), ["own"])
    }

    /// While the Locked Folder is unlocked the server would return its photos to any search that
    /// let it; every search asks for the timeline and archive only, and drops a locked photo anyway.
    func testElevatedSessionSearchCannotShowLockedPhotos() async throws {
        var locked = photo("locked", owner: "alice"); locked.visibility = .locked
        var hidden = photo("hidden", owner: "alice"); hidden.visibility = .hidden
        let api = SearchRecorder(userID: "alice", items: [locked, hidden, photo("shown", owner: "alice")])
        let store = LibraryStore(source: api, placesDelay: .zero)
        defer { store.stop() }
        removeCachesAfterwards(api.cacheScope)

        store.search("beach")
        try await until("The search was not sent.") { await api.smart.count == 1 && !store.isSearching }
        XCTAssertEqual(store.results.map(\.id), ["shown"])
        store.findSimilar(to: Asset(id: "reference"))
        try await until("The similar search was not sent.") { await api.smart.count == 2 && !store.isSearching }
        XCTAssertEqual(store.results.map(\.id), ["shown"])
        store.applySearchOptions(mode: .filename, filter: SearchFilter())
        store.search("beach")
        try await until("The filename search was not sent.") { await api.metadata.count == 1 && !store.isSearching }
        XCTAssertEqual(store.results.map(\.id), ["shown"])
        store.applySearchOptions(mode: .filename, filter: SearchFilter(isFavorite: BoolFilter(eq: true)))
        try await until("The filtered search was not sent.") { await api.metadata.count == 2 && !store.isSearching }
        XCTAssertEqual(store.results.map(\.id), ["shown"])
        for body in await api.smart.map(\.filter) + api.metadata.map(\.filter) {
            XCTAssertEqual(body.visibility, StringFilter(in: ["timeline", "archive"]))
            XCTAssertEqual(body.trashedAt, .unset)
        }
    }

    func testPlaceIdentityTracksMembershipNotCount() throws {
        func place(_ ids: [String]) -> LibraryQuery { .place(PlaceMembership(placeID: "Lisbon", assetIDs: ids, markerQuery: "")) }
        let lisbon = place(["a", "b"]), swapped = place(["a", "c"]), reordered = place(["b", "a"])
        XCTAssertNotEqual(lisbon, swapped, "Same count, other photos: another feed.")
        XCTAssertNotEqual(lisbon.stableKey, swapped.stableKey)
        XCTAssertEqual(lisbon, reordered)
        XCTAssertEqual(lisbon.stableKey, reordered.stableKey)
        XCTAssertFalse(lisbon.stableKey.hasSuffix("#2"), "A place is no longer named by its count.")

        // The places on the map carry their membership, with the marker query that found them.
        let markers = [MapMarker(id: "a", lat: 38.7, lon: -9.1, city: "Lisbon", state: nil, country: "Portugal"),
                       MapMarker(id: "b", lat: 38.7, lon: -9.1, city: "Lisbon", state: nil, country: "Portugal")]
        let place = try XCTUnwrap(PlaceCollection.group(markers, markerQuery: "withPartners=false").first)
        XCTAssertEqual(place.membership, PlaceMembership(placeID: place.id, assetIDs: ["b", "a"], markerQuery: "withPartners=false"))
        XCTAssertNotEqual(place.membership, PlaceMembership(placeID: place.id, assetIDs: ["a", "b"], markerQuery: "withPartners=true"))
    }

    /// An offline answer stands in only when the server gave none at all, and only from an index
    /// that is complete; an HTTP failure or a cancellation is never hidden.
    func testOfflineFallbackOnlyOnDefiniteTransportFailure() async throws {
        let server = makeStubServer()
        let api = try APIClient(baseURL: server.baseURL, accessToken: "session", userID: "alice", sessionConfiguration: server.configuration(),
                                networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryRepository-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let index = try LibraryIndex(scope: api.cacheScope, userID: "alice", directory: directory)
        await api.attachEntityStore(index)
        let partner = try event("PartnerV1", #"{"sharedById":"bob","sharedWithId":"alice","inTimeline":true}"#, ack: "PartnerV1|bob")

        // Unreachable, but the index has not finished its first sync.
        _ = try await index.apply([partner], epoch: await index.epoch())
        server.route("GET", "partners", .transportFailure(.notConnectedToInternet))
        await assertThrows { _ = try await api.partners() }

        _ = try await index.apply([try event("SyncCompleteV1", "{}", ack: "SyncCompleteV1|done")], epoch: await index.epoch())
        let offline = try await api.partners()
        let indexed = try await index.partners(direction: "shared-with")
        XCTAssertEqual(offline.map(\.id), indexed.map(\.id), "Unreachable with a complete index: the index answers.")

        server.route("GET", "partners", .json(#"{"message":"Internal error"}"#, status: 500))
        await assertThrows { _ = try await api.partners() }

        // The policy itself.
        XCTAssertTrue(OfflineFallback.allows(URLError(.notConnectedToInternet)))
        XCTAssertTrue(OfflineFallback.allows(TransportFailure.allEndpointsUnavailable))
        XCTAssertFalse(OfflineFallback.allows(URLError(.cancelled)))
        XCTAssertFalse(OfflineFallback.allows(ServerFailure.http(503, nil)))
        XCTAssertFalse(OfflineFallback.allows(ServerFailure.notFound))
        XCTAssertFalse(OfflineFallback.allows(CancellationError()))
        let complete = try await OfflineFallback.index(after: URLError(.timedOut), index, requires: .complete)
        XCTAssertNotNil(complete)
        let none = try await OfflineFallback.index(after: URLError(.timedOut), nil, requires: .complete)
        XCTAssertNil(none)
        let failed = try await OfflineFallback.index(after: ServerFailure.http(500, nil), index, requires: .complete)
        XCTAssertNil(failed)
    }

    // MARK: Helpers

    private func photo(_ id: String, owner: String, trashed: Bool = false, developed: Bool = false) -> Asset {
        var asset = Asset(id: id, ownerId: owner, isDeveloped: developed)
        asset.isTrashed = trashed
        return asset
    }

    private func event(_ type: String, _ json: String, ack: String) throws -> EntitySyncEvent {
        EntitySyncEvent(type: type, data: try JSONDecoder().decode([String: EntityJSON].self, from: Data(json.utf8)), ack: ack)
    }

    private func assertThrows(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected the request to fail.", file: file, line: line) } catch {}
    }

    private func until(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }

    private func removeCachesAfterwards(_ scope: String) {
        addTeardownBlock {
            await TimelineCache.shared.removeAll(scope: scope)
            await TimelinePlacesCache.shared.removeAll(scope: scope)
        }
    }
}

/// A library whose searches all answer with the same photos, recording each request.
actor SearchRecorder: FakeFeedSource {
    nonisolated let cacheScope = "test-search-" + UUID().uuidString
    nonisolated let userID: String?
    private let items: [Asset]
    private(set) var smart: [SearchQuery] = []
    private(set) var metadata: [MetadataQuery] = []
    init(userID: String?, items: [Asset]) { self.userID = userID; self.items = items }
    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] { [] }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] { [] }
    func search(_ query: SearchQuery) async throws -> SearchResponse { smart.append(query); return page() }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { metadata.append(query); return page() }
    private func page() -> SearchResponse {
        SearchResponse(assets: SearchAssets(items: items, count: items.count, nextCursor: nil, nextPage: nil), verification: nil)
    }
}

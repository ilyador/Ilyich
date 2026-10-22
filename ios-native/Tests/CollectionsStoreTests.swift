import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// What the shelves show of the account's collections (REBUILD_ROADMAP.md F5): the newest load
/// wins, a failed load keeps what the shelves show and is tried again later, and the order the
/// owner gives people and albums is kept.
@MainActor final class CollectionsStoreTests: XCTestCase {
    private var server: StubServer!
    private var api: APIClient!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        server = makeStubServer()
        api = try APIClient(baseURL: server.baseURL, accessToken: "session", userID: "alice", sessionConfiguration: server.configuration(),
                            networkConfiguration: NetworkConfiguration())
        let suite = "CollectionsStoreTests-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { [api] in
            await api?.shutdown()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }

    /// An album made while a load is on its way stays on the shelf when that load's list, which
    /// the server gave before the album existed, lands; an album left meanwhile does not come back;
    /// and an older load landing after a newer one is dropped.
    func testAStaleShelfLoadCannotDropANewAlbum() async throws {
        server.route("GET", "server/features", features(map: true))
        server.route("GET", "people", noPeople)
        let store = makeStore()

        // Made while the only load is on its way.
        let first = StubServer.Gate()
        server.route("GET", "albums", albums(["coast"]).waiting(for: first))
        let made = Task { await store.load() }
        try await until("The load did not ask for the albums.") { first.waiting == 1 }
        store.albumCreated(album("harbor"))
        XCTAssertEqual(store.albums.map(\.id), ["harbor"])
        first.open()
        await made.value
        XCTAssertEqual(store.albums.map(\.id), ["harbor", "coast"], "The load on its way cannot drop the album made meanwhile.")

        // Made while an older load is on its way, with a newer load landing first.
        let older = StubServer.Gate()
        server.route("GET", "albums", albums(["harbor", "coast"]).waiting(for: older), albums(["reef", "harbor", "coast"]))
        let stale = Task { await store.load() }
        try await until("The older load did not ask for the albums.") { older.waiting == 1 }
        store.albumCreated(album("reef"))
        await store.load()
        XCTAssertEqual(store.albums.map(\.id), ["reef", "harbor", "coast"])
        older.open()
        await stale.value
        XCTAssertEqual(store.albums.map(\.id), ["reef", "harbor", "coast"], "The older load cannot put back the list without the new album.")

        // Left while a load is on its way.
        let leaving = StubServer.Gate()
        server.route("GET", "albums", albums(["reef", "harbor", "coast"]).waiting(for: leaving), albums(["harbor", "coast"]))
        let left = Task { await store.load() }
        try await until("The load did not ask for the albums.") { leaving.waiting == 1 }
        store.albumRemoved("reef")
        leaving.open()
        await left.value
        XCTAssertEqual(store.albums.map(\.id), ["harbor", "coast"], "The load on its way cannot bring back the album left meanwhile.")
        XCTAssertFalse(store.lastLoadFailed)

        // The owner's order leads with an album made here, and a row moved keeps its place.
        store.saveOrder(["coast", "harbor"], for: .albums)
        store.albumCreated(album("lagoon"))
        XCTAssertEqual(store.orderedAlbums.map(\.id), ["lagoon", "coast", "harbor"])
        XCTAssertTrue(store.moveRow(from: 2, to: 0, of: .albums))
        XCTAssertEqual(store.orderedAlbums.map(\.id), ["harbor", "lagoon", "coast"])
        XCTAssertEqual(defaults.stringArray(forKey: "shelfOrder.albums.\(api.cacheScope)"), ["harbor", "lagoon", "coast"])
        XCTAssertFalse(store.moveRow(from: 0, to: 0, of: .albums))
        store.albumRemoved("lagoon")
        XCTAssertEqual(store.orderedAlbums.map(\.id), ["harbor", "coast"])
    }

    /// A launch load that fails leaves the shelves as they are and marks a reload, which the app
    /// coming forward or the shelves opening runs; a later failed reload keeps what loaded before.
    func testFailedLaunchLoadKeepsPeopleAndAlbumsAndReloadsLater() async throws {
        server.route("GET", "server/features", .immichError(500, message: "Down"))
        server.route("GET", "people", .immichError(500, message: "Down"))
        server.route("GET", "albums", .immichError(500, message: "Down"))
        let store = makeStore()
        await store.load()
        XCTAssertTrue(store.lastLoadFailed)
        XCTAssertEqual(store.people, []); XCTAssertEqual(store.albums, []); XCTAssertNil(store.features)

        server.route("GET", "server/features", features(map: true))
        server.route("GET", "people", page(["maya"]))
        server.route("GET", "albums", albums(["coast"]))
        store.reloadIfFailed()
        try await until("The failed load was not tried again.") { !store.lastLoadFailed }
        XCTAssertEqual(store.people.map(\.id), ["maya"])
        XCTAssertEqual(store.albums.map(\.id), ["coast"])
        XCTAssertEqual(store.features?.map, true)
        let loaded = server.requests.count
        store.reloadIfFailed()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requests.count, loaded, "A load that succeeded is not run again.")

        // The server goes away again: the shelves keep what they show, and a reload is due.
        server.route("GET", "people", .transportFailure(.notConnectedToInternet))
        server.route("GET", "albums", .immichError(503, message: "Down"))
        await store.load()
        XCTAssertTrue(store.lastLoadFailed)
        XCTAssertEqual(store.people.map(\.id), ["maya"], "A failed load keeps the people shown.")
        XCTAssertEqual(store.albums.map(\.id), ["coast"], "And the albums.")
        server.route("GET", "people", page(["maya", "leo"]))
        server.route("GET", "albums", albums(["coast", "harbor"]))
        store.reloadIfFailed()
        try await until("The reload did not land.") { store.people.count == 2 && store.albums.count == 2 }
        XCTAssertFalse(store.lastLoadFailed)
    }

    /// The server's features gate what the shelves offer, such as Places. A load superseded by a
    /// newer one cannot change them when it lands late.
    func testSupersededReloadCannotChangePlaceTimelineSupport() async throws {
        let held = StubServer.Gate()
        server.route("GET", "server/features", features(map: false).waiting(for: held), features(map: true))
        server.route("GET", "people", noPeople)
        server.route("GET", "albums", albums([]))
        let store = makeStore()
        let superseded = Task { await store.load() }
        try await until("The first load did not ask for the features.") { held.waiting == 1 }
        await store.load()
        XCTAssertEqual(store.features?.map, true)
        held.open()
        await superseded.value
        XCTAssertEqual(store.features?.map, true, "The superseded load's features do not take Places away.")
    }

    // MARK: - Support

    private func makeStore() -> CollectionsStore {
        var order = ShelfOrder(scope: api.cacheScope)
        order.defaults = defaults
        return CollectionsStore(api: api, people: PeopleDirectory(source: api), order: order)
    }

    private var noPeople: StubServer.Response { page([]) }

    private func page(_ ids: [String]) -> StubServer.Response {
        let people = ids.map { #"{"id":"\#($0)","name":"\#($0.capitalized)","isHidden":false}"# }.joined(separator: ",")
        return .json(#"{"people":[\#(people)],"total":\#(ids.count),"hidden":0,"hasNextPage":false}"#)
    }

    private func albums(_ ids: [String]) -> StubServer.Response {
        .json("[" + ids.map { #"{"id":"\#($0)","albumName":"\#($0.capitalized)","assetCount":1,"shared":false,"albumUsers":[],"updatedAt":"2026-12-01T12:00:00Z"}"# }.joined(separator: ",") + "]")
    }

    private func album(_ id: String) -> Album {
        Album(id: id, albumName: id.capitalized, assetCount: 1, shared: false, albumUsers: nil, startDate: nil, endDate: nil, updatedAt: nil, order: nil)
    }

    private func features(map: Bool) -> StubServer.Response {
        .json(#"{"passwordLogin":true,"oauth":false,"smartSearch":true,"ocr":false,"facialRecognition":true,"map":\#(map),"trash":true,"sidecar":true,"realtimeTranscoding":false}"#)
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

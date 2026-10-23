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

    /// The shelves read the people and albums in the owner's order on every touch of a drag, at
    /// every level of them, so the store puts them in it when they or the order change and a read
    /// sorts nothing; they keep to the order through a load, a rename, a move, an album made or
    /// left and an order saved.
    func testTheOwnersOrderIsAppliedWhenItChangesNotOnEveryRead() async throws {
        server.route("GET", "server/features", features(map: true))
        server.route("GET", "people", page(["maya", "leo", "ana"]))
        server.route("GET", "albums", albums(["coast", "harbor", "reef"]))
        let store = makeStore()
        store.saveOrder(["ana", "maya"], for: .people)
        store.saveOrder(["reef"], for: .albums)
        await store.load()
        XCTAssertEqual(store.orderedPeople.map(\.id), ["ana", "maya", "leo"], "The owner's order first, then the server's.")
        XCTAssertEqual(store.orderedAlbums.map(\.id), ["reef", "coast", "harbor"])

        // Two reads are one list: neither sorted it again.
        let people = store.orderedPeople, peopleAgain = store.orderedPeople
        XCTAssertTrue(sharesStorage(people, peopleAgain), "Reading the people in the owner's order sorted them again.")
        let albums = store.orderedAlbums, albumsAgain = store.orderedAlbums
        XCTAssertTrue(sharesStorage(albums, albumsAgain), "Reading the albums in the owner's order sorted them again.")

        store.apply(.personUpdated(person("leo", name: "Leonard")))
        XCTAssertEqual(store.orderedPeople.map(\.name), ["Ana", "Maya", "Leonard"])
        XCTAssertTrue(store.moveRow(from: 0, to: 2, of: .people))
        XCTAssertEqual(store.orderedPeople.map(\.id), ["maya", "leo", "ana"])
        store.albumCreated(album("lagoon"))
        XCTAssertEqual(store.orderedAlbums.map(\.id), ["lagoon", "reef", "coast", "harbor"])
        store.albumRemoved("reef")
        XCTAssertEqual(store.orderedAlbums.map(\.id), ["lagoon", "coast", "harbor"])
        store.saveOrder(["harbor"], for: .albums)
        XCTAssertEqual(store.orderedAlbums.map(\.id), ["harbor", "lagoon", "coast"])
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

    // MARK: - Collection changes (N4)

    /// A change to the account's collections applies in place at once: an album renamed keeps its
    /// place, a person renamed theirs, an album deleted or left goes. A load on its way when the
    /// change happened, whose answer the server gave before it, can't put back the old name or the
    /// album left.
    func testCollectionChangesApplyInPlaceAndOutliveALoadOnItsWay() async throws {
        server.route("GET", "server/features", features(map: true))
        server.route("GET", "people", page(["maya", "leo"]))
        server.route("GET", "albums", albums(["coast", "harbor"]))
        let store = makeStore()
        await store.load()

        store.apply(.albumUpdated(album("coast", name: "Coast at dusk")))
        XCTAssertEqual(store.albums.map(\.albumName), ["Coast at dusk", "Harbor"], "A rename keeps the album's place.")
        store.apply(.personUpdated(person("leo", name: "Leonard")))
        XCTAssertEqual(store.people.map(\.name), ["Maya", "Leonard"], "And a person's.")

        // Renamed and left while a load is on its way with the server's older list.
        let gate = StubServer.Gate()
        server.route("GET", "albums", albums(["coast", "harbor", "reef"]).waiting(for: gate))
        server.route("GET", "people", page(["maya", "leo"]))
        let loading = Task { await store.load() }
        try await until("The load did not ask for the albums.") { gate.waiting == 1 }
        store.apply(.albumUpdated(album("harbor", name: "Harbor lights")))
        store.apply(.albumLeft("reef"))
        store.apply(.personUpdated(person("maya", name: "Maya R.")))
        gate.open()
        await loading.value
        XCTAssertEqual(store.albums.map(\.albumName), ["Coast", "Harbor lights"], "The load keeps the rename and the album left out.")
        XCTAssertEqual(store.people.map(\.name), ["Maya R.", "Leo"])

        store.apply(.albumDeleted("coast"))
        store.apply(.partnersChanged)
        store.apply(.memorySaved("memory", saved: true))
        XCTAssertEqual(store.albums.map(\.id), ["harbor"])
        XCTAssertEqual(store.people.count, 2)
    }

    /// The acceptance: an album renamed through the account's collections shows on the shelf at
    /// once, in its place, with nothing loaded again; a shelf's album deleted there leaves it.
    func testAnAlbumRenameShowsOnTheShelfAtOnce() async throws {
        server.route("GET", "server/features", features(map: true))
        server.route("GET", "people", noPeople)
        server.route("GET", "albums", albums(["coast", "harbor"]))
        server.route("PATCH", "albums/harbor", .json(albumJSON("harbor", name: "Harbor lights")))
        server.route("DELETE", "albums/coast", .empty(204))
        let bus = LibraryBus()
        let service = CollectionsService(client: api, authorization: nil, bus: bus)
        addTeardownBlock { await service.shutdown() }
        let store = makeStore()
        await store.load()
        store.follow(bus)
        let loads = server.requests("GET", "albums").count

        let renamed = try await service.updateAlbum("harbor", name: "Harbor lights", description: "", order: "desc")
        XCTAssertEqual(renamed.albumName, "Harbor lights")
        try await until("The rename did not reach the shelf.") { store.orderedAlbums.map(\.albumName) == ["Coast", "Harbor lights"] }
        XCTAssertEqual(try body(server.requests("PATCH", "albums/harbor").first)["albumName"] as? String, "Harbor lights")

        try await service.deleteAlbum("coast")
        try await until("The deleted album stayed on the shelf.") { store.albums.map(\.id) == ["harbor"] }
        XCTAssertEqual(server.requests("GET", "albums").count, loads, "Nothing was loaded again.")
    }

    /// Each change to the account's collections is one call (an album's members are read again
    /// after a change to them) and goes out on the bus with the server's record. Read-only mode
    /// refuses a change before it is sent.
    func testEachCollectionChangeIsOneCallAndReachesTheBus() async throws {
        server.route("POST", "albums", .json(albumJSON("lagoon", name: "Lagoon"), status: 201))
        server.route("DELETE", "albums/lagoon/user/alice", .empty(204))
        server.route("PUT", "albums/coast/user/bob", .empty(204))
        server.route("GET", "albums/coast", .json(albumJSON("coast", name: "Coast")))
        server.route("PUT", "people/maya", .json(#"{"id":"maya","name":"Maya R.","isHidden":false}"#))
        server.route("PUT", "partners/bob", .json("{}"))
        server.route("PUT", "memories/memory", .json("{}"))
        let bus = LibraryBus()
        let heard = Recorded<CollectionChange>()
        _ = bus.subscribe { event -> Bool? in
            if case .collection(let change) = event { heard.append(change) }
            return nil
        }
        let service = CollectionsService(client: api, authorization: nil, bus: bus)
        addTeardownBlock { await service.shutdown() }

        let made = try await service.createAlbum(name: "Lagoon", description: "Low tide")
        XCTAssertEqual(try body(server.requests("POST", "albums").first)["albumName"] as? String, "Lagoon")
        try await service.leaveAlbum("lagoon")
        let shared = try await service.setRole("viewer", of: "bob", in: "coast")
        XCTAssertEqual(try body(server.requests("PUT", "albums/coast/user/bob").first)["role"] as? String, "viewer")
        let maya = try await service.updatePerson("maya", name: "Maya R.", birthDate: nil)
        XCTAssertTrue(try body(server.requests("PUT", "people/maya").first).keys.contains("birthDate"), "A cleared birthday is sent as null.")
        try await service.showPartnerInTimeline("bob", true)
        try await service.setMemorySaved("memory", true)

        XCTAssertEqual(heard.all, [.albumCreated(made), .albumLeft("lagoon"), .albumUpdated(shared), .personUpdated(maya), .partnersChanged,
                                   .memorySaved("memory", saved: true)])
        XCTAssertEqual(server.requests.count, 7, "One call each, and the album read again after its members changed.")

        let readOnly = CollectionsService(client: api, authorization: AuthorizationState(account: AccountID(server: api.baseURL, userID: "alice"), token: "session",
                                                                                         readOnly: true, requiresPasswordChange: false, mirror: nil),
                                          bus: bus)
        addTeardownBlock { await readOnly.shutdown() }
        do {
            try await readOnly.deleteAlbum("coast")
            XCTFail("Read-only mode refuses the change.")
        } catch {
            XCTAssertTrue(error is ReadOnlyPolicy.ReadOnlyError, "\(error)")
        }
        XCTAssertEqual(server.requests.count, 7, "Nothing is sent.")
    }

    /// An album a library mutation made or changed reaches the shelves too: one made from the
    /// selected photos leads them, one given a cover shows it, and one that gained photos is read
    /// again for its count.
    func testAlbumsAMutationChangedReachTheShelves() async throws {
        server.route("GET", "server/features", features(map: true))
        server.route("GET", "people", noPeople)
        server.route("GET", "albums", albums(["coast"]))
        server.route("GET", "albums/coast", .json(albumJSON("coast", name: "Coast", count: 4)))
        let bus = LibraryBus()
        let service = CollectionsService(client: api, authorization: nil, bus: bus)
        addTeardownBlock { await service.shutdown() }
        let store = makeStore()
        await store.load()
        store.follow(bus)

        let made = album("reef", name: "Reef")
        bus.post(.mutation(.applied(MutationResult(operation: OperationID(), request: .createAlbum(name: "Reef", assets: ["a"]),
                                                   succeeded: ["a"], failed: [:], fresh: [:], album: made))))
        try await until("The album made did not reach the shelf.") { store.albums.map(\.id) == ["reef", "coast"] }
        var covered = album("coast", name: "Coast")
        covered.albumThumbnailAssetId = "a"
        bus.post(.mutation(.applied(MutationResult(operation: OperationID(), request: .setAlbumCover(album: "coast", asset: "a"),
                                                   succeeded: ["a"], failed: [:], fresh: [:], album: covered))))
        try await until("The cover did not reach the shelf.") { store.albums.last?.albumThumbnailAssetId == "a" }
        bus.post(.mutation(.applied(MutationResult(operation: OperationID(), request: .addToAlbum(album: "coast", assets: ["b"]),
                                                   succeeded: ["b"], failed: [:], fresh: [:]))))
        try await until("The album's count was not read again.") { store.albums.last?.assetCount == 4 }
        XCTAssertEqual(server.requests("GET", "albums/coast").count, 1)
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

    private func album(_ id: String, name: String? = nil) -> Album {
        Album(id: id, albumName: name ?? id.capitalized, assetCount: 1, shared: false, albumUsers: nil, startDate: nil, endDate: nil, updatedAt: nil, order: nil)
    }

    private func person(_ id: String, name: String) -> Person {
        Person(id: id, name: name, birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: false, isFavorite: nil)
    }

    private func albumJSON(_ id: String, name: String, count: Int = 1) -> String {
        #"{"id":"\#(id)","albumName":"\#(name)","assetCount":\#(count),"shared":false,"albumUsers":[],"updatedAt":"2026-12-01T12:00:00Z","order":"desc"}"#
    }

    /// Whether two lists are one in memory, as two reads of a kept list are and two lists sorted
    /// apart are not.
    private func sharesStorage<Element>(_ first: [Element], _ second: [Element]) -> Bool {
        first.withUnsafeBufferPointer { first in second.withUnsafeBufferPointer { second in first.baseAddress == second.baseAddress } }
    }

    /// A request's JSON body.
    private func body(_ request: StubServer.Request?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request?.body)) as? [String: Any])
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

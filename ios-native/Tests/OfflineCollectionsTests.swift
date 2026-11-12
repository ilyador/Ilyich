import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

@MainActor final class OfflineCollectionsTests: XCTestCase {
    private var server: StubServer!
    private var api: APIClient!
    private var index: LibraryIndex!

    override func setUp() async throws {
        server = makeStubServer()
        api = try APIClient(baseURL: server.baseURL, accessToken: "session", userID: "alice", sessionConfiguration: server.configuration(),
                            networkConfiguration: NetworkConfiguration())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineCollections-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { [api] in
            await api?.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        index = try LibraryIndex(scope: api.cacheScope, userID: "alice", directory: directory)
        await api.attachEntityStore(index)
    }

    func testAlbumsRenderTheSavedListBeforeTheServerAnswers() async throws {
        try await completeIndex(albums: ["coast"])
        let gate = StubServer.Gate()
        server.route("GET", "albums", albums(["harbor"]).waiting(for: gate))
        let store = AlbumsStore(source: api)
        let loading = Task { await store.load() }
        try await until { gate.waiting == 1 }
        XCTAssertEqual(store.albums.map(\.id), ["coast"])
        XCTAssertTrue(store.hasSnapshot)
        XCTAssertTrue(store.isLoading)
        gate.open(); await loading.value
        XCTAssertEqual(store.albums.map(\.id), ["harbor"])
        XCTAssertFalse(store.isOffline)
    }

    func testAnOfflineEmptyIndexDoesNotEraseNewerAlbumsButAServerEmptyListDoes() async throws {
        try await completeIndex()
        server.route("GET", "albums", albums(["coast"]), .transportFailure(.notConnectedToInternet), albums([]))
        let store = AlbumsStore(source: api)
        await store.load()
        XCTAssertEqual(store.albums.map(\.id), ["coast"])
        await store.load()
        XCTAssertEqual(store.albums.map(\.id), ["coast"], "An old empty index cannot erase the list shown after a transport failure.")
        XCTAssertTrue(store.isOffline)
        XCTAssertNil(store.failure)
        await store.load()
        XCTAssertEqual(store.albums, [], "A successful server answer is authoritative, even when empty.")
        XCTAssertTrue(store.hasSnapshot)
        XCTAssertFalse(store.isOffline)
    }

    func testMissingOfflineAlbumsAreDifferentFromASuccessfullyEmptyLibrary() async throws {
        server.route("GET", "albums", .transportFailure(.notConnectedToInternet), albums([]))
        let store = AlbumsStore(source: api)
        await store.load()
        XCTAssertFalse(store.hasSnapshot)
        XCTAssertTrue(store.isOffline)
        XCTAssertNotNil(store.failure)
        await store.load()
        XCTAssertTrue(store.hasSnapshot)
        XCTAssertFalse(store.isOffline)
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.albums, [])
    }

    func testAlbumRefusalClearsTheSavedListAndCannotFallBackOnTheNextOfflineRetry() async throws {
        try await completeIndex(albums: ["coast"])
        server.route("GET", "albums", .immichError(403, message: "Access removed"), .transportFailure(.notConnectedToInternet), albums(["harbor"]))
        let store = AlbumsStore(source: api)
        await store.load()
        XCTAssertEqual(store.albums, [])
        XCTAssertFalse(store.hasSnapshot)
        let denied = try await api.cachedAlbums()
        XCTAssertNil(denied)
        await store.load()
        XCTAssertEqual(store.albums, [])
        XCTAssertFalse(store.hasSnapshot)
        XCTAssertNotNil(store.failure, "Known denied content stays blocked, even if the next request is offline.")
        await store.load()
        XCTAssertEqual(store.albums.map(\.id), ["harbor"], "A later successful server read recovers the screen.")
    }

    func testAnOldAlbumResponseCannotReopenTheCacheAfterANewerRefusal() async throws {
        try await completeIndex(albums: ["coast"])
        let gate = StubServer.Gate()
        server.route("GET", "albums", albums(["coast"]).waiting(for: gate), .immichError(401, message: "Expired"))
        let store = AlbumsStore(source: api)
        let old = Task { await store.load() }
        try await until { gate.waiting == 1 }
        await store.load()
        gate.open(); await old.value
        XCTAssertEqual(store.albums, [])
        XCTAssertFalse(store.hasSnapshot)
        let cached = try await api.cachedAlbums()
        XCTAssertNil(cached, "The older success must not reopen a cache the newer refusal closed.")
    }

    func testAlbumDenialSurvivesAColdOfflineLaunchUntilThatEndpointSucceeds() async throws {
        try await completeIndex(albums: ["coast"], people: ["maya"])
        server.route("GET", "albums", .immichError(403, message: "Access removed"), .transportFailure(.notConnectedToInternet), albums(["coast"]))
        let first = AlbumsStore(source: api)
        await first.load()
        await api.shutdown()

        let restarted = try await reopenedClient()
        let denied = try await restarted.cachedAlbums()
        let unrelated = try await restarted.cachedPeople()
        XCTAssertNil(denied)
        XCTAssertEqual(unrelated?.map(\.id), ["maya"], "An album refusal does not disable the saved People list.")
        let cold = AlbumsStore(source: restarted)
        await cold.load()
        XCTAssertTrue(cold.albums.isEmpty)
        XCTAssertFalse(cold.hasSnapshot, "An offline restart must not seed the list that the server refused.")
        XCTAssertNotNil(cold.failure)
        await cold.load()
        XCTAssertEqual(cold.albums.map(\.id), ["coast"])
        let restored = try await restarted.cachedAlbums()
        XCTAssertEqual(restored?.map(\.id), ["coast"], "An actual successful endpoint read restores its cache.")
    }

    func testAResponseFromBeforeAnotherClientsDenialCannotClearTheSavedFence() async throws {
        try await completeIndex(albums: ["coast"])
        let gate = StubServer.Gate()
        server.route("GET", "albums", albums(["coast"]).waiting(for: gate), .immichError(403, message: "Access removed"))
        let old = Task { try await api.albumListing() }
        try await until { gate.waiting == 1 }
        let other = try await reopenedClient()
        do { _ = try await other.albumListing(); XCTFail("The newer request must see the refusal.") } catch { }
        gate.open()
        do { _ = try await old.value; XCTFail("An older 200 must not clear another client's persisted refusal.") } catch { }
        let restarted = try await reopenedClient()
        let denied = try await restarted.cachedAlbums()
        XCTAssertNil(denied)
    }

    func testARefusalInAnotherConsumerAlsoClearsAnOlderCollectionLoad() async throws {
        try await completeIndex(albums: ["coast"])
        let gate = StubServer.Gate()
        server.route("GET", "albums", albums(["coast"]).waiting(for: gate), .immichError(403, message: "Access removed"))
        let store = AlbumsStore(source: api)
        let loading = Task { await store.load() }
        try await until { gate.waiting == 1 }
        do { _ = try await api.albums(); XCTFail("The second consumer must see the refusal.") } catch { }
        gate.open(); await loading.value
        XCTAssertEqual(store.albums, [], "An overtaken response is an access change, not a harmless cancellation that keeps old rows.")
        XCTAssertFalse(store.hasSnapshot)
        XCTAssertNotNil(store.failure)
    }

    func testPeopleRenderSavedNamesBeforeARefreshAndKeepThemOffline() async throws {
        try await completeIndex(people: ["maya"])
        let gate = StubServer.Gate()
        server.route("GET", "people", people(["ann"]).waiting(for: gate), .transportFailure(.notConnectedToInternet))
        let pager = PeoplePager(source: api)
        let loading = Task { await pager.start(query: "", keepingPeople: true) }
        try await until { gate.waiting == 1 }
        XCTAssertEqual(pager.people.map(\.id), ["maya"])
        XCTAssertTrue(pager.hasSnapshot)
        gate.open(); await loading.value
        XCTAssertEqual(pager.people.map(\.id), ["ann"])
        await pager.start(query: "", keepingPeople: true)
        XCTAssertEqual(pager.people.map(\.id), ["ann"], "A refresh that cannot reach the server keeps the newer names already shown.")
        XCTAssertTrue(pager.isOffline)
        XCTAssertFalse(pager.hasMore)
    }

    func testPeopleDistinguishNoOfflineCopyFromAnEmptyServerAnswer() async throws {
        server.route("GET", "people", .transportFailure(.notConnectedToInternet), people([]))
        let pager = PeoplePager(source: api)
        await pager.start(query: "")
        XCTAssertTrue(pager.isOffline)
        XCTAssertFalse(pager.hasSnapshot)
        XCTAssertNotNil(pager.failure)
        await pager.start(query: "")
        XCTAssertFalse(pager.isOffline)
        XCTAssertTrue(pager.hasSnapshot)
        XCTAssertNil(pager.failure)
        XCTAssertEqual(pager.people, [])
    }

    func testPeopleRefusalDoesNotReappearThroughTheOfflineIndex() async throws {
        try await completeIndex(people: ["maya"])
        server.route("GET", "people", .immichError(403, message: "Access removed"), .transportFailure(.notConnectedToInternet))
        let pager = PeoplePager(source: api)
        await pager.start(query: "", keepingPeople: true)
        XCTAssertEqual(pager.people, [])
        XCTAssertFalse(pager.hasSnapshot)
        let denied = try await api.cachedPeople()
        XCTAssertNil(denied)
        await pager.start(query: "", keepingPeople: true)
        XCTAssertEqual(pager.people, [])
        XCTAssertFalse(pager.hasSnapshot)
        XCTAssertNotNil(pager.failure)
    }

    func testPeopleDenialSurvivesAColdOfflineLaunchUntilThatEndpointSucceeds() async throws {
        try await completeIndex(albums: ["coast"], people: ["maya"])
        server.route("GET", "people", .immichError(403, message: "Access removed"), .transportFailure(.notConnectedToInternet), people(["maya"]))
        let first = PeoplePager(source: api)
        await first.start(query: "")
        await api.shutdown()

        let restarted = try await reopenedClient()
        let denied = try await restarted.cachedPeople()
        let unrelated = try await restarted.cachedAlbums()
        XCTAssertNil(denied)
        XCTAssertEqual(unrelated?.map(\.id), ["coast"], "A People refusal does not disable the saved album list.")
        let cold = PeoplePager(source: restarted)
        await cold.start(query: "", keepingPeople: true)
        XCTAssertTrue(cold.people.isEmpty)
        XCTAssertFalse(cold.hasSnapshot)
        XCTAssertNotNil(cold.failure)
        await cold.start(query: "", keepingPeople: true)
        XCTAssertEqual(cold.people.map(\.id), ["maya"])
        let restored = try await restarted.cachedPeople()
        XCTAssertEqual(restored?.map(\.id), ["maya"])
    }

    func testARefusalElsewhereClearsAlreadyShownAlbumsOnAnOfflineRefresh() async throws {
        try await completeIndex(albums: ["coast"])
        server.route("GET", "albums", albums(["coast"]), .immichError(403, message: "Access removed"), .transportFailure(.notConnectedToInternet))
        let store = AlbumsStore(source: api)
        await store.load()
        let other = try await reopenedClient()
        do { _ = try await other.albumListing(); XCTFail("The other consumer must see the refusal.") } catch { }
        await store.load()
        XCTAssertTrue(store.albums.isEmpty, "A transport failure cannot retain rows that another consumer learned were denied.")
        XCTAssertFalse(store.hasSnapshot)
    }

    func testACollectionChangeDuringAnAlbumLoadStillWins() async throws {
        let gate = StubServer.Gate()
        server.route("GET", "albums", albums(["coast", "harbor"]).waiting(for: gate))
        let store = AlbumsStore(source: api)
        let loading = Task { await store.load() }
        try await until { gate.waiting == 1 }
        store.apply(.albumLeft("coast"))
        gate.open(); await loading.value
        XCTAssertEqual(store.albums.map(\.id), ["harbor"])
    }

    func testAnAlbumLeftDoesNotReturnFromAnOlderOfflineIndex() async throws {
        try await completeIndex(albums: ["coast"])
        server.route("GET", "albums", albums(["coast"]), .transportFailure(.notConnectedToInternet))
        let store = AlbumsStore(source: api)
        await store.load()
        store.apply(.albumLeft("coast"))
        await store.load()
        XCTAssertEqual(store.albums, [], "A confirmed local removal outlives an offline refresh.")
        XCTAssertTrue(store.isOffline)
    }

    func testCollectionCachesAreScopedToTheSignedInAccount() async throws {
        try await completeIndex(albums: ["coast"], people: ["maya"])
        let other = try APIClient(baseURL: server.baseURL, accessToken: "other", userID: "bob", sessionConfiguration: server.configuration(),
                                  networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await other.shutdown() }
        await other.attachEntityStore(index)
        let albums = try await other.cachedAlbums(), people = try await other.cachedPeople()
        XCTAssertNil(albums)
        XCTAssertNil(people)
    }

    private func completeIndex(albums: [String] = [], people: [String] = []) async throws {
        var events = albums.map { SyncEvents.event("AlbumV2", #"{"id":"\#($0)","name":"\#($0.capitalized)","thumbnailAssetId":null}"#, ack: "AlbumV2|" + $0) }
        events += people.map { SyncEvents.event("PersonV1", #"{"id":"\#($0)","name":"\#($0.capitalized)","isHidden":false}"#, ack: "PersonV1|" + $0) }
        events.append(SyncEvents.complete())
        _ = try await index.apply(events, epoch: await index.epoch())
    }

    private func reopenedClient() async throws -> APIClient {
        let client = try APIClient(baseURL: server.baseURL, accessToken: "session", userID: "alice", sessionConfiguration: server.configuration(),
                                   networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await client.shutdown() }
        let directory = URL(fileURLWithPath: index.writer.path).deletingLastPathComponent()
        let reopened = try LibraryIndex(scope: client.cacheScope, userID: "alice", directory: directory)
        await client.attachEntityStore(reopened)
        return client
    }

    private func albums(_ ids: [String]) -> StubServer.Response {
        .json("[" + ids.map { #"{"id":"\#($0)","albumName":"\#($0.capitalized)","assetCount":1,"shared":false}"# }.joined(separator: ",") + "]")
    }

    private func people(_ ids: [String]) -> StubServer.Response {
        let rows = ids.map { #"{"id":"\#($0)","name":"\#($0.capitalized)","isHidden":false}"# }.joined(separator: ",")
        return .json(#"{"people":[\#(rows)],"total":\#(ids.count),"hidden":0,"hasNextPage":false}"#)
    }

    private func until(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The collection request did not start.")
    }
}

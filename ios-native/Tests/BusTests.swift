import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// N4: the account's bus replaced the notification dictionaries. Every subscriber gets every
/// mutation result and every sync change, in one order, and each of the screens that observed the
/// notifications still updates from it: the feed and its search results, the viewer's refresh, the
/// shelves, and the feed after Diagnostics clears the browsing cache.
@MainActor final class BusTests: XCTestCase {
    private static let march = "2026-03-01T00:00:00Z"

    /// A favorite made through the account's mutations and an album renamed through its
    /// collections reach every subscriber in the order they happened: the server's answer, the
    /// follow-up sync's change, the answer with the follow-up merged in, then the rename.
    func testEverySubscriberGetsMutationAndSyncChanges() async throws {
        let harness = try makeSyncHarness()
        try await harness.primeIndex([SyncEvents.asset("photo")])
        var favorite = asset("photo")
        favorite.isFavorite = true
        harness.server.route("PUT", "assets/photo", .json(String(decoding: try APIJSON.encoder().encode(favorite), as: UTF8.self)))
        harness.server.route("POST", "sync/stream", SyncEvents.stream([SyncEvents.asset("photo", revision: "r2"), SyncEvents.complete()]))
        harness.server.route("PATCH", "albums/coast", .json(Self.albumJSON("coast", name: "Coast at dusk")))
        let engine = harness.engine
        let mutations = LibraryMutationService(client: harness.api, pipeline: harness.pipeline, authorization: harness.authorization,
                                               refresh: { try await engine.refresh() }, bus: harness.bus)
        let collections = CollectionsService(client: harness.api, authorization: harness.authorization, bus: harness.bus)
        addTeardownBlock { await mutations.shutdown(); await collections.shutdown() }
        let first = harness.bus.events(), second = harness.bus.events()

        _ = try await mutations.start(.favorite(["photo"], true), on: [asset("photo")]).result
        let followed = await becomesTrue { mutations.runningCount == 0 }
        XCTAssertTrue(followed, "The follow-up sync ran.")
        _ = try await collections.updateAlbum("coast", name: "Coast at dusk", description: "", order: "desc")

        for events in [first, second] {
            let heard = try await take(4, from: events)
            guard case .mutation(.applied(let applied)) = heard[0] else { return XCTFail("The server's answer comes first: \(heard)") }
            XCTAssertEqual(applied.fresh["photo"]?.isFavorite, true)
            guard case .changed(let change, let accessChanged) = heard[1] else { return XCTFail("Then the sync's change: \(heard)") }
            XCTAssertNotNil(change.upserted["photo"], "It names the photo the sync read again.")
            XCTAssertFalse(accessChanged)
            guard case .mutation(.followedUp(let result)) = heard[2] else { return XCTFail("Then the follow-up: \(heard)") }
            XCTAssertEqual(result.operation, applied.operation)
            XCTAssertNotNil(result.followUp?.upserted["photo"], "The sync's change is merged into it.")
            guard case .collection(.albumUpdated(let album)) = heard[3] else { return XCTFail("Then the rename: \(heard)") }
            XCTAssertEqual(album.albumName, "Coast at dusk")
        }
    }

    /// Sync changes a subscriber hasn't taken yet, one right after another, fold into one, and
    /// lost access is never forgotten; nothing else is merged or dropped. Closing the bus ends
    /// every stream once it has been read, and later events reach no one.
    func testAFallingBehindSubscriberMissesNothingAndClosingEndsEveryStream() async throws {
        let bus = LibraryBus()
        let events = bus.events()
        let account = AccountID(server: URL(string: "https://photos.example/api")!, userID: "me")
        func change(_ removed: String) -> LibraryChange {
            var change = LibraryChange(account: account, authorization: AuthorizationEpoch(account: account, value: 1), indexRevision: 1, origin: .sync)
            change.removed = [removed]
            return change
        }
        bus.post(.changed(change("a"), accessChanged: false))
        bus.post(.changed(change("b"), accessChanged: true))
        bus.post(.cachesCleared)
        bus.post(.changed(change("c"), accessChanged: false))
        bus.post(.collection(.partnersChanged))
        XCTAssertEqual(bus.subscriberCount, 1)
        bus.close()
        bus.post(.cachesCleared)
        XCTAssertEqual(bus.subscriberCount, 0)

        var heard: [String] = []
        for await event in events {
            switch event {
            case .changed(let change, let accessChanged): heard.append("changed \(change.removed.sorted()) \(accessChanged)")
            case .cachesCleared: heard.append("cachesCleared")
            case .collection(let change): heard.append("collection \(change)")
            case .mutation: heard.append("mutation")
            }
        }
        XCTAssertEqual(heard, ["changed [\"a\", \"b\"] true", "cachesCleared", "changed [\"c\"] false", "collection partnersChanged"])
        var late = bus.events().makeAsyncIterator()
        let none = await late.next()
        XCTAssertNil(none, "A closed bus hands out ended streams.")
    }

    /// The feed and its search results: a sync change takes what it removed out of the months and
    /// the results at once, and a mutation's result does the same. A cleared browsing cache, as
    /// Diagnostics clears it through the account, has the feed read its months again.
    func testTheFeedAndItsSearchResultsFollowTheBus() async throws {
        let source = BusLibrary(timeline: ["a", "b", "c"], results: ["x", "y", "z"])
        let store = LibraryFeedStore(source: source)
        defer { store.stop() }
        await store.reload()
        store.requestBucket(0)
        try await until("The month did not load.") { store.loaded[Self.march]?.count == 3 }
        let bus = LibraryBus()
        let follower = LibraryFollower()
        follower.follow(bus) { event in await FeedEventApplier.apply(event, to: store, refreshes: false) }
        defer { follower.stop() }

        // The server no longer has what each change took away.
        await source.remove(["a"])
        bus.post(.changed(removing: ["a"]))
        try await until("The sync's removal did not reach the feed.") { store.availableAssets(around: "b").map(\.id) == ["b", "c"] }
        await source.remove(["b"])
        bus.post(.mutation(.applied(trashed("b"))))
        try await until("The mutation's result did not reach the feed.") { store.availableAssets(around: "c").map(\.id) == ["c"] }

        let refreshes = await source.refreshes
        bus.post(.cachesCleared)
        try await until("A cleared cache did not have the feed read again.") { await source.refreshes == refreshes + 1 }

        store.setMetadataFilter(SearchFilter(type: StringFilter(eq: "VIDEO")), title: "Videos")
        try await until("The results did not load.") { store.results.map(\.id) == ["x", "y", "z"] && !store.isSearching }
        await source.remove(["x"])
        bus.post(.changed(removing: ["x"]))
        try await until("The sync's removal did not reach the results.") { store.results.map(\.id) == ["y", "z"] }
        await source.remove(["y"])
        bus.post(.mutation(.applied(trashed("y"))))
        try await until("The mutation's result did not reach the results.") { store.results.map(\.id) == ["z"] }
    }

    /// The viewer: each sync change reads the photo on screen again, one that may have taken
    /// access asks for the photo to be confirmed, and a mutation's result shows its fresh record.
    func testTheViewerRefreshesFromTheBus() async throws {
        let server = makeStubServer()
        let api = try APIClient(baseURL: server.baseURL, accessToken: "viewer", userID: "me", sessionConfiguration: server.configuration(),
                                networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        let shown = asset("photo")
        let list = AssetList([shown])
        let model = ViewerModel(api: api, route: ViewerRoute(asset: shown, source: .collection("list"), albumContext: nil),
                                window: .collection(list), settleDelay: .zero)
        let bus = LibraryBus()
        model.start(mutations: nil, bus: bus, close: {})
        XCTAssertEqual(bus.subscriberCount, 1, "The viewer follows the account's bus.")

        bus.post(.changed(removing: ["elsewhere"]))
        try await until("The viewer did not read its photo again.") { model.refreshRevision == 1 }
        var favorite = shown
        favorite.isFavorite = true
        bus.post(.mutation(.applied(MutationResult(operation: OperationID(), request: .favorite(["photo"], true), succeeded: ["photo"],
                                                   failed: [:], fresh: ["photo": favorite]))))
        try await until("The viewer did not show the change.") { model.current.isFavorite == true }
    }

    /// The shelves: a collection change applies in place, and a sync change to albums, people,
    /// partners or memories loads them again; one to photos alone doesn't.
    func testTheShelvesFollowTheBus() async throws {
        let server = makeStubServer()
        server.route("GET", "server/features", .json(Self.features))
        server.route("GET", "people", .json(#"{"people":[],"total":0,"hidden":0,"hasNextPage":false}"#))
        server.route("GET", "albums", .json("[" + Self.albumJSON("coast", name: "Coast") + "," + Self.albumJSON("harbor", name: "Harbor") + "]"))
        let api = try APIClient(baseURL: server.baseURL, accessToken: "shelves", userID: "me", sessionConfiguration: server.configuration(),
                                networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        var order = ShelfOrder(scope: api.cacheScope)
        let suite = "BusTests-" + UUID().uuidString
        order.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = CollectionsStore(api: api, people: PeopleDirectory(source: api), order: order)
        await store.load()
        let bus = LibraryBus()
        store.follow(bus)

        var renamed = try XCTUnwrap(store.albums.first)
        renamed.albumName = "Coast at dusk"
        bus.post(.collection(.albumUpdated(renamed)))
        try await until("The rename did not reach the shelf.") { store.albums.map(\.albumName) == ["Coast at dusk", "Harbor"] }

        let loads = server.requests("GET", "albums").count
        bus.post(.changed(removing: ["photo"]))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(server.requests("GET", "albums").count, loads, "A change to photos alone leaves the shelves.")
        var albums = LibraryChange.removing([])
        albums.albums = ["harbor"]
        bus.post(.changed(albums, accessChanged: false))
        try await until("A sync change to an album did not load the shelves again.") { server.requests("GET", "albums").count == loads + 1 }
        try await until("The load did not land.") { store.albums.map(\.albumName) == ["Coast", "Harbor"] }
    }

    // MARK: - Support

    private static let features = #"{"passwordLogin":true,"oauth":false,"smartSearch":true,"ocr":false,"facialRecognition":true,"map":true,"trash":true,"sidecar":true,"realtimeTranscoding":false}"#

    static func albumJSON(_ id: String, name: String) -> String {
        #"{"id":"\#(id)","albumName":"\#(name)","assetCount":3,"shared":false,"albumUsers":[],"updatedAt":"2026-12-01T12:00:00Z","order":"desc"}"#
    }

    private func asset(_ id: String) -> Asset {
        var asset = Asset(id: id, localDateTime: APIDate.parse("2026-03-10T12:00:00Z"))
        asset.ownerId = "alice"
        return asset
    }

    /// A photo put in Trash, as the mutation service publishes it.
    private func trashed(_ id: String) -> MutationResult {
        var record = asset(id)
        record.isTrashed = true
        return MutationResult(operation: OperationID(), request: .trash([id]), succeeded: [id], failed: [:], fresh: [id: record])
    }

    /// The first `count` events, or a failure after five seconds.
    private func take(_ count: Int, from events: AsyncStream<LibraryEvent>) async throws -> [LibraryEvent] {
        let taking = Task {
            var taken: [LibraryEvent] = []
            for await event in events {
                taken.append(event)
                if taken.count == count { break }
            }
            return taken
        }
        let deadline = Task { try await Task.sleep(for: .seconds(5)); taking.cancel() }
        defer { deadline.cancel() }
        let taken = await taking.value
        XCTAssertEqual(taken.count, count, "Only \(taken.count) events arrived: \(taken)")
        return taken
    }

    private func until(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
        throw CancellationError()
    }
}

private extension LibraryEvent {
    /// A sync change that took `ids` away.
    static func changed(removing ids: Set<String>) -> LibraryEvent { .changed(.removing(ids), accessChanged: false) }
}

private extension LibraryChange {
    static func removing(_ ids: Set<String>) -> LibraryChange {
        let account = AccountID(server: URL(string: "https://photos.example/api")!, userID: "me")
        var change = LibraryChange(account: account, authorization: AuthorizationEpoch(account: account, value: 1), indexRevision: 1, origin: .sync)
        change.removed = ids
        return change
    }
}

/// A library of one month of timeline photos, and the results every metadata search finds.
private actor BusLibrary: FakeFeedSource {
    nonisolated let cacheScope = "test-bus-" + UUID().uuidString
    private var timeline: [String]
    private var results: [String]
    var refreshes = 0

    init(timeline: [String], results: [String]) {
        self.timeline = timeline
        self.results = results
    }

    /// The server lets these photos go.
    func remove(_ ids: Set<String>) {
        timeline.removeAll { ids.contains($0) }
        results.removeAll { ids.contains($0) }
    }

    func refresh() async throws -> LibraryChange? { refreshes += 1; return nil }
    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] { [TimeBucket(timeBucket: "2026-03-01T00:00:00Z", count: timeline.count)] }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] { timeline.map { Self.asset($0) } }
    func search(_ query: SearchQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse {
        let assets = results.map { Self.asset($0) }
        return SearchResponse(assets: .init(items: assets, count: assets.count, nextCursor: nil, nextPage: nil), verification: nil)
    }

    private static func asset(_ id: String) -> Asset {
        Asset(id: id, localDateTime: APIDate.parse("2026-03-10T12:00:00Z"))
    }
}

import Foundation
import XCTest
@testable import Ilyich

/// The server's partner setting is membership, not a UI preference: every index projection
/// and the server-only search fallback must agree, without changing own-only collections.
@MainActor final class PartnerTimelineTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PartnerTimeline-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func partner(_ id: String, shown: Bool, incoming: Bool = true) -> EntitySyncEvent {
        let by = incoming ? id : "alice", with = incoming ? "alice" : id
        return SyncEvents.event("PartnerV1", #"{"sharedById":"\#(by)","sharedWithId":"\#(with)","inTimeline":\#(shown)}"#,
                                ack: "PartnerV1|\(id)-\(shown)")
    }

    private func photo(_ id: String, owner: String = "alice", visibility: String = "timeline", video: Bool = false,
                       trashed: Bool = false) -> EntitySyncEvent {
        var event = IndexReadsTests.asset(id, owner: owner, taken: "2026-02-01T05:00:00Z", visibility: visibility,
                                         trashed: trashed, favorite: true, developed: true,
                                         type: owner == "alice" ? "AssetV2" : "PartnerAssetV2")
        if video { event.data["type"] = .string("VIDEO") }
        return event
    }

    private func seed(_ index: LibraryIndex) async throws {
        _ = try await index.apply([
            partner("bob", shown: true), partner("carol", shown: false), partner("outgoing", shown: true, incoming: false),
            photo("mine"), photo("mine-video", video: true), photo("mine-archive", visibility: "archive"),
            photo("bob", owner: "bob"), photo("bob-video", owner: "bob", video: true),
            photo("carol", owner: "carol"), photo("outgoing", owner: "outgoing"),
            photo("bob-archive", owner: "bob", visibility: "archive"), photo("bob-trash", owner: "bob", trashed: true),
            photo("bob-hidden", owner: "bob", visibility: "hidden"), photo("bob-locked", owner: "bob", visibility: "locked"),
            SyncEvents.event("PersonV1", #"{"id":"maya","name":"Maya","isHidden":false}"#),
            IndexReadsTests.face("mine-face", asset: "mine-video"), IndexReadsTests.face("bob-face", asset: "bob-video"),
            SyncEvents.event("AssetExifV1", #"{"assetId":"mine","city":"Lisbon","country":"Portugal"}"#),
            SyncEvents.event("PartnerAssetExifV1", #"{"assetId":"bob","city":"Porto","country":"Portugal"}"#),
            SyncEvents.complete(),
        ], epoch: index.epoch())
    }

    func testLibraryAndMediaFeedsUseOnlyIncomingTimelinePartners() async throws {
        let index = try LibraryIndex(scope: "server|alice", userID: "alice", directory: directory())
        try await seed(index)
        let table: [(LibraryQuery, Set<String>)] = [
            (.library, ["mine", "mine-video", "bob", "bob-video"]),
            (.videos, ["mine-video", "bob-video"]),
            (.lightroom, ["mine", "mine-video", "bob", "bob-video"]),
            (.recentlyTaken, ["mine", "mine-video"]),
            (.favorites, ["mine", "mine-video"]),
            (.archive, ["mine-archive"]),
        ]
        for (query, expected) in table {
            let assets = try await index.timelineAssets(query)
            XCTAssertEqual(Set(assets.map(\.id)), expected, query.stableKey)
            let months = try await index.timeBuckets(query)
            XCTAssertEqual(months.reduce(0) { $0 + $1.count }, expected.count, query.stableKey)
            let ids = try await index.feedIDs(query)
            XCTAssertEqual(ids, expected, "Earth membership must match the feed.")
        }
        let facets = try await index.facets(.videos)
        XCTAssertEqual(facets.people, ["maya": 2], "The shelves count the partner's video too.")
        let places = try await index.monthPlaces()
        XCTAssertEqual(Set(places.compactMap(\.city)), ["Lisbon", "Porto"])
        let coverage = try await index.coverageCount()
        XCTAssertEqual(coverage, 2, "Whole-library offline coverage remains the account's own timeline.")
    }

    func testPartnerToggleChangesTheIndexWithoutAssetUpdatesAndClearsSavedCounts() async throws {
        let root = directory()
        let index = try LibraryIndex(scope: "server|alice", userID: "alice", directory: root)
        try await seed(index)
        let counts = try await index.monthPlaces()
        try await index.keepMonthPlaces(counts, forKey: LibraryQuery.library.stableKey, ifCurrent: { true })
        let change = try await index.apply([partner("bob", shown: false)], epoch: index.epoch())
        XCTAssertTrue(change.partnersChanged)
        let saved = try await index.monthPlaces(forKey: LibraryQuery.library.stableKey)
        XCTAssertNil(saved)
        let own = try await index.feedIDs(.library)
        XCTAssertEqual(own, ["mine", "mine-video"])

        let reopened = try LibraryIndex(scope: "server|alice", userID: "alice", directory: root)
        let afterLaunch = try await reopened.feedIDs(.library)
        XCTAssertEqual(afterLaunch, own, "A new launch follows the persisted partner setting.")
        _ = try await index.apply([partner("carol", shown: true)], epoch: index.epoch())
        let next = try await index.feedIDs(.library)
        XCTAssertEqual(next, ["mine", "mine-video", "carol"], "Existing shared assets join without an asset re-upload or reset.")
        let retained = try await index.asset(id: "bob")
        XCTAssertNotNil(retained, "Hiding a partner from the timeline does not revoke access to their library.")
    }

    func testSearchFallbackDoesNotDiscardEnabledPartnerMedia() throws {
        for query in [LibraryQuery.videos, .motion, .lightroom] {
            XCTAssertFalse(QueryPlanner.keepsToOwnPhotos(query), query.stableKey)
            let search = try ServerSearchRequest(query, userID: "alice", keepsToOwnPhotos: QueryPlanner.keepsToOwnPhotos(query))
            XCTAssertNil(search.owner, "The server's search already restricts its universe to incoming partners shown in the timeline.")
        }
        for query in [LibraryQuery.favorites, .archive, .trash] {
            XCTAssertTrue(QueryPlanner.keepsToOwnPhotos(query), query.stableKey)
        }
        XCTAssertTrue(LibraryQuery.library.stableKey.hasSuffix("&withPartners=true"))
        XCTAssertFalse(LibraryQuery.favorites.stableKey.contains("withPartners"))
    }

    func testASettingChangedHereRefreshesTheIndexBeforeReadingTheFeedAgain() async throws {
        let source = PartnerSettingSource()
        let store = LibraryFeedStore(source: source, placesDelay: .zero)
        defer { store.stop() }
        await store.reload()
        try await until { store.loaded.values.flatMap { $0 }.contains { $0.id == "bob" } }
        _ = store.apply(.partnersChanged)
        try await until {
            let refreshes = await source.refreshes
            return refreshes == 1 && Set(store.loaded.values.flatMap { $0 }.map(\.id)) == ["mine"]
        }
    }

    private func until(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The partner setting was not applied to the feed.")
    }
}

/// The remote setting changed while the index still includes Bob, until the next sync pass.
private actor PartnerSettingSource: FakeFeedSource {
    nonisolated let cacheScope = "partner-setting"
    nonisolated let userID: String? = "alice"
    private var shown = true
    private(set) var refreshes = 0
    func refresh() async throws -> LibraryChange? { refreshes += 1; shown = false; return nil }
    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] {
        [TimeBucket(timeBucket: "2026-02-01", count: shown ? 2 : 1)]
    }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] {
        [Asset(id: "mine", ownerId: "alice")] + (shown ? [Asset(id: "bob", ownerId: "bob")] : [])
    }
    func search(_ body: SearchQuery) async throws -> SearchResponse { response() }
    func metadataSearch(_ body: MetadataQuery) async throws -> SearchResponse { response() }
    private func response() -> SearchResponse {
        let items = [Asset(id: "mine", ownerId: "alice")] + (shown ? [Asset(id: "bob", ownerId: "bob")] : [])
        return SearchResponse(assets: .init(items: items, count: items.count, nextCursor: nil, nextPage: nil), verification: nil)
    }
}

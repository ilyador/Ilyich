import Foundation
import XCTest
@testable import Ilyich

@MainActor final class LibraryStoreTests: XCTestCase {
    func testPartialPageStopsAndRetriesItsOwnCursorWithoutLosingEarlierMatches() async throws {
        let api = LibraryAPIFixture([
            .page(["first"], next: "second"),
            .page([], next: "third", status: .partial),
            .page(["second"], next: "third"),
        ])
        let store = LibraryStore(api: api)
        store.search("me wearing a red hat in Amsterdam")
        try await settle(store, calls: 1, api: api)
        store.loadMore()
        try await settle(store, calls: 2, api: api)
        XCTAssertEqual(store.results.map(\.id), ["first"])
        XCTAssertTrue(store.verification?.canRetry == true)
        XCTAssertFalse(store.hasMore, "Resolve the unchecked batch before advancing beyond it.")
        store.retrySearch()
        try await settle(store, calls: 3, api: api)
        let calls = await api.cursors
        XCTAssertEqual(calls, [nil, "second", "second"])
        XCTAssertEqual(store.results.map(\.id), ["first", "second"])
        XCTAssertTrue(store.hasMore)
        store.stop()
    }

    func testEmptyVerifiedPageFollowsCursorButUnavailablePageDoesNot() async throws {
        let api = LibraryAPIFixture([
            .page([], next: "next"),
            .page([], next: "later", status: .unavailable),
            .page(["found"]),
        ])
        let store = LibraryStore(api: api)
        store.search("Maya in Amsterdam")
        try await settle(store, calls: 2, api: api)
        XCTAssertTrue(store.verification?.canRetry == true)
        XCTAssertTrue(store.results.isEmpty)
        store.retrySearch()
        try await settle(store, calls: 3, api: api)
        let calls = await api.cursors
        XCTAssertEqual(calls, [nil, "next", "next"])
        XCTAssertEqual(store.results.map(\.id), ["found"])
        store.stop()
    }

    func testSwitchingScopeClearsSelectionAndInvalidatesPendingSearch() async throws {
        let api = LibraryAPIFixture([.page(["old-query"])], delayed: true)
        let store = LibraryStore(api: api)
        store.search("old query")
        for _ in 0..<100 where await api.cursors.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        store.selected = ["invisible-photo"]; store.isSelecting = true
        store.setTimeline(TimelineFilter(isFavorite: true), title: "Favorites")
        XCTAssertTrue(store.selected.isEmpty)
        XCTAssertFalse(store.isSelecting)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(store.isSearching)
        XCTAssertTrue(store.query.isEmpty)
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertEqual(store.sections.first?.id, "2026-01-01T00:00:00Z")
        store.stop()
        await TimelineCache.shared.removeAll(scope: api.cacheScope)
    }

    func testClearingFilterRestoresScrollPositionAndTimelineRetryStaysTimeline() async throws {
        let api = LibraryAPIFixture([])
        let store = LibraryStore(api: api)
        await store.reload()
        let position = GridPosition(section: "2026-01-01T00:00:00Z", item: 0, offset: 17)
        store.position = position
        store.setTimeline(TimelineFilter(isFavorite: true), title: "Favorites")
        store.clearFilters()
        XCTAssertEqual(store.restorePosition, position)
        store.retryCurrent()
        try await Task.sleep(for: .milliseconds(60))
        let calls = await api.cursors
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(store.sections.first?.id, position.section)
        store.stop()
        await TimelineCache.shared.removeAll(scope: api.cacheScope)
    }

    private func settle(_ store: LibraryStore, calls: Int, api: LibraryAPIFixture) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await api.cursors.count >= calls, !store.isSearching { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The library did not settle its search request.")
    }

    func testMonthSelectionResolvesEvictedAssetsAndKeepsRemoteAndLocalIdentitiesSeparate() async throws {
        let assets = (0..<650).map { Asset(id: "remote-\($0)") }
        let api = LibraryAPIFixture([], timelineAssets: assets)
        let store = LibraryStore(api: api, includesDevicePhotos: true)
        await store.reload()
        let date = try XCTUnwrap(APIDate.parse("2026-01-15T12:00:00Z"))
        store.updateDeviceTimeline(MergedTimeline(photos: [.init(id: "phone-only", date: date), .init(id: "backed-up", date: date)],
                                                  associations: ["backed-up": "remote-0"]))
        store.loaded = [:] // The summary survives eviction of its asset records.
        store.isSelecting = true
        store.selectMonth(true)
        try await settleSelection(store)
        XCTAssertEqual(store.selected.count, 651)
        XCTAssertEqual(Set(store.selectedAssets.map(\.id)), Set(assets.map(\.id)))
        XCTAssertEqual(store.selectedLocalPhotos.map(\.id), ["phone-only"])
        XCTAssertEqual(Set(store.selectedDevicePhotos.map(\.id)), ["phone-only", "backed-up"])
        XCTAssertFalse(store.selected.contains("local:backed-up"))
        store.selectMonth(false)
        try await settleSelection(store)
        XCTAssertTrue(store.selected.isEmpty)
        XCTAssertTrue(store.selectedLocalPhotos.isEmpty)
        store.stop(); await TimelineCache.shared.removeAll(scope: api.cacheScope)
    }

    func testPendingGroupSelectionCannotReappearAfterLeavingSelection() async throws {
        let api = LibraryAPIFixture([], delayedTimeline: true)
        let store = LibraryStore(api: api)
        await store.reload()
        store.isSelecting = true; store.selectMonth(true)
        await Task.yield()
        store.isSelecting = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.selected.isEmpty)
        XCTAssertFalse(store.isSelectingGroup)
        store.stop(); await TimelineCache.shared.removeAll(scope: api.cacheScope)
    }

    func testDeduplicationKeepsTheVisiblePhotoAnchoredWhenEarlierRowsDisappear() async throws {
        let api = LibraryAPIFixture([])
        let store = LibraryStore(api: api, includesDevicePhotos: true)
        await store.reload()
        let date = try XCTUnwrap(APIDate.parse("2026-01-15T12:00:00Z"))
        let photos = [LocalPhoto(id: "a", date: date), LocalPhoto(id: "b", date: date.addingTimeInterval(-60))]
        store.updateDeviceTimeline(MergedTimeline(photos: photos))
        store.loaded = ["2026-01-01T00:00:00Z": [Asset(id: "timeline-photo")]]
        store.updateDeviceTimeline(MergedTimeline(photos: photos))
        store.position = GridPosition(section: "2026-01-01T00:00:00Z", item: 1, offset: 17, assetID: "local:b")
        store.updateDeviceTimeline(MergedTimeline(photos: photos, associations: ["a": "timeline-photo"]))
        let position = try XCTUnwrap(store.restorePosition)
        XCTAssertEqual(store.restoredIndex(for: position)?.item, 0)
        XCTAssertEqual(position.offset, 17)
        store.updateDeviceTimeline(MergedTimeline(photos: photos, associations: ["a": "timeline-photo", "b": "timeline-photo"]))
        XCTAssertEqual(store.restorePosition?.assetID, "timeline-photo")
        store.stop(); await TimelineCache.shared.removeAll(scope: api.cacheScope)
    }

    private static let june = "2025-06-01T00:00:00Z"
    private func datedFixture(slow: Set<String> = []) throws -> LibraryAPIFixture {
        let early = try XCTUnwrap(APIDate.parse("2025-06-02T12:00:00Z"))
        let late = try XCTUnwrap(APIDate.parse("2025-06-20T12:00:00Z"))
        return LibraryAPIFixture([], bucketAssets: [
            "2026-03-01T00:00:00Z": [Asset(id: "march")],
            "2026-02-01T00:00:00Z": [Asset(id: "february")],
            Self.june: [Asset(id: "early", fileCreatedAt: early, localDateTime: early), Asset(id: "late", fileCreatedAt: late, localDateTime: late)],
        ], slowBuckets: slow)
    }

    private func until(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }

    func testRepeatedRailJumpsToTheSameMonthAreDistinctRequests() async throws {
        let api = try datedFixture()
        let store = LibraryStore(api: api)
        await store.reload()
        store.scrollToBucket(1)
        let first = try XCTUnwrap(store.scrollRequest)
        store.scrollToBucket(1)
        let second = try XCTUnwrap(store.scrollRequest)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.position, second.position)
        XCTAssertEqual(first.position.section, "2026-02-01T00:00:00Z")
        XCTAssertEqual(first.position.item, 0)
        store.stop(); await TimelineCache.shared.removeAll(scope: api.cacheScope)
    }

    func testShowInTimelineLoadsTheUnloadedMonthAndFindsTheAsset() async throws {
        let api = try datedFixture()
        let store = LibraryStore(api: api)
        store.setTimeline(TimelineFilter(isFavorite: true), title: "Favorites")
        store.selected = ["other"]; store.isSelecting = true
        let date = try XCTUnwrap(APIDate.parse("2025-06-20T12:00:00Z"))
        store.showInTimeline(Asset(id: "late", fileCreatedAt: date, localDateTime: date))
        XCTAssertNil(store.filterTitle)
        XCTAssertTrue(store.selected.isEmpty)
        XCTAssertFalse(store.isSelecting)
        try await until("The date navigation never published a scroll request.") { store.scrollRequest != nil }
        let request = try XCTUnwrap(store.scrollRequest)
        XCTAssertEqual(request.position.section, Self.june)
        XCTAssertEqual(request.position.assetID, "late")
        XCTAssertEqual(store.loaded[Self.june]?.map(\.id), ["early", "late"])
        XCTAssertEqual(store.restoredIndex(for: request.position)?.section, 2)
        XCTAssertEqual(store.restoredIndex(for: request.position)?.item, 1)
        XCTAssertNil(store.error)

        // A missing asset falls back to the nearest capture date in the same month.
        let near = try XCTUnwrap(APIDate.parse("2025-06-19T00:00:00Z"))
        store.showInTimeline(Asset(id: "elsewhere", fileCreatedAt: near))
        try await until("The fallback navigation never published.") { store.scrollRequest != nil }
        XCTAssertEqual(store.scrollRequest?.position.assetID, "late")
        XCTAssertNotEqual(store.scrollRequest?.id, request.id)
        store.stop(); await TimelineCache.shared.removeAll(scope: api.cacheScope)
    }

    func testScopeChangeOrStopPreventsAnOldDateNavigationFromPublishing() async throws {
        let api = try datedFixture(slow: [Self.june])
        let store = LibraryStore(api: api)
        let date = try XCTUnwrap(APIDate.parse("2025-06-20T12:00:00Z"))
        let asset = Asset(id: "late", fileCreatedAt: date, localDateTime: date)
        store.showInTimeline(asset)
        try await until("The target month was never requested.") { await api.bucketCalls.contains(Self.june) }
        store.setTimeline(TimelineFilter(isFavorite: true), title: "Favorites")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.scrollRequest)

        store.showInTimeline(asset)
        try await until("The target month was never requested again.") { await api.bucketCalls.filter { $0 == Self.june }.count >= 2 }
        store.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.scrollRequest)
        await TimelineCache.shared.removeAll(scope: api.cacheScope)
    }

    func testRailJumpSupersedesPendingDateNavigation() async throws {
        let api = try datedFixture(slow: [Self.june])
        let store = LibraryStore(api: api)
        let date = try XCTUnwrap(APIDate.parse("2025-06-20T12:00:00Z"))
        store.showInTimeline(Asset(id: "late", localDateTime: date))
        try await until("The target month was never requested.") { await api.bucketCalls.contains(Self.june) }
        store.scrollToBucket(0)
        let request = try XCTUnwrap(store.scrollRequest)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.scrollRequest, request)
        XCTAssertEqual(request.position.section, "2026-03-01T00:00:00Z")
        store.stop(); await TimelineCache.shared.removeAll(scope: api.cacheScope)
    }

    private func settleSelection(_ store: LibraryStore) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while store.isSelectingGroup && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isSelectingGroup)
        XCTAssertNil(store.error)
    }
}

private actor LibraryAPIFixture: LibraryAPI {
    nonisolated let cacheScope = "test-library-" + UUID().uuidString
    var cursors: [String?] = []
    private var pages: [SearchResponse]
    private let delayed: Bool
    private let timelineAssets: [Asset]
    private let delayedTimeline: Bool
    private let bucketAssets: [String: [Asset]]
    private let slowBuckets: Set<String>
    var bucketCalls: [String] = []
    init(_ pages: [SearchResponse], delayed: Bool = false, timelineAssets: [Asset] = [Asset(id: "timeline-photo")], delayedTimeline: Bool = false,
         bucketAssets: [String: [Asset]] = [:], slowBuckets: Set<String> = []) {
        self.pages = pages; self.delayed = delayed; self.timelineAssets = timelineAssets; self.delayedTimeline = delayedTimeline
        self.bucketAssets = bucketAssets; self.slowBuckets = slowBuckets
    }
    func timeBuckets(filter: TimelineFilter) async throws -> [TimeBucket] {
        if !bucketAssets.isEmpty { return bucketAssets.keys.sorted(by: >).map { .init(timeBucket: $0, count: bucketAssets[$0]?.count ?? 0) } }
        return [.init(timeBucket: "2026-01-01T00:00:00Z", count: timelineAssets.count)]
    }
    func timeBucket(_ bucket: String, filter: TimelineFilter) async throws -> [Asset] {
        bucketCalls.append(bucket)
        if delayedTimeline || slowBuckets.contains(bucket) { try await Task.sleep(for: .seconds(3)) }
        if let assets = bucketAssets[bucket] { return assets }
        return timelineAssets
    }
    func search(_ query: SearchQuery) async throws -> SearchResponse {
        cursors.append(query.cursor)
        if delayed { try await Task.sleep(for: .seconds(3)) }
        guard !pages.isEmpty else { throw APIError.http(500) }
        return pages.removeFirst()
    }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { throw APIError.http(500) }
}

private extension SearchResponse {
    static func page(_ ids: [String], next: String? = nil, status: Verification.Status = .complete) -> Self {
        .init(assets: .init(items: ids.map { Asset(id: $0) }, count: ids.count, nextCursor: next, nextPage: nil),
              verification: .init(status: status, checked: 10, rejected: 10 - ids.count))
    }
}

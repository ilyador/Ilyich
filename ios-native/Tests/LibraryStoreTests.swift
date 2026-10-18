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
}

private actor LibraryAPIFixture: LibraryAPI {
    nonisolated let cacheScope = "test-library-" + UUID().uuidString
    var cursors: [String?] = []
    private var pages: [SearchResponse]
    private let delayed: Bool
    init(_ pages: [SearchResponse], delayed: Bool = false) { self.pages = pages; self.delayed = delayed }
    func timeBuckets(filter: TimelineFilter) async throws -> [TimeBucket] {
        [.init(timeBucket: "2026-01-01T00:00:00Z", count: 1)]
    }
    func timeBucket(_ bucket: String, filter: TimelineFilter) async throws -> [Asset] { [Asset(id: "timeline-photo")] }
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

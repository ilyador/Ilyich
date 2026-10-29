import Foundation
import XCTest
@testable import Ilyich

@MainActor final class SearchFeedTests: XCTestCase {
    // MARK: - Continuation and verification, ported from the feed store's tests

    func testPartialPageStopsAndRetriesItsOwnCursorWithoutLosingEarlierMatches() async throws {
        let source = ScriptedSearch([
            .page(["first"], next: "second"),
            .page([], next: "third", status: .partial),
            .page(["second"], next: "third"),
        ])
        let feed = SearchFeed(.init(try Self.smart()), source: source)
        _ = try await feed.first()
        let stopped = try await feed.more()
        XCTAssertEqual(stopped.results.map(\.id), ["first"])
        XCTAssertTrue(stopped.verification?.canRetry == true)
        XCTAssertEqual(stopped.retryPoint, .init(cursor: "second", prefix: [Asset(id: "first")]))
        XCTAssertFalse(stopped.hasMore, "Resolve the unchecked batch before advancing beyond it.")
        let resumed = try await feed.retry()
        let cursors = await source.cursors
        XCTAssertEqual(cursors, [nil, "second", "second"])
        XCTAssertEqual(resumed.results.map(\.id), ["first", "second"])
        XCTAssertTrue(resumed.hasMore)
        XCTAssertNil(resumed.retryPoint)
    }

    func testEmptyVerifiedPageFollowsCursorButUnavailablePageDoesNot() async throws {
        let source = ScriptedSearch([
            .page([], next: "next"),
            .page([], next: "later", status: .unavailable),
            .page(["found"]),
        ])
        let feed = SearchFeed(.init(try Self.smart()), source: source)
        let first = try await feed.first()
        XCTAssertTrue(first.verification?.canRetry == true)
        XCTAssertTrue(first.results.isEmpty)
        let retried = try await feed.retry()
        let cursors = await source.cursors
        XCTAssertEqual(cursors, [nil, "next", "next"])
        XCTAssertEqual(retried.results.map(\.id), ["found"])
        XCTAssertFalse(retried.hasMore)
    }

    // MARK: - Pages

    func testSmartPagesOfTenMetadataOfAHundredDevelopedOfFiveHundred() async throws {
        let source = ScriptedSearch([.page(["a"])], metadata: [.page(["b"]), .page(["c"])])
        _ = try await SearchFeed(.init(try Self.smart()), source: source).first()
        _ = try await SearchFeed(.init(try Self.metadata()), source: source).first()
        _ = try await SearchFeed(.init(try Self.metadata(developed: true)), source: source).first()
        let smartSizes = await source.smartSizes, metadataSizes = await source.metadataSizes
        XCTAssertEqual(smartSizes, [10])
        XCTAssertEqual(metadataSizes, [100, 500])
    }

    func testEmptyVerifiedPagesAreFollowedThreeTimesOrFortyWhenDevelopedOnly() async throws {
        let empty = (0..<50).map { SearchResponse.page([], next: "page-\($0 + 1)") }
        let source = ScriptedSearch(empty, metadata: empty)
        let smart = try await SearchFeed(.init(try Self.smart()), source: source).first()
        XCTAssertTrue(smart.hasMore, "After three empty pages the search stops with more to check.")
        let developed = try await SearchFeed(.init(try Self.metadata(developed: true)), source: source).first()
        XCTAssertTrue(developed.hasMore)
        let smartCalls = await source.cursors.count, metadataCalls = await source.metadataSizes.count
        XCTAssertEqual(smartCalls, 3)
        XCTAssertEqual(metadataCalls, 40, "The developed shelf looks through 20,000 photos.")
    }

    func testAContinuationThatIsOnlyAPageNumberIsRefusedAndRetriedFromItsCursor() async throws {
        let legacy = SearchResponse(assets: .init(items: [Asset(id: "a")], count: 1, nextCursor: nil, nextPage: "2"), verification: nil)
        let source = ScriptedSearch([.page(["first"], next: "c1"), legacy, .page(["a"])])
        let feed = SearchFeed(.init(try Self.smart()), source: source)
        _ = try await feed.first()
        do { _ = try await feed.more(); XCTFail("A page number is not a cursor.") } catch {}
        let state = await feed.state
        XCTAssertEqual(state.results.map(\.id), ["first"], "A refused page adds nothing.")
        XCTAssertEqual(state.retryPoint, .init(cursor: "c1", prefix: [Asset(id: "first")]))
        _ = try await feed.retry()
        let cursors = await source.cursors
        XCTAssertEqual(cursors, [nil, "c1", "c1"])
    }

    func testARepeatedCursorEndsTheResults() async throws {
        let source = ScriptedSearch([.page([], next: "same"), .page([], next: "same")])
        let state = try await SearchFeed(.init(try Self.smart()), source: source).first()
        XCTAssertFalse(state.hasMore)
        XCTAssertNil(state.cursor)
        let cursors = await source.cursors
        XCTAssertEqual(cursors, [nil, "same"])
    }

    func testPagesThatRepeatAPhotoShowItOnce() async throws {
        let source = ScriptedSearch([.page(["a", "b"], next: "c1"), .page(["b", "c", "c"])])
        let feed = SearchFeed(.init(try Self.smart()), source: source)
        _ = try await feed.first()
        let state = try await feed.more()
        XCTAssertEqual(state.results.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(state.pagesLoaded, 2)
        XCTAssertNil(state.totalCount, "Immich's search gives no total.")
    }

    func testRefreshReplaysTheLoadedPagesAndSaysWhetherRowsChanged() async throws {
        let source = ScriptedSearch([
            .page(["a"], next: "c1"), .page(["b"], next: "c2"),
            .page(["a"], next: "c1"), .page(["b"], next: "c2"),
            .page(["a"], next: "c1"), .page(["x"], next: "c2"),
        ])
        let feed = SearchFeed(.init(try Self.smart()), source: source)
        _ = try await feed.first(); _ = try await feed.more()
        let same = try await feed.refresh()
        XCTAssertFalse(same.rowsChanged)
        XCTAssertEqual(same.pagesLoaded, 2)
        let changed = try await feed.refresh()
        XCTAssertTrue(changed.rowsChanged)
        XCTAssertEqual(changed.results.map(\.id), ["a", "x"])
        let cursors = await source.cursors
        XCTAssertEqual(cursors, [nil, "c1", nil, "c1", nil, "c1"])
    }

    func testAPrunedPhotoStaysOutOfLaterPages() async throws {
        let source = ScriptedSearch([.page(["a", "b"], next: "c1"), .page(["b", "c"])])
        let feed = SearchFeed(.init(try Self.smart()), source: source)
        _ = try await feed.first()
        let pruned = await feed.prune(["b"])
        XCTAssertEqual(pruned.results.map(\.id), ["a"])
        let state = try await feed.more()
        XCTAssertEqual(state.results.map(\.id), ["a", "c"])
    }

    func testARefreshGivenTheExclusionsBringsBackAPhotoNoLongerRemoved() async throws {
        let source = ScriptedSearch([.page(["a", "b"]), .page(["a", "b"]), .page(["a", "b"])])
        let feed = SearchFeed(.init(try Self.smart()), source: source)
        _ = try await feed.first()
        await feed.prune(["b"])
        let stillOut = try await feed.refresh()
        XCTAssertEqual(stillOut.results.map(\.id), ["a"], "Without exclusions the feed keeps its own.")
        let back = try await feed.refresh(excluding: [])
        XCTAssertEqual(back.results.map(\.id), ["a", "b"], "A photo no longer excluded comes back.")
    }

    // MARK: - LibraryFeedStore applies the feed's State

    func testRefreshKeepsRowsWhenIDsUnchanged() async throws {
        let api = SearchStoreFixture([
            .page(["a"], next: "c1"), .page(["b"], next: "c2"),
            .page(["a"], next: "c1"), .page(["b"], next: "c2"),
        ])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        store.setMetadataFilter(SearchFilter(type: StringFilter(eq: "VIDEO")), title: "Videos")
        try await until("The first page did not show.") { store.results.map(\.id) == ["a"] && !store.isSearching }
        store.loadMore()
        try await until("The second page did not show.") { store.results.map(\.id) == ["a", "b"] && !store.isSearching }
        let resetID = store.resetID
        await store.reload(preservingPosition: true)
        let calls = await api.metadataCursors
        XCTAssertEqual(calls, [nil, "c1", nil, "c1"], "A refresh reads the pages shown again.")
        XCTAssertEqual(store.results.map(\.id), ["a", "b"])
        XCTAssertEqual(store.resetID, resetID, "Unchanged rows keep the grid where it is.")
        XCTAssertTrue(store.hasMore)
    }

    func testLibraryChangePrunesResultsWhileSearching() async throws {
        let api = SearchStoreFixture(smart: [
            .page(["a", "b", "c"], next: "c1"), .page(["b", "d"]),
        ])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        store.search("beach")
        try await until("The results did not show.") { store.results.count == 3 && !store.isSearching }
        let resetID = store.resetID, revision = store.revision
        var change = LibraryChange(account: LegacyGoldens.account,
                                   authorization: AuthorizationEpoch(account: LegacyGoldens.account, value: 1),
                                   indexRevision: 2, origin: .sync)
        change.removed = ["b"]
        store.prune(change)
        XCTAssertEqual(store.results.map(\.id), ["a", "c"], "The deleted photo leaves the results at once.")
        XCTAssertEqual(store.resetID, resetID, "In place: the grid keeps its position.")
        XCTAssertGreaterThan(store.revision, revision)
        XCTAssertEqual(store.query, "beach", "The search stays.")
        store.loadMore()
        try await until("The next page did not show.") { store.results.count == 3 && !store.isSearching }
        XCTAssertEqual(store.results.map(\.id), ["a", "c", "d"], "A later page can't bring the deleted photo back.")
    }

    func testARestoredPhotoComesBackWithTheNextRefresh() async throws {
        let api = SearchStoreFixture([.page(["a", "b"]), .page(["a"]), .page(["a", "b"])])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        store.setMetadataFilter(SearchFilter(type: StringFilter(eq: "VIDEO")), title: "Videos")
        try await until("The results did not show.") { store.results.map(\.id) == ["a", "b"] && !store.isSearching }
        store.removeLocally(["b"])
        XCTAssertEqual(store.results.map(\.id), ["a"])
        await store.reload(preservingPosition: true)
        XCTAssertEqual(store.results.map(\.id), ["a"])
        var change = LibraryChange(account: LegacyGoldens.account,
                                   authorization: AuthorizationEpoch(account: LegacyGoldens.account, value: 1),
                                   indexRevision: 3, origin: .sync)
        change.upserted = ["b": .init()]
        store.prune(change)
        await store.reload(preservingPosition: true)
        XCTAssertEqual(store.results.map(\.id), ["a", "b"], "A photo restored from Trash shows again.")
    }

    /// G1: a text search is not read again for a sync's change, but a photo it shows that the
    /// change names takes the offline library's record. Put in Trash elsewhere, which reaches the
    /// phone as a change to the photo, not a removal, it leaves the results in place; favorited
    /// elsewhere, it shows that. Only the photos shown are looked up, and nothing is searched again.
    func testAPhotoTrashedElsewhereLeavesATextSearch() async throws {
        let api = SearchStoreFixture(smart: [.page(["a", "b", "c"])])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        store.search("beach")
        try await until("The results did not show.") { store.results.count == 3 && !store.isSearching }
        var trashed = Asset(id: "b")
        trashed.isTrashed = true
        var favorited = Asset(id: "c")
        favorited.isFavorite = true
        await api.setRecords([trashed, favorited])
        let resetID = store.resetID
        var change = LibraryChange(account: LegacyGoldens.account,
                                   authorization: AuthorizationEpoch(account: LegacyGoldens.account, value: 1),
                                   indexRevision: 2, origin: .sync)
        change.upserted = ["b": .init(), "c": .init(), "elsewhere": .init()]
        await store.apply(change)
        XCTAssertEqual(store.results.map(\.id), ["a", "c"], "The photo put in Trash leaves the results.")
        XCTAssertEqual(store.results.last?.isFavorite, true, "The favorited photo shows its record.")
        XCTAssertEqual(store.resetID, resetID, "In place: the grid keeps its position.")
        XCTAssertEqual(store.query, "beach", "The search stays.")
        let asked = await api.recordsAsked
        XCTAssertEqual(asked, [["b", "c"]], "Only the photos shown are looked up.")
        let searches = await api.smartCalls
        XCTAssertEqual(searches, 1, "Nothing is searched again.")
    }

    // MARK: - Helpers

    private func until(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }

    private static func smart() throws -> ServerSearchRequest {
        try ServerSearchRequest(LibraryFeedStore.librarySearch.refined(text: "red hat", mode: .context), userID: nil)
    }

    private static func metadata(developed: Bool = false) throws -> ServerSearchRequest {
        var query = LibraryQuery(SearchFilter(type: StringFilter(eq: "PHOTO")))
        if developed { query.predicates.developed = true }
        return try ServerSearchRequest(query, userID: nil)
    }
}

/// Search pages in the order given; each call takes the next page.
private actor ScriptedSearch: SearchSource {
    private var smartPages: [SearchResponse]
    private var metadataPages: [SearchResponse]
    var cursors: [String?] = []
    var smartSizes: [Int] = []
    var metadataSizes: [Int] = []
    init(_ smart: [SearchResponse], metadata: [SearchResponse] = []) { smartPages = smart; metadataPages = metadata }
    func smart(_ request: ServerSearchRequest, cursor: String?) async throws -> SearchResponse {
        cursors.append(cursor); smartSizes.append(request.smartBody(cursor: cursor).size)
        guard !smartPages.isEmpty else { throw ServerFailure.http(500, nil) }
        return request.page(smartPages.removeFirst())
    }
    func metadata(_ request: ServerSearchRequest, cursor: String?, size: Int) async throws -> SearchResponse {
        metadataSizes.append(size)
        guard !metadataPages.isEmpty else { throw ServerFailure.http(500, nil) }
        return request.page(metadataPages.removeFirst())
    }
}

/// A one-month library whose searches answer with the pages given.
private actor SearchStoreFixture: FakeFeedSource {
    nonisolated let cacheScope = "test-search-feed-" + UUID().uuidString
    private var metadataPages: [SearchResponse]
    private var smartPages: [SearchResponse]
    var metadataCursors: [String?] = []
    private(set) var smartCalls = 0
    /// The offline library's records, and the photos each lookup asked for.
    private var stored: [String: Asset] = [:]
    private(set) var recordsAsked: [Set<String>] = []
    init(_ metadata: [SearchResponse] = [], smart: [SearchResponse] = []) { metadataPages = metadata; smartPages = smart }
    func setRecords(_ records: [Asset]) { for record in records { stored[record.id] = record } }
    func records(_ ids: Set<String>) async -> [Asset] {
        recordsAsked.append(ids)
        return ids.compactMap { stored[$0] }
    }
    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] { [.init(timeBucket: "2026-01-01T00:00:00Z", count: 1)] }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] { [Asset(id: "timeline-photo")] }
    func search(_ body: SearchQuery) async throws -> SearchResponse {
        smartCalls += 1
        guard !smartPages.isEmpty else { throw ServerFailure.http(500, nil) }
        return smartPages.removeFirst()
    }
    func metadataSearch(_ body: MetadataQuery) async throws -> SearchResponse {
        metadataCursors.append(body.cursor)
        guard !metadataPages.isEmpty else { throw ServerFailure.http(500, nil) }
        return metadataPages.removeFirst()
    }
}

private extension SearchResponse {
    static func page(_ ids: [String], next: String? = nil, status: Verification.Status = .complete) -> Self {
        .init(assets: .init(items: ids.map { Asset(id: $0) }, count: ids.count, nextCursor: next, nextPage: nil),
              verification: .init(status: status, checked: 10, rejected: 10 - ids.count))
    }
}

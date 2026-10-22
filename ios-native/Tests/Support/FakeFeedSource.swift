import Foundation
@testable import Ilyich

/// A fake library for feed tests: months by query, searches by the request bodies the store
/// sends. By default it plans as an account without a readable offline library does, so every
/// shelf comes from the server timeline and a place from search; a fake overrides `plan` to lay
/// places out by month. Pages keep only the photos that belong to the request, as the repository's do.
protocol FakeFeedSource: LibraryFeedSource {
    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket]
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset]
    func search(_ body: SearchQuery) async throws -> SearchResponse
    func metadataSearch(_ body: MetadataQuery) async throws -> SearchResponse
    func placeCounts(_ query: LibraryQuery) async throws -> [MonthPlaceCount]
}

extension FakeFeedSource {
    var userID: String? { nil }
    func refresh() async throws -> LibraryChange? { nil }
    func placeCounts(_ query: LibraryQuery) async throws -> [MonthPlaceCount] { [] }

    func plan(_ query: LibraryQuery) async throws -> QueryPlan {
        try QueryPlanner.plan(query, context: PlannerContext(indexReadable: false))
    }
    func summary(_ query: LibraryQuery, plan: QueryPlan) async throws -> [TimeBucket] { try await monthList(query) }
    func month(_ bucket: String, of query: LibraryQuery, plan: QueryPlan) async throws -> [Asset] { try await month(bucket, of: query) }
    /// Counted whatever the plan, so place tests need no index.
    func monthPlaces(_ query: LibraryQuery, plan: QueryPlan) async throws -> [MonthPlaceCount] { try await placeCounts(query) }
    func smart(_ request: ServerSearchRequest, cursor: String?) async throws -> SearchResponse {
        request.page(try await search(request.smartBody(cursor: cursor)))
    }
    func metadata(_ request: ServerSearchRequest, cursor: String?, size: Int) async throws -> SearchResponse {
        request.page(try await metadataSearch(request.metadataBody(cursor: cursor, size: size)))
    }
}

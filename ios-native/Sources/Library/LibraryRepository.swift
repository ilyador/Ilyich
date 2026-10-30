import Foundation
import IlyichPlatform

/// One account's library reads: the planner picks the index, the server timeline or server search
/// for a query, and the translators speak to each. A feed passes the plan it pinned to every read,
/// so its months all come from one backend. Search pages keep only the photos that belong to the
/// request.
final class LibraryRepository: LibraryFeedSource {
    let client: APIClient
    let index: LibraryIndex?
    /// The account's sync, which runs refreshes as its own passes. Nil where nothing syncs.
    let sync: SyncEngine?
    /// Whether the library includes the partners shown in the timeline (QUERY-1). Off: adopting it
    /// changes what the library shows and its cache key, which waits for the owner's answer.
    let includesPartners: Bool

    init(client: APIClient, index: LibraryIndex?, sync: SyncEngine?, includesPartners: Bool = false) {
        self.client = client; self.index = index; self.sync = sync; self.includesPartners = includesPartners
    }

    var cacheScope: String { client.cacheScope }
    var userID: String? { client.userID }

    private func indexReadable() async throws -> Bool {
        guard let index else { return false }
        return try await index.isReadable()
    }

    // MARK: TimelineSource

    func plan(_ query: LibraryQuery) async throws -> QueryPlan {
        try QueryPlanner.plan(query, context: PlannerContext(indexReadable: try await indexReadable()))
    }

    func summary(_ query: LibraryQuery, plan: QueryPlan) async throws -> [TimeBucket] {
        switch plan.backend {
        case .index: return try await requireIndex(query).timeBuckets(query, includesPartners: includesPartners)
        case .serverTimeline: return try await client.timeBuckets(try timelineRequest(query))
        case .serverSearch: throw Self.noMonths(query)
        }
    }

    func month(_ bucket: String, of query: LibraryQuery, plan: QueryPlan) async throws -> [Asset] {
        switch plan.backend {
        case .index:
            FeedMonthProbe.note(.index)
            return try await requireIndex(query).timeBucket(bucket, of: query, includesPartners: includesPartners)
        case .serverTimeline:
            FeedMonthProbe.note(.serverTimeline)
            return try await client.timeBucket(bucket, of: try timelineRequest(query))
        case .serverSearch: throw Self.noMonths(query)
        }
    }

    func monthPlaces(_ query: LibraryQuery, plan: QueryPlan) async throws -> [MonthPlaceCount] {
        guard case .index = plan.backend else { return [] }
        return try await requireIndex(query).monthPlaces(query, includesPartners: includesPartners)
    }

    private func requireIndex(_ query: LibraryQuery) throws -> LibraryIndex {
        guard let index else { throw Self.noMonths(query) }
        return index
    }
    private func timelineRequest(_ query: LibraryQuery) throws(Unsupported) -> ServerTimelineRequest {
        try ServerTimelineRequest(query, userID: client.userID, includesPartners: includesPartners)
    }
    private static func noMonths(_ query: LibraryQuery) -> Unsupported {
        if query.predicates.place != nil { return .placeNeedsIndex }
        return .predicate("months")
    }

    // MARK: SearchSource

    /// Only the owner's fork pages and checks smart search; a stock server answers one page.
    /// Features that can't be read leave the fork's request, which a stock server reads as one.
    func smart(_ request: ServerSearchRequest, cursor: String?) async throws -> SearchResponse {
        let pages = (try? await client.knownServerFeatures())?.isFork ?? true
        return request.page(try await client.search(request.smartBody(cursor: cursor, pages: pages)))
    }

    func metadata(_ request: ServerSearchRequest, cursor: String?, size: Int) async throws -> SearchResponse {
        request.page(try await client.metadataSearch(request.metadataBody(cursor: cursor, size: size)))
    }

    /// A sync pass, published like every other, and what it changed. Without a sync the server is
    /// always up to date.
    func refresh() async throws -> LibraryChange? { try await sync?.refresh() }

    /// The index's records of `ids`, at most `recordLimit` of them, once it is readable.
    func records(_ ids: Set<String>) async -> [Asset] {
        guard let index, (try? await index.isReadable()) == true else { return [] }
        var records: [Asset] = []
        for id in ids.prefix(Self.recordLimit) {
            if let record = try? await index.asset(id: id) { records.append(record) }
        }
        return records
    }

    /// A change naming more of a search's photos than this leaves the rest to the next search.
    static let recordLimit = 200
}

/// When a server read may be answered from the offline index instead: only after a definite
/// transport failure (no answer at all, never an HTTP status or a cancellation) and only from an
/// index that is complete, or, for what the derived tables serve, readable. Each read keeps the
/// requirement it had.
enum OfflineFallback {
    enum Requirement: Sendable { case complete, readable }

    static func allows(_ error: any Error) -> Bool { TransportFailure.isDefinite(error) && !Task.isCancelled }

    /// The index to read from after `error`, or nil when the failure must stand.
    static func index(after error: any Error, _ index: LibraryIndex?, requires requirement: Requirement) async throws -> LibraryIndex? {
        guard allows(error), let index else { return nil }
        switch requirement {
        case .complete: return try await index.isComplete() ? index : nil
        case .readable: return try await index.isReadable() ? index : nil
        }
    }
}

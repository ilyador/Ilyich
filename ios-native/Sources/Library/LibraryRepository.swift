import Foundation
import IlyichPlatform

/// One account's library reads: the planner picks the index, the server timeline or server search
/// for a query, and the translators speak to each. Search pages keep only the photos that belong
/// to the request. NativeLibraryAPI's TimelineFilter entry points route through here until Q5
/// moves the feeds onto LibraryQuery.
final class LibraryRepository: TimelineSource, SearchSource, Sendable {
    let client: APIClient
    let index: LibraryIndex?
    /// The account's sync, which runs refreshes as its own passes. Nil where nothing syncs.
    let sync: SyncEngine?
    /// Whether the library includes the partners shown in the timeline. Off until Q5 decides it.
    let includesPartners: Bool

    init(client: APIClient, index: LibraryIndex?, sync: SyncEngine?, includesPartners: Bool = false) {
        self.client = client; self.index = index; self.sync = sync; self.includesPartners = includesPartners
    }

    private func indexReadable() async throws -> Bool {
        guard let index else { return false }
        return try await index.isReadable()
    }

    // MARK: TimelineSource

    func plan(_ query: LibraryQuery) async throws -> QueryPlan {
        try QueryPlanner.plan(query, context: PlannerContext(indexReadable: try await indexReadable()))
    }

    func summary(_ query: LibraryQuery) async throws -> [TimeBucket] {
        switch try await plan(query).backend {
        case .index: return try await requireIndex().timeBuckets(filter: try indexFilter(query))
        case .serverTimeline: return try await client.timeBuckets(filter: try timelineRequest(query).filter)
        case .serverSearch: throw Self.noMonths(query)
        }
    }

    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] {
        switch try await plan(query).backend {
        case .index:
            FeedMonthProbe.note(.index)
            return try await requireIndex().timeBucket(bucket, filter: try indexFilter(query))
        case .serverTimeline:
            FeedMonthProbe.note(.serverTimeline)
            return try await client.timeBucket(bucket, filter: try timelineRequest(query).filter)
        case .serverSearch: throw Self.noMonths(query)
        }
    }

    func monthPlaces(_ query: LibraryQuery) async throws -> [MonthPlaceCount] {
        guard case .index = try await plan(query).backend else { return [] }
        return try await requireIndex().monthPlaces(filter: try indexFilter(query))
    }

    private func requireIndex() throws -> LibraryIndex {
        guard let index else { throw Unsupported.placeNeedsIndex }
        return index
    }
    private func indexFilter(_ query: LibraryQuery) throws(Unsupported) -> TimelineFilter {
        try TimelineFilter(query, userID: client.userID, includesPartners: includesPartners)
    }
    private func timelineRequest(_ query: LibraryQuery) throws(Unsupported) -> ServerTimelineRequest {
        try ServerTimelineRequest(query, userID: client.userID, includesPartners: includesPartners)
    }
    private static func noMonths(_ query: LibraryQuery) -> Unsupported {
        if query.predicates.place != nil { return .placeNeedsIndex }
        return .predicate("months")
    }

    // MARK: SearchSource

    func smart(_ request: ServerSearchRequest, cursor: String?) async throws -> SearchResponse {
        request.page(try await client.search(request.smartBody(cursor: cursor)))
    }

    func metadata(_ request: ServerSearchRequest, cursor: String?, size: Int) async throws -> SearchResponse {
        request.page(try await client.metadataSearch(request.metadataBody(cursor: cursor, size: size)))
    }

    // MARK: Today's feeds (TimelineFilter), until Q5

    /// The complete, queryable index serves the timeline; first sync never delays the server
    /// timeline. The Locked Folder always comes from the server, and a place only from the index.
    func timeBuckets(filter: TimelineFilter) async throws -> [TimeBucket] {
        if filter.visibility != .locked, let index, try await index.isReadable() {
            return try await index.timeBuckets(filter: filter)
        }
        guard filter.place == nil else { throw LibraryAPIError.placeNeedsOfflineLibrary }
        return try await client.timeBuckets(filter: filter)
    }
    func timeBucket(_ bucket: String, filter: TimelineFilter) async throws -> [Asset] {
        if filter.visibility != .locked, let index, try await index.isReadable() {
            FeedMonthProbe.note(.index)
            return try await index.timeBucket(bucket, filter: filter)
        }
        guard filter.place == nil else { throw LibraryAPIError.placeNeedsOfflineLibrary }
        FeedMonthProbe.note(.serverTimeline)
        return try await client.timeBucket(bucket, filter: filter)
    }
    /// A place's photos are laid out by month only from the complete local index.
    func supportsPlaceTimelines() async -> Bool { (try? await indexReadable()) == true }
    func monthPlaces(filter: TimelineFilter) async throws -> [MonthPlaceCount] {
        guard filter.visibility != .locked, let index, try await index.isReadable() else { return [] }
        return try await index.monthPlaces(filter: filter)
    }
    /// A sync pass, published like every other, and what it changed.
    func refresh() async throws -> LibraryChange? { try await sync?.refresh() }
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

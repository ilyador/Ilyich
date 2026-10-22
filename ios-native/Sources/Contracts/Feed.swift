import Foundation

enum FeedSectionKey: Hashable, Sendable {
    case month(MonthKey)
    /// Search results, which have no months.
    case results
}

/// One month of a feed, ready for the grid.
struct MonthProjection: Hashable, Sendable {
    /// A local day's entries, by their position in the month.
    struct DayGroup: Hashable, Sendable {
        let day: Date
        let range: Range<Int>
    }

    let key: MonthKey
    let entries: [LibraryEntry]
    let ids: [String]
    /// Only when the grid groups by day.
    let dayGroups: [DayGroup]?
    let placeSummary: String?
}

enum MonthState: Hashable, Sendable {
    case unloaded, loading, loaded, failed
}

/// What the feed shows. The grid compares counters, not contents.
struct FeedSnapshot: Hashable, Sendable {
    /// Changes only when the feed's scope does.
    let sessionID: UUID
    /// Moves when counts or order change: the grid reloads and restores its anchor.
    let structure: UInt64
    /// Moves when only cells need reconfiguring.
    let content: UInt64
    let sections: [FeedSectionKey]
    let months: [MonthKey: MonthState]
    let results: [LibraryEntry]
    /// The server's total, when it gave one.
    let totalCount: Int?
}

/// Feeds by month: the index or the server timeline, as the plan says. A feed plans once and
/// passes its plan to every read, so one feed never mixes backends; it plans again when the
/// routing changes.
protocol TimelineSource: Sendable {
    func plan(_ query: LibraryQuery) async throws -> QueryPlan
    /// The query's months and their counts, newest first unless it asks otherwise.
    func summary(_ query: LibraryQuery, plan: QueryPlan) async throws -> [TimeBucket]
    /// One month's photos, by the time taken (or added) and then ID.
    func month(_ bucket: String, of query: LibraryQuery, plan: QueryPlan) async throws -> [Asset]
    /// Each month's places, counted by the index; none without it.
    func monthPlaces(_ query: LibraryQuery, plan: QueryPlan) async throws -> [MonthPlaceCount]
}

/// Search results by page, with only the photos that belong to the request.
protocol SearchSource: Sendable {
    func smart(_ request: ServerSearchRequest, cursor: String?) async throws -> SearchResponse
    func metadata(_ request: ServerSearchRequest, cursor: String?, size: Int) async throws -> SearchResponse
}

/// What one account's feeds read: months, search pages, and a refresh through its sync.
protocol LibraryFeedSource: TimelineSource, SearchSource {
    /// Names the account's caches on the phone.
    var cacheScope: String { get }
    /// The signed-in user, which names the account's own photos. Nil when unknown.
    var userID: String? { get }
    /// Brings the library up to date with the server, and says what that changed, when it knows.
    func refresh() async throws -> LibraryChange?
}

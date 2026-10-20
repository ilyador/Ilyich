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

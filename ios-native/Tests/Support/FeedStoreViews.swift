import Foundation
@testable import Ilyich

/// The feed store keys its months by MonthKey, as the TimelineFeed does (F6). The store's tests,
/// ported unchanged from LibraryStoreTests, name a month by its section's ID, the bucket the grid
/// shows it under; these read and set the store's months that way.
extension LibraryFeedStore {
    /// The server's photos of each month the feed has delivered, by the ID of the month's section.
    /// Setting it stands in for months the feed delivered, or let go.
    var loaded: [String: [Asset]] {
        get { bySection(rows) }
        set { rows = Dictionary(newValue.compactMap { id, assets in MonthKey(bucketID: id).map { ($0, assets) } }, uniquingKeysWith: { first, _ in first }) }
    }

    /// The months that failed to load, by the ID of the month's section.
    var bucketErrors: [String: String] { bySection(failedMonths) }

    /// The server's months the grid last reported on screen, by section ID.
    var visibleBucketIDs: Set<String> {
        let months = (visibleMonths ?? []).intersection(remoteMonths)
        return Set(buckets.filter { MonthKey(bucketID: $0.id).map(months.contains) ?? false }.map(\.id))
    }

    private func bySection<Value>(_ months: [MonthKey: Value]) -> [String: Value] {
        var ids: [MonthKey: String] = [:]
        for bucket in buckets { if let month = MonthKey(bucketID: bucket.id), ids[month] == nil { ids[month] = bucket.id } }
        var values: [String: Value] = [:]
        for (month, value) in months { values[ids[month] ?? month.bucketID] = value }
        return values
    }
}

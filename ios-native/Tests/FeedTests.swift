import Foundation
import XCTest
@testable import Ilyich

/// A feed plans once per load and reads every month with that plan (Q5).
@MainActor final class FeedTests: XCTestCase {
    /// The offline library becomes readable while the library is open from the server. Months the
    /// grid asks for afterwards still come from the server, as the feed planned; only when the feed
    /// reloads on the routing change does it plan again, and then every month comes from the index,
    /// with the grid kept on the photo it showed.
    func testAFeedNeverMixesBackends() async throws {
        let months = ["2026-04-01T00:00:00Z", "2026-03-01T00:00:00Z", "2026-02-01T00:00:00Z", "2026-01-01T00:00:00Z"]
        let source = RoutedLibrary(months: months)
        let store = LibraryStore(source: source, placesDelay: .zero)
        addTeardownBlock { @MainActor in
            store.stop()
            await TimelinePlacesCache.shared.removeAll(scope: source.cacheScope)
        }

        await store.reload()
        try await until("The first months did not load.") { store.loaded[months[0]] != nil && store.loaded[months[1]] != nil }
        XCTAssertEqual(store.feedPlan?.backend, .serverTimeline)

        await source.setIndexReadable(true)
        store.visibleSections([2, 3])
        try await until("The later months did not load.") { store.loaded[months[2]] != nil && store.loaded[months[3]] != nil }
        let before = await source.reads
        XCTAssertEqual(Set(before.map(\.backend)), [.serverTimeline], "The open feed keeps the backend it planned: \(before)")

        store.position = GridPosition(section: months[2], item: 1, offset: 0, assetID: "2026-02-01T00:00:00Z-1")
        await store.reload(preservingPosition: true)
        try await until("The reopened feed did not read its months.") { await source.reads.count > before.count + 1 }
        XCTAssertEqual(store.feedPlan?.backend, .index)
        let after = await source.reads.dropFirst(before.count)
        XCTAssertEqual(Set(after.map(\.backend)), [.index], "After the routing change every read is the index's: \(Array(after))")
        XCTAssertEqual(store.restorePosition?.assetID, "2026-02-01T00:00:00Z-1", "The reopened feed is anchored by the photo it showed.")
        XCTAssertEqual(store.sections.map(\.id), months)
    }

    private func until(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }
}

/// The same months from the server timeline or the index, planned as the planner would, recording
/// the backend each read was given.
private actor RoutedLibrary: LibraryFeedSource {
    struct Read: Equatable, CustomStringConvertible {
        let bucket: String?
        let backend: QueryPlan.Backend
        var description: String { "\(bucket ?? "summary") from \(backend)" }
    }
    nonisolated let cacheScope = "test-routed-" + UUID().uuidString
    nonisolated var userID: String? { "alice" }
    private let months: [String]
    private var indexReadable = false
    private(set) var reads: [Read] = []

    init(months: [String]) { self.months = months }
    func setIndexReadable(_ readable: Bool) { indexReadable = readable }

    func plan(_ query: LibraryQuery) async throws -> QueryPlan {
        try QueryPlanner.plan(query, context: PlannerContext(indexReadable: indexReadable))
    }
    func summary(_ query: LibraryQuery, plan: QueryPlan) async throws -> [TimeBucket] {
        reads.append(Read(bucket: nil, backend: plan.backend))
        return months.map { TimeBucket(timeBucket: $0, count: 3) }
    }
    func month(_ bucket: String, of query: LibraryQuery, plan: QueryPlan) async throws -> [Asset] {
        reads.append(Read(bucket: bucket, backend: plan.backend))
        return (0..<3).map { Asset(id: "\(bucket)-\($0)") }
    }
    func monthPlaces(_ query: LibraryQuery, plan: QueryPlan) async throws -> [MonthPlaceCount] { [] }
    func smart(_ request: ServerSearchRequest, cursor: String?) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
    func metadata(_ request: ServerSearchRequest, cursor: String?, size: Int) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
    func refresh() async throws -> LibraryChange? { nil }
}

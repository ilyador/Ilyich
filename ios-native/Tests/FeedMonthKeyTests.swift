import Foundation
import XCTest
@testable import Ilyich

/// F6: the feed store keys its months by MonthKey, and each grid section carries its month. With
/// the index's bucket IDs (YYYY-MM-01, the form a month only the phone has takes too) a month
/// that moves between the server and the phone keeps its ID, so the store, not the ID, decides
/// what of it stays.
@MainActor final class FeedMonthKeyTests: XCTestCase {
    /// The server's last photo of a month goes while the phone keeps one there: the month shows
    /// the phone's photo alone, and the server's photo is neither shown nor swiped to.
    func testAMonthTheServerLostKeepsOnlyThePhonesPhotos() async throws {
        let api = IndexMonths(["2026-03-01": [Asset(id: "m1", localDateTime: try day("2026-03-10"))],
                               "2026-02-01": [Asset(id: "f1", localDateTime: try day("2026-02-20"))]])
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        defer { store.stop() }
        await store.reload()
        try await until("The months did not load.") { store.loaded["2026-03-01"] != nil && store.loaded["2026-02-01"] != nil }
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "phone", date: try day("2026-02-05"))]))
        await store.settleProjections()
        XCTAssertEqual(store.sections.map(\.count), [1, 2])
        XCTAssertEqual((0..<2).compactMap { store.entry(section: 1, item: $0)?.id }, ["f1", "local:phone"])

        // f1 is deleted on the web: a sync's reload finds February only on the phone.
        await api.set("2026-02-01", nil)
        await store.reload(preservingPosition: true)
        await store.settleProjections()
        XCTAssertEqual(store.sections.map(\.id), ["2026-03-01", "2026-02-01"])
        XCTAssertEqual(store.sections.map(\.count), [1, 1])
        XCTAssertEqual(store.entry(section: 1, item: 0)?.id, "local:phone", "Only the phone's photo is left in February.")
        XCTAssertNil(store.loaded["2026-02-01"], "The server's photos of the month went with it.")
        XCTAssertEqual(store.availableAssets(around: Asset(id: "m1")).map(\.id), ["m1"], "The viewer can't swipe to the deleted photo.")
    }

    /// The server gains a month only the phone had: the phone's photo keeps showing while the
    /// month's rows are on their way, and the month shows both once they land.
    func testAMonthTheServerGainedKeepsThePhonesPhotosUntilItsRowsLand() async throws {
        let api = IndexMonths(["2026-03-01": [Asset(id: "m1", localDateTime: try day("2026-03-10"))]])
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        defer { store.stop() }
        await store.reload()
        try await until("March did not load.") { store.loaded["2026-03-01"] != nil }
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "phone", date: try day("2026-04-02"))]))
        await store.settleProjections()
        XCTAssertEqual(store.sections.map(\.id), ["2026-04-01", "2026-03-01"])
        XCTAssertEqual(store.entry(section: 0, item: 0)?.id, "local:phone")

        // The server gains April, whose rows are slow to come.
        let gate = await api.hold("2026-04-01")
        await api.set("2026-04-01", [Asset(id: "a1", localDateTime: try day("2026-04-20"))])
        await store.reload(preservingPosition: true)
        await store.settleProjections()
        XCTAssertEqual(store.sections.map(\.count), [2, 1])
        XCTAssertEqual(store.entry(section: 0, item: 0)?.id, "local:phone", "The phone's photo stays while April's rows are on their way.")
        gate.open()
        try await until("April's rows never landed.") { store.loaded["2026-04-01"] != nil }
        await store.settleProjections()
        XCTAssertEqual((0..<2).compactMap { store.entry(section: 0, item: $0)?.id }, ["a1", "local:phone"])
    }

    // MARK: - Support

    private func day(_ day: String) throws -> Date { try XCTUnwrap(APIDate.parse(day + "T12:00:00Z")) }

    private func until(_ message: String, within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
        throw CancellationError()
    }
}

/// Months named as the index names them, whose photos change under the store; a month can be
/// held until the test lets it through.
private actor IndexMonths: FakeFeedSource {
    nonisolated let cacheScope = "test-month-keys-" + UUID().uuidString
    private var months: [String: [Asset]]
    private var held: [String: StubServer.Gate] = [:]

    init(_ months: [String: [Asset]]) { self.months = months }

    func set(_ bucket: String, _ assets: [Asset]?) { months[bucket] = assets }
    /// Reads of the month from now on wait for the gate.
    func hold(_ bucket: String) -> StubServer.Gate {
        let gate = StubServer.Gate()
        held[bucket] = gate
        return gate
    }

    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] {
        months.keys.sorted(by: >).map { TimeBucket(timeBucket: $0, count: months[$0]?.count ?? 0) }
    }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] {
        if let gate = held[bucket] { await gate.wait() }
        return months[bucket] ?? []
    }
    func search(_ query: SearchQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
}

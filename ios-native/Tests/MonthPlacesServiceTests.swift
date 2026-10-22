import Foundation
import XCTest
@testable import Ilyich

/// Each feed's month places as MonthPlacesService serves them (REBUILD_ROADMAP.md F5): memory,
/// then the index's copy, then a fresh count; one count at a time with one recount; eight feeds
/// kept with the library and the feed shown pinned; the index bounded to twelve feeds.
@MainActor final class MonthPlacesServiceTests: XCTestCase {
    private static let kyoto = [MonthPlaceCount(bucket: "2024-10-01", city: "Kyoto", country: "Japan", count: 40)]
    private static let oslo = [MonthPlaceCount(bucket: "2024-10-01", city: "Oslo", country: "Norway", count: 12)]
    private var plan: QueryPlan { get throws { try QueryPlanner.plan(.library, context: PlannerContext(indexReadable: true)) } }

    func testPlacesServeMemoryThenTheIndexThenAFreshCount() async throws {
        let kept = MemoryPlacesStore()
        await kept.seed(Self.kyoto, forKey: LibraryQuery.library.stableKey)
        let counter = PlacesCounter([.library: Self.oslo], holding: true)
        let service = MonthPlacesService(source: counter, store: kept, delay: .zero)
        service.show(.library, plan: try plan)
        try await until("The index's copy did not show.") { service.places(of: .library)?.months["2024-10-01"]?.first?.name == "Kyoto" }
        try await until("The fresh count was not asked for.") { await counter.calls == [.library] }
        await counter.release()
        try await until("The fresh count did not replace the copy.") { service.places(of: .library)?.months["2024-10-01"]?.first?.name == "Oslo" }
        try await until("The count was not kept.") { await kept.rows[LibraryQuery.library.stableKey] == Self.oslo }
        let reads = await kept.reads
        XCTAssertEqual(reads, 1)

        // Shown again, memory serves at once and the index is not read; the feed is counted again.
        service.show(.library, plan: try plan)
        try await until("The feed was not counted again.") { await counter.calls.count == 2 }
        XCTAssertEqual(service.places(of: .library)?.months["2024-10-01"]?.first?.name, "Oslo")
        let readsAfter = await kept.reads
        XCTAssertEqual(readsAfter, 1, "Memory serves a feed it holds; the index is not read again.")
        await counter.release()
    }

    func testOneCountRunsPerFeedWithAtMostOneRecount() async throws {
        let counter = PlacesCounter([.library: Self.kyoto], holding: true)
        let service = MonthPlacesService(source: counter, delay: .zero)
        service.show(.library, plan: try plan)
        try await until("The count did not start.") { await counter.calls.count == 1 }
        // Reloads while it counts ask for one recount after it, however many there are.
        for _ in 0..<3 { service.show(.library, plan: try plan) }
        try await Task.sleep(for: .milliseconds(50))
        let during = await counter.calls.count
        XCTAssertEqual(during, 1, "The count on its way is left to finish.")
        await counter.release()
        try await until("The recount did not run.") { await counter.calls.count == 2 }
        await counter.release()
        try await until("The recount did not finish.") { await counter.answered == 2 }
        try await Task.sleep(for: .milliseconds(50))
        let after = await counter.calls.count
        XCTAssertEqual(after, 2, "One recount, not one per reload.")
        XCTAssertEqual(service.places(of: .library)?.months["2024-10-01"]?.first?.name, "Kyoto")
    }

    func testShowingAnotherFeedStopsTheCountOnItsWay() async throws {
        let maya = LibraryQuery.person("maya")
        let counter = PlacesCounter([.library: Self.kyoto, maya: Self.oslo], holding: true)
        let service = MonthPlacesService(source: counter, delay: .zero)
        service.show(.library, plan: try plan)
        try await until("The library's count did not start.") { await counter.calls == [.library] }
        service.show(maya, plan: try plan)
        try await until("The person's count did not start.") { await counter.calls == [.library, maya] }
        await counter.release()
        try await until("The person's places did not show.") { service.places(of: maya)?.months["2024-10-01"]?.first?.name == "Oslo" }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(service.places(of: .library), "Only the feed shown is counted; the library's count was stopped, not kept.")
        service.cancel()
    }

    /// A feed planned again while its places are being counted (the offline library became
    /// readable, say) is counted under the new plan; the count the old plan began is dropped when
    /// it lands, however late, so it never stands in for the new one.
    func testAReplanSupersedesTheCountOnItsWay() async throws {
        let counter = PlacesCounter(holding: true)
        await counter.queue([Self.kyoto, Self.oslo])
        let service = MonthPlacesService(source: counter, delay: .zero)
        let server = try QueryPlanner.plan(.library, context: PlannerContext(indexReadable: false))
        service.show(.library, plan: server)
        try await until("The first count did not start.") { await counter.calls.count == 1 }
        service.show(.library, plan: try plan)
        try await until("The replanned count did not start.") { await counter.calls.count == 2 }
        await counter.release()
        try await until("The replanned count did not show.") { service.places(of: .library)?.months["2024-10-01"]?.first?.name == "Oslo" }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(service.places(of: .library)?.months["2024-10-01"]?.first?.name, "Oslo", "The superseded count never lands.")
        let calls = await counter.calls.count
        XCTAssertEqual(calls, 2, "The replan is one count, not a recount as well.")
    }

    func testEightFeedsAreKeptWithTheLibraryAndTheFeedShownPinned() async throws {
        var counts: [LibraryQuery: [MonthPlaceCount]] = [.library: Self.kyoto]
        let people = (1...8).map { LibraryQuery.person("person-\($0)") }
        for person in people { counts[person] = Self.oslo }
        let counter = PlacesCounter(counts)
        let service = MonthPlacesService(source: counter, delay: .zero)
        service.show(.library, plan: try plan)
        try await until("The library was not counted.") { service.places(of: .library) != nil }
        for person in people.prefix(7) {
            service.show(person, plan: try plan)
            try await until("\(person.stableKey) was not counted.") { service.places(of: person) != nil }
        }
        XCTAssertEqual(service.kept.count, MonthPlacesService.keptLimit)
        service.show(people[7], plan: try plan)
        try await until("The ninth feed was not counted.") { service.places(of: people[7]) != nil }
        XCTAssertEqual(Set(service.kept.keys), [.library, people[7]], "The library and the feed shown stay; the rest go.")
    }

    func testTheIndexKeepsTheTwelveFeedsWrittenMostRecently() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MonthPlacesServiceTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let index = try LibraryIndex(scope: "https://places.example.test/api|alice", userID: "alice", directory: directory)
        for n in 1...13 { try await index.keepMonthPlaces(Self.kyoto, forKey: "feed-\(n)", ifCurrent: { true }) }
        let first = try await index.monthPlaces(forKey: "feed-1")
        XCTAssertNil(first, "The thirteenth feed pushes the oldest out.")
        let second = try await index.monthPlaces(forKey: "feed-2")
        XCTAssertEqual(second, Self.kyoto)
        let last = try await index.monthPlaces(forKey: "feed-13")
        XCTAssertEqual(last, Self.kyoto)

        // Writing a feed again makes it the newest.
        try await index.keepMonthPlaces(Self.oslo, forKey: "feed-2", ifCurrent: { true })
        try await index.keepMonthPlaces(Self.kyoto, forKey: "feed-14", ifCurrent: { true })
        let third = try await index.monthPlaces(forKey: "feed-3")
        XCTAssertNil(third)
        let rewritten = try await index.monthPlaces(forKey: "feed-2")
        XCTAssertEqual(rewritten, Self.oslo)

        // A feed without located photos keeps no rows, and reads as not kept.
        try await index.keepMonthPlaces([], forKey: "feed-14", ifCurrent: { true })
        let empty = try await index.monthPlaces(forKey: "feed-14")
        XCTAssertNil(empty)
    }

    private func until(_ message: String, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }
}

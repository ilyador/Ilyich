import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// People for the shelves and the people screens (REBUILD_ROADMAP.md F5): PeopleDirectory loads
/// every visible person in one flight from one source, and PeoplePager pages them by name, with
/// the offline library standing in only when the server gives no answer at all.
@MainActor final class PeopleTests: XCTestCase {
    private var server: StubServer!
    private var api: APIClient!
    private var index: LibraryIndex!

    override func setUp() async throws {
        server = makeStubServer()
        api = try APIClient(baseURL: server.baseURL, accessToken: "session", userID: "alice", sessionConfiguration: server.configuration(),
                            networkConfiguration: NetworkConfiguration())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PeopleTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { [api] in
            await api?.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        index = try LibraryIndex(scope: api.cacheScope, userID: "alice", directory: directory)
        await api.attachEntityStore(index)
    }

    /// Two callers asking at once share one run of page requests, and a run never mixes sources:
    /// a later page's failure fails the run rather than finishing it from the index, and only a
    /// first page with no answer at all turns to the index, for the whole run.
    func testAllVisiblePeopleIsOneFlightFromOneSource() async throws {
        try await completeIndex()
        let held = StubServer.Gate()
        server.route("GET", "people", page(["ann", "ben"], total: 3, more: true).waiting(for: held), page(["cal"], total: 3, more: false))
        let directory = PeopleDirectory(source: api)
        let first = Task { try await directory.allVisible() }
        let second = Task { try await directory.allVisible() }
        try await until("The first page was not asked for.") { held.waiting == 1 }
        held.open()
        let firstPeople = try await first.value, secondPeople = try await second.value
        XCTAssertEqual(firstPeople.map(\.id), ["ann", "ben", "cal"])
        XCTAssertEqual(secondPeople.map(\.id), firstPeople.map(\.id))
        XCTAssertEqual(server.requests("GET", "people").map { $0.query.first { $0.name == "page" }?.value }, ["1", "2"], "One run of pages for both callers.")

        // The run is over: the next call runs again, and a failed second page fails it.
        server.route("GET", "people", page(["ann", "ben"], total: 3, more: true), .transportFailure(.notConnectedToInternet))
        do { _ = try await directory.allVisible(); XCTFail("A page that got no answer midway must not be made up from the index.") }
        catch { XCTAssertTrue(TransportFailure.isDefinite(error), "\(error)") }

        // No answer at all: the index answers the whole run, hidden people left out.
        server.route("GET", "people", .transportFailure(.notConnectedToInternet))
        let before = server.requests("GET", "people").count
        let offline = try await directory.allVisible()
        XCTAssertEqual(offline.map(\.id), ["maya"])
        XCTAssertEqual(server.requests("GET", "people").count, before + 1, "Only the first page was asked of the server.")

        // A server that keeps saying there is more stops at the page cap.
        server.route("GET", "people", responses: (1...5).map { page(["p\($0)"], total: 100, more: true) })
        let capped = PeopleDirectory(source: api, pageSize: 1, pageCap: 3)
        let some = try await capped.allVisible()
        XCTAssertEqual(some.map(\.id), ["p1", "p2", "p3"])
    }

    func testPeoplePagerNumbersItsPagesAndStartsOverOnANewQuery() async throws {
        server.route("GET", "people", page(["ann", "ben"], total: 3, more: true), page(["cal"], total: 3, more: false), page(["ann"], total: 1, more: false))
        let pager = PeoplePager(source: api)
        await pager.start(query: "")
        XCTAssertEqual(pager.people.map(\.id), ["ann", "ben"])
        XCTAssertTrue(pager.hasMore)
        XCTAssertEqual(pager.nextPage, 2)
        await pager.loadMore()
        XCTAssertEqual(pager.people.map(\.id), ["ann", "ben", "cal"])
        XCTAssertFalse(pager.hasMore)
        XCTAssertFalse(pager.isLoading)
        await pager.start(query: " an ")
        XCTAssertEqual(pager.people.map(\.id), ["ann"], "A new query starts over at its first page.")
        XCTAssertEqual(pager.nextPage, 2)
        let requests = server.requests("GET", "people")
        XCTAssertEqual(requests.map { $0.query.first { $0.name == "page" }?.value }, ["1", "2", "1"])
        XCTAssertEqual(requests.map { $0.query.first { $0.name == "name" }?.value }, [nil, nil, "an"])
    }

    /// With no answer at all and a complete offline library, the index answers the whole query as
    /// one page; a later page's failure is shown and the page asked for again on retry.
    func testPeoplePagerUsesTheOfflineFallback() async throws {
        server.route("GET", "people", .transportFailure(.notConnectedToInternet))
        let pager = PeoplePager(source: api)
        await pager.start(query: "")
        XCTAssertNotNil(pager.failure, "Before the first sync is complete the index cannot answer.")

        try await completeIndex()
        await pager.start(query: "")
        XCTAssertEqual(pager.people.map(\.id), ["maya"], "The index answers, hidden people left out.")
        XCTAssertFalse(pager.hasMore)
        XCTAssertNil(pager.failure)
        await pager.start(query: "zz")
        XCTAssertEqual(pager.people, [], "The index answers by name too.")
        await pager.start(query: "ma")
        XCTAssertEqual(pager.people.map(\.id), ["maya"])

        server.route("GET", "people", page(["ann"], total: 2, more: true), .transportFailure(.notConnectedToInternet), page(["ben"], total: 2, more: false))
        await pager.start(query: "")
        XCTAssertEqual(pager.people.map(\.id), ["ann"])
        await pager.loadMore()
        XCTAssertNotNil(pager.failure, "A later page is never made up from the index.")
        XCTAssertEqual(pager.people.map(\.id), ["ann"])
        XCTAssertEqual(pager.nextPage, 2, "The failed page is asked for again.")
        await pager.loadMore()
        XCTAssertNil(pager.failure)
        XCTAssertEqual(pager.people.map(\.id), ["ann", "ben"])
    }

    /// The People screen keeps the people it shows, filtering them itself, until a new query's
    /// first page replaces them, and keeps them when that page fails, so typing, coming back and
    /// pulling to refresh never empty it. The search filter's picker empties at once, as before.
    func testPeoplePagerKeepsThePeopleShownUntilTheirReplacementArrives() async throws {
        let held = StubServer.Gate()
        server.route("GET", "people", page(["ann", "ben"], total: 3, more: true), page(["ann"], total: 1, more: false).waiting(for: held),
                     .immichError(502, message: "Bad gateway"), page(["anya"], total: 1, more: false))
        let pager = PeoplePager(source: api)
        await pager.start(query: "", keepingPeople: true)
        XCTAssertEqual(pager.people.map(\.id), ["ann", "ben"])

        // A query typed over is never asked for, and changes nothing while it waits.
        let typedOver = Task { await pager.start(query: "zz", debounce: .seconds(30), keepingPeople: true) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(pager.isLoading)
        typedOver.cancel(); await typedOver.value
        XCTAssertEqual(pager.people.map(\.id), ["ann", "ben"])
        XCTAssertEqual(pager.query, "")
        XCTAssertEqual(server.requests("GET", "people").count, 1)

        // The people stay while the new query's first page is on its way, which replaces them.
        let typed = Task { await pager.start(query: "an", debounce: .milliseconds(20), keepingPeople: true) }
        try await until("The new query's first page was not asked for.") { held.waiting == 1 }
        XCTAssertEqual(pager.people.map(\.id), ["ann", "ben"], "The people shown stay while their replacement is on its way.")
        XCTAssertTrue(pager.isLoading)
        XCTAssertTrue(pager.hasMore)
        held.open()
        await typed.value
        XCTAssertEqual(pager.people.map(\.id), ["ann"])
        XCTAssertFalse(pager.hasMore)

        // A refresh the server refuses keeps them and says why; trying again asks for the first
        // page, which replaces them rather than joining them.
        await pager.start(query: "an", keepingPeople: true)
        XCTAssertEqual(pager.people.map(\.id), ["ann"], "A failed refresh keeps the people shown.")
        XCTAssertNotNil(pager.failure)
        XCTAssertFalse(pager.isLoading)
        XCTAssertEqual(pager.nextPage, 1)
        await pager.loadMore()
        XCTAssertNil(pager.failure)
        XCTAssertEqual(pager.people.map(\.id), ["anya"])
        XCTAssertEqual(server.requests("GET", "people").map { $0.query.first { $0.name == "page" }?.value }, ["1", "1", "1", "1"])

        // The picker's way: a new query empties the list at once.
        let picked = StubServer.Gate()
        server.route("GET", "people", page(["cal"], total: 1, more: false).waiting(for: picked))
        let picking = Task { await pager.start(query: "cal") }
        try await until("The picker's query was not asked for.") { picked.waiting == 1 }
        XCTAssertEqual(pager.people, [], "Without keeping them, the people shown go at once.")
        picked.open()
        await picking.value
        XCTAssertEqual(pager.people.map(\.id), ["cal"])
    }

    // MARK: - Support

    /// A complete offline library with a visible person and a hidden one.
    private func completeIndex() async throws {
        _ = try await index.apply([
            SyncEvents.event("PersonV1", #"{"id":"maya","name":"Maya","isHidden":false}"#, ack: "PersonV1|maya"),
            SyncEvents.event("PersonV1", #"{"id":"pat","name":"Pat","isHidden":true}"#, ack: "PersonV1|pat"),
            SyncEvents.complete(),
        ], epoch: await index.epoch())
    }

    private func page(_ ids: [String], total: Int, more: Bool) -> StubServer.Response {
        let people = ids.map { #"{"id":"\#($0)","name":"\#($0.capitalized)","isHidden":false}"# }.joined(separator: ",")
        return .json(#"{"people":[\#(people)],"total":\#(total),"hidden":0,"hasNextPage":\#(more)}"#)
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

import Foundation
@testable import Ilyich

/// What the index would keep of each feed's month places, in memory, recording every read and
/// write. Reads can be held until the test releases them.
actor MemoryPlacesStore: MonthPlacesStore {
    private(set) var rows: [String: [MonthPlaceCount]] = [:]
    private(set) var writes: [String] = []
    private(set) var reads = 0
    private(set) var refused = 0
    private var readGate: StubServer.Gate?

    func monthPlaces(forKey key: String) async throws -> [MonthPlaceCount]? {
        reads += 1
        if let readGate { await readGate.wait() }
        return rows[key]
    }

    func keepMonthPlaces(_ counts: [MonthPlaceCount], forKey key: String, ifCurrent: @escaping @Sendable () -> Bool) async throws {
        guard ifCurrent() else { refused += 1; return }
        rows[key] = counts
        writes.append(key)
    }

    func seed(_ counts: [MonthPlaceCount], forKey key: String) { rows[key] = counts }
    func removeAll() { rows = [:] }
    func holdReads() { readGate = StubServer.Gate() }
    func releaseReads() { readGate?.open() }
}

/// Counts each feed's places on demand, recording the feeds asked for. With `holding`, each count
/// waits until the test releases it.
actor PlacesCounter: TimelineSource {
    private var counts: [LibraryQuery: [MonthPlaceCount]]
    private var queued: [[MonthPlaceCount]] = []
    private(set) var calls: [LibraryQuery] = []
    private(set) var answered = 0
    private var gate: StubServer.Gate?
    private let holding: Bool

    init(_ counts: [LibraryQuery: [MonthPlaceCount]] = [:], holding: Bool = false) {
        self.counts = counts; self.holding = holding
        gate = holding ? StubServer.Gate() : nil
    }

    func set(_ places: [MonthPlaceCount], for query: LibraryQuery) { counts[query] = places }
    /// Answers for the next counts, in the order they are asked, before the feeds' own.
    func queue(_ answers: [[MonthPlaceCount]]) { queued = answers }
    /// Lets the counts waiting go; the next count waits again.
    func release() {
        gate?.open()
        if holding { gate = StubServer.Gate() }
    }

    func plan(_ query: LibraryQuery) async throws -> QueryPlan {
        try QueryPlanner.plan(query, context: PlannerContext(indexReadable: true))
    }
    func summary(_ query: LibraryQuery, plan: QueryPlan) async throws -> [TimeBucket] { [] }
    func month(_ bucket: String, of query: LibraryQuery, plan: QueryPlan) async throws -> [Asset] { [] }
    func monthPlaces(_ query: LibraryQuery, plan: QueryPlan) async throws -> [MonthPlaceCount] {
        calls.append(query)
        let answer = queued.isEmpty ? counts[query] ?? [] : queued.removeFirst()
        if let gate { await gate.wait() }
        answered += 1
        return answer
    }
}

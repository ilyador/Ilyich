import Foundation

/// Where a feed's month places are kept on the phone: the index's month_places rows (F5).
protocol MonthPlacesStore: Sendable {
    /// The rows kept for `key`, or nil when none are.
    func monthPlaces(forKey key: String) async throws -> [MonthPlaceCount]?
    /// Replaces the rows kept for `key`, unless `ifCurrent` says no at the moment they are written.
    func keepMonthPlaces(_ counts: [MonthPlaceCount], forKey key: String, ifCurrent: @escaping @Sendable () -> Bool) async throws
}

/// Each feed's month places (REBUILD_ROADMAP.md F5): what the rail calls a month before its photos
/// load, the trips marked on it and each year's places. The feed shown is served from memory,
/// then from the copy the index keeps, then counted afresh once its first months have had time to
/// load; the count is kept in memory and in the index. One count runs at a time, for the feed
/// shown; a reload while it runs asks for one recount after it. A count begun under one access
/// epoch is never kept once the epoch has moved: it is dropped, and the feed is counted again if
/// it still shows. Eight feeds stay in memory, the library's and the feed shown pinned, so clearing
/// a filter brings the library's places straight back.
@MainActor @Observable final class MonthPlacesService {
    /// The feeds kept in memory.
    private(set) var kept: [LibraryQuery: FeedPlaces] = [:]
    @ObservationIgnored private let source: any TimelineSource
    @ObservationIgnored private let store: (any MonthPlacesStore)?
    @ObservationIgnored private let authorization: AuthorizationState?
    /// Counting every photo's place is one long read, so it waits for the first months of the grid.
    @ObservationIgnored private let delay: Duration
    /// The feed shown, which the eviction keeps.
    @ObservationIgnored private var displayed: LibraryQuery = .library
    @ObservationIgnored private var load: (query: LibraryQuery, plan: QueryPlan, id: UUID, task: Task<Void, Never>)?
    /// The feed changed while it was being counted, so it is counted again after.
    @ObservationIgnored private var recount = false
    static let keptLimit = 8

    /// Without a `store` the places live in memory only, as in tests and the UI fixture.
    init(source: any TimelineSource, store: (any MonthPlacesStore)? = nil, authorization: AuthorizationState? = nil,
         delay: Duration = .seconds(3)) {
        self.source = source; self.store = store; self.authorization = authorization; self.delay = delay
    }

    /// The places of `query`, if they are in memory.
    func places(of query: LibraryQuery) -> FeedPlaces? { kept[query] }

    /// Shows `query`'s places: what memory holds, then the index's copy, then a fresh count after
    /// the delay. Showing the feed being counted asks for one recount after it; showing another
    /// feed stops the count on its way, since only the feed shown is counted.
    func show(_ query: LibraryQuery, plan: QueryPlan) {
        displayed = query
        if let load {
            if load.query == query, load.plan == plan { recount = true; return }
            load.task.cancel()
        }
        recount = false
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(query, plan: plan, id: id)
        }
        load = (query, plan, id, task)
    }

    /// Stops the count on its way, as when the feed stops.
    func cancel() {
        load?.task.cancel(); load = nil; recount = false
    }

    private func run(_ query: LibraryQuery, plan: QueryPlan, id: UUID) async {
        defer { finish(id) }
        if kept[query] == nil, let store, let rows = try? await store.monthPlaces(forKey: query.stableKey), !Task.isCancelled {
            let saved = await Task.detached(priority: .utility) { FeedPlaces(counts: rows) }.value
            guard !Task.isCancelled else { return }
            if kept[query] == nil { keep(saved, for: query) }
        }
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        let current = fence()
        guard let counts = try? await source.monthPlaces(query, plan: plan), !Task.isCancelled else { return }
        let places = await Task.detached(priority: .utility) { FeedPlaces(counts: counts) }.value
        guard !Task.isCancelled else { return }
        if !current() {
            // Counted under access the account no longer has: dropped, and counted again.
            recount = true
            return
        }
        keep(places, for: query)
        try? await store?.keepMonthPlaces(counts, forKey: query.stableKey, ifCurrent: current)
    }

    /// Whether the account's access is still what it is now, for what is counted or read from now
    /// on: false once the access epoch moves or the session ends.
    private func fence() -> @Sendable () -> Bool {
        guard let authorization else { return { true } }
        let epoch = authorization.snapshot.epoch
        return { authorization.isCurrent(epoch) }
    }

    private func finish(_ id: UUID) {
        guard let load, load.id == id else { return }
        self.load = nil
        guard recount else { return }
        recount = false
        if load.query == displayed { show(load.query, plan: load.plan) }
    }

    private func keep(_ places: FeedPlaces, for query: LibraryQuery) {
        // The library and a handful of people or albums are plenty to keep.
        if kept[query] == nil, kept.count >= Self.keptLimit {
            kept = kept.filter { $0.key == .library || $0.key == displayed }
        }
        kept[query] = places
    }
}

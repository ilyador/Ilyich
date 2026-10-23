import Foundation

/// What the stacked filters' counts are read from: the offline index (REBUILD_ROADMAP.md N6).
protocol ShelfFacetSource: Sendable {
    func isReadable() async throws -> Bool
    func facets(_ query: LibraryQuery) async throws -> ShelfFacets
    func feedIDs(_ query: LibraryQuery) async throws -> Set<String>
}

extension LibraryIndex: ShelfFacetSource {}

/// The photos the Earth keeps of its places under a stack of filters: those of the stack without
/// its place, by ID. Equal by the stack it was counted for.
struct PlaceNarrowing: Equatable, Sendable {
    let key: String
    let ids: Set<String>
    static func == (a: PlaceNarrowing, b: PlaceNarrowing) -> Bool { a.key == b.key }
}

/// What the shelves and the Earth narrow to under the filters stacked (REBUILD_ROADMAP.md N6): the
/// people and albums in the stacked feed's photos, each with how many it holds, and the photos the
/// Earth keeps of its places, all counted by the offline index off the main actor. With no filter,
/// or without a readable index, nothing narrows. Only the newest stack's counts are kept; a sync's
/// change marks them stale, and they are counted again the next time the shelves open or the Earth
/// rises, so a backup's stream of changes counts nothing until the counts are wanted.
@MainActor @Observable final class ShelfNarrowing {
    /// The counts for `key`'s stack.
    private(set) var facets: (key: String, value: ShelfFacets)?
    /// The Earth's photos for the stack without its place; nil while the Earth isn't up.
    private(set) var earth: PlaceNarrowing?
    @ObservationIgnored private let source: (any ShelfFacetSource)?
    @ObservationIgnored private var stack = FilterStack()
    @ObservationIgnored private var counting: Task<Void, Never>?
    @ObservationIgnored private var placing: Task<Void, Never>?
    @ObservationIgnored private var stale = false
    @ObservationIgnored private var earthWanted = false
    @ObservationIgnored private let follower = LibraryFollower()

    init(source: (any ShelfFacetSource)?) { self.source = source }

    /// The counts for `stack` when they are in; nil when nothing narrows or they are on their way.
    func facets(for stack: FilterStack) -> ShelfFacets? {
        guard !stack.isEmpty, let facets, facets.key == Self.key(stack) else { return nil }
        return facets.value
    }

    /// Follows the account's bus: a sync's change makes the counts stale.
    func follow(_ bus: LibraryBus?) {
        follower.follow(bus) { [weak self] event in
            if case .changed = event { self?.stale = true }
        }
    }

    /// The filters shown changed: their counts are read now, and the Earth's places if it is up.
    func show(_ stack: FilterStack) {
        guard stack != self.stack else { return }
        self.stack = stack
        stale = false
        count()
        if earthWanted { place() }
    }

    /// The shelves open: counts made stale by a sync since are read again.
    func shelvesOpened() {
        guard stale else { return }
        stale = false
        count()
        if earthWanted { place() }
    }

    /// The Earth rose or sank: its places narrow to the stack while it is up.
    func earthShown(_ up: Bool) {
        earthWanted = up
        if up { place() } else { placing?.cancel(); placing = nil; earth = nil }
    }

    private func count() {
        counting?.cancel()
        let stack = self.stack, key = Self.key(stack)
        guard !stack.isEmpty, let source else { counting = nil; facets = nil; return }
        if facets?.key != key { facets = nil }
        counting = Task { [weak self] in
            guard let counted = try? await Self.read({ try await source.facets(stack.query) }, from: source), !Task.isCancelled else { return }
            guard let self, Self.key(self.stack) == key else { return }
            self.facets = (key, counted)
        }
    }

    private func place() {
        placing?.cancel()
        let narrowing = stack.withoutPlace, key = Self.key(narrowing)
        guard !narrowing.isEmpty, let source else { placing = nil; earth = nil; return }
        if earth?.key != key { earth = nil }
        placing = Task { [weak self] in
            guard let ids = try? await Self.read({ try await source.feedIDs(narrowing.query) }, from: source), !Task.isCancelled else { return }
            guard let self, self.earthWanted, Self.key(self.stack.withoutPlace) == key else { return }
            self.earth = PlaceNarrowing(key: key, ids: ids)
        }
    }

    /// Reads `body` only from a readable index; nil otherwise.
    nonisolated private static func read<T: Sendable>(_ body: @Sendable () async throws -> T, from source: any ShelfFacetSource) async throws -> T? {
        guard try await source.isReadable() else { return nil }
        return try await body()
    }

    private static func key(_ stack: FilterStack) -> String { stack.query.stableKey }
}

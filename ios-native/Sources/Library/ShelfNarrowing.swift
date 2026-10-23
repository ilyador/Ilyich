import Foundation

/// What the stacked filters' counts are read from: the offline index (REBUILD_ROADMAP.md N6).
protocol ShelfFacetSource: Sendable {
    func isReadable() async throws -> Bool
    func facets(_ query: LibraryQuery) async throws -> ShelfFacets
    func feedIDs(_ query: LibraryQuery) async throws -> Set<String>
}

extension LibraryIndex: ShelfFacetSource {}

/// The photos the Earth keeps of its places under a stack of filters: those of the stack without
/// its place, by ID. Equal by the stack it was counted for and the count, so a count again for the
/// same stack that found other photos (after a sync) is told apart without comparing every ID.
struct PlaceNarrowing: Equatable, Sendable {
    let key: String
    let ids: Set<String>
    /// Moves each time the photos counted for the stack change.
    var revision = 0
    /// What the Earth's places are arranged for: the stack and its count.
    var identity: String { "\(key)#\(revision)" }
    static func == (a: PlaceNarrowing, b: PlaceNarrowing) -> Bool { a.key == b.key && a.revision == b.revision }
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
    /// The Earth's count, which a count that found other photos moves.
    @ObservationIgnored private var placeRevision = 0
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

    /// Counts the Earth's photos for the stack without its place. A count again for the stack shown
    /// (after a sync) that found other photos reaches the Earth as a new revision; the same photos
    /// leave it as it is.
    private func place() {
        placing?.cancel()
        let narrowing = stack.withoutPlace, key = Self.key(narrowing)
        guard !narrowing.isEmpty, let source else { placing = nil; earth = nil; return }
        if earth?.key != key { earth = nil }
        let shown = earth?.ids
        placing = Task { [weak self] in
            guard let ids = try? await Self.placed(narrowing.query, from: source, unless: shown), !Task.isCancelled else { return }
            guard let self, self.earthWanted, Self.key(self.stack.withoutPlace) == key else { return }
            self.placeRevision += 1
            self.earth = PlaceNarrowing(key: key, ids: ids, revision: self.placeRevision)
        }
    }

    /// Reads `body` only from a readable index; nil otherwise.
    nonisolated private static func read<T: Sendable>(_ body: @Sendable () async throws -> T, from source: any ShelfFacetSource) async throws -> T? {
        guard try await source.isReadable() else { return nil }
        return try await body()
    }

    /// A feed's photos from a readable index, compared here, off the main actor, with those the
    /// Earth shows; nil when they are the same, or the index can't be read.
    nonisolated private static func placed(_ query: LibraryQuery, from source: any ShelfFacetSource, unless shown: Set<String>?) async throws -> Set<String>? {
        guard try await source.isReadable() else { return nil }
        let ids = try await source.feedIDs(query)
        return ids == shown ? nil : ids
    }

    private static func key(_ stack: FilterStack) -> String { stack.query.stableKey }
}

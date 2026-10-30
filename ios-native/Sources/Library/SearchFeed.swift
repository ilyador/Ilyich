import Foundation

/// One search's results, read page by page through the server's cursors. LibraryFeedStore asks it
/// for the first pages, more, a retry or a refresh, and shows the State each one returns.
///
/// - Smart search reads pages of 10 (SearchQuery's size), or, from a stock server, which pages
///   none, one page of 100; metadata search pages of 100, or 500 when the phone filters what the
///   server returns (owner or developed).
/// - A verified page can be empty and still continue: the first pages, more and a retry follow
///   up to 3 pages until one has results, or up to 40 (20,000 photos) when the phone filters.
/// - A partial or unavailable verification stops there with a RetryPoint at that page's cursor,
///   keeping the results before it.
/// - A continuation that is only a legacy page number is refused; a cursor the server repeats ends
///   the results.
/// - A refresh reads again as many pages as were loaded, and says whether the rows changed.
///
/// Every operation commits only if no other started after it, so a superseded read never
/// overwrites a newer one.
actor SearchFeed {
    struct Request: Sendable {
        let search: ServerSearchRequest

        init(_ search: ServerSearchRequest) { self.search = search }

        /// Metadata search's page size; smart search keeps SearchQuery's 10.
        var pageSize: Int { search.scanBudget != nil ? 500 : 100 }
        /// How many pages the first pages, more or a retry read at most, until one has results.
        var followLimit: Int { search.scanBudget.map { max(1, $0 / 500) } ?? 3 }
    }

    /// Where a stopped read starts again: the cursor of the page that needs reading again, and the
    /// results before it.
    struct RetryPoint: Sendable, Equatable {
        let cursor: String?
        let prefix: [Asset]
    }

    struct State: Sendable {
        var results: [Asset] = []
        /// The cursor of the next page, if the server has more.
        var cursor: String?
        var hasMore = false
        var verification: Verification?
        var retryPoint: RetryPoint?
        /// Pages read into the results, which a refresh reads again.
        var pagesLoaded = 0
        /// The result IDs differ from those before this operation.
        var rowsChanged = false
        /// The server's total. Immich's search gives none (its `total` is the page length), so the
        /// count shown is the results shown.
        var totalCount: Int? { nil }
    }

    let request: Request
    private let source: any SearchSource
    private(set) var state = State()
    /// Results taken out (deleted, or no longer visible) stay out of every later page and retry.
    /// A read given `excluding` takes that set instead, so the caller can let a photo that came
    /// back (restored, or shared again) return.
    private var removed: Set<String> = []
    /// Newer copies of results, by the edit that made them; a refresh started after an edit
    /// carries it from the server.
    private var replaced: [String: (asset: Asset, edit: Int)] = [:]
    private var edits = 0
    private var operation = 0

    init(_ request: Request, source: any SearchSource) {
        self.request = request; self.source = source
    }

    /// The first pages.
    func first(excluding: Set<String>? = nil) async throws -> State {
        if let excluding { removed = excluding }
        return try await read(from: nil, prefix: [], limit: request.followLimit, replay: false, kind: .first)
    }

    /// The next pages, when there are more and nothing waits for a retry.
    func more(excluding: Set<String>? = nil) async throws -> State {
        if let excluding { removed = excluding }
        guard state.hasMore, state.retryPoint == nil else { return state }
        return try await read(from: state.cursor, prefix: state.results, limit: request.followLimit, replay: false, kind: .more)
    }

    /// Reads again from where the last read stopped, or from the start when nothing stopped.
    func retry(excluding: Set<String>? = nil) async throws -> State {
        if let excluding { removed = excluding }
        guard let point = state.retryPoint else {
            return try await read(from: nil, prefix: [], limit: request.followLimit, replay: false, kind: .first)
        }
        return try await read(from: point.cursor, prefix: point.prefix, limit: request.followLimit, replay: false, kind: .more)
    }

    /// Reads again as many pages as were loaded, from the start.
    func refresh(excluding: Set<String>? = nil) async throws -> State {
        if let excluding { removed = excluding }
        return try await read(from: nil, prefix: [], limit: max(1, state.pagesLoaded), replay: true, kind: .first)
    }

    /// Takes results out in place.
    @discardableResult func prune(_ ids: Set<String>) -> State {
        removed.formUnion(ids)
        let before = state.results.count
        state.results.removeAll { ids.contains($0.id) }
        if let point = state.retryPoint {
            state.retryPoint = RetryPoint(cursor: point.cursor, prefix: point.prefix.filter { !ids.contains($0.id) })
        }
        state.rowsChanged = state.results.count != before
        return state
    }

    /// Keeps a newer copy of a result.
    func replace(_ asset: Asset) {
        edits += 1
        replaced[asset.id] = (asset, edits)
        if let i = state.results.firstIndex(where: { $0.id == asset.id }) { state.results[i] = asset }
    }

    /// The first pages and a refresh replace the page count; more and a retry add to it.
    private enum Kind { case first, more }

    private func read(from start: String?, prefix: [Asset], limit: Int, replay: Bool, kind: Kind) async throws -> State {
        operation += 1
        let mine = operation, editsAtStart = edits
        let previousIDs = state.results.map(\.id)
        var failed = RetryPoint(cursor: start, prefix: prefix)
        do {
            var nextCursor = start
            var seen: Set<String> = []
            var accumulated: [Asset] = []
            var latest: Verification?
            var pendingRetry: RetryPoint?
            var fetched = 0
            for _ in 0..<limit {
                try Task.checkCancellation()
                failed = RetryPoint(cursor: nextCursor, prefix: prefix + accumulated)
                let response = switch request.search.endpoint {
                case .smart: try await source.smart(request.search, cursor: nextCursor)
                case .metadata: try await source.metadata(request.search, cursor: nextCursor, size: request.pageSize)
                }
                try Task.checkCancellation()
                fetched += 1
                accumulated += response.assets.items
                latest = response.verification
                // Structured filters select this server's cursor API. A legacy page number must
                // never be sent back as an opaque cursor.
                if response.assets.nextCursor == nil, response.assets.nextPage != nil {
                    throw APIError.invalidResponse("The server returned an incompatible search continuation.")
                }
                let newCursor = response.assets.nextCursor
                if latest?.canRetry == true {
                    pendingRetry = failed; nextCursor = newCursor; break
                }
                if newCursor == nextCursor || (newCursor.map { seen.contains($0) } ?? false) { nextCursor = nil; break }
                nextCursor = newCursor
                if let nextCursor { seen.insert(nextCursor) }
                if nextCursor == nil || (!replay && !accumulated.isEmpty) { break }
            }
            guard operation == mine else { throw CancellationError() }
            if replay, let pendingRetry {
                // A refresh that meets an unchecked page keeps the rows shown and waits for a retry.
                state.cursor = nextCursor; state.retryPoint = pendingRetry.pruned(removed)
                state.hasMore = false; state.verification = latest; state.rowsChanged = false
                return state
            }
            if replay { replaced = replaced.filter { $0.value.edit > editsAtStart } }
            var ids = Set(prefix.map(\.id)).union(removed)
            let unique = accumulated.filter { ids.insert($0.id).inserted }
            let results = (prefix + unique).compactMap { asset -> Asset? in
                guard !removed.contains(asset.id) else { return nil }
                return replaced[asset.id]?.asset ?? asset
            }
            state.results = results
            state.cursor = nextCursor
            state.retryPoint = pendingRetry?.pruned(removed)
            state.hasMore = nextCursor != nil && pendingRetry == nil
            state.verification = latest
            switch kind {
            case .first: state.pagesLoaded = fetched
            case .more: state.pagesLoaded += fetched
            }
            state.rowsChanged = previousIDs != results.map(\.id)
            return state
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if operation == mine { state.retryPoint = failed.pruned(removed) }
            throw error
        }
    }
}

private extension SearchFeed.RetryPoint {
    func pruned(_ removed: Set<String>) -> Self {
        removed.isEmpty ? self : .init(cursor: cursor, prefix: prefix.filter { !removed.contains($0.id) })
    }
}

import Foundation
import Observation

struct LibrarySection: Identifiable, Equatable {
    let id: String
    let count: Int
    let title: String
}
struct GridPosition: Equatable {
    let section: String
    let item: Int
    let offset: Double
}
@MainActor @Observable final class TimelinePosition {
    var section = 0
    var item = 0
    var isScrolling = false
}

protocol LibraryAPI: Sendable {
    var cacheScope: String { get }
    func timeBuckets(filter: TimelineFilter) async throws -> [TimeBucket]
    func timeBucket(_ bucket: String, filter: TimelineFilter) async throws -> [Asset]
    func search(_ query: SearchQuery) async throws -> SearchResponse
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse
}
extension APIClient: LibraryAPI {}

@MainActor @Observable final class LibraryStore {
    let api: any LibraryAPI
    var buckets: [TimeBucket] = []
    var loaded: [String: [Asset]] = [:]
    var results: [Asset] = []
    var isLoading = false
    var isSearching = false
    var error: String?
    var bucketErrors: [String: String] = [:]
    var title = "Library"
    var filterTitle: String?
    var query = ""
    var verification: Verification?
    var hasMore = false
    var revision = 0
    var resetID = UUID()
    var scrollTarget: String?
    var restorePosition: GridPosition?
    var selected: Set<String> = []
    var isSelecting = false
    let navigation = TimelinePosition()
    private(set) var timelineFilter = TimelineFilter()
    private(set) var searchFilter = SearchFilter()
    private(set) var searchMode = SearchMode.context
    private var similarAssetID: String?
    private var cursor: String?
    private var retryBatch: (cursor: String?, prefix: [Asset])?
    private var requests: [String: Task<Void, Never>] = [:]
    private var queryTask: Task<Void, Never>?
    private var generation = UUID()
    private var recentBuckets: [String] = []
    private var usesMetadata = false
    private var showingResults = false
    private var timelineSections: [LibrarySection] = []
    private var cacheEpoch: UUID?
    private var cachedBuckets: Set<String> = []
    private var searchGeneration = UUID()
    private var originalTimeline: (TimelineSnapshot, GridPosition?, String)?
    @ObservationIgnored var position: GridPosition?
    @ObservationIgnored var started = false

    init(api: any LibraryAPI) { self.api = api }

    var sections: [LibrarySection] {
        if showingResults { return [.init(id: "results", count: results.count, title: query.isEmpty ? filterTitle ?? "Library" : "Search")] }
        return timelineSections
    }
    var totalCount: Int { showingResults ? results.count : buckets.reduce(0) { $0 + $1.count } }
    var isFiltered: Bool { filterTitle != nil || !query.isEmpty }

    func asset(section: Int, item: Int) -> Asset? {
        if showingResults { return results.indices.contains(item) ? results[item] : nil }
        guard buckets.indices.contains(section), let assets = loaded[buckets[section].id], assets.indices.contains(item) else { return nil }
        return assets[item]
    }
    func availableAssets(around asset: Asset) -> [Asset] {
        if showingResults { return results }
        guard let i = buckets.firstIndex(where: { loaded[$0.id]?.contains(where: { $0.id == asset.id }) == true }) else { return [asset] }
        return buckets[max(0, i - 1)...min(buckets.count - 1, i + 1)].flatMap { loaded[$0.id] ?? [] }
    }

    func reload() async {
        cancelRequests()
        queryTask?.cancel()
        searchGeneration = UUID(); isSearching = false
        generation = UUID(); let current = generation
        isLoading = true; error = nil; buckets = []; loaded = [:]; recentBuckets = []; bucketErrors = [:]; cachedBuckets = []
        updateSections()
        resetID = UUID()
        defer { if generation == current { isLoading = false } }
        do {
            if showingResults { await loadResults(reset: true); return }
            cacheEpoch = await TimelineCache.shared.epoch(scope: api.cacheScope)
            if let snapshot = await TimelineCache.shared.load(scope: api.cacheScope, filter: timelineFilter), generation == current {
                buckets = snapshot.buckets; loaded = snapshot.assets; cachedBuckets = Set(loaded.keys)
                recentBuckets = buckets.map(\.id).filter { loaded[$0] != nil }; updateSections(); revision += 1
            }
            let response = try await api.timeBuckets(filter: timelineFilter)
            guard generation == current else { return }
            buckets = response
            updateSections()
            title = Self.monthTitle(response.first?.date)
            revision += 1
            for index in 0..<min(2, buckets.count) { requestBucket(index) }
        } catch is CancellationError {} catch { if generation == current { self.error = error.localizedDescription } }
    }

    func requestBucket(_ section: Int) {
        guard !showingResults, buckets.indices.contains(section) else { return }
        let bucket = buckets[section]
        guard loaded[bucket.id] == nil || cachedBuckets.contains(bucket.id), requests[bucket.id] == nil, bucketErrors[bucket.id] == nil else { return }
        let current = generation, filter = timelineFilter
        requests[bucket.id] = Task { [weak self, api] in
            do {
                let assets = try await api.timeBucket(bucket.id, filter: filter)
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.loaded[bucket.id] = assets
                self.cachedBuckets.remove(bucket.id)
                self.recentBuckets.removeAll { $0 == bucket.id }; self.recentBuckets.append(bucket.id)
                // Bucket summaries are cheap; keep a bounded window while the grid remains virtual.
                while self.recentBuckets.count > 12 { self.loaded[self.recentBuckets.removeFirst()] = nil }
                self.requests[bucket.id] = nil; self.revision += 1
                if let epoch = self.cacheEpoch {
                    let snapshot = TimelineSnapshot(buckets: self.buckets, assets: self.loaded)
                    await TimelineCache.shared.save(snapshot, scope: api.cacheScope, filter: filter, epoch: epoch)
                }
            } catch is CancellationError {} catch {
                guard let self, self.generation == current else { return }
                self.requests[bucket.id] = nil; self.bucketErrors[bucket.id] = error.localizedDescription; self.revision += 1
            }
        }
    }

    func visibleSection(_ index: Int) {
        if showingResults { return }
        guard buckets.indices.contains(index) else { return }
        let next = Self.monthTitle(buckets[index].date)
        if title != next { title = next }
        requestBucket(index)
        if index + 1 < buckets.count { requestBucket(index + 1) }
        if index > 0 { requestBucket(index - 1) }
    }

    func retryFailedBuckets() { bucketErrors = [:]; revision += 1 }

    func setPerson(_ person: Person) {
        rememberOriginal()
        beginScopeChange()
        timelineFilter = TimelineFilter(personID: person.id)
        searchFilter = SearchFilter(personIds: IDsFilter(all: [person.id]))
        filterTitle = person.name.isEmpty ? "Person" : person.name
        query = ""; showingResults = false; usesMetadata = false
        scheduleReload()
    }

    func setAlbum(_ album: Album) {
        rememberOriginal()
        beginScopeChange()
        timelineFilter = TimelineFilter(albumID: album.id)
        timelineFilter.order = album.order ?? "desc"
        searchFilter = SearchFilter(albumIds: IDsFilter(all: [album.id]))
        filterTitle = album.albumName; query = ""; showingResults = false; usesMetadata = false
        scheduleReload()
    }

    func setPlace(assetIDs: [String], title: String) {
        guard !assetIDs.isEmpty else { return }
        rememberOriginal()
        beginScopeChange()
        searchFilter = SearchFilter()
        if assetIDs.count == 1 { searchFilter.id = IDFilter(eq: assetIDs[0]) }
        else { searchFilter.or = assetIDs.map { SearchIDAlternative(id: IDFilter(eq: $0)) } }
        filterTitle = title; query = ""; usesMetadata = true; showingResults = true
        scheduleReload()
    }

    func setTimeline(_ filter: TimelineFilter, title: String) {
        rememberOriginal()
        beginScopeChange()
        timelineFilter = filter; filterTitle = title; query = ""; showingResults = false; usesMetadata = false
        searchFilter = SearchFilter(visibility: filter.visibility.map { StringFilter(eq: $0.rawValue) }, isFavorite: filter.isFavorite.map { BoolFilter(eq: $0) })
        scheduleReload()
    }

    func clearFilters() {
        beginScopeChange(); timelineFilter = TimelineFilter(); searchFilter = SearchFilter()
        filterTitle = nil; query = ""; verification = nil; showingResults = false; usesMetadata = false; searchMode = .context
        selected = []; isSelecting = false
        if let saved = originalTimeline {
            cancelRequests(); generation = UUID(); searchGeneration = UUID()
            buckets = saved.0.buckets; loaded = saved.0.assets; title = saved.2
            recentBuckets = buckets.map(\.id).filter { loaded[$0] != nil }; cachedBuckets = Set(loaded.keys)
            updateSections(); restorePosition = saved.1; resetID = UUID(); revision += 1
            error = nil; isLoading = false; isSearching = false; originalTimeline = nil
        } else { scheduleReload() }
    }

    func search(_ text: String) {
        rememberOriginal()
        beginScopeChange()
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            if filterTitle == nil { clearFilters() }
            else { showingResults = usesMetadata; scheduleReload() }
            return
        }
        // Keep the current grid visible until the replacement query returns.
        queryTask = Task { await loadResults(reset: true) }
    }

    func applySearchOptions(mode: SearchMode, filter: SearchFilter) {
        rememberOriginal(); beginScopeChange()
        searchMode = mode; searchFilter = filter; usesMetadata = true; showingResults = true
        filterTitle = mode == .context ? "Filtered library" : mode.rawValue
        queryTask = Task { await loadResults(reset: true) }
    }

    func findSimilar(to asset: Asset) {
        rememberOriginal(); beginScopeChange()
        query = ""; searchMode = .context; searchFilter = SearchFilter(); similarAssetID = asset.id
        filterTitle = "Similar photos"; showingResults = true; usesMetadata = true
        queryTask = Task { await loadResults(reset: true) }
    }

    func loadMore() {
        guard hasMore, !isSearching, error == nil else { return }
        isSearching = true
        queryTask = Task { await loadResults(reset: false) }
    }
    func retrySearch() {
        queryTask?.cancel()
        let batch = retryBatch
        queryTask = Task { await loadResults(reset: batch == nil, retry: batch) }
    }
    func retryCurrent() {
        if showingResults || !query.isEmpty { retrySearch() }
        else { scheduleReload() }
    }

    private func loadResults(reset: Bool, retry: (cursor: String?, prefix: [Asset])? = nil) async {
        let searchID = UUID(); searchGeneration = searchID
        let text = query, filter = searchFilter.matching(query, mode: searchMode), requestGeneration = generation
        let mode = searchMode, reference = similarAssetID
        let startCursor: String?
        if let retry { startCursor = retry.cursor } else { startCursor = reset ? nil : cursor }
        let prefix = retry?.prefix ?? (reset ? [] : results)
        var failedBatch = (cursor: startCursor, prefix: prefix)
        isSearching = true; error = nil
        defer { if searchGeneration == searchID { isSearching = false } }
        do {
            var nextCursor = startCursor
            var seen: Set<String> = []
            var accumulated: [Asset] = []
            var latest: Verification?
            var pendingRetry: (cursor: String?, prefix: [Asset])?
            // A verified page can contain zero matches and still have a continuation.
            // Bound automatic work; expose Check more when the server has more candidates.
            for _ in 0..<3 {
                try Task.checkCancellation()
                failedBatch = (nextCursor, prefix + accumulated)
                let response: SearchResponse
                if reference != nil {
                    response = try await api.search(SearchQuery(query: nil, queryAssetId: reference, filter: filter, cursor: nextCursor))
                } else if text.isEmpty || mode != .context {
                    response = try await api.metadataSearch(MetadataQuery(filter: filter, cursor: nextCursor))
                } else {
                    response = try await api.search(SearchQuery(query: text, filter: filter, cursor: nextCursor))
                }
                try Task.checkCancellation()
                accumulated += response.assets.items; latest = response.verification
                // Structured filters select this server's cursor API. A legacy page
                // number must never be sent back as an opaque cursor.
                if response.assets.nextCursor == nil, response.assets.nextPage != nil {
                    throw APIError.invalidResponse("The server returned an incompatible search continuation.")
                }
                let newCursor = response.assets.nextCursor
                if latest?.canRetry == true {
                    pendingRetry = failedBatch; nextCursor = newCursor; break
                }
                if newCursor == nextCursor || (newCursor.map { seen.contains($0) } ?? false) { nextCursor = nil; break }
                nextCursor = newCursor
                if let nextCursor { seen.insert(nextCursor) }
                if !accumulated.isEmpty || nextCursor == nil { break }
            }
            guard searchGeneration == searchID, query == text, generation == requestGeneration else { return }
            var IDs = Set(prefix.map(\.id))
            let unique = accumulated.filter { IDs.insert($0.id).inserted }
            results = prefix + unique
            showingResults = true; cursor = nextCursor; retryBatch = pendingRetry
            hasMore = nextCursor != nil && pendingRetry == nil; verification = latest
            revision += 1
            if reset { resetID = UUID() }
        } catch is CancellationError {} catch {
            if searchGeneration == searchID, query == text, generation == requestGeneration {
                retryBatch = failedBatch; self.error = error.localizedDescription
            }
        }
    }

    func update(_ asset: Asset) {
        if let i = results.firstIndex(where: { $0.id == asset.id }) { results[i] = asset }
        for key in Array(loaded.keys) {
            if let i = loaded[key]?.firstIndex(where: { $0.id == asset.id }) { loaded[key]?[i] = asset }
        }
        revision += 1
    }

    private func cancelRequests() { requests.values.forEach { $0.cancel() }; requests = [:] }
    func stop() { cancelRequests(); queryTask?.cancel(); generation = UUID(); searchGeneration = UUID() }
    private func beginScopeChange() {
        stop(); selected = []; isSelecting = false; isSearching = false; isLoading = false
        verification = nil; retryBatch = nil; cursor = nil; hasMore = false
        similarAssetID = nil
        restorePosition = nil; error = nil
    }
    private func scheduleReload() {
        let current = generation
        Task { guard generation == current else { return }; await reload() }
    }
    private func rememberOriginal() {
        if originalTimeline == nil && !isFiltered && !showingResults {
            originalTimeline = (TimelineSnapshot(buckets: buckets, assets: loaded), position, title)
        }
    }
    private func updateSections() {
        timelineSections = buckets.map { .init(id: $0.id, count: $0.count, title: Self.monthTitle($0.date)) }
    }
    private static func monthTitle(_ date: Date?) -> String {
        guard let date else { return "Library" }
        var style = Date.FormatStyle().month(.wide).year()
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }
}

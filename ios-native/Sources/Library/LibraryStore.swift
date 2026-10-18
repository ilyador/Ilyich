import Foundation
import Observation

struct LibrarySection: Identifiable, Equatable {
    let id: String
    let count: Int
    let title: String
}

@MainActor @Observable final class LibraryStore {
    let api: APIClient
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
    var selected: Set<String> = []
    var isSelecting = false
    private(set) var timelineFilter = TimelineFilter()
    private var searchFilter = SearchFilter()
    private var cursor: String?
    private var requests: [String: Task<Void, Never>] = [:]
    private var queryTask: Task<Void, Never>?
    private var generation = UUID()
    private var recentBuckets: [String] = []
    private var usesMetadata = false
    private var showingResults = false

    init(api: APIClient) { self.api = api }

    var sections: [LibrarySection] {
        if showingResults { return [.init(id: "results", count: results.count, title: query.isEmpty ? filterTitle ?? "Library" : "Search")] }
        return buckets.map { .init(id: $0.id, count: $0.count, title: Self.monthTitle($0.date)) }
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
        generation = UUID(); let current = generation
        isLoading = true; error = nil; buckets = []; loaded = [:]; recentBuckets = []; bucketErrors = [:]
        resetID = UUID()
        defer { if generation == current { isLoading = false } }
        do {
            if showingResults { await loadResults(reset: true); return }
            let response = try await api.timeBuckets(filter: timelineFilter)
            guard generation == current else { return }
            buckets = response
            title = Self.monthTitle(response.first?.date)
            revision += 1
            for index in 0..<min(2, buckets.count) { requestBucket(index) }
        } catch is CancellationError {} catch { if generation == current { self.error = error.localizedDescription } }
    }

    func requestBucket(_ section: Int) {
        guard !showingResults, buckets.indices.contains(section) else { return }
        let bucket = buckets[section]
        guard loaded[bucket.id] == nil, requests[bucket.id] == nil, bucketErrors[bucket.id] == nil else { return }
        let current = generation, filter = timelineFilter
        requests[bucket.id] = Task { [weak self, api] in
            do {
                let assets = try await api.timeBucket(bucket.id, filter: filter)
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.loaded[bucket.id] = assets
                self.recentBuckets.removeAll { $0 == bucket.id }; self.recentBuckets.append(bucket.id)
                // Bucket summaries are cheap; keep a bounded window while the grid remains virtual.
                while self.recentBuckets.count > 12 { self.loaded[self.recentBuckets.removeFirst()] = nil }
                self.requests[bucket.id] = nil; self.revision += 1
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
        timelineFilter = TimelineFilter(personID: person.id)
        searchFilter = SearchFilter(personIds: IDsFilter(all: [person.id]))
        filterTitle = person.name.isEmpty ? "Person" : person.name
        query = ""; showingResults = false; usesMetadata = false
        Task { await reload() }
    }

    func setAlbum(_ album: Album) {
        timelineFilter = TimelineFilter(albumID: album.id)
        searchFilter = SearchFilter(albumIds: IDsFilter(all: [album.id]))
        filterTitle = album.albumName; query = ""; showingResults = false; usesMetadata = false
        Task { await reload() }
    }

    func setPlace(assetIDs: [String], title: String) {
        guard !assetIDs.isEmpty else { return }
        searchFilter = SearchFilter()
        if assetIDs.count == 1 { searchFilter.id = IDFilter(eq: assetIDs[0]) }
        else { searchFilter.or = assetIDs.map { SearchIDAlternative(id: IDFilter(eq: $0)) } }
        filterTitle = title; query = ""; usesMetadata = true; showingResults = true
        Task { await reload() }
    }

    func setTimeline(_ filter: TimelineFilter, title: String) {
        timelineFilter = filter; filterTitle = title; query = ""; showingResults = false; usesMetadata = false
        searchFilter = SearchFilter(visibility: filter.visibility.map { StringFilter(eq: $0.rawValue) }, isFavorite: filter.isFavorite.map { BoolFilter(eq: $0) })
        Task { await reload() }
    }

    func clearFilters() {
        queryTask?.cancel(); timelineFilter = TimelineFilter(); searchFilter = SearchFilter()
        filterTitle = nil; query = ""; verification = nil; showingResults = false; usesMetadata = false
        selected = []; isSelecting = false
        Task { await reload() }
    }

    func search(_ text: String) {
        queryTask?.cancel()
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { showingResults = usesMetadata; Task { await reload() }; return }
        // Keep the current grid visible until the replacement query returns.
        queryTask = Task { await loadResults(reset: true) }
    }

    func loadMore() { guard hasMore, !isSearching else { return }; queryTask = Task { await loadResults(reset: false) } }
    func retrySearch() { queryTask?.cancel(); queryTask = Task { await loadResults(reset: true) } }

    private func loadResults(reset: Bool) async {
        let text = query, filter = searchFilter, requestGeneration = generation
        let startCursor = reset ? nil : cursor
        isSearching = true; error = nil
        defer { if query == text && generation == requestGeneration { isSearching = false } }
        do {
            var nextCursor = startCursor
            var seen: Set<String> = []
            var accumulated: [Asset] = []
            var latest: Verification?
            // A verified page can contain zero matches and still have a continuation.
            // Bound automatic work; expose Check more when the server has more candidates.
            for _ in 0..<3 {
                try Task.checkCancellation()
                let response: SearchResponse
                if text.isEmpty {
                    response = try await api.metadataSearch(MetadataQuery(filter: filter, cursor: nextCursor))
                } else {
                    response = try await api.search(SearchQuery(query: text, filter: filter, cursor: nextCursor))
                }
                try Task.checkCancellation()
                accumulated += response.assets.items; latest = response.verification
                let newCursor = response.assets.nextCursor ?? response.assets.nextPage
                if newCursor == nextCursor || (newCursor.map { seen.contains($0) } ?? false) { nextCursor = nil; break }
                nextCursor = newCursor
                if let nextCursor { seen.insert(nextCursor) }
                if !accumulated.isEmpty || nextCursor == nil { break }
            }
            guard query == text, generation == requestGeneration else { return }
            var IDs = Set(reset ? [] : results.map(\.id))
            let unique = accumulated.filter { IDs.insert($0.id).inserted }
            results = reset ? unique : results + unique
            showingResults = true; cursor = nextCursor; hasMore = nextCursor != nil; verification = latest
            revision += 1
            if reset { resetID = UUID() }
        } catch is CancellationError {} catch {
            if query == text, generation == requestGeneration { self.error = error.localizedDescription }
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
    private static func monthTitle(_ date: Date?) -> String {
        guard let date else { return "Library" }
        var style = Date.FormatStyle().month(.wide).year()
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }
}

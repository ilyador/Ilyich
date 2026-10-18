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
    var assetID: String? = nil
}
/// One explicit request for the grid to scroll. A fresh ID makes repeating the same target work.
struct ScrollRequest: Equatable {
    let id = UUID()
    let position: GridPosition
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
    func refresh() async throws
}
extension LibraryAPI { func refresh() async throws {} }
extension APIClient: LibraryAPI {}

@MainActor @Observable final class LibraryStore {
    let api: any LibraryAPI
    var buckets: [TimeBucket] = []
    var loaded: [String: [Asset]] = [:]
    private var remoteBuckets: [TimeBucket] = []
    private var deviceTimeline = MergedTimeline()
    private var merged: [String: [LibraryEntry]] = [:]
    private let includesDevicePhotos: Bool
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
    var scrollRequest: ScrollRequest?
    var restorePosition: GridPosition?
    var selected: Set<String> = [] { didSet {
        selectedRecords = selectedRecords.filter { selected.contains($0.key) }
        selectedLocalRecords = selectedLocalRecords.filter { selected.contains("local:" + $0.key) }
        selectedMatchedCopies = selectedMatchedCopies.filter { selected.contains($0.key) }
    } }
    private var selectedRecords: [String: Asset] = [:]
    private var selectedLocalRecords: [String: LocalPhoto] = [:]
    private var selectedMatchedCopies: [String: LocalPhoto] = [:]
    var isSelecting = false {
        didSet { if !isSelecting { groupSelectionTask?.cancel(); isSelectingGroup = false } }
    }
    private(set) var isSelectingGroup = false
    @ObservationIgnored private var groupSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var groupSelectionID = UUID()
    let navigation = TimelinePosition()
    private(set) var timelineFilter = TimelineFilter()
    private(set) var searchFilter = SearchFilter()
    private(set) var searchMode = SearchMode.context
    private var similarAssetID: String?
    private var cursor: String?
    private var retryBatch: (cursor: String?, prefix: [Asset])?
    private var requests: [String: Task<Void, Never>] = [:]
    private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
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

    init(api: any LibraryAPI, includesDevicePhotos: Bool = false) {
        self.api = api; self.includesDevicePhotos = includesDevicePhotos
    }
    private var mergesDevicePhotos: Bool { includesDevicePhotos && !isFiltered && !showingResults && timelineFilter == TimelineFilter() }
    var selectedLocalPhotos: [LocalPhoto] { Array(selectedLocalRecords.values) }
    var selectedDevicePhotos: [LocalPhoto] {
        var seen = Set<String>()
        return (Array(selectedLocalRecords.values) + Array(selectedMatchedCopies.values)).filter { seen.insert($0.id).inserted }
    }
    var matchingDevicePhotos: [String: LocalPhoto] { deviceTimeline.remoteToLocal }
    func updateDeviceTimeline(_ snapshot: MergedTimeline) {
        deviceTimeline = snapshot
        guard mergesDevicePhotos else { return }
        restorePosition = position
        if let id = restorePosition?.assetID, id.hasPrefix("local:"),
           let remote = snapshot.localToRemote[String(id.dropFirst(6))] {
            restorePosition?.assetID = remote
        }
        updateSections(); resetID = UUID(); revision += 1
    }

    func restoredIndex(for position: GridPosition) -> (section: Int, item: Int)? {
        if let id = position.assetID {
            if showingResults, let item = results.firstIndex(where: { $0.id == id }) { return (0, item) }
            for (section, bucket) in buckets.enumerated() {
                if mergesDevicePhotos, let item = merged[bucket.id]?.firstIndex(where: { $0.id == id }) { return (section, item) }
                if !mergesDevicePhotos, let item = loaded[bucket.id]?.firstIndex(where: { $0.id == id }) { return (section, item) }
            }
        }
        guard let section = sections.firstIndex(where: { $0.id == position.section }), sections[section].count > 0 else { return nil }
        return (section, min(position.item, sections[section].count - 1))
    }

    var sections: [LibrarySection] {
        if showingResults { return [.init(id: "results", count: results.count, title: query.isEmpty ? filterTitle ?? "Library" : "Search")] }
        return timelineSections
    }
    var totalCount: Int { showingResults ? results.count : buckets.reduce(0) { $0 + $1.count } }
    var isFiltered: Bool { filterTitle != nil || !query.isEmpty }
    var selectedAssets: [Asset] {
        var seen = Set<String>()
        return (Array(selectedRecords.values) + results + loaded.values.flatMap { $0 }).filter { selected.contains($0.id) && seen.insert($0.id).inserted }
    }
    func toggleSelection(_ asset: Asset) {
        if selected.contains(asset.id) { selected.remove(asset.id) }
        else { selected.insert(asset.id); selectedRecords[asset.id] = asset }
    }
    func select(_ asset: Asset) { selected.insert(asset.id); selectedRecords[asset.id] = asset }
    func toggleSelection(_ entry: LibraryEntry) {
        if let asset = entry.remote {
            toggleSelection(asset)
            if selected.contains(asset.id), let local = entry.local { selectedMatchedCopies[asset.id] = local }
            return
        }
        guard let photo = entry.local else { return }
        if selected.contains(entry.id) { selected.remove(entry.id) }
        else { selected.insert(entry.id); selectedLocalRecords[photo.id] = photo }
    }
    func select(_ entry: LibraryEntry) {
        if let asset = entry.remote { select(asset); if let local = entry.local { selectedMatchedCopies[asset.id] = local } }
        else if let photo = entry.local { selected.insert(entry.id); selectedLocalRecords[photo.id] = photo }
    }

    /// Resolve the whole date group before changing selection. A virtualized
    /// viewport or an evicted bucket must not silently select only visible cells.
    func selectMonth(_ selecting: Bool) {
        guard isSelecting, !showingResults, !isSelectingGroup,
              buckets.indices.contains(navigation.section) else { return }
        let bucket = buckets[navigation.section].id
        let current = generation, filter = timelineFilter
        let operation = UUID(); groupSelectionID = operation
        isSelectingGroup = true
        groupSelectionTask = Task {
            defer { if generation == current && groupSelectionID == operation { isSelectingGroup = false } }
            do {
                let assets: [Asset]
                if let cached = loaded[bucket], !cachedBuckets.contains(bucket) { assets = cached }
                else if remoteBuckets.contains(where: { $0.id == bucket }) {
                    assets = try await api.timeBucket(bucket, filter: filter)
                } else { assets = [] }
                try Task.checkCancellation()
                guard generation == current, isSelecting else { return }
                let entries = mergesDevicePhotos ? deviceTimeline.entries(remote: assets, bucket: bucket)
                    : assets.map { LibraryEntry.remote($0) }
                let ids = Set(entries.map(\.id))
                if !selecting { selected.subtract(ids) }
                else {
                    for entry in entries {
                        if let asset = entry.remote {
                            selectedRecords[asset.id] = asset
                            if let local = entry.local { selectedMatchedCopies[asset.id] = local }
                        }
                        else if let photo = entry.local { selectedLocalRecords[photo.id] = photo }
                    }
                    selected.formUnion(ids)
                }
            } catch is CancellationError { }
            catch { if generation == current { self.error = error.localizedDescription } }
        }
    }

    var canSelectMonth: Bool { !showingResults && buckets.indices.contains(navigation.section) }

    /// Up to two most common places (city, else country) among already loaded assets.
    func placeSummary(for assets: [Asset]) -> String? {
        var counts: [String: Int] = [:]
        for asset in assets {
            guard let exif = asset.exifInfo else { continue }
            let city = exif.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let country = exif.country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = city.isEmpty ? country : city
            if !name.isEmpty { counts[name, default: 0] += 1 }
        }
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return ranked.isEmpty ? nil : ranked.prefix(2).map(\.key).joined(separator: " · ")
    }
    /// Place summary for one loaded month section; nil until that month has loaded.
    func placeSummary(section: Int) -> String? {
        guard !showingResults, buckets.indices.contains(section), let assets = loaded[buckets[section].id] else { return nil }
        return placeSummary(for: assets)
    }
    /// Search/filter results when showing them, otherwise the month under the viewport.
    var currentPlaceSummary: String? {
        showingResults ? placeSummary(for: results) : placeSummary(section: navigation.section)
    }

    func entry(section: Int, item: Int) -> LibraryEntry? {
        if mergesDevicePhotos, buckets.indices.contains(section) {
            let key = buckets[section].id
            if let entries = merged[key], entries.indices.contains(item) { return entries[item] }
            return nil
        }
        return asset(section: section, item: item).map { .remote($0, local: deviceTimeline.remoteToLocal[$0.id]) }
    }

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

    func reload(preservingPosition: Bool = false) async {
        cancelRequests()
        groupSelectionTask?.cancel(); groupSelectionID = UUID(); isSelectingGroup = false
        queryTask?.cancel()
        searchGeneration = UUID(); isSearching = false
        generation = UUID(); let current = generation
        isLoading = true; error = nil; bucketErrors = [:]; cachedBuckets = []
        if preservingPosition { restorePosition = position }
        else { remoteBuckets = []; buckets = []; loaded = [:]; recentBuckets = [] }
        updateSections()
        resetID = UUID()
        defer { if generation == current { isLoading = false } }
        do {
            if showingResults { await loadResults(reset: true); return }
            cacheEpoch = await TimelineCache.shared.epoch(scope: api.cacheScope)
            if let snapshot = await TimelineCache.shared.load(scope: api.cacheScope, filter: timelineFilter), generation == current {
                remoteBuckets = snapshot.buckets; loaded = snapshot.assets; cachedBuckets = Set(loaded.keys)
                recentBuckets = buckets.map(\.id).filter { loaded[$0] != nil }; updateSections(); revision += 1
            }
            let response = try await api.timeBuckets(filter: timelineFilter)
            guard generation == current else { return }
            remoteBuckets = response
            updateSections()
            title = Self.monthTitle(buckets.first?.date)
            revision += 1
            if preservingPosition {
                cachedBuckets = Set(loaded.keys)
                if let anchor = restorePosition, let index = buckets.firstIndex(where: { $0.id == anchor.section }) {
                    requestBucket(index)
                    if index + 1 < buckets.count { requestBucket(index + 1) }
                }
            }
            for index in 0..<min(2, buckets.count) { requestBucket(index) }
        } catch is CancellationError {} catch { if generation == current { self.error = error.localizedDescription } }
    }

    func requestBucket(_ section: Int) {
        guard !showingResults, buckets.indices.contains(section) else { return }
        let bucket = buckets[section]
        guard remoteBuckets.contains(where: { $0.id == bucket.id }) else { return }
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
                self.requests[bucket.id] = nil; self.updateMergedEntries(); self.revision += 1
                if let epoch = self.cacheEpoch {
                    let snapshot = TimelineSnapshot(buckets: self.remoteBuckets, assets: self.loaded)
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

    /// Rail jump: the section already exists, so only its data and a fresh scroll request are needed.
    func scrollToBucket(_ index: Int) {
        guard !showingResults, buckets.indices.contains(index) else { return }
        cancelPendingNavigation()
        requestBucket(index)
        scrollRequest = ScrollRequest(position: GridPosition(section: buckets[index].id, item: 0, offset: 0))
    }

    func cancelPendingNavigation() {
        navigationTask?.cancel(); navigationTask = nil; scrollRequest = nil
    }

    /// Leaves any filter, search or selection, then scrolls the normal timeline to the asset's
    /// month. Bucket IDs hold local wall dates as UTC components, so the month is matched in UTC.
    func showInTimeline(_ asset: Asset) {
        let reuseTimeline = !isFiltered && !showingResults && !buckets.isEmpty
        let saved = originalTimeline
        beginScopeChange()
        timelineFilter = TimelineFilter(); searchFilter = SearchFilter()
        filterTitle = nil; query = ""; results = []; showingResults = false; usesMetadata = false; searchMode = .context
        originalTimeline = nil; scrollRequest = nil
        let restoreSaved = !reuseTimeline && saved?.0.buckets.isEmpty == false
        if restoreSaved, let saved {
            remoteBuckets = saved.0.buckets; loaded = saved.0.assets; title = saved.2
            recentBuckets = remoteBuckets.map(\.id).filter { loaded[$0] != nil }
            cachedBuckets = Set(loaded.keys)
            updateSections(); resetID = UUID(); revision += 1
        }
        let date = asset.localDateTime ?? asset.fileCreatedAt
        navigationTask = Task {
            if !reuseTimeline && !restoreSaved { await reload() }
            guard !Task.isCancelled, error == nil else { return }
            let current = generation
            guard let date, let index = nearestBucket(to: date) else {
                error = "Couldn't find this photo's date in the timeline."; return
            }
            let bucket = buckets[index].id
            requestBucket(index)
            await requests[bucket]?.value
            guard !Task.isCancelled, generation == current else { return }
            guard bucketErrors[bucket] == nil else {
                error = "Couldn't load photos for that date."; return
            }
            let entries = mergesDevicePhotos ? merged[bucket] ?? [] : (loaded[bucket] ?? []).map { LibraryEntry.remote($0) }
            let distance = { (entry: LibraryEntry) in abs(entry.date.timeIntervalSince(date)) }
            guard let target = entries.first(where: { $0.id == asset.id }) ?? entries.min(by: { distance($0) < distance($1) }),
                  let item = entries.firstIndex(where: { $0.id == target.id }) else {
                error = "Couldn't load photos for that date."; return
            }
            scrollRequest = ScrollRequest(position: GridPosition(section: bucket, item: item, offset: 0, assetID: target.id))
        }
    }

    private func nearestBucket(to date: Date) -> Int? {
        let month = MergedTimeline.monthKey(date)
        if let exact = buckets.firstIndex(where: { $0.id.hasPrefix(month) }) { return exact }
        return buckets.indices.compactMap { index in buckets[index].date.map { (index, abs($0.timeIntervalSince(date))) } }
            .min { $0.1 < $1.1 }?.0
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
            remoteBuckets = saved.0.buckets; loaded = saved.0.assets; title = saved.2
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
        originalTimeline = nil
        if asset.visibility == .locked { Task { await reload() }; return }
        if let i = results.firstIndex(where: { $0.id == asset.id }) { results[i] = asset }
        for key in Array(loaded.keys) {
            if let i = loaded[key]?.firstIndex(where: { $0.id == asset.id }) { loaded[key]?[i] = asset }
        }
        updateMergedEntries()
        revision += 1
    }
    func refreshAfterMutation() async {
        originalTimeline = nil
        do { try await api.refresh(); await reload(preservingPosition: true) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func cancelRequests() { requests.values.forEach { $0.cancel() }; requests = [:] }
    func stop() {
        cancelRequests(); queryTask?.cancel(); cancelPendingNavigation(); groupSelectionTask?.cancel(); isSelectingGroup = false
        generation = UUID(); searchGeneration = UUID()
    }
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
            originalTimeline = (TimelineSnapshot(buckets: remoteBuckets, assets: loaded), position, title)
        }
    }
    private func updateSections() {
        buckets = mergesDevicePhotos ? deviceTimeline.buckets(remote: remoteBuckets) : remoteBuckets
        updateMergedEntries()
        timelineSections = buckets.map { .init(id: $0.id, count: $0.count, title: Self.monthTitle($0.date)) }
    }
    private func updateMergedEntries() {
        merged = [:]
        guard mergesDevicePhotos else { return }
        let remoteKeys = Set(remoteBuckets.map(\.id))
        for bucket in buckets {
            if let assets = loaded[bucket.id] { merged[bucket.id] = deviceTimeline.entries(remote: assets, bucket: bucket.id) }
            else if !remoteKeys.contains(bucket.id) { merged[bucket.id] = deviceTimeline.entries(remote: [], bucket: bucket.id) }
        }
    }
    private static func monthTitle(_ date: Date?) -> String {
        guard let date else { return "Library" }
        var style = Date.FormatStyle().month(.wide).year()
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }
}

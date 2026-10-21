import Foundation
import UIKit
import Observation

struct LibrarySection: Identifiable, Equatable {
    let id: String
    let count: Int
    let title: String
}
struct TimelineDayGroup: Equatable, Sendable {
    let startItem: Int
    var count: Int
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
private struct FrozenFeed {
    let sections: [LibrarySection]
    let assets: [String: [Asset]]
    let mergedEntries: [String: [LibraryEntry]]
    let dayGroups: [String: [TimelineDayGroup]]
    let remoteToLocal: [String: LocalPhoto]
    let showingResults: Bool
    let totalCount: Int
    /// The frozen feed's own month places, not those of the filter on its way.
    let places: [String: [PlaceTally]]
}
/// The time rail drives the grid's offset directly, so scrubbing is one continuous movement
/// instead of jumps from row to row through view updates.
@MainActor final class GridScroller {
    weak var collection: UICollectionView?

    private var range: ClosedRange<CGFloat>? {
        guard let collection else { return nil }
        let top = -collection.adjustedContentInset.top
        let bottom = collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.height
        return top...max(top, bottom)
    }

    /// How far the timeline scrolls, in points.
    var scrollableHeight: CGFloat? { range.map { $0.upperBound - $0.lowerBound } }

    /// How far down the timeline the grid is, from 0 to 1.
    var fraction: CGFloat? {
        guard let collection, let range, range.upperBound > range.lowerBound else { return nil }
        return min(1, max(0, (collection.contentOffset.y - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    func scroll(toFraction fraction: CGFloat) {
        guard let collection, let range else { return }
        let y = range.lowerBound + min(1, max(0, fraction)) * (range.upperBound - range.lowerBound)
        collection.setContentOffset(CGPoint(x: 0, y: y.rounded(.toNearestOrEven)), animated: false)
    }

    /// Where a month starts on the rail, from the grid's own layout.
    func fraction(ofSection section: Int) -> CGFloat? {
        guard let range, range.upperBound > range.lowerBound,
              let top = (collection?.collectionViewLayout as? VirtualPhotoLayout)?.top(ofSection: section) else { return nil }
        return min(1, max(0, (top - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    func scroll(toSection section: Int, animated: Bool) {
        guard let collection, let range, let top = (collection.collectionViewLayout as? VirtualPhotoLayout)?.top(ofSection: section) else { return }
        collection.setContentOffset(CGPoint(x: 0, y: min(range.upperBound, max(range.lowerBound, top - collection.adjustedContentInset.top))), animated: animated)
    }
}

@MainActor @Observable final class TimelinePosition {
    var section = 0
    var item = 0
    var isScrolling = false
    /// The finger is on the time rail.
    var isScrubbing = false
}

protocol LibraryAPI: Sendable {
    var cacheScope: String { get }
    func timeBuckets(filter: TimelineFilter) async throws -> [TimeBucket]
    func timeBucket(_ bucket: String, filter: TimelineFilter) async throws -> [Asset]
    func search(_ query: SearchQuery) async throws -> SearchResponse
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse
    /// Brings the library up to date with the server, and says what that changed, when it knows.
    func refresh() async throws -> LibraryChange?
    func monthPlaces(filter: TimelineFilter) async throws -> [MonthPlaceCount]
    /// Whether a place's photos can be laid out by month, as a person's are.
    func supportsPlaceTimelines() async -> Bool
}
extension LibraryAPI {
    /// Without an offline library the server is always up to date.
    func refresh() async throws -> LibraryChange? { nil }
    /// Only the local index can count places for every month at once.
    func monthPlaces(filter: TimelineFilter) async throws -> [MonthPlaceCount] { [] }
    /// Only the local index can lay out a place by month.
    func supportsPlaceTimelines() async -> Bool { false }
}

enum LibraryAPIError: LocalizedError {
    /// A place's months come from the offline library, which is not ready.
    case placeNeedsOfflineLibrary
    var errorDescription: String? { "This place's photos can be shown by month once the offline library has synced." }
}
extension APIClient: LibraryAPI {}

@MainActor @Observable final class LibraryStore {
    let api: any LibraryAPI
    var buckets: [TimeBucket] = []
    var loaded: [String: [Asset]] = [:]
    private var remoteBuckets: [TimeBucket] = []
    private var deviceTimeline = MergedTimeline()
    private var merged: [String: [LibraryEntry]] = [:]
    private var dayGroupCache: [String: [TimelineDayGroup]] = [:]
    private let includesDevicePhotos: Bool
    var results: [Asset] = []
    var isLoading = false
    var isSearching = false
    var error: String?
    var bucketErrors: [String: String] = [:]
    var title = "Library"
    /// Each feed's places, so a month has a name before its photos load. They are kept per filter,
    /// so the places shown are always those of the feed shown, and clearing a filter brings the
    /// library's places straight back.
    private var placesByFilter: [TimelineFilter: TimelinePlaces] = [:]
    /// Each month's places in the feed shown, ranked.
    var monthPlaces: [String: [PlaceTally]] { placesByFilter[timelineFilter]?.months ?? [:] }
    /// Months spent abroad, named for the time rail.
    var trips: [String: String] { placesByFilter[timelineFilter]?.trips ?? [:] }
    /// The places being counted, and for which feed.
    @ObservationIgnored private var placesLoad: (filter: TimelineFilter, id: UUID, task: Task<Void, Never>)?
    /// The library changed while its places were being counted, so they are counted again after.
    @ObservationIgnored private var placesStale = false
    /// Counting every photo's place is one long read, so it waits for the first months of the grid.
    private let placesDelay: Duration
    /// Whether a chosen place can be laid out by month like a person, as of the last reload.
    @ObservationIgnored private(set) var canShowPlacesByMonth = false
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
    /// The rail moves the grid through this directly, at the finger's pace.
    @ObservationIgnored let scroller = GridScroller()
    private(set) var timelineFilter = TimelineFilter()
    private(set) var searchFilter = SearchFilter.library
    private(set) var searchMode = SearchMode.context
    private var similarAssetID: String?
    private var cursor: String?
    private var retryBatch: (cursor: String?, prefix: [Asset])?
    private var loadedResultPageCount = 0
    // The month queue drives no view. Observing it made SwiftUI update the grid on every scrolled
    // frame, since binding a cell that waits for its month reads it.
    @ObservationIgnored private var requests: [String: Task<Void, Never>] = [:]
    /// Months waiting for a request slot, the one wanted most first. They are held by ID: a
    /// section's index moves when the phone adds a newer month.
    @ObservationIgnored private var pendingBuckets: [String] = []
    @ObservationIgnored private var visibleBucketIDs: Set<String> = []
    /// The first and last month on screen as of the last scrolled frame, to tell which way the grid moves.
    @ObservationIgnored private var shownSections: ClosedRange<Int>?
    /// Each month's section, so the months loading are placed without searching the feed every frame.
    @ObservationIgnored private var sectionOfBucket: [String: Int] = [:]
    @ObservationIgnored private var targetBucketID: String?
    private let maximumBucketRequests = 3
    private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    private var generation = UUID()
    @ObservationIgnored private var recentBuckets: [String] = []
    private var usesMetadata = false
    private var developedOnlyResults = false
    private var showingResults = false
    private var timelineSections: [LibrarySection] = []
    private var frozenFeed: FrozenFeed?
    private var cacheEpoch: UUID?
    @ObservationIgnored private var cachedBuckets: Set<String> = []
    private var searchGeneration = UUID()
    private var originalTimeline: (TimelineSnapshot, GridPosition?, String)?
    @ObservationIgnored var position: GridPosition? {
        didSet { updateVisibleResultsTitle() }
    }
    @ObservationIgnored var started = false

    init(api: any LibraryAPI, includesDevicePhotos: Bool = false, placesDelay: Duration = .seconds(3)) {
        self.api = api; self.includesDevicePhotos = includesDevicePhotos; self.placesDelay = placesDelay
    }
    private var mergesDevicePhotos: Bool { includesDevicePhotos && !isFiltered && !showingResults && timelineFilter == TimelineFilter() }
    var selectedLocalPhotos: [LocalPhoto] { Array(selectedLocalRecords.values) }
    var selectedDevicePhotos: [LocalPhoto] {
        var seen = Set<String>()
        return (Array(selectedLocalRecords.values) + Array(selectedMatchedCopies.values)).filter { seen.insert($0.id).inserted }
    }
    var matchingDevicePhotos: [String: LocalPhoto] { deviceTimeline.remoteToLocal }
    func updateDeviceTimeline(_ snapshot: MergedTimeline) {
        let previousMatches = deviceTimeline.remoteToLocal
        let previousEntries = merged
        let previousSections = timelineSections
        deviceTimeline = snapshot
        guard !isReplacingFeed else { return }
        guard mergesDevicePhotos else {
            if previousMatches != snapshot.remoteToLocal { revision += 1 }
            return
        }
        updateSections()
        let rowsChanged = previousSections != timelineSections
            || previousEntries.mapValues { $0.map(\.id) } != merged.mapValues { $0.map(\.id) }
        // Indexing publishes discovery and fingerprint progress independently. An
        // identical snapshot must not recycle every visible cell or move the grid.
        guard rowsChanged || previousEntries != merged || previousMatches != snapshot.remoteToLocal else { return }
        revision += 1
        guard rowsChanged else { return }
        restorePosition = position
        if let id = restorePosition?.assetID, id.hasPrefix("local:"),
           let remote = snapshot.localToRemote[String(id.dropFirst(6))] {
            restorePosition?.assetID = remote
        }
        resetID = UUID()
    }

    func restoredIndex(for position: GridPosition) -> (section: Int, item: Int)? {
        if let frozenFeed {
            if let id = position.assetID {
                for (section, bucket) in frozenFeed.sections.enumerated() {
                    if let item = frozenFeed.assets[bucket.id]?.firstIndex(where: { $0.id == id }) { return (section, item) }
                    if let item = frozenFeed.mergedEntries[bucket.id]?.firstIndex(where: { $0.id == id }) { return (section, item) }
                }
            }
            guard let section = frozenFeed.sections.firstIndex(where: { $0.id == position.section }),
                  frozenFeed.sections[section].count > 0 else { return nil }
            return (section, min(position.item, frozenFeed.sections[section].count - 1))
        }
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

    private var liveSections: [LibrarySection] {
        if showingResults { return [.init(id: "results", count: results.count, title: query.isEmpty ? filterTitle ?? "Library" : "Search")] }
        return timelineSections
    }
    var sections: [LibrarySection] { frozenFeed?.sections ?? liveSections }
    var totalCount: Int { frozenFeed?.totalCount ?? (showingResults ? results.count : buckets.reduce(0) { $0 + $1.count }) }
    var isReplacingFeed: Bool { frozenFeed != nil }
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
        guard !isReplacingFeed, isSelecting, !showingResults, !isSelectingGroup,
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
    var canScrubTimeline: Bool { !isReplacingFeed && !showingResults && !buckets.isEmpty }

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
    /// Place summary for one month: its loaded photos, or else the local index's count of them.
    func placeSummary(section: Int) -> String? {
        if let frozenFeed {
            guard frozenFeed.sections.indices.contains(section) else { return nil }
            let id = frozenFeed.sections[section].id
            guard let assets = frozenFeed.assets[id] else { return MonthPlaces.summary(frozenFeed.places[id]) }
            return placeSummary(for: assets) ?? MonthPlaces.summary(frozenFeed.places[id])
        }
        guard !showingResults, buckets.indices.contains(section) else { return nil }
        guard let assets = loaded[buckets[section].id] else { return MonthPlaces.summary(monthPlaces[buckets[section].id]) }
        return placeSummary(for: assets) ?? MonthPlaces.summary(monthPlaces[buckets[section].id])
    }

    /// The places of a whole year, for the rail's year lens.
    func placeSummary(year: Int) -> String? {
        var totals: [String: Int] = [:]
        for (bucket, places) in monthPlaces where bucket.hasPrefix("\(year)-") {
            for place in places { totals[place.name, default: 0] += place.count }
        }
        return MonthPlaces.summary(MonthPlaces.ranked(totals))
    }

    /// Counts the feed's places once its first months are in, showing the copy kept on the phone
    /// meanwhile. A reload while they are being counted lets the count finish and then counts
    /// again, so a library that keeps changing still gets its places. The count is kept on the
    /// phone by the same task, under the epoch it began with, so a count that an access change
    /// overtook is never kept.
    private func loadMonthPlaces(_ filter: TimelineFilter) {
        if let placesLoad {
            if placesLoad.filter == filter { placesStale = true; return }
            placesLoad.task.cancel()
        }
        placesStale = false
        let api = self.api, scope = api.cacheScope, delay = placesDelay, id = UUID()
        let task = Task { [weak self] in
            defer { self?.finishPlacesLoad(id) }
            if self?.placesByFilter[filter] == nil, let saved = await TimelinePlacesCache.shared.load(scope: scope, filter: filter),
               !Task.isCancelled, self?.placesByFilter[filter] == nil {
                self?.keepPlaces(saved, for: filter)
            }
            try? await Task.sleep(for: delay)
            let epoch = await TimelinePlacesCache.shared.epoch(scope: scope)
            guard !Task.isCancelled, let counts = try? await api.monthPlaces(filter: filter), !Task.isCancelled else { return }
            let places = await Task.detached(priority: .utility) { TimelinePlaces(counts: counts) }.value
            guard !Task.isCancelled, let self else { return }
            self.keepPlaces(places, for: filter)
            await TimelinePlacesCache.shared.save(places, scope: scope, filter: filter, epoch: epoch)
        }
        placesLoad = (filter, id, task)
    }

    private func finishPlacesLoad(_ id: UUID) {
        guard let load = placesLoad, load.id == id else { return }
        placesLoad = nil
        if placesStale {
            placesStale = false
            if load.filter == timelineFilter { loadMonthPlaces(load.filter) }
        }
    }

    private func keepPlaces(_ places: TimelinePlaces, for filter: TimelineFilter) {
        // The library and a handful of people or albums are plenty to keep.
        if placesByFilter[filter] == nil, placesByFilter.count >= 8 {
            placesByFilter = placesByFilter.filter { $0.key == TimelineFilter() || $0.key == timelineFilter }
        }
        placesByFilter[filter] = places
    }
    /// Search/filter results when showing them, otherwise the month under the viewport.
    var currentPlaceSummary: String? {
        if let frozenFeed {
            if frozenFeed.showingResults { return placeSummary(for: frozenFeed.assets["results"] ?? []) }
            return placeSummary(section: navigation.section)
        }
        return showingResults ? placeSummary(for: results) : placeSummary(section: navigation.section)
    }

    func entry(section: Int, item: Int) -> LibraryEntry? {
        if let frozenFeed {
            guard frozenFeed.sections.indices.contains(section) else { return nil }
            let key = frozenFeed.sections[section].id
            if let entries = frozenFeed.mergedEntries[key], entries.indices.contains(item) { return entries[item] }
            guard let assets = frozenFeed.assets[key], assets.indices.contains(item) else { return nil }
            return .remote(assets[item], local: frozenFeed.remoteToLocal[assets[item].id])
        }
        if mergesDevicePhotos, buckets.indices.contains(section) {
            let key = buckets[section].id
            if let entries = merged[key], entries.indices.contains(item) { return entries[item] }
            return nil
        }
        return asset(section: section, item: item).map { .remote($0, local: deviceTimeline.remoteToLocal[$0.id]) }
    }

    func dayGroups(section: Int) -> [TimelineDayGroup] {
        if let frozenFeed {
            guard frozenFeed.sections.indices.contains(section) else { return [] }
            return frozenFeed.dayGroups[frozenFeed.sections[section].id] ?? []
        }
        guard !showingResults, buckets.indices.contains(section) else { return [] }
        return dayGroupCache[buckets[section].id] ?? []
    }

    func asset(section: Int, item: Int) -> Asset? {
        if let frozenFeed {
            guard frozenFeed.sections.indices.contains(section) else { return nil }
            return frozenFeed.assets[frozenFeed.sections[section].id].flatMap { $0.indices.contains(item) ? $0[item] : nil }
        }
        if showingResults { return results.indices.contains(item) ? results[item] : nil }
        guard buckets.indices.contains(section), let assets = loaded[buckets[section].id], assets.indices.contains(item) else { return nil }
        return assets[item]
    }
    func availableAssets(around asset: Asset) -> [Asset] {
        if let frozenFeed {
            if frozenFeed.showingResults { return frozenFeed.assets["results"] ?? [] }
            guard let i = frozenFeed.sections.firstIndex(where: { frozenFeed.assets[$0.id]?.contains(where: { $0.id == asset.id }) == true }) else { return [asset] }
            return frozenFeed.sections[max(0, i - 1)...min(frozenFeed.sections.count - 1, i + 1)].flatMap { frozenFeed.assets[$0.id] ?? [] }
        }
        if showingResults { return results }
        guard let i = buckets.firstIndex(where: { loaded[$0.id]?.contains(where: { $0.id == asset.id }) == true }) else { return [asset] }
        return buckets[max(0, i - 1)...min(buckets.count - 1, i + 1)].flatMap { loaded[$0.id] ?? [] }
    }

    /// Everything on this phone in the photo's month and the months beside it, in the order the grid
    /// shows them, for swiping in the local viewer.
    func availableLocalPhotos(around photo: LocalPhoto) -> [LocalPhoto] {
        let sections = self.sections
        func phonePhotos(_ section: Int) -> [LocalPhoto] { (0..<sections[section].count).compactMap { entry(section: section, item: $0)?.local } }
        guard let i = sections.indices.first(where: { phonePhotos($0).contains { $0.id == photo.id } }) else { return [photo] }
        return (max(0, i - 1)...min(sections.count - 1, i + 1)).flatMap(phonePhotos)
    }

    func reload(preservingPosition: Bool = false) async {
        cancelRequests()
        groupSelectionTask?.cancel(); groupSelectionID = UUID(); isSelectingGroup = false
        queryTask?.cancel()
        searchGeneration = UUID(); isSearching = false
        generation = UUID(); let current = generation
        isLoading = true; error = nil; bucketErrors = [:]; cachedBuckets = []
        if preservingPosition { restorePosition = position }
        else {
            remoteBuckets = []; buckets = []; loaded = [:]; recentBuckets = []
            updateSections()
            if frozenFeed == nil { resetID = UUID() }
        }
        defer { if generation == current { isLoading = false } }
        do {
            if showingResults { await loadResults(reset: true, preservingPosition: preservingPosition); return }
            cacheEpoch = await TimelineCache.shared.epoch(scope: api.cacheScope)
            // A background sync refresh already has current in-memory rows. Disk
            // hydration is only for an empty timeline; replaying it here can flash
            // older media revisions before the fresh bucket response arrives.
            if !preservingPosition,
               let snapshot = await TimelineCache.shared.load(scope: api.cacheScope, filter: timelineFilter), generation == current {
                remoteBuckets = snapshot.buckets; loaded = snapshot.assets; cachedBuckets = Set(loaded.keys)
                recentBuckets = buckets.map(\.id).filter { loaded[$0] != nil }; updateSections(); revision += 1
                if frozenFeed == nil { title = Self.monthTitle(buckets.first?.date) }
            }
            let response = try await api.timeBuckets(filter: timelineFilter)
            canShowPlacesByMonth = await api.supportsPlaceTimelines()
            guard generation == current else { return }
            let previousSections = timelineSections
            remoteBuckets = response
            loadMonthPlaces(timelineFilter)
            updateSections()
            if preservingPosition && previousSections != timelineSections { resetID = UUID() }
            // Background sync keeps the viewport heading; scrolling/restoration
            // publishes a new visible month if the returned sections move it.
            if !preservingPosition && frozenFeed == nil { title = Self.monthTitle(buckets.first?.date) }
            revision += 1
            if preservingPosition {
                cachedBuckets = Set(loaded.keys)
                if let anchor = restorePosition, let index = buckets.firstIndex(where: { $0.id == anchor.section }) {
                    requestBucket(index)
                    if index + 1 < buckets.count { requestBucket(index + 1) }
                }
            }
            for index in 0..<min(2, buckets.count) { requestBucket(index) }
            if frozenFeed != nil {
                let startup = (0..<min(2, buckets.count)).compactMap { requests[buckets[$0].id] }
                for task in startup { await task.value }
                guard generation == current else { return }
                if buckets.isEmpty || (0..<min(2, buckets.count)).allSatisfy({
                    let id = buckets[$0].id
                    return loaded[id] != nil && bucketErrors[id] == nil
                }) {
                    if !preservingPosition { title = Self.monthTitle(buckets.first?.date) }
                    commitFrozenFeed()
                } else if let failure = bucketErrors.values.first {
                    error = failure
                }
            }
        } catch is CancellationError {} catch LibraryAPIError.placeNeedsOfflineLibrary {
            // The offline library went away under a place, so its photos are found by search instead.
            guard generation == current, let place = timelineFilter.place else { return }
            canShowPlacesByMonth = false
            searchPlace(assetIDs: place.assetIDs, title: filterTitle ?? "Place")
        } catch { if generation == current { self.error = error.localizedDescription } }
    }

    func requestBucket(_ section: Int) {
        guard !showingResults, buckets.indices.contains(section) else { return }
        let id = buckets[section].id
        // Every cell still waiting for its month asks again on each bind, so the cheap checks go first.
        guard requests[id] == nil, bucketErrors[id] == nil,
              loaded[id] == nil || cachedBuckets.contains(id),
              remoteBuckets.contains(where: { $0.id == id }) else { return }
        if visibleBucketIDs.contains(id) || targetBucketID == id {
            // A month on screen, or the one a jump lands on, goes first: the newest request first.
            pendingBuckets.removeAll { $0 == id }
            pendingBuckets.insert(id, at: 0)
        } else if !pendingBuckets.contains(id) {
            pendingBuckets.append(id)
        }
        // Prefetch cannot displace the viewport or accumulate every crossed month.
        if pendingBuckets.count > 6 { pendingBuckets.removeLast(pendingBuckets.count - 6) }
        startPendingBuckets()
    }

    private func startPendingBuckets() {
        while requests.count < maximumBucketRequests, !pendingBuckets.isEmpty {
            let id = pendingBuckets.removeFirst()
            guard requests[id] == nil, bucketErrors[id] == nil,
                  loaded[id] == nil || cachedBuckets.contains(id),
                  remoteBuckets.contains(where: { $0.id == id }) else { continue }
            let current = generation, filter = timelineFilter
            requests[id] = Task { [weak self, api] in
                defer {
                    if let self, self.generation == current {
                        self.requests[id] = nil
                        // While a dropped load wound down its month could not be asked for again, so a
                        // month the grid has come back to meanwhile is asked for now.
                        if Task.isCancelled, let section = self.sectionOfBucket[id], self.isWanted(section) {
                            self.requestBucket(section)
                        }
                        self.startPendingBuckets()
                    }
                }
                do {
                    let assets = try await FeedMonthProbe.measure { try await api.timeBucket(id, filter: filter) }
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    self.loaded[id] = assets
                    self.cachedBuckets.remove(id)
                    self.recentBuckets.removeAll { $0 == id }; self.recentBuckets.append(id)
                    let trimmed = self.trimLoadedBuckets()
                    self.updateMergedEntries(of: [id] + trimmed); self.revision += 1
                    FeedMonthProbe.committed()
                    if let epoch = self.cacheEpoch {
                        let snapshot = TimelineSnapshot(buckets: self.remoteBuckets, assets: self.loaded)
                        await TimelineCache.shared.save(snapshot, scope: api.cacheScope, filter: filter, epoch: epoch)
                    }
                } catch is CancellationError {} catch {
                    // A load dropped for a month the grid left behind fails as URLError.cancelled
                    // when the server was answering it; that is not a month that failed.
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    self.bucketErrors[id] = error.localizedDescription; self.revision += 1
                }
            }
        }
    }

    /// The grid has moved on: a month it left behind that is still loading gives its slot to the
    /// months on screen. One whose load has not started yet is dropped before it starts, and one
    /// that has started stops; the month is asked for again if the grid comes back to it. Months
    /// ahead of the grid, which prefetch asked for, keep loading, and so does the month a jump lands on.
    private func dropLoadsLeftBehind(near sections: [Int]) {
        guard let first = sections.first, let last = sections.last else { return }
        // The grid starts at the top of the feed.
        let previous = shownSections ?? 0...0
        shownSections = first...last
        guard !requests.isEmpty, first != previous.lowerBound || last != previous.upperBound else { return }
        let down = first != previous.lowerBound ? first > previous.lowerBound : last > previous.upperBound
        for (id, task) in requests where id != targetBucketID {
            guard let section = sectionOfBucket[id] else { continue }
            if down ? section < first - 2 : section > last + 2 { task.cancel() }
        }
    }

    /// A month on screen or beside one, or the one a jump lands on: the months the grid asks for.
    private func isWanted(_ section: Int) -> Bool {
        guard buckets.indices.contains(section) else { return false }
        if targetBucketID == buckets[section].id { return true }
        return (section - 1...section + 1).contains { buckets.indices.contains($0) && visibleBucketIDs.contains(buckets[$0].id) }
    }

    /// Keeps the twelve most recently loaded months, and any on screen; returns the months let go.
    private func trimLoadedBuckets() -> [String] {
        let protected = visibleBucketIDs.union(targetBucketID.map { [$0] } ?? [])
        var trimmed: [String] = []
        while recentBuckets.count > 12,
              let index = recentBuckets.firstIndex(where: { !protected.contains($0) }) {
            let id = recentBuckets.remove(at: index)
            loaded[id] = nil
            trimmed.append(id)
        }
        return trimmed
    }

    /// Actual viewport membership, including months that share the same visible row.
    func visibleSections(_ indices: Set<Int>) {
        visibleBucketIDs = Set(indices.compactMap { buckets.indices.contains($0) ? buckets[$0].id : nil })
        if let targetBucketID, visibleBucketIDs.contains(targetBucketID) { self.targetBucketID = nil }
        let ordered = indices.filter { buckets.indices.contains($0) }.sorted()
        let desired = ordered + ordered.flatMap { [$0 + 1, $0 - 1] }.filter { buckets.indices.contains($0) && !indices.contains($0) }
        dropLoadsLeftBehind(near: ordered)
        pendingBuckets = []
        for section in desired { requestBucket(section) }
    }

    func visibleSection(_ index: Int, visible: Set<Int>? = nil) {
        if isReplacingFeed || showingResults { return }
        guard buckets.indices.contains(index) else { return }
        // This runs on every scrolled frame; the sections already carry each month's title.
        let next = timelineSections.indices.contains(index) && timelineSections[index].id == buckets[index].id
            ? timelineSections[index].title : Self.monthTitle(buckets[index].date)
        if title != next { title = next }
        visibleSections(visible ?? [index])
    }

    /// Rail jump: the section already exists, so only its data and a fresh scroll request are needed.
    func scrollToBucket(_ index: Int, item: Int = 0) {
        guard !isReplacingFeed, !showingResults, buckets.indices.contains(index) else { return }
        cancelPendingNavigation()
        targetBucketID = buckets[index].id
        pendingBuckets = []
        requestBucket(index)
        let item = min(max(0, item), max(0, buckets[index].count - 1))
        scrollRequest = ScrollRequest(position: GridPosition(section: buckets[index].id, item: item, offset: 0))
    }

    func cancelPendingNavigation() {
        navigationTask?.cancel(); navigationTask = nil; scrollRequest = nil; targetBucketID = nil
    }

    /// Leaves any filter, search or selection, then scrolls the normal timeline to the asset's
    /// month. Bucket IDs hold local wall dates as UTC components, so the month is matched in UTC.
    func showInTimeline(_ asset: Asset) {
        let reuseTimeline = !isFiltered && !showingResults && !buckets.isEmpty
        let saved = originalTimeline
        beginScopeChange()
        timelineFilter = TimelineFilter(); searchFilter = .library
        filterTitle = nil; query = ""; results = []; showingResults = false; usesMetadata = false; searchMode = .context
        originalTimeline = nil; scrollRequest = nil
        let restoreSaved = !reuseTimeline && saved?.0.buckets.isEmpty == false
        if restoreSaved, let saved {
            remoteBuckets = saved.0.buckets; loaded = saved.0.assets; title = saved.2
            recentBuckets = remoteBuckets.map(\.id).filter { loaded[$0] != nil }
            cachedBuckets = Set(loaded.keys)
            updateSections(); revision += 1
        }
        if reuseTimeline || restoreSaved { commitFrozenFeed() }
        let date = asset.localDateTime ?? asset.fileCreatedAt
        navigationTask = Task {
            if !reuseTimeline && !restoreSaved { await reload() }
            guard !Task.isCancelled, error == nil else { return }
            let current = generation
            guard let date, let index = nearestBucket(to: date) else {
                error = "Couldn't find this photo's date in the timeline."; return
            }
            let bucket = buckets[index].id
            targetBucketID = bucket
            pendingBuckets = []
            requestBucket(index)
            while generation == current, !Task.isCancelled,
                  pendingBuckets.contains(bucket) || requests[bucket] != nil {
                if let task = requests[bucket] { await task.value }
                else { await Task.yield() }
            }
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
        searchFilter = SearchFilter(personIds: IDsFilter(all: [person.id]), visibility: SearchFilter.library.visibility)
        filterTitle = person.name.isEmpty ? "Person" : person.name
        query = ""; showingResults = false; usesMetadata = false
        scheduleReload()
    }

    func setAlbum(_ album: Album) {
        rememberOriginal()
        beginScopeChange()
        timelineFilter = TimelineFilter(albumID: album.id)
        timelineFilter.order = album.order ?? "desc"
        searchFilter = SearchFilter(albumIds: IDsFilter(all: [album.id]), visibility: SearchFilter.library.visibility)
        filterTitle = album.albumName; query = ""; showingResults = false; usesMetadata = false
        scheduleReload()
    }

    /// A place's photos are laid out by month, as a person's are, so the rail, the months' places
    /// and the trips work there too. Without the offline library they are found by search instead.
    func setPlace(id: String, assetIDs: [String], title: String) {
        guard !assetIDs.isEmpty else { return }
        guard canShowPlacesByMonth else { searchPlace(assetIDs: assetIDs, title: title); return }
        rememberOriginal()
        beginScopeChange()
        timelineFilter = TimelineFilter(place: TimelinePlace(id: id, assetIDs: assetIDs))
        searchFilter = Self.placeSearch(assetIDs)
        filterTitle = title; query = ""; showingResults = false; usesMetadata = false
        scheduleReload()
    }

    private func searchPlace(assetIDs: [String], title: String) {
        rememberOriginal()
        beginScopeChange()
        timelineFilter = TimelineFilter()
        searchFilter = Self.placeSearch(assetIDs)
        filterTitle = title; query = ""; usesMetadata = true; showingResults = true
        scheduleReload()
    }

    private static func placeSearch(_ assetIDs: [String]) -> SearchFilter {
        var filter = SearchFilter.library
        if assetIDs.count == 1 { filter.id = IDFilter(eq: assetIDs[0]) }
        else { filter.or = assetIDs.map { SearchIDAlternative(id: IDFilter(eq: $0)) } }
        return filter
    }

    func setMetadataFilter(_ filter: SearchFilter, title: String, developedOnly: Bool = false) {
        rememberOriginal()
        beginScopeChange()
        timelineFilter = TimelineFilter(); searchFilter = filter
        filterTitle = title; query = ""; searchMode = .context
        developedOnlyResults = developedOnly
        usesMetadata = true; showingResults = true
        queryTask = Task { await loadResults(reset: true) }
    }

    /// Every photo developed in Lightroom, laid out by month as a person's photos are. A search
    /// within them keeps to developed photos.
    func setDeveloped(title: String) {
        setTimeline(TimelineFilter(isDeveloped: true), title: title)
        developedOnlyResults = true
    }

    func setTimeline(_ filter: TimelineFilter, title: String) {
        rememberOriginal()
        beginScopeChange()
        timelineFilter = filter; filterTitle = title; query = ""; showingResults = false; usesMetadata = false
        searchFilter = SearchFilter(visibility: filter.visibility.map { StringFilter(eq: $0.rawValue) } ?? SearchFilter.library.visibility, isFavorite: filter.isFavorite.map { BoolFilter(eq: $0) })
        scheduleReload()
    }

    func clearFilters() {
        beginScopeChange(); timelineFilter = TimelineFilter(); searchFilter = .library
        filterTitle = nil; query = ""; verification = nil; showingResults = false; usesMetadata = false; searchMode = .context
        selected = []; isSelecting = false
        if let saved = originalTimeline {
            cancelRequests(); generation = UUID(); searchGeneration = UUID()
            remoteBuckets = saved.0.buckets; loaded = saved.0.assets; title = saved.2
            recentBuckets = buckets.map(\.id).filter { loaded[$0] != nil }; cachedBuckets = Set(loaded.keys)
            updateSections(); restorePosition = saved.1; frozenFeed = nil; resetID = UUID(); revision += 1
            error = nil; isLoading = false; isSearching = false; originalTimeline = nil
            // The library's places come back with it, unless they were never counted.
            if placesByFilter[timelineFilter] == nil { loadMonthPlaces(timelineFilter) }
        } else { scheduleReload() }
    }

    func search(_ text: String) {
        rememberOriginal()
        let keepDevelopedOnly = developedOnlyResults
        beginScopeChange()
        developedOnlyResults = keepDevelopedOnly
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
        query = ""; searchMode = .context; searchFilter = .library; similarAssetID = asset.id
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

    private func loadResults(reset: Bool, retry: (cursor: String?, prefix: [Asset])? = nil,
                             preservingPosition: Bool = false) async {
        let searchID = UUID(); searchGeneration = searchID
        let text = query, filter = searchFilter.matching(query, mode: searchMode), requestGeneration = generation
        let mode = searchMode, reference = similarAssetID, developedOnly = developedOnlyResults
        let previousResultIDs = results.map(\.id)
        // Developed photos can sit a thousand photos deep behind recent phone shots, so the
        // developed shelf reads bigger pages and keeps going, up to 20,000 photos, until it finds some.
        let pageSize = developedOnly ? 500 : 100
        let requestLimit = preservingPosition ? max(1, loadedResultPageCount) : developedOnly ? 40 : 3
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
            var fetchedPageCount = 0
            // A verified page can contain zero matches and still have a continuation.
            // Bound automatic work; expose Check more when the server has more candidates.
            for _ in 0..<requestLimit {
                try Task.checkCancellation()
                failedBatch = (nextCursor, prefix + accumulated)
                let response: SearchResponse
                if reference != nil {
                    response = try await api.search(SearchQuery(query: nil, queryAssetId: reference, filter: filter, cursor: nextCursor))
                } else if text.isEmpty || mode != .context {
                    response = try await api.metadataSearch(MetadataQuery(filter: filter, cursor: nextCursor, size: pageSize))
                } else {
                    response = try await api.search(SearchQuery(query: text, filter: filter, cursor: nextCursor))
                }
                try Task.checkCancellation()
                fetchedPageCount += 1
                accumulated += response.assets.items.filter { !developedOnly || $0.isDeveloped }
                latest = response.verification
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
                if nextCursor == nil || (!preservingPosition && !accumulated.isEmpty) { break }
            }
            guard searchGeneration == searchID, query == text, generation == requestGeneration else { return }
            if preservingPosition, let pendingRetry {
                cursor = nextCursor; retryBatch = pendingRetry; hasMore = false; verification = latest
                revision += 1
                return
            }
            var IDs = Set(prefix.map(\.id))
            let unique = accumulated.filter { IDs.insert($0.id).inserted }
            let updatedResults = prefix + unique
            let resultRowsChanged = previousResultIDs != updatedResults.map(\.id)
            results = updatedResults
            showingResults = true; cursor = nextCursor; retryBatch = pendingRetry
            hasMore = nextCursor != nil && pendingRetry == nil; verification = latest
            revision += 1
            if reset {
                loadedResultPageCount = retry == nil ? fetchedPageCount : max(loadedResultPageCount, fetchedPageCount)
            } else {
                loadedResultPageCount += fetchedPageCount
            }
            if reset && (!preservingPosition || resultRowsChanged) { resetID = UUID() }
            commitFrozenFeed()
            updateVisibleResultsTitle()
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
    /// Takes photos out of the feed at once, before the server's refresh confirms it, so a deleted
    /// photo can't be opened while that is on its way.
    func removeLocally(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        originalTimeline = nil
        results.removeAll { ids.contains($0.id) }
        var removed: [String: Int] = [:]
        for key in Array(loaded.keys) {
            let before = loaded[key]?.count ?? 0
            loaded[key]?.removeAll { ids.contains($0.id) }
            let gone = before - (loaded[key]?.count ?? 0)
            if gone > 0 { removed[key] = gone }
        }
        if !removed.isEmpty {
            remoteBuckets = remoteBuckets.compactMap { bucket in
                guard let gone = removed[bucket.id] else { return bucket }
                return bucket.count > gone ? TimeBucket(timeBucket: bucket.timeBucket, count: bucket.count - gone) : nil
            }
            updateSections()
        }
        revision += 1
    }
    func refreshAfterMutation() async {
        originalTimeline = nil
        do {
            let change = try await api.refresh()
            // A change the pass found was published, and LibraryView reloads the feed on it unless a
            // search is showing. Reloading here as well would load every month twice.
            if let change, !change.isEmpty, query.isEmpty { return }
            await reload(preservingPosition: true)
        }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func cancelRequests() {
        pendingBuckets = []; visibleBucketIDs = []; shownSections = nil; targetBucketID = nil
        requests.values.forEach { $0.cancel() }; requests = [:]
    }
    func stop() {
        cancelRequests(); queryTask?.cancel(); cancelPendingNavigation(); groupSelectionTask?.cancel(); isSelectingGroup = false
        generation = UUID(); searchGeneration = UUID()
        placesLoad?.task.cancel(); placesLoad = nil; placesStale = false
    }
    private func beginScopeChange() {
        freezeCurrentFeedIfNeeded()
        stop(); selected = []; isSelecting = false; isSearching = false; isLoading = false
        verification = nil; retryBatch = nil; cursor = nil; hasMore = false
        loadedResultPageCount = 0
        similarAssetID = nil
        developedOnlyResults = false
        restorePosition = nil; error = nil
    }
    private func freezeCurrentFeedIfNeeded() {
        guard frozenFeed == nil else { return }
        let currentSections = liveSections
        guard currentSections.contains(where: { $0.count > 0 }) else { return }
        let visibleAssets = showingResults ? ["results": results] : loaded
        frozenFeed = FrozenFeed(sections: currentSections, assets: visibleAssets, mergedEntries: merged,
                                dayGroups: dayGroupCache, remoteToLocal: deviceTimeline.remoteToLocal,
                                showingResults: showingResults,
                                totalCount: showingResults ? results.count : buckets.reduce(0) { $0 + $1.count },
                                places: monthPlaces)
    }
    private func commitFrozenFeed() {
        guard frozenFeed != nil else { return }
        frozenFeed = nil
        resetID = UUID()
        revision += 1
    }
    private func updateVisibleResultsTitle() {
        guard showingResults, frozenFeed == nil else { return }
        let index = position?.section == "results" ? position?.item ?? 0 : 0
        let asset = results.indices.contains(index) ? results[index] : results.first
        let next = Self.monthTitle(asset?.localDateTime ?? asset?.fileCreatedAt)
        if title != next { title = next }
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
        sectionOfBucket = Dictionary(buckets.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        updateMergedEntries()
        timelineSections = buckets.map { .init(id: $0.id, count: $0.count, title: Self.monthTitle($0.date)) }
    }
    private func updateMergedEntries() {
        var entries: [String: [LibraryEntry]] = [:], days: [String: [TimelineDayGroup]] = [:]
        let remoteKeys = Set(remoteBuckets.map(\.id)), merging = mergesDevicePhotos
        for bucket in buckets {
            let month = mergedMonth(bucket.id, remote: remoteKeys.contains(bucket.id), merging: merging)
            entries[bucket.id] = month.entries; days[bucket.id] = month.days
        }
        merged = entries; dayGroupCache = days
    }
    /// Only these months changed: one just loaded and those let go to make room. Redoing every
    /// loaded month on each load took a large share of the main thread while scrubbing.
    private func updateMergedEntries(of ids: [String]) {
        let merging = mergesDevicePhotos
        for id in ids {
            let month = buckets.contains(where: { $0.id == id })
                ? mergedMonth(id, remote: remoteBuckets.contains(where: { $0.id == id }), merging: merging) : (entries: nil, days: nil)
            merged[id] = month.entries; dayGroupCache[id] = month.days
        }
    }
    /// One month's rows merged with the photos only on this phone, when they are merged, and its days.
    private func mergedMonth(_ id: String, remote: Bool, merging: Bool) -> (entries: [LibraryEntry]?, days: [TimelineDayGroup]?) {
        let entries: [LibraryEntry]?
        if !merging { entries = loaded[id]?.map { .remote($0) } }
        else if let assets = loaded[id] { entries = deviceTimeline.entries(remote: assets, bucket: id) }
        else if !remote { entries = deviceTimeline.entries(remote: [], bucket: id) }
        else { entries = nil }
        let days = entries.flatMap { $0.isEmpty ? nil : Self.dayGroups($0) }
        return (merging ? entries : nil, days)
    }
    /// Runs of photos taken on the same day. Their dates are wall times stored as UTC, and a UTC
    /// day is a whole 86,400 seconds from midnight, so the day is worked out by hand; asking the
    /// calendar for the start of every photo's day was most of the cost of loading a month.
    nonisolated static func dayGroups(_ entries: [LibraryEntry]) -> [TimelineDayGroup] {
        var style = Date.FormatStyle().month(.wide).day().year()
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        var groups: [TimelineDayGroup] = []
        var currentDay: Double?
        for (item, entry) in entries.enumerated() {
            let day = (entry.date.timeIntervalSinceReferenceDate / 86_400).rounded(.down)
            if currentDay == day {
                groups[groups.count - 1].count += 1
            } else {
                groups.append(TimelineDayGroup(startItem: item, count: 1,
                                               title: Date(timeIntervalSinceReferenceDate: day * 86_400).formatted(style)))
                currentDay = day
            }
        }
        return groups
    }
    private static func monthTitle(_ date: Date?) -> String {
        guard let date else { return "Library" }
        var style = Date.FormatStyle().month(.wide).year()
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }
}

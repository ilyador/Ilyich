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
    /// Its months as projected: rows, days and places.
    let projections: [String: MonthProjector.Projection]
    let remoteToLocal: [String: LocalPhoto]
    let showingResults: Bool
    let totalCount: Int
    /// The frozen feed's own month places, not those of the filter on its way.
    let places: [String: [PlaceTally]]
}
/// The unfiltered library as it was left, to come straight back when a filter or search clears.
private struct SavedTimeline {
    let buckets: [TimeBucket]
    let assets: [String: [Asset]]
    /// Its months as projected, and the phone's photos they were projected with.
    let projections: [String: MonthProjector.Projection]
    let device: MergedTimeline
    let position: GridPosition?
    let title: String
    /// The plan its months came from; nil before the library ever loaded.
    let plan: QueryPlan?
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
    var isScrolling = false { didSet { motionChanged(wasMoving: oldValue || isScrubbing) } }
    /// The finger is on the time rail.
    var isScrubbing = false { didSet { motionChanged(wasMoving: isScrolling || oldValue) } }
    /// Told when the grid starts or stops moving, by a scroll or a scrub, for work that waits
    /// for it to rest (coverage).
    @ObservationIgnored var onMotionChange: ((Bool) -> Void)?

    var isMoving: Bool { isScrolling || isScrubbing }

    private func motionChanged(wasMoving: Bool) {
        if wasMoving != isMoving { onMotionChange?(isMoving) }
    }
}

@MainActor @Observable final class LibraryStore {
    /// Where the feed reads: the account's library repository.
    let source: any LibraryFeedSource
    var buckets: [TimeBucket] = []
    var loaded: [String: [Asset]] = [:]
    private var remoteBuckets: [TimeBucket] = []
    /// The phone's photos as last published, for selection, the viewer and the next projection.
    private var deviceTimeline = MergedTimeline()
    /// The grid's months as projected off the main actor (F3): each bucket's rows, days and
    /// places. A loaded month and its projection land together; a month only the phone has is
    /// projected as soon as the grid knows it.
    private var projections: [String: MonthProjector.Projection] = [:]
    /// The phone's photos as the sections and projections reflect them.
    @ObservationIgnored private var projectedDevice = MergedTimeline()
    /// A snapshot arrived that the projections do not reflect yet.
    @ObservationIgnored private var deviceDirty = false
    /// Months to project again, and why.
    @ObservationIgnored private var dirty: [String: ProjectionReason] = [:]
    /// Months the feed delivered, shown with their rows once projected.
    @ObservationIgnored private var pendingLoads: [String: PendingLoad] = [:]
    /// The projection run on its way; one at a time, the next taking everything that changed meanwhile.
    @ObservationIgnored private var projecting: Task<Void, Never>?
    /// Moves whenever the months or the feed change under a run, which then applies nothing and starts over.
    @ObservationIgnored private var structureVersion = 0
    /// The server's months by bucket, the bucket of each "YYYY-MM" shown, and each bucket's title, formatted once.
    @ObservationIgnored private var remoteIDs: Set<String> = []
    @ObservationIgnored private var bucketOfMonth: [String: String] = [:]
    @ObservationIgnored private var titles: [String: String] = [:]
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
    private var placesByFilter: [LibraryQuery: TimelinePlaces] = [:]
    /// Each month's places in the feed shown, ranked.
    var monthPlaces: [String: [PlaceTally]] { placesByFilter[feedQuery]?.months ?? [:] }
    /// Months spent abroad, named for the time rail.
    var trips: [String: String] { placesByFilter[feedQuery]?.trips ?? [:] }
    /// The places being counted, and for which feed.
    @ObservationIgnored private var placesLoad: (query: LibraryQuery, plan: QueryPlan, id: UUID, task: Task<Void, Never>)?
    /// The library changed while its places were being counted, so they are counted again after.
    @ObservationIgnored private var placesStale = false
    /// Counting every photo's place is one long read, so it waits for the first months of the grid.
    private let placesDelay: Duration
    var filterTitle: String?
    var query = ""
    /// The server's check of the results shown; nil unless a checked Photo content search returned them.
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
    /// What the feed shows. Its plan, made when the feed loads, serves every month it reads.
    private(set) var feedQuery = LibraryQuery.library
    /// How the feed shown is served, as of its last load; nil before then.
    private(set) var feedPlan: QueryPlan?
    /// What a search inside the feed shown searches: its scope, trash, visibility and filters.
    private(set) var searchScope = LibraryStore.librarySearch {
        didSet { searchFilter = ServerSearchRequest.filter(for: searchScope) }
    }
    /// The search scope as Search options edit it.
    private(set) var searchFilter = ServerSearchRequest.filter(for: LibraryStore.librarySearch)
    /// The AI check, mode and filters chosen under the search bar. They persist until changed.
    private(set) var searchChoices: SearchChoices {
        didSet { if searchChoices != oldValue { choicesStorage?.save(searchChoices) } }
    }
    var searchMode: SearchMode { searchChoices.mode }
    @ObservationIgnored private let choicesStorage: SearchChoicesStorage?
    /// While More's filters show without text: the title and the kind of feed they were opened
    /// over, which come back once the last filter goes.
    private var choiceBrowse: (title: String?, usesMetadata: Bool)?
    /// The filtered view More opens, with no text typed, is showing.
    var isBrowsingChoices: Bool { choiceBrowse != nil }
    /// Whether the choices apply to what is shown: a text search, or More's filtered view.
    var choicesApply: Bool { similarAssetID == nil && (!query.isEmpty || choiceBrowse != nil) }
    /// The search shown asks the server to check photo content.
    var checksPhotoContent: Bool { similarAssetID == nil && !query.isEmpty && searchChoices.verifiesText }
    /// What the search bar searches in, by name: the feed's title, not the filtered view's.
    var searchPlaceTitle: String? { choiceBrowse.map { $0.title } ?? filterTitle }
    private var similarAssetID: String?
    /// The search shown, which reads its pages; nil until one starts, and after a change of scope.
    @ObservationIgnored private var searchFeed: SearchFeed?
    /// The search stopped at a page it can read again; otherwise a retry starts it over.
    @ObservationIgnored private var searchCanResume = false
    /// Results taken out while this search shows, kept out of every page that arrives after.
    @ObservationIgnored private var removedResultIDs: Set<String> = []
    /// The feed's months, loaded off the main actor as the grid needs them (F2). `loaded` and
    /// `bucketErrors` mirror what it delivers; the grid reads the mirror.
    @ObservationIgnored private let feed: TimelineFeed
    /// The months on screen, for the feed to read at once: the viewport command that follows
    /// them through the queue must not let a load that lands first evict a month just scrolled on.
    @ObservationIgnored private let feedViewport = TimelineFeed.Viewport()
    /// The feed open in it: its ticket names every delivery, and its query and plan say whether a
    /// reload may keep the months on their way.
    @ObservationIgnored private var feedSession: (ticket: TimelineFeed.Ticket, query: LibraryQuery, plan: QueryPlan)?
    /// The feed shown's ticket, for tests that deliver a month as the feed would.
    var feedTicket: TimelineFeed.Ticket? { feedSession?.ticket }
    /// Commands on their way to the feed, sent in order by one task. The month queue drives no
    /// view: observing it made SwiftUI update the grid on every scrolled frame.
    @ObservationIgnored private var feedCommands: [TimelineFeed.Command] = []
    @ObservationIgnored private var feedCommandTask: Task<Void, Never>?
    /// The section-to-MonthKey mapping (F2 -> F6): each section's month, and the bucket the
    /// source reads for each month it has. Months are keyed by month, not section: a section's
    /// index moves when the phone adds a newer month.
    @ObservationIgnored private var monthKeys: [MonthKey?] = []
    @ObservationIgnored private var monthBuckets: [MonthKey: String] = [:]
    @ObservationIgnored private var monthKeyByBucket: [String: MonthKey] = [:]
    /// What the feed was last told, so a scrolled frame or a repeated snapshot sends nothing.
    @ObservationIgnored private var lastVisibleMonths: Set<MonthKey>?
    @ObservationIgnored private var sentMonths: (order: [MonthKey], buckets: [MonthKey: String])?
    private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    private var generation = UUID()
    private var usesMetadata = false
    private var showingResults = false
    private var timelineSections: [LibrarySection] = []
    private var frozenFeed: FrozenFeed?
    private var searchGeneration = UUID()
    private var originalTimeline: SavedTimeline?
    @ObservationIgnored var position: GridPosition? {
        didSet { updateVisibleResultsTitle() }
    }
    @ObservationIgnored var started = false

    init(source: any LibraryFeedSource, includesDevicePhotos: Bool = false, placesDelay: Duration = .seconds(3),
         choices: SearchChoicesStorage? = nil) {
        self.source = source; self.includesDevicePhotos = includesDevicePhotos; self.placesDelay = placesDelay
        choicesStorage = choices
        searchChoices = choices?.load() ?? SearchChoices()
        feed = TimelineFeed(source: source, viewport: feedViewport)
        send(.attach(self))
    }
    private var mergesDevicePhotos: Bool { includesDevicePhotos && !isFiltered && !showingResults && feedQuery == .library }
    var selectedLocalPhotos: [LocalPhoto] { Array(selectedLocalRecords.values) }
    var selectedDevicePhotos: [LocalPhoto] {
        var seen = Set<String>()
        return (Array(selectedLocalRecords.values) + Array(selectedMatchedCopies.values)).filter { seen.insert($0.id).inserted }
    }
    var matchingDevicePhotos: [String: LocalPhoto] { deviceTimeline.remoteToLocal }
    /// The phone's photos changed. The months they changed in are projected again off the main
    /// actor and land together with the sections, so nothing here costs the frame; an identical
    /// snapshot changes nothing. While a feed is being replaced the snapshot waits for the commit.
    func updateDeviceTimeline(_ snapshot: MergedTimeline) {
        deviceTimeline = snapshot
        deviceDirty = true
        project()
    }

    /// Waits until every month that changed has been projected and shown.
    func settleProjections() async {
        while let task = projecting { await task.value }
    }

    func restoredIndex(for position: GridPosition) -> (section: Int, item: Int)? {
        if let frozenFeed {
            if let id = position.assetID {
                for (section, bucket) in frozenFeed.sections.enumerated() {
                    if let item = frozenFeed.assets[bucket.id]?.firstIndex(where: { $0.id == id }) { return (section, item) }
                    if let item = frozenFeed.projections[bucket.id]?.entries.firstIndex(where: { $0.id == id }) { return (section, item) }
                }
            }
            guard let section = frozenFeed.sections.firstIndex(where: { $0.id == position.section }),
                  frozenFeed.sections[section].count > 0 else { return nil }
            return (section, min(position.item, frozenFeed.sections[section].count - 1))
        }
        if let id = position.assetID {
            if showingResults, let item = results.firstIndex(where: { $0.id == id }) { return (0, item) }
            for (section, bucket) in buckets.enumerated() {
                if let item = projections[bucket.id]?.entries.firstIndex(where: { $0.id == id }) { return (section, item) }
                if projections[bucket.id] == nil, let item = loaded[bucket.id]?.firstIndex(where: { $0.id == id }) { return (section, item) }
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
    /// One step of a drag across the grid, applied as a single change: the selection's records
    /// are filtered once per step, not once per photo.
    func changeSelection(adding: [LibraryEntry], removing: [LibraryEntry]) {
        guard !adding.isEmpty || !removing.isEmpty else { return }
        for entry in adding {
            if let asset = entry.remote {
                selectedRecords[asset.id] = asset
                if let local = entry.local { selectedMatchedCopies[asset.id] = local }
            } else if let photo = entry.local { selectedLocalRecords[photo.id] = photo }
        }
        var next = selected
        next.subtract(removing.map(\.id))
        next.formUnion(adding.map(\.id))
        selected = next
    }

    /// Resolve the whole date group before changing selection. A virtualized
    /// viewport or an evicted bucket must not silently select only visible cells.
    func selectMonth(_ selecting: Bool) {
        guard !isReplacingFeed, isSelecting, !showingResults, !isSelectingGroup,
              buckets.indices.contains(navigation.section) else { return }
        let bucket = buckets[navigation.section].id
        let month = monthKeys[navigation.section]
        let current = generation
        let operation = UUID(); groupSelectionID = operation
        isSelectingGroup = true
        groupSelectionTask = Task {
            defer { if generation == current && groupSelectionID == operation { isSelectingGroup = false } }
            do {
                // The feed's copy of the month, or the month read now; a month only the phone has needs no read.
                var assets: [Asset] = []
                if let month, monthBuckets[month] != nil { assets = try await self.assets(of: month) }
                try Task.checkCancellation()
                guard generation == current, isSelecting else { return }
                let entries = await mergedEntries(remote: assets, bucket: bucket)
                try Task.checkCancellation()
                guard generation == current, isSelecting else { return }
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

    /// Place summary for one month: its loaded photos' (computed in the projection), or else the
    /// local index's count of them.
    func placeSummary(section: Int) -> String? {
        if let frozenFeed {
            guard frozenFeed.sections.indices.contains(section) else { return nil }
            let id = frozenFeed.sections[section].id
            return frozenFeed.projections[id]?.placeSummary ?? MonthPlaces.summary(frozenFeed.places[id])
        }
        guard !showingResults, buckets.indices.contains(section) else { return nil }
        let id = buckets[section].id
        return projections[id]?.placeSummary ?? MonthPlaces.summary(monthPlaces[id])
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
    private func loadMonthPlaces(_ query: LibraryQuery, plan: QueryPlan) {
        if let placesLoad {
            if placesLoad.query == query, placesLoad.plan == plan { placesStale = true; return }
            placesLoad.task.cancel()
        }
        placesStale = false
        let source = self.source, scope = source.cacheScope, delay = placesDelay, id = UUID()
        let task = Task { [weak self] in
            defer { self?.finishPlacesLoad(id) }
            if self?.placesByFilter[query] == nil, let saved = await TimelinePlacesCache.shared.load(scope: scope, query: query),
               !Task.isCancelled, self?.placesByFilter[query] == nil {
                self?.keepPlaces(saved, for: query)
            }
            try? await Task.sleep(for: delay)
            let epoch = await TimelinePlacesCache.shared.epoch(scope: scope)
            guard !Task.isCancelled, let counts = try? await source.monthPlaces(query, plan: plan), !Task.isCancelled else { return }
            let places = await Task.detached(priority: .utility) { TimelinePlaces(counts: counts) }.value
            guard !Task.isCancelled, let self else { return }
            self.keepPlaces(places, for: query)
            await TimelinePlacesCache.shared.save(places, scope: scope, query: query, epoch: epoch)
        }
        placesLoad = (query, plan, id, task)
    }

    private func finishPlacesLoad(_ id: UUID) {
        guard let load = placesLoad, load.id == id else { return }
        placesLoad = nil
        if placesStale {
            placesStale = false
            if load.query == feedQuery, let plan = feedPlan { loadMonthPlaces(load.query, plan: plan) }
        }
    }

    private func keepPlaces(_ places: TimelinePlaces, for query: LibraryQuery) {
        // The library and a handful of people or albums are plenty to keep.
        if placesByFilter[query] == nil, placesByFilter.count >= 8 {
            placesByFilter = placesByFilter.filter { $0.key == .library || $0.key == feedQuery }
        }
        placesByFilter[query] = places
    }
    /// Search/filter results when showing them, otherwise the month under the viewport.
    var currentPlaceSummary: String? {
        if let frozenFeed {
            if frozenFeed.showingResults { return MonthProjector.placeSummary(of: frozenFeed.assets["results"] ?? []) }
            return placeSummary(section: navigation.section)
        }
        return showingResults ? MonthProjector.placeSummary(of: results) : placeSummary(section: navigation.section)
    }

    /// A row of the grid, from its month's projection. A loaded month whose projection has not
    /// landed shows the server's rows in its order meanwhile.
    func entry(section: Int, item: Int) -> LibraryEntry? {
        if let frozenFeed {
            guard frozenFeed.sections.indices.contains(section) else { return nil }
            let key = frozenFeed.sections[section].id
            if let entries = frozenFeed.projections[key]?.entries { return entries.indices.contains(item) ? entries[item] : nil }
            guard let assets = frozenFeed.assets[key], assets.indices.contains(item) else { return nil }
            return .remote(assets[item], local: frozenFeed.remoteToLocal[assets[item].id])
        }
        if showingResults { return asset(section: section, item: item).map { .remote($0, local: deviceTimeline.remoteToLocal[$0.id]) } }
        guard buckets.indices.contains(section) else { return nil }
        if let entries = projections[buckets[section].id]?.entries { return entries.indices.contains(item) ? entries[item] : nil }
        return asset(section: section, item: item).map { .remote($0, local: deviceTimeline.remoteToLocal[$0.id]) }
    }

    func dayGroups(section: Int) -> [TimelineDayGroup] {
        if let frozenFeed {
            guard frozenFeed.sections.indices.contains(section) else { return [] }
            return frozenFeed.projections[frozenFeed.sections[section].id]?.days ?? []
        }
        guard !showingResults, buckets.indices.contains(section) else { return [] }
        return projections[buckets[section].id]?.days ?? []
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
        groupSelectionTask?.cancel(); groupSelectionID = UUID(); isSelectingGroup = false
        queryTask?.cancel()
        searchGeneration = UUID(); isSearching = false
        generation = UUID(); let current = generation
        isLoading = true; error = nil; bucketErrors = [:]
        if preservingPosition { restorePosition = position }
        else {
            // The feed starts over: its months are dropped and a new one opens once planned. With
            // nothing projected yet, the phone's latest photos place the months.
            cancelRequests()
            remoteBuckets = []; buckets = []; loaded = [:]; projections = [:]; dirty = [:]
            projectedDevice = deviceTimeline; deviceDirty = false
            refreshStructure(); project()
            if frozenFeed == nil { resetID = UUID() }
        }
        defer { if generation == current { isLoading = false } }
        do {
            if showingResults { await loadResults(preservingPosition ? .refresh : .first); return }
            // The feed is planned on every load, so a change of routing (the offline library
            // becoming readable, or going away) reopens it on the new backend, anchored by the
            // photo it showed; every month of one load comes from that load's backend.
            let query = feedQuery
            let plan = try await source.plan(query)
            guard generation == current else { return }
            feedPlan = plan
            if plan.backend == .serverSearch {
                // A feed only search can serve, such as a place before the offline library is
                // readable, is one list of results: the plan's noMonths limitation.
                usesMetadata = true; showingResults = true
                await loadResults(preservingPosition ? .refresh : .first); return
            }
            if preservingPosition, let session = feedSession, session.query == query, session.plan == plan {
                // A sync's reload of the feed shown: every month is stale and read again when the
                // grid wants it, shown meanwhile; a month on its way keeps coming, not restarted.
                send(.invalidate(nil))
            } else {
                openFeed(query, plan: plan)
            }
            let response = try await source.summary(query, plan: plan)
            guard generation == current else { return }
            let previousSections = timelineSections
            remoteBuckets = response
            loadMonthPlaces(query, plan: plan)
            refreshStructure(); project()
            if preservingPosition && previousSections != timelineSections { resetID = UUID() }
            // Background sync keeps the viewport heading; scrolling/restoration
            // publishes a new visible month if the returned sections move it.
            if !preservingPosition && frozenFeed == nil { title = Self.monthTitle(buckets.first?.date) }
            revision += 1
            if preservingPosition, let anchor = restorePosition, let index = buckets.firstIndex(where: { $0.id == anchor.section }) {
                requestBucket(index)
                if index + 1 < buckets.count { requestBucket(index + 1) }
            }
            for index in 0..<min(2, buckets.count) { requestBucket(index) }
            if frozenFeed != nil {
                // The first months of the feed on its way, joined rather than polled for. A month
                // only the phone has is not loaded, as before.
                for month in (0..<min(2, buckets.count)).compactMap({ monthKeys[$0] }) where monthBuckets[month] != nil {
                    _ = try? await assets(of: month)
                }
                // Their rows land with their projections.
                await settleProjections()
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
        } catch is CancellationError {} catch { if generation == current { self.error = error.localizedDescription } }
    }

    /// Asks the feed for a month by name, behind what the grid shows. The grid itself never asks:
    /// its months come from the viewport.
    func requestBucket(_ section: Int) {
        guard !showingResults, monthKeys.indices.contains(section), let month = monthKeys[section],
              monthBuckets[month] != nil else { return }
        send(.request([month]))
    }

    /// Actual viewport membership, including months that share the same visible row. The feed
    /// hears of it only when the months on screen change, not on every scrolled frame.
    func visibleSections(_ indices: Set<Int>) {
        let months = Set(indices.compactMap { monthKeys.indices.contains($0) ? monthKeys[$0] : nil })
        guard months != lastVisibleMonths else { return }
        lastVisibleMonths = months
        feedViewport.show(months)
        send(.viewport(visible: months))
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
        if let month = monthKeys[index] { send(.target(month)) }
        let item = min(max(0, item), max(0, buckets[index].count - 1))
        scrollRequest = ScrollRequest(position: GridPosition(section: buckets[index].id, item: item, offset: 0))
    }

    func cancelPendingNavigation() {
        navigationTask?.cancel(); navigationTask = nil; scrollRequest = nil
        send(.target(nil))
    }

    /// Leaves any filter, search or selection, then scrolls the normal timeline to the asset's
    /// month. Bucket IDs hold local wall dates as UTC components, so the month is matched in UTC.
    func showInTimeline(_ asset: Asset) {
        let reuseTimeline = !isFiltered && !showingResults && !buckets.isEmpty
        let saved = originalTimeline, shownPlan = feedPlan
        // The library shown stays, on the feed its months come from: a month on its way keeps coming.
        beginScopeChange(keepingFeed: reuseTimeline)
        if reuseTimeline { feedPlan = shownPlan }
        feedQuery = .library; searchScope = Self.librarySearch
        filterTitle = nil; query = ""; results = []; showingResults = false; usesMetadata = false; choiceBrowse = nil
        originalTimeline = nil; scrollRequest = nil
        let restoreSaved = !reuseTimeline && saved?.buckets.isEmpty == false && saved?.plan != nil
        if restoreSaved, let saved, let plan = saved.plan { restoreTimeline(saved, plan: plan); revision += 1 }
        if reuseTimeline || restoreSaved { commitFrozenFeed() }
        let date = asset.localDateTime ?? asset.fileCreatedAt
        navigationTask = Task {
            if !reuseTimeline && !restoreSaved { await reload() }
            if restoreSaved, let plan = saved?.plan { await replanRestoredLibrary(plan, anchor: saved?.position) }
            guard !Task.isCancelled, error == nil else { return }
            let current = generation
            guard let date, let index = nearestBucket(to: date) else {
                error = "Couldn't find this photo's date in the timeline."; return
            }
            let bucket = buckets[index].id
            // The month is the feed's target, protected and first in line; its load is joined,
            // not polled for. A month only the phone has needs no load.
            var assets: [Asset] = []
            if let month = monthKeys[index], monthBuckets[month] != nil {
                send(.target(month))
                do { assets = try await self.assets(of: month) }
                catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, generation == current else { return }
                    self.error = "Couldn't load photos for that date."; return
                }
            }
            guard !Task.isCancelled, generation == current else { return }
            let entries = await mergedEntries(remote: assets, bucket: bucket)
            guard !Task.isCancelled, generation == current else { return }
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

    /// The banner's Retry: the months that failed are asked for again as the grid wants them.
    func retryFailedBuckets() {
        bucketErrors = [:]; revision += 1
        send(.retryFailed)
    }

    func setPerson(_ person: Person) {
        rememberOriginal()
        beginScopeChange(); choiceBrowse = nil
        feedQuery = .person(person.id)
        searchScope = Self.widened(.person(person.id))
        filterTitle = person.name.isEmpty ? "Person" : person.name
        query = ""; showingResults = false; usesMetadata = false
        scheduleReload()
    }

    func setAlbum(_ album: Album) {
        rememberOriginal()
        beginScopeChange(); choiceBrowse = nil
        let ascending = album.order == "asc"
        feedQuery = .album(album.id, ascending: ascending)
        searchScope = Self.widened(.album(album.id, ascending: ascending))
        filterTitle = album.albumName; query = ""; showingResults = false; usesMetadata = false
        scheduleReload()
    }

    /// A place's photos are laid out by month, as a person's are, so the rail, the months' places
    /// and the trips work there too. Until the offline library is readable the planner serves a
    /// place by search, as one list.
    func setPlace(id: String, assetIDs: [String], title: String) {
        guard !assetIDs.isEmpty else { return }
        setPlace(PlaceMembership(placeID: id, assetIDs: assetIDs, markerQuery: ""), title: title)
    }

    /// A place, known by its membership revision.
    func setPlace(_ place: PlaceMembership, title: String) {
        guard !place.assetIDs.isEmpty else { return }
        rememberOriginal()
        beginScopeChange(); choiceBrowse = nil
        feedQuery = .place(place)
        searchScope = Self.widened(.place(place))
        filterTitle = title; query = ""; showingResults = false; usesMetadata = false
        scheduleReload()
    }

    /// The library as it is searched: the timeline and the archive, active photos only.
    static let librarySearch = widened(.library)
    /// Searches inside the library, a person, an album or a place look in the archive too, as
    /// they always have; the Locked Folder and hidden photos are never asked for.
    private static func widened(_ query: LibraryQuery) -> LibraryQuery {
        var query = query
        query.visibility = [.timeline, .archive]
        return query
    }

    func setMetadataFilter(_ filter: SearchFilter, title: String, developedOnly: Bool = false) {
        rememberOriginal()
        beginScopeChange(); choiceBrowse = nil
        feedQuery = .library
        var scope = LibraryQuery(filter)
        if developedOnly { scope.predicates.developed = true }
        searchScope = scope
        filterTitle = title; query = ""
        usesMetadata = true; showingResults = true
        queryTask = Task { await loadResults(.first) }
    }

    /// Every photo developed in Lightroom, laid out by month as a person's photos are. A search
    /// within them keeps to developed photos.
    func setDeveloped(title: String) {
        setFeed(.lightroom, title: title)
    }

    /// A shelf's feed: Favorites, Archive, Trash, Recently taken or added, a partner, Lightroom.
    func setFeed(_ query: LibraryQuery, title: String) {
        rememberOriginal()
        beginScopeChange(); choiceBrowse = nil
        feedQuery = query; filterTitle = title; self.query = ""; showingResults = false; usesMetadata = false
        // A search inside the feed keeps its scope, trash, visibility and filters.
        searchScope = query
        scheduleReload()
    }

    func clearFilters() {
        beginScopeChange(); feedQuery = .library; searchScope = Self.librarySearch; choiceBrowse = nil
        filterTitle = nil; query = ""; verification = nil; showingResults = false; usesMetadata = false
        selected = []; isSelecting = false
        if let saved = originalTimeline, let plan = saved.plan {
            cancelRequests(); generation = UUID(); searchGeneration = UUID()
            restoreTimeline(saved, plan: plan)
            restorePosition = saved.position; frozenFeed = nil; resetID = UUID(); revision += 1
            // The phone's photos that changed while the filter showed are merged in now, as at a
            // commit: the restore ran while the filter was still frozen, so it could not take them.
            project()
            error = nil; isLoading = false; isSearching = false; originalTimeline = nil
            // The library's places come back with it, unless they were never counted.
            if placesByFilter[feedQuery] == nil { loadMonthPlaces(feedQuery, plan: plan) }
            let anchor = saved.position, current = generation
            Task { guard generation == current else { return }; await replanRestoredLibrary(plan, anchor: anchor) }
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
        queryTask = Task { await loadResults(.first) }
    }

    /// More's mode and filters. With text typed the search runs again with them; without, the
    /// filters show the feed narrowed by them, as one list, until the last one is removed.
    func applySearchOptions(mode: SearchMode, filter: SearchFilter) {
        var choices = searchChoices
        choices.mode = mode; choices.filter = SearchChoices.sanitized(filter)
        changeChoices(to: choices, reopen: true)
    }

    /// The AI check under the search bar. A Photo content search showing runs again.
    func setChecksContent(_ on: Bool) {
        guard on != searchChoices.checksContent else { return }
        searchChoices.checksContent = on
        guard searchChoices.mode == .context, similarAssetID == nil, !query.isEmpty else { return }
        rememberOriginal(); beginScopeChange()
        queryTask = Task { await loadResults(.first) }
    }

    /// Removes one chip's choice, and shows what is left.
    func removeChoice(_ kind: SearchChip.Kind) {
        changeChoices(to: searchChoices.removing(kind))
    }

    /// `reopen` is More's Apply: with no text it opens the filtered view, even when nothing changed.
    private func changeChoices(to choices: SearchChoices, reopen: Bool = false) {
        let before = searchChoices
        searchChoices = choices
        guard choices != before || (reopen && query.isEmpty && choiceBrowse == nil), similarAssetID == nil else { return }
        if !choices.isFiltering, let base = choiceBrowse {
            // The last filter went: the feed More was opened over comes back.
            choiceBrowse = nil
            filterTitle = base.title; usesMetadata = base.usesMetadata
            if query.isEmpty {
                if base.title == nil { clearFilters() }
                else { beginScopeChange(); showingResults = base.usesMetadata; scheduleReload() }
                return
            }
        }
        if query.isEmpty {
            // Only More's Apply opens the filtered view; once open, a change of filter narrows it
            // again. A chip removed while browsing plainly, or a mode alone, opens nothing: the
            // mode changes only what the next search looks in.
            guard choices.isFiltering, choiceBrowse == nil ? reopen : choices.filter != before.filter else { return }
            // The feed shown is frozen before it becomes the filtered view, so it stays on screen
            // until the view is ready, and on an error.
            rememberOriginal(); beginScopeChange()
            if choiceBrowse == nil {
                choiceBrowse = (filterTitle, usesMetadata)
                if filterTitle == nil { filterTitle = "Filtered library" }
            }
            usesMetadata = true; showingResults = true
        } else {
            rememberOriginal(); beginScopeChange()
        }
        queryTask = Task { await loadResults(.first) }
    }

    func findSimilar(to asset: Asset) {
        rememberOriginal(); beginScopeChange(); choiceBrowse = nil
        query = ""; searchScope = Self.librarySearch; similarAssetID = asset.id
        filterTitle = "Similar photos"; showingResults = true; usesMetadata = true
        queryTask = Task { await loadResults(.first) }
    }

    func loadMore() {
        guard hasMore, !isSearching, error == nil else { return }
        isSearching = true
        queryTask = Task { await loadResults(.more) }
    }
    func retrySearch() {
        queryTask?.cancel()
        queryTask = Task { await loadResults(.retry) }
    }
    func retryCurrent() {
        if showingResults || !query.isEmpty { retrySearch() }
        else { scheduleReload() }
    }

    /// The search the feed's scope, the text and its mode, More's filters, or the similar photo,
    /// make. Nil when More's filters leave the feed no photo to find: a visibility chosen outside
    /// the feed's own, such as Only archived inside Favorites, which keeps to the timeline.
    private func searchRequest(text: String) throws(Unsupported) -> ServerSearchRequest? {
        var scope = searchScope
        if let similarAssetID {
            scope = scope.similar(to: similarAssetID)
        } else {
            // Search can't order by date added, so a field search inside Recently added is ordered by
            // the time taken, as the server's search always ordered it.
            if case .chronological(.createdAt, let ascending) = scope.ranking { scope.ranking = .chronological(.takenAt, ascending: ascending) }
            // More's filters narrow every search typed, and the filtered view they open.
            if !text.isEmpty || choiceBrowse != nil {
                scope = scope.narrowed(by: searchChoices.filter)
                guard !scope.visibility.isEmpty else { return nil }
            }
            scope = scope.refined(text: text, mode: searchChoices.mode)
        }
        return try ServerSearchRequest(scope, userID: source.userID, checksContent: similarAssetID == nil && searchChoices.verifiesText)
    }

    /// The choices leave nothing to find: the results are empty at once, as a search that found
    /// nothing, and the server is not asked.
    private func showNothingFound() {
        guard !Task.isCancelled else { return }
        searchFeed = nil; searchCanResume = false; removedResultIDs = []
        results = []; showingResults = true
        hasMore = false; verification = nil; error = nil; isSearching = false
        revision += 1; resetID = UUID()
        commitFrozenFeed()
        updateVisibleResultsTitle()
    }

    private enum SearchStep { case first, more, retry, refresh }

    /// Runs one step of the search shown through its SearchFeed and shows the State it returns.
    /// The first pages and a retry from the start make a new feed; a refresh reads the feed's
    /// loaded pages again, keeping the grid where it is when the rows are unchanged.
    private func loadResults(_ step: SearchStep) async {
        let searchID = UUID(); searchGeneration = searchID
        let text = query, requestGeneration = generation
        let fromStart = step == .first || (step == .retry && !searchCanResume)
        let feed: SearchFeed
        if !fromStart, let searchFeed { feed = searchFeed }
        else if step == .more { isSearching = false; return }
        else {
            let request: ServerSearchRequest?
            do { request = try searchRequest(text: text) } catch {
                self.error = error.localizedDescription; return
            }
            guard let request else { showNothingFound(); return }
            feed = SearchFeed(SearchFeed.Request(request), source: source)
            searchFeed = feed; searchCanResume = false; removedResultIDs = []
        }
        let previousResultIDs = results.map(\.id)
        // Only a search the server was asked to check has a verification to show.
        let checked = feed.request.search.asksForCheck
        isSearching = true; error = nil
        defer { if searchGeneration == searchID { isSearching = false } }
        do {
            let state: SearchFeed.State
            let excluding = removedResultIDs
            switch step {
            case .first: state = try await feed.first(excluding: excluding)
            case .more: state = try await feed.more(excluding: excluding)
            case .retry: if fromStart { state = try await feed.first(excluding: excluding) } else { state = try await feed.retry(excluding: excluding) }
            case .refresh: state = try await feed.refresh(excluding: excluding)
            }
            guard searchGeneration == searchID, query == text, generation == requestGeneration, searchFeed === feed else { return }
            searchCanResume = state.retryPoint != nil
            if step == .refresh, state.retryPoint != nil {
                // An unchecked page met while refreshing keeps the rows shown until it is retried.
                hasMore = false; verification = checked ? state.verification : nil
                revision += 1
                return
            }
            let updatedResults = removedResultIDs.isEmpty ? state.results : state.results.filter { !removedResultIDs.contains($0.id) }
            let resultRowsChanged = previousResultIDs != updatedResults.map(\.id)
            results = updatedResults
            showingResults = true
            hasMore = state.hasMore; verification = checked ? state.verification : nil
            revision += 1
            if fromStart || (step == .refresh && resultRowsChanged) { resetID = UUID() }
            commitFrozenFeed()
            updateVisibleResultsTitle()
        } catch is CancellationError {} catch {
            if searchGeneration == searchID, query == text, generation == requestGeneration, searchFeed === feed {
                searchCanResume = true; self.error = error.localizedDescription
            }
        }
    }

    /// A change the account's sync published takes deleted photos, and photos no longer visible,
    /// out of the results shown, in place. A photo it upserts (restored, or shared again) may come
    /// back with the next read.
    func prune(_ change: LibraryChange) {
        let gone = change.removed.union(change.accessLost)
        if !removedResultIDs.isEmpty { removedResultIDs.subtract(Set(change.upserted.keys).subtracting(gone)) }
        guard !gone.isEmpty, showingResults, let feed = searchFeed else { return }
        removedResultIDs.formUnion(gone)
        Task { await feed.prune(gone) }
        let before = results.count
        results.removeAll { gone.contains($0.id) }
        guard results.count != before else { return }
        revision += 1
        updateVisibleResultsTitle()
    }

    func update(_ asset: Asset) {
        originalTimeline = nil
        if asset.visibility == .locked { Task { await reload() }; return }
        if let i = results.firstIndex(where: { $0.id == asset.id }) {
            results[i] = asset
            if let feed = searchFeed { Task { await feed.replace(asset) } }
        }
        // Only the photo's month is projected again, off the main actor; the record shows at once.
        for key in Array(loaded.keys) {
            if let i = loaded[key]?.firstIndex(where: { $0.id == asset.id }) { loaded[key]?[i] = asset; markDirty(key, .edit) }
        }
        for key in Array(pendingLoads.keys) {
            if let i = pendingLoads[key]?.assets.firstIndex(where: { $0.id == asset.id }) { pendingLoads[key]?.assets[i] = asset; markDirty(key, .edit) }
        }
        send(.replace(asset))
        revision += 1
        project()
    }
    /// Takes photos out of the feed at once, before the server's refresh confirms it, so a deleted
    /// photo can't be opened while that is on its way.
    func removeLocally(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        originalTimeline = nil
        if let feed = searchFeed {
            removedResultIDs.formUnion(ids)
            Task { await feed.prune(ids) }
        }
        results.removeAll { ids.contains($0.id) }
        send(.remove(ids))
        var removed: [String: Int] = [:]
        for key in Array(loaded.keys) {
            let before = loaded[key]?.count ?? 0
            loaded[key]?.removeAll { ids.contains($0.id) }
            let gone = before - (loaded[key]?.count ?? 0)
            guard gone > 0 else { continue }
            removed[key] = gone
            // The rows go at once; the month's days are redone off the main actor.
            projections[key] = projections[key]?.removing(ids)
            markDirty(key, .edit)
        }
        for key in Array(pendingLoads.keys) {
            let before = pendingLoads[key]?.assets.count ?? 0
            pendingLoads[key]?.assets.removeAll { ids.contains($0.id) }
            if before != pendingLoads[key]?.assets.count { markDirty(key, .edit) }
        }
        if !removed.isEmpty {
            remoteBuckets = remoteBuckets.compactMap { bucket in
                guard let gone = removed[bucket.id] else { return bucket }
                return bucket.count > gone ? TimeBucket(timeBucket: bucket.timeBucket, count: bucket.count - gone) : nil
            }
            // A month with nothing left goes whole.
            let kept = Set(remoteBuckets.map(\.id))
            for key in removed.keys where !kept.contains(key) { loaded[key] = nil }
            refreshStructure()
        }
        revision += 1
        project()
    }
    func refreshAfterMutation() async {
        originalTimeline = nil
        do {
            let change = try await source.refresh()
            // A change the pass found was published, and LibraryView reloads the feed on it unless a
            // search is showing. Reloading here as well would load every month twice.
            if let change, !change.isEmpty, query.isEmpty { return }
            await reload(preservingPosition: true)
        }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    /// Closes the feed: its loads stop and nothing it delivers after is shown. Commands still
    /// queued go first, in order; they belong to the feed being closed, and `close` undoes them.
    private func cancelRequests() {
        feedSession = nil; lastVisibleMonths = nil; sentMonths = nil; feedViewport.show([])
        pendingLoads = [:]; structureVersion += 1
        send(.close)
    }

    /// Opens a feed for `query` as `plan` serves it. Every delivery carries its ticket.
    private func openFeed(_ query: LibraryQuery, plan: QueryPlan) {
        let ticket = TimelineFeed.Ticket()
        feedSession = (ticket, query, plan)
        lastVisibleMonths = nil; sentMonths = nil; feedViewport.show([])
        send(.open(ticket, query, plan))
    }

    /// A saved library comes back at once, on a feed of its own with the months it had: twelve
    /// at most, around where it was left.
    private func restoreTimeline(_ saved: SavedTimeline, plan: QueryPlan) {
        openFeed(feedQuery, plan: plan); feedPlan = plan
        remoteBuckets = saved.buckets; title = saved.title
        loaded = Self.resident(saved.assets, buckets: saved.buckets, around: saved.position?.section)
        // Its months come back projected as they were left, with the phone's photos of that time;
        // the photos the phone has now are merged in off the main actor, once it is on screen.
        let remote = Set(saved.buckets.map(\.id))
        projections = saved.projections.filter { loaded[$0.key] != nil || !remote.contains($0.key) }
        dirty = [:]
        projectedDevice = saved.device; deviceDirty = true
        // Where the grid is going back to, so a row the phone's photos move meanwhile anchors there.
        position = saved.position
        refreshStructure()
        var months: [MonthKey: [Asset]] = [:]
        for (id, assets) in loaded { if let month = monthKey(id) { months[month] = assets } }
        send(.restore(months))
        project()
    }

    /// Up to twelve of a saved feed's months, those nearest the anchor first.
    private static func resident(_ assets: [String: [Asset]], buckets: [TimeBucket], around anchor: String?) -> [String: [Asset]] {
        guard assets.count > TimelineFeed.residentLimit else { return assets }
        let index = buckets.firstIndex { $0.id == anchor } ?? 0
        // Nearest first; at the same distance the newer month.
        let nearest = buckets.indices.sorted { (abs($0 - index), $0) < (abs($1 - index), $1) }.map { buckets[$0].id }.filter { assets[$0] != nil }
        var kept: [String: [Asset]] = [:]
        for id in nearest.prefix(TimelineFeed.residentLimit) { kept[id] = assets[id] }
        return kept
    }

    /// Queues a command for the feed. One task sends them in order; a viewport or a target
    /// replaces the one queued before it, so a scrub costs nothing per frame.
    private func send(_ command: TimelineFeed.Command) {
        switch (command, feedCommands.last) {
        case (.viewport, .viewport?), (.target, .target?): feedCommands[feedCommands.count - 1] = command
        default: feedCommands.append(command)
        }
        guard feedCommandTask == nil else { return }
        feedCommandTask = Task {
            while !feedCommands.isEmpty {
                let batch = feedCommands; feedCommands = []
                await feed.handle(batch)
            }
            feedCommandTask = nil
        }
    }

    /// A month's photos from the feed: resident, or joined on their way. Every command sent before
    /// goes first, whatever its task's priority: the task sending them is waited for, and what is
    /// still queued goes with the request, so the answer is for the feed as the store last left it.
    private func assets(of month: MonthKey) async throws -> [Asset] {
        while let task = feedCommandTask { await task.value }
        guard let session = feedSession else { throw CancellationError() }
        let commands = feedCommands; feedCommands = []
        return try await feed.assets(of: month, ticket: session.ticket, after: commands)
    }

    private func monthKey(_ bucket: String) -> MonthKey? {
        if let month = monthKeyByBucket[bucket] { return month }
        guard let month = MonthKey(bucketID: bucket) else { return nil }
        monthKeyByBucket[bucket] = month
        return month
    }
    /// Stops everything on its way. `keepingFeed` leaves the feed and its loads alone, for a
    /// change that keeps the months shown.
    func stop(keepingFeed: Bool = false) {
        if !keepingFeed { cancelRequests() }
        queryTask?.cancel(); cancelPendingNavigation(); groupSelectionTask?.cancel(); isSelectingGroup = false
        generation = UUID(); searchGeneration = UUID()
        placesLoad?.task.cancel(); placesLoad = nil; placesStale = false
    }
    private func beginScopeChange(keepingFeed: Bool = false) {
        freezeCurrentFeedIfNeeded()
        // The results belong to the search left behind; the frozen feed keeps its own copy. An old
        // search's results kept here would show under the next results view while it loads, when
        // the feed it replaces had nothing on screen to freeze.
        results = []
        stop(keepingFeed: keepingFeed); selected = []; isSelecting = false; isSearching = false; isLoading = false
        verification = nil; hasMore = false
        searchFeed = nil; searchCanResume = false; removedResultIDs = []
        similarAssetID = nil
        // The next feed plans its own months; none is read with this one's plan.
        feedPlan = nil
        restorePosition = nil; error = nil
    }
    private func freezeCurrentFeedIfNeeded() {
        guard frozenFeed == nil else { return }
        let currentSections = liveSections
        guard currentSections.contains(where: { $0.count > 0 }) else { return }
        let visibleAssets = showingResults ? ["results": results] : loaded
        frozenFeed = FrozenFeed(sections: currentSections, assets: visibleAssets, projections: projections,
                                remoteToLocal: projectedDevice.remoteToLocal, showingResults: showingResults,
                                totalCount: showingResults ? results.count : buckets.reduce(0) { $0 + $1.count },
                                places: monthPlaces)
    }
    private func commitFrozenFeed() {
        guard frozenFeed != nil else { return }
        frozenFeed = nil
        resetID = UUID()
        revision += 1
        // The phone's photos that arrived while the feed was frozen are merged in now.
        project()
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
    /// The saved library comes back at once with the plan it was left with. A routing change that
    /// arrived while a filter or search was open (the offline library becoming readable, or going
    /// away) reached only the feed shown, so the library plans again and, on a new backend,
    /// reopens there anchored where it was left.
    private func replanRestoredLibrary(_ saved: QueryPlan, anchor: GridPosition?) async {
        let current = generation
        guard let plan = try? await source.plan(feedQuery), generation == current, !Task.isCancelled,
              !isFiltered, !showingResults else { return }
        if plan.backend == saved.backend { feedPlan = plan; return }
        position = anchor
        await reload(preservingPosition: true)
    }
    private func rememberOriginal() {
        if originalTimeline == nil && !isFiltered && !showingResults {
            originalTimeline = SavedTimeline(buckets: remoteBuckets, assets: loaded, projections: projections, device: projectedDevice,
                                             position: position, title: title, plan: feedPlan)
        }
    }

    // MARK: - Sections and projections (F3)

    /// The grid's months from the server's and the phone's as projected: the sections, each one's
    /// month, the bucket the source reads for each month it has, and the feed's order, which it
    /// hears once per change. Projections of months no longer shown go; a month only the phone
    /// has that is new to the grid is projected. Cheap: nothing here reads a photo.
    private func refreshStructure() {
        let merging = mergesDevicePhotos
        buckets = merging ? projectedDevice.buckets(remote: remoteBuckets) : remoteBuckets
        remoteIDs = Set(remoteBuckets.map(\.id))
        monthKeys = buckets.map { monthKey($0.id) }
        monthBuckets = Dictionary(remoteBuckets.compactMap { bucket in monthKey(bucket.id).map { ($0, bucket.id) } },
                                  uniquingKeysWith: { first, _ in first })
        bucketOfMonth = Dictionary(buckets.map { (String($0.id.prefix(7)), $0.id) }, uniquingKeysWith: { first, _ in first })
        timelineSections = buckets.map { .init(id: $0.id, count: $0.count, title: title(of: $0)) }
        let shown = Set(buckets.map(\.id))
        for id in projections.keys where !shown.contains(id) { projections[id] = nil }
        for id in pendingLoads.keys where !shown.contains(id) { pendingLoads[id] = nil }
        for id in dirty.keys where !shown.contains(id) { dirty[id] = nil }
        if merging {
            for bucket in buckets where !remoteIDs.contains(bucket.id) && projections[bucket.id] == nil { markDirty(bucket.id, .device) }
        }
        structureVersion += 1
        let order = monthKeys.compactMap { $0 }
        if sentMonths?.order != order || sentMonths?.buckets != monthBuckets {
            sentMonths = (order, monthBuckets)
            send(.months(order, buckets: monthBuckets))
        }
    }

    private func markDirty(_ bucket: String, _ reason: ProjectionReason) {
        dirty[bucket, default: []].formUnion(reason)
    }

    /// Projects what changed, off the main actor: the months delivered or edited, and, after a
    /// snapshot, the months the phone's photos changed in (by digest) and, when the matches
    /// changed, every loaded month. One run at a time; the next takes everything that changed
    /// meanwhile. A snapshot waits while a feed is being replaced, for the feed that commits.
    private func project() {
        guard projecting == nil else { return }
        var months = dirty
        // The months shown, and those the snapshot adds: a month only the phone has, new to the grid.
        var shown = Set(buckets.map(\.id))
        let device: MergedTimeline? = deviceDirty && frozenFeed == nil ? deviceTimeline : nil
        if let device {
            deviceDirty = false
            if mergesDevicePhotos {
                for key in device.changedMonths(since: projectedDevice) {
                    let bucket = bucketOfMonth[key] ?? key + "-01"
                    months[bucket, default: []].insert(.device); shown.insert(bucket)
                }
            }
            if device.matchesDigest != projectedDevice.matchesDigest {
                for id in Set(loaded.keys).union(pendingLoads.keys) { months[id, default: []].insert(.device) }
            }
        }
        months = months.filter { shown.contains($0.key) }
        guard !months.isEmpty else {
            // A snapshot that changes no month, as discovery and fingerprint progress often publish.
            if let device { projectedDevice = device }
            dirty = [:]
            return
        }
        dirty = [:]
        let phone = device ?? projectedDevice, merging = mergesDevicePhotos
        var inputs: [MonthProjector.Input] = [], unprojected: [String] = []
        for bucket in months.keys {
            let remote = pendingLoads[bucket]?.assets ?? loaded[bucket]
            let phoneOnly = merging ? phone.phoneOnly(in: bucket) : []
            // A server month not loaded has no rows to show; a month only the phone has always does.
            guard remote != nil || (!remoteIDs.contains(bucket) && !phoneOnly.isEmpty) else { unprojected.append(bucket); continue }
            inputs.append(.init(bucket: bucket, remote: remote ?? [], phoneOnly: phoneOnly, matches: phone.remoteToLocal, merges: merging,
                                previous: projections[bucket]))
        }
        let version = structureVersion
        projecting = Task { [inputs, unprojected, months, device, version] in
            let results = await MonthProjector.project(inputs)
            self.apply(results, unprojected: unprojected, reasons: months, device: device, version: version)
        }
    }

    /// Shows a run's months: their rows (with the feed's delivery, for a loaded month), days and
    /// places, then the sections after a snapshot. A month changed again meanwhile is left to the
    /// next run, with this run's reasons for it; a server month the feed let go meanwhile stays
    /// gone. The phone's photos moving a row the grid shows restore its anchor, as before.
    private func apply(_ results: [MonthProjector.Result], unprojected: [String], reasons: [String: ProjectionReason],
                       device: MergedTimeline?, version: Int) {
        projecting = nil
        defer { project() }
        guard version == structureVersion else {
            // The feed or its months changed under the run: everything it took is asked again.
            for (bucket, reason) in reasons { markDirty(bucket, reason) }
            if device != nil { deviceDirty = true }
            return
        }
        // A month changed again during the run is the next run's, for this run's reasons as well:
        // a phone change this run carried still restores the anchor when that month's rows move.
        for (bucket, reason) in reasons where dirty[bucket] != nil { markDirty(bucket, reason) }
        var changed = false, rowsMoved = false, structureChanged = false, committed = 0
        for result in results where dirty[result.bucket] == nil {
            let id = result.bucket
            if let pending = pendingLoads[id] {
                pendingLoads[id] = nil
                guard pending.ticket == feedSession?.ticket, remoteIDs.contains(id) else { continue }
                loaded[id] = pending.assets; bucketErrors[id] = nil
                committed += 1
                if pending.fresh, let index = remoteBuckets.firstIndex(where: { $0.id == id }), remoteBuckets[index].count != pending.assets.count {
                    // FEED-5: the month's own count stands over the summary's, so a month smaller
                    // than its summary leaves no placeholder, and a larger one shows every photo.
                    structureChanged = true
                    if pending.assets.isEmpty { remoteBuckets.remove(at: index); loaded[id] = nil; projections[id] = nil; continue }
                    remoteBuckets[index] = TimeBucket(timeBucket: id, count: pending.assets.count)
                }
            }
            // A server month the feed let go during the run has no rows: its projection stays gone,
            // or it would outlive the twelve resident months, out of reach of removals and edits.
            guard loaded[id] != nil || !remoteIDs.contains(id) else { continue }
            if result.changed || projections[id] == nil {
                if result.rowsChanged, projections[id] != nil, reasons[id]?.contains(.device) == true { rowsMoved = true }
                projections[id] = result.projection; changed = true
            }
        }
        for id in unprojected where dirty[id] == nil && projections[id] != nil { projections[id] = nil; changed = true }
        if let device { projectedDevice = device }
        if device != nil || structureChanged {
            let before = timelineSections
            refreshStructure()
            if device != nil && before != timelineSections { rowsMoved = true }
        }
        if rowsMoved {
            // The grid keeps the photo it shows; a phone photo matched meanwhile is its server record now.
            if let anchor = position, buckets.contains(where: { $0.id == anchor.section }) {
                restorePosition = anchor
                if let id = anchor.assetID, id.hasPrefix("local:"), let remote = projectedDevice.localToRemote[String(id.dropFirst(6))] {
                    restorePosition?.assetID = remote
                }
            }
            resetID = UUID()
        }
        if changed || committed > 0 || structureChanged { revision += 1 }
        for _ in 0..<committed { FeedMonthProbe.committed() }
    }

    /// A month's rows merged with the phone's photos as published, off the main actor, for a
    /// selection or a date navigation; a feed that does not merge them lists the server's.
    private func mergedEntries(remote: [Asset], bucket: String) async -> [LibraryEntry] {
        guard mergesDevicePhotos else { return remote.map { .remote($0) } }
        let phone = deviceTimeline
        return await MonthProjector.merge(remote: remote, phoneOnly: phone.phoneOnly(in: bucket), matches: phone.remoteToLocal)
    }

    private func title(of bucket: TimeBucket) -> String {
        if let title = titles[bucket.id] { return title }
        let title = Self.monthTitle(bucket.date)
        titles[bucket.id] = title
        return title
    }
    private static func monthTitle(_ date: Date?) -> String {
        guard let date else { return "Library" }
        var style = Date.FormatStyle().month(.wide).year()
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }
}

/// Why a month is projected again: it was delivered by the feed, a record in it was edited or
/// removed, or the phone's photos changed. Only the phone's photos move the grid's anchor.
private struct ProjectionReason: OptionSet, Sendable {
    let rawValue: UInt8
    static let load = ProjectionReason(rawValue: 1)
    static let edit = ProjectionReason(rawValue: 2)
    static let device = ProjectionReason(rawValue: 4)
}

/// A month the feed delivered, waiting for its projection.
private struct PendingLoad {
    let ticket: TimelineFeed.Ticket
    var assets: [Asset]
    let fresh: Bool
}

extension LibraryStore: TimelineFeedConsumer {
    /// A month arrived. It is projected off the main actor and shown with its rows; the months
    /// let go to make room go now, as the grid cannot be on them.
    func monthLoaded(_ ticket: TimelineFeed.Ticket, month: MonthKey, assets: [Asset], fresh: Bool, evicting: [MonthKey]) {
        guard ticket == feedSession?.ticket, let id = monthBuckets[month] else { return }
        for evicted in evicting {
            guard let gone = monthBuckets[evicted], loaded[gone] != nil || pendingLoads[gone] != nil else { continue }
            loaded[gone] = nil; pendingLoads[gone] = nil; projections[gone] = nil; dirty[gone] = nil
        }
        pendingLoads[id] = PendingLoad(ticket: ticket, assets: assets, fresh: fresh)
        markDirty(id, .load)
        project()
    }

    func monthFailed(_ ticket: TimelineFeed.Ticket, month: MonthKey, message: String) {
        guard ticket == feedSession?.ticket, let id = monthBuckets[month] else { return }
        bucketErrors[id] = message
        revision += 1
    }
}

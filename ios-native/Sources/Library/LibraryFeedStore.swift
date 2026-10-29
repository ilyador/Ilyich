import Foundation
import UIKit
import Observation

/// A section of the grid: a month of the feed, or the search results.
struct LibrarySection: Identifiable, Equatable {
    /// The grid's name for it: the bucket its month's summary gave (YYYY-MM-01 for a month only
    /// the phone has), or "results".
    let id: String
    let count: Int
    let title: String
    /// The month it shows, by which the store and the feed know it (F6); nil for the results.
    let month: MonthKey?
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
/// One month of a feed's summary: the bucket the source reads it by, with its count, and the
/// month it is, read from the bucket once, when the summary arrives (F6).
private struct SummaryMonth: Equatable {
    let bucket: TimeBucket
    let month: MonthKey?
    var id: String { bucket.id }
    var count: Int { bucket.count }
    /// The same month counting otherwise.
    func counting(_ count: Int) -> SummaryMonth {
        SummaryMonth(bucket: TimeBucket(timeBucket: bucket.timeBucket, count: count), month: month)
    }
}
/// The feed shown while a new scope loads behind it (F4), frozen as it was. With the feed as it
/// stands, it is what the grid displays, and both are read the same way (`DisplayedFeed`).
private struct FrozenFeed {
    let sections: [LibrarySection]
    /// Its months' server photos, and the months as projected: rows, days and places.
    let rows: [MonthKey: [Asset]]
    let projections: [MonthKey: MonthProjector.Projection]
    /// The search results it showed, when it showed results rather than months.
    let results: [Asset]?
    let matches: [String: LocalPhoto]
    let totalCount: Int
    /// The frozen feed's own month places, not those of the filter on its way.
    let places: [String: [PlaceTally]]
}
/// The unfiltered library as it was left, to come straight back when a filter or search clears.
private struct SavedTimeline {
    let summary: [SummaryMonth]
    let rows: [MonthKey: [Asset]]
    /// Its months as projected, and the phone's photos they were projected with.
    let projections: [MonthKey: MonthProjector.Projection]
    let device: MergedTimeline
    let position: GridPosition?
    let title: String
    /// The plan its months came from; nil before the library ever loaded.
    let plan: QueryPlan?
}

/// What the grid displays (F6): the feed as it stands or, while a new scope loads behind it, the
/// frozen feed. The grid, the rail's lens, the month heading and the viewer read either one through
/// the same code, so what they show of the frozen feed and of the live one can't drift apart.
@MainActor private protocol DisplayedFeed {
    var shownSections: [LibrarySection] { get }
    /// The search results shown, when the feed shows results rather than months.
    var shownResults: [Asset]? { get }
    func shownRows(of month: MonthKey) -> [Asset]?
    func shownProjection(of month: MonthKey) -> MonthProjector.Projection?
    /// The phone's copy of a server photo, shown beside it.
    func shownMatch(_ id: String) -> LocalPhoto?
    /// The places the index counted in a month, by the month's section ID.
    func shownPlaces(of section: String) -> [PlaceTally]?
}

private extension DisplayedFeed {
    /// The month a section shows. Only for months: the results have none.
    func month(at index: Int) -> MonthKey? {
        let sections = shownSections
        return sections.indices.contains(index) ? sections[index].month : nil
    }

    /// A row of the grid, from its month's projection. A loaded month whose projection has not
    /// landed shows the server's rows in their order meanwhile.
    func displayedEntry(section: Int, item: Int) -> LibraryEntry? {
        if let results = shownResults {
            guard results.indices.contains(item) else { return nil }
            return .remote(results[item], local: shownMatch(results[item].id))
        }
        guard let month = month(at: section) else { return nil }
        if let entries = shownProjection(of: month)?.entries { return entries.indices.contains(item) ? entries[item] : nil }
        guard let rows = shownRows(of: month), rows.indices.contains(item) else { return nil }
        return .remote(rows[item], local: shownMatch(rows[item].id))
    }

    func displayedAsset(section: Int, item: Int) -> Asset? {
        if let results = shownResults { return results.indices.contains(item) ? results[item] : nil }
        guard let month = month(at: section), let rows = shownRows(of: month), rows.indices.contains(item) else { return nil }
        return rows[item]
    }

    func displayedDayGroups(section: Int) -> [TimelineDayGroup] {
        guard shownResults == nil, let month = month(at: section) else { return [] }
        return shownProjection(of: month)?.days ?? []
    }

    /// A month's places: its loaded photos' (computed in the projection), or else the index's
    /// count of them.
    func displayedPlaceSummary(section index: Int) -> String? {
        guard shownResults == nil else { return nil }
        let sections = shownSections
        guard sections.indices.contains(index) else { return nil }
        let section = sections[index]
        return section.month.flatMap { shownProjection(of: $0)?.placeSummary } ?? MonthPlaces.summary(shownPlaces(of: section.id))
    }

    /// The results' places when showing them, otherwise the month at `section`'s.
    func displayedPlaceSummary(around section: Int) -> String? {
        if let results = shownResults { return MonthProjector.placeSummary(of: results) }
        return displayedPlaceSummary(section: section)
    }

    /// Where a position is in the grid: the photo it names, wherever its month now puts it, or
    /// else its section and item, kept within the section.
    func displayedIndex(for position: GridPosition) -> (section: Int, item: Int)? {
        let sections = shownSections
        if let id = position.assetID {
            if let results = shownResults {
                if let item = results.firstIndex(where: { $0.id == id }) { return (0, item) }
            } else {
                for (index, section) in sections.enumerated() {
                    guard let month = section.month else { continue }
                    if let projection = shownProjection(of: month) {
                        if let item = projection.entries.firstIndex(where: { $0.id == id }) { return (index, item) }
                    } else if let item = shownRows(of: month)?.firstIndex(where: { $0.id == id }) {
                        return (index, item)
                    }
                }
            }
        }
        guard let index = sections.firstIndex(where: { $0.id == position.section }), sections[index].count > 0 else { return nil }
        return (index, min(position.item, sections[index].count - 1))
    }

    /// The server photos of a photo's month and the months beside it, for swiping in the viewer;
    /// the results, when showing them. Empty when the feed doesn't show the photo.
    func displayedAssets(around id: String) -> [Asset] {
        if let results = shownResults { return results }
        let months = shownSections.map(\.month)
        guard let index = months.firstIndex(where: { month in
            month.flatMap { shownRows(of: $0) }?.contains(where: { $0.id == id }) == true
        }) else { return [] }
        return months[max(0, index - 1)...min(months.count - 1, index + 1)].flatMap { month in month.flatMap { shownRows(of: $0) } ?? [] }
    }
}

extension FrozenFeed: DisplayedFeed {
    var shownSections: [LibrarySection] { sections }
    var shownResults: [Asset]? { results }
    func shownRows(of month: MonthKey) -> [Asset]? { rows[month] }
    func shownProjection(of month: MonthKey) -> MonthProjector.Projection? { projections[month] }
    func shownMatch(_ id: String) -> LocalPhoto? { matches[id] }
    func shownPlaces(of section: String) -> [PlaceTally]? { places[section] }
}

/// The library's feed (REBUILD_ROADMAP.md F6): what the grid displays, a new scope loading behind
/// it, the scope and its title, the search's verification, the errors, the scroll request and the
/// anchor to restore, the feeds' places, and the commands that change them. Its months come from
/// the TimelineFeed, keyed by month as the feed keys them, and are projected off the main actor
/// (MonthProjector); a search's pages come from its SearchFeed. What is selected is the
/// selection's (FeedSelection), which reads a whole month through this feed.
@MainActor @Observable final class LibraryFeedStore {
    /// Where the feed reads: the account's library repository.
    let source: any LibraryFeedSource
    /// The feed's months as the grid and the rail show them: the server's, with the phone's own
    /// months merged in for the library.
    var buckets: [TimeBucket] = []
    /// The server's photos of each month the feed has delivered, by month.
    var rows: [MonthKey: [Asset]] = [:]
    /// The server's months and their counts, as the summary gave them.
    private var summary: [SummaryMonth] = []
    /// The phone's photos as last published, for selection, the viewer and the next projection.
    private var deviceTimeline = MergedTimeline()
    /// The grid's months as projected off the main actor (F3): each month's rows, days and
    /// places. A loaded month and its projection land together; a month only the phone has is
    /// projected as soon as the grid knows it.
    private var projections: [MonthKey: MonthProjector.Projection] = [:]
    /// The phone's photos as the sections and projections reflect them.
    @ObservationIgnored private var projectedDevice = MergedTimeline()
    /// A snapshot arrived that the projections do not reflect yet.
    @ObservationIgnored private var deviceDirty = false
    /// Months to project again, and why.
    @ObservationIgnored private var dirty: [MonthKey: ProjectionReason] = [:]
    /// Months the feed delivered, shown with their rows once projected.
    @ObservationIgnored private var pendingLoads: [MonthKey: PendingLoad] = [:]
    /// The projection run on its way; one at a time, the next taking everything that changed meanwhile.
    @ObservationIgnored private var projecting: Task<Void, Never>?
    /// Moves whenever the months or the feed change under a run, which then applies nothing and starts over.
    @ObservationIgnored private var structureVersion = 0
    /// The months the server has in the feed shown.
    @ObservationIgnored private(set) var remoteMonths: Set<MonthKey> = []
    /// Each section's title, formatted once.
    @ObservationIgnored private var titles: [String: String] = [:]
    private let includesDevicePhotos: Bool
    var results: [Asset] = []
    var isLoading = false
    var isSearching = false
    var error: String?
    /// The months that failed to load, for the banner and its Retry.
    var failedMonths: [MonthKey: String] = [:]
    var title = "Library"
    /// Each feed's places, so a month has a name before its photos load (F5). They are kept per
    /// feed, so the places shown are always those of the feed shown, and clearing a filter brings
    /// the library's places straight back.
    let places: MonthPlacesService
    /// Each month's places in the feed shown, ranked.
    var monthPlaces: [String: [PlaceTally]] { places.places(of: feedQuery)?.months ?? [:] }
    /// Months spent abroad, named for the time rail.
    var trips: [String: String] { places.places(of: feedQuery)?.trips ?? [:] }
    var filterTitle: String?
    var query = ""
    /// The server's check of the results shown; nil unless a checked Photo content search returned them.
    var verification: Verification?
    var hasMore = false
    var revision = 0
    var resetID = UUID()
    var scrollRequest: ScrollRequest?
    var restorePosition: GridPosition?
    /// What is selected, and selecting a whole month through this feed (F6).
    let selection = FeedSelection()
    let navigation = TimelinePosition()
    /// What the feed shows. Its plan, made when the feed loads, serves every month it reads.
    private(set) var feedQuery = LibraryQuery.library
    /// The filters the feed shows, in the order chosen (N6): the feed is their AND. Empty for the
    /// library, and for a feed that is no layer: a partner's, similar photos, More's filtered
    /// library, or a feed given as a query of its own.
    private(set) var stack = FilterStack()
    /// How the feed shown is served, as of its last load; nil before then.
    private(set) var feedPlan: QueryPlan?
    /// What a search inside the feed shown searches: its scope, trash, visibility and filters.
    private(set) var searchScope = LibraryFeedStore.librarySearch {
        didSet { searchFilter = ServerSearchRequest.filter(for: searchScope) }
    }
    /// The search scope as Search options edit it.
    private(set) var searchFilter = ServerSearchRequest.filter(for: LibraryFeedStore.librarySearch)
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
    /// The feed's months, loaded off the main actor as the grid needs them (F2). `rows` and
    /// `failedMonths` hold what it delivers, by month as it names them; the grid reads them
    /// through its sections, each of which carries its month.
    @ObservationIgnored private let feed: TimelineFeed
    /// The months on screen, for the feed to read at once: the viewport command that follows
    /// them through the queue must not let a load that lands first evict a month just scrolled on.
    @ObservationIgnored private let feedViewport = TimelineFeed.Viewport()
    /// The feed open in it, shown or pending behind the frozen one: its ticket names every
    /// delivery, and its query and plan say whether a reload may keep the months on their way.
    @ObservationIgnored private var feedSession: FeedSession?
    /// The feed shown's ticket, for tests that deliver a month as the feed would.
    var feedTicket: TimelineFeed.Ticket? { feedSession?.ticket }
    /// Commands on their way to the feed, sent in order by one task. The month queue drives no
    /// view: observing it made SwiftUI update the grid on every scrolled frame.
    @ObservationIgnored private var feedCommands: [TimelineFeed.Command] = []
    @ObservationIgnored private var feedCommandTask: Task<Void, Never>?
    /// The months on screen as the feed was last told, so a scrolled frame or a repeated snapshot
    /// sends nothing.
    @ObservationIgnored private(set) var visibleMonths: Set<MonthKey>?
    /// The feed's months in the grid's order and the bucket the source reads each server month
    /// by, as the feed was last told.
    @ObservationIgnored private var sentMonths: (order: [MonthKey], reads: [MonthKey: String])?
    private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    private var generation = UUID()
    private var usesMetadata = false
    private var showingResults = false
    private var timelineSections: [LibrarySection] = []
    private var frozenFeed: FrozenFeed?
    private var searchGeneration = UUID()
    /// The library as it was left when a filter or search opened, patched by what changes
    /// meanwhile (F4).
    private var originalTimeline: SavedTimeline?
    /// The saved library's months a change touched meanwhile, and those it was yet to read again
    /// when it was left, read again once it is back; nil when a change named none and every month
    /// is read again.
    @ObservationIgnored private var savedStaleMonths: Set<MonthKey>? = []
    /// Months the open feed is yet to hear are stale: those a sync's change named, those a banner
    /// a reload took down named, and the saved library's once it is back. A reload tells the feed
    /// once it has its plan, so a newer reload that takes over meanwhile tells it with its own
    /// instead of losing them (F4). Nil is every month.
    @ObservationIgnored private var unsentStale: Set<MonthKey>? = []
    /// The months the store told the open feed to read again that it has not delivered fresh
    /// since, as the feed keeps them, so a filter opened meanwhile carries them into the saved
    /// library (F4).
    @ObservationIgnored private var feedStale: Set<MonthKey> = []
    @ObservationIgnored var position: GridPosition? {
        didSet { updateVisibleResultsTitle() }
    }
    @ObservationIgnored var started = false

    /// Without `places`, the feeds' places live in memory only, counted after `placesDelay`.
    init(source: any LibraryFeedSource, includesDevicePhotos: Bool = false, placesDelay: Duration = .seconds(3),
         choices: SearchChoicesStorage? = nil, places: MonthPlacesService? = nil,
         residentPhotoBudget: Int = TimelineFeed.residentPhotoBudget) {
        self.source = source; self.includesDevicePhotos = includesDevicePhotos
        self.places = places ?? MonthPlacesService(source: source, delay: placesDelay)
        choicesStorage = choices
        searchChoices = choices?.load() ?? SearchChoices()
        feed = TimelineFeed(source: source, viewport: feedViewport, residentPhotoBudget: residentPhotoBudget)
        send(.attach(self))
    }
    private var mergesDevicePhotos: Bool { includesDevicePhotos && !isFiltered && !showingResults && feedQuery == .library }
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

    // MARK: - What the grid displays

    func restoredIndex(for position: GridPosition) -> (section: Int, item: Int)? {
        if let frozenFeed { return frozenFeed.displayedIndex(for: position) }
        return displayedIndex(for: position)
    }

    private var liveSections: [LibrarySection] {
        if showingResults { return [.init(id: "results", count: results.count, title: query.isEmpty ? filterTitle ?? "Library" : "Search", month: nil)] }
        return timelineSections
    }
    var sections: [LibrarySection] { frozenFeed?.sections ?? liveSections }
    var totalCount: Int { frozenFeed?.totalCount ?? (showingResults ? results.count : buckets.reduce(0) { $0 + $1.count }) }
    var isReplacingFeed: Bool { frozenFeed != nil }
    var isFiltered: Bool { filterTitle != nil || !query.isEmpty }

    /// Place summary for one month: its loaded photos' (computed in the projection), or else the
    /// local index's count of them.
    func placeSummary(section: Int) -> String? {
        if let frozenFeed { return frozenFeed.displayedPlaceSummary(section: section) }
        return displayedPlaceSummary(section: section)
    }

    /// The places of a whole year, for the rail's year lens, worked out once per count.
    func placeSummary(year: Int) -> String? { places.places(of: feedQuery)?.years[year] }

    /// Shows the feed's places: the copy kept on the phone at once, and a fresh count once its
    /// first months are in (MonthPlacesService).
    private func loadMonthPlaces(_ query: LibraryQuery, plan: QueryPlan) { places.show(query, plan: plan) }
    /// Search/filter results when showing them, otherwise the month under the viewport.
    var currentPlaceSummary: String? {
        if let frozenFeed { return frozenFeed.displayedPlaceSummary(around: navigation.section) }
        return displayedPlaceSummary(around: navigation.section)
    }

    /// A row of the grid, from its month's projection. A loaded month whose projection has not
    /// landed shows the server's rows in its order meanwhile.
    func entry(section: Int, item: Int) -> LibraryEntry? {
        if let frozenFeed { return frozenFeed.displayedEntry(section: section, item: item) }
        return displayedEntry(section: section, item: item)
    }

    func dayGroups(section: Int) -> [TimelineDayGroup] {
        if let frozenFeed { return frozenFeed.displayedDayGroups(section: section) }
        return displayedDayGroups(section: section)
    }

    func asset(section: Int, item: Int) -> Asset? {
        if let frozenFeed { return frozenFeed.displayedAsset(section: section, item: item) }
        return displayedAsset(section: section, item: item)
    }
    /// The photos the viewer pages through around the photo `id`, as the grid shows them
    /// (AssetWindowProvider.feed): empty when the grid doesn't show it.
    func availableAssets(around id: String) -> [Asset] {
        if let frozenFeed { return frozenFeed.displayedAssets(around: id) }
        return displayedAssets(around: id)
    }

    /// Everything on this phone in the photo's month and the months beside it, in the order the grid
    /// shows them, for swiping in the local viewer.
    func availableLocalPhotos(around photo: LocalPhoto) -> [LocalPhoto] {
        let sections = self.sections
        func phonePhotos(_ section: Int) -> [LocalPhoto] { (0..<sections[section].count).compactMap { entry(section: section, item: $0)?.local } }
        guard let i = sections.indices.first(where: { phonePhotos($0).contains { $0.id == photo.id } }) else { return [photo] }
        return (max(0, i - 1)...min(sections.count - 1, i + 1)).flatMap(phonePhotos)
    }

    // MARK: - Selection

    // The selection's, for the grid, the selection bar and the month menu.
    var selected: Set<String> {
        get { selection.selected }
        set { selection.selected = newValue }
    }
    var isSelecting: Bool {
        get { selection.isSelecting }
        set { selection.isSelecting = newValue }
    }
    /// A whole month is being read to be selected or deselected.
    var isSelectingGroup: Bool { selection.isSelectingMonth }
    var selectedAssets: [Asset] { selection.assets(among: { results + rows.values.joined() }) }
    var selectedLocalPhotos: [LocalPhoto] { selection.localPhotos }
    var selectedDevicePhotos: [LocalPhoto] { selection.devicePhotos }
    func toggleSelection(_ asset: Asset) { selection.toggle(asset) }
    func select(_ asset: Asset) { selection.select(asset) }
    func toggleSelection(_ entry: LibraryEntry) { selection.toggle(entry) }
    func select(_ entry: LibraryEntry) { selection.select(entry) }
    func changeSelection(adding: [LibraryEntry], removing: [LibraryEntry]) { selection.change(adding: adding, removing: removing) }

    /// Selects or deselects the month under the viewport, whole: the selection reads it through
    /// the feed, so a virtualized grid or a month the feed let go never selects only the photos at
    /// hand.
    func selectMonth(_ selecting: Bool) {
        guard !isReplacingFeed, !showingResults, timelineSections.indices.contains(navigation.section) else { return }
        let section = timelineSections[navigation.section], current = generation
        selection.selectMonth(selecting, reading: { [weak self] in
            try await self?.entries(of: section, generation: current)
        }, failed: { [weak self] error in
            guard let self, generation == current else { return }
            self.error = error.localizedDescription
        })
    }

    /// Every photo of a section's month, for selecting it whole: the feed's copy of its server
    /// photos, or the month read now (a month only the phone has needs no read), merged with the
    /// phone's photos off the main actor. Nil once the feed has moved on.
    private func entries(of section: LibrarySection, generation current: UUID) async throws -> [LibraryEntry]? {
        var assets: [Asset] = []
        if let month = section.month, remoteMonths.contains(month) { assets = try await self.assets(of: month) }
        try Task.checkCancellation()
        guard generation == current else { return nil }
        let entries = await mergedEntries(remote: assets, bucket: section.id)
        try Task.checkCancellation()
        guard generation == current else { return nil }
        return entries
    }

    var canSelectMonth: Bool { !showingResults && timelineSections.indices.contains(navigation.section) }
    var canScrubTimeline: Bool { !isReplacingFeed && !showingResults && !buckets.isEmpty }

    // MARK: - Loading the feed

    /// Reads the feed shown again. `preservingPosition` is a sync's or a refresh's reload: the grid
    /// keeps its place and, while the query and plan stand, the feed keeps its session and the
    /// months on their way. `invalidating` names the months it reads again when the grid wants
    /// them, every month when nil; a typed change names only those it touched (F4).
    func reload(preservingPosition: Bool = false, invalidating months: Set<MonthKey>? = nil) async {
        selection.cancelMonthSelection()
        queryTask?.cancel()
        searchGeneration = UUID(); isSearching = false
        generation = UUID(); let current = generation
        // The banner goes, so the months it named are asked for again with the rest (F2).
        let failed = Set(failedMonths.keys)
        isLoading = true; error = nil; failedMonths = [:]
        if preservingPosition {
            // A feed pending behind a frozen one opens at its top: the position is the frozen feed's.
            restorePosition = frozenFeed == nil ? position : nil
            // Owed to the feed until a reload has its plan: this one, or a newer one taking over.
            owe(months.map { $0.union(failed) })
        } else {
            // The feed starts over: its months are dropped and a new one opens once planned. With
            // nothing projected yet, the phone's latest photos place the months.
            cancelRequests()
            summary = []; buckets = []; rows = [:]; projections = [:]; dirty = [:]
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
            // The months this reload told the feed it keeps are stale; nil when it keeps none, or
            // told it every month is.
            let told: Set<MonthKey>?
            if preservingPosition, let session = feedSession, session.query == query, session.plan == plan {
                // A sync's reload of the feed shown: the months owed to it are stale and read again
                // when the grid wants them, shown meanwhile; a month on its way keeps coming.
                told = unsentStale
                tellUnsentStale()
            } else {
                openFeed(query, plan: plan)
                told = nil
            }
            let response = try await source.summary(query, plan: plan)
            guard generation == current else { return }
            let previousSections = timelineSections
            summary = summaryMonths(response)
            if let told {
                // A month the summary counts otherwise than its rows, which no change named, is
                // read again too, so no placeholder stays (FEED-5).
                let counts = Dictionary(summary.compactMap { entry in entry.month.map { ($0, entry.count) } }, uniquingKeysWith: { first, _ in first })
                let miscounted = Set(rows.compactMap { month, assets in counts[month] == assets.count ? nil : month }).subtracting(told)
                if !miscounted.isEmpty { markStale(miscounted) }
            }
            loadMonthPlaces(query, plan: plan)
            refreshStructure(); project()
            // While a feed is pending the grid shows the frozen one, which these sections don't move.
            if preservingPosition && frozenFeed == nil && previousSections != timelineSections { resetID = UUID() }
            // Background sync keeps the viewport heading; scrolling/restoration
            // publishes a new visible month if the returned sections move it.
            if !preservingPosition && frozenFeed == nil { title = Self.monthTitle(buckets.first?.date) }
            revision += 1
            if preservingPosition, let anchor = restorePosition, let index = timelineSections.firstIndex(where: { $0.id == anchor.section }) {
                requestBucket(index)
                if index + 1 < timelineSections.count { requestBucket(index + 1) }
            }
            for index in 0..<min(FeedSession.firstMonths, timelineSections.count) { requestBucket(index) }
            if frozenFeed != nil, let readiness = await settlePendingFeed(current) {
                if case .failed(let message) = readiness {
                    // The feed shown stays, with Retry and Clear.
                    error = message
                } else {
                    if !preservingPosition { title = Self.monthTitle(buckets.first?.date) }
                    commitFrozenFeed()
                }
            }
        } catch is CancellationError {} catch { if generation == current { self.error = error.localizedDescription } }
    }

    /// A summary's months, each read from its bucket once: a month the summary shown already had
    /// keeps the month read then, so a sync's summary reads none of them again.
    private func summaryMonths(_ buckets: [TimeBucket]) -> [SummaryMonth] {
        let known = Dictionary(summary.map { ($0.id, $0.month) }, uniquingKeysWith: { first, _ in first })
        return buckets.map { SummaryMonth(bucket: $0, month: known[$0.id] ?? MonthKey(bucketID: $0.id)) }
    }

    /// Asks the feed for a month by name, behind what the grid shows. The grid itself never asks:
    /// its months come from the viewport.
    func requestBucket(_ section: Int) {
        guard !showingResults, timelineSections.indices.contains(section), let month = timelineSections[section].month,
              remoteMonths.contains(month) else { return }
        send(.request([month]))
    }

    /// Actual viewport membership, including months that share the same visible row. The feed
    /// hears of it only when the months on screen change, not on every scrolled frame.
    func visibleSections(_ indices: Set<Int>) {
        let sections = timelineSections
        let months = Set(indices.compactMap { sections.indices.contains($0) ? sections[$0].month : nil })
        guard months != visibleMonths else { return }
        visibleMonths = months
        feedViewport.show(months)
        send(.viewport(visible: months))
    }

    func visibleSection(_ index: Int, visible: Set<Int>? = nil) {
        if isReplacingFeed || showingResults { return }
        // This runs on every scrolled frame; the sections already carry each month's title.
        guard timelineSections.indices.contains(index) else { return }
        let next = timelineSections[index].title
        if title != next { title = next }
        visibleSections(visible ?? [index])
    }

    /// Rail jump: the section already exists, so only its data and a fresh scroll request are needed.
    func scrollToBucket(_ index: Int, item: Int = 0) {
        guard !isReplacingFeed, !showingResults, timelineSections.indices.contains(index) else { return }
        cancelPendingNavigation()
        let section = timelineSections[index]
        if let month = section.month { send(.target(month)) }
        let item = min(max(0, item), max(0, section.count - 1))
        scrollRequest = ScrollRequest(position: GridPosition(section: section.id, item: item, offset: 0))
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
        // Every filter stacked goes with the feed (N6), as Clear takes them.
        feedQuery = .library; searchScope = Self.librarySearch; stack = FilterStack()
        filterTitle = nil; query = ""; results = []; showingResults = false; usesMetadata = false; choiceBrowse = nil
        originalTimeline = nil; scrollRequest = nil
        let restoreSaved = !reuseTimeline && saved?.summary.isEmpty == false && saved?.plan != nil
        if restoreSaved, let saved, let plan = saved.plan { restoreTimeline(saved, plan: plan); revision += 1 }
        if reuseTimeline || restoreSaved { commitFrozenFeed() }
        let date = asset.localDateTime ?? asset.fileCreatedAt
        navigationTask = Task {
            if !reuseTimeline && !restoreSaved { await reload() }
            if restoreSaved, let plan = saved?.plan { await revalidateRestoredLibrary(plan, anchor: saved?.position) }
            // The restored library has its months even when checking it against the source failed.
            guard !Task.isCancelled, restoreSaved || error == nil else { return }
            let current = generation
            guard let date, let index = nearestBucket(to: date), timelineSections.indices.contains(index) else {
                error = "Couldn't find this photo's date in the timeline."; return
            }
            let section = timelineSections[index]
            // The month is the feed's target, protected and first in line; its load is joined,
            // not polled for. A month only the phone has needs no load.
            var assets: [Asset] = []
            if let month = section.month, remoteMonths.contains(month) {
                send(.target(month))
                do { assets = try await self.assets(of: month) }
                catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, generation == current else { return }
                    self.error = "Couldn't load photos for that date."; return
                }
            }
            guard !Task.isCancelled, generation == current else { return }
            let entries = await mergedEntries(remote: assets, bucket: section.id)
            guard !Task.isCancelled, generation == current else { return }
            let distance = { (entry: LibraryEntry) in abs(entry.date.timeIntervalSince(date)) }
            guard let target = entries.first(where: { $0.id == asset.id }) ?? entries.min(by: { distance($0) < distance($1) }),
                  let item = entries.firstIndex(where: { $0.id == target.id }) else {
                error = "Couldn't load photos for that date."; return
            }
            scrollRequest = ScrollRequest(position: GridPosition(section: section.id, item: item, offset: 0, assetID: target.id))
        }
    }

    private func nearestBucket(to date: Date) -> Int? {
        let month = MergedTimeline.monthKey(date)
        if let exact = buckets.firstIndex(where: { $0.id.hasPrefix(month) }) { return exact }
        return buckets.indices.compactMap { index in buckets[index].date.map { (index, abs($0.timeIntervalSince(date))) } }
            .min { $0.1 < $1.1 }?.0
    }

    /// The banner's Retry: the months that failed are asked for again as the grid wants them. A
    /// feed pending behind the frozen one is loaded again whole, as the other banner's Retry does,
    /// so it replaces the frozen feed once its first months are in (F4).
    func retryFailedBuckets() {
        if frozenFeed != nil, !showingResults, query.isEmpty { scheduleReload(); return }
        failedMonths = [:]; revision += 1
        send(.retryFailed)
    }

    // MARK: - Scope

    /// Shows a person's photos alone, as a link or the viewer asks; the shelves add them instead.
    func setPerson(_ person: Person) {
        open(FilterStack([.collection(.person(person))]))
    }

    /// Shows an album alone, in its own order, as a link or the viewer asks; the shelves add it instead.
    func setAlbum(_ album: Album) {
        open(FilterStack([.collection(.album(album))]))
    }

    /// Adds a layer to the filters shown (N6): the feed narrows to it as well, by AND. A layer
    /// already there stays as it is, and a new place takes the place of the one there. A feed that
    /// is no layer (a partner's, similar photos, More's filtered library) gives way to it. A search
    /// typed ends, as choosing a filter always ended it.
    func add(_ layer: FilterLayer) {
        if case .place(let membership, _) = layer, membership.assetIDs.isEmpty { return }
        var next = stack
        guard next.add(layer) else {
            // Already shown: only a search typed ends.
            if !query.isEmpty { search("") }
            return
        }
        open(next)
    }

    /// Removes only one layer (N6). The others stay, and so does a search typed in them or More's
    /// filtered view of them, which run again in what is left; the last layer gone brings the
    /// library back, as Clear does, or keeps the search or the filtered view, now of the library.
    func remove(_ id: String) {
        var next = stack
        guard next.remove(id) else { return }
        open(next, keepingSearch: true)
    }

    /// Shows the feed `next` makes. The saved library is kept for Clear; the feed shown stays on
    /// screen, frozen, until the new one is ready. `keepingSearch` runs a search typed, or More's
    /// filtered view, again in it; with neither, no layer left brings the saved library back.
    private func open(_ next: FilterStack, keepingSearch: Bool = false) {
        let browsing = keepingSearch && choiceBrowse != nil
        let searching = keepingSearch && (!query.isEmpty || browsing)
        if next.isEmpty && !searching { return clearFilters() }
        rememberOriginal()
        beginScopeChange()
        stack = next
        feedQuery = next.query; searchScope = next.searchScope; filterTitle = next.title
        showingResults = false; usesMetadata = false
        // More's filtered view comes back over the feed left, with no layer as the filtered library.
        choiceBrowse = browsing ? (next.title, false) : nil
        guard searching else {
            query = ""
            return scheduleReload()
        }
        if browsing && query.isEmpty {
            if filterTitle == nil { filterTitle = "Filtered library" }
            usesMetadata = true; showingResults = true
        }
        queryTask = Task { await loadResults(.first) }
    }

    /// A place's photos are laid out by month, as a person's are, so the rail, the months' places
    /// and the trips work there too. Until the offline library is readable the planner serves a
    /// place by search, as one list.
    func setPlace(id: String, assetIDs: [String], title: String) {
        guard !assetIDs.isEmpty else { return }
        setPlace(PlaceMembership(placeID: id, assetIDs: assetIDs, markerQuery: ""), title: title)
    }

    /// A place alone, known by its membership revision; the Earth adds one instead.
    func setPlace(_ place: PlaceMembership, title: String) {
        guard !place.assetIDs.isEmpty else { return }
        open(FilterStack([.place(place, title: title)]))
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

    /// A search filter shown as one list of results, which is no layer of the stack.
    func setMetadataFilter(_ filter: SearchFilter, title: String, developedOnly: Bool = false) {
        rememberOriginal()
        beginScopeChange(); choiceBrowse = nil
        stack = FilterStack()
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

    /// A feed alone: one of More's collections (Favorites, Archive, Trash, Recently taken or added,
    /// Lightroom, Videos, Motion) as a layer of its own, or a partner's feed, which is no layer.
    func setFeed(_ query: LibraryQuery, title: String) {
        if let collection = LibraryCollection.more(showing: query), collection.title == title {
            return open(FilterStack([.collection(collection)]))
        }
        rememberOriginal()
        beginScopeChange(); choiceBrowse = nil
        stack = FilterStack()
        feedQuery = query; filterTitle = title; self.query = ""; showingResults = false; usesMetadata = false
        // A search inside the feed keeps its scope, trash, visibility and filters.
        searchScope = query
        scheduleReload()
    }

    /// Every filter goes (N6's Clear, and a pill's X on the last one): the library comes back where
    /// it was left, and a search typed ends.
    func clearFilters() {
        beginScopeChange(); feedQuery = .library; searchScope = Self.librarySearch; choiceBrowse = nil
        stack = FilterStack()
        filterTitle = nil; query = ""; verification = nil; showingResults = false; usesMetadata = false
        selection.clear()
        if let saved = originalTimeline, let plan = saved.plan {
            cancelRequests(); generation = UUID(); searchGeneration = UUID()
            restoreTimeline(saved, plan: plan)
            restorePosition = saved.position; frozenFeed = nil; resetID = UUID(); revision += 1
            // The phone's photos that changed while the filter showed are merged in now, as at a
            // commit: the restore ran while the filter was still frozen, so it could not take them.
            project()
            error = nil; isLoading = false; isSearching = false; originalTimeline = nil
            // The library's places come back with it, unless they were never counted.
            if places.places(of: feedQuery) == nil { loadMonthPlaces(feedQuery, plan: plan) }
            // Then it is checked against the source: counted again, and its months read again as
            // the grid wants them, so what changed while the filter showed reaches it (F4).
            let anchor = saved.position, current = generation
            Task { guard generation == current else { return }; await revalidateRestoredLibrary(plan, anchor: anchor) }
        } else {
            // A library that never loaded is loaded now, and saved again by the next filter.
            originalTimeline = nil
            scheduleReload()
        }
    }

    // MARK: - Search

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
        stack = FilterStack()
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
        // The stacked feed itself, when only search serves it, keeps to the photos the index and
        // the server timeline show of it (N6): partners are not in the library yet.
        let stackedFeed = !stack.isEmpty && text.isEmpty && choiceBrowse == nil && similarAssetID == nil
        return try ServerSearchRequest(scope, userID: source.userID, checksContent: similarAssetID == nil && searchChoices.verifiesText,
                                       keepsToOwnPhotos: stackedFeed && QueryPlanner.keepsToOwnPhotos(feedQuery))
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

    // MARK: - Changes

    /// A photo's fresh record, from the viewer or its details (F4). The saved library keeps its
    /// place: it takes the record, or loses the photo when the record takes it out of the library
    /// (archived, locked, put in Trash). In the feed shown the record decides the same way
    /// (FeedMembership): a photo it takes out leaves in place, the grid keeping where it is, and
    /// any other shows its new record. What the record can't tell (an album, a person, a place, a
    /// search) the sync's change reconciles by reading the photo's month again.
    func update(_ asset: Asset) {
        let now = ContinuousClock.now
        if let saved = originalTimeline {
            if FeedMembership.of(asset, in: .library, userID: source.userID) == .excluded {
                originalTimeline = saved.removing([asset.id])
                send(.withhold([asset.id], from: .query(.library), at: now))
            } else {
                originalTimeline = saved.replacing(asset)
            }
        }
        if let shown = shownQuery, FeedMembership.of(asset, in: shown, userID: source.userID) == .excluded {
            // Out of the feed shown as well as the library saved: the feed keeps it out of both.
            if !showingResults { send(.withhold([asset.id], from: .query(shown), at: now)) }
            removeRows([asset.id])
            return
        }
        if let i = results.firstIndex(where: { $0.id == asset.id }) {
            results[i] = asset
            if let feed = searchFeed { Task { await feed.replace(asset) } }
        }
        // Only the photo's month is projected again, off the main actor; the record shows at once.
        for month in Array(rows.keys) {
            if let i = rows[month]?.firstIndex(where: { $0.id == asset.id }) { rows[month]?[i] = asset; markDirty(month, .edit) }
        }
        for month in Array(pendingLoads.keys) {
            if let i = pendingLoads[month]?.assets.firstIndex(where: { $0.id == asset.id }) { pendingLoads[month]?.assets[i] = asset; markDirty(month, .edit) }
        }
        send(.replace(asset))
        revision += 1
        project()
    }
    /// Takes photos out of the feed at once, before the server's refresh confirms it, so a deleted
    /// photo can't be opened while that is on its way. The saved library loses them too and keeps
    /// its place (F4), and no month read before the server's change can bring them back: a photo
    /// deleted, locked or restored from Trash leaves every feed with the trash state it had.
    func removeLocally(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        originalTimeline = originalTimeline?.removing(ids)
        send(.withhold(ids, from: .trash(shownQuery?.trash ?? feedQuery.trash), at: .now))
        removeRows(ids)
    }

    /// The query of what the grid shows: the feed's, or the search's; nil before a search has one.
    private var shownQuery: LibraryQuery? {
        guard showingResults else { return feedQuery }
        return searchFeed?.request.search.query
    }

    /// Takes photos out of what the grid shows, in place: search results, and the feed's rows,
    /// whose months are redone off the main actor and count fewer; a month left with nothing goes
    /// whole. The grid keeps where it is.
    private func removeRows(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if let feed = searchFeed {
            removedResultIDs.formUnion(ids)
            Task { await feed.prune(ids) }
        }
        results.removeAll { ids.contains($0.id) }
        send(.remove(ids))
        var removed: [MonthKey: Int] = [:]
        for month in Array(rows.keys) {
            let before = rows[month]?.count ?? 0
            rows[month]?.removeAll { ids.contains($0.id) }
            let gone = before - (rows[month]?.count ?? 0)
            guard gone > 0 else { continue }
            removed[month] = gone
            // The rows go at once; the month's days are redone off the main actor.
            projections[month] = projections[month]?.removing(ids)
            markDirty(month, .edit)
        }
        for month in Array(pendingLoads.keys) {
            let before = pendingLoads[month]?.assets.count ?? 0
            pendingLoads[month]?.assets.removeAll { ids.contains($0.id) }
            if before != pendingLoads[month]?.assets.count { markDirty(month, .edit) }
        }
        if !removed.isEmpty {
            summary = summary.compactMap { entry in
                guard let month = entry.month, let gone = removed[month] else { return entry }
                return entry.count > gone ? entry.counting(entry.count - gone) : nil
            }
            // A month with nothing left goes whole.
            let kept = Set(summary.compactMap(\.month))
            for month in removed.keys where !kept.contains(month) { rows[month] = nil }
            refreshStructure()
        }
        revision += 1
        project()
    }
    /// Brings the feed up to date after a change made here. The saved library stays: the change
    /// the sync publishes patches it (F4). The sync begins reading the server after this call, so
    /// once it has run the photos taken out here before the call are as the source has them: their
    /// months are trusted again and read again, and a photo taken out that is still there (a
    /// stack's cover after a stack change) comes back. One taken out after the call waits for a
    /// later sync. When the sync fails, the next change a sync publishes confirms them.
    func refreshAfterMutation() async {
        let asked = ContinuousClock.now
        do {
            let change = try await source.refresh()
            send(.confirm(heldBy: change?.syncedThrough ?? asked))
            // A change the pass found was published, and LibraryView applies it to the feed unless a
            // search is showing. Reloading here as well would load every month twice.
            if let change, !change.isEmpty, query.isEmpty { return }
            await reload(preservingPosition: true)
        }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    /// A change the account's sync published (F4). What it removed, or what the account may no
    /// longer see, leaves at once, here and in the saved library, and no month read before the
    /// change brings it back. The months it touched are read again when the grid wants them,
    /// shown meanwhile, and the feed is counted again; the saved library's are read again once a
    /// filter clears back to it. A change that names no item one by one (a reset, an overflow), or
    /// that changes how feeds are served or what a stack or partner shows, reads every month
    /// again. A text search is not read again, as before: its results drop what went, and a photo
    /// they show that the change names takes its record from the offline library, so one put in
    /// Trash elsewhere leaves them too.
    func apply(_ change: LibraryChange) async {
        prune(change)
        let gone = change.removed.union(change.accessLost)
        // Those it took out stay out of any month read before it.
        if !gone.isEmpty { send(.forget(gone)) }
        // The photos taken out here before its pass began reading the server are as the source
        // now has them, whether it names them or not; one taken out later waits for a later pass.
        if let synced = change.syncedThrough { send(.confirm(heldBy: synced)) }
        let named = Set(change.upserted.keys).union(gone).union(change.mediaRevisions.keys)
        let everything = change.reset || change.overflow || change.routingChanged || change.configurationChanged
            || change.partnersChanged || !change.stacks.isEmpty
        if change.reset || change.overflow {
            // Anything it held may be gone: a filter clears back to the library read afresh.
            originalTimeline = nil
        } else if originalTimeline != nil {
            if !gone.isEmpty { originalTimeline = originalTimeline?.removing(gone) }
            if everything { savedStaleMonths = nil }
            else { savedStaleMonths?.formUnion(Self.months(touchedBy: change, in: originalTimeline?.rows ?? [:])) }
        }
        guard query.isEmpty else { return await recheckResults(named: Set(change.upserted.keys)) }
        if showingResults {
            // Results are read again, as before, unless the change touched no photo, album or person.
            if !named.isEmpty || everything || !change.albums.isEmpty || !change.people.isEmpty { await reload(preservingPosition: true) }
            return
        }
        removeRows(gone)
        // An album or a person can lose photos without their months being named (an album or a
        // person deleted, faces merged): such a feed reads all its months again.
        let scoped = !feedQuery.predicates.albums.isDisjoint(with: change.albums) || !feedQuery.predicates.people.isDisjoint(with: change.people)
        if everything || scoped { await reload(preservingPosition: true); return }
        let months = Self.months(touchedBy: change, in: rows)
        if !change.upserted.isEmpty || !gone.isEmpty { await reload(preservingPosition: true, invalidating: months) }
        else if !months.isEmpty { markStale(months) }
    }

    /// Photos a text search shows that a sync's change names, checked against their records in the
    /// offline library (G1): the change says only that they changed, and a photo put in Trash or
    /// hidden elsewhere comes as such a change, not as a removal. Each record decides as
    /// a viewer's does (FeedMembership): a photo out of the search leaves in place, and any other
    /// shows its record. A search that was replaced meanwhile takes none.
    private func recheckResults(named ids: Set<String>) async {
        guard showingResults, let feed = searchFeed, !ids.isEmpty else { return }
        let shown = ids.intersection(results.map(\.id))
        guard !shown.isEmpty else { return }
        let session = generation
        let records = await source.records(shown)
        guard generation == session, searchFeed === feed, showingResults else { return }
        for record in records where shown.contains(record.id) { update(record) }
    }

    /// A change to the account's collections (N4). An album that was deleted or left leaves the
    /// filters (N6): alone, the filter clears back to the library; stacked, only its layer goes. An
    /// album or a person renamed while the feed shows it gives its layer the new name, and an album
    /// whose photos' order changed is read again in that order. A partner added or removed, or shown
    /// in the timeline or no longer, reads the feed again, as a sync's partner change does, and the
    /// saved library once a filter clears back to it. Returns whether the filter cleared.
    @discardableResult
    func apply(_ change: CollectionChange) -> Bool {
        switch change {
        case .albumDeleted(let id), .albumLeft(let id):
            let layer = LibraryCollection.albumRowID(id)
            guard stack.contains(layer) else { return false }
            guard stack.layers.count > 1 else { clearFilters(); return true }
            remove(layer)
            return false
        case .albumUpdated(let album):
            var next = stack
            guard next.update(.collection(.album(album))) else { return false }
            if query.isEmpty, next.query != feedQuery { open(next) }
            else { stack = next; filterTitle = next.title; feedQuery = next.query; searchScope = next.searchScope }
            return false
        case .personUpdated(let person):
            var next = stack
            guard next.update(.collection(.person(person))) else { return false }
            stack = next; filterTitle = next.title
            return false
        case .partnersChanged:
            if originalTimeline != nil { savedStaleMonths = nil }
            if query.isEmpty { Task { await reload(preservingPosition: true) } }
            return false
        case .albumCreated, .memorySaved:
            return false
        }
    }

    /// The months a change touched among those `rows` hold: those its photos left and joined, and
    /// those holding a photo whose media changed.
    private static func months(touchedBy change: LibraryChange, in rows: [MonthKey: [Asset]]) -> Set<MonthKey> {
        var months = Set<MonthKey>()
        for move in change.upserted.values {
            if let from = move.from { months.insert(from) }
            if let to = move.to { months.insert(to) }
        }
        if !change.mediaRevisions.isEmpty {
            for (month, assets) in rows where assets.contains(where: { change.mediaRevisions[$0.id] != nil }) { months.insert(month) }
        }
        return months
    }

    // MARK: - Feed sessions (F4)

    /// Waits until the pending feed's first months have come to something (F4): each server month
    /// is joined, queued or not (FEED-3), and its rows land with their projection; a month only
    /// the phone has is ready as it is (FEED-2). The first months are worked out again after each
    /// round, since a month that came back empty leaves the feed (FEED-5) and the next takes its
    /// place. Nil once a newer load or scope has taken over.
    private func settlePendingFeed(_ current: UUID) async -> FeedSession.Readiness? {
        var readiness = FeedSession.Readiness.waiting
        for _ in 0..<3 {
            for month in firstMonths().compactMap(\.join) { _ = try? await assets(of: month) }
            await settleProjections()
            guard generation == current else { return nil }
            readiness = FeedSession.readiness(firstMonths().map(\.state))
            guard readiness == .waiting else { return readiness }
        }
        // Every load joined has ended without a failure, yet a first month has no rows (a load the
        // feed dropped, months emptying one after another): the feed shows, and those months load
        // as the grid shows them, rather than the grid staying frozen with nothing on its way.
        return readiness
    }

    /// The first months of the feed being loaded, and for each one still loading, the month to join.
    private func firstMonths() -> [(state: FeedSession.Month, join: MonthKey?)] {
        timelineSections.prefix(FeedSession.firstMonths).map { section in
            guard let month = section.month else { return (.loading, nil) }
            // A month that failed while the server had it, and is the phone's alone now, has nothing to wait for.
            guard remoteMonths.contains(month) else { return (.phoneOnly, nil) }
            if let message = failedMonths[month] { return (.failed(message), nil) }
            if rows[month] != nil { return (.loaded, nil) }
            return (.loading, month)
        }
    }

    /// Closes the feed: its loads stop and nothing it delivers after is shown. Commands still
    /// queued go first, in order; they belong to the feed being closed, and `close` undoes them.
    private func cancelRequests() {
        feedSession = nil; visibleMonths = nil; sentMonths = nil; feedViewport.show([])
        pendingLoads = [:]; structureVersion += 1
        unsentStale = []; feedStale = []
        send(.close)
    }

    /// Opens a feed for `query` as `plan` serves it. Every delivery carries its ticket. Its
    /// months are as it reads them: none is stale.
    private func openFeed(_ query: LibraryQuery, plan: QueryPlan) {
        let session = FeedSession(query, plan: plan)
        feedSession = session
        visibleMonths = nil; sentMonths = nil; feedViewport.show([])
        unsentStale = []; feedStale = []
        send(.open(session.ticket, query, plan))
    }

    /// Owes the open feed these months as stale, for the next reload that has its plan to tell.
    private func owe(_ months: Set<MonthKey>?) {
        guard let owed = unsentStale else { return }
        unsentStale = months.map { owed.union($0) }
    }

    /// Tells the open feed the months owed to it are stale.
    private func tellUnsentStale() {
        let owed = unsentStale
        unsentStale = []
        markStale(owed)
    }

    /// Tells the open feed these months are stale, every month when nil: read again when the grid
    /// wants them, shown meanwhile. The store keeps them as the feed does, until each is delivered
    /// fresh, so a filter opened meanwhile carries them into the saved library (F4).
    private func markStale(_ months: Set<MonthKey>?) {
        feedStale.formUnion(months ?? Set(rows.keys).union(pendingLoads.keys))
        send(.invalidate(months))
    }

    /// A saved library comes back at once, on a feed of its own with the months it had: twelve
    /// at most, around where it was left.
    private func restoreTimeline(_ saved: SavedTimeline, plan: QueryPlan) {
        openFeed(feedQuery, plan: plan); feedPlan = plan
        // The months changes touched while it was saved, and those it was yet to read again when
        // it was left, are owed to the feed: the check that follows tells it, or a reload that
        // takes over first, or the saved library again should a filter open before either.
        unsentStale = savedStaleMonths; savedStaleMonths = []
        summary = saved.summary; title = saved.title
        rows = Self.resident(saved.rows, summary: saved.summary, around: saved.position?.section)
        // Its months come back projected as they were left, with the phone's photos of that time;
        // the photos the phone has now are merged in off the main actor, once it is on screen.
        let remote = Set(saved.summary.compactMap(\.month))
        projections = saved.projections.filter { rows[$0.key] != nil || !remote.contains($0.key) }
        dirty = [:]
        // A month that lost photos while it was saved has its rows but not yet its days.
        for (month, projection) in projections where projection.days.reduce(0, { $0 + $1.count }) != projection.entries.count {
            markDirty(month, .edit)
        }
        projectedDevice = saved.device; deviceDirty = true
        // Where the grid is going back to, so a row the phone's photos move meanwhile anchors there.
        position = saved.position
        // Its projections are its own summary's: none of its months left the server meanwhile.
        remoteMonths = remote
        refreshStructure()
        send(.restore(rows))
        project()
    }

    /// Up to twelve of a saved feed's months, those nearest the anchor first.
    private static func resident(_ rows: [MonthKey: [Asset]], summary: [SummaryMonth], around anchor: String?) -> [MonthKey: [Asset]] {
        guard rows.count > TimelineFeed.residentLimit else { return rows }
        let index = summary.firstIndex { $0.id == anchor } ?? 0
        // Nearest first; at the same distance the newer month.
        let nearest = summary.indices.sorted { (abs($0 - index), $0) < (abs($1 - index), $1) }.compactMap { summary[$0].month }.filter { rows[$0] != nil }
        var kept: [MonthKey: [Asset]] = [:]
        for month in nearest.prefix(TimelineFeed.residentLimit) { kept[month] = rows[month] }
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

    /// Stops everything on its way. `keepingFeed` leaves the feed and its loads alone, for a
    /// change that keeps the months shown.
    func stop(keepingFeed: Bool = false) {
        if !keepingFeed { cancelRequests() }
        // A reload stopped here can no longer tell the feed kept what it owes it.
        else if unsentStale != [] { tellUnsentStale() }
        queryTask?.cancel(); cancelPendingNavigation(); selection.cancelMonthSelection()
        generation = UUID(); searchGeneration = UUID()
        places.cancel()
    }
    private func beginScopeChange(keepingFeed: Bool = false) {
        freezeCurrentFeedIfNeeded()
        // The results belong to the search left behind; the frozen feed keeps its own copy. An old
        // search's results kept here would show under the next results view while it loads, when
        // the feed it replaces had nothing on screen to freeze.
        results = []
        stop(keepingFeed: keepingFeed); selection.clear(); isSearching = false; isLoading = false
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
        frozenFeed = FrozenFeed(sections: currentSections, rows: rows, projections: projections,
                                results: showingResults ? results : nil, matches: projectedDevice.remoteToLocal,
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
    /// The saved library comes back at once with the plan it was left with, then is checked
    /// against the source (F4): it is counted again and its months are read again as the grid
    /// wants them, shown meanwhile, so whatever changed while a filter or search was open reaches
    /// it. A routing change that arrived meanwhile (the offline library becoming readable, or
    /// going away) reached only the feed shown, so the library plans again and, on a new backend,
    /// reopens there anchored where it was left.
    private func revalidateRestoredLibrary(_ saved: QueryPlan, anchor: GridPosition?) async {
        let current = generation
        let plan = try? await source.plan(feedQuery)
        guard generation == current, !Task.isCancelled, !isFiltered, !showingResults else { return }
        guard let plan else {
            // Not counted again, its months owed are still read again when the grid wants them.
            if unsentStale != [] { tellUnsentStale() }
            return
        }
        if plan.backend != saved.backend { position = anchor }
        // The months owed to it since it came back, and any the summary counts otherwise.
        await reload(preservingPosition: true, invalidating: [])
    }
    private func rememberOriginal() {
        if originalTimeline == nil && !isFiltered && !showingResults {
            originalTimeline = SavedTimeline(summary: summary, rows: rows, projections: projections, device: projectedDevice,
                                             position: position, title: title, plan: feedPlan)
            // The months the library was yet to read again are read again once it is back.
            savedStaleMonths = unsentStale.map { $0.union(feedStale) }
        }
    }

    // MARK: - Sections and projections (F3)

    /// The grid's months from the server's and the phone's as projected: the sections, each
    /// carrying its month, and the feed's order and the bucket it reads each server month by,
    /// which it hears once per change. The server's photos of a month it no longer has go;
    /// projections of months no longer shown go, and a month only the phone has that is new to
    /// the grid is projected. Cheap: nothing here reads a photo or a date.
    private func refreshStructure() {
        let merging = mergesDevicePhotos
        let server = Dictionary(summary.map { ($0.id, $0.month) }, uniquingKeysWith: { first, _ in first })
        buckets = merging ? projectedDevice.buckets(remote: summary.map(\.bucket)) : summary.map(\.bucket)
        let wasRemote = remoteMonths
        remoteMonths = Set(summary.compactMap(\.month))
        // A month only the phone has is named YYYY-MM-01, which reads without a date.
        timelineSections = buckets.map { .init(id: $0.id, count: $0.count, title: title(of: $0), month: server[$0.id] ?? MonthKey(bucketID: $0.id)) }
        let shown = Set(timelineSections.compactMap(\.month))
        // A month the server no longer has loses its photos, and a projection made with them; the
        // phone's own photos there are projected again. A month the server gained keeps showing
        // the phone's photos until its own rows land.
        for month in wasRemote.subtracting(remoteMonths) {
            pendingLoads[month] = nil
            if projections[month]?.entries.contains(where: { $0.remote != nil }) == true { projections[month] = nil }
        }
        for month in Array(rows.keys) where !remoteMonths.contains(month) { rows[month] = nil }
        for month in Array(projections.keys) where !shown.contains(month) { projections[month] = nil }
        for month in Array(pendingLoads.keys) where !shown.contains(month) { pendingLoads[month] = nil }
        for month in Array(dirty.keys) where !shown.contains(month) { dirty[month] = nil }
        if merging {
            for month in shown where !remoteMonths.contains(month) && projections[month] == nil { markDirty(month, .device) }
        }
        structureVersion += 1
        let order = timelineSections.compactMap(\.month)
        let reads = Dictionary(summary.compactMap { entry in entry.month.map { ($0, entry.id) } }, uniquingKeysWith: { first, _ in first })
        if sentMonths?.order != order || sentMonths?.reads != reads {
            sentMonths = (order, reads)
            send(.months(order, buckets: reads))
        }
    }

    private func markDirty(_ month: MonthKey, _ reason: ProjectionReason) {
        dirty[month, default: []].formUnion(reason)
    }

    /// Projects what changed, off the main actor: the months delivered or edited, and, after a
    /// snapshot, the months the phone's photos changed in (by digest) and, when the matches
    /// changed, every loaded month. One run at a time; the next takes everything that changed
    /// meanwhile. A snapshot waits while a feed is being replaced, for the feed that commits.
    private func project() {
        guard projecting == nil else { return }
        var months = dirty
        // The months shown, and those the snapshot adds: a month only the phone has, new to the grid.
        var shown = Set(timelineSections.compactMap(\.month))
        let device: MergedTimeline? = deviceDirty && frozenFeed == nil ? deviceTimeline : nil
        if let device {
            deviceDirty = false
            if mergesDevicePhotos {
                for key in device.changedMonths(since: projectedDevice) {
                    guard let month = MonthKey(bucketID: key + "-01") else { continue }
                    months[month, default: []].insert(.device); shown.insert(month)
                }
            }
            if device.matchesDigest != projectedDevice.matchesDigest {
                for month in Set(rows.keys).union(pendingLoads.keys) { months[month, default: []].insert(.device) }
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
        // The grid's name for each month projected: the bucket its section shows.
        var ids: [MonthKey: String] = [:]
        for section in timelineSections { if let month = section.month, months[month] != nil, ids[month] == nil { ids[month] = section.id } }
        var inputs: [MonthProjector.Input] = [], unprojected: [MonthKey] = []
        for month in months.keys {
            let remote = pendingLoads[month]?.assets ?? rows[month]
            let bucket = ids[month] ?? month.bucketID
            let phoneOnly = merging ? phone.phoneOnly(in: bucket) : []
            // A server month not loaded has no rows to show; a month only the phone has always does.
            guard remote != nil || (!remoteMonths.contains(month) && !phoneOnly.isEmpty) else { unprojected.append(month); continue }
            inputs.append(.init(month: month, bucket: bucket, remote: remote ?? [], phoneOnly: phoneOnly, matches: phone.remoteToLocal,
                                merges: merging, previous: projections[month]))
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
    private func apply(_ results: [MonthProjector.Result], unprojected: [MonthKey], reasons: [MonthKey: ProjectionReason],
                       device: MergedTimeline?, version: Int) {
        projecting = nil
        defer { project() }
        guard version == structureVersion else {
            // The feed or its months changed under the run: everything it took is asked again.
            for (month, reason) in reasons { markDirty(month, reason) }
            if device != nil { deviceDirty = true }
            return
        }
        // A month changed again during the run is the next run's, for this run's reasons as well:
        // a phone change this run carried still restores the anchor when that month's rows move.
        for (month, reason) in reasons where dirty[month] != nil { markDirty(month, reason) }
        var changed = false, rowsMoved = false, structureChanged = false, committed = 0
        for result in results where dirty[result.month] == nil {
            let month = result.month
            if let pending = pendingLoads[month] {
                pendingLoads[month] = nil
                guard pending.ticket == feedSession?.ticket, remoteMonths.contains(month) else { continue }
                rows[month] = pending.assets
                // Only when there was one: the banner's observers needn't redraw for every month.
                if failedMonths[month] != nil { failedMonths[month] = nil }
                committed += 1
                if pending.fresh, let index = summary.firstIndex(where: { $0.month == month }), summary[index].count != pending.assets.count {
                    // FEED-5: the month's own count stands over the summary's, so a month smaller
                    // than its summary leaves no placeholder, and a larger one shows every photo.
                    structureChanged = true
                    if pending.assets.isEmpty { summary.remove(at: index); rows[month] = nil; projections[month] = nil; continue }
                    summary[index] = summary[index].counting(pending.assets.count)
                }
            }
            // A server month the feed let go during the run has no rows: its projection stays gone,
            // or it would outlive the twelve resident months, out of reach of removals and edits.
            guard rows[month] != nil || !remoteMonths.contains(month) else { continue }
            if result.changed || projections[month] == nil {
                if result.rowsChanged, projections[month] != nil, reasons[month]?.contains(.device) == true { rowsMoved = true }
                projections[month] = result.projection; changed = true
            }
        }
        for month in unprojected where dirty[month] == nil && projections[month] != nil { projections[month] = nil; changed = true }
        if let device { projectedDevice = device }
        if device != nil || structureChanged {
            let before = timelineSections
            refreshStructure()
            if device != nil && before != timelineSections { rowsMoved = true }
        }
        if rowsMoved {
            // The grid keeps the photo it shows; a phone photo matched meanwhile is its server record now.
            if let anchor = position, timelineSections.contains(where: { $0.id == anchor.section }) {
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

/// The saved library, patched while a filter or search shows (F4). Its place and title stay.
private extension SavedTimeline {
    /// Without these photos: their rows go, their months count fewer, and a month left with none
    /// of the server's photos goes from the summary. A month's days are redone once it is back.
    func removing(_ ids: Set<String>) -> SavedTimeline {
        var rows = self.rows, projections = self.projections, removed: [MonthKey: Int] = [:]
        for (month, assets) in self.rows {
            let kept = assets.filter { !ids.contains($0.id) }
            guard kept.count != assets.count else { continue }
            removed[month] = assets.count - kept.count
            rows[month] = kept
            projections[month] = projections[month]?.removing(ids)
        }
        guard !removed.isEmpty else { return self }
        let summary = self.summary.compactMap { entry -> SummaryMonth? in
            guard let month = entry.month, let gone = removed[month] else { return entry }
            return entry.count > gone ? entry.counting(entry.count - gone) : nil
        }
        let kept = Set(summary.compactMap(\.month))
        for month in removed.keys where !kept.contains(month) { rows[month] = nil }
        return SavedTimeline(summary: summary, rows: rows, projections: projections, device: device, position: position,
                             title: title, plan: plan)
    }

    /// With a photo's newer record, its phone copy kept beside it.
    func replacing(_ asset: Asset) -> SavedTimeline {
        var rows = self.rows, projections = self.projections, changed = false
        for (month, assets) in self.rows {
            guard let index = assets.firstIndex(where: { $0.id == asset.id }) else { continue }
            rows[month]?[index] = asset
            projections[month] = projections[month]?.replacing(asset)
            changed = true
        }
        guard changed else { return self }
        return SavedTimeline(summary: summary, rows: rows, projections: projections, device: device, position: position,
                             title: title, plan: plan)
    }
}

extension LibraryFeedStore: DisplayedFeed {
    fileprivate var shownSections: [LibrarySection] { liveSections }
    fileprivate var shownResults: [Asset]? { showingResults ? results : nil }
    fileprivate func shownRows(of month: MonthKey) -> [Asset]? { rows[month] }
    fileprivate func shownProjection(of month: MonthKey) -> MonthProjector.Projection? { projections[month] }
    fileprivate func shownMatch(_ id: String) -> LocalPhoto? { deviceTimeline.remoteToLocal[id] }
    fileprivate func shownPlaces(of section: String) -> [PlaceTally]? { monthPlaces[section] }
}

extension LibraryFeedStore: TimelineFeedConsumer {
    /// A month arrived. It is projected off the main actor and shown with its rows; the months
    /// let go to make room go now, as the grid cannot be on them.
    func monthLoaded(_ ticket: TimelineFeed.Ticket, month: MonthKey, assets: [Asset], fresh: Bool, evicting: [MonthKey]) {
        guard ticket == feedSession?.ticket, remoteMonths.contains(month) else { return }
        // A load begun before the month was made stale leaves it stale, as the feed keeps it.
        if fresh { feedStale.remove(month) } else { feedStale.insert(month) }
        for evicted in evicting {
            feedStale.remove(evicted)
            guard remoteMonths.contains(evicted), rows[evicted] != nil || pendingLoads[evicted] != nil else { continue }
            rows[evicted] = nil; pendingLoads[evicted] = nil; projections[evicted] = nil; dirty[evicted] = nil
        }
        pendingLoads[month] = PendingLoad(ticket: ticket, assets: assets, fresh: fresh)
        markDirty(month, .load)
        project()
    }

    func monthFailed(_ ticket: TimelineFeed.Ticket, month: MonthKey, message: String) {
        guard ticket == feedSession?.ticket, remoteMonths.contains(month) else { return }
        failedMonths[month] = message
        revision += 1
    }
}

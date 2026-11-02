import Foundation
import IlyichPlatform

/// The account's places (REBUILD_ROADMAP.md L1). Everything that names or finds places reads them
/// here: the Earth and its list of locations, search, and the names months and photos carry.
///
/// It keeps the photos' locations for each marker query asked for, the localities found so far,
/// and the place hierarchy of each query, built again off the actor whenever the photos change or
/// more localities come in. Localities are looked up one unit at a time, paced, the biggest units
/// first, and kept on the phone; a unit's answer never needs asking again.
actor PlaceDirectory {
    enum Snapshot: Sendable {
        case loading
        case loaded(PlaceHierarchy)
        case failed(String)
    }

    /// The photos the library's Earth and search find places in: the account's, its partners' and
    /// those of shared albums, without the archive.
    static let library = MapMarkerQuery(withPartners: true, withSharedAlbums: true, isArchived: false)

    /// Where an account's localities are kept, in Application Support.
    static func url(for account: AccountID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AccountStoragePaths(account).places, isDirectory: false)
    }

    /// The language localities are named in: the app's first.
    static var language: String { Locale.preferredLanguages.first ?? "en" }

    private struct Entry {
        var markers: [MapMarker]?
        var hierarchy: PlaceHierarchy?
        var failure: String?
        var stale = true
        var loading: Task<Void, Never>?
        var watchers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
        var snapshot: Snapshot {
            if let hierarchy { return .loaded(hierarchy) }
            if let failure { return .failed(failure) }
            return .loading
        }
    }

    /// The city each server name lies in, for the screens that name one photo's place.
    nonisolated let naming: PlaceNaming?
    private let markers: @Sendable (MapMarkerQuery) async throws -> [MapMarker]
    private let geocoder: (any PlaceGeocoder)?
    private let file: URL?
    private let pacing: Duration
    private let backoff: Duration
    private let settle: Duration
    private var entries: [MapMarkerQuery: Entry] = [:]
    private var localities: PlaceLocalities
    private var localitiesRead = false
    private var unsaved = 0
    /// Units not looked up yet, by key.
    private var wanted: [String: PlaceUnit] = [:]
    private var resolving: Task<Void, Never>?
    private var rebuilding: Task<Void, Never>?
    private var reloading: Task<Void, Never>?
    private var following: Task<Void, Never>?
    private var ended = false

    /// `markers` finds the photos' locations; without a geocoder no locality is looked up, and
    /// without a file none is kept past the directory.
    init(markers: @escaping @Sendable (MapMarkerQuery) async throws -> [MapMarker], geocoder: (any PlaceGeocoder)?, file: URL?,
         naming: PlaceNaming? = nil, language: String = PlaceDirectory.language, pacing: Duration = .milliseconds(1300),
         backoff: Duration = .seconds(60), settle: Duration = .seconds(2)) {
        self.markers = markers; self.geocoder = geocoder; self.file = file; self.naming = naming
        self.pacing = pacing; self.backoff = backoff; self.settle = settle
        localities = PlaceLocalities(language: language)
    }

    /// The places of `query`, kept current: what is known at once, then each new hierarchy.
    func places(_ query: MapMarkerQuery = PlaceDirectory.library) -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !ended else { continuation.finish(); return stream }
        let id = UUID()
        entries[query, default: Entry()].watchers[id] = continuation
        continuation.yield(entries[query]!.snapshot)
        continuation.onTermination = { [weak self] _ in Task { await self?.unwatch(id, query) } }
        if entries[query]!.stale { load(query) }
        return stream
    }

    /// The places a search names, read against the library's hierarchy, loaded first when it
    /// isn't yet. Nil when the text names none, or the places can't be loaded.
    func read(_ text: String) async -> PlaceSearch.Reading? {
        guard let hierarchy = await hierarchy(Self.library) else { return nil }
        return PlaceSearch(hierarchy: hierarchy).read(text)
    }

    /// `query`'s hierarchy, loading it when there is none yet.
    func hierarchy(_ query: MapMarkerQuery) async -> PlaceHierarchy? {
        if let hierarchy = entries[query]?.hierarchy { return hierarchy }
        guard !ended else { return nil }
        if entries[query]?.loading == nil { load(query) }
        await entries[query]?.loading?.value
        return entries[query]?.hierarchy
    }

    /// Reads `query`'s photos again.
    func reload(_ query: MapMarkerQuery = PlaceDirectory.library) {
        entries[query, default: Entry()].stale = true
        entries[query]!.failure = nil
        load(query)
    }

    /// Follows the account's bus: photos added, removed or changed read the places again, a few
    /// seconds after the changes stop.
    func follow(_ bus: LibraryBus) {
        let events = bus.subscribe { event -> Bool? in
            switch event {
            case .changed(let change, _): !change.upserted.isEmpty || !change.removed.isEmpty || !change.accessLost.isEmpty ? true : nil
            case .mutation: true
            case .collection, .cachesCleared: nil
            }
        }
        following = Task { [weak self] in for await _ in events { await self?.libraryChanged() } }
    }

    func shutdown() async {
        ended = true
        for task in [resolving, rebuilding, reloading, following] { task?.cancel() }
        for entry in entries.values {
            entry.loading?.cancel()
            entry.watchers.values.forEach { $0.finish() }
        }
        entries = [:]
        save()
    }

    // MARK: Photos

    private func unwatch(_ id: UUID, _ query: MapMarkerQuery) {
        entries[query]?.watchers[id] = nil
        // Other queries' places are let go with their last screen; the library's stay for search.
        if query != Self.library, entries[query]?.watchers.isEmpty == true {
            entries[query]?.loading?.cancel(); entries[query] = nil
        }
    }

    private func load(_ query: MapMarkerQuery) {
        guard !ended, entries[query]?.loading == nil else { return }
        let markers = self.markers
        entries[query, default: Entry()].loading = Task { [weak self] in
            do {
                let found = try await markers(query)
                await self?.loaded(found, for: query)
            } catch is CancellationError {
                await self?.settled(query)
            } catch {
                await self?.failed(error, for: query)
            }
        }
    }

    private func loaded(_ markers: [MapMarker], for query: MapMarkerQuery) async {
        guard entries[query] != nil else { return }
        entries[query]!.markers = markers; entries[query]!.stale = false; entries[query]!.loading = nil
        entries[query]!.failure = nil
        await readLocalities()
        await rebuild(query)
    }

    private func settled(_ query: MapMarkerQuery) { entries[query]?.loading = nil }

    private func failed(_ error: any Error, for query: MapMarkerQuery) {
        guard entries[query] != nil else { return }
        entries[query]!.loading = nil
        // Places already shown stay; only a first load that failed says so.
        guard entries[query]!.hierarchy == nil else { return }
        entries[query]!.failure = error.localizedDescription
        publish(query)
    }

    private func libraryChanged() {
        for query in entries.keys { entries[query]!.stale = true }
        reloading?.cancel()
        reloading = Task { [weak self, settle] in
            try? await Task.sleep(for: settle * 2)
            guard !Task.isCancelled else { return }
            await self?.reloadWatched()
        }
    }

    private func reloadWatched() {
        for (query, entry) in entries where entry.stale && (!entry.watchers.isEmpty || query == Self.library) { load(query) }
    }

    // MARK: Hierarchies

    private func rebuild(_ query: MapMarkerQuery) async {
        guard let markers = entries[query]?.markers else { return }
        let localities = self.localities
        let markerQuery = query.queryItems.map { $0.name + "=" + ($0.value ?? "") }.joined(separator: "&")
        let hierarchy = await Task.detached(priority: .userInitiated) {
            PlaceHierarchy.build(markers, localities: localities, markerQuery: markerQuery)
        }.value
        guard entries[query] != nil, !ended else { return }
        entries[query]!.hierarchy = hierarchy
        publish(query)
        if query == Self.library, let naming {
            let cities = hierarchy.citiesByServerName
            await MainActor.run { naming.cities = cities }
        }
        want(hierarchy.units)
    }

    private func publish(_ query: MapMarkerQuery) {
        guard let entry = entries[query] else { return }
        for watcher in entry.watchers.values { watcher.yield(entry.snapshot) }
    }

    /// Builds the hierarchies again as localities come in, every few of them rather than on each
    /// one, so the Earth isn't made again every other second while they are looked up.
    private func scheduleRebuild() {
        guard rebuilding == nil else { return }
        rebuilding = Task { [weak self, settle] in
            try? await Task.sleep(for: settle * 8)
            await self?.rebuildAll()
        }
    }

    private func rebuildAll() async {
        rebuilding = nil
        guard !Task.isCancelled else { return }
        for query in entries.keys where entries[query]?.markers != nil { await rebuild(query) }
    }

    // MARK: Localities

    private func want(_ units: [PlaceUnit]) {
        guard geocoder != nil else { return }
        for unit in units where localities[unit.key] == nil { wanted[unit.key] = unit }
        guard !wanted.isEmpty, resolving == nil, !ended else { return }
        resolving = Task { [weak self] in await self?.resolve() }
    }

    /// Looks up one unit at a time until none is left: first the biggest of each country not yet
    /// known, so every country is named early, then the rest, biggest first. A throttled or
    /// unanswered lookup waits and is tried again.
    private func resolve() async {
        var failures = 0
        while !Task.isCancelled, let geocoder, let unit = nextUnit() {
            do {
                let locality = try await geocoder.locality(latitude: unit.latitude, longitude: unit.longitude, language: localities.language)
                record(locality, for: unit.key)
                failures = 0
                try? await Task.sleep(for: pacing)
            } catch {
                switch error {
                case .throttled: try? await Task.sleep(for: backoff)
                case .unavailable:
                    failures += 1
                    try? await Task.sleep(for: backoff * min(failures, 5))
                }
            }
        }
        save()
        resolving = nil
    }

    private func nextUnit() -> PlaceUnit? {
        wanted = wanted.filter { localities[$0.key] == nil }
        var known = Set<String>()
        for (key, locality) in localities.units where locality.countryCode != nil { known.insert(key.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) ?? "") }
        let unnamedCountry = wanted.values.filter { !known.contains($0.country ?? "") }.max { $0.count < $1.count }
        return unnamedCountry ?? wanted.values.max { $0.count != $1.count ? $0.count < $1.count : $0.key > $1.key }
    }

    private func record(_ locality: PlaceLocality, for key: String) {
        localities.units[key] = locality
        wanted[key] = nil
        unsaved += 1
        if unsaved >= 20 { save() }
        scheduleRebuild()
    }

    private func readLocalities() async {
        guard !localitiesRead else { return }
        localitiesRead = true
        guard let file, let data = try? Data(contentsOf: file),
              let kept = try? JSONDecoder().decode(PlaceLocalities.self, from: data), kept.language == localities.language else { return }
        localities.units.merge(kept.units) { current, _ in current }
    }

    private func save() {
        guard let file, unsaved > 0 else { return }
        unsaved = 0
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(localities).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

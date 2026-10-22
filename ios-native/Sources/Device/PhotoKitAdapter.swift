import Foundation
import Photos
import Synchronization

/// Reads assets by identifier. Safe on any thread, inside a change block too.
protocol AssetFetching: Sendable {
    /// The assets among `ids` that Photos still has, in no particular order.
    func states(of ids: [DeviceAssetID]) -> [DeviceAssetState]
}

/// The Photos library: its access, its change notifications and its changes. The request methods
/// are called only from a block passed to `performChanges`, on Photos' own queue.
protocol PhotoLibraryPerforming: Sendable {
    func authorizationStatus() -> PHAuthorizationStatus
    func requestAuthorization() async -> PHAuthorizationStatus
    /// Registers the app's one change observer. Photos calls `onChange` on a queue of its own.
    func startObserving(_ onChange: @escaping @Sendable (PhotoLibraryChangeDetails) -> Void)
    func stopObserving()
    /// Runs `block` as one change and returns once iOS has applied it. It throws when iOS doesn't,
    /// as when the person declines iOS's prompt to delete.
    func performChanges(_ block: @escaping @Sendable () -> Void) async throws
    func requestDeletion(of ids: [DeviceAssetID])
    func requestFavorite(_ isFavorite: Bool, for ids: [DeviceAssetID])
    /// Adds an asset made of these files, and returns its identifier.
    func requestCreation(still: URL?, video: URL?, pairedVideo: URL?) -> DeviceAssetID?
}

/// A change Photos didn't make, with the reason to show.
struct PhotosChangeFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// The app's one door to the Photos library (architecture section 1). It runs on a serial queue of
/// its own, so its PhotoKit work never waits on the main thread or holds it up:
/// - access, with a generation that moves whenever it changes;
/// - the only change observer. Each burst of changes reaches every subscriber merged into one,
///   a quarter second after it began;
/// - every change the app makes to the library. Each is journaled in DeviceDatabase before Photos
///   is asked and finished after, checked again inside its change block, all or nothing, and
///   never retried. An entry an earlier run left unfinished is reconciled at launch from what
///   Photos holds, and never applied again.
actor PhotoKitAdapter {
    /// The process's adapter, as iOS gives the app one Photos library.
    static let shared: PhotoKitAdapter = {
        let photos = SystemPhotoKit()
        return PhotoKitAdapter(library: photos, assets: photos, journal: DeviceDatabase(url: DeviceDatabase.standardURL), staging: photos)
    }()

    private nonisolated let queue = DispatchSerialQueue(label: "app.ilyich.photokit", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private nonisolated let library: any PhotoLibraryPerforming
    private nonisolated let assets: any AssetFetching
    /// What backup staging and discovery read (PhotoLibraryStaging.swift).
    nonisolated let stagingReader: any PhotoStagingReading
    private nonisolated let journal: DeviceDatabase
    /// The phone's database, which also keeps the device index's fingerprints.
    nonisolated var database: DeviceDatabase { journal }
    private nonisolated let window: Duration
    private nonisolated let sleep: @Sendable (Duration) async throws -> Void
    /// Access and what subscribers hear, behind a lock, so that Photos' own queue adds to it in
    /// the order Photos reports.
    private nonisolated let observation = Mutex(Observation())

    private var observing = false
    /// Journal entries this run began. Reconciling never takes one of them for an earlier run's.
    private var begun: Set<UUID> = []
    /// Assets a deletion in progress names. Another deletion of any of them is refused, so the
    /// person never answers a second prompt for the same photos.
    private var removing: Set<DeviceAssetID> = []
    private var reconciled = false
    /// The album list as last read, with the album generation it was read at
    /// (PhotoLibraryStaging.swift).
    var albumCache: (generation: UInt64, albums: [DeviceAlbum])?
    /// Moves whenever Photos reports a change, as any change may add, remove, rename or resize an album.
    nonisolated let albumGeneration = Mutex<UInt64>(0)
    /// Revisions that show the same content, as when a favorite moved an asset's modification date
    /// (DeviceBrowsing.swift).
    nonisolated let contentRevisions = Mutex(ContentRevisions())

    private struct Observation {
        /// Generation 0 until access is first read.
        var access = DeviceAccess(status: .notDetermined, generation: 0)
        var pending: DeviceLibraryChange?
        var flushScheduled = false
        var changes: [UUID: AsyncStream<DeviceLibraryChange>.Continuation] = [:]
        var mutations: [UUID: AsyncStream<DeviceMutationResult>.Continuation] = [:]
    }

    /// `sleep` waits out the coalescing window; tests pass a clock of their own.
    init(library: any PhotoLibraryPerforming, assets: any AssetFetching, journal: DeviceDatabase,
         staging: any PhotoStagingReading = SystemPhotoKit(),
         coalescing window: Duration = .milliseconds(250),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.library = library
        self.assets = assets
        self.journal = journal
        self.stagingReader = staging
        self.window = window
        self.sleep = sleep
    }

    // MARK: - Access

    /// Photos access as last read.
    nonisolated var access: DeviceAccess { observation.withLock { $0.access } }

    /// At launch, whatever launched the app: reads access, starts the change observer, and
    /// reconciles what an earlier run left unfinished.
    func start() async {
        refreshAccess()
        await reconcileInterrupted()
    }

    /// Photos access as Photos reports it now. Cheap, and safe on any thread.
    nonisolated var authorization: PHAuthorizationStatus { library.authorizationStatus() }

    /// Whether the change observer runs, which an album list read now can rely on to go stale.
    var isObserving: Bool { observing }

    /// Reads Photos access again. The first reading only learns it, as generation 1. A change
    /// after that moves the generation and reaches subscribers as a change that needs a full
    /// reload, and read access newly granted also reconciles what an earlier run left unfinished.
    /// The change observer runs exactly while access allows reading.
    @discardableResult
    func refreshAccess() -> DeviceAccess {
        let status = library.authorizationStatus()
        let (access, changed) = observation.withLock { state -> (DeviceAccess, Bool) in
            if state.access.generation == 0 {
                state.access = DeviceAccess(status: status, generation: 1)
                return (state.access, false)
            }
            guard state.access.status != status else { return (state.access, false) }
            state.access = DeviceAccess(status: status, generation: state.access.generation &+ 1)
            return (state.access, true)
        }
        let readable = Self.canRead(status)
        if readable != observing {
            observing = readable
            if readable { library.startObserving { [weak self] details in self?.ingest(details) } }
            else { library.stopObserving() }
        }
        if changed {
            ingest(PhotoLibraryChangeDetails(requiresFullReload: true))
            if readable, !reconciled { Task { await self.reconcileInterrupted() } }
        }
        return access
    }

    /// Asks the person for Photos access if iOS will still ask, and returns access as it then is.
    func requestAccess() async -> DeviceAccess {
        _ = await library.requestAuthorization()
        return refreshAccess()
    }

    static func canRead(_ status: PHAuthorizationStatus) -> Bool { status == .authorized || status == .limited }

    // MARK: - Changes

    /// Every burst of library changes from now on, each merged into one, until the stream is
    /// dropped. Photos has one observer however many subscribe.
    nonisolated func changes() -> AsyncStream<DeviceLibraryChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceLibraryChange.self)
        let id = UUID()
        observation.withLock { $0.changes[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.unsubscribe(change: id) }
        return stream
    }

    /// Adds what Photos reported to the burst subscribers will hear, which goes out one window
    /// after the burst began. Photos calls this on its own queue.
    private nonisolated func ingest(_ details: PhotoLibraryChangeDetails) {
        // Any change may move an album: an insert or removal changes counts, and a favorite or an
        // edit changes smart albums such as Favorites and Recently Edited, which Photos doesn't
        // reliably report as a change to the album itself.
        albumGeneration.withLock { $0 &+= 1 }
        contentRevisions.withLock { $0.apply(details) }
        let starts = observation.withLock { state -> Bool in
            var change = state.pending ?? DeviceLibraryChange(access: state.access)
            change.merge(details)
            state.pending = change
            defer { state.flushScheduled = true }
            return !state.flushScheduled
        }
        guard starts else { return }
        Task { [weak self, sleep = self.sleep, window = self.window] in
            try? await sleep(window)
            self?.flush()
        }
    }

    private nonisolated func flush() {
        observation.withLock { state in
            state.flushScheduled = false
            guard var change = state.pending else { return }
            state.pending = nil
            change.access = state.access
            for subscriber in state.changes.values { subscriber.yield(change) }
        }
    }

    private nonisolated func unsubscribe(change id: UUID) {
        observation.withLock { _ = $0.changes.removeValue(forKey: id) }
    }

    // MARK: - Mutations

    /// The result of every change from now on, those reconciled at launch included.
    nonisolated func mutations() -> AsyncStream<DeviceMutationResult> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceMutationResult.self)
        let id = UUID()
        observation.withLock { $0.mutations[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.unsubscribe(mutation: id) }
        return stream
    }

    private nonisolated func unsubscribe(mutation id: UUID) {
        observation.withLock { _ = $0.mutations.removeValue(forKey: id) }
    }

    /// Applies `mutation` to the Photos library and says how it ended. Once begun it runs to its
    /// end even if the caller is cancelled or its screen is gone, as the person may already be
    /// answering iOS's prompt; the journal says how it ended either way.
    nonisolated func perform(_ mutation: DeviceMutation) async -> DeviceMutationResult {
        await Task { await self.apply(mutation) }.value
    }

    private func apply(_ mutation: DeviceMutation) async -> DeviceMutationResult {
        let id = UUID()
        func ended(_ outcome: DeviceMutationResult.Outcome) -> DeviceMutationResult {
            publish(DeviceMutationResult(id: id, mutation: mutation, outcome: outcome))
        }
        switch mutation {
        case .delete(let ids, _, _), .setFavorite(let ids, _, _):
            guard !ids.isEmpty, Set(ids).count == ids.count else { return ended(.failed(Self.selectAgain)) }
            guard Self.canRead(refreshAccess().status) else { return ended(.notPermitted) }
            // Checked before asking too, so a change that can't happen leaves no entry and shows no prompt.
            let verdict = PhotoChangeChecks.verdict(for: mutation, found: assets.states(of: ids))
            guard verdict == .allowed else { return ended(Self.outcome(of: verdict)) }
        case .create(let still, let video, _, _):
            guard still != nil || video != nil else { return ended(.failed(Self.nothingToSave)) }
        }
        var deleting: [DeviceAssetID] = []
        if case .delete(let ids, _, _) = mutation { deleting = ids }
        guard removing.isDisjoint(with: deleting) else { return ended(.failed(Self.alreadyRemoving)) }
        removing.formUnion(deleting)
        defer { removing.subtract(deleting) }

        // The entry comes first: Photos is asked only once it is written.
        begun.insert(id)
        do { try await journal.begin(DeviceJournalEntry(id: id, mutation: mutation, createdAt: Date())) }
        catch { return ended(.failed(Self.journalUnavailable)) }
        let report = ChangeReport()
        var failure: (any Error)?
        do { try await library.performChanges(PhotoChanges.block(for: mutation, library: library, assets: assets, report: report)) }
        catch { failure = error }
        let outcome = Self.outcome(of: mutation, report: report.value, error: failure)
        // An entry left unfinished, as when this write fails, is reconciled at the next launch.
        try? await journal.finish(id, outcome: outcome, at: Date())
        return ended(outcome)
    }

    private nonisolated func publish(_ result: DeviceMutationResult) -> DeviceMutationResult {
        observation.withLock { state in
            for subscriber in state.mutations.values { subscriber.yield(result) }
        }
        return result
    }

    static func outcome(of verdict: PhotoChangeVerdict) -> DeviceMutationResult.Outcome {
        switch verdict {
        case .allowed: .failed(notApplied)
        case .revisionChanged: .revisionChanged
        case .notPermitted: .notPermitted
        }
    }

    /// How a change ended, from what its block found and how Photos answered.
    static func outcome(of mutation: DeviceMutation, report: ChangeReport.Value, error: (any Error)?) -> DeviceMutationResult.Outcome {
        if let verdict = report.verdict, verdict != .allowed { return outcome(of: verdict) }
        var deletes = false
        if case .delete = mutation { deletes = true }
        if let error { return isDeclined(error, deleting: deletes) ? .declined : .failed(error.localizedDescription) }
        guard report.requested else { return .failed(notApplied) }
        switch mutation {
        case .delete(let ids, _, _), .setFavorite(let ids, _, _): return .committed(affected: ids, created: [])
        case .create: return .committed(affected: [], created: report.created)
        }
    }

    /// Whether Photos says the person declined, as it does when they refuse iOS's prompt to
    /// delete. iOS before 14 reported a refused deletion as Cocoa error -1.
    static func isDeclined(_ error: any Error, deleting: Bool) -> Bool {
        let error = error as NSError
        if error.code == PHPhotosError.userCancelled.rawValue, error.domain == PHPhotosErrorDomain || error.domain == NSCocoaErrorDomain {
            return true
        }
        return deleting && error.domain == NSCocoaErrorDomain && error.code == -1
    }

    // MARK: - Reconciling at launch

    /// Reconciles the journal entries an earlier run began and never finished: the app ended while
    /// Photos applied them. Each is told from what Photos holds now, and never applied again. It
    /// waits for read access, without which nothing can be told.
    func reconcileInterrupted() async {
        guard !reconciled, Self.canRead(access.status) else { return }
        reconciled = true
        let entries: [DeviceJournalEntry]
        do { entries = try await journal.unfinished() }
        catch { reconciled = false; return }
        for entry in entries where !begun.contains(entry.id) {
            let outcome = Self.reconciliation(of: entry.mutation, found: assets.states(of: Self.assetIDs(of: entry.mutation)),
                                          fullAccess: access.status == .authorized)
            guard (try? await journal.finish(entry.id, outcome: outcome, at: Date())) != nil else { continue }
            _ = publish(DeviceMutationResult(id: entry.id, mutation: entry.mutation, outcome: outcome))
        }
    }

    /// What an interrupted change did, told from Photos now. A deletion happened when none of its
    /// assets is left, which only full access can tell, as limited access hides photos outside the
    /// selection; favoriting, when every asset has the value asked for. Anything else, a save
    /// among them, is interrupted.
    static func reconciliation(of mutation: DeviceMutation, found: [DeviceAssetState], fullAccess: Bool) -> DeviceMutationResult.Outcome {
        switch mutation {
        case .delete(let ids, _, _):
            return fullAccess && found.isEmpty ? .committed(affected: ids, created: []) : .interrupted
        case .setFavorite(let ids, let value, _):
            let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.allSatisfy({ byID[$0]?.isFavorite == value }) ? .committed(affected: ids, created: []) : .interrupted
        case .create:
            return .interrupted
        }
    }

    private static func assetIDs(of mutation: DeviceMutation) -> [DeviceAssetID] {
        switch mutation {
        case .delete(let ids, _, _), .setFavorite(let ids, _, _): ids
        case .create: []
        }
    }

    private static let selectAgain = "Select the photos again before continuing."
    private static let nothingToSave = "There was nothing to save to Photos."
    private static let alreadyRemoving = "These items are already being removed from Photos."
    private static let journalUnavailable = "Ilyich couldn’t keep a record of this change on the phone, so nothing was changed. Free some storage, then try again."
    private static let notApplied = "Photos didn’t apply the change. Try again."
}

import Foundation
import Network
import Synchronization

// MARK: - Policy

/// When and what coverage keeps offline (REBUILD_ROADMAP.md T5). Persisted in UserDefaults under
/// `thumbnails.coverage.v1`; a missing or unreadable value is today's behavior: the account's own
/// timeline, on unmetered networks only, paused in Low Power Mode, when the phone is hot, while a
/// photo is open and for a moment after the grid moves. Nothing in the app changes it yet.
struct CoveragePolicy: Codable, Hashable, Sendable {
    /// Which photos are kept offline. Partners and shared albums are an open owner question.
    enum Scope: String, Codable, Hashable, Sendable {
        case ownerTimeline
    }

    var scope = Scope.ownerTimeline
    var unmeteredOnly = true
    var pausesInLowPowerMode = true
    var pausesWhenHot = true
    var pausesWhileViewing = true
    /// How long after the grid stops moving coverage waits before downloading again.
    var motionHold: TimeInterval = 1.5

    static let today = CoveragePolicy()
    static let defaultsKey = "thumbnails.coverage.v1"

    init() {}

    /// Keys a later build adds read as today's values here, and keys this build doesn't know are ignored.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decodeIfPresent(Scope.self, forKey: .scope) ?? .ownerTimeline
        unmeteredOnly = try container.decodeIfPresent(Bool.self, forKey: .unmeteredOnly) ?? true
        pausesInLowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .pausesInLowPowerMode) ?? true
        pausesWhenHot = try container.decodeIfPresent(Bool.self, forKey: .pausesWhenHot) ?? true
        pausesWhileViewing = try container.decodeIfPresent(Bool.self, forKey: .pausesWhileViewing) ?? true
        motionHold = try container.decodeIfPresent(TimeInterval.self, forKey: .motionHold) ?? 1.5
    }

    static func load(from defaults: UserDefaults = .standard) -> CoveragePolicy {
        guard let data = defaults.data(forKey: defaultsKey), let policy = try? JSONDecoder().decode(CoveragePolicy.self, from: data) else {
            return today
        }
        return policy
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// Names what decides which photos are covered. When it changes, the next pass verifies every
    /// photo again (the thumbnail index keeps it as policy_hash).
    var fingerprint: String { "scope=" + scope.rawValue }

    /// Why coverage may not download right now, or nil.
    func hold(_ conditions: CoverageConditions.Snapshot, now: TimeInterval) -> CoverageHold? {
        guard conditions.appActive else { return .background }
        if conditions.network == .none { return .offline }
        if unmeteredOnly, conditions.network != .unmetered { return .metered }
        if pausesInLowPowerMode, conditions.lowPower { return .lowPower }
        if pausesWhenHot, conditions.thermal == .serious || conditions.thermal == .critical { return .thermal }
        if pausesWhileViewing, conditions.viewing { return .viewing }
        if conditions.moving { return .moving }
        if let ended = conditions.motionEndedAt, ended + motionHold > now { return .settling(until: ended + motionHold) }
        return nil
    }
}

/// What keeps coverage from downloading.
enum CoverageHold: Hashable, Sendable {
    case background
    case offline
    /// Cellular, a hotspot or Low Data Mode.
    case metered
    case lowPower
    case thermal
    /// A photo is open.
    case viewing
    /// The grid is scrolling or the rail is scrubbing.
    case moving
    /// The grid just stopped; coverage waits until `until` on the uptime clock.
    case settling(until: TimeInterval)
    /// Downloads failed: the server is left alone for a while.
    case serverFailing
    /// The thumbnail store is at its cap: downloading more would only evict what the grid showed.
    case diskBudget
    /// The offline library isn't complete yet.
    case libraryNotReady
}

// MARK: - Conditions

/// What coverage waits for, written by whoever knows: the network monitor, ProcessInfo, the
/// library screen (viewing, motion) and the session (app in front). Readable from any thread.
final class CoverageConditions: Sendable {
    struct Snapshot: Hashable, Sendable {
        var appActive = true
        var network = EnvironmentSnapshot.Network.unmetered
        var lowPower = false
        var thermal = ProcessInfo.ThermalState.nominal
        var viewing = false
        var moving = false
        /// When the grid last stopped moving, on the uptime clock. Nil when it never moved.
        var motionEndedAt: TimeInterval?
    }

    private struct State {
        var snapshot: Snapshot
        var onChange: (@Sendable () -> Void)?
    }

    private let state: Mutex<State>
    /// The uptime clock, replaceable by tests.
    let now: @Sendable () -> TimeInterval
    private let monitor: NWPathMonitor?
    /// Set once in init, removed in stop.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    /// Conditions a caller sets, for tests and for parts of the app that know them.
    init(_ snapshot: Snapshot = Snapshot(), now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        state = Mutex(State(snapshot: snapshot))
        self.now = now
        monitor = nil
    }

    /// Conditions that follow the phone: the network path (unmetered, expensive or constrained),
    /// Low Power Mode and the thermal state. `appActive` starts as given and the session keeps it
    /// current; the library screen says when a photo is open or the grid moves.
    init(followingSystemWithAppActive appActive: Bool) {
        let info = ProcessInfo.processInfo
        // Until the monitor's first reading the network counts as absent, so nothing downloads blind.
        let snapshot = Snapshot(appActive: appActive, network: .none, lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState)
        state = Mutex(State(snapshot: snapshot))
        now = { ProcessInfo.processInfo.systemUptime }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let network = Self.network(path)
            self?.update { $0.network = network }
        }
        monitor.start(queue: DispatchQueue(label: "ilyich.coverage.conditions", qos: .utility))
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
                let thermal = ProcessInfo.processInfo.thermalState
                self?.update { $0.thermal = thermal }
            },
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
                let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.update { $0.lowPower = lowPower }
            },
        ]
    }

    deinit { stop() }

    static func network(_ path: NWPath) -> EnvironmentSnapshot.Network {
        guard path.status == .satisfied else { return .none }
        if path.isConstrained { return .constrained }
        if path.isExpensive { return .expensive }
        return .unmetered
    }

    var snapshot: Snapshot { state.withLock { $0.snapshot } }

    /// Changes the conditions and wakes whoever waits on them, if anything changed.
    func update(_ change: @Sendable (inout Snapshot) -> Void) {
        let handler = state.withLock { state -> (@Sendable () -> Void)? in
            var next = state.snapshot
            change(&next)
            guard next != state.snapshot else { return nil }
            state.snapshot = next
            return state.onChange
        }
        handler?()
    }

    /// A photo is open in the viewer.
    func setViewing(_ viewing: Bool) { update { $0.viewing = viewing } }

    /// The grid is scrolling or the rail is scrubbing; when it stops, the hold starts.
    func setMoving(_ moving: Bool) {
        let time = now()
        update { snapshot in
            guard snapshot.moving != moving else { return }
            snapshot.moving = moving
            if !moving { snapshot.motionEndedAt = time }
        }
    }

    /// The app is in front.
    func setAppActive(_ active: Bool) { update { $0.appActive = active } }

    /// Called after every change. One listener: the worker that waits on these conditions.
    func onChange(_ handler: (@Sendable () -> Void)?) { state.withLock { $0.onChange = handler } }

    func stop() {
        monitor?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}

// MARK: - Persisted state

/// Where coverage is, kept in the thumbnail index's meta table beside the files it describes,
/// so clearing the store clears it too.
struct CoverageState: Hashable, Sendable {
    /// The keyset position of the pass under way, as JSON; nil between passes.
    var cursor: String?
    /// The index's persisted revision (index_state.revision) the library was last verified at.
    /// Nil, as on every phone before T5, forces a verification pass; present files are never
    /// fetched again.
    var mark: Int64?
    /// The mark the pass under way places when it reaches the end: the index's revision when it
    /// began, or nil once one of its downloads failed. Nil between passes.
    var passMark: Int64?
    /// The policy fingerprint the cursor and mark were made under.
    var policyHash: String?
    var total = 0
    var stored = 0
}

/// The store coverage checks and resumes from: ThumbnailDiskStore, or a fake in tests.
protocol CoverageStoring: Sendable {
    var fence: MediaFence { get }
    var limit: Int { get }
    func contains(assetID: String, revision: String) -> Bool
    func currentUsage() async -> Int
    func coverageState() async -> CoverageState
    /// Saves the state, unless the store was cleared since `token` was taken from its fence. Whether it did.
    func saveCoverageState(_ state: CoverageState, token: UInt64) async -> Bool
}

extension ThumbnailDiskStore: CoverageStoring {}

/// A page of the photos coverage keeps, read from the index.
struct CoverageRow: Hashable, Sendable {
    let id: String
    let revision: String
    let cursor: CoverageCursor
}

/// A keyset position in the library's order (month and time taken, newest first, then ID).
struct CoverageCursor: Codable, Hashable, Sendable {
    let month: String
    let taken: Double
    let id: String

    var encoded: String? { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } }

    init(month: String, taken: Double, id: String) {
        self.month = month; self.taken = taken; self.id = id
    }

    init?(encoded: String?) {
        guard let encoded, let cursor = try? JSONDecoder().decode(CoverageCursor.self, from: Data(encoded.utf8)) else { return nil }
        self = cursor
    }
}

// MARK: - Progress

/// What Diagnostics shows of coverage. The worker is its only writer.
@MainActor @Observable final class CoverageBoard {
    private(set) var progress = CoverageWorker.Progress()
    @ObservationIgnored private var shown: UInt64 = 0

    fileprivate func show(_ progress: CoverageWorker.Progress, sequence: UInt64) {
        guard sequence > shown else { return }
        shown = sequence
        if self.progress != progress { self.progress = progress }
    }
}

// MARK: - Worker

/// Keeps every grid thumbnail of the account's own timeline on disk, about 12 KB a photo, so
/// scrolling anywhere draws real thumbnails without asking the server (REBUILD_ROADMAP.md T5).
///
/// It pages asset_index by keyset on the index's aggregate reader, newest first, and checks each
/// photo against the thumbnail store's presence map; only the missing ones are downloaded, on the
/// scheduler's coverage band, which never takes more than two of the six download slots and
/// yields every other to the screen. The position is saved after every page, so a kill resumes
/// where it stopped, and once a pass has walked the whole library the index's revision it began
/// at is kept as the mark: a relaunch with nothing changed since makes no request at all, and one
/// after changes that synced while no worker ran, or during a pass an earlier launch began,
/// verifies the library once more without fetching a present file. While the account is open each
/// library change names the photos it touched, and only those are checked again; a reset or an
/// overflow asks for a whole pass. A download that failed leaves the library unverified, so the
/// photo is asked for again after a pause. It downloads only while the conditions allow
/// (CoveragePolicy): the app in front, an unmetered network, no Low Power Mode, the phone not
/// hot, no photo open, and the grid still for a moment. It belongs to one account; once that
/// session ends it never starts again.
final class CoverageWorker: Sendable {
    struct Progress: Hashable, Sendable {
        var total = 0
        var stored = 0
        /// A pass or a recheck has work, whether or not the conditions let it download now.
        var isRunning = false
        var hold: CoverageHold?
    }

    /// What the worker did, for tests.
    struct Statistics: Hashable, Sendable {
        var passes = 0
        var completedPasses = 0
        var pagesRead = 0
        var rechecked = 0
        var downloads = 0
    }

    private struct State {
        var task: Task<Void, Never>?
        var started = false
        var stopped = false
        /// Photos a change named, to check again.
        var recheck = Set<String>()
        /// A change touched the library since the mark was last placed.
        var changed = false
        /// Photos came or went, so the count is read again.
        var countStale = false
        var fullPassWanted = false
        var progress = Progress()
        var statistics = Statistics()
        var sequence: UInt64 = 0
    }

    let conditions: CoverageConditions
    let board: CoverageBoard
    let policy: CoveragePolicy
    private let index: LibraryIndex
    private let store: any CoverageStoring
    private let scheduler: ThumbnailScheduler
    private let changes: @Sendable () async -> AsyncStream<LibraryChange>
    private let authorization: AuthorizationState?
    private let pageSize: Int
    private let startDelay: Duration
    private let failurePause: Duration
    private let wake = Wakeup()
    private let state = Mutex(State())

    /// Past this many photos named by changes, a whole pass is cheaper than remembering them.
    static let recheckLimit = 20_000
    /// How many of the store's cap coverage fills before it waits for the trim to make room.
    static let budgetShare = 0.95
    /// Downloads in flight at once: the coverage band's ceiling.
    static let window = ThumbnailScheduler.ceiling(.coverage)

    /// `changes` is the account's library changes (SyncEngine.changes); `authorization` fences the
    /// worker to its session. `pageSize`, `startDelay` and `failurePause` are for tests: the app
    /// reads 500 rows a page, waits 8 s after the account opens so launch and the first screen come
    /// first, and gives a failing server a minute of peace.
    init(index: LibraryIndex, store: any CoverageStoring, scheduler: ThumbnailScheduler, conditions: CoverageConditions, board: CoverageBoard,
         changes: @escaping @Sendable () async -> AsyncStream<LibraryChange>, authorization: AuthorizationState?,
         policy: CoveragePolicy = .load(), pageSize: Int = 500, startDelay: Duration = .seconds(8), failurePause: Duration = .seconds(60)) {
        self.index = index
        self.store = store
        self.scheduler = scheduler
        self.conditions = conditions
        self.board = board
        self.changes = changes
        self.authorization = authorization
        self.policy = policy
        self.pageSize = max(1, pageSize)
        self.startDelay = startDelay
        self.failurePause = failurePause
    }

    // MARK: Commands

    /// Starts the worker once. Nothing happens after stop, or for a session that has ended.
    func start() {
        let task = state.withLock { state -> Task<Void, Never>? in
            guard !state.started, !state.stopped, authorization?.hasEnded != true else { return nil }
            state.started = true
            let task = Task(priority: .utility) { [weak self] in
                if let self { await run() }
            }
            state.task = task
            return task
        }
        guard task != nil else { return }
        conditions.onChange { [weak self] in self?.wake.signal() }
    }

    /// Stops for good and waits for the work under way to end. A download that has started
    /// finishes into the store, as every download does.
    func stop() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.stopped = true
            defer { state.task = nil }
            return state.task
        }
        conditions.onChange(nil)
        conditions.stop()
        task?.cancel()
        await task?.value
        publish { $0.isRunning = false; $0.hold = nil }
    }

    /// A pass or a recheck has work.
    var isRunning: Bool { state.withLock { $0.progress.isRunning } }
    var progress: Progress { state.withLock { $0.progress } }
    var statistics: Statistics { state.withLock { $0.statistics } }

    private var mayRun: Bool {
        !Task.isCancelled && !state.withLock({ $0.stopped }) && authorization?.hasEnded != true
    }

    // MARK: The loop

    private func run() async {
        if startDelay > .zero { try? await Task.sleep(for: startDelay) }
        guard mayRun else { return }
        // Subscribed before anything is read, so every change from here on is named in memory.
        let stream = await changes()
        let subscription = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                received(change)
            }
        }
        defer { subscription.cancel() }
        // While the worker runs, changes name the photos to check again. Changes that landed
        // while no worker ran, or during a pass an earlier launch began, are named in no memory
        // of this one: until a pass begins here, or the mark is found level with the index, a
        // mark behind the index's revision means one more verification pass, which fetches no
        // present file.
        var trusted = false
        // Rounds in a row in which a download failed; each gives the server a longer pause.
        var failingRounds = 0
        while mayRun {
            guard (try? await index.isReadable()) == true else {
                publish { $0.hold = .libraryNotReady }
                // A completed first sync publishes a change; the backfill ending does not.
                await wake.wait(upTo: .seconds(30))
                continue
            }
            publish { $0.hold = nil }
            let token = store.fence.token()
            var saved = await store.coverageState()
            if saved.policyHash != policy.fingerprint {
                saved = CoverageState(policyHash: policy.fingerprint)
                guard await store.saveCoverageState(saved, token: token) else { continue }
            }
            guard mayRun else { return }
            let revision = (try? await index.derivedRevision()) ?? 0
            let (full, pending, changed) = state.withLock { state in (state.fullPassWanted, state.recheck, state.changed) }
            let behind = !trusted && saved.mark != revision
            // A reset or an overflow walks from the newest photo again, whatever position a pass had.
            if full { saved.cursor = nil }
            // A pass that begins here sees every change from now on; one resumed from an earlier
            // launch did not, so its mark is checked against the index's revision once it ends.
            if saved.cursor == nil { trusted = true }
            let failed: Bool
            if full || saved.cursor != nil || saved.mark == nil || behind {
                state.withLock { $0.fullPassWanted = false }
                failed = await verify(resuming: saved)
            } else if !pending.isEmpty || changed {
                failed = await recheck(pending)
            } else {
                publish { $0.isRunning = false; $0.hold = nil; $0.total = saved.total; $0.stored = saved.stored }
                await wake.wait(upTo: nil)
                continue
            }
            // The photos whose download failed are asked for again, after a pause that doubles
            // with every round that failed, up to sixteen times the first.
            if failed {
                failingRounds += 1
                guard await pauseAfterFailures(failurePause * (1 << (min(failingRounds, 5) - 1))) else { return }
            } else {
                failingRounds = 0
            }
        }
    }

    /// A library change: the photos it names are checked again and the mark follows it, since an
    /// album or a person changing moves the index's revision too; a reset or an overflow asks for
    /// a whole pass instead.
    private func received(_ change: LibraryChange) {
        guard !change.isEmpty else { return }
        state.withLock { state in
            if change.reset || change.overflow {
                state.fullPassWanted = true
                state.recheck.removeAll()
            } else {
                state.changed = true
                if !change.upserted.isEmpty || !change.removed.isEmpty || !change.accessLost.isEmpty { state.countStale = true }
                state.recheck.formUnion(change.upserted.keys)
                state.recheck.formUnion(change.mediaRevisions.keys)
                state.recheck.subtract(change.removed)
                state.recheck.subtract(change.accessLost)
                if state.recheck.count > Self.recheckLimit {
                    state.fullPassWanted = true
                    state.recheck.removeAll()
                }
            }
        }
        wake.signal()
    }

    // MARK: Passes

    /// Walks the library from the saved position, or from the newest photo, checking every photo
    /// against the store and downloading the missing ones. The position and the counts are saved
    /// after each page; at the end the index's revision the pass began at becomes the mark,
    /// unless a download failed on the way. Whether one did.
    private func verify(resuming saved: CoverageState) async -> Bool {
        var kept = saved
        var cursor = CoverageCursor(encoded: saved.cursor)
        if cursor == nil {
            // From the newest photo. A change after this is named in memory, or found at the
            // next launch as a mark behind the index's revision.
            guard let revision = try? await index.derivedRevision() else {
                await wake.wait(upTo: .seconds(30))
                return false
            }
            kept.stored = 0
            kept.passMark = revision
        }
        guard let total = try? await index.coverageCount() else {
            await wake.wait(upTo: .seconds(30))
            return false
        }
        kept.total = total
        state.withLock { $0.statistics.passes += 1 }
        publish { $0.isRunning = true; $0.total = total; $0.stored = kept.stored }
        var failures = 0
        var failed = false
        while mayRun {
            // Taken before the page is read: a store cleared after this refuses the page's
            // writes and the save of its position alike.
            let token = store.fence.token()
            guard let page = try? await index.coveragePage(after: cursor, limit: pageSize) else {
                await wake.wait(upTo: .seconds(30))
                return failed
            }
            state.withLock { $0.statistics.pagesRead += 1 }
            if page.isEmpty {
                // Walked to the end: verified through the revision the pass began at. What
                // changed since was named by changes that wait to be checked; a reset meanwhile
                // means another pass, and a failed download a library not verified, so the
                // next pass asks for the photo again.
                let verified = !state.withLock({ $0.fullPassWanted })
                kept.cursor = nil
                kept.mark = verified ? kept.passMark : nil
                kept.passMark = nil
                kept.stored = min(kept.stored, kept.total)
                // A store cleared meanwhile refuses the save: this pass ends and the next starts
                // from the newest photo with fresh counts. Clear browsing cache leaves the store
                // and the pass alone (G2).
                guard await store.saveCoverageState(kept, token: token) else { return failed }
                state.withLock { $0.statistics.completedPasses += 1 }
                publish { $0.total = kept.total; $0.stored = kept.stored }
                return failed
            }
            var present = 0
            var missing: [(id: String, revision: String)] = []
            for row in page {
                if store.contains(assetID: row.id, revision: row.revision) { present += 1 } else { missing.append((row.id, row.revision)) }
            }
            let outcome = await download(missing, token: token, failures: &failures)
            if !outcome.failed.isEmpty {
                // Saved with the position, so the pass ends unverified in this launch or a later one.
                failed = true
                kept.passMark = nil
            }
            guard !outcome.interrupted else { return failed }
            // Committed only once the page is done, so a page worked twice is never counted twice.
            kept.stored += present + outcome.fetched
            cursor = page.last?.cursor
            kept.cursor = cursor?.encoded
            guard await store.saveCoverageState(kept, token: token) else { return failed }
            publish { $0.stored = kept.stored }
        }
        return failed
    }

    /// Checks the photos changes named: those still in the covered set and not on disk are
    /// downloaded. The count follows the index when photos came or went, and the mark the changes
    /// once every download succeeded; the photos that failed wait to be checked again. Whether
    /// one failed.
    private func recheck(_ ids: Set<String>) async -> Bool {
        let countStale = state.withLock { state -> Bool in
            state.recheck.subtract(ids)
            state.changed = false
            defer { state.countStale = false }
            return state.countStale
        }
        // Kept for the next recheck when this one could not finish.
        func putBack() {
            state.withLock { state in
                state.recheck.formUnion(ids)
                state.changed = true
                state.countStale = state.countStale || countStale
            }
        }
        let revision = (try? await index.derivedRevision()) ?? 0
        guard let revisions = try? await index.coverageRevisions(of: Array(ids)) else {
            putBack()
            await wake.wait(upTo: .seconds(30))
            return false
        }
        state.withLock { $0.statistics.rechecked += ids.count }
        let token = store.fence.token()
        let missing = revisions.filter { !store.contains(assetID: $0.key, revision: $0.value) }.map { (id: $0.key, revision: $0.value) }.sorted { $0.id < $1.id }
        if !missing.isEmpty { publish { $0.isRunning = true } }
        var failures = 0
        let outcome = await download(missing, token: token, failures: &failures)
        let failed = !outcome.failed.isEmpty
        guard !outcome.interrupted else {
            putBack()
            return failed
        }
        if failed {
            // Checked again after a pause; the mark waits for them, so a kill meanwhile finds
            // the index past it at the next launch.
            state.withLock { state in
                state.recheck.formUnion(outcome.failed)
                state.changed = true
            }
        }
        var kept = await store.coverageState()
        guard mayRun, kept.cursor == nil, kept.mark != nil else { return failed }
        if countStale, let total = try? await index.coverageCount() { kept.total = total }
        kept.stored = min(kept.stored + outcome.fetched, kept.total)
        // Verified through this revision, unless more changes already wait.
        let quiet = state.withLock { state in state.recheck.isEmpty && !state.fullPassWanted && !state.changed }
        if quiet { kept.mark = revision }
        // A store cleared meanwhile refuses the save; the next pass starts from the newest photo.
        guard await store.saveCoverageState(kept, token: token) else { return failed }
        publish { $0.total = kept.total; $0.stored = kept.stored }
        return failed
    }

    // MARK: Downloads

    private struct Outcome {
        var fetched = 0
        /// The photos whose download failed.
        var failed: [String] = []
        var interrupted = false
    }

    /// Downloads these photos onto the disk, at most `window` at a time, each only once the
    /// conditions allow. After three failures in a row what is in flight ends and the server gets
    /// a pause. Interrupted when the worker stops or its session ends.
    private func download(_ photos: [(id: String, revision: String)], token: UInt64, failures: inout Int) async -> Outcome {
        var outcome = Outcome()
        guard !photos.isEmpty else { return outcome }
        guard await waitForRoom() else { outcome.interrupted = true; return outcome }
        var consecutive = failures
        await withTaskGroup(of: (id: String, stored: Bool?).self) { group in
            var inFlight = 0
            func settle(_ result: (id: String, stored: Bool?)) {
                switch result.stored {
                case .some(true): outcome.fetched += 1; consecutive = 0
                case .some(false): outcome.failed.append(result.id); consecutive += 1
                case .none: break
                }
            }
            for photo in photos {
                if inFlight >= Self.window, let next = await group.next() {
                    inFlight -= 1
                    settle(next)
                }
                if consecutive >= 3 {
                    for await result in group { inFlight -= 1; settle(result) }
                    consecutive = 0
                    guard await pauseAfterFailures(failurePause) else { outcome.interrupted = true; break }
                }
                // Checked just before each download starts, so none starts during a hold.
                guard await waitUntilClear() else { outcome.interrupted = true; break }
                let scheduler = scheduler
                group.addTask {
                    do {
                        try await scheduler.store(assetID: photo.id, revision: photo.revision, band: .coverage, token: token)
                        return (photo.id, true)
                    } catch is CancellationError {
                        // The photo was forgotten or the store cleared meanwhile: not a failure.
                        return (photo.id, nil)
                    } catch {
                        return (photo.id, false)
                    }
                }
                inFlight += 1
                state.withLock { $0.statistics.downloads += 1 }
            }
            for await result in group { settle(result) }
        }
        failures = consecutive
        if Task.isCancelled || !mayRun { outcome.interrupted = true }
        return outcome
    }

    /// A pause that leaves a failing server alone, which a change of conditions or a library
    /// change meanwhile does not cut short. False once the worker may not run.
    private func pauseAfterFailures(_ pause: Duration) async -> Bool {
        publish { $0.hold = .serverFailing }
        let deadline = ContinuousClock.now + pause
        while mayRun {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return true }
            await wake.wait(upTo: remaining)
        }
        return false
    }

    /// Waits until the conditions allow a download. False once the worker may not run.
    private func waitUntilClear() async -> Bool {
        while mayRun {
            let now = conditions.now()
            guard let hold = policy.hold(conditions.snapshot, now: now) else {
                publish { $0.hold = nil }
                return true
            }
            publish { $0.hold = hold }
            if case .settling(let until) = hold {
                await wake.wait(upTo: .seconds(max(0.05, until - now)))
            } else {
                await wake.wait(upTo: nil)
            }
        }
        return false
    }

    /// Waits while the store is at its cap: the trim makes room least recently viewed first, and
    /// filling it faster would only evict what the grid showed. False once the worker may not run.
    private func waitForRoom() async -> Bool {
        while mayRun {
            let used = await store.currentUsage()
            guard Double(used) >= Double(store.limit) * Self.budgetShare else { return true }
            publish { $0.hold = .diskBudget }
            await wake.wait(upTo: .seconds(60))
        }
        return false
    }

    // MARK: Progress

    /// Shows the progress on the board once it changed; the main actor hears of nothing else.
    private func publish(_ change: (inout Progress) -> Void) {
        let update = state.withLock { state -> (progress: Progress, sequence: UInt64)? in
            let before = state.progress
            change(&state.progress)
            guard state.progress != before else { return nil }
            state.sequence &+= 1
            return (state.progress, state.sequence)
        }
        guard let update else { return }
        let board = board
        Task { @MainActor in board.show(update.progress, sequence: update.sequence) }
    }
}

/// Lets one loop sleep until something happens, a time passes or it is cancelled. A signal that
/// comes while nobody waits is kept for the next wait.
final class Wakeup: Sendable {
    private struct State {
        var signaled = false
        var waiter: (id: UUID, continuation: CheckedContinuation<Void, Never>)?
    }
    private let state = Mutex(State())

    func signal() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter.continuation
            }
            state.signaled = true
            return nil
        }
        continuation?.resume()
    }

    /// Returns on a signal, after `timeout` if given, or when the task is cancelled.
    func wait(upTo timeout: Duration?) async {
        let id = UUID()
        let timer = timeout.map { timeout in
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resume(id)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state -> Bool in
                    if state.signaled || Task.isCancelled {
                        state.signaled = false
                        return true
                    }
                    state.waiter = (id, continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            resume(id)
        }
        timer?.cancel()
    }

    private func resume(_ id: UUID) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.waiter, waiter.id == id else { return nil }
            state.waiter = nil
            return waiter.continuation
        }
        continuation?.resume()
    }
}

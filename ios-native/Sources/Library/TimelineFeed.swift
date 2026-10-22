import Foundation
import IlyichPlatform
import Synchronization

/// Takes the feed's months as they arrive, on the main actor. A delivery names the ticket of the
/// feed it belongs to, so a month of a feed the user has left is dropped.
protocol TimelineFeedConsumer: AnyObject, Sendable {
    /// A month's photos. `fresh` is false for a load that began before the month was invalidated:
    /// shown, but read again while the grid wants it. `evicting` are months let go to make room.
    @MainActor func monthLoaded(_ ticket: TimelineFeed.Ticket, month: MonthKey, assets: [Asset], fresh: Bool, evicting: [MonthKey])
    @MainActor func monthFailed(_ ticket: TimelineFeed.Ticket, month: MonthKey, message: String)
}

/// The months of the feed shown, keyed by month and loaded as the grid needs them (F2).
///
/// At most three months load at a time and six wait, the month on screen or the one a jump lands
/// on first; twelve stay resident, with the months on screen and the jump's target protected from
/// eviction. A month's load carries the ticket of the feed it was asked for, and the slot it held
/// is released before its month is delivered, so the next month starts while the main thread
/// draws. `assets(of:)` joins a load on its way instead of polling for it. A month that failed for
/// a passing reason (no network, a timeout, a busy server) is asked again while it stays on
/// screen, after 1 s, then 2, 4, 8, 16 and every 30 s; a refusal waits for Retry. `invalidate`
/// marks months stale: they stay shown and are read again when the grid wants them, and a load on
/// its way is kept, not restarted; a month that failed is forgotten, so the grid can ask again.
///
/// A photo the store took out before the source had changed (a deletion or a lock made here, a
/// photo that left a feed) is withheld (F4): a month read before the source says so leaves it out,
/// in this feed and in the next one opened, so the library a filter clears back to cannot bring it
/// back either. A change that names the photo, or the sync that follows the store's own change,
/// confirms it: reads begun after that are trusted, and the months it was taken out of are read
/// again, so a photo taken out by mistake comes back.
actor TimelineFeed {
    /// Names one opening of a feed: its query and the plan its months come from.
    struct Ticket: Hashable, Sendable {
        private let id = UUID()
        init() {}
    }

    /// The months on screen as the grid last reported them, read at once rather than through the
    /// command queue. The viewport command behind it in the queue decides what loads; this only
    /// decides what stays: a load that lands while that command is on its way must not evict the
    /// month that has just scrolled on, as the store's synchronous trim never did before F2.
    final class Viewport: Sendable {
        private let state = Mutex<Set<MonthKey>>([])
        var months: Set<MonthKey> { state.withLock { $0 } }
        func show(_ months: Set<MonthKey>) { state.withLock { $0 = months } }
    }

    enum Command: Sendable {
        case attach(any TimelineFeedConsumer)
        /// A feed opens: every month of the one before is dropped, loads on their way included.
        case open(Ticket, LibraryQuery, QueryPlan)
        /// The feed's months in the grid's order, and the bucket the source reads for each month
        /// it has; a month without one (only on the phone) is never asked for.
        case months([MonthKey], buckets: [MonthKey: String])
        /// The months on screen; they and their neighbours are asked for, the months the grid
        /// left behind give up their loads, and nothing queued before stays.
        case viewport(visible: Set<MonthKey>)
        /// The month a rail jump or a date navigation lands on: protected, and first in line.
        case target(MonthKey?)
        /// Months asked for by name, behind what the grid wants.
        case request([MonthKey])
        /// Months to read again when wanted; nil is every month.
        case invalidate(Set<MonthKey>?)
        case retryFailed
        /// The months of a feed opened again, as they were left.
        case restore([MonthKey: [Asset]])
        case replace(Asset)
        case remove(Set<String>)
        /// Photos the store took out before the source changed: no read of the feeds `scope`
        /// names brings them back until they are confirmed.
        case withhold(Set<String>, from: Withholding)
        /// Photos a change named, or every photo withheld when nil, as after the sync that follows
        /// the store's own change: the source has them as they now are.
        case confirm(Set<String>?)
        /// Photos a change took out: only a load already on its way, which read the source before
        /// the change, still leaves them out.
        case forget(Set<String>)
        case close
    }

    /// The feeds a withheld photo stays out of.
    enum Withholding: Hashable, Sendable {
        /// Every feed with this trash state: the photo was deleted, locked, put in Trash or taken
        /// out of it.
        case trash(LibraryQuery.Trash)
        /// This feed only: the photo left it, as an unfavorited photo leaves Favorites.
        case query(LibraryQuery)
        /// Every feed.
        case all
    }

    static let concurrentLimit = 3
    static let queueLimit = 6
    static let residentLimit = 12
    static let retryBackoff: ClosedRange<Duration> = .seconds(1)...(.seconds(30))

    private struct Session { let ticket: Ticket; let query: LibraryQuery; let plan: QueryPlan }
    /// `sequence` orders the loads by when they began, which says whether a load read the source
    /// before a change confirmed a withheld photo.
    private struct Load { let id: UUID; let sequence: UInt64; let task: Task<[Asset], any Error>; var stale = false }
    private struct Failure { var message: String; var attempts = 0; var transient = false; var due = false }
    /// A withheld photo: the feeds it stays out of, the first load that may show it again (`.max`
    /// until it is confirmed), and the months it was taken out of, read again once it is.
    private struct Withheld { var scope: Withholding; var trustedFrom: UInt64; var months: Set<MonthKey> = [] }

    private let source: any TimelineSource
    /// What the grid shows right now, ahead of the viewport command that follows it.
    private let onScreen: Viewport
    private weak var consumer: (any TimelineFeedConsumer)?
    private var session: Session?
    private var order: [MonthKey] = []
    private var positions: [MonthKey: Int] = [:]
    private var buckets: [MonthKey: String] = [:]
    private var resident: [MonthKey: [Asset]] = [:]
    /// Resident months to read again when the grid wants them.
    private var stale: Set<MonthKey> = []
    /// Resident months, the least recently loaded first.
    private var recent: [MonthKey] = []
    private var loads: [MonthKey: Load] = [:]
    private var queue: [MonthKey] = []
    private var visible: Set<MonthKey> = []
    /// The first and last month on screen as of the last viewport, to tell which way the grid moves.
    private var shown: ClosedRange<Int>?
    private var target: MonthKey?
    private var failures: [MonthKey: Failure] = [:]
    private var retries: [MonthKey: Task<Void, Never>] = [:]
    /// Photos no read before their confirmation may bring back. They outlive the feed they were
    /// taken out of: the next one opened reads the same source.
    private var withheld: [String: Withheld] = [:]
    /// The sequence the next load begins with.
    private var nextLoad: UInt64 = 1

    init(source: any TimelineSource, viewport: Viewport = Viewport()) { self.source = source; onScreen = viewport }

    /// Commands in the order they were given.
    func handle(_ commands: [Command]) {
        for command in commands {
            switch command {
            case .attach(let consumer): self.consumer = consumer
            case .open(let ticket, let query, let plan): open(ticket, query: query, plan: plan)
            case .months(let order, let buckets): months(order, buckets: buckets)
            case .viewport(let visible): viewportChanged(visible)
            case .target(let month): targetChanged(month)
            case .request(let months):
                for month in months { enqueue(month) }
                startQueued()
            case .invalidate(let months): invalidate(months)
            case .retryFailed: retryFailed()
            case .restore(let months): restore(months)
            case .replace(let asset): replace(asset)
            case .remove(let ids): remove(ids)
            case .withhold(let ids, let scope): withhold(ids, from: scope)
            case .confirm(let ids): confirm(ids)
            case .forget(let ids): forget(ids)
            case .close: close()
            }
        }
    }

    /// A month's photos: the resident ones, or those of the load on its way, joined. A month not
    /// yet asked for starts now, ahead of the queue. `commands` are handled first, in order.
    func assets(of month: MonthKey, ticket: Ticket, after commands: [Command] = []) async throws -> [Asset] {
        handle(commands)
        guard let session, session.ticket == ticket else { throw CancellationError() }
        if let assets = resident[month], !stale.contains(month) { return assets }
        guard buckets[month] != nil else { return [] }
        if loads[month] == nil {
            failures[month]?.due = true
            queue.removeAll { $0 == month }
            start(month)
        }
        guard let load = loads[month] else { return resident[month] ?? [] }
        return try await load.task.value
    }

    /// The whole-feed snapshots kept under Caches/IlyichTimelines until F2. The index is the
    /// cache now; the folder goes once, at launch.
    nonisolated static func deleteLegacySnapshots(cachesDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) {
        try? FileManager.default.removeItem(at: cachesDirectory.appendingPathComponent("IlyichTimelines", isDirectory: true))
    }

    /// A failure that passes by itself: no network, a timeout, a busy or restarting server. A
    /// refusal does not.
    static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case let failure as TransportFailure:
            switch failure {
            case .unreachable(let code): return isTransient(code)
            case .endpointChanged, .allEndpointsUnavailable, .systemCancelled: return true
            }
        case ServerFailure.http(let status, _): return [408, 425, 429].contains(status) || status >= 500
        case ServerFailure.undecodable: return true
        case let failure as URLError: return isTransient(failure.code)
        default: return false
        }
    }

    private static func isTransient(_ code: URLError.Code) -> Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
             .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
             .badServerResponse, .cannotParseResponse, .cancelled:
            return true
        default: return false
        }
    }

    /// The wait before trying a month again: 1 s doubled per failure, at most 30 s.
    static func backoff(attempts: Int) -> Duration {
        min(retryBackoff.upperBound, retryBackoff.lowerBound * (1 << max(0, min(attempts - 1, 5))))
    }

    // MARK: - Sessions

    private func open(_ ticket: Ticket, query: LibraryQuery, plan: QueryPlan) {
        close()
        session = Session(ticket: ticket, query: query, plan: plan)
    }

    private func close() {
        for load in loads.values { load.task.cancel() }
        for retry in retries.values { retry.cancel() }
        session = nil; order = []; positions = [:]; buckets = [:]; resident = [:]; stale = []; recent = []
        loads = [:]; queue = []; visible = []; shown = nil; target = nil; failures = [:]; retries = [:]
    }

    private func months(_ order: [MonthKey], buckets: [MonthKey: String]) {
        self.order = order; self.buckets = buckets
        positions = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for month in Array(resident.keys) where buckets[month] == nil { resident[month] = nil; stale.remove(month) }
        recent.removeAll { buckets[$0] == nil }
        for (month, load) in loads where buckets[month] == nil { load.task.cancel() }
        queue.removeAll { buckets[$0] == nil }
        for month in Array(failures.keys) where buckets[month] == nil { failures[month] = nil; cancelRetry(month) }
        requestWanted()
    }

    private func restore(_ months: [MonthKey: [Asset]]) {
        for (month, assets) in months where buckets[month] != nil && loads[month] == nil {
            // Read before anything was withheld.
            resident[month] = withholding(assets, readFrom: 0); stale.remove(month)
        }
        // Loaded in the feed's order, so the oldest months make room first.
        recent = resident.keys.sorted { (positions[$0] ?? 0) > (positions[$1] ?? 0) }
        requestWanted()
    }

    private func replace(_ asset: Asset) {
        for (month, assets) in resident {
            if let index = assets.firstIndex(where: { $0.id == asset.id }) { resident[month]?[index] = asset }
        }
    }

    private func remove(_ ids: Set<String>) {
        for month in Array(resident.keys) { resident[month]?.removeAll { ids.contains($0.id) } }
    }

    /// Comes before the store's `remove`, while the months still hold the photos.
    private func withhold(_ ids: Set<String>, from scope: Withholding) {
        var months: [String: Set<MonthKey>] = [:]
        for (month, assets) in resident {
            for asset in assets where ids.contains(asset.id) { months[asset.id, default: []].insert(month) }
        }
        for id in ids {
            withheld[id] = Withheld(scope: scope, trustedFrom: .max, months: months[id, default: []].union(withheld[id]?.months ?? []))
        }
    }

    /// The source has these photos as they now are: a load that begins from now on reads them as
    /// they are, while one already on its way still leaves them out. The months they were taken out
    /// of are read again when the grid wants them, so a photo taken out by mistake comes back.
    private func confirm(_ ids: Set<String>?) {
        var reread = Set<MonthKey>()
        for id in ids ?? Set(withheld.keys) {
            guard var entry = withheld[id], entry.trustedFrom == .max else { continue }
            entry.trustedFrom = nextLoad
            reread.formUnion(entry.months)
            withheld[id] = entry
        }
        forgetConfirmed()
        if !reread.isEmpty { invalidate(reread) }
    }

    /// A change took these out, and the store with it: only loads already on their way read them.
    private func forget(_ ids: Set<String>) {
        for id in ids { withheld[id] = Withheld(scope: .all, trustedFrom: nextLoad) }
        forgetConfirmed()
    }

    /// What a load that began at `sequence` may show of `assets`.
    private func withholding(_ assets: [Asset], readFrom sequence: UInt64) -> [Asset] {
        guard !withheld.isEmpty, let query = session?.query else { return assets }
        return assets.filter { asset in
            guard let entry = withheld[asset.id], sequence < entry.trustedFrom else { return true }
            switch entry.scope {
            case .all: return false
            case .trash(let trash): return query.trash != trash
            case .query(let withheldFrom): return query != withheldFrom
            }
        }
    }

    /// A confirmed photo no load on its way began before is trusted everywhere: it is let go.
    private func forgetConfirmed() {
        let oldest = loads.values.map(\.sequence).min() ?? nextLoad
        withheld = withheld.filter { $0.value.trustedFrom > oldest }
    }

    private func invalidate(_ months: Set<MonthKey>?) {
        // The failed months too: a sync's reload takes the banner and its Retry down, so a month
        // that was refused must be askable again when the grid wants it, not placeholders for good.
        for month in months ?? Set(resident.keys).union(loads.keys).union(failures.keys) {
            if resident[month] != nil { stale.insert(month) }
            loads[month]?.stale = true
            failures[month] = nil; cancelRetry(month)
        }
        requestWanted()
    }

    /// The banner's Retry: every month that failed is asked for again, in the feed's order, behind
    /// what the grid wants.
    private func retryFailed() {
        let failed = failures.keys.sorted { (positions[$0] ?? .max) < (positions[$1] ?? .max) }
        for month in failed { cancelRetry(month) }
        failures = [:]
        for month in failed { enqueue(month) }
        requestWanted()
    }

    // MARK: - The viewport

    private func viewportChanged(_ visible: Set<MonthKey>) {
        self.visible = visible
        if let target, visible.contains(target) { self.target = nil }
        dropLoadsLeftBehind(near: visible.compactMap { positions[$0] }.sorted())
        // Prefetch cannot displace the viewport or accumulate every crossed month.
        queue = []
        requestWanted()
        reconcileRetries()
    }

    private func targetChanged(_ month: MonthKey?) {
        target = month
        if let month {
            // The month a jump lands on goes first; the months a drag passed are dropped before they start.
            queue = []
            enqueue(month, first: true)
            startQueued()
        }
        reconcileRetries()
    }

    /// The grid has moved on: a month it left behind that is still loading gives its slot to the
    /// months on screen. One that has started stops; the month is asked for again if the grid
    /// comes back to it. Months ahead of the grid keep loading, and so does the month a jump lands on.
    private func dropLoadsLeftBehind(near sections: [Int]) {
        guard let first = sections.first, let last = sections.last else { return }
        // The grid starts at the top of the feed.
        let previous = shown ?? 0...0
        shown = first...last
        guard !loads.isEmpty, first != previous.lowerBound || last != previous.upperBound else { return }
        let down = first != previous.lowerBound ? first > previous.lowerBound : last > previous.upperBound
        for (month, load) in loads where month != target {
            guard let section = positions[month] else { continue }
            if down ? section < first - 2 : section > last + 2 { load.task.cancel() }
        }
    }

    /// The months the grid asks for, the most wanted first: the one a jump lands on, those on
    /// screen, then their neighbours.
    private func wanted() -> [MonthKey] {
        var months: [MonthKey] = []
        if let target { months.append(target) }
        let ordered = visible.compactMap { positions[$0] }.sorted()
        months += ordered.map { order[$0] }
        for section in ordered {
            for neighbour in [section + 1, section - 1] where order.indices.contains(neighbour) && !visible.contains(order[neighbour]) {
                months.append(order[neighbour])
            }
        }
        return months
    }

    /// Queues what the grid wants ahead of anything asked for by name.
    private func requestWanted() {
        let priority = wanted().filter(canAsk)
        queue = priority + queue.filter { !priority.contains($0) }
        trimQueue()
        startQueued()
    }

    /// On screen, as of the last viewport handled or the one the grid has reported since, or the
    /// month a jump lands on.
    private func isProtected(_ month: MonthKey) -> Bool {
        visible.contains(month) || target == month || onScreen.months.contains(month)
    }

    /// A month on screen or beside one, or the one a jump lands on.
    private func isWanted(_ month: MonthKey) -> Bool {
        if isProtected(month) { return true }
        guard let section = positions[month] else { return false }
        return [section - 1, section + 1].contains { order.indices.contains($0) && visible.contains(order[$0]) }
    }

    // MARK: - The queue

    /// Whether a month has something to load: the source has it, it is not resident and current,
    /// not on its way, and not failed, unless its retry is due.
    private func canAsk(_ month: MonthKey) -> Bool {
        guard buckets[month] != nil, loads[month] == nil, resident[month] == nil || stale.contains(month) else { return false }
        return failures[month].map(\.due) ?? true
    }

    private func enqueue(_ month: MonthKey, first: Bool = false) {
        guard canAsk(month) else { return }
        if first || isProtected(month) {
            queue.removeAll { $0 == month }
            queue.insert(month, at: 0)
        } else if !queue.contains(month) {
            queue.append(month)
        }
        trimQueue()
    }

    private func trimQueue() {
        if queue.count > Self.queueLimit { queue.removeLast(queue.count - Self.queueLimit) }
    }

    private func startQueued() {
        while loads.count < Self.concurrentLimit, !queue.isEmpty {
            let month = queue.removeFirst()
            guard canAsk(month) else { continue }
            start(month)
        }
    }

    private func start(_ month: MonthKey) {
        guard let session, let bucket = buckets[month] else { return }
        failures[month]?.due = false
        let id = UUID(), ticket = session.ticket, query = session.query, plan = session.plan, source = source
        let sequence = nextLoad
        nextLoad += 1
        let task = Task {
            let result: Result<[Asset], any Error>
            do { result = .success(try await FeedMonthProbe.measure { try await source.month(bucket, of: query, plan: plan) }) }
            catch { result = .failure(error) }
            return try await landed(month, load: id, ticket: ticket, result: result)
        }
        loads[month] = Load(id: id, sequence: sequence, task: task)
    }

    /// A load has ended. Its slot goes first, so the next month starts while this one is
    /// delivered; whoever joined the load resumes after the delivery.
    private func landed(_ month: MonthKey, load id: UUID, ticket: Ticket, result: Result<[Asset], any Error>) async throws -> [Asset] {
        guard let load = loads[month], load.id == id else { throw CancellationError() }
        loads[month] = nil
        defer { forgetConfirmed() }
        guard let session, session.ticket == ticket else { throw CancellationError() }
        switch result {
        case .success(let read):
            let assets = withholding(read, readFrom: load.sequence)
            let fresh = !load.stale
            resident[month] = assets
            recent.removeAll { $0 == month }; recent.append(month)
            if fresh { stale.remove(month); failures[month] = nil; cancelRetry(month) }
            else {
                // Read before the month was invalidated: shown, and read again if the grid wants it.
                stale.insert(month)
                if isWanted(month) { enqueue(month) }
            }
            let evicted = evict()
            // The queue holds a few months at a time; a sparse feed (an album with a photo or two a
            // month) shows more than that on one screen, so the rest are asked for as slots free.
            requestWanted()
            await consumer?.monthLoaded(ticket, month: month, assets: assets, fresh: fresh, evicting: evicted)
            return assets
        case .failure(let error):
            if Task.isCancelled {
                // Dropped for a month the grid left behind (the server answers with URLError.cancelled),
                // not failed; asked for again if the grid is back on it.
                if isWanted(month) { enqueue(month) }
                requestWanted()
                throw CancellationError()
            }
            // A cancellation that was not this load's (the transport shut down under it) passes
            // like a lost connection, and is nothing to show.
            let cancelled = error is CancellationError
            var failure = failures[month] ?? Failure(message: "")
            failure.message = error.localizedDescription; failure.attempts += 1
            failure.transient = cancelled || Self.isTransient(error); failure.due = false
            failures[month] = failure
            scheduleRetry(month)
            // The rest of the screen goes on; this month waits for its retry or Retry.
            requestWanted()
            if !cancelled { await consumer?.monthFailed(ticket, month: month, message: failure.message) }
            throw error
        }
    }

    /// Keeps the twelve most recently loaded months, and any on screen or being jumped to.
    private func evict() -> [MonthKey] {
        var evicted: [MonthKey] = []
        while recent.count > Self.residentLimit, let index = recent.firstIndex(where: { !isProtected($0) }) {
            let month = recent.remove(at: index)
            resident[month] = nil; stale.remove(month)
            evicted.append(month)
        }
        return evicted
    }

    // MARK: - Retries

    /// Only while someone listens: a feed whose store is gone must not keep asking.
    private func scheduleRetry(_ month: MonthKey) {
        guard session != nil, consumer != nil, let failure = failures[month], failure.transient, !failure.due,
              isProtected(month), retries[month] == nil else { return }
        let delay = Self.backoff(attempts: failure.attempts)
        retries[month] = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            retryDue(month)
        }
    }

    private func retryDue(_ month: MonthKey) {
        retries[month] = nil
        guard consumer != nil, failures[month] != nil, isProtected(month) else { return }
        failures[month]?.due = true
        enqueue(month, first: true)
        startQueued()
    }

    private func cancelRetry(_ month: MonthKey) {
        retries[month]?.cancel(); retries[month] = nil
    }

    /// A failed month that left the screen stops retrying; one that came back starts again.
    private func reconcileRetries() {
        for month in Array(retries.keys) where !isProtected(month) { cancelRetry(month) }
        for month in failures.keys { scheduleRetry(month) }
    }
}

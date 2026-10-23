import Foundation
import Network
import Synchronization

/// The disk side of grid thumbnails the scheduler needs: ThumbnailDiskStore, or a fake in tests.
protocol ThumbnailStoring: Sendable {
    var fence: MediaFence { get }
    func contains(assetID: String, revision: String) -> Bool
    func data(assetID: String, revision: String) -> Data?
    func enqueueWrite(_ data: Data, assetID: String, revision: String, token: UInt64)
}

extension ThumbnailDiskStore: ThumbnailStoring {}

/// A grid thumbnail on its way to the main thread, or the news that it could not be loaded.
struct ThumbnailDelivery: Sendable {
    /// As ThumbnailKey.assetID names it.
    let assetID: String
    let revision: String
    /// Nil when the photo could not be loaded.
    let image: PreparedImage?
    /// Where the bytes came from.
    let fromNetwork: Bool
    /// A phone photo Photos holds only in iCloud, which the grid never downloads.
    var inCloud = false
}

/// The one place grid thumbnails are loaded. Grids say what they want as a whole, replacing what
/// they wanted before (a latest-wins mailbox); the viewer, feature tiles and the coverage warmer
/// ask for single photos and wait. Each photo revision has one job, whoever wants it.
///
/// - Disk decodes run on a few lanes off the main thread, most urgent band first. While the grid
///   scrubs or passes photos faster than they could arrive (ViewportPolicy), the photo that came
///   on screen last decodes first; otherwise the one nearest the middle. A lane checks the job's
///   wanted flag before reading the file, so a photo that scrolled away is never decoded.
/// - While the grid is fast, only where it will land (the target band) may download; the screen
///   is served from memory and the disk. The decision stands between the policy's two speeds, so
///   a speed hovering near one does not start and stop downloads every frame.
/// - Photos renders phone photos' thumbnails on the same lanes, through the device source, which
///   also keeps Photos' caching manager one window ahead of the grid (T6). They never download.
///   One Photos could not render (gone, or only in iCloud) waits like a failing download, twice
///   as long after each failure, instead of being asked of Photos on every demand.
/// - Downloads start most urgent band first, each band only while fewer downloads than its
///   ceiling are running, so coverage never takes the slots the screen needs. A download that has
///   started finishes and is stored even if nobody wants it any more: the server does the work
///   either way. Its bytes are decoded and delivered straight away, before the disk write ends.
/// - Every job carries the media fence's token from when it was asked for, and the scheduler's
///   generation, so a photo forgotten or a store cleared meanwhile is neither stored nor shown.
/// - Grid deliveries are batched: everything that finished before the main thread gets to it
///   arrives in one main-thread hop.
final class ThumbnailScheduler: Sendable {
    typealias Source = UUID

    /// A download for a band starts only while fewer than this many are running.
    static func ceiling(_ band: DemandBand) -> Int {
        switch band {
        case .visible, .target: 6
        case .ahead, .explicit: 5
        case .behind: 4
        case .coverage: 2
        }
    }

    private struct Key: Hashable, Sendable {
        let assetID: String
        let revision: String
    }

    private final class Flag: Sendable {
        let wanted = Atomic<Bool>(true)
    }

    private struct Want {
        var band: DemandBand
        var rank: Int
        var shortSide: Int
        var network: Bool
        /// Negated order of arrival on screen while scrubbing, so the newest sorts first; zero otherwise.
        var lifo: Int = 0
        /// False for coverage: the bytes only need to reach the disk.
        var decode = true

        /// The more urgent of two wants, at the larger size, with the network if either may use it.
        func merged(_ other: Want) -> Want {
            var result = (other.band, other.lifo, other.rank) < (band, lifo, rank) ? other : self
            result.shortSide = max(shortSide, other.shortSide)
            result.network = network || other.network
            result.decode = decode || other.decode
            return result
        }
    }

    private struct Waiter {
        let want: Want
        let continuation: CheckedContinuation<PreparedImage?, Error>
    }

    private enum Phase { case idle, decoding, fetching }

    private struct Job {
        let key: Key
        let token: UInt64
        let generation: Int
        /// The phone photo this is, when Photos renders it instead of the disk or the server.
        var device: DeviceAssetID?
        var grid: [Source: Want] = [:]
        var waiters: [UUID: Waiter] = [:]
        var phase = Phase.idle
        var onDisk: Bool
        /// Downloaded bytes not decoded yet.
        var fetched: Data?
        var decodingSide = 0
        var flag = Flag()
        var download: Task<Void, Never>?

        var isWanted: Bool { !grid.isEmpty || !waiters.isEmpty }

        var want: Want? {
            var result: Want?
            for want in grid.values { result = result.map { $0.merged(want) } ?? want }
            for waiter in waiters.values { result = result.map { $0.merged(waiter.want) } ?? waiter.want }
            return result
        }
    }

    private struct DeviceWindow {
        var ids: Set<DeviceAssetID>
        var pixels: Int
    }

    private struct State {
        var jobs: [Key: Job] = [:]
        /// Each grid's latest demand not yet worked in.
        var mailbox: [Source: ViewportDemand] = [:]
        var mailboxScheduled = false
        /// The photos each grid wants now.
        var wanted: [Source: Set<Key>] = [:]
        /// The phone photos each grid wants that memory lacks, for Photos to render ahead.
        var deviceWindows: [Source: DeviceWindow] = [:]
        /// Whether each grid passes photos faster than they could arrive, as of its last demand.
        var fast: [Source: Bool] = [:]
        var serial = 0
        var decoding = 0
        var fetching = 0
        var generation = 0
        var retryScheduled: TimeInterval?
    }

    private struct DecodeWork {
        let key: Key
        let generation: Int
        let token: UInt64
        let side: Int
        let bytes: Data?
        let flag: Flag
        /// Set when Photos renders this one instead of a lane decoding a file.
        let device: DeviceAssetID?
    }

    private let state = Mutex(State())
    private let store: any ThumbnailStoring
    private let memory: DecodedThumbnailCache
    private let fetcher: ThumbnailFetcher
    /// Phone photos' thumbnails, when the account browses the phone's photos too.
    private let device: (any DeviceThumbnailProviding)?
    private let lanes: Int

    /// Decode lanes for this phone: one for each core the main thread and the system leave free,
    /// three to five. A rail jump lands on a screen of some fifty-five photos at once, and three
    /// lanes made the last of them wait about 85 ms on an iPhone 15 Pro (T7).
    static func lanes(cores: Int) -> Int { min(5, max(3, cores - 2)) }

    /// The lanes the app runs with. A perf run may set them with -IlyichDecodeLanes to compare.
    static var deviceLanes: Int {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "IlyichPerfScenario") != nil, defaults.integer(forKey: "IlyichDecodeLanes") > 0 {
            return min(8, defaults.integer(forKey: "IlyichDecodeLanes"))
        }
        return lanes(cores: ProcessInfo.processInfo.activeProcessorCount)
    }
    private let queue = DispatchQueue(label: "ilyich.thumbnail-scheduler", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(label: "ilyich.thumbnail-decode", qos: .userInitiated, attributes: .concurrent)
    private struct Listener {
        let deliveries: @MainActor @Sendable ([ThumbnailDelivery]) -> Void
        let reset: (@MainActor @Sendable () -> Void)?
    }
    private let listeners = Mutex<[UUID: Listener]>([:])
    private let outbox = Mutex<(deliveries: [ThumbnailDelivery], scheduled: Bool)>(([], false))
    /// Lets tests watch which photos decode, in order.
    private let willDecode: (@Sendable (String) -> Void)?

    /// Watches for the network coming back, when asked to.
    private let monitor: NWPathMonitor?
    private let online = Atomic<Bool>(true)

    private var fence: MediaFence { store.fence }

    /// With `watchesNetwork`, photos waiting after a failure are tried again as soon as the
    /// network comes back. Without `device`, phone photos in a demand are left alone.
    init(store: any ThumbnailStoring, memory: DecodedThumbnailCache, fetcher: ThumbnailFetcher,
         device: (any DeviceThumbnailProviding)? = nil, lanes: Int = 3,
         watchesNetwork: Bool = false, willDecode: (@Sendable (String) -> Void)? = nil) {
        self.store = store
        self.memory = memory
        self.fetcher = fetcher
        self.device = device
        self.lanes = max(1, lanes)
        self.willDecode = willDecode
        monitor = watchesNetwork ? NWPathMonitor() : nil
        if let monitor {
            // Readings arrive one at a time on the scheduler's queue.
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let online = path.status == .satisfied
                if !self.online.exchange(online, ordering: .relaxed) && online { networkReturned() }
            }
            monitor.start(queue: queue)
        }
    }

    deinit { monitor?.cancel() }

    /// The network is back: photos that failed while it was gone are tried again now instead of
    /// when their wait ends.
    func networkReturned() {
        fetcher.clearBackoff()
        queue.async { [self] in pump() }
    }

    // MARK: Grids

    /// Everything `source` wants now, replacing what it wanted before. Returns at once; the demand
    /// is worked in off the main thread, and a newer one sent meanwhile replaces it unread. The
    /// demand's generation is the media fence's token from when it was built.
    func submit(_ demand: ViewportDemand, from source: Source) {
        let schedule = state.withLock { state -> Bool in
            state.mailbox[source] = demand
            guard !state.mailboxScheduled else { return false }
            state.mailboxScheduled = true
            return true
        }
        if schedule { queue.async { [self] in readMailbox() } }
    }

    /// The grid is gone: it wants nothing.
    func withdraw(_ source: Source) {
        submit(ViewportDemand(generation: fence.token(), items: [], motion: .idle(since: 0)), from: source)
    }

    /// Grid deliveries reach `listener` on the main thread, in batches. `reset` is told, on the
    /// main thread, when everything the grids wanted was dropped, so they say again what they
    /// want. Returns the ID to remove it with.
    func addListener(_ listener: @escaping @MainActor @Sendable ([ThumbnailDelivery]) -> Void,
                     reset: (@MainActor @Sendable () -> Void)? = nil) -> UUID {
        let id = UUID()
        listeners.withLock { $0[id] = Listener(deliveries: listener, reset: reset) }
        return id
    }

    func removeListener(_ id: UUID) { listeners.withLock { _ = $0.removeValue(forKey: id) } }

    private func readMailbox() {
        let mail = state.withLock { state -> [Source: ViewportDemand] in
            state.mailboxScheduled = false
            defer { state.mailbox = [:] }
            return state.mailbox
        }
        for (source, demand) in mail { apply(demand, from: source) }
        if let device, !mail.isEmpty {
            // Photos renders ahead what every grid wants of the phone, at the largest cell.
            let window = state.withLock { state -> DeviceWindow in
                state.deviceWindows.values.reduce(into: DeviceWindow(ids: [], pixels: 0)) { union, window in
                    union.ids.formUnion(window.ids)
                    union.pixels = max(union.pixels, window.pixels)
                }
            }
            device.preheat(window.ids, pixels: window.pixels)
        }
        pump()
    }

    private func apply(_ demand: ViewportDemand, from source: Source) {
        // Fast is scrubbing, or passing photos faster than they could arrive; between the policy's
        // speeds the grid's last decision stands.
        let fast = state.withLock { state -> Bool in
            let fast = ViewportPolicy.isFast(demand.motion, wasFast: state.fast[source] ?? false)
            state.fast[source] = demand.items.isEmpty ? nil : fast
            return fast
        }
        var wants: [Key: Want] = [:]
        var devices: [Key: DeviceAssetID] = [:]
        for item in demand.items {
            let request = item.request
            let key = Key(assetID: request.key.assetID, revision: request.key.revision)
            // Phone photos need the device source; without one they are left alone.
            if request.key.deviceID != nil && device == nil { continue }
            // What memory has already needs nothing.
            if memory.image(assetID: key.assetID, revision: key.revision, shortSide: request.shortSide) != nil { continue }
            if let id = request.key.deviceID { devices[key] = id }
            let want = Want(band: item.band, rank: item.rank, shortSide: request.shortSide,
                            network: ViewportPolicy.allowsNetwork(item.band, fast: fast))
            wants[key] = wants[key].map { $0.merged(want) } ?? want
        }
        // Photos renders ahead the phone photos wanted, at the largest cell, except those it
        // could not render lately: they wait their turn to be asked for again.
        var window = DeviceWindow(ids: [], pixels: 0)
        if !devices.isEmpty {
            let now = fetcher.currentTime()
            for (key, id) in devices {
                guard let want = wants[key] else { continue }
                if let wait = fetcher.retryTime(assetID: key.assetID, revision: key.revision), wait > now { continue }
                window.ids.insert(id)
                window.pixels = max(window.pixels, want.shortSide)
            }
        }
        // The disk is asked about new photos only, outside the lock. Photos always has its own.
        let known = state.withLock { state in Set(wants.keys.filter { state.jobs[$0] != nil }) }
        var onDisk: [Key: Bool] = [:]
        for key in wants.keys where !known.contains(key) {
            onDisk[key] = devices[key] != nil || store.contains(assetID: key.assetID, revision: key.revision)
        }
        let token = demand.generation
        state.withLock { state in
            state.serial += 1
            let serial = state.serial
            for key in state.wanted[source] ?? [] where wants[key] == nil {
                guard var job = state.jobs[key] else { continue }
                job.grid[source] = nil
                Self.store(job, in: &state)
            }
            for (key, var want) in wants {
                var job = state.jobs[key] ?? Job(key: key, token: token, generation: state.generation,
                                                 device: devices[key], onDisk: onDisk[key] ?? true)
                if fast && want.band == .visible {
                    let previous = job.grid[source]
                    want.lifo = previous?.band == .visible && previous?.lifo != 0 ? previous!.lifo : -serial
                }
                job.grid[source] = want
                job.flag.wanted.store(true, ordering: .relaxed)
                state.jobs[key] = job
            }
            state.wanted[source] = wants.isEmpty ? nil : Set(wants.keys)
            state.deviceWindows[source] = window.ids.isEmpty ? nil : window
        }
    }

    /// When the photo may be asked for again, from the server or from Photos, if it is waiting out
    /// a failure; nil when it may be asked for now. Something asking for this one photo, such as
    /// the viewer, tries at once; the grid and coverage wait.
    private static func retryWait(_ job: Job, fetcher: ThumbnailFetcher, now: TimeInterval) -> TimeInterval? {
        let asked = job.waiters.values.contains { ($0.want.network || job.device != nil) && $0.want.band <= .explicit }
        guard !asked, let wait = fetcher.retryTime(assetID: job.key.assetID, revision: job.key.revision), wait > now else { return nil }
        return wait
    }

    /// Puts a changed job back, or lets it go once nobody wants it: at once if it is waiting, when
    /// its decode ends if one is running (the lane skips it if it hasn't begun), and when its
    /// download ends if one is running.
    private static func store(_ job: Job, in state: inout State) {
        guard !job.isWanted else { state.jobs[job.key] = job; return }
        switch job.phase {
        case .idle: state.jobs[job.key] = nil
        case .decoding:
            job.flag.wanted.store(false, ordering: .relaxed)
            state.jobs[job.key] = job
        case .fetching: state.jobs[job.key] = job
        }
    }

    // MARK: Single photos

    /// The grid thumbnail for a cell of `shortSide` pixels: from memory, from disk, or when
    /// `network` allows from the server. Nil when it is not stored and the network may not be
    /// used. `token` is the media fence's from when the photo was asked for.
    func image(assetID: String, revision: String, shortSide: Int, band: DemandBand = .explicit, network: Bool,
               token: UInt64) async throws -> PreparedImage? {
        guard fence.admits(assetID, since: token) else { throw CancellationError() }
        if let image = memory.image(assetID: assetID, revision: revision, shortSide: shortSide) { return image }
        let onDisk = store.contains(assetID: assetID, revision: revision)
        guard onDisk || network else { return nil }
        return try await wait(Key(assetID: assetID, revision: revision), onDisk: onDisk, token: token,
                              want: Want(band: band, rank: 0, shortSide: shortSide, network: network))
    }

    /// Downloads a thumbnail onto the disk without decoding it, unless it is there already.
    func store(assetID: String, revision: String, band: DemandBand = .coverage, token: UInt64) async throws {
        guard fence.admits(assetID, since: token) else { throw CancellationError() }
        guard !store.contains(assetID: assetID, revision: revision) else { return }
        _ = try await wait(Key(assetID: assetID, revision: revision), onDisk: false, token: token,
                           want: Want(band: band, rank: 0, shortSide: 0, network: true, decode: false))
    }

    private enum Arrival { case cancelled, waiting }

    private func wait(_ key: Key, onDisk: Bool, token: UInt64, want: Want) async throws -> PreparedImage? {
        let waiter = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PreparedImage?, Error>) in
                let arrival = state.withLock { state -> Arrival in
                    // Cancellation is flagged before its handler runs, so a waiter the handler
                    // missed is never left behind.
                    guard !Task.isCancelled else { return .cancelled }
                    var job = state.jobs[key] ?? Job(key: key, token: token, generation: state.generation, onDisk: onDisk)
                    job.waiters[waiter] = Waiter(want: want, continuation: continuation)
                    job.flag.wanted.store(true, ordering: .relaxed)
                    state.jobs[key] = job
                    return .waiting
                }
                switch arrival {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .waiting: pump()
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<PreparedImage?, Error>? in
                guard var job = state.jobs[key], let removed = job.waiters.removeValue(forKey: waiter) else { return nil }
                // A photo nobody waits for any more is never decoded or downloaded.
                Self.store(job, in: &state)
                return removed.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
        return result
    }

    // MARK: Work

    /// Starts decodes and downloads while there are lanes and slots for them.
    func pump() {
        let now = fetcher.currentTime()
        let (newLanes, downloads, retry) = state.withLock { state -> (Int, [(Key, DemandBand, UInt64, Int)], TimeInterval?) in
            var decodable = 0
            var candidates: [(key: Key, want: Want)] = []
            var retry: TimeInterval?
            for job in state.jobs.values where job.phase == .idle {
                guard let want = job.want else { continue }
                if want.decode && (job.fetched != nil || job.onDisk) {
                    // A phone photo Photos could not render waits out its failures too.
                    if job.device != nil, let wait = Self.retryWait(job, fetcher: fetcher, now: now) {
                        retry = min(retry ?? wait, wait); continue
                    }
                    decodable += 1; continue
                }
                guard want.network else { continue }
                if let wait = Self.retryWait(job, fetcher: fetcher, now: now) { retry = min(retry ?? wait, wait); continue }
                candidates.append((job.key, want))
            }
            let newLanes = max(0, min(decodable, lanes - state.decoding))
            state.decoding += newLanes
            candidates.sort { ($0.want.band, $0.want.rank) < ($1.want.band, $1.want.rank) }
            var downloads: [(Key, DemandBand, UInt64, Int)] = []
            for candidate in candidates {
                guard state.fetching < Self.ceiling(candidate.want.band) else { continue }
                guard var job = state.jobs[candidate.key] else { continue }
                job.phase = .fetching
                state.jobs[candidate.key] = job
                state.fetching += 1
                downloads.append((candidate.key, candidate.want.band, job.token, job.generation))
            }
            if let next = retry, state.retryScheduled.map({ next < $0 }) ?? true { state.retryScheduled = next } else { retry = nil }
            return (newLanes, downloads, retry)
        }
        for _ in 0..<newLanes { runLane() }
        for (key, band, token, generation) in downloads { download(key, band: band, token: token, generation: generation) }
        if let retry {
            queue.asyncAfter(deadline: .now() + max(0, retry - now)) { [weak self] in
                guard let self else { return }
                state.withLock { state in if state.retryScheduled == retry { state.retryScheduled = nil } }
                pump()
            }
        }
    }

    private func download(_ key: Key, band: DemandBand, token: UInt64, generation: Int) {
        let task = fetcher.fetch(assetID: key.assetID, revision: key.revision, band: band) { [self] result in
            downloaded(key, generation: generation, token: token, result: result)
        }
        state.withLock { state in
            guard var job = state.jobs[key], job.generation == generation, job.phase == .fetching else { return }
            job.download = task
            state.jobs[key] = job
        }
    }

    private func downloaded(_ key: Key, generation: Int, token: UInt64, result: Result<Data, Error>) {
        if case .success(let data) = result {
            // Readable from the store at once; written on the store's own queue.
            store.enqueueWrite(data, assetID: key.assetID, revision: key.revision, token: token)
        }
        let (resumes, failure) = state.withLock { state -> ([(CheckedContinuation<PreparedImage?, Error>, Result<PreparedImage?, Error>)], ThumbnailDelivery?) in
            state.fetching -= 1
            guard var job = state.jobs[key], job.generation == generation, job.phase == .fetching else { return ([], nil) }
            job.phase = .idle
            job.download = nil
            var resumes: [(CheckedContinuation<PreparedImage?, Error>, Result<PreparedImage?, Error>)] = []
            var failure: ThumbnailDelivery?
            switch result {
            case .success(let data):
                job.onDisk = true
                // Coverage only needed the bytes on disk.
                for (id, waiter) in job.waiters where !waiter.want.decode {
                    resumes.append((waiter.continuation, .success(nil)))
                    job.waiters[id] = nil
                }
                job.fetched = job.want?.decode == true ? data : nil
            case .failure(let error):
                for waiter in job.waiters.values { resumes.append((waiter.continuation, .failure(error))) }
                job.waiters = [:]
                if !ThumbnailFetcher.isCancellation(error), !job.grid.isEmpty {
                    failure = ThumbnailDelivery(assetID: key.assetID, revision: key.revision, image: nil, fromNetwork: true)
                }
            }
            Self.store(job, in: &state)
            return (resumes, failure)
        }
        for (continuation, result) in resumes { continuation.resume(with: result) }
        if let failure { deliver(failure) }
        pump()
    }

    private func runLane() {
        decodeQueue.async { [self] in
            while let work = nextDecode() {
                var image: PreparedImage?
                var skipped = false
                var inCloud = false
                if work.flag.wanted.load(ordering: .relaxed) {
                    willDecode?(work.key.assetID)
                    if let id = work.device {
                        // Photos renders it, at the cell's size, while this lane waits.
                        switch device?.thumbnail(id, pixels: work.side) {
                        case .image(let rendered): image = rendered
                        case .unavailable(let cloud): inCloud = cloud
                        case nil: break
                        }
                    } else {
                        image = autoreleasepool { () -> PreparedImage? in
                            guard let data = work.bytes ?? store.data(assetID: work.key.assetID, revision: work.key.revision) else { return nil }
                            return try? MediaPipeline.downsampleThumbnail(data, shortSide: work.side)
                        }
                    }
                } else {
                    skipped = true
                }
                finishDecode(work, image: image, skipped: skipped, inCloud: inCloud)
            }
        }
    }

    /// The most urgent decode waiting, or nil, giving the lane back.
    private func nextDecode() -> DecodeWork? {
        let now = fetcher.currentTime()
        return state.withLock { state in
            var best: (key: Key, order: (DemandBand, Int, Int))?
            for job in state.jobs.values where job.phase == .idle && (job.fetched != nil || job.onDisk) {
                guard let want = job.want, want.decode else { continue }
                // A phone photo waiting out a failure is not Photos' to render yet.
                if job.device != nil, Self.retryWait(job, fetcher: fetcher, now: now) != nil { continue }
                let order = (want.band, want.lifo, want.rank)
                if best.map({ order < $0.order }) ?? true { best = (job.key, order) }
            }
            guard let best, var job = state.jobs[best.key], let want = job.want else {
                state.decoding -= 1
                return nil
            }
            job.phase = .decoding
            job.decodingSide = want.shortSide
            state.jobs[best.key] = job
            return DecodeWork(key: job.key, generation: job.generation, token: job.token, side: want.shortSide,
                              bytes: job.fetched, flag: job.flag, device: job.device)
        }
    }

    private func finishDecode(_ work: DecodeWork, image: PreparedImage?, skipped: Bool, inCloud: Bool = false) {
        let key = work.key, fence = fence
        var admitted = false
        if let image {
            admitted = memory.insert(image, assetID: key.assetID, revision: key.revision, shortSide: work.side) {
                fence.admits(key.assetID, since: work.token)
            }
        }
        let (resumes, delivery) = state.withLock { state -> ([(CheckedContinuation<PreparedImage?, Error>, Result<PreparedImage?, Error>)], ThumbnailDelivery?) in
            guard var job = state.jobs[key], job.generation == work.generation, job.phase == .decoding else { return ([], nil) }
            job.phase = .idle
            var resumes: [(CheckedContinuation<PreparedImage?, Error>, Result<PreparedImage?, Error>)] = []
            var delivery: ThumbnailDelivery?
            if skipped {
                job.flag = Flag()
            } else if let image {
                let fromNetwork = work.bytes != nil
                job.fetched = nil
                if work.device != nil { fetcher.succeeded(assetID: key.assetID, revision: key.revision) }
                let fileLimited = min(image.cgImage.width, image.cgImage.height) + 1 < work.side
                if admitted {
                    if !job.grid.isEmpty {
                        delivery = ThumbnailDelivery(assetID: key.assetID, revision: key.revision, image: image, fromNetwork: fromNetwork)
                    }
                    // Someone who asked for a larger size while this decoded has it decoded
                    // again at that size, unless the file is no larger.
                    for (id, waiter) in job.waiters where fileLimited || waiter.want.shortSide <= work.side {
                        resumes.append((waiter.continuation, .success(image)))
                        job.waiters[id] = nil
                    }
                } else {
                    for waiter in job.waiters.values { resumes.append((waiter.continuation, .failure(CancellationError()))) }
                    job.waiters = [:]
                    job.grid = [:]
                }
                // A cell that grew while this decoded has it decoded again at its size, unless the
                // file is no larger.
                let grew = job.grid.values.contains { $0.shortSide > work.side }
                if !admitted || fileLimited || !grew { job.grid = [:] }
            } else if work.bytes != nil {
                // Downloaded bytes that do not decode: the photo failed.
                job.fetched = nil
                let error = APIError.invalidResponse("This image could not be decoded.")
                for waiter in job.waiters.values { resumes.append((waiter.continuation, .failure(error))) }
                job.waiters = [:]
                if !job.grid.isEmpty {
                    delivery = ThumbnailDelivery(assetID: key.assetID, revision: key.revision, image: nil, fromNetwork: true)
                }
                job.grid = [:]
            } else if work.device != nil {
                // Photos has nothing to give for it: gone, or only in iCloud. Nobody else can help,
                // and the grid waits before asking Photos again.
                fetcher.failed(assetID: key.assetID, revision: key.revision)
                for waiter in job.waiters.values { resumes.append((waiter.continuation, .success(nil))) }
                job.waiters = [:]
                if !job.grid.isEmpty {
                    delivery = ThumbnailDelivery(assetID: key.assetID, revision: key.revision, image: nil, fromNetwork: false, inCloud: inCloud)
                }
                job.grid = [:]
            } else {
                // Listed but unreadable, or damaged: only the server can help now.
                job.onDisk = false
                for (id, waiter) in job.waiters where !waiter.want.network {
                    resumes.append((waiter.continuation, .success(nil)))
                    job.waiters[id] = nil
                }
            }
            Self.store(job, in: &state)
            return (resumes, delivery)
        }
        for (continuation, result) in resumes { continuation.resume(with: result) }
        if let delivery { deliver(delivery) }
        pump()
    }

    // MARK: Deliveries

    private func deliver(_ delivery: ThumbnailDelivery) {
        let schedule = outbox.withLock { outbox -> Bool in
            outbox.deliveries.append(delivery)
            guard !outbox.scheduled else { return false }
            outbox.scheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                let batch = outbox.withLock { outbox -> [ThumbnailDelivery] in
                    outbox.scheduled = false
                    defer { outbox.deliveries = [] }
                    return outbox.deliveries
                }
                guard !batch.isEmpty else { return }
                for listener in listeners.withLock({ Array($0.values) }) { listener.deliveries(batch) }
            }
        }
    }

    // MARK: Invalidation

    /// Work for these photos stops: nothing queued starts, downloads running are cancelled, and
    /// whoever waits is told.
    func forget(_ assetIDs: Set<String>) {
        guard !assetIDs.isEmpty else { return }
        let waiters = state.withLock { state -> [CheckedContinuation<PreparedImage?, Error>] in
            var waiters: [CheckedContinuation<PreparedImage?, Error>] = []
            for (key, job) in state.jobs where assetIDs.contains(key.assetID) {
                waiters += job.waiters.values.map(\.continuation)
                job.flag.wanted.store(false, ordering: .relaxed)
                job.download?.cancel()
                state.jobs[key] = nil
            }
            return waiters
        }
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }

    /// These photos have new revisions: work for any other revision that has not started is dropped.
    func refresh(_ revisions: [String: String]) {
        guard !revisions.isEmpty else { return }
        let waiters = state.withLock { state -> [CheckedContinuation<PreparedImage?, Error>] in
            var waiters: [CheckedContinuation<PreparedImage?, Error>] = []
            for (key, job) in state.jobs where job.phase == .idle {
                guard let revision = revisions[key.assetID], revision != key.revision else { continue }
                waiters += job.waiters.values.map(\.continuation)
                state.jobs[key] = nil
            }
            return waiters
        }
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }

    /// Everything stops, as at sign-out: queued work is dropped, downloads are cancelled, and work
    /// already running neither stores nor shows what it finishes.
    func reset() {
        let waiters = state.withLock { state -> [CheckedContinuation<PreparedImage?, Error>] in
            state.generation += 1
            var waiters: [CheckedContinuation<PreparedImage?, Error>] = []
            for job in state.jobs.values {
                waiters += job.waiters.values.map(\.continuation)
                job.flag.wanted.store(false, ordering: .relaxed)
                job.download?.cancel()
            }
            state.jobs = [:]
            state.wanted = [:]
            state.deviceWindows = [:]
            state.fast = [:]
            state.mailbox = [:]
            return waiters
        }
        outbox.withLock { $0.deliveries = [] }
        fetcher.clearBackoff()
        device?.stop()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
        // The grids' cells still waiting for thumbnails ask again.
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                for listener in listeners.withLock({ Array($0.values) }) { listener.reset?() }
            }
        }
    }

    /// Jobs waiting for a lane or a download slot.
    var pendingCount: Int { state.withLock { state in state.jobs.values.count { $0.phase == .idle } } }

    /// Downloads running now.
    var downloadsRunning: Int { state.withLock { $0.fetching } }
}

import Foundation
import Synchronization

/// Grid thumbnails move from disk to memory here, a few at a time and newest request first, so
/// the photos on screen go before the ones a scrub has already passed. A request nobody waits
/// for any more is dropped before it starts, and photos about to scroll in decode only while
/// nothing on screen is waiting. Decoding runs on its own queue, off the main thread and the
/// cooperative pool.
final class ThumbnailDecoder: Sendable {
    struct Request: Sendable {
        let identity: MediaCacheIdentity
        let assetID: String
        let revision: String
    }

    private enum Priority { case visible, ahead }
    private struct Job {
        let request: Request
        var priority: Priority
        var waiters: [UUID: CheckedContinuation<PreparedImage?, Never>] = [:]
        var started = false
        let generation: Int
    }
    private struct State {
        var jobs: [MediaCacheIdentity: Job] = [:]
        /// Newest last. A key whose job has started or gone is skipped when it comes up.
        var visible: [MediaCacheIdentity] = []
        var ahead: [MediaCacheIdentity] = []
        var running = 0
        var generation = 0
    }
    private enum Arrival { case cancelled, joined, queued, startLane }

    private let state = Mutex(State())
    private let store: ThumbnailStore
    private let lanes: Int
    private let queue = DispatchQueue(label: "ilyich.thumbnail-decoder", qos: .userInitiated, attributes: .concurrent)
    private let decoded: @Sendable (PreparedImage, MediaCacheIdentity) -> Void
    private let willDecode: (@Sendable (MediaCacheIdentity) -> Void)?
    /// Photos about to scroll in; past this many the oldest have usually scrolled past already.
    private static let aheadLimit = 120

    /// `decoded` receives every image decoded for the current generation, so prefetched photos
    /// reach memory with nobody waiting. `willDecode` lets tests watch the order.
    init(store: ThumbnailStore, lanes: Int = 3, decoded: @escaping @Sendable (PreparedImage, MediaCacheIdentity) -> Void,
         willDecode: (@Sendable (MediaCacheIdentity) -> Void)? = nil) {
        self.store = store
        self.lanes = max(1, lanes)
        self.decoded = decoded
        self.willDecode = willDecode
    }

    /// The stored thumbnail, decoded; nil when the store doesn't have it or the caller stopped waiting.
    func image(_ request: Request) async -> PreparedImage? {
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PreparedImage?, Never>) in
                let arrival = state.withLock { state -> Arrival in
                    // Cancellation is flagged before its handler runs, so a waiter the handler
                    // missed is never left behind.
                    guard !Task.isCancelled else { return .cancelled }
                    if var job = state.jobs[request.identity] {
                        job.waiters[waiter] = continuation
                        // Asked for again, it is the newest request.
                        if !job.started {
                            job.priority = .visible
                            state.visible.append(request.identity)
                        }
                        state.jobs[request.identity] = job
                        return .joined
                    }
                    state.jobs[request.identity] = Job(request: request, priority: .visible, waiters: [waiter: continuation], generation: state.generation)
                    state.visible.append(request.identity)
                    if state.visible.count > 256 {
                        state.visible.removeAll { key in state.jobs[key].map { $0.started || $0.priority != .visible } ?? true }
                    }
                    guard state.running < lanes else { return .queued }
                    state.running += 1
                    return .startLane
                }
                switch arrival {
                case .cancelled: continuation.resume(returning: nil)
                case .startLane: startLane()
                case .joined, .queued: break
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<PreparedImage?, Never>? in
                guard var job = state.jobs[request.identity], let continuation = job.waiters.removeValue(forKey: waiter) else { return nil }
                // A photo that scrolled away before its turn is never decoded.
                state.jobs[request.identity] = job.waiters.isEmpty && !job.started ? nil : job
                return continuation
            }
            continuation?.resume(returning: nil)
        }
    }

    /// Photos about to scroll in, decoded once nothing on screen waits.
    func prefetch(_ requests: [Request]) {
        guard !requests.isEmpty else { return }
        let start = state.withLock { state -> Int in
            var added = 0
            for request in requests where state.jobs[request.identity] == nil {
                state.jobs[request.identity] = Job(request: request, priority: .ahead, generation: state.generation)
                state.ahead.append(request.identity)
                added += 1
            }
            while state.ahead.count > Self.aheadLimit {
                let key = state.ahead.removeFirst()
                if let job = state.jobs[key], !job.started, job.waiters.isEmpty { state.jobs[key] = nil }
            }
            let start = min(added, lanes - state.running)
            state.running += max(0, start)
            return max(0, start)
        }
        for _ in 0..<start { startLane() }
    }

    /// Decodes waiting for a lane.
    var pendingCount: Int { state.withLock { state in state.jobs.values.count { !$0.started } } }

    /// Photos that will not scroll in after all.
    func cancelPrefetch(_ identities: [MediaCacheIdentity]) {
        state.withLock { state in
            for key in identities {
                if let job = state.jobs[key], !job.started, job.priority == .ahead, job.waiters.isEmpty { state.jobs[key] = nil }
            }
        }
    }

    /// Drops every queued decode. One already running finishes without reaching memory.
    func reset() {
        let waiters = state.withLock { state -> [CheckedContinuation<PreparedImage?, Never>] in
            state.generation += 1
            let waiters = state.jobs.values.flatMap { $0.waiters.values }
            state.jobs.removeAll(); state.visible.removeAll(); state.ahead.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    private func startLane() {
        queue.async { [self] in
            while let job = nextJob() {
                willDecode?(job.request.identity)
                let image = autoreleasepool { () -> PreparedImage? in
                    guard let data = store.data(assetID: job.request.assetID, revision: job.request.revision) else { return nil }
                    return try? MediaPipeline.downsample(data, pixelSize: job.request.identity.pixelSize)
                }
                finish(job, image)
            }
        }
    }

    /// The newest photo on screen, otherwise the newest about to scroll in. Gives the lane back
    /// when nothing is left.
    private func nextJob() -> Job? {
        state.withLock { state in
            while let key = state.visible.popLast() {
                if var job = state.jobs[key], !job.started, job.priority == .visible {
                    job.started = true; state.jobs[key] = job
                    return job
                }
            }
            while let key = state.ahead.popLast() {
                if var job = state.jobs[key], !job.started {
                    job.started = true; state.jobs[key] = job
                    return job
                }
            }
            state.running -= 1
            return nil
        }
    }

    private func finish(_ job: Job, _ image: PreparedImage?) {
        let key = job.request.identity
        let waiters = state.withLock { state -> [CheckedContinuation<PreparedImage?, Never>]? in
            // After a reset the key may belong to a newer job; it is left alone.
            guard let current = state.jobs[key], current.started, current.generation == job.generation,
                  job.generation == state.generation else { return nil }
            state.jobs[key] = nil
            return Array(current.waiters.values)
        }
        guard let waiters else { return }
        if let image { decoded(image, key) }
        for waiter in waiters { waiter.resume(returning: image) }
    }
}

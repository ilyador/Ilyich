import Foundation
import Network

/// Keeps every grid thumbnail of the library on disk, about 12 KB a photo, so scrolling
/// anywhere draws real thumbnails without asking the server. It works from the local library
/// index, newest photos first, two downloads at a time, only on unmetered networks, and holds
/// while the user scrolls, views a photo or saves power.
///
/// It belongs to one session. Once that session ends, or the warmer is stopped, it never starts
/// again, even when a check or a sync begun before then finishes later.
@MainActor @Observable final class ThumbnailWarmer {
    private(set) var stored = 0
    private(set) var total = 0
    private(set) var isRunning = false
    /// The library holds the warmer while the user looks at a photo.
    var isHeld = false
    /// Asked before each download, so a scroll in progress always wins the network.
    @ObservationIgnored var isScrolling: (@MainActor () -> Bool)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The check that the offline library is complete, before the first start.
    @ObservationIgnored private var pendingStart: Task<Void, Never>?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let session: AuthorizationState?
    @ObservationIgnored private var stopped = false
    private var unmetered = false

    /// A warmer for `session`'s library, which stops for good when that session ends.
    init(session: AuthorizationState? = nil) {
        self.session = session
        monitor.pathUpdateHandler = { [weak self] path in
            let unmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in self?.unmetered = unmetered }
        }
        monitor.start(queue: DispatchQueue(label: "ilyich.thumbnail-warmer.network", qos: .utility))
    }

    /// Whether the warmer may run: not stopped, and its session still open.
    private var mayRun: Bool { !stopped && session?.hasEnded != true }

    /// Starts once `isReady` finds the offline library complete. The check is the warmer's own
    /// work, so stopping the warmer ends it.
    func start(when isReady: @escaping @Sendable () async -> Bool, entities: EntityStore, pipeline: MediaPipeline) {
        guard mayRun, task == nil, pendingStart == nil else { return }
        pendingStart = Task { [weak self] in
            let ready = await isReady()
            guard !Task.isCancelled, let self else { return }
            self.pendingStart = nil
            if ready { self.start(entities: entities, pipeline: pipeline) }
        }
    }

    func start(entities: EntityStore, pipeline: MediaPipeline) {
        guard mayRun, task == nil else { return }
        pendingStart?.cancel(); pendingStart = nil
        isRunning = true
        task = Task { [weak self] in
            await self?.run(entities: entities, pipeline: pipeline)
            self?.isRunning = false; self?.task = nil
        }
    }

    /// Stops for good.
    func stop() {
        stopped = true
        pendingStart?.cancel(); pendingStart = nil
        task?.cancel(); task = nil; isRunning = false
        monitor.cancel()
    }

    private func run(entities: EntityStore, pipeline: MediaPipeline) async {
        // Launch and the first screen of photos come first.
        try? await Task.sleep(for: .seconds(8))
        // Until the index's backfill is done its photos are not all listed; the next sync starts
        // the warmer again.
        guard (try? await entities.isReadable()) == true else { return }
        total = (try? await entities.timeBuckets().reduce(0) { $0 + $1.count }) ?? 0
        stored = 0
        var offset = 0, failures = 0
        while !Task.isCancelled, mayRun {
            guard let batch = try? await entities.timelineAssets(offset: offset, limit: 400), !batch.isEmpty else { return }
            offset += batch.count
            // Hashing names and checking 400 files stays off the main thread.
            let missing = await Task.detached(priority: .utility) { batch.filter { !pipeline.hasStoredThumbnail($0) } }.value
            stored += batch.count - missing.count
            var index = 0
            while index < missing.count {
                await waitForQuiet()
                guard !Task.isCancelled, mayRun else { return }
                let pair = Array(missing[index..<min(index + 2, missing.count)])
                let succeeded = await withTaskGroup(of: Bool.self) { group in
                    for asset in pair { group.addTask { (try? await pipeline.storeThumbnail(asset)) != nil } }
                    var count = 0
                    for await stored in group where stored { count += 1 }
                    return count
                }
                stored += succeeded
                index += pair.count
                // A server or network in trouble gets a minute of peace instead of a stream of failures.
                failures = succeeded == 0 ? failures + 1 : 0
                if failures >= 3 { failures = 0; try? await Task.sleep(for: .seconds(60)) }
            }
        }
    }

    private func waitForQuiet() async {
        while !Task.isCancelled && (isHeld || isScrolling?() == true || !unmetered || ProcessInfo.processInfo.isLowPowerModeEnabled) {
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

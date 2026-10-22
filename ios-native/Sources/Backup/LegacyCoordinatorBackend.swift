import Foundation
import IlyichShareInbox
import Observation

/// The backup and Shared files screens' commands and reads, served by today's BackupCoordinator
/// and ShareInboxStore (REBUILD_ROADMAP.md B8). The screens speak only TransferControlling, so
/// the transfer engine can take over underneath in B9, which deletes this adapter. Every command
/// does exactly what the screens' buttons did before.
@MainActor final class LegacyCoordinatorBackend: TransferControlling {
    static let shared = LegacyCoordinatorBackend()

    private let coordinator: BackupCoordinator
    private let inbox: ShareInboxStore
    /// The client shared files upload with; nil where nothing enqueues them.
    private let shareClient: APIClient?
    private var history: (key: HistoryKey, ids: [String])?
    /// The failures and album counts last read, until the backup state changes. A snapshot is
    /// sent for every progress tick, and each rereads both; kept, they cost nothing then, and the
    /// store's comparison with what it shows meets the same storage and returns at once.
    private var failureCache: (revision: Int, limit: Int, items: [TransferQueueItem])?
    private var countsCache: (revision: Int, counts: [String: AlbumUploadCount])?

    private struct HistoryKey: Equatable {
        let scope: String?
        let confirmed: Int
        let receipts: Int
    }

    init(coordinator: BackupCoordinator = .shared, inbox: ShareInboxStore = .shared, shareClient: APIClient? = nil) {
        self.coordinator = coordinator
        self.inbox = inbox
        self.shareClient = shareClient
    }

    // MARK: Commands

    /// Paused is the Pause button, which also switches automatic backup off, as it always has.
    /// Manual is Back up now; automatic is the start automatic backup makes.
    func setIntent(_ intent: RunIntent) async throws {
        switch intent {
        case .paused: await coordinator.pause()
        case .manual: await coordinator.start()
        case .automatic: await coordinator.startAutomatically()
        }
    }

    /// Phone photos join the queue and backup starts, as Back up selected always did; a request
    /// with an album adds them to it after upload. Approved shared files start uploading. The
    /// result is this call's own; a refusal throws with its message.
    func enqueue(_ requests: [TransferRequest]) async throws -> EnqueueResult {
        var queued = 0
        var photos: [String?: [String]] = [:]
        var shared: Set<String> = []
        for request in requests {
            switch request.source {
            case .photo(let id): photos[request.album, default: []].append(id.rawValue)
            case .shared(_, let attachment): shared.insert(attachment)
            }
        }
        for album in photos.keys.sorted(by: { ($0 ?? "") < ($1 ?? "") }) {
            let localIDs = photos[album] ?? []
            switch await coordinator.enqueue(localIDs: localIDs, albumID: album) {
            case .queued: queued += localIDs.count
            case .failed(let message): throw BackupError.message(message)
            }
        }
        if !shared.isEmpty, let shareClient {
            let wasRunning = inbox.isRunning
            inbox.upload(selected: shared, api: shareClient)
            if !wasRunning, inbox.isRunning { queued += shared.count }
        }
        return .queued(queued)
    }

    /// Shared files stop uploading, as Pause upload did; the files not yet sent stay. The inbox
    /// can only stop as a whole, so an empty list, sent once the last file left the list, stops
    /// it too. Phone photos have no cancel of their own today.
    func cancel(_ sources: [TransferSource]) async throws {
        if sources.isEmpty || sources.contains(where: { $0.lane == .share }) { inbox.cancel() }
    }

    func setPreferences(_ preferences: TransferPreferences) async throws {
        let value = BackupPreferences(preferences)
        guard value != coordinator.preferences else { return }
        coordinator.preferences = value
        coordinator.savePreferences()
    }

    func preferences() async throws -> TransferPreferences? { TransferPreferences(coordinator.preferences) }

    /// Retry failed uploads: backup starts again with every failed photo.
    func retry(_ sources: [TransferSource]?) async throws {
        await coordinator.start()
    }

    // MARK: Reads

    /// The coordinator's state now, then again each time it changes: at most four times a
    /// second, except that starting or stopping is sent at once. Its observation is the only
    /// source, so nothing polls.
    func snapshots() async -> AsyncStream<TransferSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: TransferSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let watch = SnapshotWatch(coordinator: coordinator, continuation: continuation)
        continuation.onTermination = { _ in Task { @MainActor in watch.stop() } }
        watch.send()
        return stream
    }

    /// The queue in its order, failed photos included with their message, as the queue screen
    /// always listed it. A page continues after the position `after`.
    func queuePage(lane: TransferLane, after seq: Int64?, limit: Int) async throws -> [TransferQueueItem] {
        guard lane == .library else { return [] }
        let queue = coordinator.queuedLocalIDs
        let start = seq.map { Int(clamping: $0) + 1 } ?? 0
        guard start < queue.count else { return [] }
        return queue[start..<min(queue.count, start + max(limit, 1))].enumerated().map { offset, id in
            let failure = coordinator.failure(for: id)
            return TransferQueueItem(source: .photo(DeviceAssetID(rawValue: id)), state: failure == nil ? .queued : .failed,
                                     seq: Int64(start + offset), displayName: failure?.filename, message: failure?.message,
                                     failedAt: failure?.date)
        }
    }

    /// Confirmed uploads, the latest first, from their receipts. The order is sorted off the main
    /// actor once per change of the confirmations.
    func historyPage(offset: Int, limit: Int) async throws -> [TransferHistoryItem] {
        let receipts = coordinator.associations
        let key = HistoryKey(scope: coordinator.activeScope, confirmed: coordinator.confirmed, receipts: receipts.count)
        let ids: [String]
        if let history, history.key == key { ids = history.ids } else {
            let dates = receipts.mapValues(\.confirmedAt)
            ids = await Task.detached(priority: .utility) {
                dates.sorted {
                    let left = $0.value ?? .distantPast, right = $1.value ?? .distantPast
                    return left == right ? $0.key < $1.key : left > right
                }.map(\.key)
            }.value
            history = (key, ids)
        }
        let start = max(offset, 0)
        guard start < ids.count else { return [] }
        return ids[start..<min(ids.count, start + max(limit, 1))].map {
            TransferHistoryItem(localID: DeviceAssetID(rawValue: $0), confirmedAt: receipts[$0]?.confirmedAt)
        }
    }

    /// Failed photos, the latest failure first.
    func failures(limit: Int) async throws -> [TransferQueueItem] {
        let revision = coordinator.stateRevision, limit = max(limit, 0)
        if let failureCache, failureCache.revision == revision, failureCache.limit == limit { return failureCache.items }
        let items = coordinator.failures.prefix(limit).enumerated().map { index, failure in
            TransferQueueItem(source: .photo(DeviceAssetID(rawValue: failure.id)), state: .failed, seq: Int64(index),
                              displayName: failure.filename, message: failure.message, failedAt: failure.date)
        }
        failureCache = (revision, limit, items)
        return items
    }

    func albumUploadCounts() async throws -> [String: AlbumUploadCount] {
        let revision = coordinator.stateRevision
        if let countsCache, countsCache.revision == revision { return countsCache.counts }
        let counts = coordinator.albumUploadCounts
        countsCache = (revision, counts)
        return counts
    }
}

/// Follows one subscriber's coordinator through Observation and sends its snapshot.
@MainActor private final class SnapshotWatch {
    private let coordinator: BackupCoordinator
    private let continuation: AsyncStream<TransferSnapshot>.Continuation
    private var lastPhase: TransferPhase?
    private var lastSent: ContinuousClock.Instant?
    private var flush: Task<Void, Never>?
    private var stopped = false
    private static let interval = Duration.milliseconds(250)

    init(coordinator: BackupCoordinator, continuation: AsyncStream<TransferSnapshot>.Continuation) {
        self.coordinator = coordinator
        self.continuation = continuation
    }

    func stop() {
        stopped = true
        flush?.cancel(); flush = nil
    }

    /// Sends the snapshot now and watches for the next change. Every change is sent, even one
    /// that leaves the counts alone (another account's state, a preference), so readers can
    /// reread what the snapshot doesn't carry.
    func send() {
        guard !stopped else { return }
        let value = withObservationTracking { LegacySnapshot.make(coordinator) } onChange: { [weak self] in
            Task { @MainActor in self?.changed() }
        }
        lastPhase = value.phase
        lastSent = .now
        continuation.yield(value)
    }

    private func changed() {
        guard !stopped, flush == nil else { return }
        let phase = LegacySnapshot.phase(coordinator)
        guard let lastSent, phase == lastPhase else { return send() }
        let wait = Self.interval - lastSent.duration(to: .now)
        guard wait > .zero else { return send() }
        flush = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            self.flush = nil
            self.send()
        }
    }
}

/// The coordinator's state as a TransferSnapshot.
@MainActor enum LegacySnapshot {
    static func make(_ coordinator: BackupCoordinator) -> TransferSnapshot {
        let running = coordinator.isRunning
        var snapshot = TransferSnapshot(intent: !running ? .paused : coordinator.preferences.automatic ? .automatic : .manual,
                                        phase: phase(coordinator), remaining: coordinator.remaining, confirmed: coordinator.confirmed,
                                        failed: coordinator.failureCount, fileProgress: coordinator.progress,
                                        bytesSent: coordinator.bytesTransferred, bytesExpected: coordinator.totalTransferBytes,
                                        bytesPerSecond: coordinator.transferRate, lastMessage: coordinator.error)
        snapshot.activity = coordinator.activity
        // Read so that a change to either is sent too: the preferences, and the account. The
        // failure count above reads the whole backup state.
        _ = coordinator.preferences
        _ = coordinator.activeScope
        return snapshot
    }

    static func phase(_ coordinator: BackupCoordinator) -> TransferPhase {
        coordinator.isDiscovering ? .discovering : coordinator.isRunning ? .running : .idle
    }
}

extension BackupPreferences {
    init(_ preferences: TransferPreferences) {
        self.init()
        includedAlbums = preferences.includedAlbums
        excludedAlbums = preferences.excludedAlbums
        cellularPhotos = preferences.cellularPhotos
        cellularVideos = preferences.cellularVideos
        downloadCloudOriginals = preferences.downloadCloudOriginals
        automatic = preferences.automatic
        requireCharging = preferences.requireCharging
        triggerDelay = preferences.triggerDelay
        syncAlbums = preferences.syncAlbums
    }
}

extension TransferPreferences {
    init(_ preferences: BackupPreferences) {
        var legacy = Legacy.BackupPreferences()
        legacy.includedAlbums = preferences.includedAlbums
        legacy.excludedAlbums = preferences.excludedAlbums
        legacy.cellularPhotos = preferences.cellularPhotos
        legacy.cellularVideos = preferences.cellularVideos
        legacy.downloadCloudOriginals = preferences.downloadCloudOriginals
        legacy.automatic = preferences.automatic
        legacy.requireCharging = preferences.requireCharging
        legacy.triggerDelay = preferences.triggerDelay
        legacy.syncAlbums = preferences.syncAlbums
        self.init(legacy)
    }
}

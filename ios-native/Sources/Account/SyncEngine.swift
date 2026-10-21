import Foundation

/// The account's library sync: when a pass runs, what a finished or failed pass does to media,
/// places and the screens, the live event stream, and the pass a background backup window asks
/// for. Moved from SessionStore as it was (C7). It belongs to one AccountRuntime, and once that
/// closes nothing it began changes anything. Q1 makes it the only writer of SyncStatus.
@MainActor @Observable final class SyncEngine {
    private(set) var syncError: String?
    private(set) var lastSyncDate: Date?
    private(set) var isSyncing = false
    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let entities: EntityStore
    @ObservationIgnored private let native: NativeSync
    @ObservationIgnored private let pipeline: MediaPipeline
    @ObservationIgnored private let warmer: ThumbnailWarmer
    @ObservationIgnored private let presence: AppPresence
    @ObservationIgnored private let check: SessionCheck
    @ObservationIgnored private let authorization: AuthorizationState
    @ObservationIgnored private let device: any AccountDevice
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncShutdown: Task<Void, Never>?
    @ObservationIgnored private var backgroundSyncOwner: UUID?
    @ObservationIgnored private var backgroundSyncPromoted = false
    @ObservationIgnored private var isResettingLibraryMetadata = false
    /// Until the account's runtime closes.
    @ObservationIgnored private(set) var isOpen = true

    init(client: APIClient, entities: EntityStore, native: NativeSync, pipeline: MediaPipeline, warmer: ThumbnailWarmer,
         presence: AppPresence, check: SessionCheck, authorization: AuthorizationState, device: any AccountDevice) {
        self.client = client
        self.entities = entities
        self.native = native
        self.pipeline = pipeline
        self.warmer = warmer
        self.presence = presence
        self.check = check
        self.authorization = authorization
        self.device = device
    }

    /// The app came to the front: a background pass in progress becomes the foreground's, and
    /// sync starts if it isn't running.
    func enteredForeground() {
        if backgroundSyncOwner != nil { backgroundSyncPromoted = true }
        startSync()
    }

    func enteredBackground() {
        backgroundSyncPromoted = false
        syncTask?.cancel(); syncTask = nil; isSyncing = false
        if backgroundSyncOwner == nil { let native = native; syncShutdown = Task { await native.stop() } }
    }

    func startSync() {
        guard isOpen, presence.isForeground, (backgroundSyncOwner == nil || backgroundSyncPromoted),
              !isResettingLibraryMetadata, syncTask == nil else { return }
        isSyncing = true; syncError = nil
        let client = client, entities = entities, sync = native
        syncTask = Task { [weak self] in
            await self?.syncShutdown?.value
            guard !Task.isCancelled else { return }
            await client.attachEntityStore(entities)
            do {
                let summary = try await sync.synchronize()
                guard !Task.isCancelled, let self, self.isOpen else { return }
                await self.didSync(summary)
            } catch is CancellationError {
                // Only this task's own cancellation ends it quietly. A pass cancelled under it must
                // not leave sync marked as running, or Sync now would never start another.
                guard !Task.isCancelled else { return }
            }
            catch {
                guard !Task.isCancelled, let self, self.isOpen else { return }
                await self.syncFailed(error)
            }
            guard !Task.isCancelled, let self, self.isOpen else { return }
            self.isSyncing = false; self.syncTask = nil
            await sync.startEvents(onChange: { [weak self] summary in
                await self?.didSync(summary)
            }, onError: { [weak self] error in
                await self?.syncFailed(error, live: true)
            })
        }
    }

    /// Syncs once for a background backup window. Returns whether the library is ready for it.
    func prepareForBackgroundBackup() async -> Bool {
        guard isOpen, backgroundSyncOwner == nil, !isResettingLibraryMetadata else { return false }
        let owner = UUID()
        backgroundSyncOwner = owner
        backgroundSyncPromoted = presence.isForeground
        isSyncing = true
        defer {
            if backgroundSyncOwner == owner {
                backgroundSyncOwner = nil
                backgroundSyncPromoted = false
                if !presence.isForeground || !isOpen { isSyncing = false }
                else { startSync() }
            }
        }

        await syncShutdown?.value
        syncShutdown = nil
        guard !Task.isCancelled, backgroundSyncOwner == owner, isOpen, !isResettingLibraryMetadata else { return false }

        await client.attachEntityStore(entities)
        guard !Task.isCancelled else { return false }
        let sync = native
        do {
            let summary = try await withTaskCancellationHandler {
                try await sync.synchronize()
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.backgroundSyncOwner == owner, self.isOpen,
                          !self.presence.isForeground, !self.backgroundSyncPromoted else { return }
                    await sync.stop()
                }
            }
            try Task.checkCancellation()
            guard backgroundSyncOwner == owner, isOpen, !isResettingLibraryMetadata else { return false }
            if !backgroundSyncPromoted { await didSync(summary) }
            return true
        } catch is CancellationError {
            if backgroundSyncOwner == owner, isOpen, !presence.isForeground, !backgroundSyncPromoted { await sync.stop() }
            return false
        } catch {
            guard backgroundSyncOwner == owner, isOpen, !isResettingLibraryMetadata else { return false }
            await syncFailed(error)
            return false
        }
    }

    func resetLibraryMetadata() async {
        guard isOpen, !isResettingLibraryMetadata, !isSyncing else { return }
        isResettingLibraryMetadata = true
        var resetRequested = false
        defer {
            isResettingLibraryMetadata = false
            if presence.isForeground && isOpen && resetRequested { startSync() }
        }
        isSyncing = true
        syncError = nil
        let previousTask = syncTask
        syncTask?.cancel()
        syncTask = nil
        await syncShutdown?.value
        syncShutdown = nil
        await native.stop()
        await previousTask?.value
        guard isOpen else { return }
        do {
            try await entities.clear()
            resetRequested = true
            authorization.accessChanged()
            await TimelineCache.shared.removeAll(scope: client.cacheScope)
            await TimelinePlacesCache.shared.removeAll(scope: client.cacheScope)
            guard isOpen else { return }
            LegacyNotificationBridge.libraryChanged(scope: client.cacheScope, collections: true, accessChanged: false)
        } catch {
            guard isOpen else { return }
            syncError = error.localizedDescription
            isSyncing = false
        }
    }

    /// Sign-out: nothing begun here changes anything any more. Cancels the passes and the live
    /// stream, and waits for them to end.
    func shutdown() async {
        isOpen = false
        let task = syncTask
        syncTask = nil; isSyncing = false
        task?.cancel()
        await syncShutdown?.value
        syncShutdown = nil
        await native.stop()
        await task?.value
    }

    private func didSync(_ summary: SyncChangeSummary) async {
        guard isOpen else { return }
        let date = try? await entities.lastSyncDate()
        guard isOpen else { return }
        lastSyncDate = date; syncError = nil
        await client.persistCachedServerFeatures()
        guard isOpen else { return }
        if summary.completed { warmer.start(entities: entities, pipeline: pipeline) }
        guard summary.changed || summary.completed || !summary.assetIDs.isEmpty else { return }
        let resetPending = (try? await entities.takeAccessInvalidation()) == true
        guard isOpen else { return }
        if resetPending || summary.reset { await pipeline.removeAll() }
        // Clearing every cache for one deletion would throw away the whole offline library.
        let revoked = await purgeRemovedMedia()
        guard isOpen else { return }
        if resetPending || summary.reset || revoked {
            // Places are kept through ordinary syncs, but not past a change in what may be seen.
            authorization.accessChanged()
            await TimelinePlacesCache.shared.removeAll(scope: client.cacheScope)
        }
        guard isOpen else { return }
        await TimelineCache.shared.removeAll(scope: client.cacheScope)
        guard isOpen else { return }
        LegacyNotificationBridge.libraryChanged(scope: client.cacheScope, collections: summary.collectionsChanged,
                                                accessChanged: resetPending || summary.accessChanged || revoked)
        await device.reloadWidgets()
        if summary.configurationChanged { check.validate() }
    }

    /// `live` says the failure is the live connection's, which tries again by itself, rather than
    /// a sync pass's.
    private func syncFailed(_ error: any Error, live: Bool = false) async {
        guard isOpen else { return }
        let resetPending = (try? await entities.takeAccessInvalidation()) == true
        guard isOpen else { return }
        if resetPending { await pipeline.removeAll() }
        // Batches that committed before the failure removed their photos from the index already.
        let revoked = await purgeRemovedMedia()
        guard isOpen else { return }
        if resetPending || revoked {
            authorization.accessChanged()
            await TimelineCache.shared.removeAll(scope: client.cacheScope)
            await TimelinePlacesCache.shared.removeAll(scope: client.cacheScope)
            guard isOpen else { return }
            LegacyNotificationBridge.libraryChanged(scope: client.cacheScope, collections: true, accessChanged: true)
        }
        if case ServerFailure.sessionExpired = error {
            // Signing out happens only when a second check agrees, as a transition of its own.
            let ending = await check.sessionEnds(after: error)
            // The session check found the session still valid.
            if !ending && isOpen {
                syncError = live ? "The server rejected the live connection. The library will reconnect."
                                 : "The server refused to sync. Sync again in a moment."
            }
        } else { syncError = error.localizedDescription }
    }

    /// Forgets the media of photos the index removed, a batch at a time, and only then takes them
    /// off the index's queue. Returns whether access to any of them was lost.
    private func purgeRemovedMedia() async -> Bool {
        var revoked = false
        // Bounded, so a queue that can't be cleared waits for the next sync instead of spinning.
        for _ in 0..<64 {
            guard isOpen, let purges = try? await entities.pendingMediaPurges(), !purges.isEmpty else { break }
            let lost = purges.contains(where: \.revoked)
            await pipeline.forget(assetIDs: Set(purges.map(\.assetID)), revoked: lost)
            revoked = revoked || lost
            guard (try? await entities.finishMediaPurges(purges)) != nil else { break }
        }
        return revoked
    }
}

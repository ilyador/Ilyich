import Foundation
import IlyichShareInbox
import Observation
import Photos

/// What the backup screens show and the commands they send (REBUILD_ROADMAP.md B8). It follows
/// the backend's snapshots, which arrive as backup changes, never by polling, and rereads the
/// failures, album counts and preferences with each. Preference edits are written once they
/// settle, and before any command, so a command always runs with what the screen shows.
@MainActor @Observable final class BackupStore: BackupEnqueuing {
    static let shared = BackupStore(backend: LegacyCoordinatorBackend.shared)

    private(set) var snapshot = TransferSnapshot(intent: .paused, phase: .idle, remaining: 0, confirmed: 0, failed: 0, fileProgress: nil,
                                                 bytesSent: 0, bytesExpected: 0, bytesPerSecond: nil, lastMessage: nil)
    /// The preferences as the screen edits them. Call `preferencesChanged()` after an edit.
    var preferences = TransferPreferences(Legacy.BackupPreferences())
    /// Failed photos, the latest failure first.
    private(set) var failures: [TransferQueueItem] = []
    /// Photos waiting for each server album after their backup.
    private(set) var albumUploads: [String: AlbumUploadCount] = [:]
    private(set) var permission: PHAuthorizationStatus
    private(set) var albums: [DeviceAlbum] = []
    /// A command the backend couldn't carry out. Today's backup never throws; its own errors
    /// arrive in the snapshot.
    private(set) var commandError: String?

    var isRunning: Bool { snapshot.phase == .running || snapshot.phase == .discovering }
    var activity: String { snapshot.activity ?? "Choose albums to back up" }
    var error: String? { snapshot.lastMessage ?? commandError }
    var remaining: Int { snapshot.remaining }
    var confirmed: Int { snapshot.confirmed }

    @ObservationIgnored let backend: any TransferControlling
    @ObservationIgnored private let photos: BackupPhotoAccess
    @ObservationIgnored private let debounce: Duration
    /// The preferences last read from or written to the backend.
    @ObservationIgnored private var adopted: TransferPreferences?
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    /// The latest write, which waits for those before it.
    @ObservationIgnored private var writing: Task<Void, Never>?
    @ObservationIgnored private var writes = 0
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var reads = 0

    init(backend: any TransferControlling, photos: BackupPhotoAccess = .live, debounce: Duration = .milliseconds(500)) {
        self.backend = backend
        self.photos = photos
        self.debounce = debounce
        permission = photos.authorization()
        following = Task { [weak self] in
            let snapshots = await backend.snapshots()
            for await snapshot in snapshots {
                guard let self else { return }
                await self.apply(snapshot)
            }
        }
    }

    // MARK: Commands

    /// Back up now, and Resume.
    func start() async {
        await perform { try await $0.setIntent(.manual) }
    }

    /// Pause, which switches automatic backup off.
    func pause() async {
        await perform { try await $0.setIntent(.paused) }
    }

    func retryFailures() async {
        await perform { try await $0.retry(nil) }
    }

    /// Adds phone photos to backup, for `albumID` when given. The outcome is this call's own: an
    /// error the screen shows from an earlier run is never taken for it.
    func enqueue(localIDs: [String], albumID: String?) async -> BackupEnqueueOutcome {
        await flushPreferences()
        let requests = localIDs.map {
            TransferRequest(source: .photo(DeviceAssetID(rawValue: $0)), origin: albumID == nil ? .selection : .albumUpload,
                            revision: nil, album: albumID)
        }
        do {
            switch try await backend.enqueue(requests) {
            case .queued, .alreadyBackedUp: return .queued
            case .refused(let restriction): return .failed(restriction.backupMessage)
            }
        } catch { return .failed(error.localizedDescription) }
    }

    /// Asks for Photos access, then reads the albums.
    func requestAccess() async {
        permission = await photos.requestAccess()
        await refreshLibrary()
    }

    /// Photos access and the album list, which the Photos adapter keeps until an album changes.
    func refreshLibrary() async {
        let status = photos.authorization()
        if status != permission { permission = status }
        let list = await photos.albums()
        if list != albums { albums = list }
    }

    // MARK: Preferences

    /// The screen edited `preferences`: written once edits pause for the debounce interval.
    func preferencesChanged() {
        pendingWrite?.cancel(); pendingWrite = nil
        guard preferences != adopted else { return }
        let debounce = debounce
        pendingWrite = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard !Task.isCancelled else { return }
            self?.writePreferences()
        }
    }

    /// Writes an edit still waiting at once, and returns once every write has reached the backend.
    func flushPreferences() async {
        if let pending = pendingWrite {
            pending.cancel()
            writePreferences()
        }
        await writing?.value
    }

    /// Sends the preferences shown, after any write before it.
    private func writePreferences() {
        pendingWrite = nil
        let value = preferences
        guard value != adopted else { return }
        adopted = value
        writes += 1
        let previous = writing, backend = backend
        writing = Task { [weak self] in
            await previous?.value
            do { try await backend.setPreferences(value) } catch { self?.commandError = error.localizedDescription }
            self?.writes -= 1
        }
    }

    // MARK: Snapshots

    private func perform(_ command: (any TransferControlling) async throws -> Void) async {
        await flushPreferences()
        do {
            try await command(backend)
            if commandError != nil { commandError = nil }
        } catch { commandError = error.localizedDescription }
    }

    private func apply(_ value: TransferSnapshot) async {
        if value != snapshot { snapshot = value }
        reads += 1
        let read = reads
        let failures = try? await backend.failures(limit: 10_000)
        let counts = try? await backend.albumUploadCounts()
        let before = preferences
        var stored: TransferPreferences?
        if pendingWrite == nil, writes == 0 { stored = try? await backend.preferences() }
        // A newer snapshot's reads win.
        guard read == reads else { return }
        if let failures, failures != self.failures { self.failures = failures }
        if let counts, counts != albumUploads { albumUploads = counts }
        // The backend's preferences show unless the screen holds an edit not yet written.
        if let stored, pendingWrite == nil, writes == 0, preferences == before, preferences == adopted || adopted == nil {
            adopted = stored
            if preferences != stored { preferences = stored }
        }
    }
}

/// Photos access and albums, for the backup screen.
struct BackupPhotoAccess: Sendable {
    var authorization: @MainActor @Sendable () -> PHAuthorizationStatus
    var albums: @MainActor @Sendable () async -> [DeviceAlbum]
    var requestAccess: @MainActor @Sendable () async -> PHAuthorizationStatus

    static let live = BackupPhotoAccess(
        authorization: { PhotoKitAdapter.shared.authorization },
        albums: { await PhotoKitAdapter.shared.albums() },
        requestAccess: {
            let status = await PhotoKitAdapter.shared.requestAccess().status
            // Automatic backup starts watching Photos once it may.
            BackupLifecycle.shared.configure()
            return status
        })

    /// No Photos access and no albums, for tests and previews.
    static let unavailable = BackupPhotoAccess(authorization: { .denied }, albums: { [] }, requestAccess: { .denied })
}

extension AccountRestriction {
    /// Why backup refused, in the words the backup screens use.
    var backupMessage: String {
        switch self {
        case .signedOut: "Backup isn’t available. Sign in again, then retry."
        case .sessionExpired: ServerFailure.sessionExpired(nil).localizedDescription
        case .proxyRejected: ServerFailure.proxyRejected(401).localizedDescription
        case .readOnly: "Turn off Read-only mode in Settings to upload."
        case .passwordChange: "Change your account password before starting backup."
        case .photosAccess: "Allow access to Photos before starting backup."
        case .deviceStorage: "Could not save backup progress. Free some device storage and retry."
        }
    }
}

/// What the Shared files sheet shows and the commands it sends (REBUILD_ROADMAP.md B8). Uploads
/// start and pause through TransferControlling; the inbox's batches, and today's upload state,
/// are read from ShareInboxStore, whose progress arrives from the share session as it is sent.
@MainActor @Observable final class ShareInboxModel {
    let api: APIClient
    @ObservationIgnored private let inbox: ShareInboxStore
    @ObservationIgnored private let backend: any TransferControlling

    init(api: APIClient, inbox: ShareInboxStore = .shared, backend: (any TransferControlling)? = nil) {
        self.api = api
        self.inbox = inbox
        self.backend = backend ?? LegacyCoordinatorBackend(inbox: inbox, shareClient: api)
    }

    var batches: [SharedBatch] { inbox.batches }
    var unreadableBatches: Int { inbox.unreadableBatches }
    var isRunning: Bool { inbox.isRunning }
    var currentID: String? { inbox.currentID }
    var progress: Double? { inbox.progress }
    var completed: Int { inbox.completed }
    var errors: [String: String] { inbox.errors }
    var error: String? { inbox.error }

    func refresh() async { await inbox.refresh() }

    /// Uploads the selected files.
    func upload(selected: Set<String>) async {
        let requests = batches.flatMap { batch in
            batch.attachments.filter { selected.contains($0.id) }.map {
                TransferRequest(source: .shared(batch: batch.id, attachment: $0.id), origin: .shareApproval, revision: nil,
                                displayName: $0.original.filename, batch: batch.id)
            }
        }
        guard !requests.isEmpty else { return }
        _ = try? await backend.enqueue(requests)
    }

    /// Pause upload: the files not yet sent stay.
    func pause() async {
        let sources = batches.flatMap { batch in batch.attachments.map { TransferSource.shared(batch: batch.id, attachment: $0.id) } }
        try? await backend.cancel(sources)
    }

    func discard(_ batch: SharedBatch) { inbox.discard(batch) }
}

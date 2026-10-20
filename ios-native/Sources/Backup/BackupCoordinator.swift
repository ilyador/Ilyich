import Foundation
import IlyichPlatform
import Observation
import Photos

struct BackupPreferences: Codable, Equatable, Sendable {
    var includedAlbums = Set<String>()
    var excludedAlbums = Set<String>()
    var cellularPhotos = false
    var cellularVideos = false
    var downloadCloudOriginals = false
    var automatic = false
    var requireCharging = false
    var triggerDelay = 30
    var syncAlbums = false

    init() {}
    private enum CodingKeys: String, CodingKey {
        case includedAlbums, excludedAlbums, cellularPhotos, cellularVideos, downloadCloudOriginals
        case automatic, requireCharging, triggerDelay, syncAlbums
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        includedAlbums = try c.decodeIfPresent(Set<String>.self, forKey: .includedAlbums) ?? []
        excludedAlbums = try c.decodeIfPresent(Set<String>.self, forKey: .excludedAlbums) ?? []
        cellularPhotos = try c.decodeIfPresent(Bool.self, forKey: .cellularPhotos) ?? false
        cellularVideos = try c.decodeIfPresent(Bool.self, forKey: .cellularVideos) ?? false
        downloadCloudOriginals = try c.decodeIfPresent(Bool.self, forKey: .downloadCloudOriginals) ?? false
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        requireCharging = try c.decodeIfPresent(Bool.self, forKey: .requireCharging) ?? false
        triggerDelay = min(3600, max(0, try c.decodeIfPresent(Int.self, forKey: .triggerDelay) ?? 30))
        syncAlbums = try c.decodeIfPresent(Bool.self, forKey: .syncAlbums) ?? false
    }
}

private struct BackupTransferNotification: Codable {
    var id: UUID
    var total: Int
    var completed = 0
    /// Nil while active; set once a terminal result is ready for replay.
    var terminalFailures: Int?
}

private struct BackupState: Codable {
    var preferences = BackupPreferences()
    var queue: [String] = []
    var current: PreparedPhoto?
    var confirmed: [String: Date] = [:]
    var receipts: [String: BackupReceipt]?
    var linkedAlbums: [String: String]?
    var pendingAlbumAdds: [String: Set<String>]?
    var suspended: [String: PreparedPhoto]?
    var failures: [String: BackupFailure]?
    var transferNotification: BackupTransferNotification?
    var paused = true
    var error: String?
}

@MainActor @Observable final class BackupCoordinator {
    static let shared = BackupCoordinator()
    var preferences = BackupPreferences()
    private(set) var albums: [DeviceAlbum] = []
    private(set) var permission = DevicePhotos.authorization
    private(set) var isRunning = false
    private(set) var remaining = 0
    private(set) var confirmed = 0
    private(set) var progress: Double?
    private(set) var bytesTransferred: Int64 = 0
    private(set) var totalTransferBytes: Int64 = 0
    private(set) var transferRate: Int64?
    var failures: [BackupFailure] { (state.failures ?? [:]).values.sorted { $0.date > $1.date } }
    /// Display associations for the active server/user. These are historical
    /// receipts; local deletion must use verifiedLocalDeletionCandidates().
    var associations: [String: BackupReceipt] { state.receipts ?? [:] }
    var queuedLocalIDs: [String] { state.queue }
    func failure(for localID: String) -> BackupFailure? { state.failures?[localID] }
    func pendingAlbumUploadCount(_ albumID: String) -> Int {
        state.pendingAlbumAdds?.values.filter { $0.contains(albumID) }.count ?? 0
    }
    func failedAlbumUploadCount(_ albumID: String) -> Int {
        state.pendingAlbumAdds?.filter { $0.value.contains(albumID) && state.failures?[$0.key] != nil }.count ?? 0
    }
    private(set) var activity = "Choose albums to back up"
    private(set) var error: String?
    private var state = BackupState()
    private var saved: StoredCredential?
    private var directory: URL?
    private var worker: Task<Void, Never>?
    private var discovery: Task<[String], any Error>?
    private var stopping: Task<Void, Never>?
    private var generation = UUID()
    private var lastProgress: (id: Int, time: Date, sent: Int64)?

    func activate() async {
        do {
            guard let session = try KeychainCredentialStore().load() else { return }
            guard session.scope != saved?.scope else { refreshLibrary(); return }
            guard !isRunning else { throw BackupError.message("Pause the active backup before switching accounts.") }
            guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: try AppGroup.identifier) else {
                throw BackupError.message("The app’s shared storage is unavailable. Check the app’s signing and reinstall.")
            }
            let folder = group.appendingPathComponent("Backup", isDirectory: true).appendingPathComponent(session.scope, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableFolder = folder
            try mutableFolder.setResourceValues(values)
            let file = folder.appendingPathComponent("state.json")
            state = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode(BackupState.self, from: Data(contentsOf: file)) : BackupState()
            saved = session; directory = folder; preferences = state.preferences
            error = state.error; refreshCounts(); refreshLibrary()
            BackupLifecycle.shared.configure()
            if state.transferNotification?.terminalFailures != nil { await replayFinishedTransferNotification() }
            if !state.paused, !state.queue.isEmpty {
                if state.transferNotification == nil {
                    state.transferNotification = BackupTransferNotification(id: UUID(), total: state.queue.count)
                    try persist()
                }
                if let batch = state.transferNotification {
                    let currentGeneration = generation
                    await TransferNotifications.started(id: batch.id, kind: "Backup", total: batch.total)
                    guard generation == currentGeneration, saved?.scope == session.scope,
                          state.transferNotification?.id == batch.id, !state.paused else {
                        TransferNotifications.cancel(id: batch.id); return
                    }
                }
                run()
            }
        } catch { self.error = error.localizedDescription }
    }

    func requestAccess() async {
        permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refreshLibrary()
        BackupLifecycle.shared.configure()
    }

    func refreshLibrary() {
        permission = DevicePhotos.authorization
        albums = DevicePhotos.albums()
    }

    func savePreferences() {
        state.preferences = preferences
        do { try persist() } catch { self.error = error.localizedDescription }
        BackupLifecycle.shared.configure()
    }

    func start(retryFailures: Bool = true) async {
        await activate()
        guard saved != nil, directory != nil, !isRunning, stopping == nil else { return }
        guard BackupLifecycle.shared.conditionsPermitBackup(requireCharging: preferences.requireCharging) else {
            activity = preferences.requireCharging ? "Waiting for charging and a cool device" : "Waiting for the device to cool down"
            return
        }
        guard [.authorized, .limited].contains(permission) else { error = "Allow access to Photos before starting backup."; return }
        let runID = generation
        let selection = preferences, confirmations = state.confirmed
        let discovery = Task.detached(priority: .utility) {
            try DevicePhotos.pendingCandidates(included: selection.includedAlbums, excluded: selection.excludedAlbums, confirmed: confirmations)
        }
        self.discovery = discovery; isRunning = true; activity = "Finding new photos"
        do {
            let pending = try await withTaskCancellationHandler { try await discovery.value } onCancel: { discovery.cancel() }
            try Task.checkCancellation()
            guard generation == runID else { return }
            self.discovery = nil; isRunning = false
            let queued = Set(state.queue)
            state.queue += pending.filter { !queued.contains($0) }
        } catch {
            guard generation == runID else { return }
            self.discovery = nil; isRunning = false
            if !(error is CancellationError) { self.error = error.localizedDescription }
            return
        }
        guard !state.queue.isEmpty || preferences.syncAlbums else { activity = "No new photos in the selected albums"; return }
        state.paused = false; state.error = nil; error = nil
        if !state.queue.isEmpty {
            if state.transferNotification == nil {
                state.transferNotification = BackupTransferNotification(id: UUID(), total: 0)
            }
            if var batch = state.transferNotification {
                batch.terminalFailures = nil
                batch.total = max(batch.total, batch.completed + state.queue.count)
                state.transferNotification = batch
            }
        }
        // A new attempt checks the server checksum before retrying a failed transfer.
        if var current = state.current { resetFailedTransfer(&current); state.current = current }
        do {
            try persist()
            if let batch = state.transferNotification {
                await TransferNotifications.started(id: batch.id, kind: "Backup", total: batch.total)
            }
            guard generation == runID, !state.paused else {
                if let id = state.transferNotification?.id { TransferNotifications.cancel(id: id) }
                return
            }
            run(retryFailures: retryFailures)
        } catch { self.error = error.localizedDescription }
    }

    func pause(disableAutomatic: Bool = true) async {
        if disableAutomatic { preferences.automatic = false; state.preferences = preferences }
        if let stopping {
            await stopping.value
            if disableAutomatic, let id = state.transferNotification?.id {
                TransferNotifications.cancel(id: id)
                clearTransferNotificationState()
                try? persist()
            }
            return
        }
        generation = UUID()
        let activeWorker = worker
        let activeDiscovery = discovery
        activeWorker?.cancel()
        activeDiscovery?.cancel()
        state.paused = true; progress = nil; activity = "Pausing backup"
        let stopping = Task {
            await BackgroundUploads.shared.cancelAll()
            await activeWorker?.value
            _ = try? await activeDiscovery?.value
            self.stopping = nil; worker = nil; discovery = nil; isRunning = false; activity = "Backup paused"
            if disableAutomatic, let id = state.transferNotification?.id {
                TransferNotifications.cancel(id: id)
                clearTransferNotificationState()
            }
            do { try persist() } catch { self.error = error.localizedDescription }
            BackupLifecycle.shared.configure()
        }
        self.stopping = stopping
        await stopping.value
    }

    /// Stops outgoing requests before the caller deletes the shared credentials.
    func disconnect() async {
        ShareInboxStore.shared.cancel()
        await pause()
        await ShareInboxStore.shared.waitUntilPaused()
        saved = nil; directory = nil; state = BackupState(); preferences = BackupPreferences()
        albums = []; error = nil; refreshCounts()
    }

    func startAutomatically() async {
        await activate()
        guard preferences.automatic, !isRunning, state.error == nil else { return }
        await start(retryFailures: false)
    }

    func enqueue(localIDs: [String], albumID: String? = nil) async {
        await activate()
        guard saved != nil, directory != nil else { return }
        guard !isRunning, stopping == nil else { error = "Pause backup before adding selected photos."; return }
        if let albumID {
            guard UUID(uuidString: albumID) != nil else { error = "The selected album is invalid."; return }
            if state.pendingAlbumAdds == nil { state.pendingAlbumAdds = [:] }
            for localID in localIDs { state.pendingAlbumAdds?[localID, default: []].insert(albumID) }
        }
        let existing = Set(state.queue)
        state.queue.append(contentsOf: Set(localIDs).subtracting(existing).sorted())
        do { try persist() } catch { self.error = error.localizedDescription; return }
        await start()
    }

    /// A past upload is not sufficient for deleting local data: recheck current
    /// server ownership, checksum, trash state, pair and local revision now.
    func verifiedLocalDeletionCandidates() async throws -> [String] {
        await activate()
        let runID = generation
        let session = try currentSession(runID)
        let api = try APIClient(baseURL: session.server, accessToken: session.token, userID: session.userID)
        var ids: [String] = []
        var measured: [String: BackupReceipt] = [:]
        for (localID, receipt) in state.receipts ?? [:] {
            _ = try currentSession(runID)
            guard DevicePhotos.canRemove(localID, revision: receipt.modificationDate) else { continue }
            let remote: BackupRemoteAsset = try await api.request(.get, path: "assets/\(receipt.original.id)")
            guard receipt.original.matches(remote, ownerID: session.userID) else { continue }
            var counted = receipt
            counted.original.byteCount = remote.knownByteCount
            if let motion = receipt.motion {
                guard remote.livePhotoVideoId == motion.id else { continue }
                let remoteMotion: BackupRemoteAsset = try await api.request(.get, path: "assets/\(motion.id)")
                guard motion.matches(remoteMotion, ownerID: session.userID) else { continue }
                counted.motion?.byteCount = remoteMotion.knownByteCount
            }
            _ = try currentSession(runID)
            if DevicePhotos.canRemove(localID, revision: receipt.modificationDate) { ids.append(localID); measured[localID] = counted }
        }
        // Record sizes only for receipts that are unchanged since verification began.
        var changed = false
        for (localID, counted) in measured {
            guard let current = state.receipts?[localID], current.modificationDate == counted.modificationDate,
                  current.original.id == counted.original.id, current.motion?.id == counted.motion?.id,
                  current.original.byteCount != counted.original.byteCount || current.motion?.byteCount != counted.motion?.byteCount else { continue }
            var updated = current
            updated.original.byteCount = counted.original.byteCount
            updated.motion?.byteCount = counted.motion?.byteCount
            state.receipts?[localID] = updated; changed = true
        }
        if changed { try? persist() }
        return ids.sorted()
    }

    /// Total original bytes (still/video plus paired motion) from the last verification, or nil if any is unknown.
    func verifiedOriginalByteCount(for localIDs: Set<String>) -> Int64? {
        var total: Int64 = 0
        for localID in localIDs {
            guard let receipt = state.receipts?[localID], let original = receipt.original.byteCount else { return nil }
            var bytes = original
            if let motion = receipt.motion {
                guard let motionBytes = motion.byteCount else { return nil }
                let (sum, overflow) = bytes.addingReportingOverflow(motionBytes)
                guard !overflow else { return nil }
                bytes = sum
            }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    private func run(retryFailures: Bool = false) {
        guard worker == nil, stopping == nil, !state.queue.isEmpty || preferences.syncAlbums else { return }
        let runID = generation
        isRunning = true
        worker = Task { await process(runID: runID, retryFailures: retryFailures) }
    }

    private func process(runID: UUID, retryFailures: Bool) async {
        defer {
            if generation == runID { isRunning = false; worker = nil; progress = nil }
        }
        do {
            var attempted = retryFailures ? Set<String>() : Set(state.failures?.keys.map { $0 } ?? [])
            while let localID = state.current?.localID ?? state.queue.first(where: { !attempted.contains($0) }) {
                let session = try currentSession(runID)
                try requireTransferConditions()
                guard let directory else { throw CancellationError() }
                do {
                    if state.current == nil, var suspended = state.suspended?[localID] {
                        resetFailedTransfer(&suspended)
                        state.current = suspended; state.suspended?[localID] = nil
                        try persist()
                    }
                    if state.current == nil {
                        activity = "Preparing full-size photo"
                        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        let prepared: PreparedPhoto
                        do {
                            prepared = try await DevicePhotos.prepare(localID, directory: folder, allowCloud: preferences.downloadCloudOriginals,
                                cellularPhotos: preferences.cellularPhotos, cellularVideos: preferences.cellularVideos) { value in
                                Task { @MainActor in
                                    if self.generation == runID { self.progress = value }
                                }
                            }
                            _ = try currentSession(runID)
                        } catch { try? FileManager.default.removeItem(at: folder); throw error }
                        state.current = prepared
                        try persist()
                    }
                    guard var prepared = state.current else { throw CancellationError() }
                    if let motion = prepared.motion, prepared.livePhotoID == nil {
                        var fields = prepared.fields
                        fields["visibility"] = "hidden"
                        fields["metadata"] = nil
                        let result = try await transfer(file: motion, sidecar: nil, fields: fields, prepared: prepared, session: session, runID: runID)
                        _ = try currentSession(runID)
                        prepared.livePhotoID = result.id; prepared.motionChecksum = result.checksum; prepared.stageID = UUID().uuidString
                        state.current = prepared
                        try persist()
                    }
                    var fields = prepared.fields
                    if let id = prepared.livePhotoID { fields["livePhotoVideoId"] = id }
                    let original = try await transfer(file: prepared.original, sidecar: prepared.sidecar, fields: fields, prepared: prepared, session: session, runID: runID)
                    _ = try currentSession(runID)
                    if let previous = state.receipts?[localID]?.original, previous.id != original.id {
                        let api = try APIClient(baseURL: session.server, accessToken: session.token, userID: session.userID)
                        struct StackCreation: Encodable, Sendable { let assetIds: [String] }
                        let _: StackDetails = try await api.request(.post, path: "stacks", body: StackCreation(assetIds: [original.id, previous.id]))
                        _ = try currentSession(runID)
                    }
                    if let destinations = state.pendingAlbumAdds?[localID], !destinations.isEmpty {
                        let api = try APIClient(baseURL: session.server, accessToken: session.token, userID: session.userID)
                        for albumID in destinations.sorted() {
                            _ = try currentSession(runID)
                            let results = try await api.addToAlbum(id: albumID, assetIDs: [original.id])
                            _ = try currentSession(runID)
                            guard results.count == 1, let result = results.first, result.id == original.id,
                                  result.success || result.error == "duplicate" else {
                                throw BackupError.item("The photo uploaded but could not be added to the selected album. Check album permissions and retry.")
                            }
                            state.pendingAlbumAdds?[localID]?.remove(albumID)
                            try persist()
                        }
                        state.pendingAlbumAdds?[localID] = nil
                    }
                    var motion: BackupRemoteFile?
                    if let id = prepared.livePhotoID, let checksum = prepared.motionChecksum { motion = BackupRemoteFile(id: id, checksum: checksum) }
                    // An older partially uploaded Live Photo has no durable video hash.
                    // It remains backed up, but is not eligible for local removal.
                    if prepared.motion == nil || motion != nil {
                        if state.receipts == nil { state.receipts = [:] }
                        state.receipts?[localID] = BackupReceipt(modificationDate: prepared.modificationDate, original: original, motion: motion, confirmedAt: Date())
                    }
                    state.confirmed[localID] = prepared.modificationDate
                    state.failures?[localID] = nil
                    state.queue.removeAll { $0 == localID }; state.current = nil
                    if var batch = state.transferNotification {
                        batch.completed += 1
                        state.transferNotification = batch
                    }
                    try persist()
                    try? FileManager.default.removeItem(at: prepared.original.url.deletingLastPathComponent())
                    refreshCounts()
                } catch {
                    _ = try currentSession(runID)
                    guard BackupAttempt.canContinue(after: error) else { throw error }
                    attempted.insert(localID)
                    recordFailure(error, localID: localID)
                    var disposable: URL?
                    if let current = state.current {
                        let folder = current.original.url.deletingLastPathComponent()
                        if current.livePhotoID != nil || BackgroundUploads.shared.completedReceipt(at: folder.appendingPathComponent(current.stageID + ".receipt")) != nil {
                            if state.suspended == nil { state.suspended = [:] }
                            state.suspended?[localID] = current
                        } else { disposable = folder }
                    }
                    state.current = nil; progress = nil
                    try persist()
                    if let disposable { try? FileManager.default.removeItem(at: disposable) }
                    else if let suspended = state.suspended?[localID] {
                        // Keep the source/receipt needed to resume, but not a second
                        // multipart copy after this completed transfer attempt.
                        try? FileManager.default.removeItem(at: suspended.original.url.deletingLastPathComponent().appendingPathComponent(suspended.stageID + ".multipart"))
                    }
                }
            }
            if preferences.syncAlbums { try await syncLinkedAlbums(runID: runID) }
            state.paused = true
            activity = state.queue.isEmpty ? "Selected photos backed up" : "\(state.queue.count.formatted()) uploads need retry"
            try persist()
            await finishTransferNotification(runID: runID)
        } catch is CancellationError { }
        catch let deferred as BackupDeferral {
            guard generation == runID else { return }
            activity = deferred.localizedDescription; state.paused = true
            try? persist()
        }
        catch {
            guard generation == runID else { return }
            self.error = error.localizedDescription; state.error = self.error; state.paused = true
            activity = "Backup needs attention"
            do { try persist() } catch { self.error = "Could not save backup progress. Free some device storage and retry." }
            await finishTransferNotification(runID: runID)
        }
    }

    private func resetFailedTransfer(_ prepared: inout PreparedPhoto) {
        let folder = prepared.original.url.deletingLastPathComponent()
        if BackgroundUploads.shared.completedReceipt(at: folder.appendingPathComponent(prepared.stageID + ".receipt")) == nil {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(prepared.stageID + ".multipart"))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(prepared.stageID + ".receipt"))
            prepared.stageID = UUID().uuidString
        }
    }

    private func recordFailure(_ error: any Error, localID: String) {
        if state.failures == nil { state.failures = [:] }
        state.failures?[localID] = BackupFailure(id: localID, filename: state.current?.original.filename ?? "Photo in selected album",
            message: error.localizedDescription, date: Date())
    }

    private func finishTransferNotification(runID: UUID) async {
        guard generation == runID, var batch = state.transferNotification else { return }
        let id = batch.id
        let completed = batch.completed
        // A failed attempt may later succeed on retry. At batch end, queued
        // photos are the actual failures; historical retry counts are not.
        let failures = state.queue.count
        let total = max(batch.total, completed + failures)
        batch.total = total
        batch.terminalFailures = failures
        state.transferNotification = batch
        do { try persist() } catch { self.error = error.localizedDescription; return }
        await TransferNotifications.finished(id: id, kind: "Backup", total: total, completed: completed, failed: failures)
        guard generation == runID, state.transferNotification?.id == id else { TransferNotifications.cancel(id: id); return }
        clearTransferNotificationState()
        do { try persist() } catch { self.error = error.localizedDescription }
    }

    private func replayFinishedTransferNotification() async {
        guard let batch = state.transferNotification, let failures = batch.terminalFailures else { return }
        let id = batch.id
        await TransferNotifications.finished(id: id, kind: "Backup", total: batch.total,
                                             completed: batch.completed, failed: failures)
        guard state.transferNotification?.id == id else { TransferNotifications.cancel(id: id); return }
        clearTransferNotificationState()
        try? persist()
    }

    private func clearTransferNotificationState() {
        state.transferNotification = nil
    }

    private func transfer(file: UploadFile, sidecar: UploadFile?, fields: [String: String], prepared: PreparedPhoto,
                          session: StoredCredential, runID: UUID) async throws -> BackupRemoteFile {
        try requireTransferConditions()
        activity = "Checking \(file.filename)"; progress = nil
        let checksum = try await UploadBody.work { try UploadBody.checksum(file.url) }
        _ = try currentSession(runID)
        let api = try APIClient(baseURL: session.server, accessToken: session.token, userID: session.userID)
        let check: UploadCheckResponse = try await api.request(.post, path: "assets/bulk-upload-check",
            body: UploadCheck(assets: [.init(id: prepared.localID, checksum: checksum)]))
        _ = try currentSession(runID)
        guard let result = check.results.first(where: { $0.id == prepared.localID }) else {
            throw BackupError.message("The server did not return a checksum result. Retry backup.")
        }
        if result.action == "reject" {
            guard result.reason == "duplicate", let id = result.assetId, result.isTrashed != true else {
                throw BackupError.item(result.isTrashed == true ? "This photo is in your server’s trash. Restore it there or empty the trash before retrying backup." : "The server rejected \(file.filename). Check its supported file formats.")
            }
            let ownReceipt = BackgroundUploads.shared.completedReceipt(at: file.url.deletingLastPathComponent().appendingPathComponent(prepared.stageID + ".receipt"))
            if sidecar != nil && !(ownReceipt?.id == id && ownReceipt?.status == "created") {
                throw BackupError.item("This photo already exists. Its XMP cannot be updated by uploading a duplicate; your source files were kept.")
            }
            if let motionID = fields["livePhotoVideoId"] {
                try await LivePhotoPairing.ensure(assetID: id, motionID: motionID, api: api)
            }
            return BackupRemoteFile(id: id, checksum: checksum)
        }
        guard result.action == "accept" else { throw BackupError.message("The server returned an unknown upload decision.") }
        let boundary = "Ilyich-" + prepared.stageID
        let folder = file.url.deletingLastPathComponent()
        let body = folder.appendingPathComponent(prepared.stageID + ".multipart")
        if !FileManager.default.fileExists(atPath: body.path) {
            try await UploadBody.work { try UploadBody.write(to: body, boundary: boundary, fields: fields, asset: file, sidecar: sidecar) }
        }
        _ = try currentSession(runID)
        var request = try await api.authorizedRequest(path: "assets")
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let isVideoTransfer = prepared.isVideo || prepared.motion?.url == file.url
        request.allowsCellularAccess = isVideoTransfer ? preferences.cellularVideos : preferences.cellularPhotos
        request.allowsExpensiveNetworkAccess = request.allowsCellularAccess
        activity = "Uploading \(file.filename)"
        let receipt = try await BackgroundUploads.shared.upload(request, body: body, id: prepared.stageID,
                                                               receipt: folder.appendingPathComponent(prepared.stageID + ".receipt"))
        _ = try currentSession(runID)
        if receipt.status == "duplicate" {
            if sidecar != nil { throw BackupError.item("This photo already exists. Its XMP needs review before this backup can be confirmed.") }
            if let motionID = fields["livePhotoVideoId"] { try await LivePhotoPairing.ensure(assetID: receipt.id, motionID: motionID, api: api) }
        }
        try? FileManager.default.removeItem(at: body)
        return BackupRemoteFile(id: receipt.id, checksum: checksum)
    }

    func refreshProgress() async {
        guard isRunning, let value = await BackgroundUploads.shared.progressSnapshot() else {
            bytesTransferred = 0; totalTransferBytes = 0; transferRate = nil; lastProgress = nil
            return
        }
        bytesTransferred = max(0, value.sent); totalTransferBytes = max(0, value.expected)
        if value.expected > 0 { progress = min(1, Double(value.sent) / Double(value.expected)) }
        let now = Date()
        if let lastProgress, lastProgress.id == value.taskID, value.sent >= lastProgress.sent {
            let elapsed = now.timeIntervalSince(lastProgress.time)
            transferRate = elapsed > 0 ? Int64(Double(value.sent - lastProgress.sent) / elapsed) : nil
        } else { transferRate = nil }
        lastProgress = (value.taskID, now, value.sent)
    }

    func reportSchedulingError(_ error: Error) {
        self.error = "iOS could not schedule automatic backup: \(error.localizedDescription). You can still use Back up now."
    }

    private func currentSession(_ runID: UUID) throws -> StoredCredential {
        try Task.checkCancellation()
        guard generation == runID, let saved, let current = try KeychainCredentialStore().load(),
              saved.scope == current.scope, saved.token == current.token else { throw CancellationError() }
        guard current.requiresPasswordChange != true else { throw BackupError.message("Change your account password before starting backup.") }
        try ReadOnlyPolicy.check(enabled: ReadOnlyPolicy.isEnabled(server: current.server, userID: current.userID), method: "POST", path: "assets")
        return current
    }

    private func requireTransferConditions() throws {
        guard BackupLifecycle.shared.conditionsPermitBackup(requireCharging: preferences.requireCharging) else {
            throw BackupDeferral.waitingForDevice
        }
    }

    private func syncLinkedAlbums(runID: UUID) async throws {
        let session = try currentSession(runID)
        let api = try APIClient(baseURL: session.server, accessToken: session.token, userID: session.userID)
        var remote: [Album] = try await api.request(.get, path: "albums", query: [.init(name: "isOwned", value: "true")])
        _ = try currentSession(runID)
        for local in albums where preferences.includedAlbums.contains(local.id) && !preferences.excludedAlbums.contains(local.id) {
            try requireTransferConditions()
            let localIDs = DevicePhotos.candidates(included: [local.id], excluded: preferences.excludedAlbums)
            let assetIDs = Set(localIDs.compactMap { state.receipts?[$0]?.original.id }).sorted()
            guard !assetIDs.isEmpty else { continue }
            activity = "Syncing album \(local.title)"
            let linked = state.linkedAlbums?[local.id]
            let album: Album
            if let existing = remote.first(where: { $0.id == linked }) ?? remote.first(where: { $0.albumName == local.title }) {
                album = existing
            } else {
                _ = try currentSession(runID)
                album = try await api.createAlbum(name: local.title)
                remote.append(album)
            }
            _ = try currentSession(runID)
            if state.linkedAlbums == nil { state.linkedAlbums = [:] }
            state.linkedAlbums?[local.id] = album.id
            try persist()
            for offset in stride(from: 0, to: assetIDs.count, by: 500) {
                _ = try currentSession(runID)
                let batch = Array(assetIDs[offset..<min(offset + 500, assetIDs.count)])
                let results = try await api.addToAlbum(id: album.id, assetIDs: batch)
                guard results.count == batch.count, results.allSatisfy({ $0.success || $0.error == "duplicate" }) else {
                    throw BackupError.message("Some backed-up photos could not be added to \(local.title). Check album permissions and retry.")
                }
            }
        }
    }

    private func persist() throws {
        guard let directory else { return }
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        refreshCounts()
    }

    private func refreshCounts() { remaining = state.queue.count; confirmed = state.confirmed.count }
}

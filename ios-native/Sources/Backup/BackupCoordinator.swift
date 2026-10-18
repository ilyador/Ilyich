import Foundation
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

    init() {}
    private enum CodingKeys: String, CodingKey {
        case includedAlbums, excludedAlbums, cellularPhotos, cellularVideos, downloadCloudOriginals
        case automatic, requireCharging, triggerDelay
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
    }
}

private struct BackupState: Codable {
    var preferences = BackupPreferences()
    var queue: [String] = []
    var current: PreparedPhoto?
    var confirmed: [String: Date] = [:]
    var receipts: [String: BackupReceipt]?
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
    private(set) var activity = "Choose albums to back up"
    private(set) var error: String?
    private var state = BackupState()
    private var saved: SavedSession?
    private var directory: URL?
    private var worker: Task<Void, Never>?
    private var generation = UUID()

    func activate() async {
        do {
            guard let session = try SessionKeychain.read() else { return }
            guard session.scope != saved?.scope else { refreshLibrary(); return }
            guard !isRunning else { throw BackupError.message("Pause the active backup before switching accounts.") }
            guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: try SessionKeychain.appGroup) else {
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
            if !state.paused, !state.queue.isEmpty { run() }
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

    func start() async {
        await activate()
        guard saved != nil, directory != nil, !isRunning else { return }
        guard BackupLifecycle.shared.conditionsPermitBackup(requireCharging: preferences.requireCharging) else {
            activity = preferences.requireCharging ? "Waiting for charging and a cool device" : "Waiting for the device to cool down"
            return
        }
        guard [.authorized, .limited].contains(permission) else { error = "Allow access to Photos before starting backup."; return }
        if state.queue.isEmpty {
            state.queue = DevicePhotos.candidates(included: preferences.includedAlbums, excluded: preferences.excludedAlbums)
                .filter {
                    guard let confirmedDate = state.confirmed[$0], let modifiedDate = DevicePhotos.modificationDate(for: $0) else { return true }
                    return confirmedDate != modifiedDate
                }
        }
        guard !state.queue.isEmpty else { activity = "No new photos in the selected albums"; return }
        state.paused = false; state.error = nil; error = nil
        // A new attempt checks the server checksum before retrying a failed transfer.
        if let current = state.current {
            let folder = current.original.url.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(current.stageID + ".multipart"))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(current.stageID + ".receipt"))
        }
        state.current?.stageID = UUID().uuidString
        do { try persist(); run() } catch { self.error = error.localizedDescription }
    }

    func pause(disableAutomatic: Bool = true) async {
        generation = UUID()
        worker?.cancel(); worker = nil
        state.paused = true; isRunning = false; progress = nil; activity = "Backup paused"
        if disableAutomatic { preferences.automatic = false; state.preferences = preferences }
        await BackgroundUploads.shared.cancelAll()
        do { try persist() } catch { self.error = error.localizedDescription }
        BackupLifecycle.shared.configure()
    }

    /// Stops outgoing requests before the caller deletes the shared credentials.
    func disconnect() async {
        await pause()
        saved = nil; directory = nil; state = BackupState(); preferences = BackupPreferences()
        albums = []; error = nil; refreshCounts()
    }

    func startAutomatically() async {
        await activate()
        guard preferences.automatic, !isRunning, state.error == nil else { return }
        await start()
    }

    func enqueue(localIDs: [String]) async {
        await activate()
        guard !isRunning else { error = "Pause backup before adding selected photos."; return }
        let existing = Set(state.queue)
        state.queue.append(contentsOf: Set(localIDs).subtracting(existing).sorted())
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
        for (localID, receipt) in state.receipts ?? [:] {
            _ = try currentSession(runID)
            guard DevicePhotos.canRemove(localID, revision: receipt.modificationDate) else { continue }
            let remote: BackupRemoteAsset = try await api.request(.get, path: "assets/\(receipt.original.id)")
            guard receipt.original.matches(remote, ownerID: session.userID) else { continue }
            if let motion = receipt.motion {
                guard remote.livePhotoVideoId == motion.id else { continue }
                let remoteMotion: BackupRemoteAsset = try await api.request(.get, path: "assets/\(motion.id)")
                guard motion.matches(remoteMotion, ownerID: session.userID) else { continue }
            }
            _ = try currentSession(runID)
            if DevicePhotos.canRemove(localID, revision: receipt.modificationDate) { ids.append(localID) }
        }
        return ids.sorted()
    }

    private func run() {
        guard worker == nil, !state.queue.isEmpty else { return }
        let runID = generation
        isRunning = true
        worker = Task { await process(runID: runID) }
    }

    private func process(runID: UUID) async {
        defer {
            if generation == runID { isRunning = false; worker = nil; progress = nil }
        }
        do {
            while let localID = state.queue.first {
                let session = try currentSession(runID)
                try requireTransferConditions()
                guard let directory else { throw CancellationError() }
                if state.current == nil {
                    activity = "Preparing original"
                    let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let prepared: PreparedPhoto
                    do {
                        prepared = try await DevicePhotos.prepare(localID, directory: folder, allowCloud: preferences.downloadCloudOriginals) { value in
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
                var motion: BackupRemoteFile?
                if let id = prepared.livePhotoID, let checksum = prepared.motionChecksum { motion = BackupRemoteFile(id: id, checksum: checksum) }
                // An older partially uploaded Live Photo has no durable video hash.
                // It remains backed up, but is not eligible for local removal.
                if prepared.motion == nil || motion != nil {
                    if state.receipts == nil { state.receipts = [:] }
                    state.receipts?[localID] = BackupReceipt(modificationDate: prepared.modificationDate, original: original, motion: motion)
                }
                state.confirmed[localID] = prepared.modificationDate
                state.queue.removeFirst(); state.current = nil
                try persist()
                try? FileManager.default.removeItem(at: prepared.original.url.deletingLastPathComponent())
                refreshCounts()
            }
            state.paused = true; activity = "Selected photos backed up"; try persist()
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
        }
    }

    private func transfer(file: UploadFile, sidecar: UploadFile?, fields: [String: String], prepared: PreparedPhoto,
                          session: SavedSession, runID: UUID) async throws -> BackupRemoteFile {
        try requireTransferConditions()
        activity = "Checking \(file.filename)"; progress = nil
        let checksum = try await Task.detached(priority: .utility) { try UploadBody.checksum(file.url) }.value
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
                throw BackupError.message(result.isTrashed == true ? "This photo is in your server’s trash. Restore it there or empty the trash before retrying backup." : "The server rejected \(file.filename). Check its supported file formats.")
            }
            if let motionID = fields["livePhotoVideoId"] {
                let existing = try await api.asset(id: id)
                _ = try currentSession(runID)
                if let paired = existing.livePhotoVideoId, paired != motionID {
                    throw BackupError.message("This photo is already paired with a different Live Photo video on the server. Its existing pairing was kept; review it before retrying.")
                }
                if existing.livePhotoVideoId == nil {
                    struct Pairing: Encodable, Sendable { let livePhotoVideoId: String }
                    try await api.requestVoid(.put, path: "assets/\(id)", body: Pairing(livePhotoVideoId: motionID))
                }
            }
            return BackupRemoteFile(id: id, checksum: checksum)
        }
        guard result.action == "accept" else { throw BackupError.message("The server returned an unknown upload decision.") }
        let boundary = "Ilyich-" + prepared.stageID
        let folder = file.url.deletingLastPathComponent()
        let body = folder.appendingPathComponent(prepared.stageID + ".multipart")
        if !FileManager.default.fileExists(atPath: body.path) {
            try await Task.detached(priority: .utility) { try UploadBody.write(to: body, boundary: boundary, fields: fields, asset: file, sidecar: sidecar) }.value
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
        try? FileManager.default.removeItem(at: body)
        return BackupRemoteFile(id: receipt.id, checksum: checksum)
    }

    func refreshProgress() async {
        if isRunning, let value = await BackgroundUploads.shared.currentProgress() { progress = value }
    }

    func reportSchedulingError(_ error: Error) {
        self.error = "iOS could not schedule automatic backup: \(error.localizedDescription). You can still use Back up now."
    }

    private func currentSession(_ runID: UUID) throws -> SavedSession {
        try Task.checkCancellation()
        guard generation == runID, let saved, let current = try SessionKeychain.read(),
              saved.scope == current.scope, saved.token == current.token else { throw CancellationError() }
        guard current.requiresPasswordChange != true else { throw BackupError.message("Change your account password before starting backup.") }
        return current
    }

    private func requireTransferConditions() throws {
        guard BackupLifecycle.shared.conditionsPermitBackup(requireCharging: preferences.requireCharging) else {
            throw BackupDeferral.waitingForDevice
        }
    }

    private func persist() throws {
        guard let directory else { return }
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        refreshCounts()
    }

    private func refreshCounts() { remaining = state.queue.count; confirmed = state.confirmed.count }
}

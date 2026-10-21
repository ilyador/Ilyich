import Foundation
import Observation
import CryptoKit
import IlyichPlatform

@MainActor @Observable final class ShareInboxStore {
    static let shared = ShareInboxStore()
    private(set) var batches: [SharedBatch] = []
    private(set) var isRunning = false
    private(set) var currentID: String?
    private(set) var progress: Double?
    private(set) var completed = 0
    private(set) var errors: [String: String] = [:]
    var error: String?
    private var worker: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var generation = UUID()

    func refresh() {
        do { batches = try SharedInbox.load() }
        catch { self.error = "Shared files couldn’t be read: \(error.localizedDescription)" }
    }

    func cancel() {
        guard stopping == nil else { return }
        generation = UUID()
        let activeWorker = worker
        activeWorker?.cancel()
        stopping = Task {
            await BackgroundUploads.sharing.cancelAll()
            await activeWorker?.value
            worker = nil; stopping = nil
            isRunning = false; currentID = nil; progress = nil
            refresh()
        }
    }

    func waitUntilPaused() async { await stopping?.value }

    func discard(_ batch: SharedBatch) {
        guard !isRunning, stopping == nil else { return }
        do { try SharedInbox.remove(batch.id); refresh() }
        catch { self.error = error.localizedDescription }
    }

    func upload(selected: Set<String>, api: APIClient) {
        guard !isRunning, stopping == nil, !selected.isEmpty else { return }
        let items = batches.flatMap { batch in batch.attachments.filter { selected.contains($0.id) }.map { (batch.id, $0) } }
        guard !items.isEmpty else { return }
        var totals: [UUID: Int] = [:]
        for (batchID, _) in items { totals[batchID, default: 0] += 1 }
        generation = UUID(); let runID = generation
        isRunning = true; error = nil; errors = [:]; completed = 0
        worker = Task {
            var notificationCompleted: [UUID: Int] = [:]
            var notificationsStarted = false
            defer {
                if generation == runID { isRunning = false; worker = nil; currentID = nil; progress = nil; refresh() }
            }
            do {
                guard let saved = try KeychainCredentialStore().load(), saved.server == api.baseURL, saved.userID == api.userID else {
                    throw BackupError.message("Sign in before uploading these shared files.")
                }
                for (batchID, total) in totals {
                    await TransferNotifications.started(id: batchID, kind: "Shared upload", total: total)
                }
                notificationsStarted = true
                for (batchID, item) in items {
                    try checkSession(saved, runID: runID)
                    currentID = item.id; progress = nil
                    do {
                        var fields = ["fileCreatedAt": Date().ISO8601Format(), "fileModifiedAt": Date().ISO8601Format()]
                        let dates = try item.original.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                        fields["fileCreatedAt"] = (dates.creationDate ?? Date()).ISO8601Format()
                        fields["fileModifiedAt"] = (dates.contentModificationDate ?? Date()).ISO8601Format()
                        if let motion = item.motion {
                            var hidden = fields; hidden["visibility"] = "hidden"
                            fields["livePhotoVideoId"] = try await transfer(motion, sidecar: nil, fields: hidden, api: api, saved: saved, runID: runID)
                        }
                        _ = try await transfer(item.original, sidecar: item.sidecar, fields: fields, api: api, saved: saved, runID: runID)
                        try checkSession(saved, runID: runID)
                        try consume(item, batchID: batchID)
                        completed += 1; refresh()
                        notificationCompleted[batchID, default: 0] += 1
                    } catch is CancellationError { throw CancellationError() }
                    // An ended session or a proxy's refusal stops every upload, not only this one.
                    catch let failure as ServerFailure where failure.stopsEveryUpload { throw failure }
                    catch {
                        try checkSession(saved, runID: runID)
                        errors[item.id] = error.localizedDescription
                    }
                }
            } catch is CancellationError { }
            catch { if generation == runID { self.error = error.localizedDescription } }
            if notificationsStarted {
                for (batchID, total) in totals {
                    guard !Task.isCancelled, generation == runID else { TransferNotifications.cancel(id: batchID); continue }
                    let done = notificationCompleted[batchID, default: 0]
                    await TransferNotifications.finished(id: batchID, kind: "Shared upload", total: total,
                                                         completed: done, failed: total - done)
                    if Task.isCancelled || generation != runID { TransferNotifications.cancel(id: batchID) }
                }
            }
        }
    }

    func refreshProgress() async {
        guard isRunning, let value = await BackgroundUploads.sharing.progressSnapshot(), value.expected > 0 else { return }
        progress = min(1, Double(value.sent) / Double(value.expected))
    }

    private func checkSession(_ expected: StoredCredential, runID: UUID) throws {
        try Task.checkCancellation()
        guard generation == runID, let current = try KeychainCredentialStore().load(),
              expected.scope == current.scope, expected.token == current.token else { throw CancellationError() }
        guard current.requiresPasswordChange != true else { throw BackupError.message("Change your account password before uploading.") }
        try ReadOnlyPolicy.check(enabled: ReadOnlyPolicy.isEnabled(server: current.server, userID: current.userID), method: "POST", path: "assets")
    }

    private func transfer(_ file: UploadFile, sidecar: UploadFile?, fields: [String: String], api: APIClient,
                          saved: StoredCredential, runID: UUID) async throws -> String {
        let checksum = try await UploadBody.work { try UploadBody.checksum(file.url) }
        let sidecarChecksum = try await UploadBody.work { try sidecar.map { try UploadBody.checksum($0.url) } ?? "" }
        let identity = [saved.scope, file.url.path, checksum, sidecarChecksum, fields["livePhotoVideoId"] ?? ""].joined(separator: "|")
        let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = file.url.deletingLastPathComponent()
        let body = folder.appendingPathComponent(id + ".multipart")
        let receipt = folder.appendingPathComponent(id + ".receipt")
        try checkSession(saved, runID: runID)
        let check: UploadCheckResponse = try await api.request(.post, path: "assets/bulk-upload-check",
            body: UploadCheck(assets: [.init(id: file.url.lastPathComponent, checksum: checksum)]))
        try checkSession(saved, runID: runID)
        guard let result = check.results.first(where: { $0.id == file.url.lastPathComponent }) else {
            throw BackupError.message("The server did not return an upload check. Your shared copy was kept for retry.")
        }
        if result.action == "reject" {
            guard result.reason == "duplicate", let id = result.assetId, result.isTrashed != true else {
                throw BackupError.message("The server rejected this file. Check its format or restore its server copy from trash, then retry.")
            }
            let ownReceipt = BackgroundUploads.sharing.completedReceipt(at: receipt)
            if sidecar != nil && !(ownReceipt?.id == id && ownReceipt?.status == "created") {
                throw BackupError.message("This photo already exists. Its XMP cannot be updated by uploading a duplicate; the shared files were kept.")
            }
            if let motionID = fields["livePhotoVideoId"] {
                try await LivePhotoPairing.ensure(assetID: id, motionID: motionID, api: api)
            }
            return id
        }
        guard result.action == "accept" else { throw BackupError.message("The server returned an unknown upload decision.") }
        defer { try? FileManager.default.removeItem(at: body) }
        BackgroundUploads.sharing.clearFailedReceipt(at: receipt)
        if !FileManager.default.fileExists(atPath: body.path) {
            try await UploadBody.work { try UploadBody.write(to: body, boundary: id, fields: fields, asset: file, sidecar: sidecar) }
        }
        try checkSession(saved, runID: runID)
        var request = try await api.authorizedRequest(path: "assets")
        request.httpMethod = "POST"; request.setValue("multipart/form-data; boundary=\(id)", forHTTPHeaderField: "Content-Type")
        try checkSession(saved, runID: runID)
        let response = try await BackgroundUploads.sharing.upload(request, body: body, id: id, receipt: receipt)
        if response.status == "duplicate", sidecar != nil { throw BackupError.message("This photo already exists. Its shared XMP was kept for you to review.") }
        if response.status == "duplicate", let motionID = fields["livePhotoVideoId"] {
            try checkSession(saved, runID: runID)
            try await LivePhotoPairing.ensure(assetID: response.id, motionID: motionID, api: api)
        }
        return response.id
    }

    private func consume(_ item: SharedAttachment, batchID: UUID) throws {
        guard var batch = try SharedInbox.load().first(where: { $0.id == batchID }) else { throw CocoaError(.fileNoSuchFile) }
        batch.attachments.removeAll { $0.id == item.id }
        if batch.attachments.isEmpty { try SharedInbox.remove(batch.id) }
        else {
            try SharedInbox.save(batch)
            for file in [item.original, item.motion, item.sidecar].compactMap({ $0 }) { try? FileManager.default.removeItem(at: file.url) }
        }
    }
}

private extension ServerFailure {
    /// The account can't upload anything right now, so no other file would fare better.
    var stopsEveryUpload: Bool {
        switch self {
        case .sessionExpired, .proxyRejected: true
        default: false
        }
    }
}

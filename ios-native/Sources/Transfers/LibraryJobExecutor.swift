import Foundation
import IlyichPlatform
import Synchronization

/// Backs up one phone photo for the transfer engine (B3, dormant until B9): nothing in the app
/// creates it, and backup still runs through BackupCoordinator and state.json.
///
/// A job stages the photo through P2's PhotoLibraryStaging (PhotoKitAdapter), on the adapter's own
/// queue, then uploads its parts: a Live Photo's video first, hidden and without the mobile-app
/// metadata, then the still with livePhotoVideoId. For each part (architecture section 4):
/// a bulk upload check whose ID is the photo's local identifier, the multipart body with boundary
/// Ilyich-<attempt>, the attempt's row, the transport, and the answer. The checksums are
/// computed once and kept with the stage, and the video's server ID too, so a job resumed after a
/// crash or a retry sends neither again. An attempt left unanswered is resumed by its ID: an
/// outcome on disk is applied without asking the server, and a task iOS still holds is adopted.
///
/// Duplicates: one in the server's trash fails the photo; one with an XMP sidecar counts only as
/// this attempt's own upload, when an attempt of this job was answered created with that ID;
/// a Live Photo's still is paired strictly (the server's answer, never the offline library),
/// failing the photo when it is paired with another video.
///
/// Cellular use follows the preferences as they are when the lease is taken: photos by
/// cellularPhotos, videos and Live Photo videos by cellularVideos.
///
/// Server calls go through `server`, the runtime's one client (APITransferServer); turns are
/// taken through `pipeline`. After every await it checks its lease. The engine commits what it
/// returns; `committed` then removes the stage's files.
final class LibraryJobExecutor: JobExecuting {
    /// job.phase as this executor writes it.
    enum Phase {
        static let staging = "staging"
        static let staged = "staged"
        static let motion = "motion"
        static let motionUploaded = "motionUploaded"
        static let original = "original"
    }

    let pipeline: TransferPipeline
    private let store: TransferStore
    private let staging: any PhotoLibraryStaging
    private let server: any TransferServerAPI
    private let uploader: any PartUploading
    private let layout: AppGroupLayout
    /// The account digest, which names every task's scope.
    private let scope: String
    /// The account's Backup folder, relative to the App Group.
    private let backupFolder: String
    private let checksum: @Sendable (URL) async throws -> String
    /// Stage folders of jobs that returned a result, removed once the engine commits it.
    private let finishedFolders = Mutex<[Int64: String]>([:])

    init(store: TransferStore, staging: any PhotoLibraryStaging, server: any TransferServerAPI, uploader: any PartUploading,
         layout: AppGroupLayout, account: AccountID, pipeline: TransferPipeline = TransferPipeline(),
         checksum: @escaping @Sendable (URL) async throws -> String = { url in try await UploadBody.work { try UploadBody.checksum(url) } }) {
        self.store = store
        self.staging = staging
        self.server = server
        self.uploader = uploader
        self.layout = layout
        scope = account.digest
        backupFolder = AccountStoragePaths(account).backup
        self.pipeline = pipeline
        self.checksum = checksum
    }

    /// Jobs the engine should run at once for this executor's pipeline.
    var concurrency: Int { pipeline.limits.jobs }

    func execute(_ job: LeasedJob, context: JobContext) async throws -> JobResult {
        guard case .photo(let id) = job.source else { throw TransferItemFailure.rejected("This transfer is not a photo backup.") }
        finishedFolders.withLock { _ = $0.removeValue(forKey: job.lease.job) }
        // The preferences as the lease is taken decide this job's network use.
        let preferences = try await store.preferences() ?? TransferPreferences(Legacy.BackupPreferences())
        try await context.ensureOwned()

        let stagingTurn = try await pipeline.acquireStaging()
        var holdsStagingTurn = true
        defer { if holdsStagingTurn { pipeline.release(stagingTurn) } }
        try await context.ensureOwned()

        var stage: LibraryStage
        if let existing = try await store.libraryStage(job: job.lease.job) {
            try await context.ensureOwned()
            stage = existing
        } else {
            try await context.ensureOwned()
            stage = try await stagePhoto(id.rawValue, job: job, context: context, preferences: preferences)
        }
        pipeline.record(bytes: bytes(of: stage), for: stagingTurn)
        let run = Run(job: job, context: context, localID: id.rawValue, preferences: preferences)

        // A Live Photo's video first, hidden and without the mobile-app metadata.
        if let motion = stage.motion, stage.motionRemoteID == nil {
            let motionChecksum = try await persistedChecksum(of: .motion, file: motion, stage: &stage, run: run)
            var fields = stage.fields
            fields["visibility"] = "hidden"
            fields["metadata"] = nil
            try await context.advance(to: .staged, phase: Phase.motion)
            let uploaded = try await upload(.motion, file: motion, sidecar: nil, fields: fields, checksum: motionChecksum, stage: stage,
                                             isVideo: true, run: run, onSubmitted: {})
            guard try await store.recordMotion(uploaded, stage: stage.stageID, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
            stage.motionRemoteID = uploaded
            try await context.advance(to: .staged, phase: Phase.motionUploaded)
        }

        // Then the still, or the video, with the Live Photo's video ID.
        let originalChecksum = try await persistedChecksum(of: .original, file: stage.original, stage: &stage, run: run)
        var fields = stage.fields
        if let motionID = stage.motionRemoteID { fields["livePhotoVideoId"] = motionID }
        let pipeline = self.pipeline
        let assetID = try await upload(.original, file: stage.original, sidecar: stage.sidecar, fields: fields, checksum: originalChecksum,
                                       stage: stage, isVideo: stage.isVideo, run: run, onSubmitted: {
            // Its last part is with the transport: the next job may stage.
            if holdsStagingTurn { holdsStagingTurn = false; pipeline.release(stagingTurn) }
        })

        let receipt: TransferReceipt?
        if stage.motion == nil {
            receipt = TransferReceipt(localID: id.rawValue, revision: stage.revision, original: RemoteCopy(id: assetID, checksum: originalChecksum),
                                      motion: nil, confirmedAt: nil)
        } else if let motionID = stage.motionRemoteID, let motionChecksum = stage.motionChecksum {
            receipt = TransferReceipt(localID: id.rawValue, revision: stage.revision, original: RemoteCopy(id: assetID, checksum: originalChecksum),
                                      motion: RemoteCopy(id: motionID, checksum: motionChecksum), confirmedAt: nil)
        } else {
            // A Live Photo an earlier build sent part way, without its video's checksum: backed
            // up, but without the receipt cleanup would need.
            receipt = nil
        }
        try await context.ensureOwned()
        finishedFolders.withLock { $0[job.lease.job] = stage.folder }
        return .backedUp(revision: stage.revision, assetID: assetID, receipt: receipt)
    }

    func committed(_ job: LeasedJob, result: JobResult) async {
        guard let folder = finishedFolders.withLock({ $0.removeValue(forKey: job.lease.job) }), isOwnStageFolder(folder) else { return }
        try? FileManager.default.removeItem(at: layout.url(forRelativePath: folder))
    }

    // MARK: Staging

    private func stagePhoto(_ localID: String, job: LeasedJob, context: JobContext, preferences: TransferPreferences) async throws -> LibraryStage {
        try await context.advance(to: .staging, phase: Phase.staging)
        let folder = backupFolder + "/" + UUID().uuidString
        let directory = layout.url(forRelativePath: folder)
        let policy = StagingPolicy(allowCloud: preferences.downloadCloudOriginals, cellularPhotos: preferences.cellularPhotos,
                                   cellularVideos: preferences.cellularVideos)
        var recorded = false
        do {
            let prepared = try await staging.stage(localID, into: directory, stageID: UUID().uuidString, policy: policy) { _ in }
            try await context.ensureOwned()
            let stage = LibraryStage(stageID: prepared.stageID, folder: folder, revision: AssetRevision(prepared.modificationDate),
                                     original: staged(prepared.original), motion: prepared.motion.map(staged), sidecar: prepared.sidecar.map(staged),
                                     fields: prepared.fields, isVideo: prepared.isVideo)
            guard try await store.saveStage(stage, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
            recorded = true
            try await context.advance(to: .staged, phase: Phase.staged)
            return stage
        } catch {
            // Files no stage row names would only wait for the sweep.
            if !recorded { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    private func staged(_ file: UploadFile) -> StagedFile {
        StagedFile(path: AppGroupLayout.relativePath(of: file.url) ?? file.url.absoluteString, filename: file.filename, contentType: file.contentType)
    }

    /// The file a staged path names: relative to the App Group, or a legacy absolute URL.
    private func url(of file: StagedFile) -> URL {
        if file.path.contains("://"), let url = URL(string: file.path) { return url }
        return layout.url(forRelativePath: file.path)
    }

    private func bytes(of stage: LibraryStage) -> Int64 {
        [stage.original, stage.motion, stage.sidecar].compactMap { $0 }.reduce(0) { total, file in
            let size = (try? FileManager.default.attributesOfItem(atPath: url(of: file).path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    /// Whether a folder is one this account's staging made, so nothing else is ever removed.
    private func isOwnStageFolder(_ folder: String) -> Bool {
        guard folder.hasPrefix(backupFolder + "/") else { return false }
        return UUID(uuidString: String(folder.dropFirst(backupFolder.count + 1))) != nil
    }

    /// The part's checksum: kept with the stage, or computed once and kept.
    private func persistedChecksum(of part: AttemptPart, file: StagedFile, stage: inout LibraryStage, run: Run) async throws -> String {
        if let kept = part == .motion ? stage.motionChecksum : stage.originalChecksum { return kept }
        let computed: String
        do { computed = try await checksum(url(of: file)) }
        catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) { throw TransferItemFailure.unreadableFile }
        try await run.context.ensureOwned()
        guard let kept = try await store.recordChecksum(computed, of: part, stage: stage.stageID, job: run.job.lease.job,
                                                        token: run.job.lease.token) else { throw LeaseLost() }
        if part == .motion { stage.motionChecksum = kept } else { stage.originalChecksum = kept }
        return kept
    }

    // MARK: Uploading a part

    /// One job's lease and what it has sent, for the parts it uploads.
    private struct Run {
        let job: LeasedJob
        let context: JobContext
        let localID: String
        let preferences: TransferPreferences
    }

    /// Uploads one part and returns its server ID.
    private func upload(_ part: AttemptPart, file: StagedFile, sidecar: StagedFile?, fields: [String: String], checksum: String,
                        stage: LibraryStage, isVideo: Bool, run: Run, onSubmitted: () -> Void) async throws -> String {
        let job = run.job, context = run.context
        let attempts = try await store.libraryAttempts(job: job.lease.job)
        try await context.ensureOwned()
        let unanswered = attempts.last { $0.part == part && $0.isUnanswered }

        // An answer nobody applied: the upload already ended.
        if let unanswered, let record = try uploader.recordedOutcome(for: key(unanswered.id, stage: stage)) {
            onSubmitted()
            return try await apply(record, attempt: unanswered, part: part, sidecar: sidecar, fields: fields, stage: stage, run: run)
        }

        let results = try await server.bulkUploadCheck([UploadCheck.Item(id: run.localID, checksum: checksum)])
        try await context.ensureOwned()
        guard let result = results.first(where: { $0.id == run.localID }) else {
            throw APIError.invalidResponse("The server did not return a checksum result.")
        }
        if result.action == "reject" {
            guard result.reason == "duplicate", let assetID = result.assetId else { throw TransferItemFailure.rejected(nil) }
            if result.isTrashed == true { throw TransferItemFailure.trashedDuplicate }
            // A sidecar reached the server only with this job's own upload of the photo.
            if sidecar != nil, !attempts.contains(where: { $0.part == part && $0.remoteStatus == "created" && $0.remoteID == assetID }) {
                throw TransferItemFailure.sidecarDuplicate
            }
            if part == .original, let motionID = fields["livePhotoVideoId"] { try await pair(assetID, with: motionID, context: context) }
            onSubmitted()
            return assetID
        }
        guard result.action == "accept" else { throw APIError.invalidResponse("The server returned an unknown upload decision.") }

        // The body: kept from an unanswered attempt whose body was written in full, which iOS may
        // still be sending, else new. One left .created never finished its body: the app ended
        // part way, or an earlier lease's write may still run or remove it, so it is abandoned
        // and its file left to the stage's cleanup. A kept body must end with its closing
        // boundary and have the size recorded when it was written (B6).
        var reusable = unanswered
        if var abandoned = unanswered, abandoned.state == .created {
            abandoned.state = .abandoned
            guard try await store.saveAttempt(abandoned, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
            reusable = nil
        }
        var attempt = reusable ?? LibraryAttempt(id: AttemptID(), part: part, state: .created)
        let key = self.key(attempt.id, stage: stage)
        let body = layout.url(forRelativePath: key.bodyPath)
        let written: Set<AttemptState> = [.bodyWritten, .submitted, .interrupted]
        if attempt.bodyPath == nil || !written.contains(attempt.state)
            || UploadBody.isComplete(body, boundary: Self.boundary(attempt.id), bytes: attempt.bodyBytes) != true {
            attempt.state = .created
            attempt.bodyPath = key.bodyPath
            attempt.checksum = checksum
            guard try await store.saveAttempt(attempt, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
            let asset = UploadFile(url: url(of: file), filename: file.filename, contentType: file.contentType)
            let xmp = sidecar.map { UploadFile(url: url(of: $0), filename: $0.filename, contentType: $0.contentType) }
            let boundary = Self.boundary(attempt.id)
            do { try await UploadBody.work { try UploadBody.write(to: body, boundary: boundary, fields: fields, asset: asset, sidecar: xmp) } }
            catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) { throw TransferItemFailure.unreadableFile }
            try await context.ensureOwned()
            attempt.state = .bodyWritten
            attempt.bodyBytes = (try? FileManager.default.attributesOfItem(atPath: body.path)[.size] as? NSNumber)?.int64Value
            guard try await store.saveAttempt(attempt, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
        }

        // The transport, one turn at a time.
        let turn = try await pipeline.acquireSubmission()
        defer { pipeline.release(turn) }
        try await context.advance(to: .submitting, phase: part == .motion ? Phase.motion : Phase.original)
        let allowsCellular = isVideo ? run.preferences.cellularVideos : run.preferences.cellularPhotos
        let request = try await server.uploadRequest(boundary: Self.boundary(attempt.id), allowsCellular: allowsCellular)
        try await context.ensureOwned()
        let taskID = try await uploader.submit(request, key: key)
        attempt.state = .submitted
        attempt.taskID = Int64(taskID)
        guard try await store.saveAttempt(attempt, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
        try await context.advance(to: .submitted)
        onSubmitted()

        let record = try await uploader.outcome(for: key) { sent, expected in Task { await context.progress(sent: sent, expected: expected) } }
        try await context.ensureOwned()
        return try await apply(record, attempt: attempt, part: part, sidecar: sidecar, fields: fields, stage: stage, run: run)
    }

    /// Records an answer and returns the part's server ID, or throws what it says went wrong.
    private func apply(_ record: OutcomeRecord, attempt: LibraryAttempt, part: AttemptPart, sidecar: StagedFile?, fields: [String: String],
                       stage: LibraryStage, run: Run) async throws -> String {
        let job = run.job, context = run.context
        let key = self.key(attempt.id, stage: stage)
        var attempt = attempt
        guard let receipt = record.receipt else {
            // Without a status the server never answered (a lost connection, a force quit): the
            // attempt is interrupted, and a retry checks again by checksum and sends this body
            // again. A status is the server's answer: a retry starts a new attempt after a new
            // check. Either way the row records it.
            let interrupted = record.httpStatus == nil
            attempt.state = interrupted ? .interrupted : .failed
            guard try await store.saveAttempt(attempt, failure: record, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
            try? uploader.acknowledge(key, keepingBody: interrupted)
            throw UploadOutcomeFailure.failed(record)
        }
        attempt.state = .completed
        attempt.remoteID = receipt.id
        attempt.remoteStatus = receipt.status
        // The row is what a resumed job reads from now on, so the file and body can go.
        guard try await store.saveAttempt(attempt, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
        try? uploader.acknowledge(key, keepingBody: false)
        if receipt.status == "duplicate" {
            // Someone else's copy: the sidecar did not go with it.
            if sidecar != nil { throw TransferItemFailure.sidecarDuplicate }
            if part == .original, let motionID = fields["livePhotoVideoId"] { try await pair(receipt.id, with: motionID, context: context) }
        }
        return receipt.id
    }

    /// Pairs a still the server already held with its video, asking the server, never the offline
    /// library. A still paired with another video fails the photo and is left as it is.
    private func pair(_ assetID: String, with motionID: String, context: JobContext) async throws {
        let paired = try await server.livePhotoVideoID(of: assetID)
        try await context.ensureOwned()
        if let paired {
            guard paired == motionID else { throw TransferItemFailure.livePairConflict }
            return
        }
        try await server.setLivePhotoVideo(assetID: assetID, motionID: motionID)
        try await context.ensureOwned()
    }

    private func key(_ attempt: AttemptID, stage: LibraryStage) -> AttemptKey {
        AttemptKey(attempt: attempt, scope: scope, folder: stage.folder)
    }

    static func boundary(_ attempt: AttemptID) -> String { "Ilyich-" + attempt.rawValue }
}

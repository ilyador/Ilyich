import CryptoKit
import Foundation
import IlyichPlatform
import IlyichShareInbox
import Synchronization

/// Uploads one shared file for the transfer engine (B4), in each account's TransferRuntime (B9).
///
/// A job is one attachment of a share batch, which the user approved:
/// - Repository validation: the batch's manifest is read on its own through ShareInboxRepository,
///   which confines every file to the batch's folder. A batch or attachment that is gone, or a
///   damaged batch, fails the job, which only the user retries.
/// - Upload in place: the files stay where the Share extension put them. The body and outcome are
///   <identity>.multipart and <identity>.receipt beside them, in ShareInbox/<batch>, sent on the
///   share-upload session.
/// - Deterministic identity: a part's identity hashes the account, the file's path relative to the
///   App Group, its checksum, its sidecar's checksum and the Live Photo video ID, so every retry
///   reuses the same body and outcome files, multipart boundary and task. Today's identity hashed
///   the absolute path instead: a task an earlier build still has in flight under it is adopted,
///   whichever container path form it recorded, and its receipt applied, never sent again.
/// - The bulk upload check's ID is the file's name, as today.
/// - A failed outcome left on disk from an earlier try is deleted before the file is sent again, so
///   it is never replayed as the new try's answer.
/// - A Live Photo's video goes first, hidden; the still follows with livePhotoVideoId. Checksums
///   and the video's server ID are kept with the job's stage row, so a resumed job sends neither
///   again.
/// The engine commits the result with share_consumed in the same transaction; `committed` then
/// rewrites the manifest without the attachment. If the app ends between the two,
/// `replayConsumed` does it at the next start, as often as needed.
final class ShareJobExecutor: JobExecuting {
    /// job.phase as this executor writes it.
    enum Phase {
        static let staged = "shareStaged"
        static let motion = "motion"
        static let motionUploaded = "motionUploaded"
        static let original = "original"
    }

    static let goneMessage = "This shared file is no longer in Shared files."

    private let store: TransferStore
    private let inbox: ShareInboxRepository
    private let server: any TransferServerAPI
    private let uploader: any PartUploading
    private let layout: AppGroupLayout
    /// The account digest, which names every task's scope and every identity.
    private let scope: String
    private let checksum: @Sendable (URL) async throws -> String
    /// Attachments whose result was returned, consumed once the engine commits it.
    private let finished = Mutex<[Int64: (batch: UUID, attachment: String)]>([:])

    init(store: TransferStore, inbox: ShareInboxRepository, server: any TransferServerAPI, uploader: any PartUploading, layout: AppGroupLayout,
         account: AccountID,
         checksum: @escaping @Sendable (URL) async throws -> String = { url in try await UploadBody.work { try UploadBody.checksum(url) } }) {
        self.store = store
        self.inbox = inbox
        self.server = server
        self.uploader = uploader
        self.layout = layout
        scope = account.digest
        self.checksum = checksum
    }

    // MARK: Identity

    /// A part's upload identity: the account, the file's path relative to the App Group, its
    /// checksum, its sidecar's checksum and the Live Photo video ID, hashed. The same on every
    /// retry and whatever the container's path.
    static func identity(scope: String, path: String, checksum: String, sidecarChecksum: String, livePhotoVideoID: String) -> String {
        legacyIdentity(scope: scope, path: path, checksum: checksum, sidecarChecksum: sidecarChecksum, livePhotoVideoID: livePhotoVideoID)
    }

    /// Today's identity (ShareInboxStore.uploadIdentity), which hashed the file's absolute path.
    static func legacyIdentity(scope: String, path: String, checksum: String, sidecarChecksum: String, livePhotoVideoID: String) -> String {
        let identity = [scope, path, checksum, sidecarChecksum, livePhotoVideoID].joined(separator: "|")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The absolute paths an earlier build may have hashed for a file: the path as resolved now and
    /// its other form on iOS, with or without /private.
    static func legacyPaths(of url: URL) -> [String] {
        let path = url.path
        if path.hasPrefix("/private/var/") { return [path, String(path.dropFirst("/private".count))] }
        if path.hasPrefix("/var/") { return [path, "/private" + path] }
        return [path]
    }

    // MARK: Running a job

    func execute(_ job: LeasedJob, context: JobContext) async throws -> JobResult {
        guard case .shared(let batchID, let name) = job.source else { throw TransferItemFailure.rejected("This transfer is not a shared file.") }
        finished.withLock { _ = $0.removeValue(forKey: job.lease.job) }

        // Repository validation: the manifest as it is now, its files confined to the batch.
        let state = await inbox.batch(batchID)
        try await context.ensureOwned()
        guard let state else { throw TransferItemFailure.rejected(Self.goneMessage) }
        guard case .ready(let batch) = state else {
            if case .damaged(_, let reason) = state { throw TransferItemFailure.rejected(reason.localizedDescription) }
            throw TransferItemFailure.rejected(Self.goneMessage)
        }
        guard let attachment = batch.attachments.first(where: { $0.id == name }) else { throw TransferItemFailure.rejected(Self.goneMessage) }

        var stage: LibraryStage
        let folder = ShareInboxRepository.folderName + "/" + batchID.uuidString
        if let existing = try await store.libraryStage(job: job.lease.job), existing.original.path == folder + "/" + attachment.original.name {
            try await context.ensureOwned()
            stage = existing
        } else {
            try await context.ensureOwned()
            stage = try await makeStage(attachment, folder: folder)
            guard try await store.saveStage(stage, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
            try await context.advance(to: .staged, phase: Phase.staged)
        }
        let run = Run(job: job, context: context, stage: stage)

        if let motion = stage.motion, stage.motionRemoteID == nil {
            let motionChecksum = try await persistedChecksum(of: .motion, file: motion, stage: &stage, run: run)
            var fields = stage.fields
            fields["visibility"] = "hidden"
            try await context.advance(to: .staged, phase: Phase.motion)
            let uploaded = try await upload(.motion, file: motion, sidecar: nil, sidecarChecksum: "", fields: fields, checksum: motionChecksum, run: run)
            guard try await store.recordMotion(uploaded, stage: stage.stageID, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
            stage.motionRemoteID = uploaded
            try await context.advance(to: .staged, phase: Phase.motionUploaded)
        }

        let originalChecksum = try await persistedChecksum(of: .original, file: stage.original, stage: &stage, run: run)
        var sidecarChecksum = ""
        if let sidecar = stage.sidecar {
            sidecarChecksum = try await fileChecksum(sidecar)
            try await context.ensureOwned()
        }
        var fields = stage.fields
        if let motionID = stage.motionRemoteID { fields["livePhotoVideoId"] = motionID }
        let remoteID = try await upload(.original, file: stage.original, sidecar: stage.sidecar, sidecarChecksum: sidecarChecksum, fields: fields,
                                        checksum: originalChecksum, run: run)
        try await context.ensureOwned()
        finished.withLock { $0[job.lease.job] = (batchID, name) }
        return .shared(remoteID: remoteID)
    }

    /// The engine committed the upload with share_consumed: the manifest is rewritten without the
    /// attachment, and its files go. A failure here leaves the record for `replayConsumed`.
    func committed(_ job: LeasedJob, result: JobResult) async {
        guard let done = finished.withLock({ $0.removeValue(forKey: job.lease.job) }) else { return }
        await consume(batch: done.batch, attachment: done.attachment)
    }

    /// Rewrites the manifest of every attachment whose upload committed, for a start after the app
    /// ended between the commit and the rewrite. Running it again changes nothing. Returns how many
    /// records it settled.
    @discardableResult
    func replayConsumed() async -> Int {
        guard let consumed = try? await store.consumedShares() else { return 0 }
        var settled = 0
        for share in consumed {
            if await consume(batch: share.batch, attachment: share.attachment) { settled += 1 }
        }
        return settled
    }

    /// Takes the attachment out of its batch, which counts as done when the batch or attachment is
    /// already gone, then forgets the record.
    @discardableResult
    private func consume(batch: UUID, attachment: String) async -> Bool {
        do {
            try await inbox.consume(attachment, from: batch)
            try await store.forgetConsumedShare(batch: batch, attachment: attachment)
            return true
        } catch {
            return false
        }
    }

    // MARK: Stage

    /// The attachment's files where they are, and the fields today's share upload sends: the
    /// original's creation and modification dates, read once and kept so the body stays the same.
    private func makeStage(_ attachment: SharedAttachment, folder: String) async throws -> LibraryStage {
        let original = attachment.original.url
        let dates = try? original.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let now = Date()
        let fields = ["fileCreatedAt": (dates?.creationDate ?? now).ISO8601Format(),
                      "fileModifiedAt": (dates?.contentModificationDate ?? now).ISO8601Format()]
        func staged(_ file: SharedFile) -> StagedFile {
            StagedFile(path: folder + "/" + file.name, filename: file.filename, contentType: file.contentType)
        }
        return LibraryStage(stageID: UUID().uuidString, folder: folder, revision: AssetRevision(dates?.contentModificationDate ?? now),
                            original: staged(attachment.original), motion: attachment.motion.map(staged),
                            sidecar: attachment.sidecar.map(staged), fields: fields,
                            isVideo: attachment.original.contentType.hasPrefix("video/"))
    }

    private func fileChecksum(_ file: StagedFile) async throws -> String {
        do { return try await checksum(layout.url(forRelativePath: file.path)) }
        catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) { throw TransferItemFailure.unreadableFile }
    }

    /// The part's checksum: kept with the stage, or computed once and kept.
    private func persistedChecksum(of part: AttemptPart, file: StagedFile, stage: inout LibraryStage, run: Run) async throws -> String {
        if let kept = part == .motion ? stage.motionChecksum : stage.originalChecksum { return kept }
        let computed = try await fileChecksum(file)
        try await run.context.ensureOwned()
        guard let kept = try await store.recordChecksum(computed, of: part, stage: stage.stageID, job: run.job.lease.job,
                                                        token: run.job.lease.token) else { throw LeaseLost() }
        if part == .motion { stage.motionChecksum = kept } else { stage.originalChecksum = kept }
        return kept
    }

    // MARK: Uploading a part

    private struct Run {
        let job: LeasedJob
        let context: JobContext
        let stage: LibraryStage
    }

    private func key(_ attempt: AttemptID, folder: String) -> AttemptKey {
        AttemptKey(attempt: attempt, scope: scope, folder: folder)
    }

    /// Uploads one part and returns its server ID.
    private func upload(_ part: AttemptPart, file: StagedFile, sidecar: StagedFile?, sidecarChecksum: String, fields: [String: String],
                        checksum: String, run: Run) async throws -> String {
        let job = run.job, context = run.context, folder = run.stage.folder
        let video = fields["livePhotoVideoId"] ?? ""
        let identity = AttemptID(legacy: Self.identity(scope: scope, path: file.path, checksum: checksum, sidecarChecksum: sidecarChecksum,
                                                       livePhotoVideoID: video))
        let legacy = Self.legacyPaths(of: layout.url(forRelativePath: file.path)).map {
            AttemptID(legacy: Self.legacyIdentity(scope: scope, path: $0, checksum: checksum, sidecarChecksum: sidecarChecksum, livePhotoVideoID: video))
        }
        let attempts = try await store.libraryAttempts(job: job.lease.job)
        try await context.ensureOwned()
        let unanswered = attempts.last { $0.part == part && $0.isUnanswered && ([identity] + legacy).contains($0.id) }

        // An answer nobody applied, for the try this job recorded.
        if let unanswered, let record = try uploader.recordedOutcome(for: key(unanswered.id, folder: folder)) {
            return try await apply(record, attempt: unanswered, part: part, sidecar: sidecar, fields: fields, run: run)
        }

        // A task iOS still holds for this file: this job's, or one an earlier build sent under
        // today's identity. Adopted, never sent again.
        var candidates: [AttemptID] = []
        for id in [unanswered?.id, identity].compactMap({ $0 }) + legacy where !candidates.contains(id) { candidates.append(id) }
        for id in candidates {
            guard await uploader.holdsTask(for: id) else { continue }
            try await context.ensureOwned()
            let attempt = unanswered?.id == id ? unanswered!
                : LibraryAttempt(id: id, part: part, state: .bodyWritten, bodyPath: key(id, folder: folder).bodyPath, checksum: checksum)
            return try await submit(attempt, part: part, sidecar: sidecar, fields: fields, run: run)
        }

        // Outcome files no try of this job's waits for: an earlier build's, or one whose answer was
        // recorded and not deleted. A receipt is this file's own upload, as the identity covers its
        // checksums; a failure is stale, and goes before the file is sent again.
        for id in candidates where id != unanswered?.id {
            guard let record = try uploader.recordedOutcome(for: key(id, folder: folder)) else { continue }
            if record.receipt != nil {
                let attempt = LibraryAttempt(id: id, part: part, state: .submitted, bodyPath: key(id, folder: folder).bodyPath, checksum: checksum)
                guard try await store.saveAttempt(attempt, session: .shareUpload, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
                return try await apply(record, attempt: attempt, part: part, sidecar: sidecar, fields: fields, run: run)
            }
            try? uploader.acknowledge(key(id, folder: folder), keepingBody: true)
        }

        // The bulk upload check, by the file's name.
        let checkID = (file.path as NSString).lastPathComponent
        let results = try await server.bulkUploadCheck([UploadCheck.Item(id: checkID, checksum: checksum)])
        try await context.ensureOwned()
        guard let result = results.first(where: { $0.id == checkID }) else {
            throw APIError.invalidResponse("The server did not return an upload check. Your shared copy was kept for retry.")
        }
        if result.action == "reject" {
            guard result.reason == "duplicate", let assetID = result.assetId else { throw TransferItemFailure.rejected(nil) }
            if result.isTrashed == true { throw TransferItemFailure.trashedDuplicate }
            // A sidecar reached the server only with this job's own upload of the file.
            if sidecar != nil, !attempts.contains(where: { $0.part == part && $0.remoteStatus == "created" && $0.remoteID == assetID }) {
                throw TransferItemFailure.sidecarDuplicate
            }
            if part == .original, !video.isEmpty { try await pair(assetID, with: video, context: context) }
            return assetID
        }
        guard result.action == "accept" else { throw APIError.invalidResponse("The server returned an unknown upload decision.") }

        // The body, in place beside the files: kept when a try of this identity wrote it in full.
        var attempt = unanswered?.id == identity ? unanswered! : LibraryAttempt(id: identity, part: part, state: .created)
        if let unanswered, unanswered.id != identity {
            // A legacy try whose task and answer are both gone: this identity takes over.
            var abandoned = unanswered
            abandoned.state = .abandoned
            guard try await store.saveAttempt(abandoned, session: .shareUpload, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
        }
        let attemptKey = key(identity, folder: folder)
        let body = layout.url(forRelativePath: attemptKey.bodyPath)
        let written: Set<AttemptState> = [.bodyWritten, .submitted, .interrupted]
        if !written.contains(attempt.state) || UploadBody.isComplete(body, boundary: identity.rawValue, bytes: attempt.bodyBytes) != true {
            attempt.state = .created
            attempt.bodyPath = attemptKey.bodyPath
            attempt.checksum = checksum
            guard try await store.saveAttempt(attempt, session: .shareUpload, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
            let asset = UploadFile(url: layout.url(forRelativePath: file.path), filename: file.filename, contentType: file.contentType)
            let xmp = sidecar.map { UploadFile(url: layout.url(forRelativePath: $0.path), filename: $0.filename, contentType: $0.contentType) }
            let boundary = identity.rawValue
            do { try await UploadBody.work { try UploadBody.write(to: body, boundary: boundary, fields: fields, asset: asset, sidecar: xmp) } }
            catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) { throw TransferItemFailure.unreadableFile }
            try await context.ensureOwned()
            attempt.state = .bodyWritten
            attempt.bodyBytes = (try? FileManager.default.attributesOfItem(atPath: body.path)[.size] as? NSNumber)?.int64Value
            guard try await store.saveAttempt(attempt, session: .shareUpload, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
        }
        return try await submit(attempt, part: part, sidecar: sidecar, fields: fields, run: run)
    }

    /// Hands the try to the share-upload session (which adopts a task iOS holds for it) and waits
    /// for its answer.
    private func submit(_ attempt: LibraryAttempt, part: AttemptPart, sidecar: StagedFile?, fields: [String: String], run: Run) async throws -> String {
        let job = run.job, context = run.context
        var attempt = attempt
        let attemptKey = key(attempt.id, folder: run.stage.folder)
        try await context.advance(to: .submitting, phase: part == .motion ? Phase.motion : Phase.original)
        let request = try await server.uploadRequest(boundary: attempt.id.rawValue, allowsCellular: true)
        try await context.ensureOwned()
        let taskID = try await uploader.submit(request, key: attemptKey)
        attempt.state = .submitted
        attempt.taskID = Int64(taskID)
        guard try await store.saveAttempt(attempt, session: .shareUpload, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
        try await context.advance(to: .submitted)
        let record = try await uploader.outcome(for: attemptKey) { sent, expected in Task { await context.progress(sent: sent, expected: expected) } }
        try await context.ensureOwned()
        return try await apply(record, attempt: attempt, part: part, sidecar: sidecar, fields: fields, run: run)
    }

    /// Records an answer and returns the part's server ID, or throws what it says went wrong. The
    /// outcome file is deleted either way, so a later try never reads it again.
    private func apply(_ record: OutcomeRecord, attempt: LibraryAttempt, part: AttemptPart, sidecar: StagedFile?, fields: [String: String],
                       run: Run) async throws -> String {
        let job = run.job
        let attemptKey = key(attempt.id, folder: run.stage.folder)
        var attempt = attempt
        guard let receipt = record.receipt else {
            let interrupted = record.httpStatus == nil
            attempt.state = interrupted ? .interrupted : .failed
            guard try await store.saveAttempt(attempt, failure: record, session: .shareUpload, job: job.lease.job, token: job.lease.token) else {
                throw LeaseLost()
            }
            try? uploader.acknowledge(attemptKey, keepingBody: interrupted)
            throw UploadOutcomeFailure.failed(record)
        }
        attempt.state = .completed
        attempt.remoteID = receipt.id
        attempt.remoteStatus = receipt.status
        guard try await store.saveAttempt(attempt, session: .shareUpload, job: job.lease.job, token: job.lease.token) else { throw LeaseLost() }
        try? uploader.acknowledge(attemptKey, keepingBody: false)
        if receipt.status == "duplicate" {
            if sidecar != nil { throw TransferItemFailure.sidecarDuplicate }
            if part == .original, let motionID = fields["livePhotoVideoId"] { try await pair(receipt.id, with: motionID, context: run.context) }
        }
        return receipt.id
    }

    /// Pairs a still the server already held with its video, asking the server. A still paired with
    /// another video fails the file and is left as it is.
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
}

/// The engine's one executor once both lanes run on it (B9): library jobs go to the library
/// executor, shared files to the share executor.
struct LaneJobExecutor: JobExecuting {
    let library: any JobExecuting
    let share: any JobExecuting

    func execute(_ job: LeasedJob, context: JobContext) async throws -> JobResult {
        try await (job.lane == .library ? library : share).execute(job, context: context)
    }

    func committed(_ job: LeasedJob, result: JobResult) async {
        await (job.lane == .library ? library : share).committed(job, result: result)
    }
}

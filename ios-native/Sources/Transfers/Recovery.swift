import Foundation
import IlyichPlatform
import IlyichShareInbox
import os

/// Puts the transfers database back in step with what iOS and the disk hold after the app ended,
/// for one account (B6, dormant until B9): nothing in the app creates it, and backup still runs
/// through BackupCoordinator and state.json. It runs only on a database the transfer engine owns,
/// never on the shadow copy B1 rebuilds, and it leaves every job a lease holds to the engine. It
/// needs neither the server nor the network, so a launch in the background can run it at once.
///
/// For each library job with a stage, in queue order, each unanswered attempt (oldest first, so a
/// Live Photo's video before its still):
/// - R1, an outcome file nobody applied. A receipt for the still or video commits the photo, with
///   the checksum kept with the stage, else the attempt's, else hashed once from the staged file;
///   a Live Photo's video records its server ID and the job goes on to the still. A duplicate with
///   an XMP sidecar fails the photo, as the executor does, and one that needs pairing with its
///   video stays on disk for the executor, which applies it without a check or an upload. A
///   status is classified (TransferFailureClassifier, never the message): an item failure fails
///   the photo, a transient one retries now, an account one (a replayed 401) is reported and
///   blames no photo. An answer without a status is no answer: the attempt is interrupted.
/// - R2, a task iOS still holds for the attempt, from this build or an earlier one (a legacy task
///   by its stage ID): the attempt is bound to it and the job waits for its outcome, never sent
///   again. Live tasks of the account that no unanswered attempt owns are cancelled. A legacy share
///   task is kept while its batch's manifest still lists files, and cancelled once it doesn't.
/// - R3, an interrupted attempt with nothing on iOS's side: its body, if it was written to its end
///   (closing boundary, recorded size), is kept for the executor, which checks again by the
///   persisted checksum (a duplicate completes; a sidecar still needs its own created outcome)
///   and otherwise sends that body again under the same ID. A body cut short is removed and the
///   attempt abandoned, so a new one is written.
/// - R4, a job the transport had resumes from its stage; one whose staged files are gone (swept,
///   signed out, purged) returns to pending and stages again.
/// - R5, StagingArea.sweep, keeping every stage, unanswered attempt and task of iOS's.
/// - R6, a report.
struct Recovery: Sendable {
    enum ReconcileError: Error, Equatable {
        /// The database is still BackupCoordinator's shadow copy.
        case notOwned
    }

    let staging: StagingArea
    private let store: TransferStore
    private let layout: AppGroupLayout
    private let backup: any TransferTransport
    private let share: (any TransferTransport)?
    private let shares: any ShareTaskListing
    /// The account digest, which names every task's scope.
    private let scope: String
    private let hashFile: @Sendable (URL) async throws -> String
    private let now: @Sendable () -> Date
    private static let logger = Logger(subsystem: "app.ilyich.native", category: "Transfers")
    private static let withTransport: Set<JobState> = [.submitting, .submitted, .finalizing]

    init(store: TransferStore, account: AccountID, layout: AppGroupLayout, backup: any TransferTransport, share: (any TransferTransport)? = nil,
         shares: (any ShareTaskListing)? = nil,
         checksum: @escaping @Sendable (URL) async throws -> String = { url in try await UploadBody.work { try UploadBody.checksum(url) } },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.layout = layout
        self.backup = backup
        self.share = share
        self.shares = shares ?? ManifestShareTaskListing(layout: layout)
        hashFile = checksum
        self.now = now
        scope = account.digest
        staging = StagingArea(layout: layout, account: account)
    }

    /// Reconciles once. Running it again changes nothing more, except for what has happened since.
    func reconcile() async throws -> RecoveryReport {
        guard try await store.meta().engine == .transfer else { throw ReconcileError.notOwned }
        var report = RecoveryReport()
        let inventory = await backup.inventory()
        for entry in try await store.recoveryJobs() where !entry.leased {
            try Task.checkCancellation()
            try await recover(entry, inventory: inventory, report: &report)
        }

        // R2: tasks nobody waits for. Read after the jobs, so an attempt the engine made meanwhile
        // counts too.
        var references = try await store.stagingReferences()
        let orphans = inventory.tasks(scope: scope).filter { task in
            task.isLive && !(task.attempt.map { references.attempts.contains($0.rawValue) } ?? false)
        }.map(\.taskID)
        if !orphans.isEmpty {
            await backup.cancel(tasks: orphans)
            report.cancelled = orphans.count
        }
        for task in inventory.tasks(scope: scope) where !orphans.contains(task.taskID) {
            if let attempt = task.attempt { references.attempts.insert(attempt.rawValue) }
            if let folder = task.descriptor.outcomePath.flatMap(Self.folder(of:)) { references.folders.insert(folder) }
        }
        if let share { await reconcileShares(share, report: &report) }

        // R5.
        let imported = try await store.meta().legacyImportMode == .authoritative
        report.sweep = staging.sweep(keeping: references, legacyImported: imported, now: now())
        Self.logger.notice("\(report.summary, privacy: .public)")
        return report
    }

    // MARK: Jobs

    private enum Applied {
        /// The job is done: committed or failed.
        case finished
        /// Recorded; the job goes on.
        case applied
        /// No answer from the server: the attempt is checked again.
        case interrupted
        /// Left on disk for the executor.
        case deferred
        /// A lease holds the job now, or the database refused: left alone.
        case skipped
    }

    private func recover(_ entry: RecoveryJob, inventory: TransportInventory, report: inout RecoveryReport) async throws {
        let job = entry.job
        let date = now()
        guard var stage = entry.stage else {
            // Nothing staged: the executor stages it from the start.
            if Self.withTransport.contains(job.state), try await store.recover(job: job.id, attempt: nil, change: .state(.staged, phase: nil), at: date) {
                report.resumed += 1
            }
            return
        }
        var withIOS = false, deferred = false, stateWritten = false
        var kept: Set<AttemptPart> = []
        for attempt in entry.attempts where attempt.isUnanswered {
            let key = AttemptKey(attempt: attempt.id, scope: scope, folder: stage.folder)
            var acknowledging = false
            if key.isValid {
                let record: OutcomeRecord?
                do { record = try backup.outcome(for: key) }
                catch is DecodingError {
                    // A file that says nothing: no answer, and it must go before the body is sent again.
                    record = nil
                    acknowledging = true
                } catch {
                    // Not readable now (before the first unlock, or the App Group is gone): next time.
                    Self.logger.error("Recovery left a job: its outcome could not be read: \(error.localizedDescription, privacy: .public)")
                    return
                }
                if let record {
                    switch try await apply(record, attempt: attempt, key: key, stage: &stage, job: job, report: &report) {
                    case .finished, .skipped: return
                    case .applied: stateWritten = true; continue
                    case .deferred: deferred = true; stateWritten = true; continue
                    case .interrupted: acknowledging = true
                    }
                }
            }

            // R2: iOS still has the attempt's task.
            if !acknowledging, let task = inventory.task(for: attempt.id) ?? inventory.tasks(for: attempt.id).first {
                var bound = attempt
                bound.state = .submitted
                bound.taskID = Int64(task.taskID)
                guard try await store.recover(job: job.id, attempt: bound, change: .state(.submitted, phase: nil), at: date) else { return }
                if task.isLive { report.bound += 1 } else { report.pending += 1 }
                withIOS = true
                stateWritten = true
                continue
            }

            // R3: interrupted, with nothing on iOS's side.
            let body = layout.url(forRelativePath: key.bodyPath)
            var resumed = attempt
            if attempt.state != .created, key.isValid {
                switch UploadBody.isComplete(body, boundary: LibraryJobExecutor.boundary(attempt.id), bytes: attempt.bodyBytes) {
                case true?: resumed.state = .interrupted
                case false?: resumed.state = .abandoned
                case nil: return
                }
            } else {
                resumed.state = .abandoned
            }
            let change: RecoveredJobChange = Self.withTransport.contains(job.state) ? .state(.staged, phase: nil) : .keep
            guard try await store.recover(job: job.id, attempt: resumed, change: change, at: date) else { return }
            if acknowledging { try? backup.acknowledge(key, keepingBody: resumed.state == .interrupted) }
            if resumed.state == .interrupted {
                kept.insert(attempt.part)
                report.resumable += 1
            } else {
                if key.isValid { try? FileManager.default.removeItem(at: body) }
                report.rebuilt += 1
            }
            if change != .keep { stateWritten = true }
        }
        // The transport has the job's upload: its outcome is applied when it lands.
        if withIOS { return }

        // R4.
        if !stateWritten, Self.withTransport.contains(job.state) {
            guard try await store.recover(job: job.id, attempt: nil, change: .state(.staged, phase: nil), at: date) else { return }
            report.resumed += 1
        }
        guard !deferred, job.state != .failed, needsStaging(stage, kept: kept) else { return }
        guard try await store.recover(job: job.id, attempt: nil, change: .pending, at: date) else { return }
        removeStageFolder(stage.folder)
        report.requeued += 1
    }

    /// R1 for one outcome file.
    private func apply(_ record: OutcomeRecord, attempt: LibraryAttempt, key: AttemptKey, stage: inout LibraryStage, job: StoredJob,
                       report: inout RecoveryReport) async throws -> Applied {
        let date = now()
        let runnable: RecoveredJobChange = Self.withTransport.contains(job.state) ? .state(.staged, phase: nil) : .keep
        if let receipt = record.receipt {
            var answered = attempt
            answered.state = .completed
            answered.remoteID = receipt.id
            answered.remoteStatus = receipt.status
            if attempt.part == .motion {
                guard try await store.recover(job: job.id, attempt: answered, motion: (stage.stageID, receipt.id),
                                              change: .state(.staged, phase: LibraryJobExecutor.Phase.motionUploaded), at: date) else { return .skipped }
                stage.motionRemoteID = receipt.id
                try? backup.acknowledge(key, keepingBody: false)
                report.applied += 1
                return .applied
            }
            if receipt.status == "duplicate", stage.sidecar != nil {
                // Someone else's copy: the sidecar did not go with it.
                guard try await store.recover(job: job.id, attempt: answered, change: .failed(TransferItemFailure.sidecarDuplicate.localizedDescription),
                                              at: date) else { return .skipped }
                try? backup.acknowledge(key, keepingBody: false)
                report.failed += 1
                return .finished
            }
            if receipt.status == "duplicate", stage.motionRemoteID != nil {
                // Pairing the still with its video asks the server; the executor does that.
                guard try await store.recover(job: job.id, attempt: nil, change: runnable, at: date) else { return .skipped }
                report.deferred += 1
                return .deferred
            }
            let originalChecksum = await checksum(of: stage, attempt: attempt)
            var transferReceipt: TransferReceipt?
            if let originalChecksum {
                let original = RemoteCopy(id: receipt.id, checksum: originalChecksum)
                if stage.motion == nil {
                    transferReceipt = TransferReceipt(localID: job.source.key, revision: stage.revision, original: original, motion: nil, confirmedAt: nil)
                } else if let motionID = stage.motionRemoteID, let motionChecksum = stage.motionChecksum {
                    transferReceipt = TransferReceipt(localID: job.source.key, revision: stage.revision, original: original,
                                                      motion: RemoteCopy(id: motionID, checksum: motionChecksum), confirmedAt: nil)
                }
            }
            // Without a checksum the photo is backed up, but never a cleanup candidate.
            guard try await store.complete(TransferCompletion(job: job.id, lease: nil, localID: job.source.key, revision: stage.revision,
                                                              assetID: receipt.id, receipt: transferReceipt, confirmedAt: date)) else { return .skipped }
            try? backup.acknowledge(key, keepingBody: false)
            removeStageFolder(stage.folder)
            report.committed += 1
            return .finished
        }
        // No status: the server never answered (a lost connection, a force quit).
        guard record.httpStatus != nil else { return .interrupted }

        var failed = attempt
        failed.state = .failed
        let verdict = TransferFailureClassifier.classify(outcome: record, context: .init(retryCount: job.retryCount)) ?? .transient(retryAfter: nil)
        let change: RecoveredJobChange
        switch verdict {
        case .item(let message):
            change = .failed(message)
            report.failed += 1
        case .waiting(let reason, jobScoped: true):
            change = .waiting(reason)
            report.retrying += 1
        case .transient, .waiting:
            change = .retry(notBefore: date, message: UploadOutcomeFailure.failed(record).localizedDescription)
            report.retrying += 1
        case .account(let restriction):
            // The account's, not the photo's: the job stays as it was, and the engine meets the
            // block itself if it still holds.
            change = runnable
            report.restriction = restriction
        }
        guard try await store.recover(job: job.id, attempt: failed, failure: record, change: change, at: date) else { return .skipped }
        try? backup.acknowledge(key, keepingBody: false)
        if case .failed = change { return .finished }
        return .applied
    }

    /// The still or video's checksum: kept with the stage, else with the attempt, else hashed once
    /// from the staged file; nil when the file is gone.
    private func checksum(of stage: LibraryStage, attempt: LibraryAttempt) async -> String? {
        if let kept = stage.originalChecksum ?? attempt.checksum { return kept }
        return try? await hashFile(url(of: stage.original))
    }

    /// Whether the files the job sends next are gone, so it has to stage again. A part whose body
    /// is kept, with its checksum, needs no file.
    private func needsStaging(_ stage: LibraryStage, kept: Set<AttemptPart>) -> Bool {
        func missing(_ file: StagedFile?) -> Bool {
            guard let file else { return false }
            return !FileManager.default.fileExists(atPath: url(of: file).path)
        }
        if stage.motion != nil, stage.motionRemoteID == nil, !(kept.contains(.motion) && stage.motionChecksum != nil), missing(stage.motion) {
            return true
        }
        if kept.contains(.original), stage.originalChecksum != nil { return false }
        return missing(stage.original) || missing(stage.sidecar)
    }

    // MARK: Shares

    /// Legacy share tasks name no account: one is kept while its batch still has files to send,
    /// and cancelled once the batch is gone. Version 2 share tasks are B4's.
    private func reconcileShares(_ share: any TransferTransport, report: inout RecoveryReport) async {
        var stale: [Int] = []
        for task in await share.inventory().tasks where task.isLive {
            guard case .legacy(let identity, _) = task.descriptor, let path = task.descriptor.outcomePath else { continue }
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "ShareInbox", let batch = UUID(uuidString: String(parts[1])) else { continue }
            if shares.lists(batch: batch, identity: identity) { report.adoptedShares += 1 } else { stale.append(task.taskID) }
        }
        guard !stale.isEmpty else { return }
        await share.cancel(tasks: stale)
        report.cancelledShares = stale.count
    }

    // MARK: Files

    /// The file a staged path names: relative to the App Group, or a legacy absolute URL.
    private func url(of file: StagedFile) -> URL {
        if file.path.contains("://"), let url = URL(string: file.path) { return url }
        return layout.url(forRelativePath: file.path)
    }

    /// Removes a stage folder of this account's, and nothing else.
    private func removeStageFolder(_ folder: String) {
        let prefix = staging.folder + "/"
        guard folder.hasPrefix(prefix), UUID(uuidString: String(folder.dropFirst(prefix.count))) != nil else { return }
        try? FileManager.default.removeItem(at: layout.url(forRelativePath: folder))
    }

    private static func folder(of path: String) -> String? {
        path.lastIndex(of: "/").map { String(path[..<$0]) }
    }
}

/// What a reconcile did (R6).
struct RecoveryReport: Hashable, Sendable {
    /// Photos committed from an outcome on disk.
    var committed = 0
    /// Live Photo videos whose answer was applied; their stills go next.
    var applied = 0
    /// Answers left on disk for the executor, which needs the server to pair them.
    var deferred = 0
    /// Photos an answer failed.
    var failed = 0
    /// Jobs a failed answer sends again by themselves.
    var retrying = 0
    /// What a replayed answer said about the account, such as an expired session. No photo is blamed.
    var restriction: AccountRestriction?
    /// Attempts bound to a live task of iOS's, and to one that ended without an outcome yet.
    var bound = 0
    var pending = 0
    /// Live tasks of the account no attempt waits for, cancelled.
    var cancelled = 0
    /// Legacy share tasks kept, and cancelled.
    var adoptedShares = 0
    var cancelledShares = 0
    /// Interrupted attempts whose body is kept, to be checked and sent again.
    var resumable = 0
    /// Attempts whose body was missing or cut short: a new one is written.
    var rebuilt = 0
    /// Jobs the transport had that resume from their stage.
    var resumed = 0
    /// Jobs whose staged files are gone, staged again.
    var requeued = 0
    var sweep = StagingArea.Sweep()

    var summary: String {
        var parts = ["committed \(committed)", "applied \(applied)", "deferred \(deferred)", "failed \(failed)", "retrying \(retrying)",
                     "bound \(bound)", "pending \(pending)", "cancelled \(cancelled)", "shares \(adoptedShares)/-\(cancelledShares)",
                     "resumable \(resumable)", "rebuilt \(rebuilt)", "resumed \(resumed)", "requeued \(requeued)",
                     "swept \(sweep.folders) folders \(sweep.files) files \(sweep.bytes) bytes"]
        if let skipped = sweep.skipped { parts.append("sweep skipped: \(skipped)") }
        if let restriction { parts.append("account: \(restriction.storedValue)") }
        return "Transfer recovery: " + parts.joined(separator: ", ")
    }
}

/// Whether a share batch still has a file a legacy share task may be sending.
protocol ShareTaskListing: Sendable {
    func lists(batch: UUID, identity: String) -> Bool
}

/// Reads the batch's manifest. A legacy task's identity is a hash of the account, the file's path
/// and its checksums, so it can't be matched to one attachment without hashing every file; B4's
/// deterministic identity can. Until then a task is kept while its batch lists any file, and when
/// the manifest can't be read now. Only a batch that is gone, or lists nothing, cancels it.
struct ManifestShareTaskListing: ShareTaskListing {
    let layout: AppGroupLayout

    func lists(batch: UUID, identity: String) -> Bool {
        let folder = layout.url(forRelativePath: "ShareInbox/" + batch.uuidString)
        let manifest = folder.appendingPathComponent(ShareManifest.fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifest.path) else { return false }
        guard let data = try? Data(contentsOf: manifest), data.count <= ShareManifest.maximumSize,
              let decoded = try? ShareManifest.decode(data, batch: batch, folder: folder) else { return true }
        return !decoded.attachments.isEmpty
    }
}

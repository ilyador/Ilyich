import CryptoKit
import Foundation
import IlyichPlatform
import OSLog

/// Brings today's backup state, <AppGroup>/Backup/<digest>/state.json, into the account's transfers
/// database (invariants BM1 to BM4 and BM8). It runs on the database's own queue, so reading,
/// hashing and decoding the file never reach the main thread.
///
/// Shadow mode, until the cutover (B9): BackupCoordinator stays authoritative and the database is a
/// copy. When the file's digest differs from the one last imported, the library lane is rebuilt
/// from it in one transaction; then the copy is compared with the file. state.json is only ever
/// read: never written, renamed or moved, even when it can't be decoded, and staged files and
/// background tasks are never looked at. A database the transfer engine owns is left alone.
///
/// Authoritative mode, from B9: the first import hands the database to the transfer engine; the
/// same digest again is a no-op; a later digest, which only a reinstalled older build can write,
/// is reported for B9's merge and changes nothing; an unreadable file is moved aside, never fatal.
///
/// The app runs it when the account's runtime opens in front, whenever the app comes forward, and
/// from Diagnostics, never on a write of state.json: BackupCoordinator writes it several times per
/// photo.
actor LegacyBackupImporter {
    enum Mode: String, Codable, Sendable {
        case shadow, authoritative
    }

    /// The file this importer reads, in the account's Backup folder.
    static let fileName = "state.json"
    /// The digest recorded when there is no state.json, which a backup that never ran leaves.
    static let absentDigest = "absent"

    nonisolated let mode: Mode
    nonisolated let store: TransferStore
    /// The account's Backup folder in the App Group; nil when the App Group can't be found.
    nonisolated let folder: URL?
    private let now: @Sendable () -> Date
    private let crash: LegacyImportCrashPoint?
    nonisolated var unownedExecutor: UnownedSerialExecutor { store.unownedExecutor }

    init(mode: Mode, store: TransferStore, folder: URL?, now: @escaping @Sendable () -> Date = { Date() },
         crashingAt crash: LegacyImportCrashPoint? = nil) {
        self.mode = mode
        self.store = store
        self.folder = folder
        self.now = now
        self.crash = crash
    }

    /// Imports state.json if it changed, compares the database with it, and reports how that went,
    /// in the console too. An unchanged file reuses the comparison made when it was imported,
    /// unless `comparing` asks for a new one. Nil when cancelled, as at sign-out, which leaves the
    /// database as it was.
    func run(comparing: Bool = false) async -> LegacyImportReport? {
        let started = ContinuousClock.now
        let outcome: LegacyImportReport.Outcome
        let comparison: LegacyImportComparison?
        do {
            (outcome, comparison) = try await perform(comparing: comparing)
        } catch is CancellationError {
            return nil
        } catch is SimulatedCrash {
            // A test's crash: the app would have ended here.
            return nil
        } catch {
            Self.log.error("Backup state import couldn't use the transfers database: \(String(describing: error), privacy: .private)")
            (outcome, comparison) = (.unavailable, nil)
        }
        let elapsed = started.duration(to: .now)
        let milliseconds = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let report = LegacyImportReport(mode: mode, outcome: outcome, date: now(), milliseconds: milliseconds, comparison: comparison)
        Self.log.notice("\(report.summary, privacy: .public)")
        return report
    }

    private func perform(comparing: Bool) async throws -> (LegacyImportReport.Outcome, LegacyImportComparison?) {
        guard let folder else { return (.unavailable, nil) }
        let file = folder.appendingPathComponent(Self.fileName, isDirectory: false)
        let data: Data?
        do { data = try Self.read(file) } catch {
            // Not unreadable: the phone may still be locked, or the folder unavailable. Next time.
            Self.log.error("Backup state couldn't be read now: \(String(describing: error), privacy: .private)")
            return (.unavailable, nil)
        }
        try Task.checkCancellation()
        let digest = data.map(Self.digest) ?? Self.absentDigest
        let meta = try await store.meta()
        // A database written by a later build, or one the transfer engine owns, is not a copy.
        guard meta.schema <= TransferStore.schemaVersion else { return (.skipped, nil) }
        if mode == .shadow, meta.engine == .transfer { return (.skipped, nil) }
        let current = meta.legacyImportDigest == digest && (mode == .shadow || meta.engine == .transfer)
        if current, !comparing, meta.legacyReportDigest == digest,
           let stored = meta.legacyReport.flatMap({ TransferJSON.decode(LegacyImportComparison.self, $0) }) {
            return (data == nil ? .absent : .unchanged, stored)
        }
        if !current, mode == .authoritative, meta.engine == .transfer { return (.needsMerge, nil) }

        let state: Legacy.BackupState
        if let data {
            do { state = try Legacy.decoder().decode(Legacy.BackupState.self, from: data) } catch {
                Self.log.error("Backup state can't be decoded: \(String(describing: error), privacy: .private)")
                guard mode == .authoritative else { return (.unreadable, nil) }
                // Only the file that failed: one replaced since is read next time.
                guard (try? Self.read(file)).map(Self.digest) == digest else { return (.unavailable, nil) }
                return (quarantine(file) ? .quarantined : .unreadable, nil)
            }
        } else {
            state = Legacy.BackupState()
        }
        try Task.checkCancellation()
        if !current {
            try await store.replace(with: LegacyBackupPlan(state), digest: digest, mode: mode, at: now(), crashingAt: crash)
        }
        let contents = try await store.contents()
        try Task.checkCancellation()
        let comparison = LegacyBackupComparison.compare(state, with: contents)
        try await store.saveLegacyReport(TransferJSON.encode(comparison), digest: digest)
        if data == nil { return (.absent, comparison) }
        return (current ? .unchanged : .imported, comparison)
    }

    /// Moves an unreadable state.json aside, beside it, so it is never read again and stays for
    /// inspection. Says whether it moved.
    private func quarantine(_ file: URL) -> Bool {
        let stamp = Int64(now().timeIntervalSince1970)
        var target = file.deletingLastPathComponent().appendingPathComponent("\(Self.fileName).unreadable-\(stamp)", isDirectory: false)
        if FileManager.default.fileExists(atPath: target.path) {
            target = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + "-" + UUID().uuidString, isDirectory: false)
        }
        do {
            try FileManager.default.moveItem(at: file, to: target)
            return true
        } catch {
            Self.log.error("Unreadable backup state couldn't be moved aside: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// The file's bytes, or nil when there is none. The writer replaces it atomically, so this reads
    /// either the old file or the new one, whole.
    static func read(_ file: URL) throws -> Data? {
        do {
            return try Data(contentsOf: file, options: .mappedIfSafe)
        } catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) {
            return nil
        }
    }

    /// The SHA-256 of the file's bytes, in lowercase hex.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let log = Logger(subsystem: "app.ilyich.native", category: "transfers")
}

// MARK: - Plan

/// What state.json says, laid out as the transfers database keeps it. Built from the decoded file
/// alone, without touching a file or the database, so the comparison can rebuild it.
///
/// - Jobs: the photo being uploaded first, then the queue in its order (BM3), each once. Then,
///   sorted, photos the legacy loop could no longer reach, so nothing state.json holds is lost: a
///   suspended stage or a failure whose photo left the queue, and an album add whose photo was
///   never uploaded, which becomes an album upload.
/// - A job's state: staged for the photo being uploaded and for a suspended stage, failed for a
///   photo with a recorded failure, which legacy builds recorded only for item failures, else
///   queued. Its error fields keep that failure.
/// - Stages: the current one and the suspended ones, files relative to the App Group (BM4). Each
///   stage's ID becomes the ID of an interrupted attempt at the part it was uploading: recovery
///   adopts its task or applies its outcome file by that ID (BM5, BM6).
/// - Album adds: one destination per photo and album, pending. Its server ID is the receipt's for
///   a photo with no job, so it can run at once; a photo with a job fills it in when it commits.
///   In state.json such an add was stranded until the photo went through the queue again.
/// - The run intent: paused stays paused; a running backup is automatic when automatic backup is
///   on, else manual (the critic's correction for B9). The last error becomes the last message,
///   never an account blocker.
/// - The notification batch, started and not yet ended: the queue's jobs count towards it while
///   it runs; once it ended, its final notification waits to be posted.
struct LegacyBackupPlan: Sendable {
    struct Job: Sendable {
        let localID: String
        let origin: JobOrigin
        let state: JobState
        let failure: Legacy.BackupFailure?
        /// The running notification batch it counts towards.
        let batch: UUID?
    }

    struct Stage: Sendable {
        let localID: String
        let stageID: String
        /// The stage's folder, relative to the App Group.
        let folder: String
        let modificationDate: Date
        let original: StagedFile
        let motion: StagedFile?
        let sidecar: StagedFile?
        let fields: [String: String]
        let isVideo: Bool
        /// The Live Photo video's server ID, once it uploaded.
        let motionRemoteID: String?
        let motionChecksum: String?
        let suspended: Bool
        /// The part the stage ID's attempt uploads.
        let part: AttemptPart
        /// The attempt's multipart body, which may or may not exist.
        let bodyPath: String?

        init(_ photo: Legacy.PreparedPhoto, localID: String, suspended: Bool) {
            self.localID = localID
            stageID = photo.stageID
            folder = Self.folder(of: photo)
            modificationDate = photo.modificationDate
            original = StagedFile(photo.original)
            motion = photo.motion.map(StagedFile.init)
            sidecar = photo.sidecar.map(StagedFile.init)
            fields = photo.fields
            isVideo = photo.isVideo
            motionRemoteID = photo.livePhotoID
            motionChecksum = photo.motionChecksum
            self.suspended = suspended
            part = Self.part(of: photo)
            bodyPath = AppGroupLayout.relativePath(of: photo.original.url.deletingLastPathComponent()).map { "\($0)/\(photo.stageID).multipart" }
        }

        /// The folder of a stage's files, relative to the App Group, or its recorded URL when it
        /// lies outside the Backup folder.
        static func folder(of photo: Legacy.PreparedPhoto) -> String {
            let folder = photo.original.url.deletingLastPathComponent()
            return AppGroupLayout.relativePath(of: folder) ?? folder.absoluteString
        }

        /// A Live Photo's video uploads first, under the stage's first ID; the still follows under
        /// a new one once the video's server ID is known.
        static func part(of photo: Legacy.PreparedPhoto) -> AttemptPart {
            photo.motion != nil && photo.livePhotoID == nil ? .motion : .original
        }
    }

    struct Destination: Hashable, Sendable {
        let localID: String
        let albumID: String
        let remoteID: String?
    }

    let preferences: TransferPreferences
    let intent: RunIntent
    let lastMessage: String?
    let jobs: [Job]
    let stages: [Stage]
    let confirmations: [(String, Date)]
    let receipts: [(String, Legacy.BackupReceipt)]
    let destinations: [Destination]
    let linkedAlbums: [(String, String)]
    let batch: Legacy.TransferNotification?

    init(_ state: Legacy.BackupState) {
        let legacyPreferences = state.preferences ?? Legacy.BackupPreferences()
        preferences = TransferPreferences(legacyPreferences)
        intent = Self.intent(state)
        lastMessage = state.error
        jobs = Self.jobs(state)
        var stages: [Stage] = []
        if let current = state.current { stages.append(Stage(current, localID: current.localID, suspended: false)) }
        for (localID, photo) in (state.suspended ?? [:]).sorted(by: { $0.key < $1.key }) {
            stages.append(Stage(photo, localID: localID, suspended: true))
        }
        self.stages = stages
        confirmations = (state.confirmed ?? [:]).sorted { $0.key < $1.key }
        receipts = (state.receipts ?? [:]).sorted { $0.key < $1.key }
        destinations = Self.destinations(state, jobs: Set(jobs.map(\.localID)))
        linkedAlbums = (state.linkedAlbums ?? [:]).sorted { $0.key < $1.key }
        batch = state.transferNotification
    }

    static func intent(_ state: Legacy.BackupState) -> RunIntent {
        // BackupState() starts paused, and a file without the key was never read by the app.
        guard state.paused == false else { return .paused }
        return (state.preferences?.automatic ?? false) ? .automatic : .manual
    }

    static func jobs(_ state: Legacy.BackupState) -> [Job] {
        let current = state.current?.localID
        let failures = state.failures ?? [:]
        let suspended = state.suspended ?? [:]
        let receipts = state.receipts ?? [:]
        let running = state.transferNotification.flatMap { $0.terminalFailures == nil ? $0.id : nil }
        var seen = Set<String>()
        var order: [(id: String, origin: JobOrigin, queued: Bool)] = []
        func add(_ id: String, _ origin: JobOrigin, queued: Bool) {
            if seen.insert(id).inserted { order.append((id, origin, queued)) }
        }
        if let current { add(current, .legacy, queued: true) }
        for id in state.queue ?? [] { add(id, .legacy, queued: true) }
        for id in suspended.keys.sorted() { add(id, .legacy, queued: false) }
        for id in failures.keys.sorted() { add(id, .legacy, queued: false) }
        for (id, albums) in (state.pendingAlbumAdds ?? [:]).sorted(by: { $0.key < $1.key }) where !albums.isEmpty && receipts[id] == nil {
            add(id, .albumUpload, queued: false)
        }
        return order.map { id, origin, queued in
            let jobState: JobState = if id == current { .staged }
                else if failures[id] != nil { .failed }
                else if suspended[id] != nil { .staged }
                else { .queued }
            return Job(localID: id, origin: origin, state: jobState, failure: failures[id], batch: queued ? running : nil)
        }
    }

    static func destinations(_ state: Legacy.BackupState, jobs: Set<String>) -> [Destination] {
        let receipts = state.receipts ?? [:]
        return (state.pendingAlbumAdds ?? [:]).sorted { $0.key < $1.key }.flatMap { localID, albums in
            albums.sorted().map { album in
                Destination(localID: localID, albumID: album, remoteID: jobs.contains(localID) ? nil : receipts[localID]?.original.id)
            }
        }
    }
}

extension StagedFile {
    /// A legacy file, by its path relative to the App Group.
    init(_ file: Legacy.UploadFile) {
        self.init(path: AppGroupLayout.relativePath(of: file.url) ?? file.url.absoluteString, filename: file.filename, contentType: file.contentType)
    }
}

// MARK: - Comparison

/// The facts a comparison checks, as Diagnostics lists them.
enum LegacyImportCategory: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case receipts, confirmations, queueOrder, stages, failures, albumAdds, linkedAlbums, preferences, runIntent, notificationBatch

    var title: String {
        switch self {
        case .receipts: "Receipts"
        case .confirmations: "Confirmations"
        case .queueOrder: "Queue order"
        case .stages: "Current and suspended stages"
        case .failures: "Failures"
        case .albumAdds: "Album adds"
        case .linkedAlbums: "Linked albums"
        case .preferences: "Preferences"
        case .runIntent: "Run intent"
        case .notificationBatch: "Notification batch"
        }
    }
}

/// How the database matches state.json, by category. Counts only: no identifiers, paths or text.
struct LegacyImportComparison: Codable, Equatable, Sendable {
    /// What state.json holds in each category.
    var compared: [LegacyImportCategory: Int] = [:]
    /// What the database doesn't hold exactly, dates bit for bit, plus what it holds that
    /// state.json doesn't.
    var mismatches: [LegacyImportCategory: Int] = [:]

    var total: Int { mismatches.values.reduce(0, +) }
}

/// Compares the database's contents with state.json, fact by fact.
enum LegacyBackupComparison {
    static func compare(_ state: Legacy.BackupState, with contents: TransferStoreContents) -> LegacyImportComparison {
        var result = LegacyImportComparison()
        func record(_ category: LegacyImportCategory, _ compared: Int, _ mismatches: Int) {
            result.compared[category] = compared
            result.mismatches[category] = mismatches
        }
        let plan = LegacyBackupPlan(state)

        // Receipts and confirmations, one row each (BM3), dates bit for bit (BM2).
        let receipts = state.receipts ?? [:]
        var storedReceipts: [String: TransferReceiptRow] = [:]
        var receiptMismatches = 0
        for row in contents.receipts where storedReceipts.updateValue(row, forKey: row.localID) != nil { receiptMismatches += 1 }
        for (localID, receipt) in receipts {
            guard let row = storedReceipts.removeValue(forKey: localID), matches(row, receipt) else { receiptMismatches += 1; continue }
        }
        record(.receipts, receipts.count, receiptMismatches + storedReceipts.count)

        let confirmed = state.confirmed ?? [:]
        var storedConfirmations: [String: TransferConfirmationRow] = [:]
        var confirmationMismatches = 0
        for row in contents.confirmations where storedConfirmations.updateValue(row, forKey: row.localID) != nil { confirmationMismatches += 1 }
        for (localID, date) in confirmed {
            guard let row = storedConfirmations.removeValue(forKey: localID), row.modificationDate?.bitPattern == bits(date),
                  row.confirmedAt == nil else { confirmationMismatches += 1; continue }
        }
        record(.confirmations, confirmed.count, confirmationMismatches + storedConfirmations.count)

        // The jobs, in order, with their origins and states.
        let expectedJobs = plan.jobs.map { [$0.localID, $0.origin.rawValue, $0.state.rawValue] }
        let storedJobs = contents.jobs.map { [$0.sourceKey, $0.origin, $0.state] }
        var queueMismatches = abs(expectedJobs.count - storedJobs.count)
        for (expected, stored) in zip(expectedJobs, storedJobs) where expected != stored { queueMismatches += 1 }
        record(.queueOrder, expectedJobs.count, queueMismatches)

        // The current and suspended stages, each with its attempt.
        let jobKeys = Dictionary(contents.jobs.map { ($0.id, $0.sourceKey) }, uniquingKeysWith: { first, _ in first })
        let attempts = Dictionary(contents.attempts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var storedStages = Dictionary(grouping: contents.stages, by: \.stageID)
        var expectedStages: [(localID: String, photo: Legacy.PreparedPhoto, suspended: Bool)] = []
        if let current = state.current { expectedStages.append((current.localID, current, false)) }
        for (localID, photo) in state.suspended ?? [:] { expectedStages.append((localID, photo, true)) }
        var stageMismatches = 0
        for expected in expectedStages {
            guard let rows = storedStages.removeValue(forKey: expected.photo.stageID), rows.count == 1, let row = rows.first,
                  jobKeys[row.jobID] == expected.localID, matches(row, expected.photo, suspended: expected.suspended),
                  let attempt = attempts[expected.photo.stageID], attempt.jobID == row.jobID,
                  attempt.part == LegacyBackupPlan.Stage.part(of: expected.photo).rawValue,
                  attempt.session == TransferSessionID.backup.rawValue, attempt.state == AttemptState.interrupted.rawValue
            else { stageMismatches += 1; continue }
        }
        record(.stages, expectedStages.count, stageMismatches + storedStages.values.reduce(0) { $0 + $1.count })

        // Failures, on their photos' jobs.
        let failures = state.failures ?? [:]
        var storedFailures: [String: TransferJobRow] = [:]
        for job in contents.jobs where job.errorClass != nil || job.errorMessage != nil || job.errorAt != nil || job.displayName != nil {
            storedFailures[job.sourceKey] = job
        }
        var failureMismatches = 0
        for (localID, failure) in failures {
            guard let job = storedFailures.removeValue(forKey: localID), job.errorClass == "item", job.errorMessage == failure.message,
                  job.errorAt?.bitPattern == bits(failure.date), job.displayName == failure.filename else { failureMismatches += 1; continue }
        }
        record(.failures, failures.count, failureMismatches + storedFailures.count)

        // Album adds: every photo and album, pending, with the server ID that lets it run.
        let jobIDs = Set(plan.jobs.map(\.localID))
        var storedDestinations: [String: AlbumDestinationRow] = [:]
        for row in contents.albumDestinations { storedDestinations[row.localID + "\u{0}" + row.albumID] = row }
        var albumMismatches = 0
        var albumAdds = 0
        for (localID, albums) in state.pendingAlbumAdds ?? [:] {
            for album in albums {
                albumAdds += 1
                let remote = jobIDs.contains(localID) ? nil : receipts[localID]?.original.id
                guard let row = storedDestinations.removeValue(forKey: localID + "\u{0}" + album), row.remoteID == remote,
                      row.state == "pending", row.attempts == 0, row.error == nil else { albumMismatches += 1; continue }
            }
        }
        record(.albumAdds, albumAdds, albumMismatches + storedDestinations.count)

        let links = state.linkedAlbums ?? [:]
        let linkKeys = Set(links.keys).union(contents.linkedAlbums.keys)
        record(.linkedAlbums, links.count, linkKeys.filter { links[$0] != contents.linkedAlbums[$0] }.count)

        record(.preferences, 1, contents.preferences == TransferPreferences(state.preferences ?? Legacy.BackupPreferences()) ? 0 : 1)

        let engine = contents.engine
        record(.runIntent, 1, engine?.intent == plan.intent && engine?.lastMessage == plan.lastMessage && engine?.blocker == nil ? 0 : 1)

        // The batch, and which jobs count towards it.
        let expectedBatches = Dictionary(plan.jobs.map { ($0.localID, $0.batch?.uuidString) }, uniquingKeysWith: { first, _ in first })
        let membership = contents.jobs.allSatisfy { (expectedBatches[$0.sourceKey] ?? nil) == $0.batchID }
        var batchMismatches = 0
        if let batch = state.transferNotification {
            let stored = contents.notificationBatches
            let matching = stored.count == 1 && stored[0] == NotificationBatchRow(
                id: batch.id.uuidString, kind: "backup", total: batch.total, completed: batch.completed, failed: batch.terminalFailures,
                startedPosted: true, terminalPosted: false)
            batchMismatches = (matching && membership ? 0 : 1) + max(0, stored.count - 1)
        } else {
            batchMismatches = contents.notificationBatches.count + (membership ? 0 : 1)
        }
        record(.notificationBatch, state.transferNotification == nil ? 0 : 1, batchMismatches)
        return result
    }

    private static func bits(_ date: Date) -> UInt64 { date.timeIntervalSinceReferenceDate.bitPattern }

    private static func matches(_ row: TransferReceiptRow, _ receipt: Legacy.BackupReceipt) -> Bool {
        row.modificationDate?.bitPattern == bits(receipt.modificationDate)
            && row.originalID == receipt.original.id && row.originalChecksum == receipt.original.checksum
            && row.originalBytes == receipt.original.byteCount
            && row.motionID == receipt.motion?.id && row.motionChecksum == receipt.motion?.checksum
            && row.motionBytes == receipt.motion?.byteCount
            && row.confirmedAt?.bitPattern == receipt.confirmedAt.map(bits)
            && row.verifiedAt == nil && row.localDeletedAt == nil
    }

    private static func matches(_ row: TransferStageRow, _ photo: Legacy.PreparedPhoto, suspended: Bool) -> Bool {
        row.folder == LegacyBackupPlan.Stage.folder(of: photo)
            && row.modificationDate?.bitPattern == bits(photo.modificationDate)
            && row.original == StagedFile(photo.original)
            && row.hasMotion == (photo.motion != nil) && row.motion == photo.motion.map(StagedFile.init)
            && row.hasSidecar == (photo.sidecar != nil) && row.sidecar == photo.sidecar.map(StagedFile.init)
            && row.fields == photo.fields && row.isVideo == photo.isVideo
            && row.motionRemoteID == photo.livePhotoID && row.motionChecksum == photo.motionChecksum
            && row.originalChecksum == nil && row.suspended == suspended
    }
}

// MARK: - Report

/// How an import went, for Diagnostics and the console. Counts only.
struct LegacyImportReport: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// state.json changed, and the database was rebuilt from it.
        case imported
        /// state.json is as last imported.
        case unchanged
        /// There is no state.json, as when backup never ran, and the database holds no backup state.
        case absent
        /// state.json can't be decoded. Shadow mode leaves it where it is.
        case unreadable
        /// An unreadable state.json was moved aside (authoritative mode).
        case quarantined
        /// state.json or the database couldn't be read now; the next run tries again.
        case unavailable
        /// The transfer engine owns the database and state.json changed since its import: B9 merges.
        case needsMerge
        /// The database belongs to the transfer engine or to a later build, so a copy isn't made.
        case skipped
    }

    let mode: LegacyBackupImporter.Mode
    let outcome: Outcome
    let date: Date
    let milliseconds: Int
    let comparison: LegacyImportComparison?

    /// One line for the console and the exported diagnostics.
    var summary: String {
        var line = "Backup state import (\(mode.rawValue)): \(outcome.rawValue) in \(milliseconds) ms"
        if let comparison {
            line += "; \(comparison.total) mismatches; "
            line += LegacyImportCategory.allCases.map { "\($0.rawValue) \(comparison.mismatches[$0] ?? 0)/\(comparison.compared[$0] ?? 0)" }
                .joined(separator: ", ")
        }
        return line
    }
}

import CryptoKit
import Foundation
import IlyichPlatform
import OSLog

/// Imports the state.json an older build kept an account's backup in,
/// <AppGroup>/Backup/<digest>/state.json, into the account's transfers database and hands the
/// database to the transfer engine: B9's authoritative import (invariants BM1 to BM4). B10 keeps it
/// for an account whose state.json no import read, one signed in last before B9 (the critic's
/// correction to B10: other accounts' files may never have been imported). Without it such an
/// account would come back with only the copy B1 made of its file, or nothing, and lose its
/// receipts and confirmations. It runs on the database's own queue, so reading, hashing and
/// decoding the file never reach the main thread.
///
/// AccountRuntime.prepareTransfers runs it once per runtime, before the engine starts, and only for
/// a database the engine doesn't own: one the engine owns is never imported into again, since no
/// older build will be reinstalled (the owner's confirmation, B10), so nothing merges. The import
/// is one transaction. An unreadable file is moved aside, never fatal, and the engine takes the
/// database as it is. state.json itself stays, and LegacyRetirement removes it once the engine has
/// started, its digest being the one recorded here.
actor LegacyBackupImporter {
    enum Outcome: String, Sendable {
        /// state.json was imported: the engine owns the database now.
        case imported
        /// There is no state.json: nothing to import.
        case absent
        /// state.json can't be decoded, and was moved aside.
        case quarantined
        /// state.json or the database couldn't be read or used now; the next start tries again.
        case unavailable
        /// The engine or a later build owns the database: nothing is imported into it.
        case skipped
    }

    /// The file this importer reads, in the account's Backup folder.
    static let fileName = LegacyRetirement.fileName

    nonisolated let store: TransferStore
    /// The account's Backup folder in the App Group; nil when the App Group can't be found.
    nonisolated let folder: URL?
    private let now: @Sendable () -> Date
    private let crash: LegacyImportCrashPoint?
    nonisolated var unownedExecutor: UnownedSerialExecutor { store.unownedExecutor }

    init(store: TransferStore, folder: URL?, now: @escaping @Sendable () -> Date = { Date() }, crashingAt crash: LegacyImportCrashPoint? = nil) {
        self.store = store
        self.folder = folder
        self.now = now
        self.crash = crash
    }

    /// Imports state.json if the engine doesn't own the database yet, and says how that went, in
    /// the console too. Nil when cancelled, as at sign-out, which leaves the database as it was.
    func run() async -> Outcome? {
        do {
            let outcome = try await perform()
            Self.log.notice("Backup records an older version left (state.json): \(outcome.rawValue, privacy: .public)")
            return outcome
        } catch is CancellationError {
            return nil
        } catch is SimulatedCrash {
            // A test's crash: the app would have ended here.
            return nil
        } catch {
            Self.log.error("Backup records an older version left couldn't be imported now: \(String(describing: error), privacy: .private)")
            return .unavailable
        }
    }

    private func perform() async throws -> Outcome {
        guard let folder else { return .unavailable }
        let file = folder.appendingPathComponent(Self.fileName, isDirectory: false)
        let data: Data?
        do { data = try Self.read(file) } catch {
            // Not unreadable: the phone may still be locked, or the folder unavailable. Next time.
            Self.log.error("Backup records an older version left couldn't be read now: \(String(describing: error), privacy: .private)")
            return .unavailable
        }
        try Task.checkCancellation()
        let meta = try await store.meta()
        // A database written by a later build, or one the engine owns, takes no import.
        guard meta.schema <= TransferStore.schemaVersion, meta.engine != .transfer else { return .skipped }
        guard let data else { return .absent }
        let digest = Self.digest(data)
        let state: Legacy.BackupState
        do { state = try Legacy.decoder().decode(Legacy.BackupState.self, from: data) } catch {
            Self.log.error("Backup records an older version left can't be decoded: \(String(describing: error), privacy: .private)")
            // Only the file that failed: one replaced since is read next time.
            guard (try? Self.read(file)).map(Self.digest) == digest, quarantine(file) else { return .unavailable }
            return .quarantined
        }
        try Task.checkCancellation()
        let plan = LegacyBackupPlan(state)
        try await store.importLegacy(plan, digest: digest, at: now(), crashingAt: crash)
        Self.log.notice("Imported \(plan.receipts.count) receipts, \(plan.confirmations.count) confirmations and \(plan.jobs.count) jobs an older version left")
        return .imported
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
            Self.log.error("Unreadable backup records couldn't be moved aside: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// The file's bytes, or nil when there is none. The writer replaced it atomically, so this
    /// reads either the old file or the new one, whole.
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

    private static let log = Logger(subsystem: "app.ilyich.native", category: "Transfers")
}

// MARK: - Plan

/// What state.json says, laid out as the transfers database keeps it. Built from the decoded file
/// alone, without touching a file or the database.
///
/// - Jobs: the photo being uploaded first, then the queue in its order (BM3), each once. Then,
///   sorted, photos the legacy loop could no longer reach, so nothing state.json holds is lost: a
///   suspended stage or a failure whose photo left the queue, and an album add whose photo was
///   never uploaded, which becomes an album upload.
/// - A job's state: staged for the photo being uploaded and for a suspended stage, failed for a
///   photo with a recorded failure, which legacy builds recorded only for item failures, else
///   queued. Its error fields keep that failure.
/// - Stages: the current one and the suspended ones, files relative to the App Group (BM4). Each
///   stage's ID becomes the ID of an interrupted attempt at the part it was uploading, which
///   recovery checks again by its checksum.
/// - Album adds: one destination per photo and album, pending. Its server ID is the receipt's for
///   a photo with no job, so it can run at once; a photo with a job fills it in when it commits.
///   In state.json such an add was stranded until the photo went through the queue again.
/// - The run intent: automatic whenever automatic backup is on, since the old backup was paused
///   between its runs; with it off, a running backup is manual and anything else paused. Signing
///   out switched automatic backup off and paused, so an account an older build signed out comes
///   back paused. The last error becomes the last message, never an account blocker.
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
        preferences = TransferPreferences(state.preferences ?? Legacy.BackupPreferences())
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

    /// The old backup marked itself paused at the end of every run, automatic or not, and started
    /// automatic backup again whenever it was on: paused was its idle state, and only the Pause
    /// button (or signing out) switched automatic backup off. So automatic backup on is the
    /// automatic intent, whether a run was under way or not; with it off, a run under way is a
    /// manual run, and anything else is paused.
    static func intent(_ state: Legacy.BackupState) -> RunIntent {
        if state.preferences?.automatic == true { return .automatic }
        // BackupState() starts paused, and a file without the key was never read by the app.
        return state.paused == false ? .manual : .paused
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
    /// A file state.json recorded, by its path relative to the App Group.
    init(_ file: Legacy.UploadFile) {
        self.init(path: AppGroupLayout.relativePath(of: file.url) ?? file.url.absoluteString, filename: file.filename, contentType: file.contentType)
    }
}

extension TransferPreferences {
    /// The preferences state.json kept, key for key.
    init(_ legacy: Legacy.BackupPreferences) {
        self.init()
        includedAlbums = legacy.includedAlbums
        excludedAlbums = legacy.excludedAlbums
        cellularPhotos = legacy.cellularPhotos
        cellularVideos = legacy.cellularVideos
        downloadCloudOriginals = legacy.downloadCloudOriginals
        automatic = legacy.automatic
        requireCharging = legacy.requireCharging
        triggerDelay = legacy.triggerDelay
        syncAlbums = legacy.syncAlbums
    }
}

// MARK: - Writing

extension TransferStore {
    /// Replaces the library lane's records with what `plan` says, records `digest` as the
    /// authoritative import's and hands the database to the transfer engine, in one transaction
    /// (BM1): a crash before the commit leaves the database as it was, and one after it leaves a
    /// complete import, which the engine then owns. The share lane is left alone. `crash`
    /// simulates the app ending at a point, for tests.
    func importLegacy(_ plan: LegacyBackupPlan, digest: String, at date: Date, crashingAt crash: LegacyImportCrashPoint? = nil) throws {
        let db = try database()
        func stop(_ point: LegacyImportCrashPoint) throws {
            if crash == point { throw SimulatedCrash(point: point) }
        }
        try db.transaction {
            for statement in [
                "DELETE FROM attempts WHERE job_id IN (SELECT id FROM jobs WHERE lane='library')",
                "DELETE FROM stages WHERE job_id IN (SELECT id FROM jobs WHERE lane='library')",
                "DELETE FROM jobs WHERE lane='library'",
                "DELETE FROM confirmations", "DELETE FROM receipts", "DELETE FROM album_destinations", "DELETE FROM stack_tasks",
                "DELETE FROM linked_albums", "DELETE FROM notification_batches WHERE kind='backup'",
                "DELETE FROM preferences", "DELETE FROM engine_state",
            ] { try db.run(statement) }
            try stop(.afterClearing)

            try db.run("INSERT INTO preferences(id,json) VALUES(1,?)", [.text(TransferJSON.encode(plan.preferences))])
            try db.run("INSERT INTO engine_state(id,intent,blocker,last_message) VALUES(1,?,NULL,?)",
                       [.text(plan.intent.rawValue), .optionalText(plan.lastMessage)])
            var jobIDs: [String: Int64] = [:]
            for (seq, job) in plan.jobs.enumerated() {
                try db.run("""
                    INSERT INTO jobs(lane,source_key,origin,state,seq,retry_count,error_class,error_message,error_at,display_name,batch_id) \
                    VALUES('library',?,?,?,?,0,?,?,?,?,?)
                    """, [.text(job.localID), .text(job.origin.rawValue), .text(job.state.rawValue), .integer(Int64(seq)),
                          .optionalText(job.failure == nil ? nil : "item"), .optionalText(job.failure?.message),
                          .optionalDate(job.failure?.date), .optionalText(job.failure?.filename),
                          .optionalText(job.batch?.uuidString)])
                jobIDs[job.localID] = db.lastInsertedRow
            }
            for stage in plan.stages {
                guard let job = jobIDs[stage.localID] else { continue }
                try db.run("""
                    INSERT OR IGNORE INTO stages(stage_id,job_id,folder,modification_date,original_json,motion_json,sidecar_json,fields_json,\
                    is_video,motion_remote_id,motion_checksum,original_checksum,suspended) VALUES(?,?,?,?,?,?,?,?,?,?,?,NULL,?)
                    """, [.text(stage.stageID), .integer(job), .text(stage.folder), .date(stage.modificationDate),
                          .text(TransferJSON.encode(stage.original)), .optionalText(stage.motion.map(TransferJSON.encode)),
                          .optionalText(stage.sidecar.map(TransferJSON.encode)), .text(TransferJSON.encode(stage.fields)),
                          .bool(stage.isVideo), .optionalText(stage.motionRemoteID), .optionalText(stage.motionChecksum), .bool(stage.suspended)])
                try db.run("INSERT OR IGNORE INTO attempts(id,job_id,part,session,state,body_path) VALUES(?,?,?,?,?,?)",
                           [.text(stage.stageID), .integer(job), .text(stage.part.rawValue), .text(TransferSessionID.backup.rawValue),
                            .text(AttemptState.interrupted.rawValue), .optionalText(stage.bodyPath)])
            }
            try stop(.afterJobs)

            for (index, (localID, modified)) in plan.confirmations.enumerated() {
                if index % 4_096 == 0 { try Task.checkCancellation() }
                try db.run("INSERT OR REPLACE INTO confirmations(local_id,modification_date,confirmed_at) VALUES(?,?,NULL)",
                           [.text(localID), .date(modified)])
            }
            for (index, (localID, receipt)) in plan.receipts.enumerated() {
                if index % 4_096 == 0 { try Task.checkCancellation() }
                try db.run("""
                    INSERT OR REPLACE INTO receipts(local_id,modification_date,original_id,original_checksum,original_bytes,motion_id,\
                    motion_checksum,motion_bytes,confirmed_at,verified_at,local_deleted_at) VALUES(?,?,?,?,?,?,?,?,?,NULL,NULL)
                    """, [.text(localID), .date(receipt.modificationDate), .text(receipt.original.id), .text(receipt.original.checksum),
                          .optionalInteger(receipt.original.byteCount), .optionalText(receipt.motion?.id), .optionalText(receipt.motion?.checksum),
                          .optionalInteger(receipt.motion?.byteCount), .optionalDate(receipt.confirmedAt)])
            }
            try stop(.afterReceipts)

            for destination in plan.destinations {
                try db.run("INSERT OR IGNORE INTO album_destinations(local_id,album_id,remote_id,state,attempts,error) VALUES(?,?,?,'pending',0,NULL)",
                           [.text(destination.localID), .text(destination.albumID), .optionalText(destination.remoteID)])
            }
            for (device, album) in plan.linkedAlbums {
                try db.run("INSERT OR REPLACE INTO linked_albums(device_album_id,album_id) VALUES(?,?)", [.text(device), .text(album)])
            }
            if let batch = plan.batch {
                try db.run("""
                    INSERT OR REPLACE INTO notification_batches(id,kind,total,completed,failed,started_posted,terminal_posted) \
                    VALUES(?,'backup',?,?,?,1,0)
                    """, [.text(batch.id.uuidString), .integer(Int64(batch.total)), .integer(Int64(batch.completed)),
                          .optionalInteger(batch.terminalFailures.map(Int64.init))])
            }
            try db.run("""
                UPDATE meta SET legacy_import_digest=?,legacy_import_mode=?,legacy_imported_at=?,engine=?,\
                legacy_report_digest=NULL,legacy_report=NULL WHERE id=1
                """, [.text(digest), .text(ImportMode.authoritative.rawValue), .date(date), .text(Engine.transfer.rawValue)])
            try Task.checkCancellation()
            try stop(.beforeCommit)
        }
        // An import passes every row through the log; give its space back.
        try? db.run("PRAGMA wal_checkpoint(TRUNCATE)")
        try stop(.afterCommit)
    }
}

/// A crash simulated at a point of an import, for tests.
struct SimulatedCrash: Error, Equatable {
    let point: LegacyImportCrashPoint
}

/// Points inside an import where a test can make the app end.
enum LegacyImportCrashPoint: Sendable, CaseIterable {
    case afterClearing, afterJobs, afterReceipts, beforeCommit, afterCommit
}

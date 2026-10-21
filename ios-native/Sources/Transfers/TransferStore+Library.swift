import Foundation

/// What the library job executor and discovery read and write (B3, dormant). Every write for a
/// leased job applies only while its lease token still matches (BM12), in the same transaction as
/// the check.
extension TransferStore {
    // MARK: Stages

    /// The job's stage: the files staged for it and how far its upload got. A job has one; a legacy
    /// import made at most one per photo too.
    func libraryStage(job: Int64) throws -> LibraryStage? {
        var stage: LibraryStage?
        try database().run("""
            SELECT stage_id,folder,modification_date,original_json,motion_json,sidecar_json,fields_json,is_video,motion_remote_id,\
            motion_checksum,original_checksum,suspended FROM stages WHERE job_id=? ORDER BY rowid DESC LIMIT 1
            """, [.integer(job)]) { row in
            guard let stageID = row.text(0), let folder = row.text(1), let modified = row.real(2),
                  let original = row.text(3).flatMap({ TransferJSON.decode(StagedFile.self, $0) }) else { return }
            stage = LibraryStage(stageID: stageID, folder: folder, revision: AssetRevision(referenceSeconds: modified), original: original,
                                 motion: row.text(4).flatMap { TransferJSON.decode(StagedFile.self, $0) },
                                 sidecar: row.text(5).flatMap { TransferJSON.decode(StagedFile.self, $0) },
                                 fields: row.text(6).flatMap { TransferJSON.decode([String: String].self, $0) } ?? [:],
                                 isVideo: row.integer(7) == 1, motionRemoteID: row.text(8), motionChecksum: row.text(9),
                                 originalChecksum: row.text(10), suspended: row.integer(11) == 1)
        }
        return stage
    }

    /// Records the files staged for a leased job. Returns false when the lease is gone.
    func saveStage(_ stage: LibraryStage, job: Int64, token: UUID) throws -> Bool {
        let db = try database()
        return try db.transaction {
            guard try Self.holds(db, job: job, token: token) else { return false }
            try db.run("""
                INSERT OR REPLACE INTO stages(stage_id,job_id,folder,modification_date,original_json,motion_json,sidecar_json,fields_json,\
                is_video,motion_remote_id,motion_checksum,original_checksum,suspended) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(stage.stageID), .integer(job), .text(stage.folder), .real(stage.revision.referenceSeconds),
                      .text(TransferJSON.encode(stage.original)), .optionalText(stage.motion.map(TransferJSON.encode)),
                      .optionalText(stage.sidecar.map(TransferJSON.encode)), .text(TransferJSON.encode(stage.fields)), .bool(stage.isVideo),
                      .optionalText(stage.motionRemoteID), .optionalText(stage.motionChecksum), .optionalText(stage.originalChecksum),
                      .bool(stage.suspended)])
            return true
        }
    }

    /// Records a checksum of the stage once: a value already there is kept, and returned, so a
    /// resumed job never sends a second one. Nil when the lease is gone.
    func recordChecksum(_ checksum: String, of part: AttemptPart, stage: String, job: Int64, token: UUID) throws -> String? {
        let db = try database()
        let column = part == .motion ? "motion_checksum" : "original_checksum"
        return try db.transaction {
            guard try Self.holds(db, job: job, token: token) else { return nil }
            try db.run("UPDATE stages SET \(column)=coalesce(\(column),?) WHERE stage_id=? AND job_id=?",
                       [.text(checksum), .text(stage), .integer(job)])
            var kept: String?
            try db.run("SELECT \(column) FROM stages WHERE stage_id=? AND job_id=?", [.text(stage), .integer(job)]) { kept = $0.text(0) }
            return kept
        }
    }

    /// Records the server ID of a Live Photo's uploaded video, so a resumed job pairs the still with
    /// it rather than sending the video again.
    func recordMotion(_ remoteID: String, stage: String, job: Int64, token: UUID) throws -> Bool {
        let db = try database()
        return try db.transaction {
            guard try Self.holds(db, job: job, token: token) else { return false }
            try db.run("UPDATE stages SET motion_remote_id=? WHERE stage_id=? AND job_id=?", [.text(remoteID), .text(stage), .integer(job)])
            return db.changes == 1
        }
    }

    // MARK: Attempts

    func libraryAttempts(job: Int64) throws -> [LibraryAttempt] {
        var attempts: [LibraryAttempt] = []
        try database().run("""
            SELECT id,part,state,body_path,body_bytes,checksum,os_task_id,remote_id,remote_status FROM attempts WHERE job_id=? ORDER BY rowid
            """, [.integer(job)]) { row in
            guard let id = row.text(0), let part = row.text(1).flatMap(AttemptPart.init(rawValue:)),
                  let state = row.text(2).flatMap(AttemptState.init(rawValue:)) else { return }
            attempts.append(LibraryAttempt(id: AttemptID(legacy: id), part: part, state: state, bodyPath: row.text(3), bodyBytes: row.integer(4),
                                           checksum: row.text(5), taskID: row.integer(6), remoteID: row.text(7), remoteStatus: row.text(8)))
        }
        return attempts
    }

    /// Writes an attempt's row as it now stands. Returns false when the lease is gone.
    func saveAttempt(_ attempt: LibraryAttempt, failure: OutcomeRecord? = nil, job: Int64, token: UUID) throws -> Bool {
        let db = try database()
        return try db.transaction {
            guard try Self.holds(db, job: job, token: token) else { return false }
            try Self.writeAttempt(db, attempt, failure: failure, job: job)
            return true
        }
    }

    /// Inserts or replaces an attempt's row.
    static func writeAttempt(_ db: TransferSQLite, _ attempt: LibraryAttempt, failure: OutcomeRecord?, job: Int64) throws {
        try db.run("""
            INSERT OR REPLACE INTO attempts(id,job_id,part,session,state,body_path,body_bytes,checksum,os_task_id,remote_id,remote_status,\
            http_status,error_domain,error_code) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(attempt.id.rawValue), .integer(job), .text(attempt.part.rawValue), .text(TransferSessionID.backup.rawValue),
                  .text(attempt.state.rawValue), .optionalText(attempt.bodyPath), .optionalInteger(attempt.bodyBytes),
                  .optionalText(attempt.checksum), .optionalInteger(attempt.taskID), .optionalText(attempt.remoteID),
                  .optionalText(attempt.remoteStatus), .optionalInteger(failure?.httpStatus.map(Int64.init)),
                  .optionalText(failure?.errorDomain), .optionalInteger(failure?.errorCode.map(Int64.init))])
    }

    // MARK: Discovery

    /// The library lane's photos that have a job, in any state.
    func libraryJobKeys() throws -> [String] {
        var keys: [String] = []
        try database().run("SELECT source_key FROM jobs WHERE lane='library' ORDER BY source_key") { row in
            if let key = row.text(0) { keys.append(key) }
        }
        return keys
    }

    /// Merges what discovery found, at commit time, in one transaction: each photo gets a job,
    /// after the lane's last, unless a confirmation has its date or a job already has it. A failed
    /// job whose stage has another date than the photo now has (the photo was edited) is queued
    /// again from staging, its stage dropped; one that failed before staging waits for the user. The
    /// checks run against the tables as they are now, so a photo confirmed while discovery read
    /// Photos is not queued again. A photo Photos reports without a date is queued only if it was
    /// never confirmed, as it would otherwise be sent again every time.
    ///
    /// The jobs of `gone`, photos no longer in Photos, are dropped with their stage and attempt
    /// rows (the owner's decision), unless a lease holds one or its upload is with the transport,
    /// whose outcome still has to land. Their files are left for the staging sweep (B6).
    func mergeDiscovery(_ found: [DeviceCandidate], gone: [String], origin: JobOrigin = .discovery) throws -> DiscoveryMerge {
        let db = try database()
        let merge = try db.transaction {
            try db.run("CREATE TEMP TABLE IF NOT EXISTS discovered(local_id TEXT PRIMARY KEY,modification_date)")
            try db.run("DELETE FROM temp.discovered")
            for (index, candidate) in found.enumerated() {
                if index % 4_096 == 0 { try Task.checkCancellation() }
                try db.run("INSERT OR REPLACE INTO temp.discovered(local_id,modification_date) VALUES(?,?)",
                           [.text(candidate.id), .optionalDate(candidate.modified)])
            }
            // Failed jobs of photos edited since they were staged start again.
            var edited: [Int64] = []
            try db.run("""
                SELECT DISTINCT j.id FROM jobs j JOIN stages s ON s.job_id=j.id JOIN temp.discovered d ON d.local_id=j.source_key \
                WHERE j.lane='library' AND j.state='failed' AND j.lease_token IS NULL AND d.modification_date IS NOT NULL \
                AND s.modification_date<>d.modification_date
                """) { row in if let id = row.integer(0) { edited.append(id) } }
            if !edited.isEmpty {
                let match = "SELECT value FROM json_each(?)"
                let ids = TransferSQLite.Value.text(TransferJSON.encode(edited))
                try Self.dropStages(db, ofJobsIn: match, [ids])
                try db.run("""
                    UPDATE jobs SET state='queued',retry_count=0,not_before=NULL,error_class=NULL,error_message=NULL,error_at=NULL \
                    WHERE id IN (\(match))
                    """, [ids])
            }
            var last: Int64 = -1
            try db.run("SELECT max(seq) FROM jobs WHERE lane='library'") { last = $0.integer(0) ?? -1 }
            try db.run("""
                INSERT OR IGNORE INTO jobs(lane,source_key,origin,state,seq,retry_count) \
                SELECT 'library',d.local_id,?,'queued',?+row_number() OVER (ORDER BY d.local_id),0 FROM temp.discovered d \
                WHERE NOT EXISTS(SELECT 1 FROM confirmations c WHERE c.local_id=d.local_id AND \
                (d.modification_date IS NULL OR c.modification_date=d.modification_date)) \
                AND NOT EXISTS(SELECT 1 FROM jobs j WHERE j.lane='library' AND j.source_key=d.local_id)
                """, [.text(origin.rawValue), .integer(last)])
            let queued = db.changes + edited.count
            var dropped = 0
            if !gone.isEmpty {
                let match = """
                    SELECT id FROM jobs WHERE lane='library' AND lease_token IS NULL AND state NOT IN ('submitting','submitted','finalizing') \
                    AND source_key IN (SELECT value FROM json_each(?))
                    """
                let keys = TransferSQLite.Value.text(TransferJSON.encode(gone))
                try db.run("DELETE FROM attempts WHERE job_id IN (\(match))", [keys])
                try db.run("DELETE FROM stages WHERE job_id IN (\(match))", [keys])
                try db.run("DELETE FROM jobs WHERE id IN (\(match))", [keys])
                dropped = db.changes
            }
            try db.run("DELETE FROM temp.discovered")
            return DiscoveryMerge(found: found.count, queued: queued, dropped: dropped)
        }
        return merge
    }

    // MARK: -

    /// Drops the stages of the jobs `match` selects, so they stage again, and abandons the
    /// attempts left unanswered with them, whose bodies were made from those stages.
    static func dropStages(_ db: TransferSQLite, ofJobsIn match: String, _ arguments: [TransferSQLite.Value]) throws {
        try db.run("""
            UPDATE attempts SET state='abandoned' WHERE job_id IN (\(match)) AND state IN ('created','bodyWritten','submitted','interrupted')
            """, arguments)
        try db.run("DELETE FROM stages WHERE job_id IN (\(match))", arguments)
    }

    /// Whether the lease still holds the job.
    private static func holds(_ db: TransferSQLite, job: Int64, token: UUID) throws -> Bool {
        var found = false
        try db.run("SELECT 1 FROM jobs WHERE id=? AND lease_token=?", [.integer(job), .text(token.uuidString)]) { _ in found = true }
        return found
    }
}

/// The files staged for a library job and how far its upload got. Paths are relative to the App
/// Group (BM4); a legacy stage's file outside the Backup folder keeps its recorded URL.
struct LibraryStage: Hashable, Sendable {
    /// Names the stage. For a legacy stage it is also the attempt ID of the part it was uploading.
    let stageID: String
    /// The stage's folder, relative to the App Group: Backup/<digest>/<uuid>.
    let folder: String
    /// PHAsset.modificationDate when staged, bit for bit.
    let revision: AssetRevision
    let original: StagedFile
    let motion: StagedFile?
    let sidecar: StagedFile?
    let fields: [String: String]
    let isVideo: Bool
    var motionRemoteID: String?
    var motionChecksum: String?
    var originalChecksum: String?
    var suspended = false
}

/// One upload of one part, as the attempts table keeps it.
struct LibraryAttempt: Hashable, Sendable {
    let id: AttemptID
    let part: AttemptPart
    var state: AttemptState
    /// The multipart body, relative to the App Group.
    var bodyPath: String?
    var bodyBytes: Int64?
    var checksum: String?
    var taskID: Int64?
    var remoteID: String?
    /// created or duplicate, from the server's answer.
    var remoteStatus: String?

    /// Sent, or on its way, and not yet answered: its task or outcome may still be with iOS.
    var isUnanswered: Bool { [.created, .bodyWritten, .submitted, .interrupted].contains(state) }
}

/// What one discovery pass changed.
struct DiscoveryMerge: Hashable, Sendable {
    /// Photos discovery read in the selected albums.
    var found = 0
    var queued = 0
    /// Jobs dropped because their photo left Photos.
    var dropped = 0
}

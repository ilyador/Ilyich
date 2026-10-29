import Foundation
@testable import Ilyich

/// Rows a test puts in a transfers database as earlier runs left them: B9's import of an earlier
/// build's state.json among them, whose rows the phone's database still holds (jobs of origin
/// legacy, stages whose ID names an interrupted attempt and records no checksum of the still,
/// confirmations without a time), and B1's copies of a state.json no import read. Tests write the
/// rows themselves; LegacyBackupImportTests pins that the import writes the same.
struct TransferSeed {
    struct Receipt {
        let localID: String
        let modified: Date
        let originalID: String
        let originalChecksum: String
        var originalBytes: Int64?
        var motionID: String?
        var motionChecksum: String?
        var motionBytes: Int64?
        var confirmedAt: Date?
    }

    struct Failure {
        let message: String
        let date: Date
        let filename: String
    }

    struct Job {
        let localID: String
        var origin: JobOrigin = .legacy
        var state: JobState = .queued
        var failure: Failure?
        /// The running notification batch it counts towards.
        var batch: UUID?
    }

    /// A stage and the interrupted attempt its ID names, as B9's import wrote them.
    struct Stage {
        let localID: String
        let stageID: String
        /// The stage's folder, relative to the App Group.
        let folder: String
        let modified: Date
        let original: StagedFile
        var motion: StagedFile?
        var sidecar: StagedFile?
        var fields: [String: String] = [:]
        var isVideo = false
        var motionRemoteID: String?
        var motionChecksum: String?
        var suspended = false
        /// The part the stage ID's attempt uploads: a Live Photo's video before its still.
        var part: AttemptPart = .original
        /// The attempt's multipart body, relative to the App Group.
        var bodyPath: String? = nil
    }

    var preferences = TransferPreferences()
    var intent: RunIntent = .paused
    var lastMessage: String?
    /// In queue order.
    var jobs: [Job] = []
    var stages: [Stage] = []
    /// Confirmed photos, by local ID and the revision confirmed, with no time kept.
    var confirmations: [(String, Date)] = []
    var receipts: [Receipt] = []
    var destinations: [(localID: String, albumID: String, remoteID: String?)] = []
    var linkedAlbums: [(device: String, album: String)] = []
    var batch: (id: UUID, total: Int, completed: Int, failed: Int?)?
}

extension TransferStore {
    /// Writes `seed` into the database in one transaction and records who owns it: the engine
    /// with B9's authoritative import of a state.json whose digest is `importedDigest`, unless the
    /// test says otherwise (a fresh database the engine claimed has no digest; B1's shadow copy
    /// is mode shadow and the old engine's).
    func seedForTest(_ seed: TransferSeed, importedDigest: String? = nil, mode: ImportMode? = .authoritative, engine: Engine = .transfer,
                     importedAt: Date = Date(timeIntervalSinceReferenceDate: 790_000_000)) throws {
        let db = try database()
        try db.transaction {
            try db.run("INSERT INTO preferences(id,json) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
                       [.text(TransferJSON.encode(seed.preferences))])
            try db.run("""
                INSERT INTO engine_state(id,intent,blocker,last_message) VALUES(1,?,NULL,?) \
                ON CONFLICT(id) DO UPDATE SET intent=excluded.intent,blocker=NULL,last_message=excluded.last_message
                """, [.text(seed.intent.rawValue), .optionalText(seed.lastMessage)])
            var last: Int64 = -1
            try db.run("SELECT max(seq) FROM jobs WHERE lane='library'") { last = $0.integer(0) ?? -1 }
            var jobIDs: [String: Int64] = [:]
            for job in seed.jobs {
                last += 1
                try db.run("""
                    INSERT INTO jobs(lane,source_key,origin,state,seq,retry_count,error_class,error_message,error_at,display_name,batch_id) \
                    VALUES('library',?,?,?,?,0,?,?,?,?,?)
                    """, [.text(job.localID), .text(job.origin.rawValue), .text(job.state.rawValue), .integer(last),
                          .optionalText(job.failure == nil ? nil : "item"), .optionalText(job.failure?.message),
                          .optionalDate(job.failure?.date), .optionalText(job.failure?.filename), .optionalText(job.batch?.uuidString)])
                jobIDs[job.localID] = db.lastInsertedRow
            }
            for stage in seed.stages {
                guard let job = jobIDs[stage.localID] else { continue }
                try db.run("""
                    INSERT INTO stages(stage_id,job_id,folder,modification_date,original_json,motion_json,sidecar_json,fields_json,\
                    is_video,motion_remote_id,motion_checksum,original_checksum,suspended) VALUES(?,?,?,?,?,?,?,?,?,?,?,NULL,?)
                    """, [.text(stage.stageID), .integer(job), .text(stage.folder), .date(stage.modified),
                          .text(TransferJSON.encode(stage.original)), .optionalText(stage.motion.map(TransferJSON.encode)),
                          .optionalText(stage.sidecar.map(TransferJSON.encode)), .text(TransferJSON.encode(stage.fields)),
                          .bool(stage.isVideo), .optionalText(stage.motionRemoteID), .optionalText(stage.motionChecksum), .bool(stage.suspended)])
                try db.run("INSERT INTO attempts(id,job_id,part,session,state,body_path) VALUES(?,?,?,?,?,?)",
                           [.text(stage.stageID), .integer(job), .text(stage.part.rawValue), .text(TransferSessionID.backup.rawValue),
                            .text(AttemptState.interrupted.rawValue), .optionalText(stage.bodyPath)])
            }
            for (localID, modified) in seed.confirmations {
                try db.run("INSERT OR REPLACE INTO confirmations(local_id,modification_date,confirmed_at) VALUES(?,?,NULL)",
                           [.text(localID), .date(modified)])
            }
            for receipt in seed.receipts {
                try db.run("""
                    INSERT OR REPLACE INTO receipts(local_id,modification_date,original_id,original_checksum,original_bytes,motion_id,\
                    motion_checksum,motion_bytes,confirmed_at,verified_at,local_deleted_at) VALUES(?,?,?,?,?,?,?,?,?,NULL,NULL)
                    """, [.text(receipt.localID), .date(receipt.modified), .text(receipt.originalID), .text(receipt.originalChecksum),
                          .optionalInteger(receipt.originalBytes), .optionalText(receipt.motionID), .optionalText(receipt.motionChecksum),
                          .optionalInteger(receipt.motionBytes), .optionalDate(receipt.confirmedAt)])
            }
            for destination in seed.destinations {
                try db.run("INSERT OR IGNORE INTO album_destinations(local_id,album_id,remote_id,state,attempts,error) VALUES(?,?,?,'pending',0,NULL)",
                           [.text(destination.localID), .text(destination.albumID), .optionalText(destination.remoteID)])
            }
            for link in seed.linkedAlbums {
                try db.run("INSERT OR REPLACE INTO linked_albums(device_album_id,album_id) VALUES(?,?)", [.text(link.device), .text(link.album)])
            }
            if let batch = seed.batch {
                try db.run("""
                    INSERT OR REPLACE INTO notification_batches(id,kind,total,completed,failed,started_posted,terminal_posted) \
                    VALUES(?,'backup',?,?,?,1,0)
                    """, [.text(batch.id.uuidString), .integer(Int64(batch.total)), .integer(Int64(batch.completed)),
                          .optionalInteger(batch.failed.map(Int64.init))])
            }
            try db.run("UPDATE meta SET engine=?,legacy_import_digest=?,legacy_import_mode=?,legacy_imported_at=? WHERE id=1",
                       [.text(engine.rawValue), .optionalText(importedDigest), .optionalText(mode?.rawValue),
                        importedDigest == nil ? .null : .date(importedAt)])
        }
    }
}

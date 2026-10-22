import Foundation

/// What the cutover to the transfer engine (B9) reads and writes beyond the engine's own tables:
/// the receipts cleanup and the device index read, local deletions cleanup committed, the queue as
/// the backup screen lists it, and the merge of a state.json a reinstalled older build wrote.
extension TransferStore {
    // MARK: Receipts for cleanup and the device index

    /// Every receipt, by local ID, as cleanup and the device index read them: one statement.
    func cleanupReceipts() throws -> [String: CleanupReceipt] {
        var result: [String: CleanupReceipt] = [:]
        try database().run("""
            SELECT local_id,modification_date,original_id,original_checksum,motion_id,motion_checksum,local_deleted_at FROM receipts
            """) { row in
            guard let localID = row.text(0), let modified = row.real(1), let original = row.text(2), let checksum = row.text(3) else { return }
            var motion: CleanupReceipt.RemoteCopy?
            if let id = row.text(4), let motionChecksum = row.text(5) { motion = CleanupReceipt.RemoteCopy(id: id, checksum: motionChecksum) }
            result[localID] = CleanupReceipt(localID: localID, revision: AssetRevision(referenceSeconds: modified),
                                             original: CleanupReceipt.RemoteCopy(id: original, checksum: checksum), motion: motion,
                                             locallyDeleted: !row.isNull(6))
        }
        return result
    }

    /// Records that cleanup removed these photos from the phone, each only while its receipt is
    /// still of the revision removed (nil matches any) and not marked yet. Returns how many were.
    @discardableResult
    func markLocallyDeleted(_ deletions: [LocalDeletion]) throws -> Int {
        guard !deletions.isEmpty else { return 0 }
        let db = try database()
        return try db.transaction {
            var marked = 0
            for deletion in deletions {
                if let revision = deletion.revision {
                    try db.run("UPDATE receipts SET local_deleted_at=? WHERE local_id=? AND modification_date=? AND local_deleted_at IS NULL",
                               [.date(deletion.date), .text(deletion.localID), .real(revision.referenceSeconds)])
                } else {
                    try db.run("UPDATE receipts SET local_deleted_at=? WHERE local_id=? AND local_deleted_at IS NULL",
                               [.date(deletion.date), .text(deletion.localID)])
                }
                marked += db.changes
            }
            return marked
        }
    }

    // MARK: An unreadable state.json

    /// state.json couldn't be read and was moved aside: the engine takes the database over as it
    /// is. A shadow copy B1 made of an earlier, readable state.json keeps its receipts and
    /// confirmations, which no other copy has now; a database without one starts empty. Returns
    /// whether the engine owns the database.
    @discardableResult
    func adoptAfterQuarantine() throws -> Bool {
        let db = try database()
        try db.run("UPDATE meta SET engine=?,legacy_import_mode=? WHERE id=1 AND schema<=?",
                   [.text(Engine.transfer.rawValue), .text(LegacyBackupImporter.Mode.authoritative.rawValue), .integer(Int64(Self.schemaVersion))])
        return try meta().engine == .transfer
    }

    // MARK: The backup screen's queue

    /// The library lane's jobs in queue order, failed ones included with their message, as the
    /// upload queue always listed them, after the job whose seq is `after`.
    func backupQueuePage(after seq: Int64?, limit: Int) throws -> [TransferQueueItem] {
        var page: [TransferQueueItem] = []
        try database().run("""
            SELECT \(Self.jobColumns) FROM jobs WHERE lane='library' AND seq>? ORDER BY seq,id LIMIT ?
            """, [.integer(seq ?? -1), .integer(Int64(max(limit, 1)))]) { row in
            if let job = Self.storedJob(row) { page.append(job.item) }
        }
        return page
    }

    // MARK: A later state.json

    /// Merges a state.json an older build wrote after the transfer engine took the database over
    /// (BM8): it can only be one reinstalled over this build, which read the state.json left in
    /// place and backed up from it. Nothing the engine recorded is lost, and nothing that build
    /// did is either:
    /// - confirmations and receipts it has that the database doesn't are added; one both have is
    ///   replaced only when its receipt is newer (confirmed later);
    /// - photos still in its queue that the database neither confirmed nor has a job for join the
    ///   end of the queue;
    /// - album adds and linked albums it has that the database doesn't are added;
    /// - preferences, the run intent, stages and the notification batch stay the database's: the
    ///   engine's are newer, and that build's stages are swept once no task holds them.
    /// Then the digest is recorded, so the same file merges once.
    func mergeLegacy(_ plan: LegacyBackupPlan, digest: String, at date: Date) throws -> LegacyMerge {
        let db = try database()
        let merge = try db.transaction {
            var merge = LegacyMerge()
            var receipts: [String: (modification: Double?, confirmed: Double?)] = [:]
            try db.run("SELECT local_id,modification_date,confirmed_at FROM receipts") { row in
                if let id = row.text(0) { receipts[id] = (row.real(1), row.real(2)) }
            }
            var confirmed: [String: Double?] = [:]
            try db.run("SELECT local_id,modification_date FROM confirmations") { row in
                if let id = row.text(0) { confirmed[id] = row.real(1) }
            }
            for (index, (localID, receipt)) in plan.receipts.enumerated() {
                if index % 4_096 == 0 { try Task.checkCancellation() }
                let theirs = receipt.confirmedAt?.timeIntervalSinceReferenceDate
                if let ours = receipts[localID] {
                    guard let theirs, let mine = ours.confirmed, theirs > mine,
                          ours.modification?.bitPattern != receipt.modificationDate.timeIntervalSinceReferenceDate.bitPattern else { continue }
                }
                try db.run("""
                    INSERT OR REPLACE INTO receipts(local_id,modification_date,original_id,original_checksum,original_bytes,motion_id,\
                    motion_checksum,motion_bytes,confirmed_at,verified_at,local_deleted_at) VALUES(?,?,?,?,?,?,?,?,?,NULL,NULL)
                    """, [.text(localID), .date(receipt.modificationDate), .text(receipt.original.id), .text(receipt.original.checksum),
                          .optionalInteger(receipt.original.byteCount), .optionalText(receipt.motion?.id), .optionalText(receipt.motion?.checksum),
                          .optionalInteger(receipt.motion?.byteCount), .optionalDate(receipt.confirmedAt)])
                try db.run("""
                    INSERT INTO confirmations(local_id,modification_date,confirmed_at) VALUES(?,?,?) \
                    ON CONFLICT(local_id) DO UPDATE SET modification_date=excluded.modification_date,confirmed_at=excluded.confirmed_at
                    """, [.text(localID), .date(receipt.modificationDate), .optionalDate(receipt.confirmedAt)])
                confirmed[localID] = receipt.modificationDate.timeIntervalSinceReferenceDate
                merge.receipts += 1
            }
            for (localID, modified) in plan.confirmations where confirmed[localID] == nil {
                try db.run("INSERT OR IGNORE INTO confirmations(local_id,modification_date,confirmed_at) VALUES(?,?,NULL)",
                           [.text(localID), .date(modified)])
                confirmed[localID] = modified.timeIntervalSinceReferenceDate
                merge.confirmations += db.changes
            }
            // A photo it confirmed that the database still queues is done: its job goes, unless a
            // lease holds it or its upload is with the transport.
            var queuedKeys = Set<String>()
            try db.run("SELECT source_key FROM jobs WHERE lane='library'") { row in if let key = row.text(0) { queuedKeys.insert(key) } }
            for localID in plan.confirmations.map(\.0) where queuedKeys.contains(localID) {
                try db.run("""
                    DELETE FROM attempts WHERE job_id IN (SELECT id FROM jobs WHERE lane='library' AND source_key=? AND lease_token IS NULL \
                    AND state NOT IN ('submitting','submitted','finalizing'))
                    """, [.text(localID)])
                try db.run("""
                    DELETE FROM stages WHERE job_id IN (SELECT id FROM jobs WHERE lane='library' AND source_key=? AND lease_token IS NULL \
                    AND state NOT IN ('submitting','submitted','finalizing'))
                    """, [.text(localID)])
                try db.run("""
                    DELETE FROM jobs WHERE lane='library' AND source_key=? AND lease_token IS NULL AND state NOT IN ('submitting','submitted','finalizing') \
                    AND EXISTS(SELECT 1 FROM confirmations c WHERE c.local_id=jobs.source_key)
                    """, [.text(localID)])
                merge.settled += db.changes
            }
            var last: Int64 = -1
            try db.run("SELECT max(seq) FROM jobs WHERE lane='library'") { last = $0.integer(0) ?? -1 }
            for job in plan.jobs where job.origin == .legacy && job.failure == nil && confirmed[job.localID] == nil {
                try db.run("INSERT OR IGNORE INTO jobs(lane,source_key,origin,state,seq,retry_count) VALUES('library',?,?,'queued',?,0)",
                           [.text(job.localID), .text(JobOrigin.legacy.rawValue), .integer(last + 1)])
                if db.changes > 0 { last += 1; merge.queued += 1 }
            }
            for destination in plan.destinations {
                var remote: String?
                try db.run("SELECT original_id FROM receipts WHERE local_id=?", [.text(destination.localID)]) { remote = $0.text(0) }
                try db.run("INSERT OR IGNORE INTO album_destinations(local_id,album_id,remote_id,state,attempts,error) VALUES(?,?,?,'pending',0,NULL)",
                           [.text(destination.localID), .text(destination.albumID), .optionalText(remote)])
                merge.albumAdds += db.changes
            }
            for (device, album) in plan.linkedAlbums {
                try db.run("INSERT OR IGNORE INTO linked_albums(device_album_id,album_id) VALUES(?,?)", [.text(device), .text(album)])
            }
            try db.run("UPDATE meta SET legacy_import_digest=?,legacy_imported_at=? WHERE id=1", [.text(digest), .date(date)])
            return merge
        }
        try? db.run("PRAGMA wal_checkpoint(TRUNCATE)")
        return merge
    }
}

/// A photo cleanup removed from the phone, as the device journal recorded it.
struct LocalDeletion: Hashable, Sendable {
    let localID: String
    /// The revision checked before removing it; nil when unknown.
    let revision: AssetRevision?
    let date: Date
}

/// What merging a later state.json added.
struct LegacyMerge: Hashable, Sendable {
    var receipts = 0
    var confirmations = 0
    /// Jobs of photos that build confirmed, settled.
    var settled = 0
    var queued = 0
    var albumAdds = 0
}

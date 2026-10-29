import Foundation

/// What the cutover to the transfer engine (B9) reads and writes beyond the engine's own tables:
/// the receipts cleanup and the device index read, local deletions cleanup committed, and the queue
/// as the backup screen lists it.
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

    // MARK: The screens' queues

    /// A lane's jobs in queue order, failed ones included with their message, after the job
    /// whose seq is `after`: the upload queue always listed failed photos, and the Shared files
    /// sheet shows each file's error beside it.
    func listedQueuePage(lane: TransferLane, after seq: Int64?, limit: Int) throws -> [TransferQueueItem] {
        var page: [TransferQueueItem] = []
        try database().run("""
            SELECT \(Self.jobColumns) FROM jobs WHERE lane=? AND seq>? ORDER BY seq,id LIMIT ?
            """, [.text(lane.rawValue), .integer(seq ?? -1), .integer(Int64(max(limit, 1)))]) { row in
            if let job = Self.storedJob(row) { page.append(job.item) }
        }
        return page
    }
}

/// A photo cleanup removed from the phone, as the device journal recorded it.
struct LocalDeletion: Hashable, Sendable {
    let localID: String
    /// The revision checked before removing it; nil when unknown.
    let revision: AssetRevision?
    let date: Date
}

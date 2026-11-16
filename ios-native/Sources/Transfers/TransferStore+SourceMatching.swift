import Foundation

/// Durable association work, never an upload job or backup/cleanup proof. The full receipt
/// identity prevents a delayed attempt from attaching an original to a different rendition.
struct SourceMatchTaskRow: Hashable, Sendable {
    let localID: String
    let revision: AssetRevision
    let currentID: String
    let currentChecksum: String
    let motionID: String?
    let motionChecksum: String?
    let state: String
    let attempts: Int
    let notBefore: Date?
    let reason: String?

    var receipt: TransferReceipt {
        TransferReceipt(localID: localID, revision: revision, original: .init(id: currentID, checksum: currentChecksum),
                        motion: motionID.flatMap { id in motionChecksum.map { .init(id: id, checksum: $0) } }, confirmedAt: nil)
    }
}

enum SourceMatchTaskOutcome: Sendable {
    case matched(SourceOriginalAssociation)
    case notApplicable(String)
    case deferred(String)
    case failed(String)
}

extension TransferStore {
    static let sourceMatchColumns = "local_id,modification_date,current_id,current_checksum,motion_id,motion_checksum,state,attempts,not_before,reason"

    /// Called inside receipt completion. Replaying an unchanged receipt preserves its work;
    /// a new revision/remote rendition replaces only that photo's obsolete task.
    static func enqueueSourceMatch(_ db: TransferSQLite, receipt: TransferReceipt) throws {
        try db.run("""
            INSERT INTO source_match_tasks(local_id,modification_date,current_id,current_checksum,motion_id,motion_checksum,state,attempts,not_before,reason) \
            VALUES(?,?,?,?,?,?,'pending',0,NULL,'awaitingSource') ON CONFLICT(local_id) DO UPDATE SET \
            modification_date=excluded.modification_date,current_id=excluded.current_id,current_checksum=excluded.current_checksum,\
            motion_id=excluded.motion_id,motion_checksum=excluded.motion_checksum,state='pending',attempts=0,not_before=NULL,reason='awaitingSource' \
            WHERE source_match_tasks.modification_date<>excluded.modification_date OR source_match_tasks.current_id<>excluded.current_id \
            OR source_match_tasks.current_checksum<>excluded.current_checksum OR source_match_tasks.motion_id IS NOT excluded.motion_id \
            OR source_match_tasks.motion_checksum IS NOT excluded.motion_checksum
            """, [.text(receipt.localID), .real(receipt.revision.referenceSeconds), .text(receipt.original.id), .text(receipt.original.checksum),
                   .optionalText(receipt.motion?.id), .optionalText(receipt.motion?.checksum)])
    }

    /// One additive migration backfills old current receipts; opening again does not reset retries.
    static func backfillSourceMatches(_ db: TransferSQLite) throws {
        try db.run("""
            INSERT OR IGNORE INTO source_match_tasks(local_id,modification_date,current_id,current_checksum,motion_id,motion_checksum,state,attempts,reason) \
            SELECT r.local_id,r.modification_date,r.original_id,r.original_checksum,r.motion_id,r.motion_checksum,'pending',0,'migration' \
            FROM receipts r JOIN confirmations c ON c.local_id=r.local_id AND c.modification_date=r.modification_date WHERE r.local_deleted_at IS NULL
            """)
    }

    /// Superseded/deleted confirmations retire work, not their receipt history or other revisions' cache.
    func retireStaleSourceMatchTasks() throws {
        try database().run("""
            DELETE FROM source_match_tasks WHERE NOT EXISTS(SELECT 1 FROM receipts r JOIN confirmations c \
            ON c.local_id=r.local_id AND c.modification_date=r.modification_date WHERE r.local_id=source_match_tasks.local_id \
            AND r.modification_date=source_match_tasks.modification_date AND r.original_id=source_match_tasks.current_id \
            AND r.original_checksum=source_match_tasks.current_checksum AND r.motion_id IS source_match_tasks.motion_id \
            AND r.motion_checksum IS source_match_tasks.motion_checksum AND r.local_deleted_at IS NULL)
            """)
    }

    func dueSourceMatchTasks(at date: Date, limit: Int = 25) throws -> [SourceMatchTaskRow] {
        var result: [SourceMatchTaskRow] = []
        try database().run("""
            SELECT \(Self.sourceMatchColumns) FROM source_match_tasks WHERE state='pending' AND (not_before IS NULL OR not_before<=?) AND \(try automaticFollowUpSQL()) \
            ORDER BY coalesce(not_before,0),local_id LIMIT ?
            """, [.date(date), .integer(Int64(min(max(limit, 1), 25)))]) { result.append(Self.sourceMatchRow($0)) }
        return result
    }

    func nextSourceMatchDue() throws -> Date? {
        var date: Date?
        try database().run("SELECT min(coalesce(not_before,0)) FROM source_match_tasks WHERE state='pending' AND \(try automaticFollowUpSQL())") { date = $0.date(0) }
        return date
    }

    func sourceMatchTasks(limit: Int = 500) throws -> [SourceMatchTaskRow] {
        var result: [SourceMatchTaskRow] = []
        try database().run("SELECT \(Self.sourceMatchColumns) FROM source_match_tasks ORDER BY local_id LIMIT ?",
                           [.integer(Int64(min(max(limit, 1), 5_000)))]) { result.append(Self.sourceMatchRow($0)) }
        return result
    }

    /// An explicit retry resets failed/pending work. A condition change wakes only source
    /// availability deferrals, preserving ordinary server backoff on unrelated upload commits.
    func requeueSourceMatches(includeFailed: Bool) throws {
        if includeFailed {
            try database().run("UPDATE source_match_tasks SET state='pending',attempts=0,not_before=NULL WHERE state IN ('pending','failed')")
        } else {
            let reasons: [SourceOriginalReason] = [.photosAccess, .assetUnavailable, .missingOriginal, .incompleteResources,
                .snapshotChanged, .libraryChanged, .cloudRequired, .waitingForWiFi, .networkUnavailable, .sourceUnavailable,
                .revisionUnavailable, .cachedSnapshotMissing]
            try database().run("""
                UPDATE source_match_tasks SET not_before=NULL WHERE state='pending' AND reason IN (SELECT value FROM json_each(?))
                """, [.text(TransferJSON.encode(reasons.map(\.rawValue) + ["serverUnavailable"]))])
        }
    }

    private static func sourceMatchRow(_ row: TransferSQLite.Row) -> SourceMatchTaskRow {
        SourceMatchTaskRow(localID: row.text(0) ?? "", revision: .init(referenceSeconds: row.real(1) ?? 0), currentID: row.text(2) ?? "",
                           currentChecksum: row.text(3) ?? "", motionID: row.text(4), motionChecksum: row.text(5), state: row.text(6) ?? "",
                           attempts: Int(row.integer(7) ?? 0), notBefore: row.date(8), reason: row.text(9))
    }

    static func sourceMatchDelay(attempts: Int) -> TimeInterval {
        min(30 * pow(2, Double(min(max(attempts, 0), 7))), 3_600)
    }

    /// Explicit maintenance also wakes deferred/terminal association work for this exact
    /// current receipt. It never requeues the upload or forgets a completed stack relation.
    func requestSourceMatch(_ receipt: TransferReceipt, permits: @Sendable () -> Bool = { true }) throws {
        let db = try database()
        try db.transaction {
            try Task.checkCancellation()
            guard permits() else { throw CancellationError() }
            var current = false
            let keys: [TransferSQLite.Value] = [.text(receipt.localID), .real(receipt.revision.referenceSeconds), .text(receipt.original.id),
                                               .text(receipt.original.checksum), .optionalText(receipt.motion?.id), .optionalText(receipt.motion?.checksum)]
            try db.run("""
                SELECT 1 FROM receipts r JOIN confirmations c ON c.local_id=r.local_id AND c.modification_date=r.modification_date \
                WHERE r.local_id=? AND r.modification_date=? AND r.original_id=? AND r.original_checksum=? AND r.motion_id IS ? \
                AND r.motion_checksum IS ? AND r.local_deleted_at IS NULL
                """, keys) { _ in current = true }
            guard current else { return }
            try Self.enqueueSourceMatch(db, receipt: receipt)
            try db.run("""
                UPDATE source_match_tasks SET state='pending',attempts=0,not_before=NULL,reason='explicitRequest' \
                WHERE local_id=? AND modification_date=? AND current_id=? AND current_checksum=? AND motion_id IS ? AND motion_checksum IS ?
                """, keys)
        }
    }

    /// The task and current receipt are checked inside the same transaction as scheduling a
    /// stack. A revoked account or superseding upload cannot turn an old match into new work.
    @discardableResult
    func finishSourceMatchTask(_ task: SourceMatchTaskRow, _ outcome: SourceMatchTaskOutcome, at date: Date,
                               permits: @Sendable () -> Bool = { true }) throws -> Bool {
        let db = try database()
        return try db.transaction {
            try Task.checkCancellation()
            guard permits() else { throw CancellationError() }
            let match = "local_id=? AND modification_date=? AND current_id=? AND current_checksum=? AND motion_id IS ? AND motion_checksum IS ?"
            let keys: [TransferSQLite.Value] = [.text(task.localID), .real(task.revision.referenceSeconds), .text(task.currentID), .text(task.currentChecksum),
                                                .optionalText(task.motionID), .optionalText(task.motionChecksum)]
            var found = false
            try db.run("SELECT 1 FROM source_match_tasks WHERE \(match) AND state='pending'", keys) { _ in found = true }
            guard found else { return false }
            var current = false
            try db.run("""
                SELECT 1 FROM receipts r JOIN confirmations c ON c.local_id=r.local_id AND c.modification_date=r.modification_date \
                WHERE r.local_id=? AND r.modification_date=? AND r.original_id=? AND r.original_checksum=? \
                AND r.motion_id IS ? AND r.motion_checksum IS ? AND r.local_deleted_at IS NULL
                """, keys) { _ in current = true }
            guard current else {
                try db.run("DELETE FROM source_match_tasks WHERE \(match)", keys)
                return false
            }
            switch outcome {
            case .matched(let source):
                let cached = try sourceOriginal(for: task.localID, revision: task.revision)
                guard source.localID == task.localID, source.revision == task.revision, source.remoteID != nil,
                      source.fingerprint != nil, cached?.checksum == source.checksum, cached?.remoteID == source.remoteID,
                      cached?.fingerprint == source.fingerprint else {
                    try db.run("UPDATE source_match_tasks SET attempts=attempts+1,not_before=?,reason='sourceEvidenceChanged' WHERE \(match)",
                               [.date(date.addingTimeInterval(Self.sourceMatchDelay(attempts: task.attempts)))] + keys)
                    return false
                }
                _ = try Self.enqueueSourceOriginalStack(db, receipt: task.receipt)
                try db.run("UPDATE source_match_tasks SET state='done',not_before=NULL,reason='matched' WHERE \(match)", keys)
            case .notApplicable(let reason):
                try db.run("UPDATE source_match_tasks SET state='notApplicable',not_before=NULL,reason=? WHERE \(match)", [.text(reason)] + keys)
            case .deferred(let reason):
                let due = date.addingTimeInterval(Self.sourceMatchDelay(attempts: task.attempts))
                try db.run("UPDATE source_match_tasks SET state='pending',attempts=attempts+1,not_before=?,reason=? WHERE \(match)",
                           [.date(due), .text(reason)] + keys)
            case .failed(let reason):
                try db.run("UPDATE source_match_tasks SET state='failed',attempts=attempts+1,not_before=NULL,reason=? WHERE \(match)", [.text(reason)] + keys)
            }
            return true
        }
    }

}

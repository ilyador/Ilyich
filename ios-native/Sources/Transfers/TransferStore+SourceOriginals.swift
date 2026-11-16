import Foundation

/// A source-original match is association evidence only. It never confirms the current edit,
/// supplies its upload checksum, or creates the receipt required for device cleanup.
struct SourceOriginalAssociation: Hashable, Sendable {
    let localID: String
    let revision: AssetRevision
    let checksum: String
    let remoteID: String?
    /// PhotoKit resource snapshot revalidated before a persisted checksum is reused.
    var fingerprint: SourceOriginalFingerprint? = nil
}

extension TransferStore {
    func sourceOriginal(for localID: String, revision: AssetRevision) throws -> SourceOriginalAssociation? {
        var result: SourceOriginalAssociation?
        try database().run("SELECT checksum,remote_id,fingerprint_json FROM source_originals WHERE local_id=? AND modification_date=?",
                           [.text(localID), .real(revision.referenceSeconds)]) { row in
            if let checksum = row.text(0) {
                result = .init(localID: localID, revision: revision, checksum: checksum, remoteID: row.text(1),
                               fingerprint: row.text(2).flatMap { TransferJSON.decode(SourceOriginalFingerprint.self, $0) })
            }
        }
        return result
    }

    func forgetSourceOriginal(_ localID: String, revision: AssetRevision) throws {
        try database().run("DELETE FROM source_originals WHERE local_id=? AND modification_date=?",
                           [.text(localID), .real(revision.referenceSeconds)])
    }

    func saveSourceOriginal(_ source: SourceOriginalAssociation) throws {
        try database().run("""
            INSERT INTO source_originals(local_id,modification_date,checksum,remote_id,linked_asset_id,fingerprint_json) VALUES(?,?,?,?,NULL,?) \
            ON CONFLICT(local_id,modification_date) DO UPDATE SET checksum=excluded.checksum,remote_id=excluded.remote_id,fingerprint_json=excluded.fingerprint_json,\
            linked_asset_id=CASE WHEN source_originals.checksum=excluded.checksum AND source_originals.remote_id IS excluded.remote_id \
            THEN source_originals.linked_asset_id ELSE NULL END
            """, [.text(source.localID), .real(source.revision.referenceSeconds), .text(source.checksum), .optionalText(source.remoteID), .optionalText(source.fingerprint.map(TransferJSON.encode))])
    }

    /// Bounded paging of receipts whose exact revision remains confirmed; no discovery or jobs.
    func confirmedReceiptsForSourceMatching(after localID: String?, limit: Int) throws -> [TransferReceipt] {
        var ids: [String] = []
        try database().run("""
            SELECT r.local_id FROM receipts r JOIN confirmations c ON c.local_id=r.local_id AND c.modification_date=r.modification_date \
            WHERE r.local_id>? AND r.local_deleted_at IS NULL ORDER BY r.local_id LIMIT ?
            """, [.text(localID ?? ""), .integer(Int64(min(max(limit, 1), 100)))]) { if let id = $0.text(0) { ids.append(id) } }
        let found = try receipts(for: ids)
        return ids.compactMap { found[$0] }
    }

    /// Exact receipt CAS: a concurrent completion/deletion cannot attach a match to another edit.
    @discardableResult
    func enqueueSourceOriginalStack(ifCurrent receipt: TransferReceipt,
                                    expectedSource: SourceOriginalAssociation? = nil,
                                    permits: @Sendable () -> Bool = { true }, retryFailed: Bool = false) throws -> Bool {
        let db = try database()
        return try db.transaction {
            try Task.checkCancellation()
            guard permits() else { throw CancellationError() }
            var current = false
            try db.run("""
                SELECT 1 FROM receipts r JOIN confirmations c ON c.local_id=r.local_id AND c.modification_date=r.modification_date \
                WHERE r.local_id=? AND r.modification_date=? AND r.original_id=? AND r.original_checksum=? \
                AND r.motion_id IS ? AND r.motion_checksum IS ? AND r.local_deleted_at IS NULL
                """, [.text(receipt.localID), .real(receipt.revision.referenceSeconds), .text(receipt.original.id), .text(receipt.original.checksum),
                       .optionalText(receipt.motion?.id), .optionalText(receipt.motion?.checksum)]) { _ in current = true }
            guard current else { return false }
            if let expectedSource {
                let cached = try sourceOriginal(for: receipt.localID, revision: receipt.revision)
                guard expectedSource.localID == receipt.localID, expectedSource.revision == receipt.revision,
                      expectedSource.remoteID != nil, cached?.checksum == expectedSource.checksum,
                      cached?.remoteID == expectedSource.remoteID, cached?.fingerprint == expectedSource.fingerprint else { return false }
            }
            let scheduled = try Self.enqueueSourceOriginalStack(db, receipt: receipt, retryFailed: retryFailed)
            if retryFailed {
                try db.run("""
                    UPDATE source_match_tasks SET state='done',not_before=NULL,reason='explicitMatch' \
                    WHERE local_id=? AND modification_date=? AND current_id=? AND current_checksum=? AND motion_id IS ? AND motion_checksum IS ?
                    """, [.text(receipt.localID), .real(receipt.revision.referenceSeconds), .text(receipt.original.id), .text(receipt.original.checksum),
                           .optionalText(receipt.motion?.id), .optionalText(receipt.motion?.checksum)])
            }
            return scheduled
        }
    }

    @discardableResult
    static func enqueueSourceOriginalStack(_ db: TransferSQLite, receipt: TransferReceipt, retryFailed: Bool = false) throws -> Bool {
        var source: (id: String, checksum: String, linkedID: String?)?
        try db.run("""
            SELECT remote_id,checksum,linked_asset_id FROM source_originals WHERE local_id=? AND modification_date=? AND remote_id IS NOT NULL
            """, [.text(receipt.localID), .real(receipt.revision.referenceSeconds)]) { row in
            if let id = row.text(0), let checksum = row.text(1) { source = (id, checksum, row.text(2)) }
        }
        guard let source, source.id != receipt.original.id else { return false }
        var requeued = false
        if retryFailed {
            // Only an explicit, freshly verified source/current rematch retries a failed proof
            // task. A completed link remains remembered, preserving a later manual unstack.
            try db.run("""
                UPDATE stack_tasks SET state='pending',attempts=0,error=NULL,source_checksum=?,current_checksum=? \
                WHERE local_id=? AND asset_id=? AND previous_asset_id=? AND state='failed' \
                AND source_checksum IS NOT NULL AND current_checksum IS NOT NULL
                """, [.text(source.checksum), .text(receipt.original.checksum), .text(receipt.localID),
                       .text(receipt.original.id), .text(source.id)])
            requeued = db.changes > 0
        }
        if source.linkedID == receipt.original.id { return requeued }
        try enqueueStack(db, localID: receipt.localID, currentID: receipt.original.id, previousID: source.id,
                         sourceChecksum: source.checksum, currentChecksum: receipt.original.checksum)
        try db.run("UPDATE source_originals SET linked_asset_id=? WHERE local_id=? AND modification_date=? AND remote_id=? AND checksum=?",
                   [.text(receipt.original.id), .text(receipt.localID), .real(receipt.revision.referenceSeconds), .text(source.id), .text(source.checksum)])
        return true
    }

    static func enqueueStack(_ db: TransferSQLite, localID: String, currentID: String, previousID: String,
                             sourceChecksum: String? = nil, currentChecksum: String? = nil) throws {
        guard currentID != previousID else { return }
        try db.run("""
            INSERT INTO stack_tasks(local_id,asset_id,previous_asset_id,state,attempts,source_checksum,current_checksum) \
            SELECT ?,?,?,'pending',0,?,? WHERE NOT EXISTS(SELECT 1 FROM stack_tasks WHERE local_id=? AND asset_id=? AND previous_asset_id=?)
            """, [.text(localID), .text(currentID), .text(previousID), .optionalText(sourceChecksum), .optionalText(currentChecksum),
                   .text(localID), .text(currentID), .text(previousID)])
        if sourceChecksum != nil, currentChecksum != nil {
            try db.run("UPDATE stack_tasks SET source_checksum=?,current_checksum=? WHERE local_id=? AND asset_id=? AND previous_asset_id=?",
                       [.optionalText(sourceChecksum), .optionalText(currentChecksum), .text(localID), .text(currentID), .text(previousID)])
        }
    }
}

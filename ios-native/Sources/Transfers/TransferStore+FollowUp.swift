import Foundation

/// What the post-upload work, share jobs and notifications read and write (B4, dormant). None of it
/// ever touches a confirmation or a receipt: whatever happens after an upload, the photo stays
/// backed up.
///
/// album_destinations and stack_tasks rows are pending until their work is done, when they are
/// deleted, or failed, which only the user retries (a manual run, or Retry). attempts counts the
/// tries that failed for a reason that may pass by itself.
extension TransferStore {
    // MARK: Album destinations

    /// The albums with a destination the post-upload work can run now: pending, with the photo's
    /// server ID known.
    func albumsWithRunnableDestinations() throws -> [String] {
        var albums: [String] = []
        try database().run("""
            SELECT DISTINCT album_id FROM album_destinations WHERE state='pending' AND remote_id IS NOT NULL ORDER BY album_id
            """) { row in if let album = row.text(0) { albums.append(album) } }
        return albums
    }

    /// One album's runnable destinations after the photo `after`, in local identifier order.
    func runnableAlbumDestinations(album: String, after localID: String?, limit: Int) throws -> [AlbumDestinationRow] {
        var rows: [AlbumDestinationRow] = []
        try database().run("""
            SELECT local_id,album_id,remote_id,state,attempts,error FROM album_destinations \
            WHERE album_id=? AND state='pending' AND remote_id IS NOT NULL AND local_id>? ORDER BY local_id LIMIT ?
            """, [.text(album), .text(localID ?? ""), .integer(Int64(max(limit, 1)))]) { row in
            rows.append(AlbumDestinationRow(localID: row.text(0) ?? "", albumID: row.text(1) ?? "", remoteID: row.text(2), state: row.text(3) ?? "",
                                            attempts: Int(row.integer(4) ?? 0), error: row.text(5)))
        }
        return rows
    }

    /// Records what one album's PUT did, in one transaction. A destination done is deleted; one
    /// whose photo got another server ID meanwhile (a newer upload) is left for that ID.
    func finishAlbumDestinations(album: String, _ outcomes: [(row: AlbumDestinationRow, outcome: FollowUpOutcome)]) throws {
        let db = try database()
        try db.transaction {
            for (row, outcome) in outcomes {
                let match = "WHERE local_id=? AND album_id=? AND state='pending' AND remote_id IS ?"
                let keys: [TransferSQLite.Value] = [.text(row.localID), .text(album), .optionalText(row.remoteID)]
                switch outcome {
                case .done:
                    try db.run("DELETE FROM album_destinations \(match)", keys)
                case .retry(let message):
                    try db.run("UPDATE album_destinations SET attempts=attempts+1,error=? \(match)", [.optionalText(message)] + keys)
                case .failed(let message):
                    try db.run("UPDATE album_destinations SET state='failed',attempts=attempts+1,error=? \(match)", [.text(message)] + keys)
                }
            }
        }
    }

    /// Destinations that failed, by album: those only the user can retry.
    func failedAlbumDestinationCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        try database().run("SELECT album_id,count(*) FROM album_destinations WHERE state='failed' GROUP BY album_id") { row in
            if let album = row.text(0) { counts[album] = Int(row.integer(1) ?? 0) }
        }
        return counts
    }

    /// Every album destination, for tests and diagnostics.
    func albumDestinations() throws -> [AlbumDestinationRow] {
        var rows: [AlbumDestinationRow] = []
        try database().run("SELECT local_id,album_id,remote_id,state,attempts,error FROM album_destinations ORDER BY album_id,local_id") { row in
            rows.append(AlbumDestinationRow(localID: row.text(0) ?? "", albumID: row.text(1) ?? "", remoteID: row.text(2), state: row.text(3) ?? "",
                                            attempts: Int(row.integer(4) ?? 0), error: row.text(5)))
        }
        return rows
    }

    // MARK: Stacks

    /// Stack tasks waiting to run, oldest first.
    func pendingStackTasks(limit: Int = 500) throws -> [StackTaskRow] {
        try stackTasks(where: "state='pending'", limit: limit)
    }

    /// Every stack task, for tests and diagnostics.
    func stackTasks() throws -> [StackTaskRow] { try stackTasks(where: "1", limit: Int.max) }

    private func stackTasks(where condition: String, limit: Int) throws -> [StackTaskRow] {
        var rows: [StackTaskRow] = []
        try database().run("""
            SELECT id,local_id,asset_id,previous_asset_id,state,attempts,error FROM stack_tasks WHERE \(condition) ORDER BY id LIMIT ?
            """, [.integer(Int64(min(max(limit, 1), Int(Int64.max))))]) { row in
            rows.append(StackTaskRow(id: row.integer(0) ?? 0, localID: row.text(1) ?? "", assetID: row.text(2) ?? "",
                                     previousAssetID: row.text(3) ?? "", state: row.text(4) ?? "", attempts: Int(row.integer(5) ?? 0),
                                     error: row.text(6)))
        }
        return rows
    }

    func finishStackTask(_ id: Int64, _ outcome: FollowUpOutcome) throws {
        let db = try database()
        switch outcome {
        case .done:
            try db.run("DELETE FROM stack_tasks WHERE id=? AND state='pending'", [.integer(id)])
        case .retry(let message):
            try db.run("UPDATE stack_tasks SET attempts=attempts+1,error=? WHERE id=? AND state='pending'", [.optionalText(message), .integer(id)])
        case .failed(let message):
            try db.run("UPDATE stack_tasks SET state='failed',attempts=attempts+1,error=? WHERE id=? AND state='pending'",
                       [.text(message), .integer(id)])
        }
    }

    /// The user retries: failed album destinations and stack tasks are pending again.
    @discardableResult
    func requeueFailedFollowUps() throws -> Int {
        let db = try database()
        return try db.transaction {
            try db.run("UPDATE album_destinations SET state='pending',attempts=0,error=NULL WHERE state='failed'")
            var changed = db.changes
            try db.run("UPDATE stack_tasks SET state='pending',attempts=0,error=NULL WHERE state='failed'")
            changed += db.changes
            return changed
        }
    }

    // MARK: Linked albums

    /// The server album each phone album syncs to, by phone album ID.
    func linkedAlbums() throws -> [String: String] {
        var linked: [String: String] = [:]
        try database().run("SELECT device_album_id,album_id FROM linked_albums") { row in
            if let device = row.text(0), let album = row.text(1) { linked[device] = album }
        }
        return linked
    }

    func linkAlbum(device: String, to album: String) throws {
        try database().run("INSERT OR REPLACE INTO linked_albums(device_album_id,album_id) VALUES(?,?)", [.text(device), .text(album)])
    }

    // MARK: Shares

    /// Attachments whose upload committed, by batch, whose manifest may still list them.
    func consumedShares() throws -> [ConsumedShare] {
        var rows: [ConsumedShare] = []
        try database().run("SELECT batch_id,attachment,remote_id FROM share_consumed ORDER BY consumed_at,batch_id,attachment") { row in
            guard let batch = row.text(0).flatMap(UUID.init(uuidString:)), let attachment = row.text(1) else { return }
            rows.append(ConsumedShare(batch: batch, attachment: attachment, remoteID: row.text(2)))
        }
        return rows
    }

    /// The manifest no longer lists the attachment: its record can go.
    func forgetConsumedShare(batch: UUID, attachment: String) throws {
        try database().run("DELETE FROM share_consumed WHERE batch_id=? AND attachment=?", [.text(batch.uuidString), .text(attachment)])
    }

    /// Share jobs a process that ended left with the transport go back to staged, so the next
    /// lease resumes them: an outcome on disk is applied, and a task iOS still holds is adopted
    /// rather than sent again. Leased jobs are the engine's.
    @discardableResult
    func resumeShareJobs() throws -> Int {
        let db = try database()
        try db.run("""
            UPDATE jobs SET state='staged' WHERE lane='share' AND lease_token IS NULL AND state IN ('submitting','submitted','finalizing')
            """)
        return db.changes
    }

    // MARK: Notification batches

    /// Every notification batch with how many of its jobs are still to run and how many failed.
    func notificationBatches() throws -> [NotificationBatchState] {
        var batches: [NotificationBatchState] = []
        try database().run("""
            SELECT n.id,n.kind,n.total,n.completed,n.failed,n.started_posted,n.terminal_posted,\
            (SELECT count(*) FROM jobs j WHERE j.batch_id=n.id AND j.state<>'failed'),\
            (SELECT count(*) FROM jobs j WHERE j.batch_id=n.id AND j.state='failed') FROM notification_batches n ORDER BY n.rowid
            """) { row in
            guard let id = row.text(0).flatMap(UUID.init(uuidString:)) else { return }
            batches.append(NotificationBatchState(id: id, kind: row.text(1).flatMap(NotificationBatchKind.init(rawValue:)) ?? .backup,
                                                  total: Int(row.integer(2) ?? 0), completed: Int(row.integer(3) ?? 0),
                                                  recordedFailures: row.integer(4).map(Int.init), startedPosted: row.integer(5) == 1,
                                                  terminalPosted: row.integer(6) == 1, remaining: Int(row.integer(7) ?? 0),
                                                  failedJobs: Int(row.integer(8) ?? 0)))
        }
        return batches
    }

    /// The batch's started notification went out.
    func markStartedPosted(_ id: UUID) throws {
        try database().run("UPDATE notification_batches SET started_posted=1 WHERE id=?", [.text(id.uuidString)])
    }

    /// The batch's last notification went out, with these failures: it is never posted again.
    func markTerminalPosted(_ id: UUID, failed: Int) throws {
        try database().run("UPDATE notification_batches SET started_posted=1,terminal_posted=1,failed=? WHERE id=?",
                           [.integer(Int64(failed)), .text(id.uuidString)])
    }

    /// Batches whose last notification went out and that no job counts in any more.
    @discardableResult
    func pruneNotificationBatches() throws -> Int {
        let db = try database()
        try db.run("""
            DELETE FROM notification_batches WHERE terminal_posted=1 AND NOT EXISTS(SELECT 1 FROM jobs j WHERE j.batch_id=notification_batches.id)
            """)
        return db.changes
    }
}

/// What one try of a follow-up did.
enum FollowUpOutcome: Hashable, Sendable {
    case done
    /// It may work later by itself; the message says why it didn't now.
    case retry(String?)
    /// Only the user can retry it.
    case failed(String)
}

struct StackTaskRow: Hashable, Sendable {
    let id: Int64
    let localID: String
    /// The new upload, which goes on top.
    let assetID: String
    /// The server copy of the photo's earlier version.
    let previousAssetID: String
    let state: String
    let attempts: Int
    let error: String?
}

struct ConsumedShare: Hashable, Sendable {
    let batch: UUID
    let attachment: String
    let remoteID: String?
}

/// notification_batches.kind.
enum NotificationBatchKind: String, Hashable, Sendable {
    case backup, share

    init(_ lane: TransferLane) { self = lane == .library ? .backup : .share }

    /// The words the notifications use, as today's.
    var title: String {
        switch self {
        case .backup: "Backup"
        case .share: "Shared upload"
        }
    }
}

/// A notification batch as the notifier reads it.
struct NotificationBatchState: Hashable, Sendable {
    let id: UUID
    let kind: NotificationBatchKind
    let total: Int
    let completed: Int
    /// The failures recorded when its last notification was due, which a legacy import carries
    /// for a run that ended before its notification went out.
    let recordedFailures: Int?
    let startedPosted: Bool
    let terminalPosted: Bool
    /// Its jobs still to run, and those that failed.
    let remaining: Int
    let failedJobs: Int

    /// Nothing of it runs any more: what is left failed, or was cancelled.
    var isFinished: Bool { remaining == 0 }
}

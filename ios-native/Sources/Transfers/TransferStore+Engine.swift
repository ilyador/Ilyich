import Foundation

/// What the transfer engine reads and writes (B2, dormant). Every change to a leased job applies
/// only while its lease token still matches, so a stale lease never changes anything (BM12).
///
/// Error fields keep what the job last met: error_class is transient (a retry is scheduled),
/// waiting (error_message names the condition) or item (only the user retries it).
extension TransferStore {
    // MARK: Ownership

    /// Hands a fresh database to the transfer engine: one no import ever wrote. A database holding
    /// a shadow copy of state.json stays BackupCoordinator's, since the next shadow import would
    /// replace what the engine wrote; B9 hands it over with an authoritative import instead.
    /// Returns whether the engine owns the database now.
    @discardableResult
    func claimForEngine() throws -> Bool {
        let db = try database()
        try db.run("UPDATE meta SET engine=? WHERE id=1 AND legacy_import_digest IS NULL", [.text(Engine.transfer.rawValue)])
        return try meta().engine == .transfer
    }

    // MARK: Engine state

    func engineState() throws -> EngineStateRow? {
        var state: EngineStateRow?
        try database().run("SELECT intent,blocker,last_message FROM engine_state WHERE id=1") { row in
            state = EngineStateRow(intent: row.text(0).flatMap(RunIntent.init(rawValue:)), blocker: row.text(1), lastMessage: row.text(2))
        }
        return state
    }

    func saveEngineState(intent: RunIntent, blocker: AccountRestriction?, lastMessage: String?) throws {
        try database().run("""
            INSERT INTO engine_state(id,intent,blocker,last_message) VALUES(1,?,?,?) \
            ON CONFLICT(id) DO UPDATE SET intent=excluded.intent,blocker=excluded.blocker,last_message=excluded.last_message
            """, [.text(intent.rawValue), .optionalText(blocker?.storedValue), .optionalText(lastMessage)])
    }

    func preferences() throws -> TransferPreferences? {
        var preferences: TransferPreferences?
        try database().run("SELECT json FROM preferences WHERE id=1") { row in
            preferences = row.text(0).flatMap { TransferJSON.decode(TransferPreferences.self, $0) }
        }
        return preferences
    }

    func savePreferences(_ preferences: TransferPreferences) throws {
        try database().run("INSERT INTO preferences(id,json) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
                           [.text(TransferJSON.encode(preferences))])
    }

    // MARK: Jobs

    /// Adds a job for each request not already queued, after the lane's last. A photo whose
    /// confirmation has the same revision is already backed up and gets none; a shared file
    /// already consumed (its upload committed, its manifest not yet rewritten) gets none either.
    /// A request with an album adds the album to the photo's destinations (B4): one already
    /// backed up joins it with the server ID of its receipt for that revision, the rest once their
    /// upload commits. A job
    /// with a notification batch counts in the batch's total.
    func enqueue(_ requests: [TransferRequest]) throws -> (queued: Int, alreadyBackedUp: Int) {
        let db = try database()
        return try db.transaction {
            var queued = 0, backedUp = 0
            var seqs: [TransferLane: Int64] = [:]
            for request in requests {
                let album = request.album.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
                if case .photo(let id) = request.source, let revision = request.revision {
                    var confirmed = false
                    try db.run("SELECT 1 FROM confirmations WHERE local_id=? AND modification_date=?",
                               [.text(id.rawValue), .real(revision.referenceSeconds)]) { _ in confirmed = true }
                    if confirmed {
                        // Only a receipt of the confirmed revision names its server copy: an older
                        // one, left when the latest upload committed without a receipt, names the
                        // copy from before an edit.
                        var remoteID: String?
                        try db.run("SELECT original_id FROM receipts WHERE local_id=? AND modification_date=?",
                                   [.text(id.rawValue), .real(revision.referenceSeconds)]) { remoteID = $0.text(0) }
                        // Confirmed without a receipt of this revision (a legacy Live Photo, a
                        // commit without its checksum): the server ID comes from uploading again,
                        // which the duplicate check answers.
                        if album == nil || remoteID != nil {
                            if let album { try Self.addDestination(db, localID: id.rawValue, album: album, remoteID: remoteID) }
                            backedUp += 1
                            continue
                        }
                    }
                }
                if case .shared(let batch, let attachment) = request.source {
                    var consumed = false
                    try db.run("SELECT 1 FROM share_consumed WHERE batch_id=? AND attachment=?",
                               [.text(batch.uuidString), .text(attachment)]) { _ in consumed = true }
                    if consumed { backedUp += 1; continue }
                }
                let lane = request.source.lane
                if seqs[lane] == nil {
                    var last: Int64 = -1
                    try db.run("SELECT max(seq) FROM jobs WHERE lane=?", [.text(lane.rawValue)]) { last = $0.integer(0) ?? -1 }
                    seqs[lane] = last
                }
                let seq = seqs[lane]! + 1
                try db.run("""
                    INSERT OR IGNORE INTO jobs(lane,source_key,origin,state,seq,retry_count,display_name,batch_id) VALUES(?,?,?,?,?,0,?,?)
                    """, [.text(lane.rawValue), .text(request.source.key), .text(request.origin.rawValue), .text(JobState.queued.rawValue),
                          .integer(seq), .optionalText(request.displayName), .optionalText(request.batch?.uuidString)])
                if db.changes > 0 {
                    queued += 1
                    seqs[lane] = seq
                    if let batch = request.batch {
                        // A batch whose last notification went out starts over (reopenNotificationBatch).
                        try db.run("""
                            INSERT INTO notification_batches(id,kind,total) VALUES(?,?,1) ON CONFLICT(id) DO UPDATE SET total=total+1,\
                            started_posted=CASE WHEN terminal_posted=1 THEN 0 ELSE started_posted END,\
                            failed=CASE WHEN terminal_posted=1 THEN NULL ELSE failed END,terminal_posted=0
                            """, [.text(batch.uuidString), .text(NotificationBatchKind(lane).rawValue)])
                    }
                }
                if let album, case .photo(let id) = request.source {
                    try Self.addDestination(db, localID: id.rawValue, album: album, remoteID: nil)
                }
            }
            return (queued, backedUp)
        }
    }

    /// The photo is to join the album: pending, with the server ID when it is known. A destination
    /// that failed is tried again; a pending one keeps the server ID it has.
    private static func addDestination(_ db: TransferSQLite, localID: String, album: String, remoteID: String?) throws {
        try db.run("""
            INSERT INTO album_destinations(local_id,album_id,remote_id,state,attempts,error) VALUES(?,?,?,'pending',0,NULL) \
            ON CONFLICT(local_id,album_id) DO UPDATE SET state='pending',attempts=0,error=NULL,remote_id=coalesce(remote_id,excluded.remote_id)
            """, [.text(localID), .text(album), .optionalText(remoteID)])
    }

    /// Drops the leases a process that ended held. A job keeps its state and phase, so the next
    /// lease resumes it where it was.
    @discardableResult
    func releaseAllLeases() throws -> Int {
        let db = try database()
        try db.run("UPDATE jobs SET lease_token=NULL,lease_epoch=NULL WHERE lease_token IS NOT NULL")
        return db.changes
    }

    /// Leases the lane's next runnable job: the first in order that no lease holds and that is
    /// queued, interrupted part way (its state kept), or due for its retry. A job submitted to
    /// the transport waits for its outcome; a waiting or failed one waits for an event or the user.
    func reserve(lane: TransferLane, now: Date, token: UUID, epoch: UInt64) throws -> StoredJob? {
        let db = try database()
        return try db.transaction {
            var job: StoredJob?
            try db.run("""
                SELECT \(Self.jobColumns) FROM jobs WHERE lane=? AND lease_token IS NULL AND \
                (state IN ('queued','staging','staged','submitting','finalizing') OR (state='retryScheduled' AND (not_before IS NULL OR not_before<=?))) \
                ORDER BY seq,id LIMIT 1
                """, [.text(lane.rawValue), .date(now)]) { job = Self.storedJob($0) }
            guard let found = job else { return nil }
            try db.run("UPDATE jobs SET lease_token=?,lease_epoch=? WHERE id=? AND lease_token IS NULL",
                       [.text(token.uuidString), .integer(Int64(bitPattern: epoch)), .integer(found.id)])
            return db.changes == 1 ? found : nil
        }
    }

    /// When the earliest retry of these lanes falls due, if one is scheduled.
    func nextRetry(lanes: [TransferLane]) throws -> Date? {
        var due: Date?
        try database().run("""
            SELECT min(not_before) FROM jobs WHERE state='retryScheduled' AND lease_token IS NULL AND lane IN (SELECT value FROM json_each(?))
            """, [.text(TransferJSON.encode(lanes.map(\.rawValue)))]) { due = $0.date(0) }
        return due
    }

    /// The leased job reached `state`; nil keeps its phase.
    func advance(job: Int64, token: UUID, to state: JobState, phase: String?) throws -> Bool {
        let db = try database()
        try db.run("UPDATE jobs SET state=?,phase=coalesce(?,phase) WHERE id=? AND lease_token=?",
                   [.text(state.rawValue), .optionalText(phase), .integer(job), .text(token.uuidString)])
        return db.changes == 1
    }

    /// Gives the job back, as it is, for a later lease.
    @discardableResult
    func release(job: Int64, token: UUID) throws -> Bool {
        let db = try database()
        try db.run("UPDATE jobs SET lease_token=NULL,lease_epoch=NULL WHERE id=? AND lease_token=?", [.integer(job), .text(token.uuidString)])
        return db.changes == 1
    }

    /// A transient failure: the job runs again from `notBefore` as retryScheduled. Its phase and
    /// stage rows stay, so the next lease resumes from them.
    func scheduleRetry(job: Int64, token: UUID, notBefore: Date, message: String?, at date: Date) throws -> Bool {
        let db = try database()
        try db.run("""
            UPDATE jobs SET state='retryScheduled',not_before=?,retry_count=retry_count+1,error_class='transient',error_message=?,error_at=?,\
            lease_token=NULL,lease_epoch=NULL WHERE id=? AND lease_token=?
            """, [.date(notBefore), .optionalText(message), .date(date), .integer(job), .text(token.uuidString)])
        return db.changes == 1
    }

    /// Only this job waits, for `reason`, until a condition changes. Its phase and stage rows stay.
    func markWaiting(job: Int64, token: UUID, reason: WaitReason, at date: Date) throws -> Bool {
        let db = try database()
        try db.run("""
            UPDATE jobs SET state='waiting',error_class='waiting',error_message=?,error_at=?,lease_token=NULL,lease_epoch=NULL \
            WHERE id=? AND lease_token=?
            """, [.text(reason.storedValue), .date(date), .integer(job), .text(token.uuidString)])
        return db.changes == 1
    }

    /// An item failure, which only the user retries.
    func markFailed(job: Int64, token: UUID, message: String, at date: Date) throws -> Bool {
        let db = try database()
        try db.run("""
            UPDATE jobs SET state='failed',error_class='item',error_message=?,error_at=?,not_before=NULL,lease_token=NULL,lease_epoch=NULL \
            WHERE id=? AND lease_token=?
            """, [.text(message), .date(date), .integer(job), .text(token.uuidString)])
        return db.changes == 1
    }

    /// A condition changed: every waiting job is queued again.
    @discardableResult
    func requeueWaiting() throws -> Int {
        let db = try database()
        try db.run("""
            UPDATE jobs SET state='queued',error_class=NULL,error_message=NULL,error_at=NULL WHERE state='waiting' AND lease_token IS NULL
            """)
        return db.changes
    }

    /// The user retries failed jobs of a lane: those named, or all of them for nil. Their retry
    /// counts start again. A library job starts again from staging: its stage is dropped, as the
    /// photo may have changed since, or its files may be what failed. The files are left for the
    /// staging sweep (B6).
    @discardableResult
    func requeueFailed(lane: TransferLane, sourceKeys: [String]? = nil) throws -> Int {
        let db = try database()
        return try db.transaction {
            var match = "SELECT id FROM jobs WHERE lane=? AND state='failed' AND lease_token IS NULL"
            var arguments: [TransferSQLite.Value] = [.text(lane.rawValue)]
            if let sourceKeys {
                match += " AND source_key IN (SELECT value FROM json_each(?))"
                arguments.append(.text(TransferJSON.encode(sourceKeys)))
            }
            if lane == .library { try Self.dropStages(db, ofJobsIn: match, arguments) }
            try Self.reopenNotificationBatches(db, ofJobsIn: match, arguments)
            try db.run("""
                UPDATE jobs SET state='queued',retry_count=0,not_before=NULL,error_class=NULL,error_message=NULL,error_at=NULL \
                WHERE id IN (\(match))
                """, arguments)
            return db.changes
        }
    }

    /// Removes jobs, with their stage and attempt rows, whatever lease holds them. Their files are
    /// left for the staging sweep (B6).
    @discardableResult
    func removeJobs(lane: TransferLane, sourceKeys: [String]) throws -> Int {
        let db = try database()
        return try db.transaction {
            let keys = TransferJSON.encode(sourceKeys)
            let match = "SELECT id FROM jobs WHERE lane=? AND source_key IN (SELECT value FROM json_each(?))"
            try db.run("DELETE FROM attempts WHERE job_id IN (\(match))", [.text(lane.rawValue), .text(keys)])
            try db.run("DELETE FROM stages WHERE job_id IN (\(match))", [.text(lane.rawValue), .text(keys)])
            try db.run("DELETE FROM jobs WHERE lane=? AND source_key IN (SELECT value FROM json_each(?))", [.text(lane.rawValue), .text(keys)])
            return db.changes
        }
    }

    /// Commits a finished share job while its lease holds: the job goes, its attachment is
    /// recorded as consumed and its notification batch counts it, in one transaction. The
    /// manifest is rewritten after the commit (ShareJobExecutor.committed), and again from
    /// share_consumed if the app ended first.
    func completeShare(job: Int64, token: UUID, batch: UUID, attachment: String, remoteID: String?, at date: Date) throws -> Bool {
        let db = try database()
        return try db.transaction {
            var found = false
            var notification: String?
            try db.run("SELECT batch_id FROM jobs WHERE id=? AND lane='share' AND lease_token=?", [.integer(job), .text(token.uuidString)]) { row in
                found = true
                notification = row.text(0)
            }
            guard found else { return false }
            if let notification {
                try db.run("UPDATE notification_batches SET completed=completed+1 WHERE id=?", [.text(notification)])
            }
            try db.run("DELETE FROM attempts WHERE job_id=?", [.integer(job)])
            try db.run("DELETE FROM stages WHERE job_id=?", [.integer(job)])
            try db.run("DELETE FROM jobs WHERE id=?", [.integer(job)])
            try db.run("INSERT OR REPLACE INTO share_consumed(batch_id,attachment,remote_id,consumed_at) VALUES(?,?,?,?)",
                       [.text(batch.uuidString), .text(attachment), .optionalText(remoteID), .date(date)])
            return true
        }
    }

    /// One job, as it is now.
    func job(lane: TransferLane, sourceKey: String) throws -> StoredJob? {
        var job: StoredJob?
        try database().run("SELECT \(Self.jobColumns) FROM jobs WHERE lane=? AND source_key=?",
                           [.text(lane.rawValue), .text(sourceKey)]) { job = Self.storedJob($0) }
        return job
    }

    /// Whether a job's part is with the transport, waiting for its answer: the background session
    /// carries it on whether or not the app runs.
    func hasSubmittedJobs() throws -> Bool {
        var found = false
        try database().run("SELECT EXISTS(SELECT 1 FROM jobs WHERE state='submitted')") { found = ($0.integer(0) ?? 0) != 0 }
        return found
    }

    // MARK: Pages and counts

    /// The library lane's counts for the snapshot: jobs left, jobs failed and photos confirmed.
    func counts() throws -> TransferCounts {
        let db = try database()
        var counts = TransferCounts()
        try db.run("SELECT count(*) FROM jobs WHERE lane='library' AND state<>'failed'") { counts.remaining = Int($0.integer(0) ?? 0) }
        try db.run("SELECT count(*) FROM jobs WHERE lane='library' AND state='failed'") { counts.failed = Int($0.integer(0) ?? 0) }
        try db.run("SELECT count(*) FROM confirmations") { counts.confirmed = Int($0.integer(0) ?? 0) }
        return counts
    }

    /// A lane's jobs that are not failed, in order, after the job whose seq is `after`.
    func queuePage(lane: TransferLane, after seq: Int64?, limit: Int) throws -> [TransferQueueItem] {
        var page: [TransferQueueItem] = []
        try database().run("""
            SELECT \(Self.jobColumns) FROM jobs WHERE lane=? AND state<>'failed' AND seq>? ORDER BY seq,id LIMIT ?
            """, [.text(lane.rawValue), .integer(seq ?? -1), .integer(Int64(max(limit, 1)))]) { row in
            if let job = Self.storedJob(row) { page.append(job.item) }
        }
        return page
    }

    /// Failed jobs of both lanes, the latest failure first.
    func failures(limit: Int) throws -> [TransferQueueItem] {
        var page: [TransferQueueItem] = []
        try database().run("SELECT \(Self.jobColumns) FROM jobs WHERE state='failed' ORDER BY error_at DESC,id LIMIT ?",
                           [.integer(Int64(max(limit, 1)))]) { row in
            if let job = Self.storedJob(row) { page.append(job.item) }
        }
        return page
    }

    /// Confirmed photos, the latest first. A confirmation imported from state.json, which kept no
    /// time, takes its receipt's, as the confirmed uploads screen always ordered them; those with
    /// neither come last.
    func historyPage(offset: Int, limit: Int) throws -> [TransferHistoryItem] {
        var page: [TransferHistoryItem] = []
        try database().run("""
            SELECT c.local_id,coalesce(c.confirmed_at,r.confirmed_at) AS at FROM confirmations c LEFT JOIN receipts r ON r.local_id=c.local_id \
            ORDER BY at IS NULL,at DESC,c.local_id LIMIT ? OFFSET ?
            """, [.integer(Int64(max(limit, 1))), .integer(Int64(max(offset, 0)))]) { row in
            page.append(TransferHistoryItem(localID: DeviceAssetID(rawValue: row.text(0) ?? ""), confirmedAt: row.date(1)))
        }
        return page
    }

    /// Photos still to be added to each album, by album ID, and how many of them failed: their backup job, or
    /// the album add itself (B4), which waits for the user's retry.
    func albumUploadCounts() throws -> [String: AlbumUploadCount] {
        var counts: [String: AlbumUploadCount] = [:]
        try database().run("""
            SELECT d.album_id,count(*),sum(CASE WHEN d.state='failed' OR j.state='failed' THEN 1 ELSE 0 END) FROM album_destinations d \
            LEFT JOIN jobs j ON j.lane='library' AND j.source_key=d.local_id WHERE d.state IN ('pending','failed') GROUP BY d.album_id
            """) { row in
            if let album = row.text(0) { counts[album] = AlbumUploadCount(pending: Int(row.integer(1) ?? 0), failed: Int(row.integer(2) ?? 0)) }
        }
        return counts
    }

    // MARK: Rows

    static let jobColumns = "id,lane,source_key,origin,state,phase,retry_count,batch_id,display_name,error_class,error_message,error_at,seq"

    static func storedJob(_ row: TransferSQLite.Row) -> StoredJob? {
        guard let id = row.integer(0), let lane = row.text(1).flatMap(TransferLane.init(rawValue:)),
              let source = row.text(2).flatMap({ TransferSource(lane: lane, key: $0) }),
              let state = row.text(4).flatMap(JobState.init(rawValue:)) else { return nil }
        return StoredJob(id: id, lane: lane, source: source, origin: row.text(3).flatMap(JobOrigin.init(rawValue:)) ?? .legacy, state: state,
                         phase: row.text(5), retryCount: Int(row.integer(6) ?? 0), batch: row.text(7).flatMap(UUID.init(uuidString:)),
                         displayName: row.text(8), errorClass: row.text(9), errorMessage: row.text(10), errorAt: row.date(11), seq: row.integer(12) ?? 0)
    }
}

/// A job as the transfers database holds it.
struct StoredJob: Hashable, Sendable {
    let id: Int64
    let lane: TransferLane
    let source: TransferSource
    let origin: JobOrigin
    let state: JobState
    /// The executor's own note of where it got to, kept across leases.
    let phase: String?
    let retryCount: Int
    let batch: UUID?
    let displayName: String?
    let errorClass: String?
    let errorMessage: String?
    let errorAt: Date?
    let seq: Int64

    var item: TransferQueueItem {
        TransferQueueItem(source: source, state: state, seq: seq, displayName: displayName,
                          message: errorClass == "waiting" ? nil : errorMessage, failedAt: state == .failed ? errorAt : nil)
    }
}

struct TransferCounts: Hashable, Sendable {
    var remaining = 0
    var failed = 0
    var confirmed = 0
}

extension TransferSource {
    var lane: TransferLane {
        switch self {
        case .photo: .library
        case .shared: .share
        }
    }

    /// The jobs table's source_key: a photo's local identifier, or a share batch and attachment.
    var key: String {
        switch self {
        case .photo(let id): id.rawValue
        case .shared(let batch, let attachment): batch.uuidString + "/" + attachment
        }
    }

    init?(lane: TransferLane, key: String) {
        switch lane {
        case .library:
            self = .photo(DeviceAssetID(rawValue: key))
        case .share:
            guard let slash = key.firstIndex(of: "/"), let batch = UUID(uuidString: String(key[..<slash])) else { return nil }
            self = .shared(batch: batch, attachment: String(key[key.index(after: slash)...]))
        }
    }
}

extension AccountRestriction {
    /// engine_state.blocker.
    var storedValue: String {
        switch self {
        case .signedOut: "signedOut"
        case .sessionExpired: "sessionExpired"
        case .proxyRejected: "proxyRejected"
        case .readOnly: "readOnly"
        case .passwordChange: "passwordChange"
        case .photosAccess: "photosAccess"
        case .deviceStorage: "deviceStorage"
        }
    }

    init?(storedValue: String) {
        let all: [AccountRestriction] = [.signedOut, .sessionExpired, .proxyRejected, .readOnly, .passwordChange, .photosAccess, .deviceStorage]
        guard let match = all.first(where: { $0.storedValue == storedValue }) else { return nil }
        self = match
    }
}

extension WaitReason {
    var storedValue: String {
        switch self {
        case .deviceConditions: "deviceConditions"
        case .unmeteredNetwork: "unmeteredNetwork"
        case .connectivity: "connectivity"
        case .serverBackoff: "serverBackoff"
        }
    }
}

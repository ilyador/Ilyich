import Foundation
import IlyichPlatform
import SQLite3

/// The account's transfers database (architecture section 3):
/// Application Support/IlyichTransfers/<digest>.sqlite, in the app's private container so that no
/// lock of it is ever held in the App Group when iOS suspends the app, excluded from iCloud backup
/// and readable after the first unlock. It runs on a queue of its own and opens on first use.
///
/// Until the cutover (B9) it is a shadow copy: LegacyBackupImporter rebuilds the library lane from
/// state.json, which BackupCoordinator still runs from. Nothing else writes it yet.
///
/// Tables:
/// - meta: schema, engine (legacy while BackupCoordinator is authoritative, transfer once this
///   database is), the digest, mode and time of the last import of state.json, and the comparison
///   made after it;
/// - preferences(id=1, json): TransferPreferences;
/// - engine_state(id=1): the run intent, an account blocker and the last message;
/// - jobs: one per photo to upload, in seq order, UNIQUE(lane, source_key). The library lane's
///   source key is the photo's local identifier. Error fields hold the last item failure: its
///   class, message, time and the file name shown with it;
/// - stages: files staged for a job, in the App Group, paths relative to it. A suspended stage was
///   kept after a failed attempt because part of it already reached the server;
/// - attempts: one upload of a part, named by its attempt ID, which for a legacy stage is the stage
///   ID that already names its body, outcome file and background task;
/// - confirmations and receipts: what was backed up, keyed by local identifier;
/// - album_destinations: albums a backed-up photo still has to join, runnable once remote_id is
///   known; stack_tasks; linked_albums; share_consumed; notification_batches.
///
/// Dates are seconds since 2001 (timeIntervalSinceReferenceDate) bound as doubles. Their columns
/// are declared without a type: a REAL column stores -0.0 as 0, and every date must come back
/// bit for bit (BM2).
actor TransferStore: ReceiptQuery {
    static let schemaVersion = 1

    /// Who the records serve: BackupCoordinator, of which this database is a copy, or the transfer
    /// engine, which owns it from B9 on.
    enum Engine: String, Sendable {
        case legacy, transfer
    }

    /// The account's database: Application Support/IlyichTransfers/<digest>.sqlite, or
    /// <directory>/<digest>.sqlite for a test.
    static func url(for account: AccountID, in directory: URL? = nil) -> URL {
        if let directory { return directory.appendingPathComponent(account.digest + ".sqlite", isDirectory: false) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AccountStoragePaths(account).transfersDatabase, isDirectory: false)
    }

    private nonisolated let queue = DispatchSerialQueue(label: "app.ilyich.transfers", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    nonisolated let url: URL
    private var connection: TransferSQLite?
    private var isClosed = false

    init(url: URL) { self.url = url }

    /// Closes the database when the account's runtime ends. Later calls fail.
    func close() {
        isClosed = true
        connection?.close()
        connection = nil
    }

    /// Statements this store has run, and how many of them ran on the main thread: none should.
    func statistics() -> (statements: Int, onMainThread: Int) {
        (connection?.statements ?? 0, connection?.statementsOnMainThread ?? 0)
    }

    // MARK: - Meta

    func meta() throws -> TransferMeta {
        let db = try database()
        var meta = TransferMeta(schema: Self.schemaVersion, engine: .legacy)
        try db.run("SELECT schema,engine,legacy_import_digest,legacy_import_mode,legacy_imported_at,legacy_report_digest,legacy_report FROM meta WHERE id=1") { row in
            meta = TransferMeta(schema: Int(row.integer(0) ?? 0), engine: row.text(1).flatMap(Engine.init(rawValue:)) ?? .legacy,
                                legacyImportDigest: row.text(2), legacyImportMode: row.text(3).flatMap(LegacyBackupImporter.Mode.init(rawValue:)),
                                legacyImportedAt: row.date(4), legacyReportDigest: row.text(5), legacyReport: row.text(6))
        }
        return meta
    }

    /// Keeps the comparison made of the state.json whose digest is `digest`, for the next launch.
    func saveLegacyReport(_ report: String, digest: String) throws {
        try database().run("UPDATE meta SET legacy_report_digest=?,legacy_report=? WHERE id=1", [.text(digest), .text(report)])
    }

    // MARK: - Legacy import

    /// Replaces the library lane's records with what `plan` says, and records `digest` with them,
    /// in one transaction (BM1): a crash before the commit leaves the database as it was, and one
    /// after it leaves a complete import that the same digest finds again. The share lane is left
    /// alone. An authoritative import hands the database to the transfer engine in the same
    /// transaction. `crash` simulates the app ending at a point, for tests.
    func replace(with plan: LegacyBackupPlan, digest: String, mode: LegacyBackupImporter.Mode, at date: Date,
                 crashingAt crash: LegacyImportCrashPoint? = nil) throws {
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
                """, [.text(digest), .text(mode.rawValue), .date(date), .text((mode == .authoritative ? Engine.transfer : .legacy).rawValue)])
            try Task.checkCancellation()
            try stop(.beforeCommit)
        }
        // A rebuild passes every row through the log; give its space back.
        try? db.run("PRAGMA wal_checkpoint(TRUNCATE)")
        try stop(.afterCommit)
    }

    /// Everything the library lane holds, for comparing it with state.json. Jobs come in seq
    /// order; everything else in key order.
    func contents() throws -> TransferStoreContents {
        let db = try database()
        var contents = TransferStoreContents()
        try db.run("SELECT json FROM preferences WHERE id=1") { row in
            contents.preferences = row.text(0).flatMap { TransferJSON.decode(TransferPreferences.self, $0) }
        }
        try db.run("SELECT intent,blocker,last_message FROM engine_state WHERE id=1") { row in
            contents.engine = EngineStateRow(intent: row.text(0).flatMap(RunIntent.init(rawValue:)), blocker: row.text(1), lastMessage: row.text(2))
        }
        try db.run("""
            SELECT id,source_key,origin,state,seq,error_class,error_message,error_at,display_name,batch_id FROM jobs WHERE lane='library' ORDER BY seq,id
            """) { row in
            contents.jobs.append(TransferJobRow(id: row.integer(0) ?? 0, sourceKey: row.text(1) ?? "", origin: row.text(2) ?? "", state: row.text(3) ?? "",
                                                seq: row.integer(4) ?? 0, errorClass: row.text(5), errorMessage: row.text(6), errorAt: row.real(7),
                                                displayName: row.text(8), batchID: row.text(9)))
        }
        try db.run("""
            SELECT s.stage_id,s.job_id,s.folder,s.modification_date,s.original_json,s.motion_json,s.sidecar_json,s.fields_json,s.is_video,\
            s.motion_remote_id,s.motion_checksum,s.original_checksum,s.suspended FROM stages s JOIN jobs j ON j.id=s.job_id \
            WHERE j.lane='library' ORDER BY s.stage_id
            """) { row in
            contents.stages.append(TransferStageRow(
                stageID: row.text(0) ?? "", jobID: row.integer(1) ?? 0, folder: row.text(2) ?? "", modificationDate: row.real(3),
                original: row.text(4).flatMap { TransferJSON.decode(StagedFile.self, $0) },
                motion: row.text(5).flatMap { TransferJSON.decode(StagedFile.self, $0) }, hasMotion: row.text(5) != nil,
                sidecar: row.text(6).flatMap { TransferJSON.decode(StagedFile.self, $0) }, hasSidecar: row.text(6) != nil,
                fields: row.text(7).flatMap { TransferJSON.decode([String: String].self, $0) }, isVideo: row.integer(8) == 1,
                motionRemoteID: row.text(9), motionChecksum: row.text(10), originalChecksum: row.text(11), suspended: row.integer(12) == 1))
        }
        try db.run("""
            SELECT a.id,a.job_id,a.part,a.session,a.state,a.body_path FROM attempts a JOIN jobs j ON j.id=a.job_id \
            WHERE j.lane='library' ORDER BY a.id
            """) { row in
            contents.attempts.append(TransferAttemptRow(id: row.text(0) ?? "", jobID: row.integer(1) ?? 0, part: row.text(2) ?? "",
                                                        session: row.text(3) ?? "", state: row.text(4) ?? "", bodyPath: row.text(5)))
        }
        try db.run("SELECT local_id,modification_date,confirmed_at FROM confirmations ORDER BY local_id") { row in
            contents.confirmations.append(TransferConfirmationRow(localID: row.text(0) ?? "", modificationDate: row.real(1), confirmedAt: row.real(2)))
        }
        try db.run("SELECT \(Self.receiptColumns) FROM receipts ORDER BY local_id") { row in
            contents.receipts.append(Self.receiptRow(row))
        }
        try db.run("SELECT local_id,album_id,remote_id,state,attempts,error FROM album_destinations ORDER BY local_id,album_id") { row in
            contents.albumDestinations.append(AlbumDestinationRow(localID: row.text(0) ?? "", albumID: row.text(1) ?? "", remoteID: row.text(2),
                                                                  state: row.text(3) ?? "", attempts: Int(row.integer(4) ?? 0), error: row.text(5)))
        }
        try db.run("SELECT device_album_id,album_id FROM linked_albums ORDER BY device_album_id") { row in
            if let device = row.text(0), let album = row.text(1) { contents.linkedAlbums[device] = album }
        }
        try db.run("SELECT count(*) FROM stack_tasks") { row in contents.stackTasks = Int(row.integer(0) ?? 0) }
        try db.run("SELECT id,kind,total,completed,failed,started_posted,terminal_posted FROM notification_batches WHERE kind='backup' ORDER BY id") { row in
            contents.notificationBatches.append(NotificationBatchRow(id: row.text(0) ?? "", kind: row.text(1) ?? "", total: Int(row.integer(2) ?? 0),
                                                                     completed: Int(row.integer(3) ?? 0), failed: row.integer(4).map(Int.init),
                                                                     startedPosted: row.integer(5) == 1, terminalPosted: row.integer(6) == 1))
        }
        return contents
    }

    // MARK: - Completion

    /// Commits a finished job, as the engine's one commit transaction (architecture section 4,
    /// backup job step 5): the job, its stages and attempts go; the confirmation and the receipt
    /// are upserted; the albums the photo waits for learn its server ID; a new server ID for a
    /// photo backed up before gets a stack task; the job's notification batch counts it. It applies
    /// only while `lease` still holds the job (nil for a job never leased), and says whether it
    /// did. Its statements don't depend on how many receipts there are (B1's 60k-receipt test).
    func complete(_ completion: TransferCompletion) throws -> Bool {
        let db = try database()
        return try db.transaction {
            var batch: String?
            var found = false
            try db.run("SELECT batch_id FROM jobs WHERE id=? AND lane=? AND source_key=? AND lease_token IS ?",
                       [.integer(completion.job), .text(TransferLane.library.rawValue), .text(completion.localID),
                        .optionalText(completion.lease?.uuidString)]) { row in
                found = true
                batch = row.text(0)
            }
            guard found else { return false }
            try db.run("DELETE FROM attempts WHERE job_id=?", [.integer(completion.job)])
            try db.run("DELETE FROM stages WHERE job_id=?", [.integer(completion.job)])
            try db.run("DELETE FROM jobs WHERE id=?", [.integer(completion.job)])
            try db.run("""
                INSERT INTO confirmations(local_id,modification_date,confirmed_at) VALUES(?,?,?) \
                ON CONFLICT(local_id) DO UPDATE SET modification_date=excluded.modification_date,confirmed_at=excluded.confirmed_at
                """, [.text(completion.localID), .real(completion.revision.referenceSeconds), .date(completion.confirmedAt)])
            if let receipt = completion.receipt {
                var previous: String?
                try db.run("SELECT original_id FROM receipts WHERE local_id=?", [.text(completion.localID)]) { previous = $0.text(0) }
                if let previous, previous != receipt.original.id {
                    try db.run("INSERT INTO stack_tasks(local_id,asset_id,previous_asset_id,state,attempts) VALUES(?,?,?,'pending',0)",
                               [.text(completion.localID), .text(receipt.original.id), .text(previous)])
                }
                try db.run("""
                    INSERT OR REPLACE INTO receipts(local_id,modification_date,original_id,original_checksum,original_bytes,motion_id,\
                    motion_checksum,motion_bytes,confirmed_at,verified_at,local_deleted_at) VALUES(?,?,?,?,?,?,?,?,?,NULL,NULL)
                    """, [.text(completion.localID), .real(receipt.revision.referenceSeconds), .text(receipt.original.id),
                          .text(receipt.original.checksum), .optionalInteger(receipt.original.byteCount), .optionalText(receipt.motion?.id),
                          .optionalText(receipt.motion?.checksum), .optionalInteger(receipt.motion?.byteCount),
                          .optionalDate(receipt.confirmedAt)])
            }
            try db.run("UPDATE album_destinations SET remote_id=? WHERE local_id=? AND remote_id IS NULL",
                       [.text(completion.assetID), .text(completion.localID)])
            if let batch {
                try db.run("UPDATE notification_batches SET completed=completed+1 WHERE id=?", [.text(batch)])
            }
            return true
        }
    }

    /// Album adds whose photo's server ID is known, which the post-upload work can run now.
    func runnableAlbumDestinations(limit: Int = 500) throws -> [AlbumDestinationRow] {
        var rows: [AlbumDestinationRow] = []
        try database().run("""
            SELECT local_id,album_id,remote_id,state,attempts,error FROM album_destinations \
            WHERE state='pending' AND remote_id IS NOT NULL ORDER BY album_id,local_id LIMIT ?
            """, [.integer(Int64(max(limit, 1)))]) { row in
            rows.append(AlbumDestinationRow(localID: row.text(0) ?? "", albumID: row.text(1) ?? "", remoteID: row.text(2), state: row.text(3) ?? "",
                                            attempts: Int(row.integer(4) ?? 0), error: row.text(5)))
        }
        return rows
    }

    // MARK: - Receipts

    func receipts(for localIDs: [String]) throws -> [String: TransferReceipt] {
        let db = try database()
        var found: [String: TransferReceipt] = [:]
        // One statement for any number of IDs, read from a JSON array.
        for start in stride(from: 0, to: localIDs.count, by: 2_000) {
            let chunk = Array(localIDs[start..<min(start + 2_000, localIDs.count)])
            try db.run("SELECT \(Self.receiptColumns) FROM receipts WHERE local_id IN (SELECT value FROM json_each(?))",
                       [.text(TransferJSON.encode(chunk))]) { row in
                if let receipt = Self.receiptRow(row).receipt { found[receipt.localID] = receipt }
            }
        }
        return found
    }

    func associations(after localID: String?, limit: Int) throws -> [ReceiptAssociation] {
        var page: [ReceiptAssociation] = []
        try database().run("SELECT local_id,original_id FROM receipts WHERE local_id>? ORDER BY local_id LIMIT ?",
                           [.text(localID ?? ""), .integer(Int64(max(limit, 1)))]) { row in
            if let local = row.text(0), let asset = row.text(1) { page.append(ReceiptAssociation(localID: local, assetID: asset)) }
        }
        return page
    }

    func receiptsForVerification(after localID: String?, limit: Int) throws -> [TransferReceipt] {
        var page: [TransferReceipt] = []
        try database().run("""
            SELECT \(Self.receiptColumns) FROM receipts WHERE local_id>? AND local_deleted_at IS NULL ORDER BY local_id LIMIT ?
            """, [.text(localID ?? ""), .integer(Int64(max(limit, 1)))]) { row in
            if let receipt = Self.receiptRow(row).receipt { page.append(receipt) }
        }
        return page
    }

    /// One statement per size, whatever the number of receipts.
    func updateVerifiedSizes(ifUnchanged sizes: [VerifiedSizes], at date: Date) throws -> Int {
        let db = try database()
        return try db.transaction {
            var updated = 0
            for size in sizes {
                try db.run("""
                    UPDATE receipts SET original_bytes=?,motion_bytes=?,verified_at=? \
                    WHERE local_id=? AND modification_date=? AND original_id=? AND motion_id IS ?
                    """, [.optionalInteger(size.originalBytes), .optionalInteger(size.motionBytes), .date(date), .text(size.localID),
                          .real(size.revision.referenceSeconds), .text(size.originalID), .optionalText(size.motionID)])
                updated += db.changes
            }
            return updated
        }
    }

    // MARK: - Testing

    /// Every row of every table, by table, in row order, for tests that compare whole databases.
    func dump() throws -> [String: [[TransferSQLite.Value]]] {
        let db = try database()
        var tables: [String] = []
        try db.run("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") { row in
            if let name = row.text(0) { tables.append(name) }
        }
        var dump: [String: [[TransferSQLite.Value]]] = [:]
        for table in tables {
            var rows: [[TransferSQLite.Value]] = []
            try db.run("SELECT * FROM \(table) ORDER BY rowid") { rows.append($0.values) }
            dump[table] = rows
        }
        return dump
    }

    // MARK: - Database

    private static let receiptColumns = """
        local_id,modification_date,original_id,original_checksum,original_bytes,motion_id,motion_checksum,motion_bytes,confirmed_at,verified_at,local_deleted_at
        """

    private static func receiptRow(_ row: TransferSQLite.Row) -> TransferReceiptRow {
        TransferReceiptRow(localID: row.text(0) ?? "", modificationDate: row.real(1), originalID: row.text(2), originalChecksum: row.text(3),
                           originalBytes: row.integer(4), motionID: row.text(5), motionChecksum: row.text(6), motionBytes: row.integer(7),
                           confirmedAt: row.real(8), verifiedAt: row.real(9), localDeletedAt: row.real(10))
    }

    private func database() throws -> TransferSQLite {
        guard !isClosed else { throw TransferStoreError.closed }
        if let connection { return connection }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        let opened = try TransferSQLite(url: url)
        try Self.createSchema(opened)
        connection = opened
        return opened
    }

    /// Creates the tables of schema 1. A database a later build made is left as it is.
    private static func createSchema(_ db: TransferSQLite) throws {
        var version: Int64 = 0
        try db.run("PRAGMA user_version") { version = $0.integer(0) ?? 0 }
        guard version < schemaVersion else { return }
        try db.transaction {
            for statement in schema { try db.run(statement) }
            try db.run("INSERT OR IGNORE INTO meta(id,schema,engine) VALUES(1,?,?)", [.integer(Int64(schemaVersion)), .text(Engine.legacy.rawValue)])
            try db.run("PRAGMA user_version=\(schemaVersion)")
        }
    }

    private static let schema = [
        """
        CREATE TABLE IF NOT EXISTS meta(id INTEGER PRIMARY KEY CHECK(id=1),schema INTEGER NOT NULL,engine TEXT NOT NULL,\
        legacy_import_digest TEXT,legacy_import_mode TEXT,legacy_imported_at,legacy_report_digest TEXT,legacy_report TEXT)
        """,
        "CREATE TABLE IF NOT EXISTS preferences(id INTEGER PRIMARY KEY CHECK(id=1),json TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS engine_state(id INTEGER PRIMARY KEY CHECK(id=1),intent TEXT NOT NULL,blocker TEXT,last_message TEXT)",
        """
        CREATE TABLE IF NOT EXISTS jobs(id INTEGER PRIMARY KEY,lane TEXT NOT NULL,source_key TEXT NOT NULL,origin TEXT NOT NULL,\
        state TEXT NOT NULL,seq INTEGER NOT NULL,not_before,retry_count INTEGER NOT NULL DEFAULT 0,phase TEXT,error_class TEXT,\
        error_message TEXT,error_at,display_name TEXT,lease_token TEXT,lease_epoch INTEGER,batch_id TEXT,UNIQUE(lane,source_key))
        """,
        "CREATE INDEX IF NOT EXISTS jobs_order ON jobs(lane,state,not_before,seq)",
        """
        CREATE TABLE IF NOT EXISTS stages(stage_id TEXT PRIMARY KEY,job_id INTEGER NOT NULL,folder TEXT NOT NULL,\
        modification_date NOT NULL,original_json TEXT NOT NULL,motion_json TEXT,sidecar_json TEXT,fields_json TEXT NOT NULL,\
        is_video INTEGER NOT NULL,motion_remote_id TEXT,motion_checksum TEXT,original_checksum TEXT,suspended INTEGER NOT NULL DEFAULT 0)
        """,
        "CREATE INDEX IF NOT EXISTS stages_job ON stages(job_id)",
        """
        CREATE TABLE IF NOT EXISTS attempts(id TEXT PRIMARY KEY,job_id INTEGER NOT NULL,part TEXT NOT NULL,session TEXT NOT NULL,\
        state TEXT NOT NULL,body_path TEXT,body_bytes INTEGER,checksum TEXT,os_task_id INTEGER,remote_id TEXT,remote_status TEXT,\
        http_status INTEGER,error_domain TEXT,error_code INTEGER)
        """,
        "CREATE INDEX IF NOT EXISTS attempts_job ON attempts(job_id)",
        "CREATE TABLE IF NOT EXISTS confirmations(local_id TEXT PRIMARY KEY,modification_date NOT NULL,confirmed_at)",
        """
        CREATE TABLE IF NOT EXISTS receipts(local_id TEXT PRIMARY KEY,modification_date NOT NULL,original_id TEXT NOT NULL,\
        original_checksum TEXT NOT NULL,original_bytes INTEGER,motion_id TEXT,motion_checksum TEXT,motion_bytes INTEGER,\
        confirmed_at,verified_at,local_deleted_at)
        """,
        """
        CREATE TABLE IF NOT EXISTS album_destinations(local_id TEXT NOT NULL,album_id TEXT NOT NULL,remote_id TEXT,state TEXT NOT NULL,\
        attempts INTEGER NOT NULL DEFAULT 0,error TEXT,PRIMARY KEY(local_id,album_id))
        """,
        """
        CREATE TABLE IF NOT EXISTS stack_tasks(id INTEGER PRIMARY KEY,local_id TEXT NOT NULL,asset_id TEXT NOT NULL,\
        previous_asset_id TEXT NOT NULL,state TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,error TEXT)
        """,
        "CREATE TABLE IF NOT EXISTS linked_albums(device_album_id TEXT PRIMARY KEY,album_id TEXT NOT NULL)",
        """
        CREATE TABLE IF NOT EXISTS share_consumed(batch_id TEXT NOT NULL,attachment TEXT NOT NULL,remote_id TEXT,consumed_at NOT NULL,\
        PRIMARY KEY(batch_id,attachment))
        """,
        """
        CREATE TABLE IF NOT EXISTS notification_batches(id TEXT PRIMARY KEY,kind TEXT NOT NULL,total INTEGER NOT NULL,\
        completed INTEGER NOT NULL DEFAULT 0,failed INTEGER,started_posted INTEGER NOT NULL DEFAULT 0,terminal_posted INTEGER NOT NULL DEFAULT 0)
        """,
    ]
}

/// The transfers database couldn't be opened or used.
enum TransferStoreError: Error, Equatable {
    /// The account's runtime has ended.
    case closed
    /// SQLite refused, with its result code.
    case sqlite(Int32)
}

/// A crash simulated at a point of an import, for tests.
struct SimulatedCrash: Error, Equatable {
    let point: LegacyImportCrashPoint
}

/// Points inside an import where a test can make the app end.
enum LegacyImportCrashPoint: Sendable, CaseIterable {
    case afterClearing, afterJobs, afterReceipts, beforeCommit, afterCommit
}

/// An upload attempt's state (architecture section 3).
enum AttemptState: String, Sendable {
    case created, bodyWritten, submitted, interrupted, completed, failed, abandoned
}

/// Which part of a photo an attempt uploads: a Live Photo's video goes first, then the still.
enum AttemptPart: String, Sendable {
    case motion, original
}

struct TransferMeta: Equatable, Sendable {
    var schema: Int
    var engine: TransferStore.Engine
    var legacyImportDigest: String?
    var legacyImportMode: LegacyBackupImporter.Mode?
    var legacyImportedAt: Date?
    var legacyReportDigest: String?
    var legacyReport: String?
}

/// A finished job, ready to commit.
struct TransferCompletion: Sendable {
    let job: Int64
    /// The lease the commit needs, or nil for a job never leased.
    let lease: UUID?
    let localID: String
    /// The photo's revision when it was staged.
    let revision: AssetRevision
    /// The still or video's server ID, which the albums it waits for take.
    let assetID: String
    /// Nil for a legacy Live Photo without its video's checksum, confirmed without a receipt.
    let receipt: TransferReceipt?
    let confirmedAt: Date
}

/// A staged file, relative to the App Group, or its recorded absolute URL when it lies outside
/// the Backup and ShareInbox folders.
struct StagedFile: Codable, Hashable, Sendable {
    let path: String
    let filename: String
    let contentType: String
}

/// Backup preferences as the transfers database keeps them: BackupPreferences' keys, with album
/// sets written as sorted arrays and keys sorted, so the same preferences always give the same text.
struct TransferPreferences: Codable, Equatable, Sendable {
    var includedAlbums: Set<String>
    var excludedAlbums: Set<String>
    var cellularPhotos: Bool
    var cellularVideos: Bool
    var downloadCloudOriginals: Bool
    var automatic: Bool
    var requireCharging: Bool
    var triggerDelay: Int
    var syncAlbums: Bool

    init(_ legacy: Legacy.BackupPreferences) {
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

    private enum CodingKeys: String, CodingKey {
        case includedAlbums, excludedAlbums, cellularPhotos, cellularVideos, downloadCloudOriginals
        case automatic, requireCharging, triggerDelay, syncAlbums
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(includedAlbums.sorted(), forKey: .includedAlbums)
        try c.encode(excludedAlbums.sorted(), forKey: .excludedAlbums)
        try c.encode(cellularPhotos, forKey: .cellularPhotos)
        try c.encode(cellularVideos, forKey: .cellularVideos)
        try c.encode(downloadCloudOriginals, forKey: .downloadCloudOriginals)
        try c.encode(automatic, forKey: .automatic)
        try c.encode(requireCharging, forKey: .requireCharging)
        try c.encode(triggerDelay, forKey: .triggerDelay)
        try c.encode(syncAlbums, forKey: .syncAlbums)
    }
}

// MARK: - Rows

/// Columns as the database holds them, read back without interpretation, so a comparison sees
/// exactly what was written: dates as their doubles, unknown values as text.
struct TransferStoreContents: Equatable, Sendable {
    var preferences: TransferPreferences?
    var engine: EngineStateRow?
    var jobs: [TransferJobRow] = []
    var stages: [TransferStageRow] = []
    var attempts: [TransferAttemptRow] = []
    var confirmations: [TransferConfirmationRow] = []
    var receipts: [TransferReceiptRow] = []
    var albumDestinations: [AlbumDestinationRow] = []
    var linkedAlbums: [String: String] = [:]
    var stackTasks = 0
    var notificationBatches: [NotificationBatchRow] = []
}

struct EngineStateRow: Equatable, Sendable {
    /// Nil when the stored intent isn't one this build knows.
    let intent: RunIntent?
    let blocker: String?
    let lastMessage: String?
}

struct TransferJobRow: Equatable, Sendable {
    let id: Int64
    let sourceKey: String
    let origin: String
    let state: String
    let seq: Int64
    let errorClass: String?
    let errorMessage: String?
    let errorAt: Double?
    let displayName: String?
    let batchID: String?
}

struct TransferStageRow: Equatable, Sendable {
    let stageID: String
    let jobID: Int64
    let folder: String
    let modificationDate: Double?
    /// Nil when the stored JSON can't be read.
    let original: StagedFile?
    let motion: StagedFile?
    let hasMotion: Bool
    let sidecar: StagedFile?
    let hasSidecar: Bool
    let fields: [String: String]?
    let isVideo: Bool
    let motionRemoteID: String?
    let motionChecksum: String?
    let originalChecksum: String?
    let suspended: Bool
}

struct TransferAttemptRow: Equatable, Sendable {
    let id: String
    let jobID: Int64
    let part: String
    let session: String
    let state: String
    let bodyPath: String?
}

struct TransferConfirmationRow: Equatable, Sendable {
    let localID: String
    let modificationDate: Double?
    let confirmedAt: Double?
}

struct TransferReceiptRow: Equatable, Sendable {
    let localID: String
    let modificationDate: Double?
    let originalID: String?
    let originalChecksum: String?
    let originalBytes: Int64?
    let motionID: String?
    let motionChecksum: String?
    let motionBytes: Int64?
    let confirmedAt: Double?
    let verifiedAt: Double?
    let localDeletedAt: Double?

    var receipt: TransferReceipt? {
        guard let modificationDate, let originalID, let originalChecksum else { return nil }
        let motion: RemoteCopy? = if let motionID, let motionChecksum { RemoteCopy(id: motionID, checksum: motionChecksum, byteCount: motionBytes) } else { nil }
        return TransferReceipt(localID: localID, revision: AssetRevision(referenceSeconds: modificationDate),
                               original: RemoteCopy(id: originalID, checksum: originalChecksum, byteCount: originalBytes), motion: motion,
                               confirmedAt: confirmedAt.map { Date(timeIntervalSinceReferenceDate: $0) },
                               verifiedAt: verifiedAt.map { Date(timeIntervalSinceReferenceDate: $0) },
                               localDeletedAt: localDeletedAt.map { Date(timeIntervalSinceReferenceDate: $0) })
    }

    /// Doubles compare by bit pattern, so a date that came back changed in its last bit differs.
    static func == (a: Self, b: Self) -> Bool {
        a.localID == b.localID && a.modificationDate?.bitPattern == b.modificationDate?.bitPattern && a.originalID == b.originalID
            && a.originalChecksum == b.originalChecksum && a.originalBytes == b.originalBytes && a.motionID == b.motionID
            && a.motionChecksum == b.motionChecksum && a.motionBytes == b.motionBytes && a.confirmedAt?.bitPattern == b.confirmedAt?.bitPattern
            && a.verifiedAt?.bitPattern == b.verifiedAt?.bitPattern && a.localDeletedAt?.bitPattern == b.localDeletedAt?.bitPattern
    }
}

struct AlbumDestinationRow: Hashable, Sendable {
    let localID: String
    let albumID: String
    let remoteID: String?
    let state: String
    let attempts: Int
    let error: String?
}

struct NotificationBatchRow: Equatable, Sendable {
    let id: String
    let kind: String
    let total: Int
    let completed: Int
    let failed: Int?
    let startedPosted: Bool
    let terminalPosted: Bool
}

// MARK: - JSON

/// JSON as the transfers database writes it: sorted keys and plain slashes, so the same value
/// always gives the same text.
enum TransferJSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

// MARK: - SQLite

/// One SQLite connection to a transfers database, used only on TransferStore's queue. Each
/// statement is prepared once and kept for the connection's life. It counts the statements it
/// runs, and those that ran on the main thread, which should be none.
final class TransferSQLite {
    enum Value: Hashable, Sendable, CustomStringConvertible {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)

        static func optionalText(_ value: String?) -> Value { value.map(Value.text) ?? .null }
        static func optionalInteger(_ value: Int64?) -> Value { value.map(Value.integer) ?? .null }
        static func date(_ date: Date) -> Value { .real(date.timeIntervalSinceReferenceDate) }
        static func optionalDate(_ date: Date?) -> Value { date.map(Value.date) ?? .null }
        static func bool(_ value: Bool) -> Value { .integer(value ? 1 : 0) }

        /// Doubles are equal only when their bits are.
        static func == (a: Value, b: Value) -> Bool {
            switch (a, b) {
            case (.null, .null): true
            case (.integer(let x), .integer(let y)): x == y
            case (.real(let x), .real(let y)): x.bitPattern == y.bitPattern
            case (.text(let x), .text(let y)): x == y
            default: false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .null: hasher.combine(0)
            case .integer(let value): hasher.combine(1); hasher.combine(value)
            case .real(let value): hasher.combine(2); hasher.combine(value.bitPattern)
            case .text(let value): hasher.combine(3); hasher.combine(value)
            }
        }

        var description: String {
            switch self {
            case .null: "NULL"
            case .integer(let value): String(value)
            case .real(let value): "\(value) (\(String(value.bitPattern, radix: 16)))"
            case .text(let value): "'\(value)'"
            }
        }
    }

    /// The current row of a running statement.
    struct Row {
        fileprivate let statement: OpaquePointer

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func text(_ column: Int32) -> String? {
            guard !isNull(column), let text = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: text)
        }
        func integer(_ column: Int32) -> Int64? { isNull(column) ? nil : sqlite3_column_int64(statement, column) }
        func real(_ column: Int32) -> Double? { isNull(column) ? nil : sqlite3_column_double(statement, column) }
        func date(_ column: Int32) -> Date? { real(column).map { Date(timeIntervalSinceReferenceDate: $0) } }

        var values: [Value] {
            (0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL: .null
                case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
                default: .text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
                }
            }
        }
    }

    private var handle: OpaquePointer?
    private var prepared: [String: OpaquePointer] = [:]
    private(set) var statements = 0
    private(set) var statementsOnMainThread = 0

    init(url: URL) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let opened else {
            sqlite3_close(opened)
            throw TransferStoreError.sqlite(status)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 5_000)
        try run("PRAGMA journal_mode=WAL")
        try run("PRAGMA synchronous=FULL")
        try run("PRAGMA journal_size_limit=8388608")
    }

    deinit { close() }

    func close() {
        for statement in prepared.values { sqlite3_finalize(statement) }
        prepared = [:]
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    /// Rows changed by the last statement.
    var changes: Int { handle.map { Int(sqlite3_changes($0)) } ?? 0 }

    /// The row ID of the last row inserted.
    var lastInsertedRow: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    /// Runs `sql` with `values`, handing each row it yields to `row`.
    func run(_ sql: String, _ values: [Value] = [], row: ((Row) throws -> Void)? = nil) throws {
        let statement = try self.statement(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard status == SQLITE_OK else { throw TransferStoreError.sqlite(status) }
        }
        statements += 1
        if Thread.isMainThread { statementsOnMainThread += 1 }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw TransferStoreError.sqlite(status) }
            try row?(Row(statement: statement))
        }
    }

    /// Runs `body` in one transaction, which a thrown error rolls back.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try run("COMMIT")
            return value
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let cached = prepared[sql] { return cached }
        guard let handle else { throw TransferStoreError.closed }
        var made: OpaquePointer?
        let status = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &made, nil)
        guard status == SQLITE_OK, let made else {
            sqlite3_finalize(made)
            throw TransferStoreError.sqlite(status)
        }
        prepared[sql] = made
        return made
    }
}

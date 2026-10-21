import Foundation

/// The offline library's file: Application Support/IlyichEntities/<sha256(scope)>.sqlite.
///
/// Version 0, as every build before Q2 left it: entities(kind, id, payload) with the server's
/// records, metadata, acknowledgements and media_purges. Those stay byte for byte as they are.
///
/// Version 1 (user_version 1) adds tables derived from the entities, which the writer keeps in
/// step with every batch and which a backfill fills for a library synced before they existed:
/// - asset_index: one row per asset, its columns in the order the server sorts a timeline
///   (local month, local day, file creation time, file name, id), then what feeds filter on;
/// - album_member: one row per album-asset record; person_member: one row per visible face of a
///   named person;
/// - locked_asset: assets the server last sent as locked, which are never stored;
/// - orphan_dependent: EXIF, faces, OCR, edits and metadata that arrived before their asset, held
///   until it arrives (Q3); dependent_repair: assets whose dependents must be fetched again, such
///   as a photo taken out of the Locked Folder (Q3); month_places: empty until F5 fills it;
/// - index_state (one row): the backfill's kind and cursor, whether the derived tables are
///   complete (queryable), a persisted revision, and the stale marker.
///
/// Version 2 (Q3) adds indexes for the feeds' reads: months in created-at order and stack
/// members. It drops the month indexes over the entities that builds before Q3 made on a second
/// read-write connection; the feeds read asset_index instead.
///
/// The stale marker: triggers on metadata and acknowledgements set index_state.stale on any write
/// made outside this build's writer, which marks its transactions with writer_active. A build
/// from before Q2, reinstalled over this one, writes both on every sync batch, reset and sign-out
/// without keeping the derived tables, so the next open of this build starts the backfill again.
enum LibraryIndexSchema {
    static let version = 2

    /// The tables and indexes every version has, created as before Q2.
    static let base = [
        "CREATE TABLE IF NOT EXISTS entities(kind TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(kind,id))",
        "CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS acknowledgements(type TEXT PRIMARY KEY,ack TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS media_purges(id TEXT PRIMARY KEY,revoked INTEGER NOT NULL)",
        "CREATE INDEX IF NOT EXISTS entity_asset ON entities(kind,json_extract(payload,'$.assetId'))",
        "CREATE INDEX IF NOT EXISTS entity_person_asset ON entities(kind,json_extract(payload,'$.personId'),json_extract(payload,'$.assetId'))",
        "CREATE INDEX IF NOT EXISTS entity_album ON entities(kind,json_extract(payload,'$.albumId'))",
        "CREATE INDEX IF NOT EXISTS entity_memory ON entities(kind,json_extract(payload,'$.memoryId'))",
        "CREATE INDEX IF NOT EXISTS asset_stack ON entities(kind,json_extract(payload,'$.stackId'))",
        "CREATE INDEX IF NOT EXISTS asset_timeline ON entities(kind,json_extract(payload,'$.ownerId'),json_extract(payload,'$.visibility'),json_extract(payload,'$.localDateTime'))",
    ]

    /// What version 1 adds. Each statement can run again harmlessly.
    static let v1: [String] = [
        """
        CREATE TABLE IF NOT EXISTS asset_index(id TEXT PRIMARY KEY NOT NULL,local_month TEXT,local_day TEXT,file_created_at REAL,file_name TEXT,
        local_date_time REAL,created_month TEXT,created_at REAL,owner_id TEXT,visibility TEXT,trashed INTEGER NOT NULL DEFAULT 0,
        favorite INTEGER NOT NULL DEFAULT 0,developed INTEGER NOT NULL DEFAULT 0,stack_id TEXT) WITHOUT ROWID
        """,
        "CREATE INDEX IF NOT EXISTS asset_index_order ON asset_index(local_month,local_day,file_created_at,file_name,id)",
        "CREATE TABLE IF NOT EXISTS album_member(entity_id TEXT PRIMARY KEY NOT NULL,album_id TEXT NOT NULL,asset_id TEXT NOT NULL) WITHOUT ROWID",
        "CREATE INDEX IF NOT EXISTS album_member_album ON album_member(album_id,asset_id)",
        "CREATE INDEX IF NOT EXISTS album_member_asset ON album_member(asset_id)",
        "CREATE TABLE IF NOT EXISTS person_member(face_id TEXT PRIMARY KEY NOT NULL,person_id TEXT NOT NULL,asset_id TEXT NOT NULL) WITHOUT ROWID",
        "CREATE INDEX IF NOT EXISTS person_member_person ON person_member(person_id,asset_id)",
        "CREATE INDEX IF NOT EXISTS person_member_asset ON person_member(asset_id)",
        "CREATE TABLE IF NOT EXISTS locked_asset(id TEXT PRIMARY KEY NOT NULL) WITHOUT ROWID",
        "CREATE TABLE IF NOT EXISTS orphan_dependent(kind TEXT NOT NULL,id TEXT NOT NULL,asset_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(kind,id))",
        "CREATE INDEX IF NOT EXISTS orphan_dependent_asset ON orphan_dependent(asset_id)",
        "CREATE TABLE IF NOT EXISTS dependent_repair(asset_id TEXT PRIMARY KEY NOT NULL,reason TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,not_before REAL)",
        "CREATE TABLE IF NOT EXISTS month_places(query_key TEXT NOT NULL,bucket TEXT NOT NULL,city TEXT,country TEXT,count INTEGER NOT NULL)",
        "CREATE INDEX IF NOT EXISTS month_places_query ON month_places(query_key,bucket)",
        """
        CREATE TABLE IF NOT EXISTS index_state(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL DEFAULT 0,backfill_kind TEXT,
        backfill_cursor TEXT,queryable INTEGER NOT NULL DEFAULT 0,stale INTEGER NOT NULL DEFAULT 0,writer_active INTEGER NOT NULL DEFAULT 0)
        """,
        "INSERT OR IGNORE INTO index_state(id,backfill_kind) VALUES(1,'\(backfillKinds[0])')",
    ] + ["metadata", "acknowledgements"].flatMap { table in
        ["INSERT", "UPDATE", "DELETE"].map { operation in
            """
            CREATE TRIGGER IF NOT EXISTS index_stale_\(table)_\(operation.lowercased()) AFTER \(operation) ON \(table)
            WHEN (SELECT writer_active=0 AND stale=0 FROM index_state WHERE id=1) IS 1
            BEGIN UPDATE index_state SET stale=1 WHERE id=1; END
            """
        }
    }

    /// What version 2 adds. Each statement can run again harmlessly.
    static let v2: [String] = [
        "CREATE INDEX IF NOT EXISTS asset_index_created ON asset_index(created_month,created_at,file_created_at,file_name,id)",
        "CREATE INDEX IF NOT EXISTS asset_index_stack ON asset_index(stack_id) WHERE stack_id IS NOT NULL",
        "DROP INDEX IF EXISTS asset_month_localDateTime",
        "DROP INDEX IF EXISTS asset_month_createdAt",
    ]

    /// The tables derived from the entities, which a backfill can work out again.
    static let derivedTables = ["asset_index", "album_member", "person_member", "locked_asset", "month_places"]
    /// What the sync stream left for later: dependents waiting for their asset and assets waiting
    /// for a repair. Nothing else holds them, so only a reset, a new session or a sign-out
    /// empties them.
    static let pendingTables = ["orphan_dependent", "dependent_repair"]

    /// The kinds the backfill walks, in order.
    static let backfillKinds = ["asset", "albumAsset", "face"]

    struct State: Sendable, Equatable {
        /// The kind the backfill is on; nil once it is done.
        var kind: String?
        /// The last entity ID of that kind it derived; nil at the kind's start.
        var cursor: String?
        var queryable: Bool
        var stale: Bool
        var revision: Int64
    }

    /// Brings a file to version 2 in place. Only new tables, indexes, triggers and the state row
    /// are added, and the old month indexes dropped, in one transaction; no entity is read or
    /// rewritten. A file a build without the derived tables wrote to since restarts its backfill.
    static func migrate(_ database: SQLiteConnection) throws {
        if try database.userVersion < version {
            try database.transaction {
                let from = try database.userVersion
                guard from < version else { return }
                if from < 1 {
                    for statement in v1 { try database.execute(statement) }
                    // An empty library has nothing to fill.
                    if case .integer(0) = try database.scalar("SELECT EXISTS(SELECT 1 FROM entities)") {
                        try database.execute("UPDATE index_state SET backfill_kind=NULL,backfill_cursor=NULL,queryable=1 WHERE id=1")
                    }
                }
                for statement in v2 { try database.execute(statement) }
                try database.execute("PRAGMA user_version=\(version)")
            }
        }
        if try state(database).stale {
            try database.transaction { try restartBackfill(database) }
        }
    }

    static func state(_ database: SQLiteConnection) throws -> State {
        var state = State(kind: backfillKinds[0], cursor: nil, queryable: false, stale: false, revision: 0)
        try database.run("SELECT backfill_kind,backfill_cursor,queryable,stale,revision FROM index_state WHERE id=1") { row in
            state = State(kind: row.text(0), cursor: row.text(1), queryable: row.integer(2) == 1, stale: row.integer(3) == 1, revision: row.integer(4) ?? 0)
        }
        return state
    }

    /// The derived tables are no longer known to match: they stay as they are, unqueryable, until
    /// the backfill has walked every entity again.
    static func restartBackfill(_ database: SQLiteConnection) throws {
        try database.execute("UPDATE index_state SET backfill_kind=?,backfill_cursor=NULL,queryable=0,stale=0 WHERE id=1", [.text(backfillKinds[0])])
    }

    /// The entities were emptied, so the derived tables empty too and match them. `pending` empties
    /// the orphans and repairs as well, as a new session or a sign-out does.
    static func clearDerived(_ database: SQLiteConnection, pending: Bool = true) throws {
        for table in derivedTables + (pending ? pendingTables : []) { try database.execute("DELETE FROM \(table)") }
        try database.execute("UPDATE index_state SET backfill_kind=NULL,backfill_cursor=NULL,queryable=1,stale=0,revision=revision+1 WHERE id=1")
    }

    // MARK: Derivation

    /// How one kind of entity row becomes a derived row: the table, its key (the entity's ID),
    /// its columns, what they are worked out from, and which rows of the kind count.
    private struct Derivation {
        let table: String
        let key: String
        let columns: String
        let select: String
        let filter: String

        func insert(where condition: String) -> String {
            "INSERT OR REPLACE INTO \(table)(\(columns)) SELECT \(select) FROM entities WHERE \(condition)\(filter)"
        }
    }

    private static let derivations: [String: Derivation] = [
        "asset": Derivation(
            table: "asset_index", key: "id",
            columns: "id,local_month,local_day,file_created_at,file_name,local_date_time,created_month,created_at,owner_id,visibility,trashed,favorite,developed,stack_id",
            select: """
            id,strftime('%Y-%m',json_extract(payload,'$.localDateTime')),date(json_extract(payload,'$.localDateTime')),
            julianday(json_extract(payload,'$.fileCreatedAt')),json_extract(payload,'$.originalFileName'),julianday(json_extract(payload,'$.localDateTime')),
            strftime('%Y-%m',json_extract(payload,'$.createdAt')),julianday(json_extract(payload,'$.createdAt')),json_extract(payload,'$.ownerId'),
            json_extract(payload,'$.visibility'),json_extract(payload,'$.deletedAt') IS NOT NULL,COALESCE(json_extract(payload,'$.isFavorite'),0),
            COALESCE(json_extract(payload,'$.isDeveloped'),0),json_extract(payload,'$.stackId')
            """,
            filter: ""),
        "albumAsset": Derivation(
            table: "album_member", key: "entity_id", columns: "entity_id,album_id,asset_id",
            select: "id,json_extract(payload,'$.albumId'),json_extract(payload,'$.assetId')",
            filter: " AND json_extract(payload,'$.albumId') IS NOT NULL AND json_extract(payload,'$.assetId') IS NOT NULL"),
        "face": Derivation(
            table: "person_member", key: "face_id", columns: "face_id,person_id,asset_id",
            select: "id,json_extract(payload,'$.personId'),json_extract(payload,'$.assetId')",
            filter: " AND json_extract(payload,'$.personId') IS NOT NULL AND json_extract(payload,'$.assetId') IS NOT NULL"
                + " AND json_extract(payload,'$.deletedAt') IS NULL AND json_extract(payload,'$.isVisible')=1"),
    ]

    /// Derives the next batch of at most `size` rows of the backfill's kind and moves the cursor
    /// past them. The derived rows in the batch's ID range are rebuilt from the entities in it, so
    /// rows of entities removed since are dropped too. Returns whether anything is left.
    static func backfillBatch(_ database: SQLiteConnection, size: Int) throws -> Bool {
        let state = try state(database)
        guard let kind = state.kind, let derivation = derivations[kind] else { return false }
        let lower = state.cursor ?? ""
        var ids: [String] = []
        try database.run("SELECT id FROM entities WHERE kind=? AND id>? ORDER BY id LIMIT ?", [.text(kind), .text(lower), .integer(Int64(size))]) { row in
            if let id = row.text(0) { ids.append(id) }
        }
        // A short batch reaches the end of the kind, so it covers everything after the cursor.
        let upper = ids.count == size ? ids.last : nil
        if let upper {
            try database.execute("DELETE FROM \(derivation.table) WHERE \(derivation.key)>? AND \(derivation.key)<=?", [.text(lower), .text(upper)])
            try database.execute(derivation.insert(where: "kind=? AND id>? AND id<=?"), [.text(kind), .text(lower), .text(upper)])
            try database.execute("UPDATE index_state SET backfill_cursor=? WHERE id=1", [.text(upper)])
            return true
        }
        try database.execute("DELETE FROM \(derivation.table) WHERE \(derivation.key)>?", [.text(lower)])
        try database.execute(derivation.insert(where: "kind=? AND id>?"), [.text(kind), .text(lower)])
        let next = backfillKinds.firstIndex(of: kind).map { $0 + 1 }.flatMap { $0 < backfillKinds.count ? backfillKinds[$0] : nil }
        try database.execute("UPDATE index_state SET backfill_kind=?,backfill_cursor=NULL,queryable=? WHERE id=1",
                             [.optionalText(next), .integer(next == nil ? 1 : 0)])
        return next != nil
    }

    /// Works the derived rows out again for what one batch touched, from the entities as the batch
    /// left them.
    static func maintain(_ database: SQLiteConnection, _ touched: DerivedTouch) throws {
        // The reset emptied the orphans and repairs itself, when it came: those that came after
        // it in the batch stay.
        if touched.reset { try clearDerived(database, pending: false) }
        let asset = derivations["asset"]!, album = derivations["albumAsset"]!, face = derivations["face"]!
        if !touched.assets.isEmpty {
            let list = try json(touched.assets)
            try database.execute("DELETE FROM asset_index WHERE id IN (SELECT value FROM json_each(?))", [.text(list)])
            try database.execute(asset.insert(where: "kind='asset' AND id IN (SELECT value FROM json_each(?))"), [.text(list)])
        }
        if !touched.members.isEmpty {
            let list = try json(touched.members)
            try database.execute("DELETE FROM album_member WHERE asset_id IN (SELECT value FROM json_each(?))", [.text(list)])
            try database.execute(album.insert(where: "kind='albumAsset' AND json_extract(payload,'$.assetId') IN (SELECT value FROM json_each(?))"), [.text(list)])
            try database.execute("DELETE FROM person_member WHERE asset_id IN (SELECT value FROM json_each(?))", [.text(list)])
            try database.execute(face.insert(where: "kind='face' AND json_extract(payload,'$.assetId') IN (SELECT value FROM json_each(?))"), [.text(list)])
        }
        if !touched.albums.isEmpty {
            let list = try json(touched.albums)
            try database.execute("DELETE FROM album_member WHERE album_id IN (SELECT value FROM json_each(?))", [.text(list)])
            try database.execute(album.insert(where: "kind='albumAsset' AND json_extract(payload,'$.albumId') IN (SELECT value FROM json_each(?))"), [.text(list)])
        }
        if !touched.people.isEmpty {
            let list = try json(touched.people)
            try database.execute("DELETE FROM person_member WHERE person_id IN (SELECT value FROM json_each(?))", [.text(list)])
            try database.execute(face.insert(where: "kind='face' AND json_extract(payload,'$.personId') IN (SELECT value FROM json_each(?))"), [.text(list)])
        }
        for (id, locked) in touched.locked {
            try database.execute(locked ? "INSERT OR IGNORE INTO locked_asset(id) VALUES(?)" : "DELETE FROM locked_asset WHERE id=?", [.text(id)])
        }
        try database.execute("UPDATE index_state SET revision=revision+1 WHERE id=1")
    }

    private static func json(_ ids: Set<String>) throws -> String {
        String(decoding: try JSONEncoder().encode(ids.sorted()), as: UTF8.self)
    }
}

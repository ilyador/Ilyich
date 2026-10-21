import Foundation
import SQLite3
import Synchronization

/// The offline library's only read-write connection, on its own serial queue at utility
/// priority. It commits each sync batch with its acknowledgements, all or nothing, and in the same
/// transaction keeps the derived tables (LibraryIndexSchema) in step with the entities. It also
/// fills those tables for a library synced before they existed, a batch at a time.
actor IndexWriter {
    private nonisolated let queue = DispatchSerialQueue(label: "ilyich.index.writer", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    nonisolated let userID: String
    nonisolated let path: String
    private let database: SQLiteConnection
    private var generation = UUID()
    /// Moves each time a committed write changes what the index holds, so a reader can tell
    /// whether it read before or after a change. It counts from zero each launch.
    private(set) var revision: UInt64 = 0
    /// What the batch being applied touched, for the derived tables.
    private var touched = DerivedTouch()
    /// Entity rows of one kind a backfill batch derives.
    nonisolated let backfillBatchSize: Int
    /// Set when a batch's derived rows failed and the backfill was restarted, until LibraryIndex
    /// takes it and runs the backfill again.
    nonisolated let backfillRestarted = Atomic<Bool>(false)
    private static let cachedServerFeaturesKey = "cache.serverFeatures.v1"

    /// Opens the file, creating it if needed, and migrates it in place: the derived tables are
    /// added empty and filled later by `backfillStep`. Entities, metadata and acknowledgements are
    /// left as they are, so nothing syncs again.
    init(url: URL, userID: String, backfillBatchSize: Int = 5_000) throws {
        self.userID = userID
        self.path = url.path
        self.backfillBatchSize = max(backfillBatchSize, 1)
        do {
            database = try SQLiteConnection(path: url.path, readOnly: false, busyTimeout: 60_000)
            // The only other writer builds a month index, which takes seconds on a large library;
            // a write waits for it rather than failing.
            try database.execute("PRAGMA journal_mode=WAL"); try database.execute("PRAGMA synchronous=FULL"); try database.execute("PRAGMA secure_delete=ON")
            for statement in LibraryIndexSchema.base { try database.execute(statement) }
            try LibraryIndexSchema.migrate(database)
        } catch { throw Self.failure(error) }
    }

    func epoch() -> UUID { generation }
    func isComplete() throws -> Bool { try metadata("complete") == "1" }
    func lastSyncDate() throws -> Date? { try metadata("completedAt").flatMap(APIDate.parse) }
    func persistCachedServerFeatures(_ features: ServerFeatures) throws {
        let data = try APIJSON.encoder().encode(features)
        guard let value = String(data: data, encoding: .utf8) else { throw invalidSync() }
        try write { try setMetadata(Self.cachedServerFeaturesKey, value) }
    }
    func cachedServerFeatures() throws -> ServerFeatures? {
        guard let value = try metadata(Self.cachedServerFeaturesKey) else { return nil }
        return try APIJSON.decoder().decode(ServerFeatures.self, from: Data(value.utf8))
    }
    /// A reset survives a later stream failure, allowing the UI to discard stale media even
    /// when the overall sync did not return a success summary.
    func takeAccessInvalidation() throws -> Bool {
        let changed = try metadata("accessInvalidated") == "1"
        if changed { try write { try setMetadata("accessInvalidated", "0") } }
        return changed
    }
    /// Photos the index removed whose media the app still has to forget, with whether access to
    /// them was lost. They stay queued until the media layer reports them forgotten, so a crash
    /// in between forgets them on the next sync.
    func pendingMediaPurges(limit: Int = 5_000) throws -> [MediaPurge] {
        try database.query("SELECT id,revoked FROM media_purges LIMIT ?", [String(max(limit, 1))], cancellable: false).compactMap { row in
            row[0].map { MediaPurge(assetID: $0, revoked: row[1] == "1") }
        }
    }
    /// A purge that a later batch made stricter stays queued.
    func finishMediaPurges(_ purges: [MediaPurge]) throws {
        try write {
            for purge in purges { try database.execute("DELETE FROM media_purges WHERE id=? AND revoked<=?", [.text(purge.assetID), .text(purge.revoked ? "1" : "0")]) }
        }
    }
    /// New login or a removed local database must never inherit server-only cursors.
    func prepare(sessionFingerprint: String) throws -> Bool {
        try Task.checkCancellation()
        if try metadata("session") != sessionFingerprint {
            if try metadata("session") != nil { generation = UUID() }
            try write {
                try database.execute("DELETE FROM entities"); try database.execute("DELETE FROM acknowledgements")
                try database.execute("DELETE FROM metadata")
                try LibraryIndexSchema.clearDerived(database)
                try setMetadata("session", sessionFingerprint); try setMetadata("needsReset", "1")
            }
            revision &+= 1
        }
        return try metadata("needsReset") == "1"
    }
    func markResetRequested() throws { try Task.checkCancellation(); try write { try setMetadata("needsReset", "0") } }
    func pendingAcknowledgements() throws -> [String] {
        try database.query("SELECT ack FROM acknowledgements ORDER BY rowid", cancellable: false).compactMap { $0[0] }
    }
    func acknowledged(_ acks: [String]) throws {
        try write {
            for ack in acks { try database.execute("DELETE FROM acknowledgements WHERE ack=?", [.text(ack)]) }
        }
    }
    func clear() throws {
        generation = UUID()
        try write {
            try database.execute("DELETE FROM entities"); try database.execute("DELETE FROM acknowledgements"); try database.execute("DELETE FROM metadata")
            try LibraryIndexSchema.clearDerived(database)
        }
        revision &+= 1
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Commits one batch of the sync stream with its acknowledgements, all or nothing, and says
    /// what it changed, item by item. The completion marker alone changes nothing, unless it
    /// completes the index. The derived tables follow in the same transaction; if they cannot,
    /// the batch still commits and the index stops being queryable until the backfill redoes them.
    func apply(_ events: [EntitySyncEvent], epoch: UUID) throws -> IndexChange {
        guard epoch == generation else { throw CancellationError() }
        var change = IndexChange()
        var complete = try metadata("complete") == "1"
        touched = DerivedTouch()
        defer { touched = DerivedTouch() }
        try write {
            for event in events {
                try Task.checkCancellation()
                if event.type == "SyncResetV1" {
                    try database.execute("DELETE FROM entities"); try database.execute("DELETE FROM acknowledgements")
                    try setMetadata("complete", "0")
                    touched = DerivedTouch(reset: true)
                    change.serverReset = true
                    if complete { change.routingChanged = true; complete = false }
                } else if event.type == "SyncCompleteV1" {
                    try setMetadata("complete", "1"); try setMetadata("completedAt", Date().ISO8601Format())
                    change.completed = true
                    if !complete { change.routingChanged = true; complete = true }
                } else if event.type != "SyncAckV1" {
                    try applyEntity(event, change: &change)
                }
                // A backfill completion uses SyncAckV1 with another entity's ack type.
                guard !event.ackType.isEmpty, event.ack.contains("|") else { throw invalidSync() }
                try database.execute("INSERT INTO acknowledgements(type,ack) VALUES(?,?) ON CONFLICT(type) DO UPDATE SET ack=excluded.ack", [.text(event.ackType), .text(event.ack)])
            }
            if change.serverReset { try setMetadata("accessInvalidated", "1") }
            maintainDerived()
        }
        change.limitItems()
        if !change.isEmpty { revision &+= 1 }
        change.revision = revision
        return change
    }

    /// The media revision the index holds for each of these assets it has.
    func mediaRevisions(of ids: [String]) throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let list = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        var revisions: [String: String] = [:]
        for row in try database.query("SELECT id,json_extract(payload,'$.mediaRevision') FROM entities WHERE kind='asset' AND id IN (SELECT value FROM json_each(?))", [list], cancellable: false) {
            if let id = row[0], let revision = row[1] { revisions[id] = revision }
        }
        return revisions
    }

    // MARK: - Derived tables

    /// Whether the derived tables hold every entity, so a reader may use them.
    func isQueryable() throws -> Bool { try LibraryIndexSchema.state(database).queryable }

    /// Where the backfill is, for tests and diagnostics.
    func backfillState() throws -> LibraryIndexSchema.State { try LibraryIndexSchema.state(database) }

    /// Derives one batch of at most `backfillBatchSize` entity rows of the kind the backfill is on,
    /// in one transaction with the cursor it moves, so a kill at any point resumes from the last
    /// batch committed. Returns false once every kind is done and the index is queryable.
    func backfillStep() throws -> Bool {
        try Task.checkCancellation()
        var more = false
        try database.transaction {
            more = try LibraryIndexSchema.backfillBatch(database, size: backfillBatchSize)
        }
        return more
    }

    /// The batch's derived rows, worked out again from the entities it touched, inside a savepoint
    /// of the batch's transaction. A failure there undoes only the derived rows and leaves the
    /// index unqueryable with its backfill restarted; the entities and acknowledgements commit.
    private func maintainDerived() {
        guard !touched.isEmpty else { return }
        do {
            try database.savepoint("derived") { try LibraryIndexSchema.maintain(database, touched) }
        } catch {
            if (try? LibraryIndexSchema.restartBackfill(database)) != nil { backfillRestarted.store(true, ordering: .releasing) }
        }
    }

    /// Runs `body` in one transaction marked as this writer's, so the stale-marker triggers stay
    /// quiet; a build that does not keep the derived tables leaves its writes unmarked.
    private func write(_ body: () throws -> Void) throws {
        try database.transaction {
            try database.execute("UPDATE index_state SET writer_active=1 WHERE id=1")
            try body()
            try database.execute("UPDATE index_state SET writer_active=0 WHERE id=1")
        }
    }

    // MARK: - Entities

    private func applyEntity(_ event: EntitySyncEvent, change: inout IndexChange) throws {
        let type = event.type
        var object = event.data
        let kind: String
        let keys: [String]
        let delete: Bool
        switch type {
        case "AuthUserV2", "UserV1": kind = "user"; keys = ["id"]; delete = false; object.removeValue(forKey: "pinCode")
        case "UserDeleteV1": kind = "user"; keys = ["userId"]; delete = true
        case "PartnerV1", "PartnerDeleteV1": kind = "partner"; keys = ["sharedById", "sharedWithId"]; delete = type.contains("Delete")
        case "AssetV2", "PartnerAssetV2", "PartnerAssetBackfillV2", "AlbumAssetCreateV2", "AlbumAssetUpdateV2", "AlbumAssetBackfillV2": kind = "asset"; keys = ["id"]; delete = false
        case "AssetDeleteV1", "PartnerAssetDeleteV1": kind = "asset"; keys = ["assetId"]; delete = true
        case "AssetExifV1", "PartnerAssetExifV1", "PartnerAssetExifBackfillV1", "AlbumAssetExifCreateV1", "AlbumAssetExifUpdateV1", "AlbumAssetExifBackfillV1": kind = "exif"; keys = ["assetId"]; delete = false
        case "AssetMetadataV1", "AssetMetadataDeleteV1": kind = "assetMetadata"; keys = ["assetId", "key"]; delete = type.contains("Delete")
        case "AssetEditV1": kind = "edit"; keys = ["id"]; delete = false
        case "AssetEditDeleteV1": kind = "edit"; keys = ["editId"]; delete = true
        case "AssetOcrV1", "AssetOcrDeleteV1": kind = "ocr"; keys = ["id"]; delete = type.contains("Delete")
        case "AlbumV2": kind = "album"; keys = ["id"]; delete = false
        case "AlbumDeleteV1": kind = "album"; keys = ["albumId"]; delete = true
        case "AlbumUserV1", "AlbumUserBackfillV1", "AlbumUserDeleteV1": kind = "albumUser"; keys = ["albumId", "userId"]; delete = type.contains("Delete")
        case "AlbumToAssetV1", "AlbumToAssetBackfillV1", "AlbumToAssetDeleteV1": kind = "albumAsset"; keys = ["albumId", "assetId"]; delete = type.contains("Delete")
        case "MemoryV2": kind = "memory"; keys = ["id"]; delete = false
        case "MemoryDeleteV1": kind = "memory"; keys = ["memoryId"]; delete = true
        case "MemoryToAssetV2", "MemoryToAssetDeleteV1": kind = "memoryAsset"; keys = ["memoryId", "assetId"]; delete = type.contains("Delete")
        case "StackV1", "PartnerStackV1", "PartnerStackBackfillV1": kind = "stack"; keys = ["id"]; delete = false
        case "StackDeleteV1", "PartnerStackDeleteV1": kind = "stack"; keys = ["stackId"]; delete = true
        case "PersonV1": kind = "person"; keys = ["id"]; delete = false
        case "PersonDeleteV1": kind = "person"; keys = ["personId"]; delete = true
        case "AssetFaceV3": kind = "face"; keys = ["id"]; delete = false
        case "AssetFaceDeleteV1": kind = "face"; keys = ["assetFaceId"]; delete = true
        case "UserMetadataV1", "UserMetadataDeleteV1": kind = "userMetadata"; keys = ["userId", "key"]; delete = type.contains("Delete")
        default: throw APIError.invalidResponse("The server sent an unsupported sync event. Update Ilyich before syncing again.")
        }
        let identifiers = try keys.map { key -> String in guard let value = object[key]?.string else { throw invalidSync() }; return value }
        let id = identifiers.joined(separator: "|")
        if kind == "asset" {
            let locked = object["visibility"]?.string == "locked"
            touched.locked[id] = locked
            if delete || locked {
                // A deletion only removes the photo; locking hides it the way lost access does.
                try deleteAsset(id, revoked: locked, change: &change)
                return
            }
            let before = try placement(of: id, localDateTime: object["localDateTime"]?.string)
            try upsert(kind, id, object)
            touched.assets.insert(id)
            let inMonth = ["timeline", "archive"].contains(object["visibility"]?.string ?? "")
            change.upsert(id, from: before.month, to: inMonth ? before.newMonth : nil)
            if before.exists, let revision = object["mediaRevision"]?.string, revision != before.revision { change.mediaRevisions[id] = revision }
            return
        }
        // The asset a dependent record belongs to, and the month that asset shows in.
        var subject: (asset: String, month: MonthKey?)?
        if let assetID = object["assetId"]?.string, ["exif", "edit", "ocr", "assetMetadata", "face"].contains(kind) {
            // Locked assets are never persisted, including their EXIF, OCR or faces.
            let held = try assetMonth(assetID)
            guard held.exists else { return }
            subject = (assetID, held.month)
        }
        // A face can move to another person, and the deletions of faces and edits name only
        // themselves, so what they belonged to is read before they change.
        var faceOwners = Set<String>()
        if kind == "face", let personID = object["personId"]?.string { faceOwners.insert(personID) }
        if kind == "face" || (kind == "edit" && delete),
           let previous = try database.query("SELECT json_extract(payload,'$.assetId'),json_extract(payload,'$.personId') FROM entities WHERE kind=? AND id=?",
                                             [kind, id], cancellable: false).first {
            if subject == nil, let assetID = previous[0] { subject = (assetID, try assetMonth(assetID).month) }
            if kind == "face", let personID = previous[1] { faceOwners.insert(personID) }
        }
        if delete {
            try database.execute("DELETE FROM entities WHERE kind=? AND id=?", [.text(kind), .text(id)])
            if kind == "album" { try deleteAlbum(id) }
            if kind == "memory" { try database.execute("DELETE FROM entities WHERE kind='memoryAsset' AND json_extract(payload,'$.memoryId')=?", [.text(id)]) }
            if kind == "person" { try database.execute("DELETE FROM entities WHERE kind='face' AND json_extract(payload,'$.personId')=?", [.text(id)]); touched.people.insert(id) }
            if kind == "user" { try deleteOwnedAssets(id, change: &change) }
        } else {
            try upsert(kind, id, object)
        }
        switch kind {
        case "user":
            // The account's own record (its quota, name and avatar) is not part of the library.
            if type != "AuthUserV2" && identifiers.first != userID { change.partnersChanged = true }
        case "partner": change.partnersChanged = true
        case "album": change.albums.insert(id)
        case "albumUser", "albumAsset": if let albumID = object["albumId"]?.string { change.albums.insert(albumID) }
        case "memory", "memoryAsset": change.memoriesChanged = true
        // Only the account's own preferences are read, for whether memories show.
        case "userMetadata": if object["userId"]?.string == userID { change.memoriesChanged = true }
        case "stack": change.stacks.insert(id)
        case "person": change.people.insert(id)
        case "face": change.people.formUnion(faceOwners)
        default: break
        }
        if kind == "albumAsset", let assetID = object["assetId"]?.string { touched.members.insert(assetID) }
        if kind == "face", let subject { touched.members.insert(subject.asset) }
        if let subject { change.touch(subject.asset, in: subject.month) }
        if delete, kind == "albumUser", object["userId"]?.string == userID, let albumID = object["albumId"]?.string { try deleteAlbum(albumID) }
        // Only photos that leave the account change what it may see. A photo removed from one of
        // my own albums stays in my library, and so does its media.
        if delete && ["partner", "albumUser", "album", "albumAsset", "user"].contains(kind) { try purgeInaccessibleAssets(change: &change) }
    }
    private func upsert(_ kind: String, _ id: String, _ object: [String: EntityJSON]) throws {
        let encoded = try JSONEncoder().encode(object)
        try database.execute("INSERT INTO entities(kind,id,payload) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload",
                             [.text(kind), .text(id), .text(String(decoding: encoded, as: UTF8.self))])
    }
    /// Where an asset is before it is written: whether the index holds it, the month it shows in
    /// (nil when it shows in none), its media revision, and the month `localDateTime` falls in,
    /// worked out by SQLite as the feeds' months are.
    private func placement(of id: String, localDateTime: String?) throws -> (exists: Bool, month: MonthKey?, revision: String?, newMonth: MonthKey?) {
        let row = try database.query("""
        SELECT e.id IS NOT NULL,
               CASE WHEN json_extract(e.payload,'$.visibility') IN ('timeline','archive') THEN strftime('%Y-%m',json_extract(e.payload,'$.localDateTime')) END,
               json_extract(e.payload,'$.mediaRevision'), strftime('%Y-%m',?2)
        FROM (SELECT 1) LEFT JOIN entities e ON e.kind='asset' AND e.id=?1
        """, [id, localDateTime], cancellable: false).first
        return (row?[0] == "1", row?[1].flatMap(Self.month), row?[2], row?[3].flatMap(Self.month))
    }
    /// The month an asset shows in, nil when it shows in none, and whether the index holds it.
    private func assetMonth(_ id: String) throws -> (exists: Bool, month: MonthKey?) {
        let rows = try database.query("""
        SELECT CASE WHEN json_extract(payload,'$.visibility') IN ('timeline','archive') THEN strftime('%Y-%m',json_extract(payload,'$.localDateTime')) END
        FROM entities WHERE kind='asset' AND id=?
        """, [id], cancellable: false)
        guard let row = rows.first else { return (false, nil) }
        return (true, row[0].flatMap(Self.month))
    }
    /// YYYY-MM, as strftime writes it.
    private static func month(_ yearMonth: String) -> MonthKey? { MonthKey(bucketID: yearMonth + "-01") }
    /// The photo's media is forgotten once the batch commits. Its queued purge commits with the
    /// batch, so a crash before then cannot leave the media behind.
    private func deleteAsset(_ id: String, revoked: Bool, change: inout IndexChange) throws {
        try database.execute("DELETE FROM entities WHERE (kind='asset' AND id=?) OR (kind IN ('exif','edit','ocr','assetMetadata','face','albumAsset','memoryAsset') AND json_extract(payload,'$.assetId')=?)", [.text(id), .text(id)])
        try database.execute("INSERT INTO media_purges(id,revoked) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET revoked=max(revoked,excluded.revoked)", [.text(id), .text(revoked ? "1" : "0")])
        touched.assets.insert(id); touched.members.insert(id)
        change.remove(id, accessLost: revoked)
    }
    private func deleteAlbum(_ id: String) throws {
        try database.execute("DELETE FROM entities WHERE (kind='album' AND id=?) OR (kind IN ('albumUser','albumAsset') AND json_extract(payload,'$.albumId')=?)", [.text(id), .text(id)])
        touched.albums.insert(id)
    }
    private func deleteOwnedAssets(_ ownerID: String, change: inout IndexChange) throws {
        let rows = try database.query("SELECT id FROM entities WHERE kind='asset' AND json_extract(payload,'$.ownerId')=?", [ownerID], cancellable: false)
        for row in rows { if let id = row[0] { try deleteAsset(id, revoked: true, change: &change) } }
    }
    private func purgeInaccessibleAssets(change: inout IndexChange) throws {
        let rows = try database.query("""
        SELECT a.id FROM entities a WHERE a.kind='asset' AND json_extract(a.payload,'$.ownerId')!=?
        AND NOT EXISTS(SELECT 1 FROM entities p WHERE p.kind='partner' AND json_extract(p.payload,'$.sharedById')=json_extract(a.payload,'$.ownerId') AND json_extract(p.payload,'$.sharedWithId')=?)
        AND NOT EXISTS(SELECT 1 FROM entities r JOIN entities u ON u.kind='albumUser' AND json_extract(u.payload,'$.albumId')=json_extract(r.payload,'$.albumId') AND json_extract(u.payload,'$.userId')=? WHERE r.kind='albumAsset' AND json_extract(r.payload,'$.assetId')=a.id)
        """, [userID, userID, userID], cancellable: false)
        for row in rows { if let id = row[0] { try deleteAsset(id, revoked: true, change: &change) } }
    }
    private func metadata(_ key: String) throws -> String? {
        try database.query("SELECT value FROM metadata WHERE key=?", [key], cancellable: false).first?[0]
    }
    private func setMetadata(_ key: String, _ value: String) throws {
        try database.execute("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }
    private func invalidSync() -> APIError { .invalidResponse("The server sent an invalid synchronization record. Your saved cursor was not advanced.") }
    static func failure(_ error: any Error) -> any Error {
        error is SQLiteError ? APIError.invalidResponse("The offline library could not be saved. Free some device storage, then try again.") : error
    }
}

/// What one batch touched, for the derived tables: assets whose own row changed, assets whose
/// album or face rows changed, albums and people whose rows went in bulk, and the assets that
/// arrived locked (true) or not (false). After a reset only what came after it counts.
struct DerivedTouch: Sendable {
    var reset = false
    var assets: Set<String> = []
    var members: Set<String> = []
    var albums: Set<String> = []
    var people: Set<String> = []
    var locked: [String: Bool] = [:]

    var isEmpty: Bool { !reset && assets.isEmpty && members.isEmpty && albums.isEmpty && people.isEmpty && locked.isEmpty }
}

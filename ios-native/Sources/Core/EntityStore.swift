import CryptoKit
import Foundation
import SQLite3

/// Durable server entities and checkpoint journal. All SQLite access is actor isolated;
/// data and its acknowledgement are committed together before the server advances.
actor EntityStore {
    nonisolated let scope: String
    nonisolated let userID: String
    private let database: EntityDatabase
    private var generation = UUID()

    init(scope: String, userID: String, directory: URL? = nil) throws {
        self.scope = scope; self.userID = userID
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("IlyichEntities", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var protectedRoot = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedRoot.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        database = try EntityDatabase(url: root.appendingPathComponent(name + ".sqlite"))
    }

    func epoch() -> UUID { generation }
    func isComplete() throws -> Bool { try metadata("complete") == "1" }
    func lastSyncDate() throws -> Date? { try metadata("completedAt").flatMap(APIDate.parse) }
    func statistics() throws -> EntityStoreStatistics {
        var counts: [String: Int] = [:]
        for row in try database.query("SELECT kind,count(*) FROM entities GROUP BY kind") { if let kind = row[0], let count = row[1].flatMap(Int.init) { counts[kind] = count } }
        return try EntityStoreStatistics(counts: counts, lastSync: lastSyncDate(), isComplete: isComplete())
    }
    /// Access changes survive a later stream failure, allowing the UI to discard
    /// stale media even when the overall sync did not return a success summary.
    func takeAccessInvalidation() throws -> Bool {
        let changed = try metadata("accessInvalidated") == "1"
        if changed { try setMetadata("accessInvalidated", "0") }
        return changed
    }
    /// New login or a removed local database must never inherit server-only cursors.
    func prepare(sessionFingerprint: String) throws -> Bool {
        try Task.checkCancellation()
        if try metadata("session") != sessionFingerprint {
            if try metadata("session") != nil { generation = UUID() }
            try database.transaction {
                try database.execute("DELETE FROM entities"); try database.execute("DELETE FROM acknowledgements")
                try database.execute("DELETE FROM metadata")
                try setMetadata("session", sessionFingerprint); try setMetadata("needsReset", "1")
            }
        }
        return try metadata("needsReset") == "1"
    }
    func markResetRequested() throws { try Task.checkCancellation(); try setMetadata("needsReset", "0") }
    func pendingAcknowledgements() throws -> [String] {
        try database.query("SELECT ack FROM acknowledgements ORDER BY rowid").compactMap { $0[0] }
    }
    func acknowledged(_ acks: [String]) throws {
        try database.transaction {
            for ack in acks { try database.execute("DELETE FROM acknowledgements WHERE ack=?", [ack]) }
        }
    }
    func clear() throws {
        generation = UUID()
        try database.transaction {
            try database.execute("DELETE FROM entities"); try database.execute("DELETE FROM acknowledgements"); try database.execute("DELETE FROM metadata")
        }
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func apply(_ events: [EntitySyncEvent], epoch: UUID) throws -> SyncChangeSummary {
        guard epoch == generation else { throw CancellationError() }
        var summary = SyncChangeSummary()
        try database.transaction {
            for event in events {
                try Task.checkCancellation()
                if event.type == "SyncResetV1" {
                    try database.execute("DELETE FROM entities"); try database.execute("DELETE FROM acknowledgements")
                    try setMetadata("complete", "0"); summary.reset = true; summary.changed = true; summary.accessChanged = true
                } else if event.type == "SyncCompleteV1" {
                    try setMetadata("complete", "1"); try setMetadata("completedAt", Date().ISO8601Format())
                    summary.completed = true
                } else if event.type != "SyncAckV1" {
                    try applyEntity(event, summary: &summary)
                }
                // A backfill completion uses SyncAckV1 with another entity's ack type.
                guard !event.ackType.isEmpty, event.ack.contains("|") else { throw invalidSync() }
                try database.execute("INSERT INTO acknowledgements(type,ack) VALUES(?,?) ON CONFLICT(type) DO UPDATE SET ack=excluded.ack", [event.ackType, event.ack])
            }
            if summary.accessChanged { try setMetadata("accessInvalidated", "1") }
        }
        return summary
    }

    func entityData(kind: String, id: String) throws -> Data? {
        try database.query("SELECT payload FROM entities WHERE kind=? AND id=?", [kind, id]).first?[0].map { Data($0.utf8) }
    }
    func entityData(kind: String, offset: Int = 0, limit: Int = 200) throws -> [Data] {
        try database.query("SELECT payload FROM entities WHERE kind=? ORDER BY id LIMIT ? OFFSET ?", [kind, String(min(max(limit, 1), 2_000)), String(max(offset, 0))]).compactMap { $0[0].map { Data($0.utf8) } }
    }
    func asset(id: String) throws -> Asset? {
        guard let data = try entityData(kind: "asset", id: id) else { return nil }
        var result = try decodeAsset(data)
        if let ownerID = result.ownerId, let owner = try entityData(kind: "user", id: ownerID) { result.owner = try APIJSON.decoder().decode(User.self, from: owner) }
        result.people = try database.query("SELECT DISTINCT p.payload FROM entities f JOIN entities p ON p.kind='person' AND p.id=json_extract(f.payload,'$.personId') WHERE f.kind='face' AND json_extract(f.payload,'$.assetId')=? AND json_extract(f.payload,'$.deletedAt') IS NULL AND json_extract(f.payload,'$.isVisible')=1", [id]).compactMap { row in
            try row[0].map { try APIJSON.decoder().decode(Person.self, from: Data($0.utf8)) }
        }
        return result
    }
    func memories(onCivilDate day: String) throws -> [Memory] {
        let preference = try database.query("SELECT json_extract(payload,'$.value.memories.enabled') FROM entities WHERE kind='userMetadata' AND json_extract(payload,'$.userId')=? AND json_extract(payload,'$.key')='preferences'", [userID]).first?[0]
        guard preference != "0" else { return [] }
        let rows = try database.query("""
        SELECT payload FROM entities WHERE kind='memory' AND json_extract(payload,'$.ownerId')=?
        AND json_extract(payload,'$.deletedAt') IS NULL
        AND (json_extract(payload,'$.showAt') IS NULL OR julianday(json_extract(payload,'$.showAt'))<=julianday(?))
        AND (json_extract(payload,'$.hideAt') IS NULL OR julianday(json_extract(payload,'$.hideAt'))>=julianday(?))
        ORDER BY json_extract(payload,'$.showAt') IS NULL,julianday(json_extract(payload,'$.showAt')) DESC,julianday(json_extract(payload,'$.memoryAt')) DESC
        """, [userID, day, day])
        return try rows.compactMap { row in
            guard let payload = row[0] else { return nil }
            var object = try JSONDecoder().decode([String: EntityJSON].self, from: Data(payload.utf8))
            guard let id = object["id"]?.string else { return nil }
            let assetRows = try database.query("""
            SELECT a.payload FROM entities r JOIN entities a ON a.kind='asset' AND a.id=json_extract(r.payload,'$.assetId')
            WHERE r.kind='memoryAsset' AND json_extract(r.payload,'$.memoryId')=?
            AND json_extract(a.payload,'$.visibility')='timeline' AND json_extract(a.payload,'$.deletedAt') IS NULL
            AND NOT EXISTS(SELECT 1 FROM entities f JOIN entities p ON p.kind='person' AND p.id=json_extract(f.payload,'$.personId')
                           WHERE f.kind='face' AND json_extract(f.payload,'$.assetId')=a.id AND json_extract(p.payload,'$.isHidden')=1)
            ORDER BY julianday(json_extract(a.payload,'$.fileCreatedAt')) ASC,a.id
            """, [id])
            object["assets"] = .array([])
            var memory = try APIJSON.decoder().decode(Memory.self, from: JSONEncoder().encode(object))
            memory.assets = try assetRows.compactMap { row in
                try row[0].map { try decodeAsset(Data($0.utf8)) }
            }
            return memory.assets.isEmpty ? nil : memory
        }
    }
    func timelineAssets(filter: TimelineFilter = .init(), offset: Int = 0, limit: Int = 200) throws -> [Asset] {
        let (whereSQL, arguments) = timelinePredicate(filter)
        let date = filter.orderBy == "createdAt" ? "createdAt" : "localDateTime"
        let rows = try database.query("SELECT a.payload FROM entities a WHERE \(whereSQL) ORDER BY julianday(json_extract(a.payload,'$.\(date)')) \(filter.order == "asc" ? "ASC" : "DESC"), a.id LIMIT ? OFFSET ?", arguments + [String(min(max(limit, 1), 2_000)), String(max(offset, 0))])
        return try rows.compactMap { try $0[0].map { try decodeAsset(Data($0.utf8)) } }
    }
    func timeBuckets(filter: TimelineFilter = .init()) throws -> [TimeBucket] {
        let (whereSQL, arguments) = timelinePredicate(filter)
        let date = filter.orderBy == "createdAt" ? "createdAt" : "localDateTime"
        return try database.query("SELECT strftime('%Y-%m-01',json_extract(a.payload,'$.\(date)')),count(*) FROM entities a WHERE \(whereSQL) GROUP BY 1 ORDER BY 1 \(filter.order == "asc" ? "ASC" : "DESC")", arguments).compactMap {
            guard let bucket = $0[0], let count = $0[1].flatMap(Int.init) else { return nil }
            return TimeBucket(timeBucket: bucket, count: count)
        }
    }
    func timeBucket(_ bucket: String, filter: TimelineFilter = .init()) throws -> [Asset] {
        let (whereSQL, arguments) = timelinePredicate(filter)
        let date = filter.orderBy == "createdAt" ? "createdAt" : "localDateTime"
        return try database.query("SELECT a.payload FROM entities a WHERE \(whereSQL) AND strftime('%Y-%m',json_extract(a.payload,'$.\(date)'))=? ORDER BY julianday(json_extract(a.payload,'$.\(date)')) \(filter.order == "asc" ? "ASC" : "DESC"),a.id", arguments + [String(bucket.prefix(7))]).compactMap {
            try $0[0].map { try decodeAsset(Data($0.utf8)) }
        }
    }
    /// Small identity rows for old Flutter uploads and native uploads alike. The
    /// current server no longer syncs obsolete deviceId/deviceAssetId columns.
    func localAssetMatches(offset: Int = 0, limit: Int = 1_000) throws -> [LocalAssetMatch] {
        let rows = try database.query("""
        SELECT a.id,json_extract(a.payload,'$.checksum'),json_extract(m.payload,'$.value')
        FROM entities a LEFT JOIN entities m ON m.kind='assetMetadata' AND json_extract(m.payload,'$.assetId')=a.id AND json_extract(m.payload,'$.key')='mobile-app'
        WHERE a.kind='asset' AND json_extract(a.payload,'$.ownerId')=?
        ORDER BY a.id LIMIT ? OFFSET ?
        """, [userID, String(min(max(limit, 1), 5_000)), String(max(offset, 0))])
        return try rows.compactMap { row in
            guard let id = row[0], let checksum = row[1] else { return nil }
            let metadata = try row[2].map { try JSONDecoder().decode([String: EntityJSON].self, from: Data($0.utf8)) } ?? [:]
            func string(_ key: String) -> String? { metadata[key]?.string }
            func number(_ key: String) -> Double? {
                switch metadata[key] { case .number(let v): v; case .integer(let v): Double(v); case .string(let v): Double(v); default: nil }
            }
            func date(_ key: String) -> Date? {
                if let value = string(key), let date = APIDate.parse(value) { return date }
                guard let value = number(key), value.isFinite else { return nil }
                return Date(timeIntervalSince1970: value)
            }
            return LocalAssetMatch(assetID: id, checksum: checksum, cloudID: string("iCloudId"), createdAt: date("createdAt"), adjustmentTime: date("adjustmentTime"), latitude: number("latitude"), longitude: number("longitude"))
        }
    }
    func albums() throws -> [Album] {
        try database.query("SELECT payload FROM entities WHERE kind='album' ORDER BY json_extract(payload,'$.name') COLLATE NOCASE").compactMap { row in
            guard let text = row[0] else { return nil }
            var object = try JSONDecoder().decode([String: EntityJSON].self, from: Data(text.utf8))
            guard let id = object["id"]?.string else { throw invalidSync() }
            let count = try database.query("SELECT count(*) FROM entities WHERE kind='albumAsset' AND json_extract(payload,'$.albumId')=?", [id]).first?[0].flatMap(Int.init) ?? 0
            let users = try database.query("SELECT u.payload,r.payload FROM entities r JOIN entities u ON u.kind='user' AND u.id=json_extract(r.payload,'$.userId') WHERE r.kind='albumUser' AND json_extract(r.payload,'$.albumId')=?", [id]).compactMap { row -> EntityJSON? in
                guard let user = row[0], let relation = row[1] else { return nil }
                let r = try JSONDecoder().decode([String: EntityJSON].self, from: Data(relation.utf8))
                return .object(["user": try JSONDecoder().decode(EntityJSON.self, from: Data(user.utf8)), "role": r["role"] ?? .string("viewer")])
            }
            object["albumName"] = object["name"]; object["albumThumbnailAssetId"] = object["thumbnailAssetId"]
            object["assetCount"] = .integer(Int64(count)); object["shared"] = .bool(users.count > 1); object["albumUsers"] = .array(users)
            return try APIJSON.decoder().decode(Album.self, from: JSONEncoder().encode(object))
        }
    }
    func people() throws -> [Person] {
        try database.query("SELECT payload FROM entities WHERE kind='person' ORDER BY json_extract(payload,'$.name') COLLATE NOCASE").compactMap { row in
            try row[0].map { try APIJSON.decoder().decode(Person.self, from: Data($0.utf8)) }
        }
    }

    /// Mirrors the server's `GET /partners`: the other user of each relationship, with the relationship's `inTimeline`.
    func partners(direction: String) throws -> [Partner] {
        let (mine, theirs): (String, String)
        switch direction {
        case "shared-with": (mine, theirs) = ("sharedWithId", "sharedById")
        case "shared-by": (mine, theirs) = ("sharedById", "sharedWithId")
        default: throw APIError.invalidResponse("Unsupported partner direction.")
        }
        return try database.query("SELECT u.payload,p.payload FROM entities p JOIN entities u ON u.kind='user' AND u.id=json_extract(p.payload,'$.\(theirs)') WHERE p.kind='partner' AND json_extract(p.payload,'$.\(mine)')=? AND json_extract(u.payload,'$.deletedAt') IS NULL ORDER BY json_extract(u.payload,'$.name') COLLATE NOCASE, u.id", [userID]).compactMap { row in
            guard let user = row[0], let relation = row[1] else { return nil }
            var object = try JSONDecoder().decode([String: EntityJSON].self, from: Data(user.utf8))
            object["inTimeline"] = try JSONDecoder().decode([String: EntityJSON].self, from: Data(relation.utf8))["inTimeline"]
            return try APIJSON.decoder().decode(Partner.self, from: JSONEncoder().encode(object))
        }
    }

    func assetOCR(id: String) throws -> [RecognizedText] {
        guard try entityData(kind: "asset", id: id) != nil else { return [] }
        return try database.query("SELECT payload FROM entities WHERE kind='ocr' AND json_extract(payload,'$.assetId')=? AND json_extract(payload,'$.isVisible')=1 ORDER BY id", [id]).compactMap { row in
            try row[0].map { try JSONDecoder().decode(RecognizedText.self, from: Data($0.utf8)) }
        }
    }

    private func applyEntity(_ event: EntitySyncEvent, summary: inout SyncChangeSummary) throws {
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
        summary.changed = true
        if kind == "asset" {
            if summary.assetIDs.count < 2_000 { summary.assetIDs.insert(id) }
            if delete || object["visibility"]?.string == "locked" {
                try deleteAsset(id)
                summary.accessChanged = true
                if summary.deletedAssetIDs.count < 2_000 { summary.deletedAssetIDs.insert(id) }
                return
            }
        }
        if let assetID = object["assetId"]?.string, ["exif", "edit", "ocr", "assetMetadata", "face"].contains(kind) {
            // Locked assets are never persisted, including their EXIF, OCR or faces.
            guard try entityData(kind: "asset", id: assetID) != nil else { return }
            if summary.assetIDs.count < 2_000 { summary.assetIDs.insert(assetID) }
        }
        if delete {
            try database.execute("DELETE FROM entities WHERE kind=? AND id=?", [kind, id])
            if kind == "album" { try deleteAlbum(id) }
            if kind == "memory" { try database.execute("DELETE FROM entities WHERE kind='memoryAsset' AND json_extract(payload,'$.memoryId')=?", [id]) }
            if kind == "person" { try database.execute("DELETE FROM entities WHERE kind='face' AND json_extract(payload,'$.personId')=?", [id]) }
            if kind == "user" { try deleteOwnedAssets(id) }
        } else {
            let encoded = try JSONEncoder().encode(object)
            try database.execute("INSERT INTO entities(kind,id,payload) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload", [kind, id, String(decoding: encoded, as: UTF8.self)])
        }
        if kind != "asset" && kind != "exif" { summary.collectionsChanged = true }
        if delete, kind == "albumUser", object["userId"]?.string == userID, let albumID = object["albumId"]?.string { try deleteAlbum(albumID) }
        if delete && ["partner", "albumUser", "album", "albumAsset", "user"].contains(kind) {
            summary.accessChanged = true
            try purgeInaccessibleAssets()
        }
    }
    private func deleteAsset(_ id: String) throws {
        try database.execute("DELETE FROM entities WHERE (kind='asset' AND id=?) OR (kind IN ('exif','edit','ocr','assetMetadata','face','albumAsset','memoryAsset') AND json_extract(payload,'$.assetId')=?)", [id, id])
    }
    private func deleteAlbum(_ id: String) throws {
        try database.execute("DELETE FROM entities WHERE (kind='album' AND id=?) OR (kind IN ('albumUser','albumAsset') AND json_extract(payload,'$.albumId')=?)", [id, id])
    }
    private func deleteOwnedAssets(_ ownerID: String) throws {
        for row in try database.query("SELECT id FROM entities WHERE kind='asset' AND json_extract(payload,'$.ownerId')=?", [ownerID]) { if let id = row[0] { try deleteAsset(id) } }
    }
    private func purgeInaccessibleAssets() throws {
        let rows = try database.query("""
        SELECT a.id FROM entities a WHERE a.kind='asset' AND json_extract(a.payload,'$.ownerId')!=?
        AND NOT EXISTS(SELECT 1 FROM entities p WHERE p.kind='partner' AND json_extract(p.payload,'$.sharedById')=json_extract(a.payload,'$.ownerId') AND json_extract(p.payload,'$.sharedWithId')=?)
        AND NOT EXISTS(SELECT 1 FROM entities r JOIN entities u ON u.kind='albumUser' AND json_extract(u.payload,'$.albumId')=json_extract(r.payload,'$.albumId') AND json_extract(u.payload,'$.userId')=? WHERE r.kind='albumAsset' AND json_extract(r.payload,'$.assetId')=a.id)
        """, [userID, userID, userID])
        for row in rows { if let id = row[0] { try deleteAsset(id) } }
    }
    private func decodeAsset(_ data: Data) throws -> Asset {
        let object = try JSONDecoder().decode([String: EntityJSON].self, from: data)
        var asset = try APIJSON.decoder().decode(Asset.self, from: data)
        asset.isTrashed = object["deletedAt"] != nil && object["deletedAt"] != .null
        if asset.ownerId != userID { asset.isFavorite = false }
        if let exif = try entityData(kind: "exif", id: asset.id) { asset.exifInfo = try APIJSON.decoder().decode(ExifInfo.self, from: exif) }
        if let stackID = object["stackId"]?.string, let data = try entityData(kind: "stack", id: stackID) {
            let stack = try JSONDecoder().decode([String: EntityJSON].self, from: data)
            if let primary = stack["primaryAssetId"]?.string {
                let count = try database.query("SELECT count(*) FROM entities WHERE kind='asset' AND json_extract(payload,'$.stackId')=?", [stackID]).first?[0].flatMap(Int.init) ?? 0
                asset.stack = .init(id: stackID, primaryAssetId: primary, assetCount: count)
            }
        }
        return asset
    }
    private func timelinePredicate(_ filter: TimelineFilter) -> (String, [String?]) {
        var conditions = ["a.kind='asset'", "json_extract(a.payload,'$.visibility')!='locked'"]
        var values: [String?] = []
        if let visibility = filter.visibility { conditions.append("json_extract(a.payload,'$.visibility')=?"); values.append(visibility.rawValue) }
        else { conditions.append("json_extract(a.payload,'$.visibility') IN ('timeline','archive')") }
        conditions.append("json_extract(a.payload,'$.deletedAt') IS \(filter.isTrashed == true ? "NOT " : "")NULL")
        if let favorite = filter.isFavorite { conditions.append("json_extract(a.payload,'$.isFavorite')=CAST(? AS INTEGER)"); values.append(favorite ? "1" : "0") }
        if let album = filter.albumID {
            conditions.append("EXISTS(SELECT 1 FROM entities r WHERE r.kind='albumAsset' AND json_extract(r.payload,'$.assetId')=a.id AND json_extract(r.payload,'$.albumId')=?)"); values.append(album)
        }
        if let person = filter.personID {
            conditions.append("EXISTS(SELECT 1 FROM entities f WHERE f.kind='face' AND json_extract(f.payload,'$.assetId')=a.id AND json_extract(f.payload,'$.personId')=? AND json_extract(f.payload,'$.deletedAt') IS NULL AND json_extract(f.payload,'$.isVisible')=1)"); values.append(person)
        }
        if filter.albumID == nil || filter.userID != nil {
            var owners = ["json_extract(a.payload,'$.ownerId')=?"]
            values.append(filter.userID ?? userID)
            if filter.withPartners {
                owners.append("EXISTS(SELECT 1 FROM entities p WHERE p.kind='partner' AND json_extract(p.payload,'$.sharedById')=json_extract(a.payload,'$.ownerId') AND json_extract(p.payload,'$.sharedWithId')=?\(filter.personID == nil ? " AND json_extract(p.payload,'$.inTimeline')=1" : ""))")
                values.append(userID)
            }
            if filter.personID != nil {
                owners.append("EXISTS(SELECT 1 FROM entities r JOIN entities u ON u.kind='albumUser' AND json_extract(u.payload,'$.albumId')=json_extract(r.payload,'$.albumId') AND json_extract(u.payload,'$.userId')=? WHERE r.kind='albumAsset' AND json_extract(r.payload,'$.assetId')=a.id)")
                values.append(userID)
            }
            conditions.append("(" + owners.joined(separator: " OR ") + ")")
        }
        if filter.withStacked {
            conditions.append("NOT EXISTS(SELECT 1 FROM entities s WHERE s.kind='stack' AND s.id=json_extract(a.payload,'$.stackId') AND json_extract(s.payload,'$.primaryAssetId')!=a.id)")
        }
        return (conditions.joined(separator: " AND "), values)
    }
    private func metadata(_ key: String) throws -> String? { try database.query("SELECT value FROM metadata WHERE key=?", [key]).first?[0] }
    private func setMetadata(_ key: String, _ value: String) throws { try database.execute("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value]) }
    private func invalidSync() -> APIError { .invalidResponse("The server sent an invalid synchronization record. Your saved cursor was not advanced.") }
}

/// This handle never escapes EntityStore; Sendable permits ownership transfer at init.
private final class EntityDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    init(url: URL) throws {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }; throw Self.failure()
        }
        handle = opened
        do {
            try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA synchronous=FULL"); try execute("PRAGMA secure_delete=ON")
            try execute("CREATE TABLE IF NOT EXISTS entities(kind TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(kind,id))")
            try execute("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS acknowledgements(type TEXT PRIMARY KEY,ack TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS entity_asset ON entities(kind,json_extract(payload,'$.assetId'))")
            try execute("CREATE INDEX IF NOT EXISTS entity_album ON entities(kind,json_extract(payload,'$.albumId'))")
            try execute("CREATE INDEX IF NOT EXISTS entity_memory ON entities(kind,json_extract(payload,'$.memoryId'))")
            try execute("CREATE INDEX IF NOT EXISTS asset_stack ON entities(kind,json_extract(payload,'$.stackId'))")
            try execute("CREATE INDEX IF NOT EXISTS asset_timeline ON entities(kind,json_extract(payload,'$.ownerId'),json_extract(payload,'$.visibility'),json_extract(payload,'$.localDateTime'))")
            sqlite3_busy_timeout(handle, 5_000)
        } catch { throw error }
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ arguments: [String?] = []) throws { _ = try query(sql, arguments) }
    func query(_ sql: String, _ arguments: [String?] = []) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Self.failure() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in arguments.enumerated() {
            let status: Int32
            if let value { status = sqlite3_bind_text(statement, Int32(offset + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            else { status = sqlite3_bind_null(statement, Int32(offset + 1)) }
            guard status == SQLITE_OK else { throw Self.failure() }
        }
        var rows: [[String?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw Self.failure() }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                guard let pointer = sqlite3_column_text(statement, column) else { return nil }
                return String(cString: pointer)
            })
        }
    }
    func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try operation(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private static func failure() -> APIError { .invalidResponse("The offline library could not be saved. Free some device storage, then try again.") }
}

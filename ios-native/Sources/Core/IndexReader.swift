import Foundation

/// A read-only connection to the offline library on a serial queue of its own: `viewport` at
/// user-initiated priority for what the screen waits on, `aggregate` at utility for counts, lists
/// and maps. Each reads the last committed state, so it never waits for the writer's batches and
/// never sees half of one. Feeds, map markers and memberships read the derived tables (Q3), which
/// a caller uses only once `isReadable`; single records still read the entities.
actor IndexReader {
    private nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    nonisolated let path: String
    nonisolated let userID: String
    private var connection: SQLiteConnection?

    init(path: String, userID: String, label: String, qos: DispatchQoS) {
        self.path = path
        self.userID = userID
        queue = DispatchSerialQueue(label: label, qos: qos)
    }

    /// The connection, opened at first use: the writer has created the file and its tables by then.
    private var database: SQLiteConnection {
        get throws {
            if let connection { return connection }
            let opened = try SQLiteConnection(path: path, readOnly: true, busyTimeout: 5_000)
            connection = opened
            return opened
        }
    }

    func isComplete() throws -> Bool { try metadata("complete") == "1" }
    func lastSyncDate() throws -> Date? { try metadata("completedAt").flatMap(APIDate.parse) }
    func statistics() throws -> EntityStoreStatistics {
        var counts: [String: Int] = [:]
        for row in try database.query("SELECT kind,count(*) FROM entities GROUP BY kind") { if let kind = row[0], let count = row[1].flatMap(Int.init) { counts[kind] = count } }
        return try EntityStoreStatistics(counts: counts, lastSync: lastSyncDate(), isComplete: isComplete())
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
    // MARK: Feeds

    /// Whether the feeds can be read here: the first sync is complete and the derived tables hold
    /// every entity. Read in one statement, so the two agree.
    func isReadable() throws -> Bool {
        try database.query("SELECT (SELECT value FROM metadata WHERE key='complete')='1' AND (SELECT queryable FROM index_state WHERE id=1)=1").first?[0] == "1"
    }

    /// A feed's photos across months, newest first by the time taken unless the feed asks otherwise.
    func timelineAssets(filter: TimelineFilter = .init(), offset: Int = 0, limit: Int = 200) throws -> [Asset] {
        let (whereSQL, arguments) = feedPredicate(filter)
        let rows = try database.query("\(Self.feedSelect) WHERE \(whereSQL) ORDER BY \(Self.order(filter, month: false)) LIMIT ? OFFSET ?",
                                      arguments + [String(min(max(limit, 1), 2_000)), String(max(offset, 0))])
        return try decodeTimelineRows(rows)
    }

    /// A feed's months, newest first unless it asks otherwise, with how many photos each holds.
    func timeBuckets(filter: TimelineFilter = .init()) throws -> [TimeBucket] {
        let (whereSQL, arguments) = feedPredicate(filter)
        let month = Self.monthColumn(filter)
        return try database.query("SELECT \(month)||'-01',count(*) FROM asset_index i WHERE \(whereSQL) AND \(month) IS NOT NULL GROUP BY \(month) ORDER BY \(month) \(Self.direction(filter))", arguments).compactMap {
            guard let bucket = $0[0], let count = $0[1].flatMap(Int.init) else { return nil }
            return TimeBucket(timeBucket: bucket, count: count)
        }
    }

    /// One month of a feed, by the time taken (or added, in created-at order), newest first unless
    /// the feed asks otherwise, then by ID.
    func timeBucket(_ bucket: String, filter: TimelineFilter = .init()) throws -> [Asset] {
        let (sql, arguments) = timeBucketQuery(bucket, filter: filter)
        return try decodeTimelineRows(try database.query(sql, arguments))
    }

    /// What SQLite plans for a month's query, for tests and diagnostics.
    func timeBucketPlan(_ bucket: String, filter: TimelineFilter = .init()) throws -> [String] {
        let (sql, arguments) = timeBucketQuery(bucket, filter: filter)
        return try database.query("EXPLAIN QUERY PLAN " + sql, arguments).compactMap { $0.last ?? nil }
    }

    private func timeBucketQuery(_ bucket: String, filter: TimelineFilter) -> (String, [String?]) {
        let (whereSQL, arguments) = feedPredicate(filter)
        return ("\(Self.feedSelect) WHERE \(Self.monthColumn(filter))=? AND \(whereSQL) ORDER BY \(Self.order(filter, month: true))",
                [String(bucket.prefix(7))] + arguments)
    }

    /// Located photos per month and place, for naming months and marking trips on the time rail.
    func monthPlaces(filter: TimelineFilter = .init()) throws -> [MonthPlaceCount] {
        let (whereSQL, arguments) = feedPredicate(filter)
        let month = Self.monthColumn(filter)
        return try database.query("""
        SELECT \(month)||'-01',json_extract(e.payload,'$.city'),json_extract(e.payload,'$.country'),count(*)
        FROM asset_index i JOIN entities e ON e.kind='exif' AND e.id=i.id
        WHERE \(whereSQL) AND \(month) IS NOT NULL AND (json_extract(e.payload,'$.city') IS NOT NULL OR json_extract(e.payload,'$.country') IS NOT NULL)
        GROUP BY 1,2,3
        """, arguments).compactMap { row in
            guard let bucket = row[0], let count = row[3].flatMap(Int.init) else { return nil }
            return MonthPlaceCount(bucket: bucket, city: row[1], country: row[2], count: count)
        }
    }

    private static func monthColumn(_ filter: TimelineFilter) -> String { filter.orderBy == "createdAt" ? "i.created_month" : "i.local_month" }
    private static func direction(_ filter: TimelineFilter) -> String { filter.order == "asc" ? "ASC" : "DESC" }
    /// The library's order: the time taken, or the time added, newest first unless the feed asks
    /// otherwise, then the ID, ascending either way. Across months the month leads, which the time
    /// already decides. The columns follow asset_index_taken and asset_index_added, so SQLite reads
    /// a month newest first in order without sorting it.
    private static func order(_ filter: TimelineFilter, month: Bool) -> String {
        let way = direction(filter)
        let time = filter.orderBy == "createdAt" ? "i.created_at" : "i.local_date_time"
        return ((month ? [] : ["\(monthColumn(filter)) \(way)"]) + ["\(time) \(way)", "i.id ASC"]).joined(separator: ",")
    }

    /// One query brings each photo with its EXIF and the fields the timeline reads from the
    /// derived row, instead of a query and two JSON passes per photo. A 4,000-photo month matters.
    private static let feedSelect = "SELECT a.payload,e.payload,i.trashed,i.stack_id FROM asset_index i "
        + "JOIN entities a ON a.kind='asset' AND a.id=i.id LEFT JOIN entities e ON e.kind='exif' AND e.id=i.id"

    private func decodeTimelineRows(_ rows: [[String?]]) throws -> [Asset] {
        let decoder = APIJSON.decoder()
        let stacks = try self.stacks(ids: Set(rows.compactMap { $0[3] }))
        return try rows.compactMap { row in
            guard let payload = row[0] else { return nil }
            var asset = try decoder.decode(Asset.self, from: Data(payload.utf8))
            asset.isTrashed = row[2] == "1"
            if asset.ownerId != userID { asset.isFavorite = false }
            if let exif = row[1] { asset.exifInfo = try decoder.decode(ExifInfo.self, from: Data(exif.utf8)) }
            if let stackID = row[3] { asset.stack = stacks[stackID] }
            return asset
        }
    }

    /// The stacks of a page of photos, in one query. A stack counts its photos the way the server
    /// does: those in the timeline and not in the trash.
    private func stacks(ids: Set<String>) throws -> [String: AssetStack] {
        guard !ids.isEmpty else { return [:] }
        let list = String(decoding: try JSONEncoder().encode(ids.sorted()), as: UTF8.self)
        var stacks: [String: AssetStack] = [:]
        for row in try database.query("""
        SELECT s.id,json_extract(s.payload,'$.primaryAssetId'),
               (SELECT count(*) FROM asset_index c WHERE c.stack_id=s.id AND c.trashed=0 AND c.visibility='timeline')
        FROM entities s WHERE s.kind='stack' AND s.id IN (SELECT value FROM json_each(?))
        """, [list]) {
            guard let id = row[0], let primary = row[1] else { continue }
            stacks[id] = .init(id: id, primaryAssetId: primary, assetCount: row[2].flatMap(Int.init) ?? 0)
        }
        return stacks
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
    /// Every album with its photo count and its users, in three queries however many albums.
    func albums() throws -> [Album] {
        var counts: [String: Int] = [:]
        for row in try database.query("SELECT album_id,count(*) FROM album_member GROUP BY album_id") {
            if let id = row[0] { counts[id] = row[1].flatMap(Int.init) ?? 0 }
        }
        let users = try albumUsers(of: nil)
        return try database.query("SELECT id,payload FROM entities WHERE kind='album' ORDER BY json_extract(payload,'$.name') COLLATE NOCASE").compactMap { row in
            guard let id = row[0], let payload = row[1] else { return nil }
            return try albumFromPayload(payload, count: counts[id] ?? 0, users: users[id] ?? [])
        }
    }
    func album(id: String) throws -> Album? {
        guard let text = try database.query("SELECT payload FROM entities WHERE kind='album' AND id=?", [id]).first?[0] else { return nil }
        let count = try database.query("SELECT count(*) FROM album_member WHERE album_id=?", [id]).first?[0].flatMap(Int.init) ?? 0
        return try albumFromPayload(text, count: count, users: albumUsers(of: id)[id] ?? [])
    }
    /// The users of one album, or of every album, by album.
    private func albumUsers(of albumID: String?) throws -> [String: [EntityJSON]] {
        let filter = albumID == nil ? "" : " AND json_extract(r.payload,'$.albumId')=?"
        var users: [String: [EntityJSON]] = [:]
        for row in try database.query("SELECT json_extract(r.payload,'$.albumId'),u.payload,json_extract(r.payload,'$.role') FROM entities r JOIN entities u ON u.kind='user' AND u.id=json_extract(r.payload,'$.userId') WHERE r.kind='albumUser'\(filter) ORDER BY r.id",
                                      albumID.map { [$0] } ?? []) {
            guard let album = row[0], let user = row[1] else { continue }
            users[album, default: []].append(.object(["user": try JSONDecoder().decode(EntityJSON.self, from: Data(user.utf8)), "role": .string(row[2] ?? "viewer")]))
        }
        return users
    }
    private func albumFromPayload(_ text: String, count: Int, users: [EntityJSON]) throws -> Album {
        var object = try JSONDecoder().decode([String: EntityJSON].self, from: Data(text.utf8))
        object["albumName"] = object["name"]; object["albumThumbnailAssetId"] = object["thumbnailAssetId"]
        object["assetCount"] = .integer(Int64(count)); object["shared"] = .bool(users.count > 1); object["albumUsers"] = .array(users)
        return try APIJSON.decoder().decode(Album.self, from: JSONEncoder().encode(object))
    }
    func person(id: String) throws -> Person? {
        try entityData(kind: "person", id: id).map { try APIJSON.decoder().decode(Person.self, from: $0) }
    }
    func people() throws -> [Person] {
        try database.query("SELECT payload FROM entities WHERE kind='person' ORDER BY json_extract(payload,'$.name') COLLATE NOCASE").compactMap { row in
            try row[0].map { try APIJSON.decoder().decode(Person.self, from: Data($0.utf8)) }
        }
    }

    /// Mirrors GET /map/markers from the derived rows, EXIF, partners and albums. Projection stays
    /// limited to the six marker fields.
    func mapMarkers(_ query: MapMarkerQuery) throws -> [MapMarker] {
        var conditions = [
            "json_extract(e.payload,'$.latitude') IS NOT NULL", "json_extract(e.payload,'$.longitude') IS NOT NULL", "i.trashed=0"
        ]
        var arguments: [String?] = []
        if query.isArchived == true {
            conditions.append("(i.visibility='timeline' OR (i.owner_id=? AND i.visibility='archive'))")
            arguments.append(userID)
        } else {
            conditions.append("i.visibility='timeline'")
        }
        if let favorite = query.isFavorite {
            conditions.append("i.favorite=CAST(? AS INTEGER)")
            arguments.append(favorite ? "1" : "0")
        }
        if let date = query.fileCreatedAfter {
            conditions.append("i.file_created_at>=julianday(?)")
            arguments.append(date.ISO8601Format())
        }
        if let date = query.fileCreatedBefore {
            conditions.append("i.file_created_at<=julianday(?)")
            arguments.append(date.ISO8601Format())
        }
        var scopes = ["i.owner_id=?"]
        arguments.append(userID)
        if query.withPartners {
            scopes.append("i.owner_id IN (SELECT json_extract(p.payload,'$.sharedById') FROM entities p JOIN entities u ON u.kind='user' AND u.id=json_extract(p.payload,'$.sharedById') WHERE p.kind='partner' AND json_extract(p.payload,'$.sharedWithId')=? AND json_extract(u.payload,'$.deletedAt') IS NULL)")
            arguments.append(userID)
        }
        if query.withSharedAlbums {
            scopes.append("i.id IN (SELECT m.asset_id FROM album_member m JOIN entities b ON b.kind='album' AND b.id=m.album_id WHERE json_extract(b.payload,'$.deletedAt') IS NULL AND m.album_id IN (SELECT json_extract(u.payload,'$.albumId') FROM entities u WHERE u.kind='albumUser' AND json_extract(u.payload,'$.userId')=?))")
            arguments.append(userID)
        }
        conditions.append("(" + scopes.joined(separator: " OR ") + ")")
        let rows = try database.query("""
        SELECT i.id,json_extract(e.payload,'$.latitude'),json_extract(e.payload,'$.longitude'),
               json_extract(e.payload,'$.city'),json_extract(e.payload,'$.state'),json_extract(e.payload,'$.country')
        FROM asset_index i JOIN entities e ON e.kind='exif' AND e.id=i.id
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY i.file_created_at DESC,i.id
        """, arguments)
        return rows.compactMap { row in
            guard let id = row[0], let latitude = row[1].flatMap(Double.init), let longitude = row[2].flatMap(Double.init) else { return nil }
            return MapMarker(id: id, lat: latitude, lon: longitude, city: row[3], state: row[4], country: row[5])
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
    private func decodeAsset(_ data: Data) throws -> Asset {
        let object = try JSONDecoder().decode([String: EntityJSON].self, from: data)
        var asset = try APIJSON.decoder().decode(Asset.self, from: data)
        asset.isTrashed = object["deletedAt"] != nil && object["deletedAt"] != .null
        if asset.ownerId != userID { asset.isFavorite = false }
        if let exif = try entityData(kind: "exif", id: asset.id) { asset.exifInfo = try APIJSON.decoder().decode(ExifInfo.self, from: exif) }
        if let stackID = object["stackId"]?.string, let data = try entityData(kind: "stack", id: stackID) {
            let stack = try JSONDecoder().decode([String: EntityJSON].self, from: data)
            if let primary = stack["primaryAssetId"]?.string {
                // Counted as the server counts a stack: its photos in the timeline, not in the trash.
                let count = try database.query("SELECT count(*) FROM entities WHERE kind='asset' AND json_extract(payload,'$.stackId')=? AND json_extract(payload,'$.deletedAt') IS NULL AND json_extract(payload,'$.visibility')='timeline'", [stackID]).first?[0].flatMap(Int.init) ?? 0
                asset.stack = .init(id: stackID, primaryAssetId: primary, assetCount: count)
            }
        }
        return asset
    }
    /// A feed's conditions on asset_index `i`. Membership comes from album_member and
    /// person_member, each read once rather than per photo.
    private func feedPredicate(_ filter: TimelineFilter) -> (String, [String?]) {
        var conditions = ["i.visibility!='locked'"]
        var values: [String?] = []
        if let visibility = filter.visibility { conditions.append("i.visibility=?"); values.append(visibility.rawValue) }
        else { conditions.append("i.visibility IN ('timeline','archive')") }
        conditions.append("i.trashed=\(filter.isTrashed == true ? 1 : 0)")
        if let favorite = filter.isFavorite { conditions.append("i.favorite=CAST(? AS INTEGER)"); values.append(favorite ? "1" : "0") }
        if let developed = filter.isDeveloped { conditions.append("i.developed=CAST(? AS INTEGER)"); values.append(developed ? "1" : "0") }
        if let album = filter.albumID {
            conditions.append("i.id IN (SELECT asset_id FROM album_member WHERE album_id=?)"); values.append(album)
        }
        if let person = filter.personID {
            conditions.append("i.id IN (SELECT asset_id FROM person_member WHERE person_id=?)"); values.append(person)
        }
        if let place = filter.place {
            // One parameter however many photos the place holds. They came from this account's
            // own map, so they need no owner check.
            conditions.append("i.id IN (SELECT value FROM json_each(?))")
            values.append(String(decoding: (try? JSONEncoder().encode(place.assetIDs)) ?? Data("[]".utf8), as: UTF8.self))
        }
        if (filter.albumID == nil && filter.place == nil) || filter.userID != nil {
            var owners = ["i.owner_id=?"]
            values.append(filter.userID ?? userID)
            if filter.withPartners {
                owners.append("i.owner_id IN (SELECT json_extract(p.payload,'$.sharedById') FROM entities p WHERE p.kind='partner' AND json_extract(p.payload,'$.sharedWithId')=?\(filter.personID == nil ? " AND json_extract(p.payload,'$.inTimeline')=1" : ""))")
                values.append(userID)
            }
            if filter.personID != nil {
                owners.append("i.id IN (SELECT m.asset_id FROM album_member m WHERE m.album_id IN (SELECT json_extract(u.payload,'$.albumId') FROM entities u WHERE u.kind='albumUser' AND json_extract(u.payload,'$.userId')=?))")
                values.append(userID)
            }
            conditions.append("(" + owners.joined(separator: " OR ") + ")")
        }
        if filter.withStacked {
            conditions.append("(i.stack_id IS NULL OR NOT EXISTS(SELECT 1 FROM entities s WHERE s.kind='stack' AND s.id=i.stack_id AND json_extract(s.payload,'$.primaryAssetId')!=i.id))")
        }
        return (conditions.joined(separator: " AND "), values)
    }
    private func metadata(_ key: String) throws -> String? { try database.query("SELECT value FROM metadata WHERE key=?", [key]).first?[0] }
}

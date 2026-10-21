import Foundation

/// A read-only connection to the offline library on a serial queue of its own: `viewport` at
/// user-initiated priority for what the screen waits on, `aggregate` at utility for counts, lists
/// and maps. Each reads the last committed state, so it never waits for the writer's batches and
/// never sees half of one. Until Q3 these run the same SQL over the entities as before Q2.
actor IndexReader {
    private nonisolated let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    nonisolated let path: String
    nonisolated let userID: String
    private var connection: SQLiteConnection?
    /// Whether each month index exists, by the date it indexes; absent until looked up.
    private var monthIndexes: [String: MonthIndex] = [:]
    private enum MonthIndex { case ready, missing, building, unavailable }
    /// Each month index being built, by the date it indexes.
    private var monthIndexBuilds: [String: Task<Void, Never>] = [:]

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
    func timelineAssets(filter: TimelineFilter = .init(), offset: Int = 0, limit: Int = 200) throws -> [Asset] {
        let (whereSQL, arguments) = timelinePredicate(filter)
        let date = filter.orderBy == "createdAt" ? "createdAt" : "localDateTime"
        let rows = try database.query("\(Self.timelineSelect) WHERE \(whereSQL) ORDER BY julianday(json_extract(a.payload,'$.\(date)')) \(filter.order == "asc" ? "ASC" : "DESC"), a.id LIMIT ? OFFSET ?", arguments + [String(min(max(limit, 1), 2_000)), String(max(offset, 0))])
        return try decodeTimelineRows(rows)
    }
    func timeBuckets(filter: TimelineFilter = .init()) throws -> [TimeBucket] {
        let (whereSQL, arguments) = timelinePredicate(filter)
        let date = filter.orderBy == "createdAt" ? "createdAt" : "localDateTime"
        return try database.query("SELECT strftime('%Y-%m-01',json_extract(a.payload,'$.\(date)')),count(*) FROM entities a WHERE \(whereSQL) GROUP BY 1 ORDER BY 1 \(filter.order == "asc" ? "ASC" : "DESC")", arguments).compactMap {
            guard let bucket = $0[0], let count = $0[1].flatMap(Int.init) else { return nil }
            return TimeBucket(timeBucket: bucket, count: count)
        }
    }
    /// One month of a feed. With `buildingIndex`, as the library's feed asks, a month read the slow
    /// way then starts building the index months are found by.
    func timeBucket(_ bucket: String, filter: TimelineFilter = .init(), buildingIndex: Bool = false) throws -> [Asset] {
        let (sql, arguments) = timeBucketQuery(bucket, filter: filter)
        let assets = try decodeTimelineRows(try database.query(sql, arguments))
        if buildingIndex { startMonthIndex(Self.monthDate(filter)) }
        return assets
    }

    /// What SQLite plans for a month's query, for tests and diagnostics.
    func timeBucketPlan(_ bucket: String, filter: TimelineFilter = .init()) throws -> [String] {
        let (sql, arguments) = timeBucketQuery(bucket, filter: filter)
        return try database.query("EXPLAIN QUERY PLAN " + sql, arguments).compactMap { $0.last ?? nil }
    }

    /// Whether a feed's months are found through their index, for tests and diagnostics.
    func monthIndexIsReady(for filter: TimelineFilter = .init()) -> Bool { monthIndex(Self.monthDate(filter)) != nil }

    private func timeBucketQuery(_ bucket: String, filter: TimelineFilter) -> (String, [String?]) {
        let (whereSQL, arguments) = timelinePredicate(filter)
        let date = Self.monthDate(filter)
        let select = Self.timelineSelect(indexedBy: monthIndex(date))
        return ("\(select) WHERE \(whereSQL) AND strftime('%Y-%m',json_extract(a.payload,'$.\(date)'))=? ORDER BY julianday(json_extract(a.payload,'$.\(date)')) \(filter.order == "asc" ? "ASC" : "DESC"),a.id",
                arguments + [String(bucket.prefix(7))])
    }

    /// A month's photos are found through an index on their month, which the month query matches
    /// exactly; without it every photo's record is read, a quarter of a second or more per month on
    /// a large library. Until the index exists a month is found that way.
    private func monthIndex(_ date: String) -> String? {
        let name = Self.monthIndexName(date)
        // The lookup is tiny, so it runs even for a month load that has been cancelled, and only an
        // answer is kept: a failed lookup is tried again by the next month.
        if monthIndexes[date] == nil,
           let rows = try? database.query("SELECT 1 FROM sqlite_master WHERE type='index' AND name=?", [name], cancellable: false) {
            monthIndexes[date] = rows.isEmpty ? .missing : .ready
        }
        return monthIndexes[date] == .ready ? name : nil
    }

    /// Builds the index for months of the feed's date, when taken or when added, if it is missing,
    /// and returns once it is in. Once the index exists this returns at once.
    func buildMonthIndex(for filter: TimelineFilter) async {
        let date = Self.monthDate(filter)
        startMonthIndex(date)
        await monthIndexBuilds[date]?.value
    }

    /// Starts building a missing month index, once a session. Building reads every photo, so it
    /// runs on a connection and a thread of its own: the store keeps answering on its own
    /// connection meanwhile, months load the old way until the index is in, and writes wait for the
    /// build as they would for any other writer.
    private func startMonthIndex(_ date: String) {
        guard monthIndex(date) == nil, monthIndexes[date] == .missing else { return }
        monthIndexes[date] = .building
        let path = self.path
        let sql = "CREATE INDEX IF NOT EXISTS \(Self.monthIndexName(date)) ON entities(kind,strftime('%Y-%m',json_extract(payload,'$.\(date)'))) WHERE kind='asset'"
        monthIndexBuilds[date] = Task.detached(priority: .utility) { [weak self] in
            let built = await SQLiteConnection.executeOnItsOwnConnection(path: path, sql)
            await self?.finishMonthIndex(date, built: built)
        }
    }

    private func finishMonthIndex(_ date: String, built: Bool) {
        monthIndexBuilds[date] = nil
        // The next month looks the index up again, through this store's connection, which so learns
        // of it. If it could not be built, months are still found by reading every photo, and the
        // next launch tries again.
        monthIndexes[date] = built ? nil : .unavailable
    }

    private static func monthDate(_ filter: TimelineFilter) -> String { filter.orderBy == "createdAt" ? "createdAt" : "localDateTime" }
    private static func monthIndexName(_ date: String) -> String { "asset_month_" + date }

    /// Located photos per month and place, for naming months and marking trips on the time rail.
    func monthPlaces(filter: TimelineFilter = .init()) throws -> [MonthPlaceCount] {
        let (whereSQL, arguments) = timelinePredicate(filter)
        let date = filter.orderBy == "createdAt" ? "createdAt" : "localDateTime"
        return try database.query("""
        SELECT strftime('%Y-%m-01',json_extract(a.payload,'$.\(date)')),json_extract(e.payload,'$.city'),json_extract(e.payload,'$.country'),count(*)
        FROM entities a JOIN entities e ON e.kind='exif' AND e.id=a.id
        WHERE \(whereSQL) AND (json_extract(e.payload,'$.city') IS NOT NULL OR json_extract(e.payload,'$.country') IS NOT NULL)
        GROUP BY 1,2,3
        """, arguments).compactMap { row in
            guard let bucket = row[0], let count = row[3].flatMap(Int.init) else { return nil }
            return MonthPlaceCount(bucket: bucket, city: row[1], country: row[2], count: count)
        }
    }

    /// One query brings each photo with its EXIF and the fields the timeline reads from the raw
    /// record, instead of a query and two JSON passes per photo. A 4,000-photo month matters.
    private static let timelineSelect = timelineSelect(indexedBy: nil)
    private static func timelineSelect(indexedBy index: String?) -> String {
        "SELECT a.payload,e.payload,json_extract(a.payload,'$.deletedAt') IS NOT NULL,json_extract(a.payload,'$.stackId') "
            + "FROM entities a\(index.map { " INDEXED BY \($0)" } ?? "") LEFT JOIN entities e ON e.kind='exif' AND e.id=a.id"
    }

    private func decodeTimelineRows(_ rows: [[String?]]) throws -> [Asset] {
        let decoder = APIJSON.decoder()
        var stacks: [String: AssetStack?] = [:]
        return try rows.compactMap { row in
            guard let payload = row[0] else { return nil }
            var asset = try decoder.decode(Asset.self, from: Data(payload.utf8))
            asset.isTrashed = row[2] == "1"
            if asset.ownerId != userID { asset.isFavorite = false }
            if let exif = row[1] { asset.exifInfo = try decoder.decode(ExifInfo.self, from: Data(exif.utf8)) }
            if let stackID = row[3] {
                if stacks[stackID] == nil { stacks[stackID] = try stack(id: stackID) }
                asset.stack = stacks[stackID] ?? nil
            }
            return asset
        }
    }

    private func stack(id stackID: String) throws -> AssetStack? {
        guard let data = try entityData(kind: "stack", id: stackID) else { return nil }
        let stack = try JSONDecoder().decode([String: EntityJSON].self, from: data)
        guard let primary = stack["primaryAssetId"]?.string else { return nil }
        let count = try database.query("SELECT count(*) FROM entities WHERE kind='asset' AND json_extract(payload,'$.stackId')=?", [stackID]).first?[0].flatMap(Int.init) ?? 0
        return .init(id: stackID, primaryAssetId: primary, assetCount: count)
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
            try row[0].map { try albumFromPayload($0) }
        }
    }
    func album(id: String) throws -> Album? {
        guard let text = try database.query("SELECT payload FROM entities WHERE kind='album' AND id=?", [id]).first?[0] else { return nil }
        return try albumFromPayload(text)
    }
    private func albumFromPayload(_ text: String) throws -> Album {
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
    func person(id: String) throws -> Person? {
        try entityData(kind: "person", id: id).map { try APIJSON.decoder().decode(Person.self, from: $0) }
    }
    func people() throws -> [Person] {
        try database.query("SELECT payload FROM entities WHERE kind='person' ORDER BY json_extract(payload,'$.name') COLLATE NOCASE").compactMap { row in
            try row[0].map { try APIJSON.decoder().decode(Person.self, from: Data($0.utf8)) }
        }
    }

    /// Mirrors GET /map/markers from the synchronized asset, EXIF, partner, and
    /// album rows. Projection stays limited to the six marker fields.
    func mapMarkers(_ query: MapMarkerQuery) throws -> [MapMarker] {
        var conditions = [
            "a.kind='asset'", "e.kind='exif'", "json_extract(e.payload,'$.assetId')=a.id",
            "json_extract(e.payload,'$.latitude') IS NOT NULL", "json_extract(e.payload,'$.longitude') IS NOT NULL",
            "json_extract(a.payload,'$.deletedAt') IS NULL"
        ]
        var arguments: [String?] = []
        if query.isArchived == true {
            conditions.append("(json_extract(a.payload,'$.visibility')='timeline' OR (json_extract(a.payload,'$.ownerId')=? AND json_extract(a.payload,'$.visibility')='archive'))")
            arguments.append(userID)
        } else {
            conditions.append("json_extract(a.payload,'$.visibility')='timeline'")
        }
        if let favorite = query.isFavorite {
            conditions.append("json_extract(a.payload,'$.isFavorite')=CAST(? AS INTEGER)")
            arguments.append(favorite ? "1" : "0")
        }
        if let date = query.fileCreatedAfter {
            conditions.append("julianday(json_extract(a.payload,'$.fileCreatedAt'))>=julianday(?)")
            arguments.append(date.ISO8601Format())
        }
        if let date = query.fileCreatedBefore {
            conditions.append("julianday(json_extract(a.payload,'$.fileCreatedAt'))<=julianday(?)")
            arguments.append(date.ISO8601Format())
        }
        var scopes = ["json_extract(a.payload,'$.ownerId')=?"]
        arguments.append(userID)
        if query.withPartners {
            scopes.append("EXISTS(SELECT 1 FROM entities p JOIN entities u ON u.kind='user' AND u.id=json_extract(p.payload,'$.sharedById') WHERE p.kind='partner' AND json_extract(p.payload,'$.sharedById')=json_extract(a.payload,'$.ownerId') AND json_extract(p.payload,'$.sharedWithId')=? AND json_extract(u.payload,'$.deletedAt') IS NULL)")
            arguments.append(userID)
        }
        if query.withSharedAlbums {
            scopes.append("EXISTS(SELECT 1 FROM entities r JOIN entities m ON m.kind='albumUser' AND json_extract(m.payload,'$.albumId')=json_extract(r.payload,'$.albumId') AND json_extract(m.payload,'$.userId')=? JOIN entities b ON b.kind='album' AND b.id=json_extract(r.payload,'$.albumId') WHERE r.kind='albumAsset' AND json_extract(r.payload,'$.assetId')=a.id AND json_extract(b.payload,'$.deletedAt') IS NULL)")
            arguments.append(userID)
        }
        conditions.append("(" + scopes.joined(separator: " OR ") + ")")
        let rows = try database.query("""
        SELECT a.id,json_extract(e.payload,'$.latitude'),json_extract(e.payload,'$.longitude'),
               json_extract(e.payload,'$.city'),json_extract(e.payload,'$.state'),json_extract(e.payload,'$.country')
        FROM entities a JOIN entities e ON e.kind='exif' AND json_extract(e.payload,'$.assetId')=a.id
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY julianday(json_extract(a.payload,'$.fileCreatedAt')) DESC,a.id
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
        if let developed = filter.isDeveloped {
            conditions.append("COALESCE(json_extract(a.payload,'$.isDeveloped'),0)=CAST(? AS INTEGER)"); values.append(developed ? "1" : "0")
        }
        if let album = filter.albumID {
            conditions.append("a.id IN (SELECT json_extract(r.payload,'$.assetId') FROM entities r WHERE r.kind='albumAsset' AND json_extract(r.payload,'$.albumId')=?)"); values.append(album)
        }
        if let person = filter.personID {
            // Materialize membership once. Correlating a JSON expression with
            // the TEXT asset ID defeats SQLite's expression index affinity.
            conditions.append("a.id IN (SELECT json_extract(f.payload,'$.assetId') FROM entities f WHERE f.kind='face' AND json_extract(f.payload,'$.personId')=? AND json_extract(f.payload,'$.deletedAt') IS NULL AND json_extract(f.payload,'$.isVisible')=1)"); values.append(person)
        }
        if let place = filter.place {
            // One parameter however many photos the place holds. They came from this account's
            // own map, so they need no owner check.
            conditions.append("a.id IN (SELECT value FROM json_each(?))")
            values.append(String(decoding: (try? JSONEncoder().encode(place.assetIDs)) ?? Data("[]".utf8), as: UTF8.self))
        }
        if (filter.albumID == nil && filter.place == nil) || filter.userID != nil {
            var owners = ["json_extract(a.payload,'$.ownerId')=?"]
            values.append(filter.userID ?? userID)
            if filter.withPartners {
                owners.append("EXISTS(SELECT 1 FROM entities p WHERE p.kind='partner' AND json_extract(p.payload,'$.sharedById')=json_extract(a.payload,'$.ownerId') AND json_extract(p.payload,'$.sharedWithId')=?\(filter.personID == nil ? " AND json_extract(p.payload,'$.inTimeline')=1" : ""))")
                values.append(userID)
            }
            if filter.personID != nil {
                owners.append("a.id IN (SELECT json_extract(r.payload,'$.assetId') FROM entities r JOIN entities u ON u.kind='albumUser' AND json_extract(u.payload,'$.albumId')=json_extract(r.payload,'$.albumId') AND json_extract(u.payload,'$.userId')=? WHERE r.kind='albumAsset')")
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
    private func invalidSync() -> APIError { .invalidResponse("The server sent an invalid synchronization record. Your saved cursor was not advanced.") }
}

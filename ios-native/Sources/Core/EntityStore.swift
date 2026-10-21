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
    /// Moves each time a committed write changes what the index holds, so a reader can tell
    /// whether it read before or after a change. It counts from zero each launch.
    private(set) var revision: UInt64 = 0
    /// Whether each month index exists, by the date it indexes; absent until looked up.
    private var monthIndexes: [String: MonthIndex] = [:]
    private enum MonthIndex { case ready, missing, building, unavailable }
    /// Each month index being built, by the date it indexes.
    private var monthIndexBuilds: [String: Task<Void, Never>] = [:]
    private static let cachedServerFeaturesKey = "cache.serverFeatures.v1"

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
    func persistCachedServerFeatures(_ features: ServerFeatures) throws {
        let data = try APIJSON.encoder().encode(features)
        guard let value = String(data: data, encoding: .utf8) else { throw invalidSync() }
        try setMetadata(Self.cachedServerFeaturesKey, value)
    }
    func cachedServerFeatures() throws -> ServerFeatures? {
        guard let value = try metadata(Self.cachedServerFeaturesKey) else { return nil }
        return try APIJSON.decoder().decode(ServerFeatures.self, from: Data(value.utf8))
    }
    /// A reset survives a later stream failure, allowing the UI to discard stale media even
    /// when the overall sync did not return a success summary.
    func takeAccessInvalidation() throws -> Bool {
        let changed = try metadata("accessInvalidated") == "1"
        if changed { try setMetadata("accessInvalidated", "0") }
        return changed
    }
    /// Photos the index removed whose media the app still has to forget, with whether access to
    /// them was lost. They stay queued until the media layer reports them forgotten, so a crash
    /// in between forgets them on the next sync.
    func pendingMediaPurges(limit: Int = 5_000) throws -> [MediaPurge] {
        try database.query("SELECT id,revoked FROM media_purges LIMIT ?", [String(max(limit, 1))]).compactMap { row in
            row[0].map { MediaPurge(assetID: $0, revoked: row[1] == "1") }
        }
    }
    /// A purge that a later batch made stricter stays queued.
    func finishMediaPurges(_ purges: [MediaPurge]) throws {
        try database.transaction {
            for purge in purges { try database.execute("DELETE FROM media_purges WHERE id=? AND revoked<=?", [purge.assetID, purge.revoked ? "1" : "0"]) }
        }
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
            revision &+= 1
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
        revision &+= 1
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Commits one batch of the sync stream with its acknowledgements, all or nothing, and says
    /// what it changed, item by item. The completion marker alone changes nothing, unless it
    /// completes the index.
    func apply(_ events: [EntitySyncEvent], epoch: UUID) throws -> IndexChange {
        guard epoch == generation else { throw CancellationError() }
        var change = IndexChange()
        var complete = try metadata("complete") == "1"
        try database.transaction {
            for event in events {
                try Task.checkCancellation()
                if event.type == "SyncResetV1" {
                    try database.execute("DELETE FROM entities"); try database.execute("DELETE FROM acknowledgements")
                    try setMetadata("complete", "0")
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
                try database.execute("INSERT INTO acknowledgements(type,ack) VALUES(?,?) ON CONFLICT(type) DO UPDATE SET ack=excluded.ack", [event.ackType, event.ack])
            }
            if change.serverReset { try setMetadata("accessInvalidated", "1") }
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
        for row in try database.query("SELECT id,json_extract(payload,'$.mediaRevision') FROM entities WHERE kind='asset' AND id IN (SELECT value FROM json_each(?))", [list]) {
            if let id = row[0], let revision = row[1] { revisions[id] = revision }
        }
        return revisions
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
           let rows = try? database.query("SELECT 1 FROM sqlite_master WHERE type='index' AND name=?", [name], cancellationChecks: false) {
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
        let database = self.database
        let sql = "CREATE INDEX IF NOT EXISTS \(Self.monthIndexName(date)) ON entities(kind,strftime('%Y-%m',json_extract(payload,'$.\(date)'))) WHERE kind='asset'"
        monthIndexBuilds[date] = Task.detached(priority: .utility) { [weak self] in
            let built = await database.executeOnItsOwnConnection(sql)
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
            if delete || locked {
                // A deletion only removes the photo; locking hides it the way lost access does.
                try deleteAsset(id, revoked: locked, change: &change)
                return
            }
            let before = try placement(of: id, localDateTime: object["localDateTime"]?.string)
            try upsert(kind, id, object)
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
                                             [kind, id], cancellationChecks: false).first {
            if subject == nil, let assetID = previous[0] { subject = (assetID, try assetMonth(assetID).month) }
            if kind == "face", let personID = previous[1] { faceOwners.insert(personID) }
        }
        if delete {
            try database.execute("DELETE FROM entities WHERE kind=? AND id=?", [kind, id])
            if kind == "album" { try deleteAlbum(id) }
            if kind == "memory" { try database.execute("DELETE FROM entities WHERE kind='memoryAsset' AND json_extract(payload,'$.memoryId')=?", [id]) }
            if kind == "person" { try database.execute("DELETE FROM entities WHERE kind='face' AND json_extract(payload,'$.personId')=?", [id]) }
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
        if let subject { change.touch(subject.asset, in: subject.month) }
        if delete, kind == "albumUser", object["userId"]?.string == userID, let albumID = object["albumId"]?.string { try deleteAlbum(albumID) }
        // Only photos that leave the account change what it may see. A photo removed from one of
        // my own albums stays in my library, and so does its media.
        if delete && ["partner", "albumUser", "album", "albumAsset", "user"].contains(kind) { try purgeInaccessibleAssets(change: &change) }
    }
    private func upsert(_ kind: String, _ id: String, _ object: [String: EntityJSON]) throws {
        let encoded = try JSONEncoder().encode(object)
        try database.execute("INSERT INTO entities(kind,id,payload) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload", [kind, id, String(decoding: encoded, as: UTF8.self)])
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
        """, [id, localDateTime], cancellationChecks: false).first
        return (row?[0] == "1", row?[1].flatMap(Self.month), row?[2], row?[3].flatMap(Self.month))
    }
    /// The month an asset shows in, nil when it shows in none, and whether the index holds it.
    private func assetMonth(_ id: String) throws -> (exists: Bool, month: MonthKey?) {
        let rows = try database.query("""
        SELECT CASE WHEN json_extract(payload,'$.visibility') IN ('timeline','archive') THEN strftime('%Y-%m',json_extract(payload,'$.localDateTime')) END
        FROM entities WHERE kind='asset' AND id=?
        """, [id], cancellationChecks: false)
        guard let row = rows.first else { return (false, nil) }
        return (true, row[0].flatMap(Self.month))
    }
    /// YYYY-MM, as strftime writes it.
    private static func month(_ yearMonth: String) -> MonthKey? { MonthKey(bucketID: yearMonth + "-01") }
    /// The photo's media is forgotten once the batch commits. Its queued purge commits with the
    /// batch, so a crash before then cannot leave the media behind.
    private func deleteAsset(_ id: String, revoked: Bool, change: inout IndexChange) throws {
        try database.execute("DELETE FROM entities WHERE (kind='asset' AND id=?) OR (kind IN ('exif','edit','ocr','assetMetadata','face','albumAsset','memoryAsset') AND json_extract(payload,'$.assetId')=?)", [id, id])
        try database.execute("INSERT INTO media_purges(id,revoked) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET revoked=max(revoked,excluded.revoked)", [id, revoked ? "1" : "0"])
        change.remove(id, accessLost: revoked)
    }
    private func deleteAlbum(_ id: String) throws {
        try database.execute("DELETE FROM entities WHERE (kind='album' AND id=?) OR (kind IN ('albumUser','albumAsset') AND json_extract(payload,'$.albumId')=?)", [id, id])
    }
    private func deleteOwnedAssets(_ ownerID: String, change: inout IndexChange) throws {
        let rows = try database.query("SELECT id FROM entities WHERE kind='asset' AND json_extract(payload,'$.ownerId')=?", [ownerID])
        for row in rows { if let id = row[0] { try deleteAsset(id, revoked: true, change: &change) } }
    }
    private func purgeInaccessibleAssets(change: inout IndexChange) throws {
        let rows = try database.query("""
        SELECT a.id FROM entities a WHERE a.kind='asset' AND json_extract(a.payload,'$.ownerId')!=?
        AND NOT EXISTS(SELECT 1 FROM entities p WHERE p.kind='partner' AND json_extract(p.payload,'$.sharedById')=json_extract(a.payload,'$.ownerId') AND json_extract(p.payload,'$.sharedWithId')=?)
        AND NOT EXISTS(SELECT 1 FROM entities r JOIN entities u ON u.kind='albumUser' AND json_extract(u.payload,'$.albumId')=json_extract(r.payload,'$.albumId') AND json_extract(u.payload,'$.userId')=? WHERE r.kind='albumAsset' AND json_extract(r.payload,'$.assetId')=a.id)
        """, [userID, userID, userID])
        for row in rows { if let id = row[0] { try deleteAsset(id, revoked: true, change: &change) } }
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
    private func setMetadata(_ key: String, _ value: String) throws { try database.execute("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value]) }
    private func invalidSync() -> APIError { .invalidResponse("The server sent an invalid synchronization record. Your saved cursor was not advanced.") }
}

/// This handle never escapes EntityStore; Sendable permits ownership transfer at init.
private final class EntityDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private let path: String
    init(url: URL) throws {
        path = url.path
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
            try execute("CREATE TABLE IF NOT EXISTS media_purges(id TEXT PRIMARY KEY,revoked INTEGER NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS entity_asset ON entities(kind,json_extract(payload,'$.assetId'))")
            try execute("CREATE INDEX IF NOT EXISTS entity_person_asset ON entities(kind,json_extract(payload,'$.personId'),json_extract(payload,'$.assetId'))")
            try execute("CREATE INDEX IF NOT EXISTS entity_album ON entities(kind,json_extract(payload,'$.albumId'))")
            try execute("CREATE INDEX IF NOT EXISTS entity_memory ON entities(kind,json_extract(payload,'$.memoryId'))")
            try execute("CREATE INDEX IF NOT EXISTS asset_stack ON entities(kind,json_extract(payload,'$.stackId'))")
            try execute("CREATE INDEX IF NOT EXISTS asset_timeline ON entities(kind,json_extract(payload,'$.ownerId'),json_extract(payload,'$.visibility'),json_extract(payload,'$.localDateTime'))")
            // The only other writer builds a month index, which takes seconds on a large library; a
            // write waits for it rather than failing.
            sqlite3_busy_timeout(handle, 60_000)
        } catch { throw error }
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ arguments: [String?] = []) throws { _ = try query(sql, arguments, cancellationChecks: false) }
    func query(_ sql: String, _ arguments: [String?] = [], cancellationChecks: Bool = true) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Self.failure() }
        defer { sqlite3_finalize(statement) }
        let checksCancellation = cancellationChecks && sqlite3_stmt_readonly(statement) != 0
        if checksCancellation {
            try Task.checkCancellation()
            sqlite3_progress_handler(handle, 1_000, entityDatabaseProgressHandler, nil)
        }
        defer {
            if checksCancellation { sqlite3_progress_handler(handle, 0, nil, nil) }
        }
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
            guard status == SQLITE_ROW else {
                if status == SQLITE_INTERRUPT && checksCancellation && Task.isCancelled { throw CancellationError() }
                throw Self.failure()
            }
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

    /// Runs one long statement on a connection and a thread of its own, returning whether it
    /// succeeded. The database is in WAL mode, so this connection keeps reading meanwhile; its
    /// writes wait for the statement as for any other writer.
    func executeOnItsOwnConnection(_ sql: String) async -> Bool {
        let path = self.path
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var connection: OpaquePointer?
                guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let connection else {
                    if let connection { sqlite3_close(connection) }
                    return continuation.resume(returning: false)
                }
                // A sync's write in progress is waited for, not given up on.
                sqlite3_busy_timeout(connection, 60_000)
                let status = sqlite3_exec(connection, "PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; " + sql, nil, nil, nil)
                sqlite3_close(connection)
                continuation.resume(returning: status == SQLITE_OK)
            }
        }
    }
    private static func failure() -> APIError { .invalidResponse("The offline library could not be saved. Free some device storage, then try again.") }
}

private func entityDatabaseProgressHandler(_ context: UnsafeMutableRawPointer?) -> Int32 {
    Task.isCancelled ? 1 : 0
}

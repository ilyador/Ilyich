import Foundation
import SQLite3

/// One change the app asked Photos to make, as the journal keeps it.
struct DeviceJournalEntry: Hashable, Sendable {
    let id: UUID
    /// A save keeps no file names: its files are gone by the time anyone reads the journal again.
    let mutation: DeviceMutation
    let createdAt: Date
}

/// A journal entry, and how it ended if it has.
struct DeviceJournalRecord: Hashable, Sendable {
    let entry: DeviceJournalEntry
    let finishedAt: Date?
    let outcome: DeviceMutationResult.Outcome?
}

/// The phone's own database (architecture section 3): Application Support/IlyichDevice/device.sqlite,
/// in the app's private container, so no lock of it is ever held in the App Group when iOS suspends
/// the app. It is device-wide, not per account, runs on a queue of its own and opens on first use.
/// It holds the mutation journal; P5 adds fingerprints.
///
/// device_mutation has one row per change the app asked of Photos:
/// - id: the change's UUID;
/// - account_digest: the account a cleanup or a save worked for, NULL for the person's own changes;
/// - kind: delete, favorite, unfavorite or create;
/// - origin: JSON, {"kind":"user"}, {"kind":"cleanup","scan":"<UUID>"} or
///   {"kind":"saveFromServer","asset":"<server asset id>"};
/// - asset_ids: a JSON array of local identifiers in the order asked; for a save, the assets it
///   made once it has;
/// - expected_revisions: a JSON object from local identifier to the modification date the asset
///   had to still have, written as the 16 lowercase hex digits of the Double's bit pattern, so a
///   later importer compares it exactly (B9 marks a receipt locally deleted only on a match);
/// - created_at and finished_at: REAL seconds since 2001 (timeIntervalSinceReferenceDate), bound as
///   doubles; finished_at is NULL until the change has ended;
/// - outcome: committed, declined, revisionChanged, notPermitted, failed or interrupted, and detail:
///   a failure's message.
/// Rows are kept as history.
actor DeviceDatabase {
    /// Application Support/IlyichDevice/device.sqlite.
    static var standardURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IlyichDevice", isDirectory: true).appendingPathComponent("device.sqlite")
    }

    private nonisolated let queue = DispatchSerialQueue(label: "app.ilyich.device-database", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    nonisolated let url: URL
    private var connection: DeviceSQLite?

    init(url: URL) { self.url = url }

    /// Writes `entry` durably, before Photos is asked. Without it the change is not made.
    func begin(_ entry: DeviceJournalEntry) throws {
        let row = Row(entry.mutation)
        try database().execute("""
            INSERT INTO device_mutation(id,account_digest,kind,origin,asset_ids,expected_revisions,created_at) VALUES(?,?,?,?,?,?,?)
            """, [.text(entry.id.uuidString), row.account.map { .text($0) } ?? .null, .text(row.kind), .text(row.origin),
                  .text(row.assetIDs), .text(row.expected), .real(entry.createdAt.timeIntervalSinceReferenceDate)])
    }

    /// Records how the change `id` ended. An entry ends once: finishing it again changes nothing.
    func finish(_ id: UUID, outcome: DeviceMutationResult.Outcome, at date: Date) throws {
        let (code, detail) = Self.columns(outcome)
        var assignments = "finished_at=?,outcome=?,detail=?"
        var values: [DeviceSQLite.Value] = [.real(date.timeIntervalSinceReferenceDate), .text(code), detail.map { .text($0) } ?? .null]
        // A save names the assets it made.
        if case .committed(_, let created) = outcome, !created.isEmpty {
            assignments += ",asset_ids=?"
            values.append(.text(Self.json(created.map(\.rawValue))))
        }
        values.append(.text(id.uuidString))
        try database().execute("UPDATE device_mutation SET \(assignments) WHERE id=? AND finished_at IS NULL", values)
    }

    /// The entries begun and never finished, oldest first.
    func unfinished() throws -> [DeviceJournalEntry] {
        try database().query(Self.selection + " WHERE finished_at IS NULL ORDER BY created_at,rowid").compactMap { Self.record($0)?.entry }
    }

    /// Every entry, oldest first.
    func records() throws -> [DeviceJournalRecord] {
        try database().query(Self.selection + " ORDER BY created_at,rowid").compactMap { Self.record($0) }
    }

    private func database() throws -> DeviceSQLite {
        if let connection { return connection }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        let opened = try DeviceSQLite(url: url)
        try opened.execute("""
            CREATE TABLE IF NOT EXISTS device_mutation(id TEXT PRIMARY KEY,account_digest TEXT,kind TEXT NOT NULL,origin TEXT NOT NULL,\
            asset_ids TEXT NOT NULL,expected_revisions TEXT NOT NULL,created_at REAL NOT NULL,finished_at REAL,outcome TEXT,detail TEXT)
            """)
        if try opened.query("PRAGMA user_version").first?.first?.real == 0 { try opened.execute("PRAGMA user_version=1") }
        connection = opened
        return opened
    }

    // MARK: - Rows

    private static let selection = "SELECT id,account_digest,kind,origin,asset_ids,expected_revisions,created_at,finished_at,outcome,detail FROM device_mutation"

    /// A mutation as its row's columns.
    private struct Row {
        let kind: String
        let origin: String
        let account: String?
        let assetIDs: String
        let expected: String

        init(_ mutation: DeviceMutation) {
            let ids: [DeviceAssetID], revisions: [DeviceAssetID: AssetRevision], from: MutationOrigin
            switch mutation {
            case .delete(let named, let wanted, let source):
                kind = "delete"; ids = named; revisions = wanted; from = source
            case .setFavorite(let named, let value, let wanted):
                kind = value ? "favorite" : "unfavorite"; ids = named; revisions = wanted; from = .user
            case .create(_, _, _, let source):
                kind = "create"; ids = []; revisions = [:]; from = source
            }
            let columns = DeviceDatabase.columns(from)
            origin = columns.origin
            account = columns.account
            assetIDs = DeviceDatabase.json(ids.map(\.rawValue))
            expected = DeviceDatabase.json(Dictionary(uniqueKeysWithValues: revisions.map { ($0.key.rawValue, DeviceDatabase.hex($0.value)) }))
        }
    }

    private struct Origin: Codable {
        var kind: String
        var scan: String?
        var asset: String?
    }

    private static func columns(_ origin: MutationOrigin) -> (origin: String, account: String?) {
        switch origin {
        case .user: (json(Origin(kind: "user")), nil)
        case .cleanup(let scan, let account): (json(Origin(kind: "cleanup", scan: scan.uuidString)), account)
        case .saveFromServer(let asset, let account): (json(Origin(kind: "saveFromServer", asset: asset)), account)
        }
    }

    private static func decodeOrigin(_ text: String, account: String?) -> MutationOrigin? {
        guard let value = decode(Origin.self, text) else { return nil }
        switch value.kind {
        case "user": return .user
        case "cleanup":
            guard let scan = value.scan.flatMap(UUID.init(uuidString:)), let account else { return nil }
            return .cleanup(scan: scan, account: account)
        case "saveFromServer":
            guard let asset = value.asset, let account else { return nil }
            return .saveFromServer(asset: asset, account: account)
        default: return nil
        }
    }

    private static func columns(_ outcome: DeviceMutationResult.Outcome) -> (code: String, detail: String?) {
        switch outcome {
        case .committed: ("committed", nil)
        case .declined: ("declined", nil)
        case .revisionChanged: ("revisionChanged", nil)
        case .notPermitted: ("notPermitted", nil)
        case .failed(let message): ("failed", message)
        case .interrupted: ("interrupted", nil)
        }
    }

    /// A row read back. A row this build can't read is left out.
    private static func record(_ row: [DeviceSQLite.Value]) -> DeviceJournalRecord? {
        guard row.count == 10, let id = row[0].text.flatMap(UUID.init(uuidString:)), let kind = row[2].text,
              let origin = row[3].text.flatMap({ decodeOrigin($0, account: row[1].text) }),
              let ids = row[4].text.flatMap({ decode([String].self, $0) }),
              let expected = row[5].text.flatMap({ decode([String: String].self, $0) }), let created = row[6].real else { return nil }
        let assetIDs = ids.map { DeviceAssetID(rawValue: $0) }
        var revisions: [DeviceAssetID: AssetRevision] = [:]
        for (key, bits) in expected {
            guard let value = revision(hex: bits) else { return nil }
            revisions[DeviceAssetID(rawValue: key)] = value
        }
        let mutation: DeviceMutation
        switch kind {
        case "delete": mutation = .delete(assetIDs, expected: revisions, origin: origin)
        case "favorite", "unfavorite": mutation = .setFavorite(assetIDs, kind == "favorite", expected: revisions)
        case "create": mutation = .create(still: nil, video: nil, pairedVideo: nil, origin: origin)
        default: return nil
        }
        let outcome: DeviceMutationResult.Outcome? = switch row[8].text ?? "" {
        case "committed": kind == "create" ? .committed(affected: [], created: assetIDs) : .committed(affected: assetIDs, created: [])
        case "declined": .declined
        case "revisionChanged": .revisionChanged
        case "notPermitted": .notPermitted
        case "failed": .failed(row[9].text ?? "")
        case "interrupted": .interrupted
        default: nil
        }
        return DeviceJournalRecord(entry: DeviceJournalEntry(id: id, mutation: mutation, createdAt: Date(timeIntervalSinceReferenceDate: created)),
                                   finishedAt: row[7].real.map { Date(timeIntervalSinceReferenceDate: $0) }, outcome: outcome)
    }

    /// A revision as the 16 lowercase hex digits of its bit pattern.
    static func hex(_ revision: AssetRevision) -> String {
        let digits = String(revision.referenceSeconds.bitPattern, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    static func revision(hex: String) -> AssetRevision? {
        guard hex.count == 16, let bits = UInt64(hex, radix: 16) else { return nil }
        return AssetRevision(referenceSeconds: Double(bitPattern: bits))
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

/// Device records couldn't be read or written, as on a full disk.
struct DeviceDatabaseError: LocalizedError, Equatable {
    var errorDescription: String? { "Ilyich couldn’t update its records on this phone. Free some storage, then try again." }
}

/// One SQLite connection, used only on DeviceDatabase's queue.
final class DeviceSQLite {
    enum Value: Equatable {
        case text(String)
        case real(Double)
        case null

        var text: String? {
            switch self {
            case .text(let value): value
            default: nil
            }
        }

        var real: Double? {
            switch self {
            case .real(let value): value
            default: nil
            }
        }
    }

    private let handle: OpaquePointer

    init(url: URL) throws {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened else {
            if let opened { sqlite3_close(opened) }
            throw DeviceDatabaseError()
        }
        handle = opened
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, _ values: [Value] = []) throws { _ = try query(sql, values) }

    func query(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            sqlite3_finalize(prepared)
            throw DeviceDatabaseError()
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 = switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .null: sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw DeviceDatabaseError() }
        }
        var rows: [[Value]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw DeviceDatabaseError() }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL: .null
                case SQLITE_TEXT, SQLITE_BLOB: .text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
                default: .real(sqlite3_column_double(statement, column))
                }
            })
        }
    }
}

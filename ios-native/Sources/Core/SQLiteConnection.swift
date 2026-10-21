import Foundation
import SQLite3
import Synchronization

/// A value bound to, or read from, a statement.
enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    static func optionalText(_ text: String?) -> SQLiteValue { text.map { .text($0) } ?? .null }
}

enum SQLiteError: Error, Sendable {
    case open(Int32)
    case statement(Int32, String)
}

/// One connection to a database file, owned by one executor: a library index writer or reader
/// queue. Statements are prepared once and kept, values are bound with their types, and a read
/// stops early when its task is cancelled. Not thread-safe; it never leaves its owner.
final class SQLiteConnection {
    /// Statements run on the main thread by any connection in this process. Library work never
    /// runs there; tests check that this stays where it was.
    static let statementsOnMainThread = Atomic<Int>(0)

    let path: String
    let isReadOnly: Bool
    private var handle: OpaquePointer?
    private var prepared: [String: OpaquePointer] = [:]
    /// Filters make many shapes of query, so the cache is bounded.
    private let cacheLimit = 96

    init(path: String, readOnly: Bool, busyTimeout: Int32) throws {
        self.path = path
        isReadOnly = readOnly
        var opened: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            sqlite3_close(opened)
            throw SQLiteError.open(status)
        }
        handle = opened
        sqlite3_busy_timeout(opened, busyTimeout)
    }

    deinit { close() }

    func close() {
        for statement in prepared.values { sqlite3_finalize(statement) }
        prepared = [:]
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    /// Runs `sql` with `values`, handing each row to `row`. A read-only statement with
    /// `cancellable` stops with CancellationError once its task is cancelled; writes always finish.
    func run(_ sql: String, _ values: [SQLiteValue] = [], cancellable: Bool = false, row: ((SQLiteRow) throws -> Void)? = nil) throws {
        guard let handle else { throw SQLiteError.statement(SQLITE_MISUSE, "closed") }
        let statement = try self.statement(sql, handle: handle)
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
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            }
            guard status == SQLITE_OK else { throw failure(status) }
        }
        if Thread.isMainThread { Self.statementsOnMainThread.add(1, ordering: .relaxed) }
        let checksCancellation = cancellable && sqlite3_stmt_readonly(statement) != 0
        if checksCancellation {
            try Task.checkCancellation()
            sqlite3_progress_handler(handle, 1_000, sqliteCancellationHandler, nil)
        }
        defer { if checksCancellation { sqlite3_progress_handler(handle, 0, nil, nil) } }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else {
                if status == SQLITE_INTERRUPT && checksCancellation && Task.isCancelled { throw CancellationError() }
                throw failure(status)
            }
            try row?(SQLiteRow(statement: statement))
        }
    }

    /// Today's shape: text arguments and every column as text, as SQLite converts it.
    func query(_ sql: String, _ arguments: [String?] = [], cancellable: Bool = true) throws -> [[String?]] {
        var rows: [[String?]] = []
        try run(sql, arguments.map(SQLiteValue.optionalText), cancellable: cancellable) { rows.append($0.texts) }
        return rows
    }

    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws { try run(sql, values) }

    /// The first column of the first row.
    func scalar(_ sql: String, _ values: [SQLiteValue] = []) throws -> SQLiteValue {
        var value = SQLiteValue.null
        try run(sql, values) { row in if case .null = value { value = row.value(0) } }
        return value
    }

    /// Runs `body` in one transaction, which a thrown error rolls back.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs `body` inside a savepoint: a thrown error undoes only what `body` did, and is rethrown.
    func savepoint<T>(_ name: String, _ body: () throws -> T) throws -> T {
        try execute("SAVEPOINT \(name)")
        do {
            let value = try body()
            try execute("RELEASE \(name)")
            return value
        } catch {
            try? execute("ROLLBACK TO \(name)")
            try? execute("RELEASE \(name)")
            throw error
        }
    }

    var userVersion: Int {
        get throws { if case .integer(let version) = try scalar("PRAGMA user_version") { Int(version) } else { 0 } }
    }

    /// Runs one long statement on a connection and a thread of its own, returning whether it
    /// succeeded. The database is in WAL mode, so other connections keep reading meanwhile; their
    /// writes wait for the statement as for any other writer.
    static func executeOnItsOwnConnection(path: String, _ sql: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var connection: OpaquePointer?
                guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let connection else {
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

    private func statement(_ sql: String, handle: OpaquePointer) throws -> OpaquePointer {
        if let cached = prepared[sql] { return cached }
        if prepared.count >= cacheLimit {
            for statement in prepared.values { sqlite3_finalize(statement) }
            prepared = [:]
        }
        var made: OpaquePointer?
        let status = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &made, nil)
        guard status == SQLITE_OK, let made else {
            sqlite3_finalize(made)
            throw failure(status)
        }
        prepared[sql] = made
        return made
    }

    private func failure(_ status: Int32) -> SQLiteError {
        .statement(status, handle.map { String(cString: sqlite3_errmsg($0)) } ?? "")
    }
}

/// The row a statement is on, valid only inside the closure it is handed to.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    var count: Int32 { sqlite3_column_count(statement) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
    func integer(_ column: Int32) -> Int64? { isNull(column) ? nil : sqlite3_column_int64(statement, column) }
    func real(_ column: Int32) -> Double? { isNull(column) ? nil : sqlite3_column_double(statement, column) }
    func value(_ column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL: .null
        case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
        default: .text(text(column) ?? "")
        }
    }
    var texts: [String?] { (0..<count).map(text) }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func sqliteCancellationHandler(_ context: UnsafeMutableRawPointer?) -> Int32 {
    Task.isCancelled ? 1 : 0
}

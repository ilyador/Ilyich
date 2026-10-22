import CryptoKit
import Foundation
import Synchronization

/// Grid thumbnails on disk, keyed by asset and revision instead of by URL. Switching between
/// the home and the remote address keeps them, and an edited photo replaces only its own.
///
/// The files keep the v1 layout, `<root>/IlyichThumbnails/<scope digest>/<stem's first 2>/<stem>.<revision digest>`,
/// and `index.sqlite` beside the folders lists them: name, size and when each was last looked at.
/// The index is loaded into memory once, so asking whether a thumbnail is stored, replacing a
/// photo's older revision, forgetting photos and trimming need no directory listing. Files
/// written by an earlier build are adopted in place, folder by folder at utility priority after
/// launch; until that is done the store falls back to the file system, as before. Nothing is
/// downloaded again. Every launch compares the folders with the index once, the same way, so files
/// an older build or iOS removed, or an older build added, are noticed.
///
/// Writes return at once: the bytes are readable straight away and reach the disk on the store's
/// own queue, which also does all its file and SQLite work, never the main thread. Trimming,
/// least recently viewed first, runs only after a few idle seconds or when the app goes to the
/// background.
final class ThumbnailDiskStore: Sendable {
    nonisolated let directory: URL
    nonisolated let limit: Int
    /// Downloads that began before their photo was forgotten, or before the store was cleared, are not written.
    nonisolated let fence: MediaFence
    /// Directory listings made, for tests that check a write needs none.
    let listings = Atomic<Int>(0)

    private struct Row: Sendable {
        var size: Int
        /// Milliseconds since 1970 when the thumbnail was last read or written.
        var access: Int64
    }
    private struct Pending: Sendable {
        let data: Data
        let ticket: UInt64
    }
    private struct State: Sendable {
        var rows: [String: Row] = [:]
        /// The file names in each folder, by folder.
        var folders: [String: Set<String>] = [:]
        var usage = 0
        /// The index lists every file. Until then a folder after `cursor` falls back to the disk.
        var complete = false
        /// The last folder adopted while the index is being built.
        var cursor: String?
        /// Bytes written but not on disk yet, by file name.
        var pending: [String: Pending] = [:]
        var tickets: UInt64 = 0
        /// Rows to save (nil: delete).
        var dirty: [String: Row?] = [:]
        var lastActivity: Int64 = 0
        var flushScheduled = false
        var maintenanceScheduled = false
        /// The index's meta rows as last read or written, for coverage's position.
        var meta: [String: String] = [:]

        func knows(_ folder: String) -> Bool { complete || cursor.map { folder <= $0 } ?? false }

        mutating func put(_ name: String, _ row: Row) {
            if let old = rows.updateValue(row, forKey: name) { usage -= old.size }
            usage += row.size
            folders[ThumbnailDiskStore.folder(ofName: name), default: []].insert(name)
            dirty[name] = row
        }

        mutating func drop(_ name: String) {
            guard let old = rows.removeValue(forKey: name) else { return }
            usage = max(0, usage - old.size)
            let folder = ThumbnailDiskStore.folder(ofName: name)
            folders[folder]?.remove(name)
            if folders[folder]?.isEmpty == true { folders[folder] = nil }
            dirty[name] = .some(nil)
        }
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "ilyich.thumbnail-disk", qos: .utility)
    /// Opened, used and closed only on `queue`.
    private nonisolated(unsafe) var database: SQLiteConnection?
    /// Set once in init, removed in deinit.
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private let idleDelay: TimeInterval
    private let touchInterval: Int64

    /// Marks an index this build understands. Another value, or none, means rebuild.
    static let writer = "thumbnail-index-1"
    /// UIApplication.didEnterBackgroundNotification, named so the store needs no UIKit.
    private static let didEnterBackground = Notification.Name("UIApplicationDidEnterBackgroundNotification")
    static let indexName = "index.sqlite"

    private struct Weak: @unchecked Sendable { weak var store: ThumbnailDiskStore? }
    private static let opened = Mutex<[String: Weak]>([:])

    /// The store of `scope` under `root`. Everyone in the process who opens the same folder gets the
    /// same store, so its index stays the one view of the folder.
    static func shared(scope: String, limit: Int = defaultLimit, root: URL? = nil) -> ThumbnailDiskStore {
        let directory = directory(scope: scope, root: root)
        return opened.withLock { opened in
            if let store = opened[directory.path]?.store { return store }
            let store = ThumbnailDiskStore(directory: directory, limit: limit)
            opened[directory.path] = Weak(store: store)
            return store
        }
    }

    static let defaultLimit = 1_536 * 1024 * 1024

    static func directory(scope: String, root: URL?) -> URL {
        let base = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = SHA256.hash(data: Data(scope.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("IlyichThumbnails", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// A store of its own, as a new launch would open it. `indexDelay` is how long after opening
    /// the folders are compared with the index; `idleDelay` how long the store must be idle before
    /// it trims; `touchInterval` how stale, in milliseconds, a read must find a row before it
    /// records the new time.
    init(directory: URL, limit: Int = defaultLimit, fence: MediaFence = MediaFence(),
         indexDelay: TimeInterval? = 2, idleDelay: TimeInterval = 5, touchInterval: Int64 = 60_000) {
        self.directory = directory
        self.limit = limit
        self.fence = fence
        self.idleDelay = idleDelay
        self.touchInterval = touchInterval
        queue.async { [self] in load() }
        if let indexDelay {
            queue.asyncAfter(deadline: .now() + indexDelay) { [weak self] in self?.startScan() }
        }
        let token = NotificationCenter.default.addObserver(forName: Self.didEnterBackground, object: nil, queue: nil) { [weak self] _ in
            self?.maintainInBackground()
        }
        observer = token
    }

    convenience init(scope: String, limit: Int = defaultLimit, root: URL? = nil, indexDelay: TimeInterval? = 2) {
        self.init(directory: Self.directory(scope: scope, root: root), limit: limit, indexDelay: indexDelay)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Names

    /// `<asset>.<revision digest>` in a folder per ID prefix, so an asset's files are easy to find.
    nonisolated func url(assetID: String, revision: String) -> URL {
        url(name: Self.name(assetID: assetID, revision: revision))
    }

    private nonisolated func url(name: String) -> URL {
        directory.appendingPathComponent(Self.folder(ofName: name), isDirectory: true).appendingPathComponent(name)
    }

    private static func name(assetID: String, revision: String) -> String {
        let digest = SHA256.hash(data: Data(revision.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return stem(assetID) + "." + digest
    }

    private static func stem(_ assetID: String) -> String {
        let safe = !assetID.isEmpty && assetID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return safe ? assetID.lowercased() : SHA256.hash(data: Data(assetID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func folder(ofName name: String) -> String { String(name.prefix(2)) }
    private static func stem(ofName name: String) -> Substring { name.prefix { $0 != "." } }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    /// Files occupy whole 4 KB blocks.
    private static func allocated(_ bytes: Int) -> Int { (bytes + 4_095) / 4_096 * 4_096 }

    // MARK: Reads, from any thread

    /// The stored thumbnail. A file the index lists but that can't be read is a miss, and leaves the index.
    nonisolated func data(assetID: String, revision: String) -> Data? {
        let name = Self.name(assetID: assetID, revision: revision)
        if let pending = state.withLock({ $0.pending[name]?.data }) { return pending }
        if let data = try? Data(contentsOf: url(name: name)) {
            touch(name)
            return data
        }
        if state.withLock({ $0.rows[name] != nil }) { queue.async { [self] in dropIfMissing(name) } }
        return nil
    }

    nonisolated func contains(assetID: String, revision: String) -> Bool {
        let name = Self.name(assetID: assetID, revision: revision)
        let known = state.withLock { state -> Bool? in
            if state.pending[name] != nil { return true }
            return state.knows(Self.folder(ofName: name)) ? state.rows[name] != nil : nil
        }
        return known ?? FileManager.default.fileExists(atPath: url(name: name).path)
    }

    private func touch(_ name: String) {
        let now = Self.now()
        let schedule = state.withLock { state -> Bool in
            state.lastActivity = now
            guard var row = state.rows[name], now - row.access >= touchInterval else { return false }
            row.access = now
            state.rows[name] = row
            state.dirty[name] = row
            return true
        }
        if schedule { scheduleFlush() }
    }

    // MARK: Writes

    /// Stores `data` as the thumbnail of `assetID` at `revision` and returns at once; it can be read
    /// straight away. `token` is the fence's, taken when the download began: a photo forgotten
    /// since, or a store cleared since, is not written. The check runs again on the store's own
    /// turn, so a write either comes before the forgetting, which then deletes it, or is refused.
    nonisolated func enqueueWrite(_ data: Data, assetID: String, revision: String, token: UInt64) {
        guard fence.admits(assetID, since: token) else { return }
        let name = Self.name(assetID: assetID, revision: revision)
        let ticket = state.withLock { state -> UInt64 in
            state.tickets &+= 1
            state.pending[name] = Pending(data: data, ticket: state.tickets)
            state.lastActivity = Self.now()
            return state.tickets
        }
        queue.async { [self] in write(name, assetID: assetID, ticket: ticket, token: token) }
    }

    /// Writes and waits until the file is on disk, for tests and callers that need it there.
    func store(_ data: Data, assetID: String, revision: String, token: UInt64? = nil) async {
        enqueueWrite(data, assetID: assetID, revision: revision, token: token ?? fence.token())
        await onQueue { }
    }

    private func write(_ name: String, assetID: String, ticket: UInt64, token: UInt64) {
        guard let pending = state.withLock({ $0.pending[name] }), pending.ticket == ticket else { return }
        guard fence.admits(assetID, since: token) else {
            state.withLock { state in if state.pending[name]?.ticket == ticket { state.pending[name] = nil } }
            return
        }
        let url = url(name: name)
        var written = false
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pending.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            written = true
        } catch {}
        let others = otherRevisions(of: name)
        state.withLock { state in
            if state.pending[name]?.ticket == ticket { state.pending[name] = nil }
            if written { state.put(name, Row(size: Self.allocated(pending.data.count), access: Self.now())) }
        }
        // A new revision makes older ones of the same photo useless.
        if written { remove(others) }
        scheduleFlush()
        scheduleMaintenance()
    }

    /// The photo's other files: from the index, or for a folder it doesn't know yet, from a listing.
    private func otherRevisions(of name: String) -> [String] {
        let folder = Self.folder(ofName: name), prefix = Self.stem(ofName: name) + "."
        if let known = state.withLock({ $0.knows(folder) ? Array($0.folders[folder] ?? []) : nil }) {
            return known.filter { $0 != name && $0.hasPrefix(prefix) }
        }
        return list(folder).filter { $0 != name && $0.hasPrefix(prefix) }
    }

    private func list(_ folder: String) -> [String] {
        listings.add(1, ordering: .relaxed)
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(folder, isDirectory: true).path)) ?? []
    }

    /// Deletes these files, unless a newer write of the same name waits.
    private func remove(_ names: some Sequence<String>) {
        for name in names {
            guard state.withLock({ $0.pending[name] == nil }) else { continue }
            try? FileManager.default.removeItem(at: url(name: name))
            state.withLock { state in state.drop(name) }
        }
    }

    private func dropIfMissing(_ name: String) {
        guard state.withLock({ $0.pending[name] == nil && $0.rows[name] != nil }),
              !FileManager.default.fileExists(atPath: url(name: name).path) else { return }
        state.withLock { state in state.drop(name) }
        scheduleFlush()
    }

    // MARK: Forgetting

    /// Photos that left the library leave nothing behind, every revision of them.
    func forget(assetIDs: some Sequence<String>) async {
        let stems = Set(assetIDs.map { Self.stem($0) })
        guard !stems.isEmpty else { return }
        state.withLock { state in
            for name in state.pending.keys where stems.contains(String(Self.stem(ofName: name))) { state.pending[name] = nil }
        }
        await onQueue { [self] in
            var byFolder: [String: Set<String>] = [:]
            for stem in stems { byFolder[String(stem.prefix(2)), default: []].insert(stem) }
            for (folder, gone) in byFolder {
                let names = state.withLock { $0.knows(folder) ? Array($0.folders[folder] ?? []) : nil } ?? list(folder)
                remove(names.filter { gone.contains(String(Self.stem(ofName: $0))) })
            }
            flush()
        }
    }

    /// The photo's previews were made again: only the file for `revision` stays, if there is one,
    /// so the next look downloads the new thumbnail.
    func refresh(assetID: String, revision: String) async {
        let keep = Self.name(assetID: assetID, revision: revision)
        await onQueue { [self] in
            remove(otherRevisions(of: keep))
            scheduleFlush()
        }
    }

    /// After the server reset the library: keeps the files of the photos the index now holds, at
    /// the revision it holds, and removes every other, which may belong to a photo the account
    /// can no longer see. Returns how many went. It lists every folder first, even under a complete
    /// index: files whose rows were never saved (a crash before the batched save) or that an older
    /// build wrote are on disk but not listed, and this sweep must not miss them.
    @discardableResult
    func sweep(keeping valid: [String: String]) async -> Int {
        let kept = Set(valid.map { Self.name(assetID: $0.key, revision: $0.value) })
        return await onQueue { [self] in
            ensureComplete(listingEveryFolder: true)
            let gone = state.withLock { state in state.rows.keys.filter { !kept.contains($0) && state.pending[$0] == nil } }
            remove(gone)
            flush()
            return gone.count
        }
    }

    /// Sign-out and Clear browsing cache: every file and the index go. A write begun before is refused.
    func removeAll() async {
        fence.forgetAll()
        state.withLock { state in state.pending.removeAll() }
        await onQueue { [self] in
            database?.close(); database = nil
            try? FileManager.default.removeItem(at: directory)
            state.withLock { state in
                let pending = state.pending, tickets = state.tickets
                state = State()
                state.complete = true
                state.pending = pending; state.tickets = tickets
            }
        }
    }

    // MARK: Size and maintenance

    func currentUsage() async -> Int {
        await onQueue { [self] in
            ensureComplete()
            return state.withLock { $0.usage }
        }
    }

    /// Waits until the index lists every file, adopting any not yet listed.
    func waitUntilIndexed() async {
        await onQueue { [self] in ensureComplete(); flush() }
    }

    /// Whether the index lists every file, for tests.
    var isIndexComplete: Bool { state.withLock { $0.complete } }

    /// Trims now if the store is over its limit, least recently viewed first, down to 90 % so
    /// trimming stays rare. Normally this waits for the store to be idle.
    func maintain() async {
        await onQueue { [self] in maintainNow() }
    }

    nonisolated func maintainInBackground() {
        queue.async { [self] in maintainNow() }
    }

    private func scheduleMaintenance() {
        let schedule = state.withLock { state -> Bool in
            guard !state.maintenanceScheduled, state.usage > limit else { return false }
            state.maintenanceScheduled = true
            return true
        }
        if schedule { queue.asyncAfter(deadline: .now() + idleDelay) { [weak self] in self?.maintainWhenIdle() } }
    }

    private func maintainWhenIdle() {
        let wait = state.withLock { state -> Int64 in
            let idle = Self.now() - state.lastActivity, needed = Int64(idleDelay * 1_000)
            if idle >= needed { state.maintenanceScheduled = false; return 0 }
            return needed - idle
        }
        guard wait == 0 else {
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(wait))) { [weak self] in self?.maintainWhenIdle() }
            return
        }
        maintainNow()
    }

    private func maintainNow() {
        defer { flush() }
        guard state.withLock({ $0.usage > limit }) else { return }
        ensureComplete()
        let target = limit / 10 * 9
        let order = state.withLock { state in state.rows.sorted { $0.value.access < $1.value.access }.map { ($0.key, $0.value.size) } }
        var usage = state.withLock { $0.usage }
        var gone: [String] = []
        for (name, size) in order where usage > target {
            gone.append(name); usage -= size
        }
        remove(gone)
    }

    // MARK: The index

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: work()) } }
    }

    /// Opens the index and loads it into memory. One written by another build, or none, is
    /// rebuilt from the folders.
    private func load() {
        guard let database = openDatabase() else { return }
        var meta: [String: String] = [:]
        try? database.run("SELECT key, value FROM meta") { row in
            if let key = row.text(0), let value = row.text(1) { meta[key] = value }
        }
        if meta["writer"] != Self.writer {
            try? database.transaction {
                try database.execute("DELETE FROM files")
                try database.execute("DELETE FROM meta")
                try database.execute("INSERT INTO meta(key, value) VALUES('writer', ?)", [.text(Self.writer)])
            }
            meta = ["writer": Self.writer]
        }
        var rows: [String: Row] = [:]
        try? database.run("SELECT name, size, last_access FROM files") { row in
            if let name = row.text(0) { rows[name] = Row(size: Int(row.integer(1) ?? 0), access: row.integer(2) ?? 0) }
        }
        state.withLock { state in
            // Writes made before the index was read are already in memory; they win.
            for (name, row) in rows where state.rows[name] == nil {
                state.rows[name] = row
                state.usage += row.size
                state.folders[Self.folder(ofName: name), default: []].insert(name)
            }
            state.complete = meta["complete"] == "1"
            state.cursor = state.complete ? nil : meta["cursor"]
            state.meta = meta
        }
    }

    private func openDatabase() -> SQLiteConnection? {
        if let database { return database }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let opened = try SQLiteConnection(path: directory.appendingPathComponent(Self.indexName).path, readOnly: false, busyTimeout: 2_000)
            try opened.execute("PRAGMA journal_mode=WAL")
            try opened.execute("PRAGMA synchronous=NORMAL")
            try opened.execute("CREATE TABLE IF NOT EXISTS files(name TEXT PRIMARY KEY, size INTEGER NOT NULL, last_access INTEGER NOT NULL) WITHOUT ROWID")
            try opened.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            let writer = try opened.scalar("SELECT value FROM meta WHERE key = 'writer'")
            if writer == .null {
                try opened.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('writer', ?)", [.text(Self.writer)])
                // A new index over a store that was just cleared lists everything there is.
                if state.withLock({ $0.complete }) {
                    try opened.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('complete', '1')")
                }
            }
            database = opened
            return opened
        } catch {
            // Without an index the store still works from the file system.
            return nil
        }
    }

    private func setMeta(_ key: String, _ value: String?) {
        state.withLock { $0.meta[key] = value }
        guard let database = openDatabase() else { return }
        if let value {
            try? database.execute("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [.text(key), .text(value)])
        } else {
            try? database.execute("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    // MARK: Coverage

    private enum CoverageKey {
        static let cursor = "coverage_cursor", mark = "coverage_mark", policy = "policy_hash", total = "coverage_total", stored = "coverage_stored"
    }

    /// Where coverage is (REBUILD_ROADMAP.md T5), from the index's meta rows. Read on the store's
    /// queue, so it comes after the index was loaded; a store that was cleared, or an index another
    /// build wrote, has none, and coverage verifies the library again without fetching present files.
    func coverageState() async -> CoverageState {
        await onQueue { [self] in
            state.withLock { state in
                CoverageState(cursor: state.meta[CoverageKey.cursor], mark: state.meta[CoverageKey.mark].flatMap { Int64($0) },
                              policyHash: state.meta[CoverageKey.policy], total: state.meta[CoverageKey.total].flatMap(Int.init) ?? 0,
                              stored: state.meta[CoverageKey.stored].flatMap(Int.init) ?? 0)
            }
        }
    }

    /// Saves coverage's position and counts in one transaction.
    func saveCoverageState(_ coverage: CoverageState) async {
        await onQueue { [self] in
            let rows: [(String, String?)] = [
                (CoverageKey.cursor, coverage.cursor), (CoverageKey.mark, coverage.mark.map { String($0) }), (CoverageKey.policy, coverage.policyHash),
                (CoverageKey.total, String(coverage.total)), (CoverageKey.stored, String(coverage.stored)),
            ]
            guard let database = openDatabase() else {
                for (key, value) in rows { state.withLock { $0.meta[key] = value } }
                return
            }
            try? database.transaction { for (key, value) in rows { setMeta(key, value) } }
        }
    }

    private func scheduleFlush() {
        let (schedule, now) = state.withLock { state -> (Bool, Bool) in
            if state.dirty.count >= 256 { return (false, true) }
            guard !state.flushScheduled, !state.dirty.isEmpty else { return (false, false) }
            state.flushScheduled = true
            return (true, false)
        }
        if now { queue.async { [self] in flush() } }
        if schedule { queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.flush() } }
    }

    /// Saves the rows changed since the last flush, in one transaction.
    private func flush() {
        let dirty = state.withLock { state -> [String: Row?] in
            state.flushScheduled = false
            defer { state.dirty = [:] }
            return state.dirty
        }
        guard !dirty.isEmpty else { return }
        guard let database = openDatabase() else { return }
        try? database.transaction {
            for (name, row) in dirty {
                if let row {
                    try database.execute("INSERT INTO files(name, size, last_access) VALUES(?, ?, ?) ON CONFLICT(name) DO UPDATE SET size = excluded.size, last_access = excluded.last_access",
                                         [.text(name), .integer(Int64(row.size)), .integer(row.access)])
                } else {
                    try database.execute("DELETE FROM files WHERE name = ?", [.text(name)])
                }
            }
        }
    }

    /// Compares the folders with the index, one folder per turn of the queue so writes go on
    /// meanwhile. While the index is being built, each folder done is saved, so an interrupted
    /// build resumes where it stopped.
    private func startScan() {
        let folders = listRoot()
        let building = !state.withLock { $0.complete }
        dropFolders(notIn: Set(folders))
        for folder in folders {
            queue.async { [weak self] in
                guard let self else { return }
                if building {
                    guard !state.withLock({ $0.knows(folder) }) else { return }
                    adopt(folder)
                    flush()
                    state.withLock { $0.cursor = folder }
                    setMeta("cursor", folder)
                } else {
                    adopt(folder)
                }
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            if building { ensureComplete() }
            flush()
        }
    }

    private func listRoot() -> [String] {
        listings.add(1, ordering: .relaxed)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { name in
            var isFolder: ObjCBool = false
            return name.count == 2 && FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isFolder) && isFolder.boolValue
        }.sorted()
    }

    /// Rows of folders that are gone, removed by iOS or an older build, leave the index.
    private func dropFolders(notIn present: Set<String>) {
        state.withLock { state in
            for folder in state.folders.keys where !present.contains(folder) && state.knows(folder) {
                for name in state.folders[folder] ?? [] where state.pending[name] == nil { state.drop(name) }
            }
        }
    }

    /// Lists one folder: files the index lacks are added, as last viewed when they were written,
    /// and rows whose file is gone are removed.
    private func adopt(_ folder: String) {
        let onDisk = Set(list(folder))
        let (known, pending) = state.withLock { state in (state.folders[folder] ?? [], Set(state.pending.keys)) }
        var found: [(String, Row)] = []
        for name in onDisk.subtracting(known) {
            let file = url(name: name)
            guard let values = try? file.resourceValues(forKeys: [.fileAllocatedSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let written = Int64((values.contentModificationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1_000)
            found.append((name, Row(size: values.fileAllocatedSize ?? Self.allocated(0), access: written)))
        }
        state.withLock { state in
            for (name, row) in found where state.rows[name] == nil { state.put(name, row) }
            for name in known.subtracting(onDisk) where !pending.contains(name) && state.pending[name] == nil { state.drop(name) }
        }
    }

    /// Adopts every folder the index doesn't know yet, at once; with `listingEveryFolder`, every
    /// folder, so the index matches the disk even where it thought it already did.
    private func ensureComplete(listingEveryFolder: Bool = false) {
        guard listingEveryFolder || !state.withLock({ $0.complete }) else { return }
        let folders = listRoot()
        for folder in folders where listingEveryFolder || !state.withLock({ $0.knows(folder) }) { adopt(folder) }
        state.withLock { state in
            state.complete = true
            state.cursor = nil
        }
        dropFolders(notIn: Set(folders))
        flush()
        setMeta("complete", "1")
        setMeta("cursor", nil)
    }
}

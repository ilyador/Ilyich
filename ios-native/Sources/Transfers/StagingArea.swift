import Foundation
import IlyichPlatform

/// One account's staging folders in the App Group (B6, dormant until B9): Backup/<digest>/<uuid>/,
/// each holding a stage's files (original, motion, sidecar) and its attempts' bodies and outcome
/// files (<attempt>.multipart, <attempt>.receipt). Only folders named by a UUID directly inside the
/// account's Backup folder are ever touched; state.json and anything else there stays, and so does
/// every other account's folder and the share inbox.
///
/// Until the transfers database has imported state.json authoritatively, a Backup folder holding
/// state.json is BackupCoordinator's, and its stages are too: nothing is removed from it.
struct StagingArea: Sendable {
    /// A file or folder changed this recently may be one staging is still writing, so it stays.
    static let grace: TimeInterval = 15 * 60

    enum Skip: Hashable, Sendable {
        /// state.json is there and the database never imported it authoritatively.
        case legacyState
        /// The account's Backup folder could not be listed.
        case unavailable
    }

    struct Sweep: Hashable, Sendable {
        var folders = 0
        var files = 0
        var bytes: Int64 = 0
        var skipped: Skip?
    }

    let layout: AppGroupLayout
    /// The account's Backup folder, relative to the App Group.
    let folder: String

    init(layout: AppGroupLayout, account: AccountID) {
        self.layout = layout
        folder = AccountStoragePaths(account).backup
    }

    /// Removes what nothing needs: stage folders no stage, unanswered attempt or task of iOS's
    /// refers to, and in the folders that stay, the bodies and outcome files of attempts that are
    /// answered, abandoned or gone. Anything changed within the grace period stays.
    func sweep(keeping references: StagingReferences, legacyImported: Bool, now: Date) -> Sweep {
        var sweep = Sweep()
        guard let folders = stageFolders(legacyImported: legacyImported, into: &sweep) else { return sweep }
        let cutoff = now.addingTimeInterval(-Self.grace)
        for url in folders {
            let path = folder + "/" + url.lastPathComponent
            let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            if !references.folders.contains(path) {
                let newest = ([url] + entries).compactMap(Self.modified).max() ?? .distantPast
                guard newest < cutoff else { continue }
                remove(url, into: &sweep)
                continue
            }
            for entry in entries {
                let name = entry.lastPathComponent
                guard let attempt = Self.attempt(named: name), !references.attempts.contains(attempt),
                      (Self.modified(entry) ?? .distantFuture) < cutoff else { continue }
                let bytes = Self.size(entry)
                guard (try? FileManager.default.removeItem(at: entry)) != nil else { continue }
                sweep.files += 1
                sweep.bytes += bytes
            }
        }
        return sweep
    }

    /// Removes every stage folder of the account, as signing out does once its tasks are cancelled.
    /// The transfers database stays, and the next reconcile stages its jobs again.
    func removeAll(legacyImported: Bool) -> Sweep {
        var sweep = Sweep()
        guard let folders = stageFolders(legacyImported: legacyImported, into: &sweep) else { return sweep }
        for url in folders { remove(url, into: &sweep) }
        return sweep
    }

    // MARK: -

    private func stageFolders(legacyImported: Bool, into sweep: inout Sweep) -> [URL]? {
        let root = layout.url(forRelativePath: folder)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        if !legacyImported, FileManager.default.fileExists(atPath: root.appendingPathComponent(LegacyBackupImporter.fileName).path) {
            sweep.skipped = .legacyState
            return nil
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            sweep.skipped = .unavailable
            return nil
        }
        return entries.filter { url in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func remove(_ url: URL, into sweep: inout Sweep) {
        var files = 0
        var bytes: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let file as URL in enumerator where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files += 1
                bytes += Self.size(file)
            }
        }
        guard (try? FileManager.default.removeItem(at: url)) != nil else { return }
        sweep.folders += 1
        sweep.files += files
        sweep.bytes += bytes
    }

    /// The attempt a body or outcome file is named after.
    private static func attempt(named name: String) -> String? {
        for suffix in [".multipart", ".receipt"] where name.hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return nil
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

/// What staging must keep: folders, relative to the App Group, and attempts whose body and outcome
/// file stay.
struct StagingReferences: Hashable, Sendable {
    var folders: Set<String> = []
    var attempts: Set<String> = []
}

extension UploadBody {
    /// Whether a body file was written to its end: it closes with its boundary and, when its size
    /// was recorded after the write, still has it. A write the app ended during leaves neither.
    /// Nil when the file is there but can't be read now, as before the first unlock.
    static func isComplete(_ url: URL, boundary: String, bytes: Int64?) -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let ending = Data("--\(boundary)--\r\n".utf8)
        guard let size = try? handle.seekToEnd(), size >= UInt64(ending.count) else { return false }
        if let bytes, bytes != Int64(size) { return false }
        guard (try? handle.seek(toOffset: size - UInt64(ending.count))) != nil else { return false }
        return (try? handle.read(upToCount: ending.count)) == ending
    }
}

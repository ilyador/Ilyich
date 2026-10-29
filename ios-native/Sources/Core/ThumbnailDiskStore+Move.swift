import Darwin
import Foundation
import Synchronization

/// The store moves out of Caches (REBUILD_ROADMAP.md T8). Builds before T8 kept grid thumbnails in
/// Caches/IlyichThumbnails, which iOS empties when it likes, and coverage then downloaded the whole
/// library again. The store now lives in Application Support/IlyichThumbnails, kept out of backups.
extension ThumbnailDiskStore {
    /// Where builds before T8 kept the store's folders.
    static var cachesRoot: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    /// One move at a time in the process, as stores of two accounts may open together. A test holds
    /// it to look at a store before its move.
    static let moveLock = Mutex(())

    /// Moves everything under `earlier`, the IlyichThumbnails folder of a build before T8, into
    /// `tree`, by renaming on the same volume: nothing is copied, and nothing is downloaded again.
    /// When `tree` doesn't exist, as at the first launch after the update, that is one rename, and
    /// each account's folder arrives with its index. Otherwise it goes folder by folder:
    /// - an account's folder that `tree` lacks moves whole, with its index;
    /// - one `tree` has already (from a move a kill stopped, or written by an older build after this
    ///   one ran) is merged. Its index is first marked as listing only part of the folder, so the
    ///   store asks the disk until the launch comparison has adopted what arrives; the earlier
    ///   index goes. In it, a two-letter folder `tree` lacks moves whole, and one it has, a file at
    ///   a time.
    /// Nothing at `tree` is replaced or removed: a file it has already is the same photo at the same
    /// revision, and the earlier copy goes. A folder goes once it is empty, `earlier` last. Anything
    /// that could not be moved stays, and the next launch tries again, as it finishes a move a kill
    /// stopped. `moves` stops it after that many changes, as a kill would, for a test. Returns the
    /// changes it tried.
    @discardableResult
    static func moveEarlierFolders(from earlier: URL, to tree: URL, moves: Int = .max) -> Int {
        var move = FolderMove(limit: moves)
        move.run(from: earlier, to: tree)
        return move.tried
    }

    /// Keeps `folder`, and everything in it, out of iCloud and computer backups: the thumbnails are
    /// the server's, and a restored phone downloads them again. Sets the mark only when it is missing.
    static func excludeFromBackup(_ folder: URL) {
        // A URL of its own, as resource values are cached per URL.
        var url = URL(fileURLWithPath: folder.path, isDirectory: true)
        guard (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// One run of the move. It counts the changes it tries, so a test can stop it where a kill would.
private struct FolderMove {
    let limit: Int
    private(set) var tried = 0

    init(limit: Int) { self.limit = limit }

    private enum Outcome { case moved, taken, failed }

    mutating func run(from earlier: URL, to tree: URL) {
        // Merging a folder into itself would take every file for a copy already there.
        guard earlier.resolvingSymlinksInPath().standardizedFileURL.path != tree.resolvingSymlinksInPath().standardizedFileURL.path,
              Self.exists(earlier) else { return }
        try? FileManager.default.createDirectory(at: tree.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard rename(earlier, to: tree) == .taken else { return }
        for name in Self.names(in: earlier) {
            let from = earlier.appendingPathComponent(name), to = tree.appendingPathComponent(name)
            guard rename(from, to: to) == .taken else { continue }
            if Self.isFolder(from) && Self.isFolder(to) { merge(from, into: to) } else if !Self.isFolder(from) { remove(from) }
        }
        removeIfEmpty(earlier)
    }

    /// One account's folder into the one `tree` has already.
    private mutating func merge(_ source: URL, into destination: URL) {
        markForComparison(destination.appendingPathComponent(ThumbnailDiskStore.indexName))
        for name in Self.names(in: source) {
            let from = source.appendingPathComponent(name), to = destination.appendingPathComponent(name)
            // The earlier index lists only files the comparison adopts anyway; the folder here keeps its own.
            if name.hasPrefix(ThumbnailDiskStore.indexName) { remove(from); continue }
            guard rename(from, to: to) == .taken else { continue }
            if Self.isFolder(from) && Self.isFolder(to) {
                for file in Self.names(in: from) {
                    let earlierFile = from.appendingPathComponent(file)
                    // The same photo at the same revision is here already.
                    if rename(earlierFile, to: to.appendingPathComponent(file)) == .taken, !Self.isFolder(earlierFile) { remove(earlierFile) }
                }
                removeIfEmpty(from)
            } else if !Self.isFolder(from) {
                remove(from)
            }
        }
        removeIfEmpty(source)
    }

    /// Marks the index of a folder being merged into as listing only part of it. An index that
    /// can't be marked goes, and the store builds it again from the folders.
    private mutating func markForComparison(_ index: URL) {
        guard step(), Self.exists(index) else { return }
        do {
            let database = try SQLiteConnection(path: index.path, readOnly: false, busyTimeout: 2_000)
            try database.execute("DELETE FROM meta WHERE key IN ('complete', 'cursor')")
        } catch {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: index.path + suffix) }
        }
    }

    private mutating func step() -> Bool {
        guard tried < limit else { return false }
        tried += 1
        return true
    }

    /// Renames without ever replacing what is at the destination (RENAME_EXCL); `taken` when
    /// something is there.
    private mutating func rename(_ source: URL, to destination: URL) -> Outcome {
        guard step() else { return .failed }
        let (status, error) = source.withUnsafeFileSystemRepresentation { from -> (Int32, Int32) in
            destination.withUnsafeFileSystemRepresentation { to -> (Int32, Int32) in
                guard let from, let to else { return (-1, EINVAL) }
                let status = renamex_np(from, to, UInt32(RENAME_EXCL))
                return (status, status == 0 ? 0 : errno)
            }
        }
        if status == 0 { return .moved }
        return error == EEXIST || error == ENOTEMPTY ? .taken : .failed
    }

    private mutating func remove(_ url: URL) {
        guard step() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes a folder only if nothing is left in it.
    private mutating func removeIfEmpty(_ folder: URL) {
        guard step() else { return }
        _ = folder.withUnsafeFileSystemRepresentation { path in path.map { rmdir($0) } }
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    private static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
}

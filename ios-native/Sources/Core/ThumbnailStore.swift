import CryptoKit
import Foundation

/// Grid thumbnails on disk, keyed by asset and revision instead of by URL. Switching between
/// the home and the remote address keeps them, and an edited photo replaces only its own.
/// A whole library, about 12 KB a photo, fits under the cap; past it the oldest files go first.
actor ThumbnailStore {
    nonisolated let directory: URL
    nonisolated let limit: Int
    /// Downloads that began before their photo was forgotten are not written.
    nonisolated let fence = MediaFence()
    private var usage: Int?

    init(scope: String, limit: Int = 1_536 * 1024 * 1024, root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = SHA256.hash(data: Data(scope.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        directory = base.appendingPathComponent("IlyichThumbnails", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        self.limit = limit
    }

    /// `<asset>.<revision digest>` in a folder per ID prefix, so an asset's files are easy to find.
    nonisolated func url(assetID: String, revision: String) -> URL {
        let name = Self.fileName(assetID)
        let digest = SHA256.hash(data: Data(revision.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(name.prefix(2)), isDirectory: true).appendingPathComponent(name + "." + digest)
    }

    private nonisolated static func fileName(_ assetID: String) -> String {
        let safe = !assetID.isEmpty && assetID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return safe ? assetID.lowercased() : SHA256.hash(data: Data(assetID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads need no coordination: writes are atomic, so a file that exists is complete.
    nonisolated func data(assetID: String, revision: String) -> Data? {
        try? Data(contentsOf: url(assetID: assetID, revision: revision))
    }

    nonisolated func contains(assetID: String, revision: String) -> Bool {
        FileManager.default.fileExists(atPath: url(assetID: assetID, revision: revision).path)
    }

    /// `token` is the fence's, taken when the download began; a photo forgotten since is not
    /// written. The check runs here, on the store's own turn, so a write either comes before the
    /// forgetting, which then deletes it, or is refused.
    func store(_ data: Data, assetID: String, revision: String, token: UInt64? = nil) {
        if let token, !fence.admits(assetID, since: token) { return }
        let url = url(assetID: assetID, revision: revision)
        let existed = FileManager.default.fileExists(atPath: url.path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { return }
        if !existed, let current = usage { usage = current + Self.allocated(data.count) }
        // A new revision makes older ones of the same photo useless.
        remove(assetID: assetID, keeping: url)
        trimIfNeeded()
    }

    /// Photos that left the library leave nothing behind. Each folder is listed once, however
    /// many of its photos go.
    func forget(assetIDs: some Sequence<String>) {
        var names: [String: Set<String>] = [:]
        for id in assetIDs {
            let name = Self.fileName(id)
            names[String(name.prefix(2)), default: []].insert(name)
        }
        for (prefix, gone) in names {
            let folder = directory.appendingPathComponent(prefix, isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileAllocatedSizeKey]) else { continue }
            for file in files where gone.contains(String(file.lastPathComponent.prefix { $0 != "." })) {
                let size = (try? file.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
                if (try? FileManager.default.removeItem(at: file)) != nil, let current = usage { usage = max(0, current - size) }
            }
        }
    }

    /// The photo's previews were made again: only the file for `revision` stays, if there is one,
    /// so the next look downloads the new thumbnail.
    func refresh(assetID: String, revision: String) {
        remove(assetID: assetID, keeping: url(assetID: assetID, revision: revision))
    }

    /// After the server reset the library: keeps the files of the photos the index now holds, at
    /// the revision it holds, and removes every other, which may belong to a photo the account
    /// can no longer see. Returns how many went.
    @discardableResult
    func sweep(keeping valid: [String: String]) -> Int {
        let kept = Set(valid.map { url(assetID: $0.key, revision: $0.value).lastPathComponent })
        var removed = 0
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileAllocatedSizeKey]) else { continue }
            for file in files where !kept.contains(file.lastPathComponent) {
                let size = (try? file.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
                if (try? FileManager.default.removeItem(at: file)) != nil {
                    removed += 1
                    if let current = usage { usage = max(0, current - size) }
                }
            }
        }
        return removed
    }

    private func remove(assetID: String, keeping kept: URL?) {
        let name = Self.fileName(assetID)
        let folder = directory.appendingPathComponent(String(name.prefix(2)), isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileAllocatedSizeKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix(name + ".") && file.lastPathComponent != kept?.lastPathComponent {
            let size = (try? file.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0
            if (try? FileManager.default.removeItem(at: file)) != nil, let current = usage { usage = max(0, current - size) }
        }
    }

    func currentUsage() -> Int { measuredUsage() }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        usage = 0
    }

    /// Files occupy whole 4 KB blocks.
    private static func allocated(_ bytes: Int) -> Int { (bytes + 4_095) / 4_096 * 4_096 }

    private func measuredUsage() -> Int {
        if let usage { return usage }
        var total = 0
        if let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey]) {
            for case let file as URL in files {
                guard let values = try? file.resourceValues(forKeys: [.fileAllocatedSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
                total += values.fileAllocatedSize ?? 0
            }
        }
        usage = total
        return total
    }

    /// Oldest files first, down to 90% of the cap, so trimming stays rare.
    private func trimIfNeeded() {
        guard measuredUsage() > limit else { return }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileAllocatedSizeKey, .isRegularFileKey]
        var files: [(url: URL, date: Date, size: Int)] = []
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) {
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                files.append((file, values.contentModificationDate ?? .distantPast, values.fileAllocatedSize ?? 0))
            }
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where total > limit * 9 / 10 {
            if (try? FileManager.default.removeItem(at: file.url)) != nil { total -= file.size }
        }
        usage = total
    }
}

import Foundation
import CryptoKit

struct TimelineSnapshot: Codable, Sendable {
    var buckets: [TimeBucket]
    var assets: [String: [Asset]]
}

/// A bounded cache of visited months. It contains neither authentication nor locked photos.
struct CachedTimelineUsage: Sendable { let snapshotCount: Int; let diskBytes: Int }

actor TimelineCache {
    static let shared = TimelineCache()
    private let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("IlyichTimelines", isDirectory: true)
    private var epochs: [String: UUID] = [:]
    func epoch(scope: String) -> UUID {
        if let value = epochs[scope] { return value }
        let value = UUID(); epochs[scope] = value; return value
    }
    func load(scope: String, filter: TimelineFilter) -> TimelineSnapshot? {
        guard filter.visibility != .locked else { return nil }
        guard let data = try? Data(contentsOf: file(scope: scope, filter: filter)), data.count <= 50 * 1024 * 1024 else { return nil }
        return try? APIJSON.decoder().decode(TimelineSnapshot.self, from: data)
    }
    func save(_ snapshot: TimelineSnapshot, scope: String, filter: TimelineFilter, epoch: UUID) {
        guard filter.visibility != .locked, epochs[scope] == epoch else { return }
        do {
            let url = file(scope: scope, filter: filter)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try APIJSON.encoder().encode(snapshot)
            guard data.count <= 50 * 1024 * 1024 else { return }
            try data.write(to: url, options: .atomic)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            let sorted = files.compactMap { file -> (URL, Date, Int)? in
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
                return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }.sorted { $0.1 > $1.1 }
            var size = 0
            for (index, entry) in sorted.enumerated() {
                size += entry.2
                if index >= 12 || size > 50 * 1024 * 1024 { try? FileManager.default.removeItem(at: entry.0) }
            }
        } catch { /* Cache writes never block a working library or become source data. */ }
    }
    func cacheUsage(scope: String) -> CachedTimelineUsage {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(scope), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])) ?? []
        var count = 0, bytes = 0
        for file in files where file.pathExtension == "json" {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            count += 1; bytes += max(0, values.fileSize ?? 0)
        }
        return .init(snapshotCount: count, diskBytes: bytes)
    }
    func removeAll(scope: String) {
        epochs[scope] = UUID()
        try? FileManager.default.removeItem(at: directory(scope))
    }
    private func directory(_ scope: String) -> URL { root.appendingPathComponent(hash(scope), isDirectory: true) }
    private func file(scope: String, filter: TimelineFilter) -> URL {
        let key = filter.queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        return directory(scope).appendingPathComponent(hash(key) + ".json")
    }
    private func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

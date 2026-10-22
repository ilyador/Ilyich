import Foundation
import CryptoKit

/// Each feed's month places, kept on the phone so the rail names months straight after launch
/// while their places are counted again.
///
/// An account's places are cleared whenever its access changes: a revoked album or partner, a
/// library reset, sign-out. Each clear moves the account's epoch here, and a save carries the
/// epoch from before its count began, so places counted under access the account no longer has
/// are never kept. Temporary until the index's month_places table replaces this cache (F5).
actor TimelinePlacesCache {
    static let shared = TimelinePlacesCache()
    private let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("IlyichTimelinePlaces", isDirectory: true)
    private var epochs: [String: UInt64] = [:]

    /// What a count begins under. It moves with every clear of the account's places.
    func epoch(scope: String) -> UInt64 { epochs[scope] ?? 0 }

    func load(scope: String, query: LibraryQuery) -> TimelinePlaces? {
        guard let data = try? Data(contentsOf: file(scope: scope, query: query)) else { return nil }
        return try? JSONDecoder().decode(TimelinePlaces.self, from: data)
    }
    /// Keeps places counted under `epoch`, unless the account's places were cleared since.
    /// Returns false when they are refused for that.
    @discardableResult
    func save(_ places: TimelinePlaces, scope: String, query: LibraryQuery, epoch: UInt64) -> Bool {
        guard epoch == self.epoch(scope: scope) else { return false }
        do {
            let url = file(scope: scope, query: query)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(places).write(to: url, options: .atomic)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
            // The library and a handful of people or albums are plenty.
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            let sorted = files.sorted {
                let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return first > second
            }
            for stale in sorted.dropFirst(12) { try? FileManager.default.removeItem(at: stale) }
        } catch { /* Cache writes never block a working library. */ }
        return true
    }
    func removeAll(scope: String) {
        epochs[scope] = epoch(scope: scope) &+ 1
        try? FileManager.default.removeItem(at: directory(scope))
    }
    private func directory(_ scope: String) -> URL { root.appendingPathComponent(hash(scope), isDirectory: true) }
    private func file(scope: String, query: LibraryQuery) -> URL {
        directory(scope).appendingPathComponent(hash(query.stableKey) + ".json")
    }
    private func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

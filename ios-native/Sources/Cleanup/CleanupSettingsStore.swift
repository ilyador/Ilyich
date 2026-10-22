import Foundation

/// Free up space's settings as they are kept: the same UserDefaults keys and meanings as the
/// screen's @AppStorage always used, so nothing is migrated.
struct CleanupSettings: Equatable, Sendable {
    var keepFavorites: Bool
    /// "none", "photos" or "videos". Anything else keeps every photo.
    var keepMediaType: String
    /// Albums whose photos stay. Nil when the kept value can't be read, which keeps every photo.
    var keptAlbumIDs: Set<String>?
    /// Days before today a photo must be taken before, or -1 before the first check (30 then).
    var cutoffDaysAgo: Int

    /// The cutoff the days give today: the start of the day that many days ago.
    func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(cutoffDaysAgo < 0 ? 30 : cutoffDaysAgo), to: now) ?? now)
    }

    /// The policy for a check made with `cutoff`.
    func policy(cutoff: Date) -> CleanupPolicy {
        CleanupPolicy(cutoff: cutoff, keepFavorites: keepFavorites, keepMediaType: keepMediaType)
    }
}

/// Reads and writes Free up space's settings. Safe on any thread: UserDefaults is.
struct CleanupSettingsStore: Sendable {
    static let keepFavoritesKey = "cleanupKeepFavorites"
    static let keepMediaTypeKey = "cleanupKeepMediaType"
    static let keepAlbumIDsKey = "cleanupKeepAlbumIDs"
    static let cutoffDaysAgoKey = "cleanupCutoffDaysAgo"
    static let defaultsInitializedKey = "cleanupDefaultsInitialized"
    /// Albums whose titles name a messaging app are kept unless the person chose otherwise.
    static let messagingApps = ["whatsapp", "telegram", "signal", "messenger", "viber", "wechat", "line"]

    /// The defaults to use; nil for the standard ones. UserDefaults is thread-safe.
    nonisolated(unsafe) private let suite: UserDefaults?

    init(defaults: UserDefaults? = nil) { suite = defaults }

    private var defaults: UserDefaults { suite ?? .standard }

    /// The settings now, with the defaults @AppStorage gave: keep favorites, keep neither media
    /// type, no kept albums, and no cutoff chosen yet.
    func load() -> CleanupSettings {
        let favorites = defaults.object(forKey: Self.keepFavoritesKey) == nil ? true : defaults.bool(forKey: Self.keepFavoritesKey)
        let mediaType = defaults.object(forKey: Self.keepMediaTypeKey) == nil ? "none" : (defaults.string(forKey: Self.keepMediaTypeKey) ?? "")
        let days = defaults.object(forKey: Self.cutoffDaysAgoKey) == nil ? -1 : defaults.integer(forKey: Self.cutoffDaysAgoKey)
        return CleanupSettings(keepFavorites: favorites, keepMediaType: mediaType, keptAlbumIDs: keptAlbums(), cutoffDaysAgo: days)
    }

    /// The kept albums: none when nothing is kept, nil when what is kept can't be read.
    private func keptAlbums() -> Set<String>? {
        guard let value = defaults.object(forKey: Self.keepAlbumIDsKey) else { return [] }
        guard let data = value as? Data else { return nil }
        if data.isEmpty { return [] }
        return try? JSONDecoder().decode(Set<String>.self, from: data)
    }

    func setKeepFavorites(_ value: Bool) { defaults.set(value, forKey: Self.keepFavoritesKey) }
    func setKeepMediaType(_ value: String) { defaults.set(value, forKey: Self.keepMediaTypeKey) }
    func setKeptAlbumIDs(_ ids: Set<String>) { defaults.set((try? JSONEncoder().encode(ids)) ?? Data(), forKey: Self.keepAlbumIDsKey) }
    func setCutoffDaysAgo(_ days: Int) { defaults.set(days, forKey: Self.cutoffDaysAgoKey) }

    /// Once, with Photos access: keeps every album whose title names a messaging app, beside the
    /// albums already kept. Returns the kept albums when it did, nil when it had already run.
    @discardableResult
    func applyMessagingDefaults(albums: [DeviceAlbum]) -> Set<String>? {
        guard !defaults.bool(forKey: Self.defaultsInitializedKey) else { return nil }
        let messaging = albums.filter { album in Self.messagingApps.contains { album.title.localizedCaseInsensitiveContains($0) } }.map(\.id)
        let kept = (keptAlbums() ?? []).union(messaging)
        setKeptAlbumIDs(kept)
        defaults.set(true, forKey: Self.defaultsInitializedKey)
        return kept
    }
}

import Foundation

/// A local item remains a PhotoKit item. Its identifier is never sent to a server
/// asset endpoint; a matched item keeps the real server record and permissions.
enum LibraryEntry: Hashable, Identifiable, Sendable {
    case remote(Asset, local: LocalPhoto? = nil)
    case local(LocalPhoto)

    var id: String {
        switch self { case .remote(let asset, _): asset.id; case .local(let photo): "local:" + photo.id }
    }
    var remote: Asset? { if case .remote(let asset, _) = self { return asset }; return nil }
    var local: LocalPhoto? {
        switch self { case .remote(_, let photo): photo; case .local(let photo): photo }
    }
    var date: Date {
        switch self {
        case .remote(let asset, _): asset.localDateTime ?? asset.fileCreatedAt ?? .distantPast
        case .local(let photo): photo.date.map { $0.addingTimeInterval(Double(TimeZone.current.secondsFromGMT(for: $0))) } ?? .distantPast
        }
    }
}

struct MergedTimeline: Sendable {
    var localOnly: [String: [LocalPhoto]] = [:]
    var remoteToLocal: [String: LocalPhoto] = [:]

    init(photos: [LocalPhoto] = [], associations: [String: String] = [:]) {
        for photo in photos {
            if let remote = associations[photo.id] {
                if remoteToLocal[remote] == nil { remoteToLocal[remote] = photo }
            } else if photo.date != nil {
                let key = Self.monthKey(LibraryEntry.local(photo).date)
                localOnly[key, default: []].append(photo)
            }
        }
        for key in localOnly.keys { localOnly[key]?.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) } }
    }
    func buckets(remote: [TimeBucket]) -> [TimeBucket] {
        var remaining = Set(localOnly.keys)
        var result = remote.map { bucket in
            let key = String(bucket.id.prefix(7)); remaining.remove(key)
            return TimeBucket(timeBucket: bucket.id, count: bucket.count + (localOnly[key]?.count ?? 0))
        }
        result += remaining.map { TimeBucket(timeBucket: $0 + "-01", count: localOnly[$0]?.count ?? 0) }
        return result.sorted { $0.id > $1.id }
    }
    func entries(remote: [Asset], bucket: String) -> [LibraryEntry] {
        let items = remote.map { LibraryEntry.remote($0, local: remoteToLocal[$0.id]) }
            + (localOnly[String(bucket.prefix(7))] ?? []).map(LibraryEntry.local)
        return items.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    static func monthKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 1970, parts.month ?? 1)
    }
}

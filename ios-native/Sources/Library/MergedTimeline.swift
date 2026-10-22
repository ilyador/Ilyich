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

/// The phone's photos as the merged library shows them at one moment: the phone-only ones by
/// month ("YYYY-MM"), newest first, and the server photo each backed-up one matched. Each month
/// and the matches carry a digest, so a consumer finds the months a publish changed without
/// reading the photos (F3); the digests hold within one process only.
struct MergedTimeline: Sendable {
    let localOnly: [String: [LocalPhoto]]
    let remoteToLocal: [String: LocalPhoto]
    let localToRemote: [String: String]
    let monthDigests: [String: Int]
    let matchesDigest: Int

    init(photos: [LocalPhoto] = [], associations: [String: String] = [:]) {
        localToRemote = associations
        var localOnly: [String: [LocalPhoto]] = [:], remoteToLocal: [String: LocalPhoto] = [:]
        for photo in photos {
            if let remote = associations[photo.id] {
                if remoteToLocal[remote] == nil { remoteToLocal[remote] = photo }
            } else if photo.date != nil {
                let key = Self.monthKey(LibraryEntry.local(photo).date)
                localOnly[key, default: []].append(photo)
            }
        }
        for key in localOnly.keys { localOnly[key]?.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) } }
        self.localOnly = localOnly; self.remoteToLocal = remoteToLocal
        monthDigests = localOnly.mapValues(Self.digest)
        matchesDigest = Self.digest(remoteToLocal)
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

    /// The phone-only photos of a bucket's month.
    func phoneOnly(in bucket: String) -> [LocalPhoto] { localOnly[String(bucket.prefix(7))] ?? [] }

    /// The months whose phone-only photos differ from an earlier snapshot's, including months
    /// that appeared or emptied.
    func changedMonths(since earlier: MergedTimeline) -> Set<String> {
        Set(monthDigests.keys).union(earlier.monthDigests.keys).filter { monthDigests[$0] != earlier.monthDigests[$0] }
    }

    static func monthKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 1970, parts.month ?? 1)
    }

    private static func digest<Value: Hashable>(_ value: Value) -> Int {
        var hasher = Hasher()
        hasher.combine(value)
        return hasher.finalize()
    }
}

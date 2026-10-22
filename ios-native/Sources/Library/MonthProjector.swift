import Foundation
import Synchronization

/// Builds the grid's months off the main actor (F3). A month's rows are the server's photos and
/// the phone-only ones merged, newest first by the time taken and then by ID, the order the index
/// and the server's months share (owner decision), with the phone's copy beside each server photo
/// it matched; its days; and the places its photos name. Pure: the same input gives the same
/// month, so the store redoes only the months whose input changed and compares nothing itself.
enum MonthProjector {
    /// What one month is made from.
    struct Input: Sendable {
        let bucket: String
        /// The server's photos, in its order. A month only the phone has passes none.
        let remote: [Asset]
        /// The phone's photos of the month that matched no server photo.
        let phoneOnly: [LocalPhoto]
        /// Each server photo's copy on this phone, by server ID.
        let matches: [String: LocalPhoto]
        /// The phone's photos are merged in, so the month is ordered by the time taken. Otherwise
        /// the server's order stands: an album's own, or Recently added by the time added.
        let merges: Bool
        /// The month as it was last projected, to tell what changed.
        let previous: Projection?
    }

    /// One month, ready for the grid.
    struct Projection: Equatable, Sendable {
        let entries: [LibraryEntry]
        let days: [TimelineDayGroup]
        /// Up to two most common places (city, else country) among the server's photos.
        let placeSummary: String?

        /// The rows without these photos. The days are redone when the month is projected again.
        func removing(_ ids: Set<String>) -> Projection {
            Projection(entries: entries.filter { !ids.contains($0.id) }, days: days, placeSummary: placeSummary)
        }
    }

    struct Result: Sendable {
        let bucket: String
        let projection: Projection
        /// Differs from the previous projection.
        let changed: Bool
        /// The rows differ (count, order or identity), not only what a row shows.
        let rowsChanged: Bool
    }

    /// Projects on the cooperative pool, never on the caller's actor.
    @concurrent static func project(_ inputs: [Input]) async -> [Result] {
        Probe.note(onMain: pthread_main_np() != 0, buckets: inputs.map(\.bucket))
        return inputs.map { project($0) }
    }

    /// One month's rows merged, off the caller's actor, for a selection or a date navigation.
    @concurrent static func merge(remote: [Asset], phoneOnly: [LocalPhoto], matches: [String: LocalPhoto]) async -> [LibraryEntry] {
        entries(remote: remote, phoneOnly: phoneOnly, matches: matches)
    }

    static func project(_ input: Input) -> Result {
        let entries = input.merges ? entries(remote: input.remote, phoneOnly: input.phoneOnly, matches: input.matches)
            : input.remote.map { LibraryEntry.remote($0, local: input.matches[$0.id]) }
        let projection = Projection(entries: entries, days: dayGroups(entries), placeSummary: placeSummary(of: input.remote))
        let rowsChanged = input.previous.map { previous in
            previous.entries.count != entries.count || !zip(previous.entries, entries).allSatisfy { $0.id == $1.id }
        } ?? true
        return Result(bucket: input.bucket, projection: projection, changed: input.previous != projection, rowsChanged: rowsChanged)
    }

    /// A month's photos, the server's and the phone-only ones together, newest first by the time
    /// taken, then by ID, whatever order the server's came in.
    static func entries(remote: [Asset], phoneOnly: [LocalPhoto], matches: [String: LocalPhoto]) -> [LibraryEntry] {
        var items = remote.map { LibraryEntry.remote($0, local: matches[$0.id]) }
        items += phoneOnly.map(LibraryEntry.local)
        // A phone photo's date is a time zone lookup, so each is read once, not once per comparison.
        let dated = items.map { (entry: $0, date: $0.date) }
        return dated.sorted { $0.date == $1.date ? $0.entry.id < $1.entry.id : $0.date > $1.date }.map(\.entry)
    }

    /// Runs of photos taken on the same day. Their dates are wall times stored as UTC, and a UTC
    /// day is a whole 86,400 seconds from midnight, so the day is worked out by hand; asking the
    /// calendar for the start of every photo's day was most of the cost of loading a month.
    static func dayGroups(_ entries: [LibraryEntry]) -> [TimelineDayGroup] {
        var style = Date.FormatStyle().month(.wide).day().year()
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        var groups: [TimelineDayGroup] = []
        var currentDay: Double?
        for (item, entry) in entries.enumerated() {
            let day = (entry.date.timeIntervalSinceReferenceDate / 86_400).rounded(.down)
            if currentDay == day {
                groups[groups.count - 1].count += 1
            } else {
                groups.append(TimelineDayGroup(startItem: item, count: 1,
                                               title: Date(timeIntervalSinceReferenceDate: day * 86_400).formatted(style)))
                currentDay = day
            }
        }
        return groups
    }

    /// Up to two most common places (city, else country) among these photos.
    static func placeSummary(of assets: [Asset]) -> String? {
        var counts: [String: Int] = [:]
        for asset in assets {
            guard let exif = asset.exifInfo else { continue }
            let city = exif.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let country = exif.country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = city.isEmpty ? country : city
            if !name.isEmpty { counts[name, default: 0] += 1 }
        }
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return ranked.isEmpty ? nil : ranked.prefix(2).map(\.key).joined(separator: " · ")
    }

    /// For tests: each run's months and whether it ran on the main thread, kept only while recording.
    enum Probe {
        struct Run: Sendable {
            let onMain: Bool
            let buckets: [String]
        }
        private struct State { var recording = false; var runs: [Run] = [] }
        private static let state = Mutex(State())

        static func start() { state.withLock { $0 = State(recording: true) } }
        /// The runs since `start`, and stops recording.
        @discardableResult static func stop() -> [Run] { state.withLock { let runs = $0.runs; $0 = State(); return runs } }
        static var runs: [Run] { state.withLock { $0.runs } }
        fileprivate static func note(onMain: Bool, buckets: [String]) {
            state.withLock { if $0.recording { $0.runs.append(Run(onMain: onMain, buckets: buckets)) } }
        }
    }
}

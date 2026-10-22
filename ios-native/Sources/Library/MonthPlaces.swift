import Foundation

/// Located photos of one month at one place, from the local library index.
struct MonthPlaceCount: Sendable, Equatable {
    let bucket: String
    let city: String?
    let country: String?
    let count: Int

    var name: String? { Self.text(city) ?? Self.text(country) }
    var countryName: String? { Self.text(country) }

    private static func text(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct PlaceTally: Sendable, Equatable {
    let name: String
    let count: Int
}

/// The places of one feed, ready for the rail: each month's, ranked, the months spent abroad,
/// named, and each year's busiest places, worked out once here rather than on every scrubbed frame.
struct FeedPlaces: Sendable, Equatable {
    let months: [String: [PlaceTally]]
    let trips: [String: String]
    /// Year to its two busiest places, for the rail's year lens.
    let years: [Int: String]

    init(months: [String: [PlaceTally]], trips: [String: String]) {
        self.months = months; self.trips = trips
        years = MonthPlaces.years(months)
    }

    init(counts: [MonthPlaceCount]) {
        self.init(months: MonthPlaces.byMonth(counts), trips: MonthPlaces.trips(counts))
    }
}

/// Names months by their places before their photos load, and finds trips for the time rail.
enum MonthPlaces {
    static func byMonth(_ counts: [MonthPlaceCount]) -> [String: [PlaceTally]] {
        var months: [String: [String: Int]] = [:]
        for entry in counts {
            guard let name = entry.name else { continue }
            months[entry.bucket, default: [:]][name, default: 0] += entry.count
        }
        return months.mapValues { ranked($0) }
    }

    static func summary(_ places: [PlaceTally]?) -> String? {
        guard let places, !places.isEmpty else { return nil }
        return places.prefix(2).map(\.name).joined(separator: " · ")
    }

    /// Each year's places, summed over its months and summarized once.
    static func years(_ months: [String: [PlaceTally]]) -> [Int: String] {
        var totals: [Int: [String: Int]] = [:]
        for (bucket, places) in months {
            guard let year = Int(bucket.prefix(4)) else { continue }
            for place in places { totals[year, default: [:]][place.name, default: 0] += place.count }
        }
        return totals.compactMapValues { summary(ranked($0)) }
    }

    static func ranked(_ totals: [String: Int]) -> [PlaceTally] {
        totals.map { PlaceTally(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// A month counts as a trip when most of its located photos are in a country other than the
    /// one the library is mostly taken in, and there are enough of them to be more than a stray.
    /// It is named by its city when one city dominates, otherwise by the country. A trip spanning
    /// neighboring months is marked once, on its busier month.
    static func trips(_ counts: [MonthPlaceCount], minimum: Int = 15) -> [String: String] {
        var countries: [String: Int] = [:]
        for entry in counts { if let country = entry.countryName { countries[country, default: 0] += entry.count } }
        guard let home = ranked(countries).first?.name else { return [:] }
        var marks: [(bucket: String, label: String, count: Int)] = []
        for (bucket, entries) in Dictionary(grouping: counts, by: \.bucket) {
            let located = entries.reduce(0) { $0 + $1.count }
            var byCountry: [String: Int] = [:]
            for entry in entries { if let country = entry.countryName { byCountry[country, default: 0] += entry.count } }
            guard let abroad = ranked(byCountry).first, abroad.name != home,
                  abroad.count >= minimum, abroad.count * 2 >= located else { continue }
            var cities: [String: Int] = [:]
            for entry in entries where entry.countryName == abroad.name {
                if let city = entry.city?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty { cities[city, default: 0] += entry.count }
            }
            let city = ranked(cities).first
            let label = city.map { $0.count * 10 >= abroad.count * 6 } == true ? city!.name : abroad.name
            marks.append((bucket, label, abroad.count))
        }
        // Buckets are "YYYY-MM-01"; neighbors with the same label are one trip.
        marks.sort { $0.bucket < $1.bucket }
        var result: [String: String] = [:]
        var index = 0
        while index < marks.count {
            var best = marks[index], next = index + 1
            while next < marks.count, marks[next].label == best.label, Self.adjacent(marks[next - 1].bucket, marks[next].bucket) {
                if marks[next].count > best.count { best = marks[next] }
                next += 1
            }
            result[best.bucket] = best.label
            index = next
        }
        return result
    }

    private static func adjacent(_ earlier: String, _ later: String) -> Bool {
        func month(_ bucket: String) -> Int? {
            let parts = bucket.prefix(7).split(separator: "-")
            guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
            return year * 12 + month
        }
        guard let a = month(earlier), let b = month(later) else { return false }
        return b - a == 1
    }
}

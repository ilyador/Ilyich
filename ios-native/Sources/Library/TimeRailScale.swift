import Foundation

struct TimeRailScale {
    private let counts: [Int]
    private let cumulativeCounts: [Int]
    private let dates: [Date?]
    private let years: [Int?]
    private let yearCounts: [Int: Int]
    let yearStartIndices: [Int]
    let totalCount: Int

    init(buckets: [TimeBucket]) {
        var counts: [Int] = []
        var cumulativeCounts = [0]
        var dates: [Date?] = []
        var years: [Int?] = []
        var yearCounts: [Int: Int] = [:]
        var yearStartIndices: [Int] = []
        var previousYear: Int?
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        for (index, bucket) in buckets.enumerated() {
            let count = max(0, bucket.count)
            let date = bucket.date
            let year = date.map { calendar.component(.year, from: $0) }
            counts.append(count)
            dates.append(date)
            years.append(year)
            cumulativeCounts.append(cumulativeCounts[index] + count)
            if let year {
                if year != previousYear { yearStartIndices.append(index) }
                previousYear = year
                yearCounts[year, default: 0] += count
            }
        }

        self.counts = counts
        self.cumulativeCounts = cumulativeCounts
        self.dates = dates
        self.years = years
        self.yearCounts = yearCounts
        self.yearStartIndices = yearStartIndices
        self.totalCount = cumulativeCounts.last ?? 0
    }

    func count(before index: Int) -> Int {
        cumulativeCounts[min(max(0, index), counts.count)]
    }

    func fraction(before index: Int) -> Double {
        guard totalCount > 0 else { return 0 }
        return Double(count(before: index)) / Double(totalCount)
    }

    func date(at index: Int) -> Date? {
        dates.indices.contains(index) ? dates[index] : nil
    }

    func year(at index: Int) -> Int? {
        years.indices.contains(index) ? years[index] : nil
    }

    func count(for year: Int) -> Int { yearCounts[year, default: 0] }

    func position(at fraction: Double) -> (index: Int, item: Int)? {
        guard totalCount > 0, !counts.isEmpty else { return nil }
        let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
        let target = min(totalCount - 1, Int(clamped * Double(totalCount)))

        var lower = 0
        var upper = counts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if cumulativeCounts[middle + 1] <= target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < counts.count else { return nil }
        return (lower, target - cumulativeCounts[lower])
    }
}

import Foundation

/// A calendar month of the library, as the server's time buckets name it.
struct MonthKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int

    init?(year: Int, month: Int) {
        guard (1...9999).contains(year), (1...12).contains(month) else { return nil }
        self.year = year; self.month = month
    }

    /// Reads a time bucket ID, the first of its month. The index writes YYYY-MM-01; the server
    /// may add a time, which is read in UTC, as the time rail reads it.
    init?(bucketID: String) {
        let text = Array(bucketID.utf8)
        func number(_ range: Range<Int>) -> Int? {
            guard text[range].allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
            return text[range].reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        }
        guard text.count >= 10, let year = number(0..<4), text[4] == UInt8(ascii: "-"), let month = number(5..<7),
              text[7] == UInt8(ascii: "-"), number(8..<10) == 1 else { return nil }
        // A date alone, or midnight in UTC as the server writes its buckets, is in the month the
        // date names: no date parsing, which costs a format style and a calendar per bucket.
        if text.count == 10 || Self.midnightUTC.contains(where: { $0.elementsEqual(text[10...]) }) {
            self.init(year: year, month: month); return
        }
        guard text[10] == UInt8(ascii: "T") || text[10] == UInt8(ascii: " "), let instant = APIDate.parse(bucketID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month], from: instant)
        guard let utcYear = parts.year, let utcMonth = parts.month else { return nil }
        self.init(year: utcYear, month: utcMonth)
    }

    /// The times after YYYY-MM-01 that APIDate reads as midnight UTC.
    private static let midnightUTC: [[UInt8]] = ["T00:00:00Z", "T00:00:00.000Z", "T00:00:00", " 00:00:00"].map { Array($0.utf8) }

    /// YYYY-MM-01.
    var bucketID: String { String(format: "%04d-%02d-01", year, month) }
    var description: String { bucketID }

    static func < (a: MonthKey, b: MonthKey) -> Bool { (a.year, a.month) < (b.year, b.month) }
}

/// A PHAsset's modificationDate, kept bit for bit. Two revisions are equal only when their bits
/// are, which is what backup confirmation and cleanup compare.
struct AssetRevision: Hashable, Sendable {
    /// Seconds since 2001, as Date stores them.
    let referenceSeconds: Double

    init(referenceSeconds: Double) { self.referenceSeconds = referenceSeconds }
    init(_ date: Date) { referenceSeconds = date.timeIntervalSinceReferenceDate }

    var date: Date { Date(timeIntervalSinceReferenceDate: referenceSeconds) }

    static func == (a: AssetRevision, b: AssetRevision) -> Bool { a.referenceSeconds.bitPattern == b.referenceSeconds.bitPattern }
    func hash(into hasher: inout Hasher) { hasher.combine(referenceSeconds.bitPattern) }
}

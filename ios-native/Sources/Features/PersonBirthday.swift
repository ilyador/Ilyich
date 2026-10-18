import Foundation

/// A birthday is a civil date, not a UTC instant. Build it in the display time
/// zone so opening and saving the picker cannot move it to the preceding day.
enum PersonBirthday {
    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
    static func parse(_ value: String, timeZone: TimeZone = .current) -> Date? {
        let date = String(value.prefix(10))
        let parts = date.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), year > 0 else { return nil }
        let calendar = calendar(timeZone: timeZone)
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let result = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: result)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return result
    }
    static func encode(_ date: Date, timeZone: TimeZone = .current) -> String {
        let parts = calendar(timeZone: timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
    static func age(_ birthDate: Date, at reference: Date = Date(), timeZone: TimeZone = .current) -> String? {
        let calendar = calendar(timeZone: timeZone)
        let birth = calendar.dateComponents([.year, .month, .day], from: birthDate)
        let now = calendar.dateComponents([.year, .month, .day], from: reference)
        guard let by = birth.year, let bm = birth.month, let bd = birth.day,
              let ny = now.year, let nm = now.month, let nd = now.day else { return nil }
        let months = (ny - by) * 12 + nm - bm - (nd < bd ? 1 : 0)
        guard months >= 0 else { return nil }
        if months < 12 { return "\(months) \(months == 1 ? "month" : "months") old" }
        if months > 12 && months < 24 { return "1 year, \(months - 12) \(months == 13 ? "month" : "months") old" }
        let years = months / 12
        return "\(years) \(years == 1 ? "year" : "years") old"
    }
    static func label(_ value: String, at reference: Date = Date()) -> String? {
        guard let date = parse(value) else { return nil }
        let formatter = DateFormatter(); formatter.calendar = calendar(); formatter.dateStyle = .medium
        let birthday = formatter.string(from: date)
        return age(date, at: reference).map { birthday + " · " + $0 } ?? birthday
    }
}

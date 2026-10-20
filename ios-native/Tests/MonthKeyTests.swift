import XCTest
@testable import Ilyich

final class MonthKeyTests: XCTestCase {
    func testReadsTheIndexAndServerBucketForms() {
        XCTAssertEqual(MonthKey(bucketID: "2026-02-01"), MonthKey(year: 2026, month: 2))
        XCTAssertEqual(MonthKey(bucketID: "2024-01-01T00:00:00Z"), MonthKey(year: 2024, month: 1))
        XCTAssertEqual(MonthKey(bucketID: "2024-01-01T00:00:00.000Z"), MonthKey(year: 2024, month: 1))
        XCTAssertEqual(MonthKey(bucketID: "2024-12-01 00:00:00"), MonthKey(year: 2024, month: 12), "A time without a zone is UTC.")
        XCTAssertEqual(MonthKey(bucketID: "2024-01-01T00:30:00+02:00"), MonthKey(year: 2023, month: 12), "In UTC, as the time rail reads it.")
    }

    func testRejectsAnythingElse() {
        let texts = ["", "2024", "2024-01", "2024-1-01", "2024-01-1", "2024-13-01", "2024-00-01", "0000-01-01", "2024-01-15", "2024-01-31",
                     "abcd-01-01", "2024/01/01", "2024-01-01X", "2024-01-01Tlater", " 2024-01-01", "\u{FF12}024-01-01"]
        for text in texts { XCTAssertNil(MonthKey(bucketID: text), text) }
        XCTAssertNil(MonthKey(year: 2024, month: 13))
        XCTAssertNil(MonthKey(year: 2024, month: 0))
        XCTAssertNil(MonthKey(year: 0, month: 1))
    }

    func testBucketIDRoundTripsAndMonthsSortByTime() throws {
        let early = try XCTUnwrap(MonthKey(year: 987, month: 3))
        XCTAssertEqual(early.bucketID, "0987-03-01")
        XCTAssertEqual(MonthKey(bucketID: early.bucketID), early)
        let months = ["2025-01-01", "2024-12-01", "2024-02-01", "2025-10-01"].compactMap { MonthKey(bucketID: $0) }
        XCTAssertEqual(months.sorted().map(\.bucketID), ["2024-02-01", "2024-12-01", "2025-01-01", "2025-10-01"])
        XCTAssertLessThan(try XCTUnwrap(MonthKey(year: 2024, month: 12)), try XCTUnwrap(MonthKey(year: 2025, month: 1)))
        // A phone photo's month, as the merged timeline names it, is the same month.
        let date = Date(timeIntervalSinceReferenceDate: 782_481_234.567_891)
        XCTAssertEqual(MonthKey(bucketID: MergedTimeline.monthKey(date) + "-01"), MonthKey(year: 2025, month: 10))
    }
}

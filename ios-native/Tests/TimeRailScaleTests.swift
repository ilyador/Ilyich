import XCTest
@testable import Ilyich

final class TimeRailScaleTests: XCTestCase {
    func testFractionsAndPositionsUseCumulativeCountsAndSkipEmptyBuckets() {
        let scale = TimeRailScale(buckets: [
            .init(timeBucket: "2024-01-01T00:00:00Z", count: 3),
            .init(timeBucket: "2024-02-01T00:00:00Z", count: 0),
            .init(timeBucket: "2024-03-01T00:00:00Z", count: 2),
            .init(timeBucket: "2024-04-01T00:00:00Z", count: 5),
        ])

        XCTAssertEqual(scale.totalCount, 10)
        XCTAssertEqual(scale.fraction(before: 0), 0)
        XCTAssertEqual(scale.fraction(before: 1), 0.3, accuracy: 0.0001)
        XCTAssertEqual(scale.fraction(before: 2), 0.3, accuracy: 0.0001)
        XCTAssertEqual(scale.fraction(before: 3), 0.5, accuracy: 0.0001)
        XCTAssertEqual(scale.fraction(before: 4), 1)

        XCTAssertEqual(scale.position(at: 0)?.index, 0)
        XCTAssertEqual(scale.position(at: 0)?.item, 0)
        XCTAssertEqual(scale.position(at: 0.29)?.index, 0)
        XCTAssertEqual(scale.position(at: 0.29)?.item, 2)
        XCTAssertEqual(scale.position(at: 0.3)?.index, 2, "The empty bucket must be skipped at the boundary.")
        XCTAssertEqual(scale.position(at: 0.3)?.item, 0)
        XCTAssertEqual(scale.position(at: 0.49)?.index, 2)
        XCTAssertEqual(scale.position(at: 0.49)?.item, 1)
        XCTAssertEqual(scale.position(at: 1)?.index, 3)
        XCTAssertEqual(scale.position(at: 1)?.item, 4)
        XCTAssertEqual(scale.position(at: -1)?.index, 0)
        XCTAssertEqual(scale.position(at: 2)?.index, 3)
    }

    func testYearTotalsAndBoundariesUseUTCAndAllBuckets() {
        let scale = TimeRailScale(buckets: [
            .init(timeBucket: "2023-12-01T00:00:00Z", count: 3),
            .init(timeBucket: "2024-01-01T00:30:00+02:00", count: 2), // Still 2023 in UTC.
            .init(timeBucket: "2024-01-01T00:00:00Z", count: 0),
            .init(timeBucket: "2024-06-01T00:00:00Z", count: 7),
            .init(timeBucket: "2025-01-01T00:00:00Z", count: 4),
        ])

        XCTAssertEqual(scale.yearStartIndices, [0, 2, 4])
        XCTAssertEqual(scale.year(at: 0), 2023)
        XCTAssertEqual(scale.year(at: 1), 2023)
        XCTAssertEqual(scale.year(at: 2), 2024)
        XCTAssertEqual(scale.year(at: 4), 2025)
        XCTAssertEqual(scale.count(for: 2023), 5)
        XCTAssertEqual(scale.count(for: 2024), 7)
        XCTAssertEqual(scale.count(for: 2025), 4)
        XCTAssertEqual(scale.count(for: 2026), 0)
    }

    func testEmptyAndAllZeroScalesHaveNoPosition() {
        XCTAssertNil(TimeRailScale(buckets: []).position(at: 0.5))
        let scale = TimeRailScale(buckets: [.init(timeBucket: "2024-01-01T00:00:00Z", count: 0)])
        XCTAssertEqual(scale.totalCount, 0)
        XCTAssertNil(scale.position(at: 0.5))
        XCTAssertEqual(scale.fraction(before: 1), 0)
    }
}

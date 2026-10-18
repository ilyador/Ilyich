import XCTest
@testable import Ilyich

final class PersonBirthdayTests: XCTestCase {
    func testCivilDatesRoundTripAcrossTimeZonesAndLeapDay() throws {
        for identifier in ["Pacific/Honolulu", "America/Los_Angeles", "Europe/Lisbon", "Pacific/Kiritimati"] {
            let zone = try XCTUnwrap(TimeZone(identifier: identifier))
            for value in ["2000-02-29", "2025-03-09", "2025-11-02"] {
                let date = try XCTUnwrap(PersonBirthday.parse(value, timeZone: zone))
                XCTAssertEqual(PersonBirthday.encode(date, timeZone: zone), value)
            }
        }
        XCTAssertNil(PersonBirthday.parse("2025-02-29"))
        XCTAssertNil(PersonBirthday.parse("2024-13-01"))
    }
    func testAgeAtBirthdayBoundaryAndInfantMonths() throws {
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let birth = try XCTUnwrap(PersonBirthday.parse("2024-03-20", timeZone: zone))
        func age(_ date: String) throws -> String? {
            PersonBirthday.age(birth, at: try XCTUnwrap(PersonBirthday.parse(date, timeZone: zone)), timeZone: zone)
        }
        XCTAssertNil(try age("2024-03-19"))
        XCTAssertEqual(try age("2024-03-20"), "0 months old")
        XCTAssertEqual(try age("2024-04-20"), "1 month old")
        XCTAssertEqual(try age("2025-03-19"), "11 months old")
        XCTAssertEqual(try age("2025-03-20"), "1 year old")
        XCTAssertEqual(try age("2025-04-20"), "1 year, 1 month old")
        XCTAssertEqual(try age("2026-03-20"), "2 years old")
    }
}

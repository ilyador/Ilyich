import XCTest
@testable import Ilyich

final class MonthPlacesTests: XCTestCase {
    private func place(_ bucket: String, _ city: String?, _ country: String?, _ count: Int) -> MonthPlaceCount {
        MonthPlaceCount(bucket: bucket, city: city, country: country, count: count)
    }

    func testMonthsAreNamedByTheirBusiestPlaces() {
        let places = MonthPlaces.byMonth([
            place("2025-07-01", "Lisbon", "Portugal", 40), place("2025-07-01", "Lagos", "Portugal", 25),
            place("2025-07-01", "Faro", "Portugal", 3), place("2025-07-01", nil, nil, 9),
        ])
        XCTAssertEqual(MonthPlaces.summary(places["2025-07-01"]), "Lisbon · Lagos")
        XCTAssertNil(MonthPlaces.summary(places["2025-06-01"]))
    }

    func testTripsAreMonthsMostlyAbroadNamedByTheirCityOrCountry() {
        var counts: [MonthPlaceCount] = []
        for month in 1...12 { counts.append(place(String(format: "2024-%02d-01", month), "Amsterdam", "Netherlands", 120)) }
        counts += [
            // Kyoto dominates its trip, so the trip carries the city's name.
            place("2024-10-01", "Kyoto", "Japan", 300), place("2024-10-01", "Osaka", "Japan", 40),
            // Norway spreads over many places, so it carries the country's name.
            place("2024-08-01", "Bergen", "Norway", 60), place("2024-08-01", "Oslo", "Norway", 50), place("2024-08-01", "Tromsø", "Norway", 45),
            // A weekend in Antwerp is too small a share of the month to be a trip.
            place("2024-05-01", "Antwerp", "Belgium", 30),
            // A trip over a month boundary is marked once, on its busier month.
            place("2024-03-01", "Reykjavík", "Iceland", 200), place("2024-04-01", "Reykjavík", "Iceland", 500),
            // Too few photos abroad are not a trip.
            place("2023-01-01", "Paris", "France", 6),
        ]
        let trips = MonthPlaces.trips(counts)
        XCTAssertEqual(trips["2024-10-01"], "Kyoto")
        XCTAssertEqual(trips["2024-08-01"], "Norway")
        XCTAssertNil(trips["2024-05-01"])
        XCTAssertEqual(trips["2024-04-01"], "Reykjavík")
        XCTAssertNil(trips["2024-03-01"])
        XCTAssertNil(trips["2023-01-01"])
        XCTAssertNil(trips["2024-01-01"], "Months at home are never trips.")
    }
}

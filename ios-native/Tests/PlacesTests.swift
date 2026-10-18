import Foundation
import XCTest
@testable import Ilyich

final class PlacesTests: XCTestCase {
    func testPlaceCenterStaysAtDateLineAndExcludesInvalidCoordinates() {
        let markers = [
            MapMarker(id: "a", lat: 20, lon: 179.5, city: "Island", state: nil, country: "Ocean"),
            MapMarker(id: "b", lat: 22, lon: -179.5, city: "Island", state: nil, country: "Ocean"),
            MapMarker(id: "invalid", lat: .nan, lon: 0, city: nil, state: nil, country: nil)
        ]
        let places = PlaceCollection.group(markers)
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.assetIDs, ["a", "b"])
        XCTAssertEqual(places.first?.latitude ?? 0, 21, accuracy: 0.001)
        XCTAssertEqual(abs(places.first?.longitude ?? 0), 180, accuracy: 0.001)
    }

    func testMatchingCityNamesInDifferentCountriesRemainSeparate() {
        let places = PlaceCollection.group([
            MapMarker(id: "a", lat: 10, lon: 10, city: "Town", state: nil, country: "North"),
            MapMarker(id: "b", lat: 30, lon: 30, city: "Town", state: nil, country: "South")
        ])
        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(Set(places.compactMap(\.country)), ["North", "South"])
    }

    func testEmptyAndUnlocatedLibrary() {
        XCTAssertTrue(PlaceCollection.group([]).isEmpty)
        XCTAssertTrue(PlaceCollection.group([MapMarker(id: "a", lat: 100, lon: 0, city: nil, state: nil, country: nil)]).isEmpty)
    }
}

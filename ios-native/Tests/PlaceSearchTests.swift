import Foundation
import XCTest
@testable import Ilyich

final class PlaceSearchTests: XCTestCase {
    static let markers = PlacesTests.porto + [
        MapMarker(id: "l1", lat: 38.7139, lon: -9.1441, city: "Bairro Alto", state: "Lisbon", country: "Portugal"),
        MapMarker(id: "l2", lat: 38.7120, lon: -9.1450, city: "Bairro Alto", state: "Lisbon", country: "Portugal"),
        MapMarker(id: "l3", lat: 38.7167, lon: -9.1300, city: "Graça", state: "Lisbon", country: "Portugal"),
        MapMarker(id: "b1", lat: 51.3811, lon: -2.3590, city: "Bath", state: "England", country: "United Kingdom"),
    ]

    static var hierarchy: PlaceHierarchy {
        var cities = PlacesTests.portoCities
        cities["Bairro Alto"] = "Lisbon"; cities["Graça"] = "Lisbon"; cities["Bath"] = "Bath"
        var localities = PlacesTests.localities(markers, cities: cities)
        let bath = PlaceUnit.group(markers).units.first { $0.name == "Bath" }!
        localities.units[bath.key] = PlaceLocality(city: "Bath", countryCode: "GB")
        return PlaceHierarchy.build(markers, localities: localities)
    }

    func testACityNamedInASearchIsTheWholeCity() {
        let reading = PlaceSearch(hierarchy: Self.hierarchy).read("me in Porto")
        XCTAssertEqual(reading?.places.map(\.title), ["Porto"])
        XCTAssertEqual(reading?.places.first?.level, .city, "The city, not the region of the same name")
        XCTAssertEqual(reading?.membership?.assetIDs, ["g1", "m1", "m2", "p1", "p2", "p3"])
        XCTAssertEqual(reading?.remainder, "me")
        XCTAssertEqual(reading?.title, "Porto")
    }

    func testANeighborhoodAndItsCityAreBothFound() {
        let hierarchy = Self.hierarchy
        XCTAssertEqual(PlaceSearch(hierarchy: hierarchy).read("photos from Bairro Alto")?.membership?.assetIDs, ["l1", "l2"])
        XCTAssertEqual(PlaceSearch(hierarchy: hierarchy).read("Lisbon")?.membership?.assetIDs, ["l1", "l2", "l3"])
        XCTAssertEqual(PlaceSearch(hierarchy: hierarchy).read("Lisbon")?.remainder, "")
        XCTAssertNil(PlaceSearch(hierarchy: hierarchy).read("graca at night"), "Nothing asked for the place: the text stays whole for the server")
        XCTAssertEqual(PlaceSearch(hierarchy: hierarchy).read("night at graca")?.places.map(\.title), ["Graça"])
        XCTAssertEqual(PlaceSearch(hierarchy: hierarchy).read("night at graca")?.remainder, "night")
    }

    func testCountriesAndContinentsAreNamedToo() {
        let reading = PlaceSearch(hierarchy: Self.hierarchy).read("beach in \(Locale.current.localizedString(forRegionCode: "PT")!)")
        XCTAssertEqual(reading?.places.first?.level, .country)
        XCTAssertEqual(reading?.membership?.assetIDs.count, 10)
        XCTAssertEqual(reading?.remainder, "beach")
        XCTAssertEqual(PlaceSearch(hierarchy: Self.hierarchy).read("Europe")?.membership?.assetIDs.count, 11)
    }

    func testOrdinaryWordsThatAreAlsoPlacesNeedToBeAskedFor() {
        let search = PlaceSearch(hierarchy: Self.hierarchy)
        XCTAssertNil(search.read("hot bath"), "A bath that is a word, not a place")
        XCTAssertEqual(search.read("bath")?.places.map(\.title), ["Bath"], "Alone, the name is the place")
        XCTAssertEqual(search.read("in Bath")?.places.map(\.title), ["Bath"])
        XCTAssertEqual(search.read("photos of Bath")?.places.map(\.title), ["Bath"], "Filler words ask for nothing else")
    }

    func testPlacesLeftOutStayForTheServer() {
        let search = PlaceSearch(hierarchy: Self.hierarchy)
        XCTAssertNil(search.read("outside Porto"))
        XCTAssertNil(search.read("not in Porto"))
        XCTAssertNil(search.read("sunset"))
        XCTAssertNil(search.read(""))
    }

    func testTwoPlacesMakeOneFilterOfBoth() {
        let reading = PlaceSearch(hierarchy: Self.hierarchy).read("Lisbon or Porto")
        XCTAssertEqual(reading?.places.map(\.title), ["Porto", "Lisbon"], "Biggest first")
        XCTAssertEqual(reading?.title, "Porto · Lisbon")
        XCTAssertEqual(reading?.membership?.assetIDs.count, 9)
        XCTAssertEqual(reading?.remainder, "")
    }

    func testTheRemainderKeepsTheTypedWords() {
        let reading = PlaceSearch(hierarchy: Self.hierarchy).read("Me and Maya's dog in Porto in 2024")
        XCTAssertEqual(reading?.remainder, "Me and Maya's dog in 2024")
    }
}

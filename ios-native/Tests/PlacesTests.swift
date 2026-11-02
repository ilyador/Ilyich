import Foundation
import XCTest
@testable import Ilyich

final class PlacesTests: XCTestCase {
    /// Porto as the server names it: the city's own name and two of its neighborhoods, which Apple
    /// Maps puts in Porto, and Vila Nova de Gaia across the river, a city of its own.
    static let porto = [
        MapMarker(id: "p1", lat: 41.1496, lon: -8.6110, city: "Porto", state: "Porto", country: "Portugal"),
        MapMarker(id: "p2", lat: 41.1500, lon: -8.6120, city: "Porto", state: "Porto", country: "Portugal"),
        MapMarker(id: "p3", lat: 41.1490, lon: -8.6100, city: "Porto", state: "Porto", country: "Portugal"),
        MapMarker(id: "m1", lat: 41.1482, lon: -8.6327, city: "Massarelos", state: "Porto", country: "Portugal"),
        MapMarker(id: "m2", lat: 41.1480, lon: -8.6330, city: "Massarelos", state: "Porto", country: "Portugal"),
        MapMarker(id: "g1", lat: 41.1545, lon: -8.5889, city: "Godim", state: "Porto", country: "Portugal"),
        MapMarker(id: "v1", lat: 41.1240, lon: -8.6124, city: "Vila Nova de Gaia", state: "Porto", country: "Portugal"),
    ]

    /// Localities as Apple Maps would answer for each unit: the city each server name lies in.
    static func localities(_ markers: [MapMarker], cities: [String: String], code: String = "PT") -> PlaceLocalities {
        var localities = PlaceLocalities(language: "en")
        for unit in PlaceUnit.group(markers).units {
            localities.units[unit.key] = PlaceLocality(city: cities[unit.name ?? ""], countryCode: code)
        }
        return localities
    }

    static let portoCities = ["Porto": "Porto", "Massarelos": "Porto", "Godim": "Porto", "Vila Nova de Gaia": "Vila Nova de Gaia"]

    func testNeighborhoodsNamedByTheServerAreOneCity() {
        let hierarchy = PlaceHierarchy.build(Self.porto, localities: Self.localities(Self.porto, cities: Self.portoCities))
        let porto = hierarchy.places(named: "Porto").first { $0.level == .city }
        XCTAssertEqual(porto?.count, 6)
        XCTAssertEqual(porto?.assetIDs, ["g1", "m1", "m2", "p1", "p2", "p3"])
        XCTAssertEqual(hierarchy.children(of: porto!).map(\.title), ["Porto", "Massarelos", "Godim"])
        XCTAssertEqual(hierarchy.children(of: porto!).map(\.level), [.neighborhood, .neighborhood, .neighborhood])
        let gaia = hierarchy.places(named: "Vila Nova de Gaia").first
        XCTAssertEqual(gaia?.level, .city)
        XCTAssertEqual(gaia?.count, 1)
        XCTAssertTrue(gaia!.childIDs.isEmpty, "A city of one name has no parts")
        XCTAssertEqual(hierarchy.citiesByServerName["Portugal|Massarelos"], "Porto")
    }

    func testPlacesNestFromContinentToNeighborhood() {
        let hierarchy = PlaceHierarchy.build(Self.porto, localities: Self.localities(Self.porto, cities: Self.portoCities))
        let massarelos = hierarchy.leaf(of: "m1")
        XCTAssertEqual(massarelos?.title, "Massarelos")
        XCTAssertEqual(hierarchy.lineage(of: massarelos!.id).map(\.level), [.neighborhood, .city, .region, .country, .continent])
        XCTAssertEqual(hierarchy.lineage(of: massarelos!.id).map(\.title), ["Massarelos", "Porto", "Porto", Locale.current.localizedString(forRegionCode: "PT")!, "Europe"])
        XCTAssertEqual(hierarchy.roots.compactMap { hierarchy[$0]?.title }, ["Europe"])
        XCTAssertEqual(hierarchy[hierarchy.roots[0]]?.count, 7)
        XCTAssertTrue(hierarchy.related(massarelos!.id, hierarchy.roots[0]))
        XCTAssertFalse(hierarchy.related(massarelos!.id, hierarchy.places(named: "Vila Nova de Gaia")[0].id))
    }

    func testAPlaceStandsWhereItsBiggestPartStands() {
        let hierarchy = PlaceHierarchy.build(Self.porto, localities: Self.localities(Self.porto, cities: Self.portoCities))
        let porto = hierarchy.places(named: "Porto").first { $0.level == .city }!
        let own = hierarchy.children(of: porto)[0]
        XCTAssertEqual(porto.coverID, own.coverID)
        XCTAssertEqual(porto.latitude, own.latitude); XCTAssertEqual(porto.longitude, own.longitude)
        XCTAssertTrue(Self.porto.contains { $0.id == porto.coverID && $0.lat == porto.latitude }, "It stands at one of its photos")
        let country = hierarchy.lineage(of: porto.id).first { $0.level == .country }!
        XCTAssertEqual(country.coverID, porto.coverID, "The country stands where its biggest city stands")
        XCTAssertGreaterThan(porto.split, 0)
        XCTAssertGreaterThan(country.split, porto.split, "Cities lie farther apart than neighborhoods")
    }

    func testTownsOfOneNameFarApartAreDifferentTowns() {
        let markers = [
            MapMarker(id: "a", lat: 41.1545, lon: -8.5889, city: "Godim", state: "Porto", country: "Portugal"),
            MapMarker(id: "b", lat: 41.1710, lon: -7.8030, city: "Godim", state: "Vila Real", country: "Portugal"),
        ]
        let hierarchy = PlaceHierarchy.build(markers, localities: Self.localities(markers, cities: ["Godim": "Godim"]))
        let towns = hierarchy.places(named: "Godim").filter { $0.level == .city }
        XCTAssertEqual(towns.count, 2)
        XCTAssertEqual(Set(towns.map(\.regionName)), ["Porto", "Vila Real"])
    }

    func testWithoutLocalitiesTheServersNamesStand() {
        let hierarchy = PlaceHierarchy.build(Self.porto, localities: PlaceLocalities(language: "en"))
        XCTAssertEqual(hierarchy.cities.map(\.title), ["Porto", "Massarelos", "Godim", "Vila Nova de Gaia"])
        XCTAssertEqual(hierarchy.roots.compactMap { hierarchy[$0] }.map(\.level), [.country], "No continent until the country's code is known")
        XCTAssertEqual(hierarchy[hierarchy.roots[0]]?.title, "Portugal")
    }

    func testACountryNamedByTheServerTakesTheCodeOfItsOtherUnits() {
        var localities = Self.localities(Self.porto, cities: Self.portoCities)
        let gaia = PlaceUnit.group(Self.porto).units.first { $0.name == "Vila Nova de Gaia" }!
        localities.units[gaia.key] = nil
        let hierarchy = PlaceHierarchy.build(Self.porto, localities: localities)
        XCTAssertEqual(hierarchy.roots.compactMap { hierarchy[$0]?.title }, ["Europe"])
        XCTAssertEqual(hierarchy.lineage(of: hierarchy.leaf(of: "v1")!.id).map(\.level), [.city, .region, .country, .continent])
    }

    func testNarrowingKeepsEveryIDAndDropsEmptyPlaces() {
        let hierarchy = PlaceHierarchy.build(Self.porto, localities: Self.localities(Self.porto, cities: Self.portoCities))
        let narrowed = hierarchy.narrowed(to: ["m1", "g1"])
        let porto = hierarchy.places(named: "Porto").first { $0.level == .city }!
        XCTAssertEqual(narrowed[porto.id]?.count, 2)
        XCTAssertEqual(narrowed[porto.id]?.assetIDs, ["g1", "m1"])
        XCTAssertNil(narrowed.places(named: "Vila Nova de Gaia").first)
        XCTAssertEqual(narrowed.children(of: narrowed[porto.id]!).map(\.title), ["Godim", "Massarelos"], "Equal counts, then by name")
        XCTAssertNotEqual(narrowed.identity, hierarchy.identity)
        XCTAssertEqual(narrowed.membership(of: narrowed[porto.id]!).placeID, hierarchy.membership(of: porto).placeID)
    }

    func testANameSpreadOverTownsIsLookedUpInEach() {
        let markers = [
            MapMarker(id: "a", lat: 41.15, lon: -8.61, city: "Porto", state: "Porto", country: "Portugal"),
            MapMarker(id: "b", lat: 41.15, lon: -8.612, city: "Porto", state: "Porto", country: "Portugal"),
            MapMarker(id: "c", lat: 41.40, lon: -8.61, city: "Porto", state: "Porto", country: "Portugal"),
        ]
        let units = PlaceUnit.group(markers).units
        XCTAssertEqual(units.count, 2, "Photos 28 km apart under one name make two units")
        XCTAssertEqual(units.map(\.count).sorted(), [1, 2])
        var localities = PlaceLocalities(language: "en")
        for unit in units { localities.units[unit.key] = PlaceLocality(city: unit.count == 2 ? "Porto" : "Barcelos", countryCode: "PT") }
        let hierarchy = PlaceHierarchy.build(markers, localities: localities)
        XCTAssertEqual(hierarchy.cities.map(\.title), ["Porto", "Barcelos"])
    }

    func testAPlaceAcrossTheDateLineStandsAtAPhotoAndInvalidCoordinatesAreLeftOut() {
        let markers = [
            MapMarker(id: "a", lat: 20, lon: 179.995, city: "Island", state: nil, country: "Ocean"),
            MapMarker(id: "b", lat: 20, lon: -179.995, city: "Island", state: nil, country: "Ocean"),
            MapMarker(id: "invalid", lat: .nan, lon: 0, city: nil, state: nil, country: nil),
        ]
        let hierarchy = PlaceHierarchy.build(markers, localities: PlaceLocalities(language: "en"))
        let island = hierarchy.places(named: "Island")
        XCTAssertEqual(island.count, 1)
        XCTAssertEqual(island[0].assetIDs, ["a", "b"])
        XCTAssertEqual(abs(island[0].longitude), 179.995, accuracy: 0.001, "It stands at one of its photos, not at Greenwich")
        XCTAssertEqual(hierarchy.photos.count, 2)
        let apart = PlaceHierarchy.build([markers[0], MapMarker(id: "c", lat: 22, lon: -179.5, city: "Island", state: nil, country: "Ocean")],
                                         localities: PlaceLocalities(language: "en"))
        XCTAssertEqual(apart.places(named: "Island").count, 2, "Two photos 240 km apart under one name are two towns")
    }

    func testMatchingCityNamesInDifferentCountriesRemainSeparate() {
        let markers = [
            MapMarker(id: "a", lat: 10, lon: 10, city: "Town", state: nil, country: "North"),
            MapMarker(id: "b", lat: 30, lon: 30, city: "Town", state: nil, country: "South"),
        ]
        let hierarchy = PlaceHierarchy.build(markers, localities: PlaceLocalities(language: "en"))
        XCTAssertEqual(hierarchy.places(named: "Town").count, 2)
        XCTAssertEqual(Set(hierarchy.cities.compactMap(\.countryName)), ["North", "South"])
    }

    func testEmptyAndUnlocatedLibrary() {
        XCTAssertTrue(PlaceHierarchy.build([], localities: PlaceLocalities(language: "en")).roots.isEmpty)
        let unlocated = PlaceHierarchy.build([MapMarker(id: "a", lat: 100, lon: 0, city: nil, state: nil, country: nil)], localities: PlaceLocalities(language: "en"))
        XCTAssertTrue(unlocated.roots.isEmpty)
        XCTAssertTrue(PlaceHierarchy.empty.cities.isEmpty)
    }

    func testContinentsComeFromTheCountryTable() {
        XCTAssertEqual(Continent.of(countryCode: "PT"), .europe)
        XCTAssertEqual(Continent.of(countryCode: "il"), .asia)
        XCTAssertEqual(Continent.of(countryCode: "US")?.name, "North America")
        XCTAssertNil(Continent.of(countryCode: "ZZ"))
    }
}

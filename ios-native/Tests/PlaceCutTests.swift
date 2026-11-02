import CoreGraphics
import Foundation
import XCTest
@testable import Ilyich

final class PlaceCutTests: XCTestCase {
    /// Portugal: Lisbon with two neighborhoods, and Porto 270 km north.
    static let markers = [
        MapMarker(id: "l1", lat: 38.7139, lon: -9.1441, city: "Bairro Alto", state: "Lisbon", country: "Portugal"),
        MapMarker(id: "l2", lat: 38.7120, lon: -9.1450, city: "Bairro Alto", state: "Lisbon", country: "Portugal"),
        MapMarker(id: "l3", lat: 38.7167, lon: -9.1300, city: "Graça", state: "Lisbon", country: "Portugal"),
        MapMarker(id: "p1", lat: 41.1496, lon: -8.6110, city: "Porto", state: "Porto", country: "Portugal"),
        MapMarker(id: "p2", lat: 41.1500, lon: -8.6120, city: "Porto", state: "Porto", country: "Portugal"),
    ]

    static var hierarchy: PlaceHierarchy {
        PlaceHierarchy.build(markers, localities: PlacesTests.localities(markers, cities: ["Bairro Alto": "Lisbon", "Graça": "Lisbon", "Porto": "Porto"]))
    }

    func testFromAfarACountryIsOnePlaceAndCloserItOpensIntoItsCities() {
        let hierarchy = Self.hierarchy
        let country = hierarchy[hierarchy.roots[0]].flatMap { hierarchy.children(of: $0).first }!
        XCTAssertEqual(country.level, .country)
        // Lisbon and Porto are 0.042 radians apart: 4 points on screen from orbit, 420 close up.
        let far = PlaceCut.shown(hierarchy, radiansPerPoint: 0.01, open: [])
        XCTAssertEqual(far.nodes.map(\.title), ["Europe"], "From orbit, the continent")
        let near = PlaceCut.shown(hierarchy, radiansPerPoint: 0.0001, open: [])
        XCTAssertEqual(Set(near.nodes.map(\.title)), ["Lisbon", "Porto"], "Cities 420 points apart show as themselves; Lisbon's neighborhoods are still too close")
        XCTAssertTrue(near.open.contains(country.id))
        let closest = PlaceCut.shown(hierarchy, radiansPerPoint: 0.000001, open: [])
        XCTAssertEqual(Set(closest.nodes.map(\.title)), ["Bairro Alto", "Graça", "Porto"])
    }

    func testAnOpenPlaceClosesALittleLaterThanItOpened() {
        let hierarchy = Self.hierarchy
        let country = hierarchy[hierarchy.roots[0]].flatMap { hierarchy.children(of: $0).first }!
        let opensAt = country.split / (PlaceCut.pinPoints * PlaceCut.opensAt)
        XCTAssertEqual(PlaceCut.shown(hierarchy, radiansPerPoint: opensAt * 1.01, open: []).nodes.count, 1)
        let opened = PlaceCut.shown(hierarchy, radiansPerPoint: opensAt * 0.99, open: [])
        XCTAssertEqual(opened.nodes.count, 2)
        XCTAssertEqual(PlaceCut.shown(hierarchy, radiansPerPoint: opensAt * 1.1, open: opened.open).nodes.count, 2, "Zooming out a little keeps it open")
        XCTAssertEqual(PlaceCut.shown(hierarchy, radiansPerPoint: opensAt * 1.5, open: opened.open).nodes.count, 1)
    }

    func testAPhotosOwnPlaceIsShownWhateverTheZoom() {
        let hierarchy = Self.hierarchy
        let leaf = hierarchy.leaf(of: "l3")!
        let cut = PlaceCut.shown(hierarchy, radiansPerPoint: 0.01, open: [], forced: [leaf.id])
        XCTAssertTrue(cut.nodes.contains { $0.id == leaf.id })
        XCTAssertEqual(Set(cut.nodes.map(\.title)), ["Graça", "Bairro Alto", "Porto"], "Its city opened with it; the other city shows as itself")
    }

    func testTheWholeHierarchyIsShownAtOnceWhenNothingOpens() {
        let cut = PlaceCut.shown(.empty, radiansPerPoint: 0.001, open: [])
        XCTAssertTrue(cut.nodes.isEmpty)
    }

    func testACountryOfOneCityOpensIntoItAtCityZoom() {
        let markers = [
            MapMarker(id: "a1", lat: 52.3676, lon: 4.9041, city: "Amsterdam", state: nil, country: "Netherlands"),
            MapMarker(id: "a2", lat: 52.3702, lon: 4.8952, city: "Amsterdam", state: nil, country: "Netherlands"),
        ]
        let hierarchy = PlaceHierarchy.build(markers, localities: PlaceLocalities(language: "en"))
        // Both photos lie within a kilometer, so they never stand a pin apart; the view spanning
        // less than a country opens it all the same.
        let wide = PlaceCut.shown(hierarchy, radiansPerPoint: PlaceCut.span(.country) / 800 * 1.3, open: [])
        XCTAssertEqual(wide.nodes.map(\.title), ["Netherlands"])
        let city = PlaceCut.shown(hierarchy, radiansPerPoint: PlaceCut.span(.country) / 800 * 0.8, open: [])
        XCTAssertEqual(city.nodes.map(\.title), ["Amsterdam"])
    }

    func testPinsSitOnTheirPlaceAndLabelsFindRoom() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let label = CGSize(width: 120, height: 28)
        let placed = PinPlacement.place([
            .init(id: "a", point: CGPoint(x: 200, y: 400), label: label),
            .init(id: "b", point: CGPoint(x: 300, y: 400), label: label),
            .init(id: "c", point: CGPoint(x: 230, y: 400), label: label),
        ], in: bounds, sides: [:], limit: 8)
        XCTAssertEqual(placed.map(\.id), ["a", "b"], "The third pin has no room even for its thumbnail")
        XCTAssertEqual(placed[0].side, .left, "To the right its label would cover the second pin's place")
        XCTAssertEqual(placed[1].side, .below, "Right runs off the edge and left meets the first pin")
        for pin in placed {
            let thumbnail = PinPlacement.thumbnailFrame(in: pin.frame, side: pin.side)
            let point = pin.id == "a" ? CGPoint(x: 200, y: 400) : CGPoint(x: 300, y: 400)
            XCTAssertEqual(thumbnail.midX, point.x, accuracy: 0.001); XCTAssertEqual(thumbnail.midY, point.y, accuracy: 0.001)
        }
    }

    func testALabelKeepsItsSideAndAPinNearTheEdgeDropsItsLabel() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let label = CGSize(width: 120, height: 28)
        let kept = PinPlacement.place([.init(id: "a", point: CGPoint(x: 200, y: 400), label: label)], in: bounds, sides: ["a": .above], limit: 8)
        XCTAssertEqual(kept.first?.side, .above)
        let edge = PinPlacement.place([.init(id: "e", point: CGPoint(x: 40, y: 40), label: CGSize(width: 380, height: 28))], in: bounds, sides: [:], limit: 8)
        XCTAssertEqual(edge.count, 1)
        XCTAssertNil(edge[0].side)
        XCTAssertEqual(edge[0].frame.size.width, PinPlacement.thumbnail)
        XCTAssertTrue(PinPlacement.place([.init(id: "o", point: CGPoint(x: 10, y: 10), label: label)], in: bounds, sides: [:], limit: 8).isEmpty, "Off the edge, not shown")
    }
}

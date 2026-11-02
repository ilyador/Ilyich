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

    func testCitiesShowFromAfarAndOpenIntoNeighborhoodsCloseUp() {
        let hierarchy = Self.hierarchy
        let far = PlaceCut.shown(hierarchy, radiansPerPoint: 0.01, open: [])
        XCTAssertEqual(Set(far.nodes.map(\.title)), ["Lisbon", "Porto"], "Cities, never countries or continents")
        let near = PlaceCut.shown(hierarchy, radiansPerPoint: 0.0001, open: [])
        XCTAssertEqual(Set(near.nodes.map(\.title)), ["Lisbon", "Porto"], "Lisbon's neighborhoods are still too close to tell apart")
        let closest = PlaceCut.shown(hierarchy, radiansPerPoint: 0.000001, open: [])
        XCTAssertEqual(Set(closest.nodes.map(\.title)), ["Bairro Alto", "Graça", "Porto"])
        XCTAssertTrue(closest.open.contains(hierarchy.places(named: "Lisbon").first { $0.level == .city }!.id))
    }

    func testAnOpenPlaceClosesALittleLaterThanItOpened() {
        let hierarchy = Self.hierarchy
        let lisbon = hierarchy.places(named: "Lisbon").first { $0.level == .city }!
        let opensAt = lisbon.split / (PlaceCut.pinPoints * PlaceCut.opensAt)
        // A tall view, so only the neighborhoods' distance apart decides.
        XCTAssertEqual(PlaceCut.shown(hierarchy, radiansPerPoint: opensAt * 1.01, viewPoints: 4000, open: []).nodes.count, 2)
        let opened = PlaceCut.shown(hierarchy, radiansPerPoint: opensAt * 0.99, viewPoints: 4000, open: [])
        XCTAssertEqual(opened.nodes.count, 3)
        XCTAssertEqual(PlaceCut.shown(hierarchy, radiansPerPoint: opensAt * 1.1, viewPoints: 4000, open: opened.open).nodes.count, 3, "Zooming out a little keeps it open")
        XCTAssertEqual(PlaceCut.shown(hierarchy, radiansPerPoint: opensAt * 1.5, viewPoints: 4000, open: opened.open).nodes.count, 2)
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

    func testACityOpensIntoItsNeighborhoodsOnceTheViewSpansLessThanACity() {
        let hierarchy = Self.hierarchy
        let wide = PlaceCut.shown(hierarchy, radiansPerPoint: PlaceCut.span(.city) / 800 * 1.3, open: [])
        XCTAssertEqual(Set(wide.nodes.map(\.title)), ["Lisbon", "Porto"])
        let city = PlaceCut.shown(hierarchy, radiansPerPoint: PlaceCut.span(.city) / 800 * 0.8, open: [])
        XCTAssertEqual(Set(city.nodes.map(\.title)), ["Bairro Alto", "Graça", "Porto"], "Porto has no parts and stays itself")
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

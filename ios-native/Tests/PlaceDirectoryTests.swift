import Foundation
import Synchronization
import XCTest
@testable import Ilyich

/// Answers each lookup by the city nearest the point, counting the lookups; it can be told to
/// throttle first.
private final class FakeGeocoder: PlaceGeocoder, @unchecked Sendable {
    var calls = 0
    var throttles = 0
    let cities: [(latitude: Double, longitude: Double, city: String)]
    init(cities: [(Double, Double, String)]) { self.cities = cities.map { (latitude: $0.0, longitude: $0.1, city: $0.2) } }

    @MainActor func locality(latitude: Double, longitude: Double, language: String) async throws(PlaceGeocodingFailure) -> PlaceLocality {
        calls += 1
        if throttles > 0 { throttles -= 1; throw .throttled }
        let nearest = cities.min { abs($0.latitude - latitude) + abs($0.longitude - longitude) < abs($1.latitude - latitude) + abs($1.longitude - longitude) }
        return PlaceLocality(city: nearest?.city, countryCode: "PT")
    }
}

final class PlaceDirectoryTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("PlaceDirectoryTests-\(UUID().uuidString)/places.json")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        super.tearDown()
    }

    private func directory(_ geocoder: FakeGeocoder?, markers: @escaping @Sendable (MapMarkerQuery) async throws -> [MapMarker]) -> PlaceDirectory {
        PlaceDirectory(markers: markers, geocoder: geocoder, file: file, language: "en",
                       pacing: .milliseconds(1), backoff: .milliseconds(5), settle: .milliseconds(20))
    }

    /// The first snapshot of a query's places, then each one after.
    private func snapshots(_ directory: PlaceDirectory, until done: @escaping @Sendable (PlaceHierarchy) -> Bool, timeout: Duration = .seconds(5)) async -> PlaceHierarchy? {
        let stream = await directory.places()
        return await withTaskGroup(of: PlaceHierarchy?.self) { group in
            group.addTask {
                for await snapshot in stream {
                    if case .loaded(let hierarchy) = snapshot, done(hierarchy) { return hierarchy }
                }
                return nil
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    func testPlacesAreNamedByTheServerFirstThenByTheirCity() async throws {
        let geocoder = FakeGeocoder(cities: [(41.15, -8.61, "Porto"), (41.124, -8.612, "Vila Nova de Gaia")])
        let directory = directory(geocoder) { _ in PlacesTests.porto }
        let first = await snapshots(directory, until: { _ in true })
        XCTAssertEqual(first?.cities.map(\.title), ["Porto", "Massarelos", "Godim", "Vila Nova de Gaia"])
        let resolved = await snapshots(directory, until: { $0.cities.count == 2 })
        XCTAssertEqual(resolved?.cities.map(\.title), ["Porto", "Vila Nova de Gaia"])
        XCTAssertEqual(resolved?.cities.first?.count, 6)
        XCTAssertEqual(geocoder.calls, 4, "One lookup per unit")
        await directory.shutdown()
        let kept = try JSONDecoder().decode(PlaceLocalities.self, from: Data(contentsOf: file))
        XCTAssertEqual(kept.units.count, 4)
    }

    func testLocalitiesKeptOnThePhoneAreNotLookedUpAgain() async throws {
        let geocoder = FakeGeocoder(cities: [(41.15, -8.61, "Porto"), (41.124, -8.612, "Vila Nova de Gaia")])
        let first = directory(geocoder) { _ in PlacesTests.porto }
        _ = await snapshots(first, until: { $0.cities.count == 2 })
        await first.shutdown()
        let again = FakeGeocoder(cities: [])
        let second = directory(again) { _ in PlacesTests.porto }
        let resolved = await snapshots(second, until: { _ in true })
        XCTAssertEqual(resolved?.cities.map(\.title), ["Porto", "Vila Nova de Gaia"], "Known at once, from the file")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(again.calls, 0)
        await second.shutdown()
    }

    func testAThrottledLookupIsTriedAgain() async {
        let geocoder = FakeGeocoder(cities: [(41.15, -8.61, "Porto"), (41.124, -8.612, "Vila Nova de Gaia")])
        geocoder.throttles = 2
        let directory = directory(geocoder) { _ in PlacesTests.porto }
        let resolved = await snapshots(directory, until: { $0.cities.count == 2 })
        XCTAssertNotNil(resolved)
        XCTAssertEqual(geocoder.calls, 6)
        await directory.shutdown()
    }

    func testASearchReadsThePlacesLoadingThemFirst() async {
        let directory = directory(nil) { _ in PlacesTests.porto }
        let reading = await directory.read("me in Massarelos")
        XCTAssertEqual(reading?.places.map(\.title), ["Massarelos"])
        XCTAssertEqual(reading?.remainder, "me")
        let none = await directory.read("sunset")
        XCTAssertNil(none)
        await directory.shutdown()
    }

    func testAFailedLoadIsToldAndPlacesAlreadyShownStay() async {
        let failing = Mutex(false)
        let directory = directory(nil) { _ in
            if failing.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return PlacesTests.porto
        }
        let loaded = await snapshots(directory, until: { _ in true })
        XCTAssertEqual(loaded?.cities.count, 4)
        failing.withLock { $0 = true }
        await directory.reload()
        try? await Task.sleep(for: .milliseconds(50))
        let still = await directory.hierarchy(PlaceDirectory.library)
        XCTAssertEqual(still?.cities.count, 4, "A failed reload keeps the places shown")
        await directory.shutdown()
        let fresh = self.directory(nil) { _ in throw URLError(.notConnectedToInternet) }
        let stream = await fresh.places()
        var failed = false
        for await snapshot in stream {
            if case .failed = snapshot { failed = true; break }
        }
        XCTAssertTrue(failed)
        await fresh.shutdown()
    }
}

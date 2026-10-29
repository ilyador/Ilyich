import RealityKit
import XCTest
import simd
@testable import Ilyich

final class GlobeGeometryTests: XCTestCase {
    func testNorthUpTextureMatchesGeographicMarkers() {
        XCTAssertEqual(GlobeGeometry.textureCoordinate(latitude: .pi / 2, longitude: 0), SIMD2<Float>(0.5, 1))
        XCTAssertEqual(GlobeGeometry.textureCoordinate(latitude: -.pi / 2, longitude: 0), SIMD2<Float>(0.5, 0))
        XCTAssertEqual(GlobeGeometry.textureCoordinate(latitude: 0, longitude: -.pi), SIMD2<Float>(0, 0.5))
        XCTAssertEqual(GlobeGeometry.position(latitude: 0, longitude: 0), SIMD3<Float>(0, 0, 1))
    }

    func testFocusedPlacesStayOnTheVisibleCenterRay() {
        for compact in [false, true] {
            for coordinate in [(52.3676, 4.9041), (-33.8688, 151.2093), (64.1466, -21.9426)] {
                let pitch = GlobeGeometry.focusPitch(latitude: coordinate.0, compact: compact)
                let yaw = Float(-coordinate.1 * .pi / 180)
                let rotation = simd_quatf(angle: pitch, axis: [1, 0, 0]) * simd_quatf(angle: yaw, axis: [0, 1, 0])
                let marker = rotation.act(GlobeGeometry.position(latitude: coordinate.0, longitude: coordinate.1) * GlobeGeometry.markerRadius)
                XCTAssertEqual(marker.x, 0, accuracy: 0.0001)
                XCTAssertEqual(marker.y, compact ? GlobeGeometry.compactCameraHeight : 0, accuracy: 0.0001)
                XCTAssertGreaterThan(marker.z, 0)
            }
        }
    }

    func testZoomReachesTownsWithoutEnteringEarth() {
        for compact in [false, true] {
            let ground = GlobeGeometry.groundZ(compact: compact)
            let closest = GlobeGeometry.clampedCameraDistance(0, compact: compact)
            XCTAssertEqual(closest - ground, GlobeGeometry.minimumSurfaceDistance, accuracy: 0.00001)
            let height: Float = compact ? GlobeGeometry.compactCameraHeight : 0
            XCTAssertGreaterThan((closest * closest + height * height).squareRoot(), GlobeGeometry.markerRadius)
        }
        XCTAssertLessThan(GlobeGeometry.minimumSurfaceDistance * 6371, 25, "Pinch should reach roughly 20 km above the ground.")
        XCTAssertEqual(GlobeGeometry.clampedCameraDistance(100), GlobeGeometry.maximumCameraDistance)
        XCTAssertEqual(GlobeGeometry.clampedCameraDistance(100, compact: true), 3)
        XCTAssertEqual(GlobeGeometry.clampedCameraDistance(GlobeGeometry.compactCameraDistance), GlobeGeometry.compactCameraDistance)
    }

    func testChoosingALocationKeepsTheZoom() {
        XCTAssertEqual(GlobeGeometry.focusDistance(current: 1.2, photo: false, compact: true), 1.2, "The Earth in the library keeps its zoom.")
        XCTAssertEqual(GlobeGeometry.focusDistance(current: 1.2, photo: true, compact: true), 1.2)
        XCTAssertEqual(GlobeGeometry.focusDistance(current: 1.6, photo: false, compact: false), 1.6, "Choosing a place keeps the zoom.")
        XCTAssertEqual(GlobeGeometry.focusDistance(current: 3.2, photo: true, compact: false), 2.35, "A photo's own location comes in closer.")
    }

    func testDragTracksSurfaceAcrossViewportAndZoom() {
        let ground = GlobeGeometry.groundZ(compact: false)
        let near = GlobeGeometry.dragRadiansPerPoint(cameraDistance: ground + 1, viewportHeight: 400)
        let far = GlobeGeometry.dragRadiansPerPoint(cameraDistance: ground + 2, viewportHeight: 400)
        XCTAssertEqual(far, near * 2, accuracy: 0.000001)
        XCTAssertEqual(GlobeGeometry.dragRadiansPerPoint(cameraDistance: ground + 1, viewportHeight: 800), near / 2, accuracy: 0.000001)
        XCTAssertTrue(GlobeGeometry.dragRadiansPerPoint(cameraDistance: ground + 1, viewportHeight: 0).isFinite)
        let closest = GlobeGeometry.clampedCameraDistance(0)
        XCTAssertEqual(GlobeGeometry.dragRadiansPerPoint(cameraDistance: closest, viewportHeight: 400),
                       near * GlobeGeometry.minimumSurfaceDistance, accuracy: 0.0000001,
                       "Close to the ground, a drag moves the surface as far as the finger moves.")
    }

    func testPhotoLightsMergeFromAfarAndSeparateUpClose() {
        let amsterdam = GlobeGeometry.position(latitude: 52.3676, longitude: 4.9041)
        let nearby = GlobeGeometry.position(latitude: 52.3700, longitude: 4.9200)
        let paris = GlobeGeometry.position(latitude: 48.8566, longitude: 2.3522)
        let lights = GlobePhotoLights(locations: [amsterdam, amsterdam, nearby, paris])
        for level in GlobePhotoLights.levels {
            XCTAssertEqual(lights.clusters(level: level).reduce(0) { $0 + $1.count }, 4, "Every photo counts once at every zoom.")
        }
        let far = lights.clusters(level: GlobePhotoLights.level(altitude: 1.4))
        XCTAssertEqual(far.map(\.count).sorted(), [1, 3], "From space, photos a kilometer apart share one brighter light.")
        let near = lights.clusters(level: GlobePhotoLights.level(altitude: GlobeGeometry.minimumSurfaceDistance))
        XCTAssertEqual(near.map(\.count).sorted(), [1, 1, 2], "Zoomed in, nearby spots separate.")
        XCTAssertLessThan(GlobePhotoLights.cell(level: GlobePhotoLights.levels.lowerBound) * 6371, 1, "The closest step resolves spots under a kilometer apart.")
    }

    @MainActor func testMorePhotosMakeABrighterLight() {
        XCTAssertEqual(GlobeLightMesh.step(count: 1), 0)
        XCTAssertLessThan(GlobeLightMesh.step(count: 3), GlobeLightMesh.step(count: 40))
        XCTAssertEqual(GlobeLightMesh.step(count: 100_000), GlobeLightMesh.steps - 1)
    }

    func testBundledLandDecodesOntoTheSphere() throws {
        let earth = try XCTUnwrap(GlobeLand.decode(), "The bundled Natural Earth land must decode.")
        let layers = earth.layers
        XCTAssertEqual(layers.count, 2)
        XCTAssertGreaterThan(layers[0].indices.count / 3, 200_000, "The coastline is fine enough to stay sharp up close.")
        XCTAssertEqual(layers[0].indices.count % 3, 0)
        for position in layers[0].positions.prefix(2_000) { XCTAssertEqual(simd_length(position), 1, accuracy: 0.00001) }
        XCTAssertGreaterThan(earth.roads.count, 5_000, "Major highways come with the land.")
        XCTAssertTrue(earth.roads.allSatisfy { $0.count >= 2 })
        for point in earth.roads.prefix(200).joined() { XCTAssertEqual(simd_length(point), 1, accuracy: 0.00001) }
        XCTAssertNil(GlobeLand.decode(Data("not a mesh".utf8)))
    }

    /// Build 3040030: the Earth's land, built while a finger crossed Places, stalled the first cold
    /// use of the shelves. A cold build runs off the main thread, in pieces of at most 24,000
    /// triangles, and the main thread keeps answering throughout, nowhere near a 250 ms hang. On
    /// the main thread, decoding the land alone takes about 450 ms on the simulator.
    @MainActor func testAColdBuildOfTheEarthNeverHoldsUpTheMainThread() async throws {
        let earth = try XCTUnwrap(GlobeLand.decode())
        let land = earth.layers[0]
        let pieces = GlobeLand.pieces(of: land)
        XCTAssertGreaterThan(pieces.count, 1, "The land is built in pieces.")
        XCTAssertTrue(pieces.allSatisfy { $0.indices.count <= 24_000 * 3 }, "No piece passes 24,000 triangles.")
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.indices.count }, land.indices.count, "The pieces hold every triangle.")

        // RealityKit sets itself up on the main thread the first time a process makes any mesh,
        // about a second on the simulator whatever the mesh. That is not the Earth's build, so a
        // mesh of one triangle is made first.
        let setup = MainThreadWatch()
        let ready = await Task.detached { () -> Bool in
            var descriptor = MeshDescriptor(name: "Setup")
            descriptor.positions = MeshBuffer([SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)])
            descriptor.primitives = .triangles([0, 1, 2])
            return (try? await MeshResource(from: [descriptor])) != nil
        }.value
        let setupWorst = await setup.stop()
        XCTAssertTrue(ready)

        let watch = MainThreadWatch()
        let started = ContinuousClock.now
        let meshes = await GlobeLand.Builder().prepare()
        let built = ContinuousClock.now - started
        let worst = await watch.stop()
        XCTAssertEqual(meshes?.land.count, pieces.count, "Every piece became a mesh.")
        print("EARTH COLD BUILD: \(built.formatted(.units(allowed: [.milliseconds]))), main thread at worst \(worst.formatted(.units(allowed: [.milliseconds]))); RealityKit's setup held it \(setupWorst.formatted(.units(allowed: [.milliseconds])))")
        XCTAssertLessThan(worst, .milliseconds(250), "The main thread answered within the hang threshold all through the build.")
    }

    func testOnlyRoadsTowardTheViewAreDrawn() {
        let lisbon = GlobeGeometry.position(latitude: 38.72, longitude: -9.14)
        let porto = GlobeGeometry.position(latitude: 41.15, longitude: -8.61)
        let auckland = GlobeGeometry.position(latitude: -36.85, longitude: 174.76)
        let roads = GlobeRoads([[lisbon, porto], [auckland, auckland * 0.999 + porto * 0.001]])
        let visible = roads.visible(around: lisbon, within: 0.3)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.points.first, lisbon)
    }

    func testStringsJoinEveryLightOnceAndArchAboveTheGround() {
        let places = [(38.72, -9.14), (41.15, -8.61), (40.42, -3.70), (48.86, 2.35), (52.37, 4.90)]
        let clusters = places.enumerated().map { index, place in
            GlobePhotoLights.Cluster(center: GlobeGeometry.position(latitude: place.0, longitude: place.1), count: 10 - index)
        }
        let edges = GlobeRibbon.spanningTree(clusters.map(\.center))
        XCTAssertEqual(edges.count, places.count - 1, "A tree joins every light without loops.")
        XCTAssertEqual(Set(edges.flatMap { [$0.0, $0.1] }).count, places.count)
        let arc = GlobeRibbon.arc(from: clusters[0].center, to: clusters[3].center, cell: 0.01)
        XCTAssertEqual(simd_length(arc.first!), GlobeStyle.lightRadius, accuracy: 0.0001)
        XCTAssertEqual(simd_length(arc.last!), GlobeStyle.lightRadius, accuracy: 0.0001)
        XCTAssertGreaterThan(simd_length(arc[arc.count / 2]), GlobeStyle.lightRadius + 0.01, "Strings rise off the ground.")
        let plane = simd_normalize(simd_cross(clusters[0].center, clusters[3].center))
        XCTAssertGreaterThan(abs(simd_dot(simd_normalize(arc[arc.count / 2]), plane)), 0.02, "Strings bow sideways, they are not ruled lines.")
        XCTAssertEqual(GlobeRibbon.arc(from: clusters[3].center, to: clusters[0].center, cell: 0.01).count, arc.count)
        XCTAssertEqual(GlobeRibbon.arc(from: clusters[3].center, to: clusters[0].center, cell: 0.01)[arc.count / 2], arc[arc.count / 2],
                       "A string keeps its bow whichever end it is drawn from.")
        let tokyo = GlobeGeometry.position(latitude: 35.68, longitude: 139.65)
        XCTAssertLessThanOrEqual(GlobeRibbon.arc(from: clusters[0].center, to: tokyo, cell: 0.01).map { simd_length($0) }.max() ?? 0,
                                 GlobeStyle.lightRadius + 0.0401, "Long strings stay close to the Earth instead of flying into space.")
        XCTAssertFalse(GlobeRibbon.strings(clusters, cell: 0.01).indices.isEmpty)
    }

}

/// How long, at worst, the main thread takes to run work handed to it while it is watched: a
/// task off the main thread hands it an empty job every few milliseconds and times the answer.
private final class MainThreadWatch: Sendable {
    private let watching: Task<Duration, Never>

    init() {
        watching = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            var worst = Duration.zero
            while !Task.isCancelled {
                let asked = clock.now
                await MainActor.run {}
                worst = max(worst, clock.now - asked)
                try? await Task.sleep(for: .milliseconds(4))
            }
            return worst
        }
    }

    func stop() async -> Duration {
        watching.cancel()
        return await watching.value
    }
}

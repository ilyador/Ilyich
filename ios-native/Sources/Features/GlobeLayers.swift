import CoreGraphics
import RealityKit
import simd

/// Major highways as polylines on the unit sphere, each with a bounding cap so only the roads
/// up to the horizon are drawn.
final class GlobeRoads: Sendable {
    struct Line: Sendable {
        let points: [SIMD3<Float>]
        let center: SIMD3<Float>
        /// The angle from `center` to the line's farthest point.
        let reach: Float
    }
    let lines: [Line]

    init(_ polylines: [[SIMD3<Float>]]) {
        lines = polylines.compactMap { points in
            guard points.count >= 2 else { return nil }
            let center = simd_normalize(points.reduce(SIMD3<Float>.zero, +))
            let reach = points.map { acos(min(1, max(-1, simd_dot($0, center)))) }.max() ?? 0
            return Line(points: points, center: center, reach: reach)
        }
    }

    func visible(around center: SIMD3<Float>, within angle: Float) -> [Line] {
        lines.filter { acos(min(1, max(-1, simd_dot($0.center, center)))) - $0.reach < angle }
    }
}

/// Thin glowing lines drawn as ribbons: roads lying on the land, and strings arching between
/// the places photos were taken. Built off the main thread.
enum GlobeRibbon {
    struct Geometry: Sendable {
        var positions: [SIMD3<Float>] = []
        var coordinates: [SIMD2<Float>] = []
        var indices: [UInt32] = []
    }

    /// A ribbon `half` wide on each side of a line through `points`, flat to the sphere; `u` runs
    /// across it for the soft line texture.
    static func append(_ points: [SIMD3<Float>], half: Float, to geometry: inout Geometry) {
        guard points.count >= 2 else { return }
        let base = UInt32(geometry.positions.count)
        for (index, point) in points.enumerated() {
            let previous = points[max(0, index - 1)], next = points[min(points.count - 1, index + 1)]
            let along = next - previous
            guard simd_length_squared(along) > 0 else { continue }
            let side = simd_normalize(simd_cross(simd_normalize(point), along)) * half
            geometry.positions += [point - side, point + side]
            geometry.coordinates += [[0, 0.5], [1, 0.5]]
        }
        let pairs = (UInt32(geometry.positions.count) - base) / 2
        guard pairs >= 2 else { geometry.positions.removeLast(Int(pairs) * 2); geometry.coordinates.removeLast(Int(pairs) * 2); return }
        for pair in 0..<(pairs - 1) {
            let a = base + pair * 2
            geometry.indices += [a, a + 1, a + 2, a + 1, a + 3, a + 2]
        }
    }

    static func mesh(_ geometry: Geometry, name: String) async -> MeshResource? {
        guard !geometry.indices.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffer(geometry.positions)
        descriptor.textureCoordinates = MeshBuffer(geometry.coordinates)
        descriptor.primitives = .triangles(geometry.indices)
        return try? await MeshResource(from: [descriptor])
    }

    /// Roads drawn about a point and a half wide on screen at this zoom step.
    static func roads(_ lines: [GlobeRoads.Line], cell: Float) -> Geometry {
        var geometry = Geometry()
        let radius = GlobeStyle.roadRadius
        for line in lines { append(line.points.map { $0 * radius }, half: cell * 0.055, to: &geometry) }
        return geometry
    }

    /// Strings joining every light to its nearest neighbor without loops: a minimum spanning
    /// tree, each edge a great-circle arch lifted in proportion to its length.
    static func strings(_ lights: [GlobePhotoLights.Cluster], cell: Float, limit: Int = 400) -> Geometry {
        let points = lights.sorted { $0.count > $1.count }.prefix(limit).map(\.center)
        var geometry = Geometry()
        for (from, to) in spanningTree(points) {
            append(arc(from: points[from], to: points[to], cell: cell), half: cell * 0.035, to: &geometry)
        }
        return geometry
    }

    /// A string bows sideways, one way or the other by place pair, and rises a little off the
    /// ground, so it hangs like a thread rather than a ruled line seen from any side.
    static func arc(from start: SIMD3<Float>, to end: SIMD3<Float>, cell: Float) -> [SIMD3<Float>] {
        // Ordered ends keep a string's bow the same whichever end the tree reaches first.
        let (a, b) = (start.x, start.y, start.z) < (end.x, end.y, end.z) ? (start, end) : (end, start)
        let angle = acos(min(1, max(-1, simd_dot(a, b))))
        guard angle > 1e-6, angle < 3.1 else { return [] }
        let steps = min(48, max(8, Int(angle / max(cell * 0.6, 0.004))))
        let side = simd_normalize(simd_cross(a, b))
        let hash = simd_dot(a + b, [12.9898, 78.233, 37.719])
        let bow = angle * 0.2 * (hash - hash.rounded(.down) < 0.5 ? 1 : -1)
        let lift = min(angle * 0.1, 0.04)
        return (0...steps).map { step in
            let t = Float(step) / Float(steps)
            let along = (sin((1 - t) * angle) * a + sin(t * angle) * b) / sin(angle)
            let rise = sin(.pi * t)
            return simd_normalize(along + side * bow * rise) * (GlobeStyle.lightRadius + lift * rise)
        }
    }

    /// Prim's algorithm on angular distance; quadratic, so callers keep the input small.
    static func spanningTree(_ points: [SIMD3<Float>]) -> [(Int, Int)] {
        guard points.count > 1 else { return [] }
        var inTree = [Bool](repeating: false, count: points.count)
        var best = [Float](repeating: -2, count: points.count)
        var parent = [Int](repeating: -1, count: points.count)
        var edges: [(Int, Int)] = []
        var current = 0
        inTree[0] = true
        for _ in 1..<points.count {
            var next = -1, nextScore: Float = -3
            for index in points.indices where !inTree[index] {
                let score = simd_dot(points[current], points[index])
                if score > best[index] { best[index] = score; parent[index] = current }
                if best[index] > nextScore { nextScore = best[index]; next = index }
            }
            guard next >= 0 else { break }
            inTree[next] = true
            edges.append((parent[next], next))
            current = next
        }
        return edges
    }

    /// A flat ring around the Earth's silhouette, radius 1 at the silhouette; `u` runs outward.
    static func rim(segments: Int = 256, inner: Float = GlobeArt.rimInner, outer: Float = GlobeArt.rimOuter) async -> MeshResource? {
        var geometry = Geometry()
        for segment in 0...segments {
            let angle = Float(segment) / Float(segments) * 2 * .pi
            let direction = SIMD3<Float>(cos(angle), sin(angle), 0)
            geometry.positions += [direction * inner, direction * outer]
            geometry.coordinates += [[0, 0.5], [1, 0.5]]
        }
        for segment in 0..<UInt32(segments) {
            let a = segment * 2
            geometry.indices += [a, a + 1, a + 2, a + 1, a + 3, a + 2]
        }
        return await mesh(geometry, name: "Rim")
    }
}

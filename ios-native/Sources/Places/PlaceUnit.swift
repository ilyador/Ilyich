import Foundation
import simd

/// The smallest piece of a place whose city is looked up (REBUILD_ROADMAP.md L1): one name the
/// server gave. A name whose photos spread wider than a neighborhood may reach into several towns,
/// so it is cut into cells about 2 km across, each looked up where its own photos are.
struct PlaceUnit: Sendable {
    let key: String
    let country: String?
    let state: String?
    let name: String?
    /// Where the unit is looked up and where it stands: its photo nearest the middle of its photos.
    let latitude: Double
    let longitude: Double
    let photoID: String
    let count: Int

    /// A name whose photos spread no wider than this, 9 in 10 of them, is one unit.
    static let neighborhoodReach = 3_000.0 / PlaceGeometry.earthRadius
    /// The cells a wider name is cut into, in degrees of latitude: about 2 km.
    static let cellDegrees = 0.018

    /// The units `markers` fall in, and each located photo with its unit.
    static func group(_ markers: [MapMarker]) -> (units: [PlaceUnit], photos: [PlacePhoto]) {
        var named: [String: [MapMarker]] = [:]
        for marker in markers where PlaceGeometry.isOnEarth(latitude: marker.lat, longitude: marker.lon) {
            let name = [marker.country, marker.state, marker.city].map { (PlaceGeometry.text($0) ?? "").replacingOccurrences(of: "|", with: "¦") }
            named[name.joined(separator: "|"), default: []].append(marker)
        }
        var units: [PlaceUnit] = [], photos: [PlacePhoto] = []
        for (name, markers) in named {
            let located = markers.map { PlacePhoto(id: $0.id, latitude: $0.lat, longitude: $0.lon, unit: name) }
            let middle = PlaceGeometry.nearestToMiddle(located)
            let parts: [String: [PlacePhoto]]
            if PlaceGeometry.reach(of: located.map(\.position), from: middle.position) <= neighborhoodReach {
                parts = [name: located]
            } else {
                parts = Dictionary(grouping: located) { name + "|" + cell(latitude: $0.latitude, longitude: $0.longitude) }
            }
            let first = markers[0]
            for (key, members) in parts {
                let standing = members.count == located.count ? middle : PlaceGeometry.nearestToMiddle(members)
                units.append(PlaceUnit(key: key, country: PlaceGeometry.text(first.country), state: PlaceGeometry.text(first.state),
                                       name: PlaceGeometry.text(first.city), latitude: standing.latitude, longitude: standing.longitude,
                                       photoID: standing.id, count: members.count))
                photos += members.map { PlacePhoto(id: $0.id, latitude: $0.latitude, longitude: $0.longitude, unit: key) }
            }
        }
        units.sort { $0.key < $1.key }
        // In ID order, so every place's members, collected in this order, are sorted already.
        photos.sort { $0.id < $1.id }
        return (units, photos)
    }

    /// The cell a point lies in: rows of equal latitude, each cut into columns about as wide as
    /// the rows are tall.
    static func cell(latitude: Double, longitude: Double) -> String {
        let row = Int((latitude / cellDegrees).rounded(.down))
        let width = cellDegrees / max(0.05, cos((Double(row) + 0.5) * cellDegrees * .pi / 180))
        return "\(row):\(Int(((longitude + 180) / width).rounded(.down)))"
    }
}

/// The sums the place hierarchy does on the sphere.
enum PlaceGeometry {
    static let earthRadius = 6_371_000.0

    static func position(latitude: Double, longitude: Double) -> SIMD3<Double> {
        let lat = latitude * .pi / 180, lon = longitude * .pi / 180
        return [cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)]
    }

    static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { acos(min(1, max(-1, simd_dot(a, b)))) }

    /// The photo nearest the middle of `photos`, which must not be empty: a place it stands on is
    /// always one where a photo was taken, never the sea between two shores.
    static func nearestToMiddle(_ photos: [PlacePhoto]) -> PlacePhoto {
        let sum = photos.reduce(SIMD3<Double>.zero) { $0 + $1.position }
        guard simd_length(sum) > 1e-9 else { return photos[0] }
        let middle = simd_normalize(sum)
        return photos.max { simd_dot($0.position, middle) < simd_dot($1.position, middle) }!
    }

    /// How far 9 in 10 of `positions` lie from `center`, in radians.
    static func reach(of positions: [SIMD3<Double>], from center: SIMD3<Double>) -> Double {
        guard !positions.isEmpty else { return 0 }
        let angles = positions.map { angle($0, center) }.sorted()
        return angles[min(angles.count - 1, Int(Double(angles.count) * 0.9))]
    }

    /// `units` in groups that lie together: a unit within `reach` radians of another joins its group.
    static func towns(_ units: [PlaceUnit], within reach: Double) -> [[Int]] {
        let positions = units.map { position(latitude: $0.latitude, longitude: $0.longitude) }
        var town = Array(repeating: -1, count: units.count)
        var towns: [[Int]] = []
        for start in units.indices.sorted(by: { units[$0].count > units[$1].count }) where town[start] < 0 {
            town[start] = towns.count
            var members = [start], next = 0
            while next < members.count {
                let current = members[next]; next += 1
                for other in units.indices where town[other] < 0 && angle(positions[current], positions[other]) <= reach {
                    town[other] = towns.count; members.append(other)
                }
            }
            towns.append(members)
        }
        return towns
    }

    /// `name` without case or accents, its spaces tidied, for matching names typed or read.
    static func folded(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func isOnEarth(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    static func text(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func coordinates(_ latitude: Double, _ longitude: Double) -> String { String(format: "%.2f°, %.2f°", latitude, longitude) }
}

import Foundation
import simd

/// Where the library's photos were taken, nested: continent, country, region, city and
/// neighborhood (REBUILD_ROADMAP.md L1). A node holds every photo of the nodes under it, so a
/// city holds all of its neighborhoods' photos, whatever name the server gave each one.
///
/// It is built in three steps, all pure. The photos fall into units (PlaceUnit). Each unit gets
/// its path down the hierarchy from its locality and from what the whole library says: the code
/// of a country the server names, the region a city lies in mostly, and which towns of one name
/// are really one town. Then the nodes are put together from the photos and their units' paths.
/// A narrowed hierarchy keeps the paths and puts the nodes together again from fewer photos, so
/// every node keeps its ID under a stack of filters.
struct PlaceHierarchy: Sendable {
    enum Level: Int, Comparable, CaseIterable, Sendable {
        case continent, country, region, city, neighborhood
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Node: Identifiable, Hashable, Sendable {
        let id: String
        let level: Level
        let title: String
        let parentID: String?
        fileprivate(set) var childIDs: [String] = []
        /// Every photo under the node, sorted.
        fileprivate(set) var assetIDs: [String] = []
        /// Where the node stands, at one of its photos: where its biggest part stands, and for a
        /// place with no parts, at its biggest unit.
        fileprivate(set) var latitude = 0.0
        fileprivate(set) var longitude = 0.0
        /// The photo standing for the node: the one where it stands.
        fileprivate(set) var coverID = ""
        /// How far 9 in 10 of the node's photos lie from where it stands, in radians.
        fileprivate(set) var reach = 0.0
        /// How far apart its parts must be seen for the place to open into them, in radians; zero
        /// for a place with no parts.
        fileprivate(set) var split = 0.0
        /// The country and the region the node lies in, for its subtitle; its own name at its level.
        let countryName: String?
        let regionName: String?

        var count: Int { assetIDs.count }
        var position: SIMD3<Double> { PlaceGeometry.position(latitude: latitude, longitude: longitude) }
    }

    /// One level of a unit's path: the key that sets it apart from its siblings, and its name.
    struct Step: Hashable, Sendable {
        let level: Level
        let key: String
        let title: String
    }

    private(set) var nodes: [String: Node] = [:]
    /// The top of the hierarchy, biggest first: continents, and anything not known to lie on one.
    private(set) var roots: [String] = []
    /// Each unit's path from its root down to its neighborhood or city.
    let paths: [String: [Step]]
    /// The located photos, with their units.
    let photos: [PlacePhoto]
    /// The units the photos fall in.
    let units: [PlaceUnit]
    /// The marker query the photos were found with, which a place's membership is known by.
    let markerQuery: String
    /// The city each name the server gave lies in mostly, by "country|name".
    let citiesByServerName: [String: String]
    /// Each photo's deepest node.
    private var leaves: [String: String] = [:]
    /// Node IDs by their folded title, for search.
    private var titled: [String: [String]] = [:]
    /// Tells one hierarchy from another: its places and their counts.
    private(set) var identity = ""

    static let empty = PlaceHierarchy(paths: [:], photos: [], units: [], markerQuery: "", citiesByServerName: [:])

    /// The hierarchy of `markers`, with the localities resolved so far. Pure; off the main actor.
    static func build(_ markers: [MapMarker], localities: PlaceLocalities, markerQuery: String = "") -> PlaceHierarchy {
        let (units, photos) = PlaceUnit.group(markers)
        let structure = PlaceStructure(units: units, localities: localities)
        return PlaceHierarchy(paths: structure.paths, photos: photos, units: units, markerQuery: markerQuery,
                              citiesByServerName: structure.citiesByServerName)
    }

    private init(paths: [String: [Step]], photos: [PlacePhoto], units: [PlaceUnit], markerQuery: String, citiesByServerName: [String: String]) {
        self.paths = paths; self.photos = photos; self.units = units; self.markerQuery = markerQuery; self.citiesByServerName = citiesByServerName
        assemble()
    }

    /// The same places counting only `ids`; a place left without photos goes.
    func narrowed(to ids: Set<String>) -> PlaceHierarchy {
        PlaceHierarchy(paths: paths, photos: photos.filter { ids.contains($0.id) }, units: units, markerQuery: markerQuery,
                       citiesByServerName: citiesByServerName)
    }

    subscript(id: String) -> Node? { nodes[id] }

    func children(of node: Node) -> [Node] { node.childIDs.compactMap { nodes[$0] } }

    /// The node and every node above it, nearest first.
    func lineage(of id: String) -> [Node] {
        var lineage: [Node] = [], current = nodes[id]
        while let node = current { lineage.append(node); current = node.parentID.flatMap { nodes[$0] } }
        return lineage
    }

    /// Whether `id` is `other`, lies inside it or holds it.
    func related(_ id: String, _ other: String) -> Bool {
        id == other || lineage(of: id).contains { $0.id == other } || lineage(of: other).contains { $0.id == id }
    }

    /// The deepest place a photo is in.
    func leaf(of assetID: String) -> Node? { leaves[assetID].flatMap { nodes[$0] } }

    /// Every city, biggest first.
    var cities: [Node] { nodes.values.filter { $0.level == .city }.sorted(by: Self.biggestFirst) }

    /// Every country, biggest first, and any place at the top that lies in no known country.
    var countries: [Node] {
        nodes.values.filter { $0.level == .country || ($0.parentID == nil && $0.level > .country) }.sorted(by: Self.biggestFirst)
    }

    /// The places at `level` under a node, biggest first, and any under it that reach no deeper.
    func descendants(of node: Node, at level: Level) -> [Node] {
        var found: [Node] = []
        var pending = children(of: node)
        while let next = pending.popLast() {
            if next.level == level || (next.level < level && next.childIDs.isEmpty) { found.append(next) }
            else if next.level < level { pending += children(of: next) }
        }
        return found.sorted(by: Self.biggestFirst)
    }

    /// The places named `name`, ignoring case and accents, biggest first.
    func places(named name: String) -> [Node] {
        (titled[PlaceGeometry.folded(name)] ?? []).compactMap { nodes[$0] }.sorted(by: Self.biggestFirst)
    }

    /// Every folded place name, for finding them in text.
    var foldedTitles: some Collection<String> { titled.keys }

    /// The node's photos as the place filter knows them.
    func membership(of node: Node) -> PlaceMembership {
        PlaceMembership(placeID: node.id, assetIDs: node.assetIDs, markerQuery: markerQuery)
    }

    static func biggestFirst(_ a: Node, _ b: Node) -> Bool {
        a.count != b.count ? a.count > b.count : a.level != b.level ? a.level < b.level : a.title < b.title
    }

    // MARK: Putting the nodes together

    private mutating func assemble() {
        let unitsByKey = Dictionary(units.map { ($0.key, $0) }) { first, _ in first }
        var members: [String: [Int]] = [:]
        var made: [String: Node] = [:]
        for (index, photo) in photos.enumerated() {
            guard let path = paths[photo.unit], !path.isEmpty else { continue }
            var parentID: String?
            var key = ""
            for step in path {
                key += (key.isEmpty ? "" : "|") + step.key
                let id = "\(step.level):\(key)"
                if made[id] == nil {
                    made[id] = Node(id: id, level: step.level, title: step.title, parentID: parentID,
                                    countryName: path.first { $0.level == .country }?.title,
                                    regionName: path.first { $0.level == .region }?.title)
                    if let parentID { made[parentID]?.childIDs.append(id) } else { roots.append(id) }
                }
                members[id, default: []].append(index)
                parentID = id
            }
            if let parentID { leaves[photo.id] = parentID }
        }
        // Deepest first: a node stands where its biggest part stands, all the way down to the
        // biggest unit of a place with no parts, so a pin that opens stays where it was and its
        // parts come out around it.
        for id in made.keys.sorted(by: { made[$0]!.level > made[$1]!.level }) {
            guard var node = made[id], let indices = members[id] else { continue }
            node.assetIDs = indices.map { photos[$0].id }.sorted()
            node.childIDs.sort { made[$0]!.assetIDs.count != made[$1]!.assetIDs.count ? made[$0]!.assetIDs.count > made[$1]!.assetIDs.count : $0 < $1 }
            let standing: PlacePhoto
            if let biggest = node.childIDs.first.flatMap({ made[$0] }) {
                standing = PlacePhoto(id: biggest.coverID, latitude: biggest.latitude, longitude: biggest.longitude, unit: "")
            } else {
                standing = Self.standing(indices.map { photos[$0] }, units: unitsByKey)
            }
            node.latitude = standing.latitude; node.longitude = standing.longitude; node.coverID = standing.id
            node.reach = PlaceGeometry.reach(of: indices.map { photos[$0].position }, from: standing.position)
            node.split = Self.split(node, children: node.childIDs.compactMap { made[$0] })
            made[id] = node
        }
        nodes = made
        var hasher = Hasher()
        for id in made.keys.sorted() { hasher.combine(id); hasher.combine(made[id]!.count); hasher.combine(made[id]!.coverID) }
        hasher.combine(markerQuery)
        identity = String(hasher.finalize())
        roots.sort { made[$0]!.assetIDs.count != made[$1]!.assetIDs.count ? made[$0]!.assetIDs.count > made[$1]!.assetIDs.count : $0 < $1 }
        for node in made.values { titled[PlaceGeometry.folded(node.title), default: []].append(node.id) }
    }

    /// Where a place with no parts stands: at its biggest unit's own photo, or, when that photo is
    /// filtered out, the kept photo of that unit nearest it.
    private static func standing(_ photos: [PlacePhoto], units: [String: PlaceUnit]) -> PlacePhoto {
        var counts: [String: Int] = [:]
        for photo in photos { counts[photo.unit, default: 0] += 1 }
        let biggest = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
        let inUnit = photos.filter { $0.unit == biggest }
        guard let unit = units[biggest] else { return PlaceGeometry.nearestToMiddle(inUnit) }
        if let own = inUnit.first(where: { $0.id == unit.photoID }) { return own }
        let target = PlaceGeometry.position(latitude: unit.latitude, longitude: unit.longitude)
        return inUnit.max { simd_dot($0.position, target) < simd_dot($1.position, target) }!
    }

    /// How far apart a place's parts must be seen for it to open into them, in radians: the
    /// closest two of its parts that hold at least one photo in 50 of it (the two biggest at
    /// least). A part smaller than that may hide behind a bigger one until it has room. A place
    /// of one part opens into it once its photos spread that far.
    private static func split(_ node: Node, children: [Node]) -> Double {
        guard children.count > 1 else { return children.isEmpty ? 0 : node.reach }
        var shown = children.filter { $0.count * 50 >= node.count }
        if shown.count < 2 { shown = Array(children.prefix(2)) }
        var closest = Double.pi
        for (index, a) in shown.enumerated() {
            for b in shown[(index + 1)...] { closest = min(closest, PlaceGeometry.angle(a.position, b.position)) }
        }
        return closest
    }
}

/// One located photo.
struct PlacePhoto: Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    /// The unit it falls in.
    let unit: String
    var position: SIMD3<Double> { PlaceGeometry.position(latitude: latitude, longitude: longitude) }

    init(id: String, latitude: Double, longitude: Double, unit: String) {
        self.id = id; self.latitude = latitude; self.longitude = longitude; self.unit = unit
    }
}

/// Each unit's path, decided from the units of the whole library.
private struct PlaceStructure {
    var paths: [String: [PlaceHierarchy.Step]] = [:]
    var citiesByServerName: [String: String] = [:]

    /// Towns of one name in one country this far apart are different towns.
    static let sameTownReach = 50_000.0 / PlaceGeometry.earthRadius

    init(units: [PlaceUnit], localities: PlaceLocalities) {
        // A country the server names is known by the code Apple Maps gives its other units.
        var codes: [String: [String: Int]] = [:]
        for unit in units {
            if let country = unit.country, let code = localities[unit.key]?.countryCode { codes[country, default: [:]][code, default: 0] += unit.count }
        }
        let learned = codes.compactMapValues { $0.max { $0.value < $1.value }?.key }

        struct Placed {
            let unit: PlaceUnit
            let countryKey: String?
            let countryTitle: String?
            let continent: Continent?
            let city: String
        }
        var placed: [Placed] = []
        for unit in units {
            let locality = localities[unit.key]
            let code = locality?.countryCode ?? unit.country.flatMap { learned[$0] }
            let countryTitle = code.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? unit.country
            let countryKey = code ?? unit.country.map { "~" + $0 }
            let city = locality?.city ?? unit.name ?? PlaceGeometry.coordinates(unit.latitude, unit.longitude)
            placed.append(Placed(unit: unit, countryKey: countryKey, countryTitle: countryTitle,
                                 continent: code.flatMap(Continent.of), city: city))
        }

        // Units of one city name in one country are one city, unless they lie far apart.
        let byCity = Dictionary(grouping: placed.indices) { "\(placed[$0].countryKey ?? "")|\(placed[$0].city)" }
        var serverNames: [String: [String: Int]] = [:]
        for indices in byCity.values {
            for (number, town) in PlaceGeometry.towns(indices.map { placed[$0].unit }, within: Self.sameTownReach).enumerated() {
                let members = town.map { indices[$0] }
                let first = placed[members[0]]
                var states: [String: Int] = [:]
                var names: [String: Int] = [:]
                for index in members {
                    let unit = placed[index].unit
                    if let state = unit.state { states[state, default: 0] += unit.count }
                    names[unit.name ?? first.city, default: 0] += unit.count
                }
                let region = states.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
                var head: [PlaceHierarchy.Step] = []
                if let continent = first.continent { head.append(.init(level: .continent, key: continent.rawValue, title: continent.name)) }
                if let key = first.countryKey, let title = first.countryTitle { head.append(.init(level: .country, key: key, title: title)) }
                if let region { head.append(.init(level: .region, key: region, title: region)) }
                head.append(.init(level: .city, key: number == 0 ? first.city : "\(first.city)#\(number)", title: first.city))
                for index in members {
                    let unit = placed[index].unit
                    var path = head
                    let name = unit.name ?? first.city
                    if names.count > 1 { path.append(.init(level: .neighborhood, key: name, title: name)) }
                    paths[unit.key] = path
                    if let name = unit.name { serverNames["\(unit.country ?? "")|\(name)", default: [:]][first.city, default: 0] += unit.count }
                }
            }
        }
        citiesByServerName = serverNames.compactMapValues { $0.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key }
    }
}

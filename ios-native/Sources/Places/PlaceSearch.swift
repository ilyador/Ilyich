import Foundation

/// The places named in a search typed, read against the hierarchy (REBUILD_ROADMAP.md L1): "me in
/// Porto" is the whole city of Porto, every neighborhood of it, with "me" left for the server to
/// read. It reads as the server's own planner does, so a name the hierarchy doesn't know is left
/// in the text for the server, and ordinary words that are also places (Reading, Bath) count only
/// after "in", "at" and the like, or when nothing else is asked.
struct PlaceSearch: Sendable {
    /// The places found, biggest first, and the text left for the server.
    struct Reading: Equatable, Sendable {
        var places: [PlaceHierarchy.Node]
        var remainder: String
        /// The places' photos together, known by the place IDs, with the title their pill shows.
        var membership: PlaceMembership?
        var title: String
    }

    struct Token {
        let original: Substring
        let folded: String
    }

    static let leading: Set<String> = ["in", "at", "from", "near", "around", "or"]
    static let filler: Set<String> = ["a", "an", "all", "some", "and", "or", "in", "at", "near", "around", "from", "of", "with", "the", "on",
                                      "during", "photos", "pictures", "images", "show", "find", "give", "please", "taken", "year"]

    let hierarchy: PlaceHierarchy

    func read(_ text: String) -> Reading? {
        let tokens = Self.tokens(of: text)
        guard !tokens.isEmpty else { return nil }
        var used = Set<Int>()
        var found: [PlaceHierarchy.Node] = []
        let titles = hierarchy.foldedTitles.sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0 < $1 })
        // A name alone counts once everything else is read, so "Lisbon or Porto" is read again
        // for Lisbon after "or Porto" was.
        var more = true
        while more {
            more = false
            for title in titles {
                let parts = title.split(separator: " ").map(String.init)
                guard !parts.isEmpty else { continue }
                var index = 0
                while index + parts.count <= tokens.count {
                    defer { index += 1 }
                    guard !(index..<index + parts.count).contains(where: used.contains),
                          (0..<parts.count).allSatisfy({ tokens[index + $0].folded == parts[$0] }) else { continue }
                    let previous = index > 0 ? tokens[index - 1].folded : nil
                    // Only a place asked for, after "in" or alone, is one; "outside" and "not in"
                    // stay for the server, which can leave a place out.
                    guard previous != "outside", !(index > 1 && tokens[index - 2].folded == "not") else { continue }
                    let askedFor = previous.map(Self.leading.contains) == true
                        || tokens.indices.allSatisfy { used.contains($0) || ($0 >= index && $0 < index + parts.count) || Self.filler.contains(tokens[$0].folded) }
                    guard askedFor, let place = Self.choose(hierarchy.places(named: title)), !found.contains(where: { $0.id == place.id }) else { continue }
                    found.append(place); more = true
                    for offset in 0..<parts.count { used.insert(index + offset) }
                    if let previous, Self.leading.contains(previous) { used.insert(index - 1) }
                }
            }
        }
        guard !found.isEmpty else { return nil }
        found.sort(by: PlaceHierarchy.biggestFirst)
        var kept = tokens.indices.filter { !used.contains($0) }
        while let first = kept.first, Self.filler.contains(tokens[first].folded) { kept.removeFirst() }
        while let last = kept.last, Self.filler.contains(tokens[last].folded) { kept.removeLast() }
        let remainder = kept.map { String(tokens[$0].original) }.joined(separator: " ")
        let ids = Set(found.flatMap(\.assetIDs)).sorted()
        let membership = ids.isEmpty ? nil : PlaceMembership(placeID: found.map(\.id).joined(separator: "+"), assetIDs: ids, markerQuery: hierarchy.markerQuery)
        return Reading(places: found, remainder: remainder, membership: membership, title: found.map(\.title).joined(separator: " · "))
    }

    /// Of the places of one name: the most specific when they lie in one another (the city of
    /// Porto, not its region, and not the neighborhood the server calls Porto, which is the city's
    /// own part), the biggest otherwise.
    static func choose(_ places: [PlaceHierarchy.Node]) -> PlaceHierarchy.Node? {
        guard let biggest = places.first else { return nil }
        let candidates = places.filter { $0.level <= .city }
        let deepest = (candidates.isEmpty ? places : candidates).max { a, b in a.level != b.level ? a.level < b.level : a.count < b.count }!
        return places.allSatisfy({ related($0, deepest) }) ? deepest : biggest
    }

    /// Whether one place holds the other: a place's key starts with its parent's.
    private static func related(_ a: PlaceHierarchy.Node, _ b: PlaceHierarchy.Node) -> Bool {
        key(a).hasPrefix(key(b)) || key(b).hasPrefix(key(a))
    }

    private static func key(_ node: PlaceHierarchy.Node) -> String { String(node.id.drop { $0 != ":" }.dropFirst()) + "|" }

    /// The words of `text`: letters and digits, with apostrophes and hyphens inside a word.
    static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        func close(_ end: String.Index) {
            guard let begin = start else { return }
            var word = text[begin..<end]
            while let last = word.last, "'’-".contains(last) { word = word.dropLast() }
            if !word.isEmpty { tokens.append(Token(original: word, folded: PlaceGeometry.folded(String(word)))) }
            start = nil
        }
        for index in text.indices {
            let character = text[index]
            if character.isLetter || character.isNumber || (start != nil && "'’-".contains(character)) {
                if start == nil { start = index }
            } else { close(index) }
        }
        close(text.endIndex)
        return tokens
    }
}

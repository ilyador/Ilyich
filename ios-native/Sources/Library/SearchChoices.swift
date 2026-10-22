import Foundation

/// What the owner chose under the search bar: the AI check, the mode and the filters from More.
/// They apply to every search typed in the bar, and to the filtered view More opens when no text
/// is typed. They persist, per server and account, until changed.
struct SearchChoices: Hashable, Sendable {
    /// The AI check on a Photo content search. Off is Immich's smart search, sent with
    /// verify: false; on leaves verification to the server, which checks when it is configured.
    var checksContent = false
    var mode = SearchMode.context
    /// Only the filters More sets: people, tags, place, camera, date, media type and display options.
    var filter = SearchFilter()

    /// A Photo content search that asks the server to check its results.
    var verifiesText: Bool { checksContent && mode == .context }
    var isFiltering: Bool { filter != SearchFilter() }

    /// The filter as More may set it; anything a feed or the text sets is dropped, and both
    /// visibilities, the default, are left unsaid.
    static func sanitized(_ filter: SearchFilter) -> SearchFilter {
        var kept = SearchFilter()
        kept.personIds = filter.personIds?.all.map { IDsFilter(all: $0) }
        kept.tagIds = filter.tagIds?.all.map { IDsFilter(all: $0) }
        kept.country = filter.country; kept.state = filter.state; kept.city = filter.city
        kept.make = filter.make; kept.model = filter.model
        kept.takenAt = filter.takenAt
        kept.type = filter.type
        kept.isFavorite = filter.isFavorite; kept.isMotion = filter.isMotion; kept.hasAlbums = filter.hasAlbums
        kept.rating = filter.rating
        if let visibility = filter.visibility {
            let names = Set(visibility.eq.map { [$0] } ?? visibility.in ?? [])
            if names == ["timeline"] || names == ["archive"] { kept.visibility = StringFilter(eq: names.first) }
        }
        return kept
    }
}

// MARK: Chips

/// One choice shown under the search bar while it applies; tapping it removes it.
struct SearchChip: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case mode, people, tags, place, camera, date, type, favorites, motion, notInAlbum, rating, visibility
    }
    let kind: Kind
    let title: String
    var id: Kind { kind }
}

extension SearchChoices {
    /// The chips, in the order More lists the choices. A person's name comes from `personName`.
    func chips(personName: (String) -> String? = { _ in nil }) -> [SearchChip] {
        var chips: [SearchChip] = []
        if mode != .context { chips.append(.init(kind: .mode, title: mode.rawValue)) }
        if let people = filter.personIds?.all, !people.isEmpty {
            let title = people.count == 1 ? personName(people[0]).flatMap { $0.isEmpty ? nil : $0 } ?? "1 person" : "\(people.count) people"
            chips.append(.init(kind: .people, title: title))
        }
        if let tags = filter.tagIds?.all, !tags.isEmpty { chips.append(.init(kind: .tags, title: tags.count == 1 ? "1 tag" : "\(tags.count) tags")) }
        if let place = filter.city?.eq ?? filter.state?.eq ?? filter.country?.eq { chips.append(.init(kind: .place, title: place)) }
        let camera = [filter.make?.eq, filter.model?.eq].compactMap { $0 }
        if !camera.isEmpty { chips.append(.init(kind: .camera, title: camera.joined(separator: " "))) }
        if let taken = filter.takenAt { chips.append(.init(kind: .date, title: Self.dateTitle(taken))) }
        if let type = filter.type?.eq { chips.append(.init(kind: .type, title: type == "VIDEO" ? "Videos" : "Photos")) }
        if filter.isFavorite?.eq == true { chips.append(.init(kind: .favorites, title: "Favorites")) }
        if filter.isMotion?.eq == true { chips.append(.init(kind: .motion, title: "Motion photos")) }
        if filter.hasAlbums?.eq == false { chips.append(.init(kind: .notInAlbum, title: "Not in an album")) }
        if let rating = filter.rating {
            let stars = rating.eq ?? 0
            chips.append(.init(kind: .rating, title: stars == 0 ? "Unrated" : stars == 1 ? "1 star" : "\(stars) stars"))
        }
        if let visibility = filter.visibility?.eq {
            chips.append(.init(kind: .visibility, title: visibility == "archive" ? "Only archived" : "Not archived"))
        }
        return chips
    }

    /// The choices without one chip's.
    func removing(_ kind: SearchChip.Kind) -> SearchChoices {
        var choices = self
        switch kind {
        case .mode: choices.mode = .context
        case .people: choices.filter.personIds = nil
        case .tags: choices.filter.tagIds = nil
        case .place: choices.filter.country = nil; choices.filter.state = nil; choices.filter.city = nil
        case .camera: choices.filter.make = nil; choices.filter.model = nil
        case .date: choices.filter.takenAt = nil
        case .type: choices.filter.type = nil
        case .favorites: choices.filter.isFavorite = nil
        case .motion: choices.filter.isMotion = nil
        case .notInAlbum: choices.filter.hasAlbums = nil
        case .rating: choices.filter.rating = nil
        case .visibility: choices.filter.visibility = nil
        }
        return choices
    }

    /// The days chosen, the last one included: Search options store the day after it.
    private static func dateTitle(_ taken: DateFilter) -> String {
        let calendar = Calendar.current
        let last = taken.lt.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) }
        switch (taken.gte, last) {
        case let (start?, end?):
            let formatter = DateIntervalFormatter()
            formatter.dateStyle = .medium; formatter.timeStyle = .none
            return formatter.string(from: start, to: max(start, end))
        case let (start?, nil): return "From " + start.formatted(date: .abbreviated, time: .omitted)
        case let (nil, end?): return "Through " + end.formatted(date: .abbreviated, time: .omitted)
        case (nil, nil): return "Any date"
        }
    }
}

// MARK: Persistence

extension SearchChoices: Codable {
    private enum CodingKeys: String, CodingKey { case checksContent, mode, filter }

    /// Modes are stored by a fixed name, not by the title the app shows.
    private static let modeNames: [SearchMode: String] = [.context: "context", .filename: "filename", .description: "description", .ocr: "ocr"]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checksContent = try container.decodeIfPresent(Bool.self, forKey: .checksContent) ?? false
        let name = try container.decodeIfPresent(String.self, forKey: .mode)
        mode = Self.modeNames.first { $0.value == name }?.key ?? .context
        filter = Self.sanitized(try container.decodeIfPresent(SearchFilter.self, forKey: .filter) ?? SearchFilter())
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(checksContent, forKey: .checksContent)
        try container.encode(Self.modeNames[mode], forKey: .mode)
        try container.encode(filter, forKey: .filter)
    }
}

/// Where the choices are kept on this phone: per server and account, as the shelf order is.
struct SearchChoicesStorage {
    let scope: String
    var defaults: UserDefaults = .standard

    private var key: String { "searchChoices.\(scope)" }

    func load() -> SearchChoices {
        guard let data = defaults.data(forKey: key), let choices = try? JSONDecoder().decode(SearchChoices.self, from: data) else { return SearchChoices() }
        return choices
    }

    func save(_ choices: SearchChoices) {
        guard let data = try? JSONEncoder().encode(choices) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: Narrowing

extension LibraryQuery {
    /// The query with More's filters added. People and tags join the feed's; any other filter
    /// chosen replaces the feed's own, and a visibility chosen keeps to the feed's.
    func narrowed(by filter: SearchFilter) -> LibraryQuery {
        let chosen = LibraryQuery(filter).predicates
        var query = self
        query.predicates.people.formUnion(chosen.people)
        query.predicates.tags.formUnion(chosen.tags)
        query.predicates.kind = chosen.kind ?? query.predicates.kind
        query.predicates.favorite = chosen.favorite ?? query.predicates.favorite
        query.predicates.motion = chosen.motion ?? query.predicates.motion
        query.predicates.inAnyAlbum = chosen.inAnyAlbum ?? query.predicates.inAnyAlbum
        query.predicates.rating = chosen.rating ?? query.predicates.rating
        query.predicates.taken = chosen.taken ?? query.predicates.taken
        query.predicates.camera = chosen.camera ?? query.predicates.camera
        query.predicates.location = chosen.location ?? query.predicates.location
        if filter.visibility != nil { query.visibility.formIntersection(LibraryQuery(filter).visibility) }
        return query
    }
}

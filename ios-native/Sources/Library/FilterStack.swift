import Foundation

/// One layer of the library's filters (REBUILD_ROADMAP.md N6): a person, an album or one of More's
/// collections from the shelves, or a place from the Earth.
enum FilterLayer: Hashable, Sendable, Identifiable {
    case collection(LibraryCollection)
    case place(PlaceMembership, title: String)

    /// The shelf row the layer comes from, which also names its pill. There is one place layer: a
    /// new place takes the old one's.
    var id: String {
        switch self {
        case .collection(let collection): collection.rowID
        case .place: Self.placeID
        }
    }
    static let placeID = "place"

    /// The pill's title, which is also the filter's: a person without a name is "Person".
    var title: String {
        switch self {
        case .collection(.person(let person)): person.name.isEmpty ? "Person" : person.name
        case .collection(let collection): collection.title
        case .place(_, let title): title
        }
    }

    /// A person, an album and a place are searched in the archive too, as the library is; More's
    /// collections keep their own visibility and trash.
    fileprivate var searchesArchive: Bool {
        switch self {
        case .collection(.person), .collection(.album), .place: true
        case .collection: false
        }
    }
}

/// The filters the feed shows, in the order they were chosen (REBUILD_ROADMAP.md N6). Layers combine
/// by AND: a place and a person show that person's photos in that place, and People and Albums
/// stack too, so two people show the photos with both. Pure.
struct FilterStack: Hashable, Sendable {
    private(set) var layers: [FilterLayer] = []

    init(_ layers: [FilterLayer] = []) {
        for layer in layers { add(layer) }
    }

    var isEmpty: Bool { layers.isEmpty }
    func contains(_ id: String) -> Bool { layers.contains { $0.id == id } }

    /// Adds a layer at the end. A layer already there stays where it is, and a new place takes the
    /// place of the one there, as two places would show nothing. Returns whether anything changed.
    @discardableResult
    mutating func add(_ layer: FilterLayer) -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == layer.id }) else {
            layers.append(layer)
            return true
        }
        guard case .place = layer, layers[index] != layer else { return false }
        layers[index] = layer
        return true
    }

    /// Takes a layer's newer record where it is, such as an album renamed or given another order.
    /// Returns whether the layer was there.
    @discardableResult
    mutating func update(_ layer: FilterLayer) -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == layer.id }) else { return false }
        layers[index] = layer
        return true
    }

    /// Removes only this layer; the others keep their order. Returns whether it was there.
    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return false }
        layers.remove(at: index)
        return true
    }

    mutating func clear() { layers = [] }

    /// The layers' titles in order, as the search prompt names the feed; nil with none.
    var title: String? { layers.isEmpty ? nil : layers.map(\.title).joined(separator: " · ") }

    /// The feed the layers make together, on the library: people and albums by AND, a place, an
    /// owner (Recently taken and added keep to the account's own photos), favorites, Lightroom, a
    /// kind and motion, archive and trash. A layer alone is exactly the feed its row showed before.
    /// Visibilities intersect, so Archive with Trash is the trashed archive. Recently added orders
    /// by the date added; one album alone keeps its own order.
    var query: LibraryQuery {
        var query = LibraryQuery.library
        var visibility: LibraryQuery.Visibility?
        var addedFirst = false
        var albumOrders: [Bool] = []
        func narrow(_ kept: LibraryQuery.Visibility) { visibility = visibility.map { $0.intersection(kept) } ?? kept }
        for layer in layers {
            switch layer {
            case .place(let membership, _): query.predicates.place = membership
            case .collection(let collection):
                switch collection {
                case .person(let person): query.predicates.people.insert(person.id)
                case .album(let album):
                    query.predicates.albums.insert(album.id)
                    albumOrders.append(album.order == "asc")
                case .recentlyTaken: query.scope = .mine
                case .recentlyAdded:
                    query.scope = .mine; narrow([.timeline, .archive]); addedFirst = true
                case .videos: query.predicates.kind = .video
                case .motion: query.predicates.motion = true
                case .lightroom: query.predicates.developed = true
                case .favorites: query.predicates.favorite = true
                case .archive: narrow(.archive)
                case .trash:
                    query.trash = .trashed; narrow([.timeline, .archive])
                }
            }
        }
        query.visibility = visibility ?? .timeline
        if addedFirst { query.ranking = .chronological(.createdAt, ascending: false) }
        else if albumOrders == [true] { query.ranking = .chronological(.takenAt, ascending: true) }
        return query
    }

    /// What a search inside the stacked feed looks in: the timeline and the archive under people,
    /// albums and a place, as the library is searched; with any of More's collections, that
    /// collection's own visibility and trash, as a search inside it always kept.
    var searchScope: LibraryQuery {
        var scope = query
        if layers.allSatisfy(\.searchesArchive) { scope.visibility = [.timeline, .archive] }
        return scope
    }

    /// The stack without its place, which narrows the Earth: the place's own layer would leave
    /// only itself there, and choosing another place replaces it.
    var withoutPlace: FilterStack {
        var stack = self
        stack.remove(FilterLayer.placeID)
        return stack
    }
}

extension LibraryCollection {
    /// More's collection whose feed `query` is, for a collection chosen outside the shelves.
    static func more(showing query: LibraryQuery) -> LibraryCollection? {
        more.first { FilterStack([.collection($0)]).query == query }
    }
}

/// How many of a stacked feed's photos each person and each album holds, counted by the offline
/// index (REBUILD_ROADMAP.md N6). The shelves list only those with photos there.
struct ShelfFacets: Hashable, Sendable {
    var people: [String: Int] = [:]
    var albums: [String: Int] = [:]
}

/// A pill at the top of the feed (REBUILD_ROADMAP.md N6): one per layer, a search typed, or the one
/// feed shown that is no layer (a partner's, More's filtered library). Its X removes only it.
struct FilterPill: Identifiable, Hashable, Sendable {
    enum Icon: Hashable, Sendable {
        case person(Person)
        /// An album's cover, round.
        case cover(String)
        case symbol(String)
    }

    enum Removal: Hashable, Sendable {
        /// Only this layer goes.
        case layer(String)
        /// The search typed ends; the layers stay.
        case search
        /// The feed that is no layer goes, back to the library.
        case feed
    }

    let id: String
    let title: String
    let icon: Icon
    /// The matches a search found, once it has.
    var count: Int?
    let removal: Removal
    /// The group of the shelves a tap or drag on the pill brings back.
    let shelf: ShelfLevel

    /// The pills for what the feed shows: the layers in the order chosen, then a search typed. A
    /// feed that is no layer (`feedTitle` with no layers) has one pill of its own.
    static func pills(stack: FilterStack, feedTitle: String?, feedSymbol: String, search: String, matches: Int?) -> [FilterPill] {
        var pills = stack.layers.map(pill)
        if stack.isEmpty, let feedTitle {
            pills.append(FilterPill(id: "feed", title: feedTitle, icon: .symbol(feedSymbol), removal: .feed, shelf: .root))
        }
        if !search.isEmpty {
            pills.append(FilterPill(id: "search", title: search, icon: .symbol("magnifyingglass"), count: matches, removal: .search, shelf: .root))
        }
        return pills
    }

    static func pill(_ layer: FilterLayer) -> FilterPill {
        switch layer {
        case .place:
            return FilterPill(id: layer.id, title: layer.title, icon: .symbol("mappin.and.ellipse"), removal: .layer(layer.id), shelf: .root)
        case .collection(let collection):
            switch collection {
            case .person(let person):
                return FilterPill(id: layer.id, title: layer.title, icon: .person(person), removal: .layer(layer.id), shelf: .people)
            case .album(let album):
                let icon: Icon = album.albumThumbnailAssetId.map { .cover($0) } ?? .symbol(collection.symbol)
                return FilterPill(id: layer.id, title: layer.title, icon: icon, removal: .layer(layer.id), shelf: .albums)
            default:
                return FilterPill(id: layer.id, title: layer.title, icon: .symbol(collection.symbol), removal: .layer(layer.id), shelf: .more)
            }
        }
    }
}

import CryptoKit
import Foundation

/// What a feed shows, in one typed description the index, the server timeline and server search
/// all serve. Hidden and locked photos can't be expressed; the Locked Folder has its own query.
struct LibraryQuery: Hashable, Sendable {
    /// Whose photos. Albums, people and a place are predicates, so each stacks with any owner and
    /// with every other filter by AND.
    enum Scope: Hashable, Sendable {
        /// The account's own photos and those of the partners it shows in its timeline.
        case library
        /// Only the account's own photos.
        case mine
        /// One partner's photos.
        case partner(String)
    }

    enum Trash: Hashable, Sendable { case active, trashed }

    /// Timeline and archive. Hidden and locked have no member, and other bits are dropped.
    struct Visibility: OptionSet, Hashable, Sendable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue & 0b11 }
        static let timeline = Visibility(rawValue: 1)
        static let archive = Visibility(rawValue: 2)
    }

    enum DateField: String, Hashable, Sendable { case takenAt, createdAt }

    enum Ranking: Hashable, Sendable {
        case chronological(DateField, ascending: Bool)
        case relevance(Relevance)
    }

    enum Relevance: Hashable, Sendable {
        /// A smart search for the text, in the given language.
        case text(String, language: String?)
        case similar(to: String)
    }

    /// Whether a stack shows only its primary photo.
    enum Stacks: Hashable, Sendable { case primaryOnly, all }

    struct Predicates: Hashable, Sendable {
        var favorite: Bool?
        /// Developed in Lightroom, or with false, not.
        var developed: Bool?
        var kind: AssetKind?
        /// Live Photos and other photos with motion.
        var motion: Bool?
        /// Photos with every one of these people.
        var people: Set<String> = []
        /// Photos with every one of these tags.
        var tags: Set<String> = []
        var inAnyAlbum: Bool?
        var rating: Int?
        var taken: DateInterval?
        var camera: Camera?
        var location: Location?
        var text: TextMatch?
        /// Photos in every one of these albums.
        var albums: Set<String> = []
        /// Photos in this place, as the map gathered them.
        var place: PlaceMembership?
    }

    struct Camera: Hashable, Sendable {
        var make: String?
        var model: String?
    }

    struct Location: Hashable, Sendable {
        var country: String?
        var state: String?
        var city: String?
    }

    /// Text found in one field, as the Filename, Description and Text in photos searches find it.
    struct TextMatch: Hashable, Sendable {
        enum Field: String, Hashable, Sendable { case filename, description, textInPhoto }
        var field: Field
        var value: String
    }

    var scope: Scope = .library
    var trash: Trash = .active
    var visibility: Visibility = .timeline
    var ranking: Ranking = .chronological(.takenAt, ascending: false)
    var stacks: Stacks = .primaryOnly
    var predicates = Predicates()
}

// MARK: Presets

extension LibraryQuery {
    /// Timeline photos, newest taken first.
    static let library = LibraryQuery()
    static let favorites = LibraryQuery(predicates: Predicates(favorite: true))
    static let archive = LibraryQuery(visibility: .archive)
    /// The account's trash, from the timeline and the archive.
    static let trash = LibraryQuery(trash: .trashed, visibility: [.timeline, .archive])
    static let recentlyTaken = LibraryQuery(scope: .mine)
    static let recentlyAdded = LibraryQuery(scope: .mine, visibility: [.timeline, .archive], ranking: .chronological(.createdAt, ascending: false))
    static let lightroom = LibraryQuery(predicates: Predicates(developed: true))
    static let videos = LibraryQuery(predicates: Predicates(kind: .video))
    static let motion = LibraryQuery(predicates: Predicates(motion: true))

    /// A partner's photos, archived ones included.
    static func partner(_ id: String) -> LibraryQuery { LibraryQuery(scope: .partner(id), visibility: [.timeline, .archive]) }
    /// An album in its own order.
    static func album(_ id: String, ascending: Bool = false) -> LibraryQuery {
        LibraryQuery(ranking: .chronological(.takenAt, ascending: ascending), predicates: Predicates(albums: [id]))
    }
    static func person(_ id: String) -> LibraryQuery { LibraryQuery(predicates: Predicates(people: [id])) }
    static func place(_ membership: PlaceMembership) -> LibraryQuery { LibraryQuery(predicates: Predicates(place: membership)) }
}

// MARK: Refinements

extension LibraryQuery {
    /// The same feed searched for text. A Photo content search ranks by relevance; Filename,
    /// Description and Text in photos match their field and keep the feed's order. Everything
    /// else is kept, the feed's filters included, as searching inside a feed keeps them today.
    /// Refine the feed's own query: a refinement replaces an earlier one.
    func refined(text: String, mode: SearchMode, language: String? = nil) -> LibraryQuery {
        var query = self
        query.predicates.text = nil
        if case .relevance = query.ranking { query.ranking = Self.library.ranking }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return query }
        switch mode {
        case .context: query.ranking = .relevance(.text(text, language: language))
        case .filename: query.predicates.text = TextMatch(field: .filename, value: text)
        case .description: query.predicates.text = TextMatch(field: .description, value: text)
        case .ocr: query.predicates.text = TextMatch(field: .textInPhoto, value: text)
        }
        return query
    }

    /// Photos like one photo, with this feed's owner, albums, people, place, trash, visibility,
    /// stacks and developed state. Its other filters don't apply.
    func similar(to assetID: String) -> LibraryQuery {
        LibraryQuery(scope: scope, trash: trash, visibility: visibility, ranking: .relevance(.similar(to: assetID)), stacks: stacks,
                     predicates: Predicates(developed: predicates.developed, people: predicates.people, albums: predicates.albums,
                                            place: predicates.place))
    }
}

// MARK: Stable key

extension LibraryQuery {
    /// Names the feed for what the phone keeps per feed. For the library, favorites, archive,
    /// trash, Lightroom, partner, album and person feeds it is byte-equal to the key these feeds
    /// were cached under before Q5, which never said withPartners. A query on the account's own
    /// photos says userId=me rather than the user's ID, and a place is named by its membership
    /// revision rather than its photo count.
    var stableKey: String {
        var items: [(String, String)] = []
        switch ranking {
        case .chronological(let field, let ascending): items += [("order", ascending ? "asc" : "desc"), ("orderBy", field.rawValue)]
        case .relevance: items.append(("order", "relevance"))
        }
        items.append(("withStacked", stacks == .primaryOnly ? "true" : "false"))
        // Both visibilities, as the old filter's nil, are left unsaid.
        if visibility == .timeline { items.append(("visibility", "timeline")) }
        else if visibility == .archive { items.append(("visibility", "archive")) }
        else if visibility.isEmpty { items.append(("visibility", "none")) }
        // One album or person is named as today's feeds name it; more are listed further on.
        if predicates.albums.count == 1, let album = predicates.albums.first { items.append(("albumId", album)) }
        if predicates.people.count == 1, let person = predicates.people.first { items.append(("personId", person)) }
        switch scope {
        case .partner(let id): items.append(("userId", id))
        case .mine: items.append(("userId", "me"))
        case .library: break
        }
        if let favorite = predicates.favorite { items.append(("isFavorite", String(favorite))) }
        // Today's own-photo feeds ask for active photos explicitly; the others leave it to the server.
        if trash == .trashed { items.append(("isTrashed", "true")) } else if scope == .mine { items.append(("isTrashed", "false")) }
        if let developed = predicates.developed { items.append(("isDeveloped", String(developed))) }
        // Filters timeline feeds could not express.
        if let kind = predicates.kind { items.append(("type", kind.rawValue)) }
        if let motion = predicates.motion { items.append(("isMotion", String(motion))) }
        if predicates.people.count > 1 { items.append(("personIds", predicates.people.sorted().joined(separator: ","))) }
        if predicates.albums.count > 1 { items.append(("albumIds", predicates.albums.sorted().joined(separator: ","))) }
        if !predicates.tags.isEmpty { items.append(("tagIds", predicates.tags.sorted().joined(separator: ","))) }
        if let inAnyAlbum = predicates.inAnyAlbum { items.append(("inAnyAlbum", String(inAnyAlbum))) }
        if let rating = predicates.rating { items.append(("rating", String(rating))) }
        if let taken = predicates.taken { items += [("takenAfter", taken.start.ISO8601Format()), ("takenBefore", taken.end.ISO8601Format())] }
        if let make = predicates.camera?.make { items.append(("make", make)) }
        if let model = predicates.camera?.model { items.append(("model", model)) }
        if let country = predicates.location?.country { items.append(("country", country)) }
        if let state = predicates.location?.state { items.append(("state", state)) }
        if let city = predicates.location?.city { items.append(("city", city)) }
        if let text = predicates.text { items.append((text.field.rawValue, text.value)) }
        switch ranking {
        case .relevance(.text(let text, let language)):
            items.append(("query", text))
            if let language { items.append(("language", language)) }
        case .relevance(.similar(let id)): items.append(("similar", id))
        case .chronological: break
        }
        let key = items.map { $0.0 + "=" + Self.escaped($0.1) }.joined(separator: "&")
        guard let membership = predicates.place else { return key }
        return key + "&place=" + Self.escaped(membership.placeID) + "#" + membership.revision
    }

    /// IDs, flags and orders pass unchanged, as they did in the keys before Q5; free text is
    /// escaped so it can't imitate another item.
    private static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// The photos of one place, found from the map markers. The revision follows the photos and the
/// marker query that found them; equality and hashing use only the place and the revision.
struct PlaceMembership: Hashable, Sendable {
    let placeID: String
    let revision: String
    let assetIDs: [String]

    /// The marker query is the query the markers were fetched with, in any stable text form.
    init(placeID: String, assetIDs: [String], markerQuery: String) {
        self.placeID = placeID
        self.assetIDs = assetIDs
        let text = (assetIDs.sorted() + [markerQuery]).joined(separator: "\n")
        revision = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func == (a: PlaceMembership, b: PlaceMembership) -> Bool { a.placeID == b.placeID && a.revision == b.revision }
    func hash(into hasher: inout Hasher) { hasher.combine(placeID); hasher.combine(revision) }
}

/// The Locked Folder's photos. Only the server timeline serves it, and only while the session is
/// elevated; no library query reaches them.
struct LockedFolderQuery: Hashable, Sendable {
    var ascending = false
}

/// How a query is served, and what that backend can't do for it.
struct QueryPlan: Hashable, Sendable {
    enum Backend: Hashable, Sendable { case index, serverTimeline, serverSearch }
    var backend: Backend
    var limitations: Set<Limitation> = []
}

enum Limitation: Hashable, Sendable {
    /// Results come as one list, not by month.
    case noMonths
    /// Search can't collapse stacks, so their other photos appear too.
    case includesStackMembers
    /// Photos others shared through albums are missing.
    case excludesSharedAlbumMembers
    /// The owner filter runs on the phone, after the server answered.
    case ownerPostFilter
    /// The developed filter runs on the phone and gives up after this many results.
    case developedPostFilter(scanBudget: Int)
    /// The offline index last finished syncing at this time.
    case indexStale(since: Date)
}

/// A query no backend can serve right now.
enum Unsupported: Error, Hashable, Sendable {
    /// Places are laid out by month only from a complete offline index.
    case placeNeedsIndex
    /// Server search can't order this way, for example by date added.
    case orderNotSearchable
    /// A filter the chosen backend lacks, by name.
    case predicate(String)
}

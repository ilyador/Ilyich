import Foundation
import IlyichPlatform
import Synchronization

/// One account's collections on the server (REBUILD_ROADMAP.md N4): its albums with their members,
/// roles and shared links, its people, partners and memories, and album comments and likes. Every
/// change the screens make to them goes through here: in read-only mode it is refused before it is
/// sent, it is one call (an album's members are read again after a change to them), and its result
/// goes out on the account's bus as a CollectionChange carrying the server's record, which the
/// shelves, the albums list and the feed apply in place. An album a library mutation made or
/// changed (made from the selected photos, its cover set, photos added or taken out) goes out the
/// same way. The work belongs to the service, so it ends the same whether the screen that asked
/// waits, closes or is gone. AccountRuntime owns it and shuts it down at sign-out.
actor CollectionsService {
    /// The account's bus, where the changes go.
    nonisolated let bus: LibraryBus
    private nonisolated let client: APIClient
    private nonisolated let requests: OwnedRequests
    /// Turns the albums mutations change into collection changes.
    private nonisolated let following = Mutex<Task<Void, Never>?>(nil)

    /// `authorization` says whether read-only mode is on; without it, the client's account flag
    /// does. The service follows the mutations' results on `bus` from the start.
    init(client: APIClient, authorization: AuthorizationState?, bus: LibraryBus) {
        self.client = client
        self.bus = bus
        requests = OwnedRequests { authorization?.snapshot.readOnly ?? client.isReadOnly }
        let applied = bus.subscribe { event -> MutationResult? in
            if case .mutation(.applied(let result)) = event { result } else { nil }
        }
        following.withLock { $0 = Task { [weak self] in for await result in applied { self?.albumsChanged(by: result) } } }
    }

    /// Sign-out: nothing begun here changes anything any more. Changes still running are cancelled
    /// and waited for.
    func shutdown() async {
        following.withLock { $0?.cancel(); $0 = nil }
        await requests.shutdown()
    }

    /// How many changes are on their way.
    nonisolated var runningCount: Int { requests.runningCount }

    // MARK: Albums

    /// The album as the server has it now, which every list showing it takes in too.
    nonisolated func refreshAlbum(_ id: String) async throws -> Album {
        try await read { [self] in
            let album = try await client.album(id: id)
            publish(.albumUpdated(album))
            return album
        }
    }

    nonisolated func createAlbum(name: String, description: String) async throws -> Album {
        try await change { [self] in
            let album: Album = try await client.request(.post, path: "albums", body: AlbumFields(albumName: name, description: description, order: nil))
            publish(.albumCreated(album))
            return album
        }
    }

    /// Changes an album's name, description and, when given, the order of its photos.
    nonisolated func updateAlbum(_ id: String, name: String, description: String, order: String?) async throws -> Album {
        try await change { [self] in
            let album: Album = try await client.request(.patch, path: "albums/\(id)", body: AlbumFields(albumName: name, description: description, order: order))
            publish(.albumUpdated(album))
            return album
        }
    }

    /// Deletes the album for everyone. Its photos stay in the library.
    nonisolated func deleteAlbum(_ id: String) async throws {
        try await change { [self] in
            try await client.deleteAlbum(id: id)
            publish(.albumDeleted(id))
        }
    }

    /// Leaves an album someone else shared with the account.
    nonisolated func leaveAlbum(_ id: String) async throws {
        guard let userID = client.userID else { throw APIError.signedOut }
        try await change { [self] in
            try await client.requestVoid(.delete, path: "albums/\(id)/user/\(userID)")
            publish(.albumLeft(id))
        }
    }

    // MARK: Members and roles

    /// The server's users, who can be asked into an album or shared a library with.
    nonisolated func users() async throws -> [User] {
        try await read { [client] in try await client.request(.get, path: "users") }
    }

    /// Asks `users` into the album with `role`. Returns the album with its members.
    nonisolated func addMembers(_ users: [String], role: String, to album: String) async throws -> Album {
        try await change { [self] in
            let members = AlbumMembers(albumUsers: users.map { AlbumMembers.Member(userId: $0, role: role) })
            try await client.requestVoid(.put, path: "albums/\(album)/users", body: members)
            return try await membersChanged(album)
        }
    }

    /// Makes a member a viewer or an editor. Returns the album with its members.
    nonisolated func setRole(_ role: String, of user: String, in album: String) async throws -> Album {
        try await change { [self] in
            try await client.requestVoid(.put, path: "albums/\(album)/user/\(user)", body: ["role": role])
            return try await membersChanged(album)
        }
    }

    /// Takes a member out of the album. Returns the album with its members.
    nonisolated func removeMember(_ user: String, from album: String) async throws -> Album {
        try await change { [self] in
            try await client.requestVoid(.delete, path: "albums/\(album)/user/\(user)")
            return try await membersChanged(album)
        }
    }

    /// The album read again after its members changed, which every list showing it takes in.
    private nonisolated func membersChanged(_ id: String) async throws -> Album {
        let album = try await client.album(id: id)
        publish(.albumUpdated(album))
        return album
    }

    // MARK: Shared links

    /// All of the account's links, or only those sharing one album.
    nonisolated func sharedLinks(albumID: String? = nil) async throws -> [SharedLink] {
        try await read { [client] in try await client.sharedLinks(albumID: albumID) }
    }

    nonisolated func createLink(_ link: SharedLinkDraft) async throws -> SharedLink {
        try await change { [client] in try await client.request(.post, path: "shared-links", body: link) }
    }

    nonisolated func updateLink(_ id: String, _ update: SharedLinkUpdate) async throws -> SharedLink {
        try await change { [client] in try await client.request(.patch, path: "shared-links/\(id)", body: update) }
    }

    nonisolated func deleteLink(_ id: String) async throws {
        try await change { [client] in try await client.deleteSharedLink(id: id) }
    }

    // MARK: People

    /// Names a person and sets or clears their birthday (yyyy-MM-dd).
    nonisolated func updatePerson(_ id: String, name: String, birthDate: String?) async throws -> Person {
        try await change { [self] in
            let person: Person = try await client.request(.put, path: "people/\(id)", body: PersonFields(name: name, birthDate: birthDate))
            publish(.personUpdated(person))
            return person
        }
    }

    // MARK: Partners

    /// Who shares their library with the account, whom it shares its own with, and the server's
    /// users it could share it with.
    nonisolated func partners() async throws -> PartnerLists {
        try await read { [client] in
            async let received = client.partners(direction: "shared-with")
            async let sent = client.partners(direction: "shared-by")
            async let users: [User] = client.request(.get, path: "users")
            return try await PartnerLists(incoming: received, outgoing: sent, candidates: users)
        }
    }

    /// Shows a partner's photos in the account's timeline, or stops.
    nonisolated func showPartnerInTimeline(_ id: String, _ shown: Bool) async throws {
        try await change { [self] in
            try await client.requestVoid(.put, path: "partners/\(id)", body: ["inTimeline": shown])
            publish(.partnersChanged)
        }
    }

    /// Shares the account's library with a user.
    nonisolated func sharePartner(with user: String) async throws {
        try await change { [self] in
            try await client.requestVoid(.post, path: "partners", body: ["sharedWithId": user])
            publish(.partnersChanged)
        }
    }

    /// Stops sharing the account's library with a partner.
    nonisolated func removePartner(_ id: String) async throws {
        try await change { [self] in
            try await client.requestVoid(.delete, path: "partners/\(id)")
            publish(.partnersChanged)
        }
    }

    // MARK: Memories

    /// Today's memories, or every saved one.
    nonisolated func memories(savedOnly: Bool) async throws -> [Memory] {
        try await read { [client] in
            if savedOnly { return try await client.request(.get, path: "memories", query: [.init(name: "isSaved", value: "true")]) }
            return try await client.memories()
        }
    }

    nonisolated func memory(_ id: String) async throws -> Memory {
        try await read { [client] in try await client.request(.get, path: "memories/\(id)") }
    }

    nonisolated func setMemorySaved(_ id: String, _ saved: Bool) async throws {
        try await change { [self] in
            try await client.requestVoid(.put, path: "memories/\(id)", body: ["isSaved": saved])
            publish(.memorySaved(id, saved: saved))
        }
    }

    // MARK: Album activity

    /// Whether the album takes comments and likes, whether the account owns it, and its activity:
    /// the album's own, or one photo's within it.
    nonisolated func activity(album: String, asset: String?) async throws -> AlbumActivityState {
        try await read { [client] in
            let settings: ActivitySettings = try await client.request(.get, path: "albums/\(album)")
            let owner = settings.albumUsers.contains { $0.user.id == client.userID && $0.role == "owner" }
            guard settings.isActivityEnabled else { return AlbumActivityState(enabled: false, owner: owner, activities: []) }
            var query = [URLQueryItem(name: "albumId", value: album), .init(name: "level", value: asset == nil ? "album" : "asset")]
            if let asset { query.append(.init(name: "assetId", value: asset)) }
            let activities: [AlbumActivity] = try await client.request(.get, path: "activities", query: query)
            return AlbumActivityState(enabled: true, owner: owner, activities: activities)
        }
    }

    nonisolated func comment(_ text: String, album: String, asset: String?) async throws -> AlbumActivity {
        try await change { [client] in
            try await client.request(.post, path: "activities", body: ActivityCreation(albumId: album, assetId: asset, type: "comment", comment: text))
        }
    }

    nonisolated func like(album: String, asset: String?) async throws -> AlbumActivity {
        try await change { [client] in
            try await client.request(.post, path: "activities", body: ActivityCreation(albumId: album, assetId: asset, type: "like", comment: nil))
        }
    }

    /// Takes back a like, or deletes a comment.
    nonisolated func deleteActivity(_ id: String) async throws {
        try await change { [client] in try await client.requestVoid(.delete, path: "activities/\(id)") }
    }

    nonisolated func setActivityEnabled(_ enabled: Bool, album: String) async throws {
        try await change { [client] in try await client.requestVoid(.patch, path: "albums/\(album)", body: ["isActivityEnabled": enabled]) }
    }

    // MARK: Albums a mutation changed

    /// An album made from the selected photos or given a cover comes back with the mutation's
    /// answer; one that gained or lost photos is read again, for its count, cover and dates.
    private nonisolated func albumsChanged(by result: MutationResult) {
        guard !result.succeeded.isEmpty || result.album != nil else { return }
        switch result.request {
        case .createAlbum:
            if let album = result.album { publish(.albumCreated(album)) }
        case .setAlbumCover:
            if let album = result.album { publish(.albumUpdated(album)) }
        case .addToAlbum(let album, _), .removeFromAlbum(let album, _):
            Task { _ = try? await self.refreshAlbum(album) }
        default:
            break
        }
    }

    // MARK: Support

    private nonisolated func change<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await requests.change(work)
    }

    private nonisolated func read<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await requests.read(work)
    }

    /// Every subscriber hears every change in one order. Nothing is published once shutdown has
    /// begun.
    private nonisolated func publish(_ change: CollectionChange) {
        requests.whileOpen { bus.post(.collection(change)) }
    }
}

/// Who shares their library with the account, whom it shares its own with, and who it could
/// share it with.
struct PartnerLists: Sendable {
    let incoming: [Partner]
    let outgoing: [Partner]
    let candidates: [User]
}

/// Whether an album takes comments and likes, whether the account owns it, and its activity.
struct AlbumActivityState: Sendable {
    let enabled: Bool
    let owner: Bool
    let activities: [AlbumActivity]
}

struct AlbumActivity: Decodable, Identifiable, Sendable {
    let id: String
    let assetId: String?
    let comment: String?
    let createdAt: Date
    let type: String
    let user: User
}

/// A new shared link: for an album, or for photos.
struct SharedLinkDraft: Encodable, Sendable {
    let type: String
    let albumId: String?
    let assetIds: [String]?
    let description: String
    let slug: String?
    let expiresAt: Date?
    let password: String?
    let allowDownload: Bool
    let allowUpload: Bool
    let showMetadata: Bool
}

/// A shared link's details as edited. A nil slug or expiry clears it; the password is sent only
/// when it changes, nil clearing it.
struct SharedLinkUpdate: Encodable, Sendable {
    let description: String; let slug: String?; let expiresAt: Date?; let password: String?; let changePassword: Bool
    let allowDownload: Bool; let allowUpload: Bool; let showMetadata: Bool
    enum CodingKeys: String, CodingKey { case description, slug, expiresAt, password, allowDownload, allowUpload, showMetadata }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(description, forKey: .description)
        if let slug { try c.encode(slug, forKey: .slug) } else { try c.encodeNil(forKey: .slug) }
        if let expiresAt { try c.encode(expiresAt, forKey: .expiresAt) } else { try c.encodeNil(forKey: .expiresAt) }
        if changePassword { if let password { try c.encode(password, forKey: .password) } else { try c.encodeNil(forKey: .password) } }
        try c.encode(allowDownload, forKey: .allowDownload); try c.encode(allowUpload, forKey: .allowUpload); try c.encode(showMetadata, forKey: .showMetadata)
    }
}

/// An album's name and description, and its photos' order when it is given.
private struct AlbumFields: Encodable, Sendable {
    let albumName: String
    let description: String
    let order: String?
}

private struct AlbumMembers: Encodable, Sendable {
    struct Member: Encodable, Sendable { let userId: String; let role: String }
    let albumUsers: [Member]
}

/// A person's name, and their birthday or an explicit null that clears it.
private struct PersonFields: Encodable, Sendable {
    let name: String
    let birthDate: String?
    enum CodingKeys: String, CodingKey { case name, birthDate }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        if let birthDate { try values.encode(birthDate, forKey: .birthDate) }
        else { try values.encodeNil(forKey: .birthDate) }
    }
}

private struct ActivitySettings: Decodable, Sendable {
    let isActivityEnabled: Bool
    let albumUsers: [AlbumUser]
}

private struct ActivityCreation: Encodable, Sendable { let albumId: String; let assetId: String?; let type: String; let comment: String? }

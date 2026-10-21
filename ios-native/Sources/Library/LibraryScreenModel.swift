import Foundation

/// What following a link needs from the server when the shelves have not already loaded it.
protocol LinkLookup: Sendable {
    func asset(id: String) async throws -> Asset
    func album(id: String) async throws -> Album
    func person(id: String) async throws -> Person
}

extension APIClient: LinkLookup {}

/// The share inbox, as the library sees it.
@MainActor protocol SharedFilesInbox: AnyObject, Sendable {
    /// The batches waiting, as last read.
    var batchIDs: Set<UUID> { get }
    /// Reads the inbox again, off the main actor.
    func refresh() async
}

/// What a link opens. An album or person the shelves already hold is used as it is, which spares
/// fetching an album with all its photos; anything else is looked up on the server.
struct DeepLinkResolver: Sendable {
    let lookup: any LinkLookup

    func intent(for link: AppLink, albums: [Album], people: [Person]) async throws -> NavigationIntent {
        switch link {
        case .asset(let id, let albumID):
            let asset = try await lookup.asset(id: id)
            if let albumID { _ = try await album(albumID, in: albums) }
            return .openAsset(asset, albumContext: albumID)
        case .album(let id):
            return .showAlbum(try await album(id, in: albums))
        case .person(let id):
            if let person = people.first(where: { $0.id == id }) { return .showPerson(person) }
            return .showPerson(try await lookup.person(id: id))
        case .memory(let id):
            return .present(.memories(initialID: id))
        case .activity(let albumID):
            _ = try await album(albumID, in: albums)
            return .present(.activity(album: albumID, asset: nil))
        case .sharedFiles:
            return .present(.sharedFiles)
        }
    }

    private func album(_ id: String, in albums: [Album]) async throws -> Album {
        if let album = albums.first(where: { $0.id == id }) { return album }
        return try await lookup.album(id: id)
    }
}

/// The library screen's own work beside its feed: what is presented over it, following links,
/// showing new shared files at a quiet moment, and warming up the Earth.
@MainActor @Observable final class LibraryScreenModel {
    let navigator = LibraryNavigator()
    @ObservationIgnored private let resolver: DeepLinkResolver
    @ObservationIgnored private let inbox: any SharedFilesInbox
    /// Batches Shared files has already been shown for.
    @ObservationIgnored private var seenShareBatches = Set<UUID>()
    @ObservationIgnored private var following: (token: UUID, task: Task<Void, Never>)?
    /// Where links come from, and the albums and people the shelves hold when one arrives.
    @ObservationIgnored private var links: (session: AccountSession, shelves: @MainActor () -> (albums: [Album], people: [Person]))?
    @ObservationIgnored private var inboxRead: Task<Void, Never>?
    @ObservationIgnored private var warmUp: Task<Void, Never>?

    init(lookup: any LinkLookup, inbox: any SharedFilesInbox) {
        resolver = DeepLinkResolver(lookup: lookup)
        self.inbox = inbox
    }

    isolated deinit {
        following?.task.cancel()
        inboxRead?.cancel()
        warmUp?.cancel()
    }

    /// Builds the Earth off the main thread a little after launch, so it is ready before anyone
    /// opens it, rather than while a finger crosses Places on the shelves.
    func start() {
        guard warmUp == nil else { return }
        warmUp = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await PlacesGlobeView.prepare()
        }
    }

    /// Follows every link the app opens while this library is up. The session is watched here
    /// rather than from the screen: while a full-screen viewer covers the library, SwiftUI does
    /// not update the screen for a link that arrives from outside, so it would wait for the viewer
    /// to close by hand.
    func takeLinks(from session: AccountSession, shelves: @escaping @MainActor () -> (albums: [Album], people: [Person])) {
        guard links == nil else { return }
        links = (session, shelves)
        takeLink()
    }

    private func takeLink() {
        guard let (session, shelves) = links else { return }
        withObservationTracking { _ = session.pendingLink } onChange: { [weak self] in
            Task { @MainActor in self?.takeLink() }
        }
        guard let link = session.pendingLink else { return }
        session.pendingLink = nil
        let lists = shelves()
        follow(link, albums: lists.albums, people: lists.people)
    }

    /// Follows a link. Everything over the library closes at once, and the link's photo, filter
    /// or screen opens when it has been looked up. A newer link, or anything opened meanwhile,
    /// overtakes it; a link that can't be followed says why.
    func follow(_ link: AppLink, albums: [Album], people: [Person]) {
        following?.task.cancel()
        let token = UUID()
        navigator.beginLink()
        let generation = navigator.unwind()
        let task = Task { [weak self, resolver, inbox] in
            var intent: NavigationIntent
            do {
                // The share extension opens this link right after writing its batch.
                if link == .sharedFiles { await inbox.refresh() }
                intent = try await resolver.intent(for: link, albums: albums, people: people)
            } catch {
                intent = .alert(.error(error.localizedDescription))
            }
            guard let self else { return }
            if self.following?.token == token {
                self.following = nil
                self.navigator.endLink()
            }
            guard !Task.isCancelled, self.navigator.generation == generation else { return }
            if link == .sharedFiles { self.seenShareBatches.formUnion(inbox.batchIDs) }
            self.navigator.send(intent)
        }
        following = (token, task)
    }

    /// Reads the share inbox again. Batches that arrived since Shared files was last shown open
    /// it once nothing else is presented or covering the grid.
    func refreshSharedFiles() {
        inboxRead?.cancel()
        inboxRead = Task { [weak self, inbox] in
            await inbox.refresh()
            guard let self, !Task.isCancelled else { return }
            self.presentNewSharedFiles()
        }
    }

    private func presentNewSharedFiles() {
        let ids = inbox.batchIDs
        seenShareBatches.formIntersection(ids)
        guard !ids.subtracting(seenShareBatches).isEmpty else { return }
        seenShareBatches.formUnion(ids)
        navigator.presentWhenIdle(.sharedFiles)
    }
}

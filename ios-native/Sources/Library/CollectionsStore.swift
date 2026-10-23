import Foundation

/// What the shelves show of the account's collections (REBUILD_ROADMAP.md F5, N4): its people, its
/// albums, the server's features and the order the owner gave people and albums. The three loads
/// run together and each applies as it lands. The newest load wins: a slower, older load can't
/// put back what a newer one changed. The store follows the account's bus: a collection change
/// (an album made, renamed, given photos or a cover, deleted or left, a person renamed) applies in
/// place at once, and is applied again over the albums of a load that was on its way when it
/// happened, since the server may have answered before it: no load drops an album made meanwhile,
/// brings back one left or puts back an old name. A sync change to albums, people, partners,
/// memories or the server's configuration, or one that resets or overflows, loads again. A load
/// that fails keeps what the shelves show, and is tried again when the app comes forward or the
/// shelves open.
@MainActor @Observable final class CollectionsStore {
    private(set) var people: [Person] = [] { didSet { orderPeople() } }
    private(set) var albums: [Album] = [] { didSet { orderAlbums() } }
    private(set) var features: ServerFeatures?
    private(set) var peopleOrder: [String] = [] { didSet { orderPeople() } }
    private(set) var albumOrder: [String] = [] { didSet { orderAlbums() } }
    /// The people and albums in the owner's order. They are put in it when they or the order
    /// change, not when they are read: the shelves read them on every touch of a drag, at every
    /// level of the shelves.
    private(set) var orderedPeople: [Person] = []
    private(set) var orderedAlbums: [Album] = []
    /// The last load left people, albums or features unloaded.
    private(set) var lastLoadFailed = false
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let directory: PeopleDirectory
    @ObservationIgnored private let order: ShelfOrder
    @ObservationIgnored private let pipeline: MediaPipeline?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// The collection changes since the newest load began, in order, which its answer may not know of.
    @ObservationIgnored private var changes: [CollectionChange] = []
    @ObservationIgnored private let follower = LibraryFollower()

    /// `pipeline` warms the faces of the People shelf once they are known.
    init(api: APIClient, people: PeopleDirectory, order: ShelfOrder, pipeline: MediaPipeline? = nil) {
        self.api = api; directory = people; self.order = order; self.pipeline = pipeline
    }

    /// Follows the account's bus from now on: its collection changes apply in place, and the sync
    /// changes that touch what the shelves show load them again.
    func follow(_ bus: LibraryBus?) {
        follower.follow(bus) { [weak self] event in self?.libraryEvent(event) }
    }

    private func libraryEvent(_ event: LibraryEvent) {
        switch event {
        case .collection(let change): apply(change)
        case .changed(let change, _): if change.reloadsCollections { reload() }
        case .mutation, .cachesCleared: break
        }
    }

    /// Loads people, albums and features together, each shown as it lands. A load started after
    /// this one wins over whatever this one brings late.
    func load() async {
        let token = UUID()
        generation = token
        // Only the collection changes made while this load is on its way are applied again over
        // its albums and people; the server held the earlier ones before it was asked.
        changes = []
        peopleOrder = order.ids(.people); albumOrder = order.ids(.albums)
        async let featuresResult = try? api.serverFeatures()
        async let albumResult = try? api.albums()
        async let peopleResult = try? directory.allVisible()
        let loadedFeatures = await featuresResult
        if let loadedFeatures, token == generation { features = loadedFeatures }
        let loadedAlbums = await albumResult
        if let loadedAlbums, token == generation { albums = Self.applying(changes, to: loadedAlbums) }
        let loadedPeople = await peopleResult
        guard token == generation else { return }
        if let loadedPeople { people = Self.applying(changes, to: loadedPeople) }
        lastLoadFailed = loadedFeatures == nil || loadedAlbums == nil || loadedPeople == nil
        // A scrub flies past every face in a second, so they all load before the shelf is opened.
        if loadedPeople != nil, let pipeline {
            let faces = orderedPeople
            Task { await pipeline.warmFaces(faces, pixelSize: PersonThumbnail.small) }
        }
    }

    /// Loads again after a failure, as when the app comes forward or the shelves open.
    func reloadIfFailed() {
        guard lastLoadFailed, retry == nil else { return }
        retry = Task { [weak self] in
            await self?.load()
            self?.retry = nil
        }
    }

    /// Loads again because the library changed. A newer change's load wins over it.
    private func reload() {
        Task { [weak self] in await self?.load() }
    }

    /// Moves a row of the People or Albums shelf and keeps the order. False when nothing moved.
    @discardableResult
    func moveRow(from: Int, to: Int, of kind: ShelfOrder.Kind) -> Bool {
        var ids = kind == .people ? orderedPeople.map(\.id) : orderedAlbums.map(\.id)
        guard from != to, ids.indices.contains(from), ids.indices.contains(to) else { return false }
        ids.insert(ids.remove(at: from), at: to)
        saveOrder(ids, for: kind)
        return true
    }

    func saveOrder(_ ids: [String], for kind: ShelfOrder.Kind) {
        switch kind {
        case .people: peopleOrder = ids
        case .albums: albumOrder = ids
        }
        order.save(ids, for: kind)
    }

    private func orderPeople() { orderedPeople = ShelfOrder.apply(peopleOrder, to: people, id: \.id) }
    private func orderAlbums() { orderedAlbums = ShelfOrder.apply(albumOrder, to: albums, id: \.id) }

    /// A collection change, applied in place at once and again over the answer of a load on its
    /// way. An album made here leads the shelf, as it leads the server's list and the owner's
    /// order; an album changed keeps its place; one deleted or left goes.
    func apply(_ change: CollectionChange) {
        switch change {
        case .albumCreated, .albumUpdated, .albumDeleted, .albumLeft:
            changes.append(change)
            albums = Self.applying([change], to: albums)
            if case .albumCreated(let album) = change, !albumOrder.isEmpty {
                saveOrder([album.id] + albumOrder.filter { $0 != album.id }, for: .albums)
            }
        case .personUpdated:
            changes.append(change)
            people = Self.applying([change], to: people)
        case .partnersChanged, .memorySaved:
            break
        }
    }

    /// An album made here leads the shelf.
    func albumCreated(_ album: Album) { apply(.albumCreated(album)) }

    /// An album left or deleted goes from the shelf at once.
    func albumRemoved(_ id: String) { apply(.albumLeft(id)) }

    /// `albums` with `changes` applied in order: an album made leads, one changed keeps its place,
    /// one deleted or left goes.
    static func applying(_ changes: [CollectionChange], to albums: [Album]) -> [Album] {
        var albums = albums
        for change in changes {
            switch change {
            case .albumCreated(let album):
                albums.removeAll { $0.id == album.id }
                albums.insert(album, at: 0)
            case .albumUpdated(let album):
                if let index = albums.firstIndex(where: { $0.id == album.id }) { albums[index] = album }
            case .albumDeleted(let id), .albumLeft(let id):
                albums.removeAll { $0.id == id }
            case .personUpdated, .partnersChanged, .memorySaved:
                break
            }
        }
        return albums
    }

    /// `people` with `changes` applied in order: a person renamed keeps their place.
    static func applying(_ changes: [CollectionChange], to people: [Person]) -> [Person] {
        var people = people
        for case .personUpdated(let person) in changes {
            if let index = people.firstIndex(where: { $0.id == person.id }) { people[index] = person }
        }
        return people
    }
}

extension LibraryChange {
    /// What the shelves show may have changed: albums, people, partners, memories or the server's
    /// configuration, or everything, after a reset or an overflow.
    var reloadsCollections: Bool {
        !albums.isEmpty || !people.isEmpty || partnersChanged || memoriesChanged || configurationChanged || reset || overflow
    }
}

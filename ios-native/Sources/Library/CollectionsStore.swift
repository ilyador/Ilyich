import Foundation

/// What the shelves show of the account's collections (REBUILD_ROADMAP.md F5): its people, its
/// albums, the server's features and the order the owner gave people and albums. The three loads
/// run together and each applies as it lands. The newest load wins: a slower, older load can't
/// put back what a newer one changed, such as an album made meanwhile. A load that fails keeps
/// what the shelves show, and is tried again when the app comes forward or the shelves open; a
/// collection change loads again.
@MainActor @Observable final class CollectionsStore {
    private(set) var people: [Person] = []
    private(set) var albums: [Album] = []
    private(set) var features: ServerFeatures?
    private(set) var peopleOrder: [String] = []
    private(set) var albumOrder: [String] = []
    /// The last load left people, albums or features unloaded.
    private(set) var lastLoadFailed = false
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let directory: PeopleDirectory
    @ObservationIgnored private let order: ShelfOrder
    @ObservationIgnored private let pipeline: MediaPipeline?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var retry: Task<Void, Never>?

    var orderedPeople: [Person] { ShelfOrder.apply(peopleOrder, to: people, id: \.id) }
    var orderedAlbums: [Album] { ShelfOrder.apply(albumOrder, to: albums, id: \.id) }

    /// `pipeline` warms the faces of the People shelf once they are known.
    init(api: APIClient, people: PeopleDirectory, order: ShelfOrder, pipeline: MediaPipeline? = nil) {
        self.api = api; directory = people; self.order = order; self.pipeline = pipeline
    }

    /// Loads people, albums and features together, each shown as it lands. A load started after
    /// this one wins over whatever this one brings late.
    func load() async {
        let token = UUID()
        generation = token
        peopleOrder = order.ids(.people); albumOrder = order.ids(.albums)
        async let featuresResult = try? api.serverFeatures()
        async let albumResult = try? api.albums()
        async let peopleResult = try? directory.allVisible()
        let loadedFeatures = await featuresResult
        if let loadedFeatures, token == generation { features = loadedFeatures }
        let loadedAlbums = await albumResult
        if let loadedAlbums, token == generation { albums = loadedAlbums }
        let loadedPeople = await peopleResult
        guard token == generation else { return }
        if let loadedPeople { people = loadedPeople }
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

    /// An album made here leads the shelf, as it leads the server's list and the owner's order.
    func albumCreated(_ album: Album) {
        albums.removeAll { $0.id == album.id }
        albums.insert(album, at: 0)
        if !albumOrder.isEmpty { saveOrder([album.id] + albumOrder.filter { $0 != album.id }, for: .albums) }
    }

    /// An album left or deleted goes from the shelf at once.
    func albumRemoved(_ id: String) { albums.removeAll { $0.id == id } }
}

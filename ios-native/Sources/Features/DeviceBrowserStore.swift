import Foundation
import Observation
import Photos

/// The photos On this phone shows, read from the Photos adapter a page at a time, newest first.
/// While shown it follows the adapter's changes: a change to photos already read re-reads only
/// their pages, a removal of photos not yet read only moves the count, and anything else reads
/// the pages already shown again. Every read runs off the main thread.
@MainActor @Observable final class DeviceBrowserStore {
    static let pageSize = 240
    /// How close to the end of what is read a shown photo asks for the next page.
    static let prefetchDistance = 60

    private(set) var photos: [LocalPhoto] = []
    private(set) var albums: [DeviceAlbum] = []
    private(set) var permission: PHAuthorizationStatus
    private(set) var total = 0
    var albumID = ""

    @ObservationIgnored private let browser: any DeviceBrowsing
    @ObservationIgnored private var query: DevicePhotoQuery?
    @ObservationIgnored private var pages: [[LocalPhoto]] = []
    @ObservationIgnored private var pageOf: [String: Int] = [:]
    @ObservationIgnored private var nearEnd: Set<String> = []
    @ObservationIgnored private var changes: Task<Void, Never>?
    @ObservationIgnored private var albumRead: Task<Void, Never>?
    /// Moves with every reading that replaces the pages, so an older one never lands after it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadingMore = false

    init(browser: any DeviceBrowsing = PhotoKitAdapter.shared) {
        self.browser = browser
        permission = browser.authorization
    }

    /// Follows the library's changes until `stop`, and reads it again.
    func start() async {
        if changes == nil {
            let stream = browser.changes()
            changes = Task { [weak self] in
                for await change in stream { await self?.apply(change) }
            }
        }
        await refresh()
    }

    func stop() {
        changes?.cancel(); changes = nil
        albumRead?.cancel(); albumRead = nil
        generation += 1
    }

    func requestAccess() async {
        permission = await browser.requestAccess().status
        await start()
    }

    /// Shows the chosen album from its first page.
    func selectAlbum() async {
        await refresh(keeping: 1)
    }

    /// Reads the next page.
    func loadMore() async {
        guard let query, !loadingMore, photos.count < query.count else { return }
        loadingMore = true; defer { loadingMore = false }
        let current = generation, start = pages.count * Self.pageSize
        let next = await browser.photos(query, in: start..<min(start + Self.pageSize, query.count))
        guard current == generation, pages.count * Self.pageSize == start, !next.isEmpty else { return }
        pages.append(next)
        publish()
    }

    /// Whether `id` is close enough to the end of what is read to read the next page.
    func isNearEnd(_ id: String) -> Bool { nearEnd.contains(id) }

    /// Reads access, the albums and the pages shown again: at least `keeping` pages, or as many as
    /// are shown when nil.
    func refresh(keeping: Int? = nil) async {
        generation += 1
        let current = generation
        permission = browser.authorization
        guard PhotoKitAdapter.canRead(permission) else {
            query = nil; pages = []; albums = []; total = 0; publish(); return
        }
        readAlbums()
        let query = await browser.query(album: albumID)
        guard current == generation else { return }
        let shown = max(1, keeping ?? pages.count) * Self.pageSize
        let read = await browser.photos(query, in: 0..<min(shown, query.count))
        guard current == generation else { return }
        commit(query, photos: read)
    }

    /// Applies one burst of library changes.
    func apply(_ change: DeviceLibraryChange) async {
        if change.access.status != permission || change.requiresFullReload || (change.albumsChanged && !albumID.isEmpty) {
            await refresh(); return
        }
        if change.albumsChanged { readAlbums() }
        guard let old = query else { return }
        let removedShown = change.removed.contains { pageOf[$0.rawValue] != nil }
        let changedPages = Set(change.changed.compactMap { pageOf[$0.rawValue] })
        guard !change.inserted.isEmpty || !change.removed.isEmpty || !changedPages.isEmpty else { return }

        generation += 1
        let current = generation
        let query = await browser.query(album: albumID)
        guard current == generation else { return }
        // A photo added or one shown removed moves every page after it.
        if !change.inserted.isEmpty || removedShown {
            let read = await browser.photos(query, in: 0..<min(pages.count * Self.pageSize, query.count))
            guard current == generation else { return }
            commit(query, photos: read); return
        }
        // Only photos not yet read were removed: the pages read stay as they are.
        if old.count != query.count, pages.count * Self.pageSize > query.count {
            await refresh(); return
        }
        var updated = pages
        for page in changedPages.sorted() {
            let range = page * Self.pageSize..<min((page + 1) * Self.pageSize, query.count)
            let read = await browser.photos(query, in: range)
            guard current == generation else { return }
            // A change that moved a photo to another page, as a new date would, reads them all again.
            guard Set(read.map(\.id)) == Set(pages[page].map(\.id)) else { await refresh(); return }
            updated[page] = read
        }
        self.query = query; pages = updated
        publish()
    }

    private func commit(_ query: DevicePhotoQuery, photos read: [LocalPhoto]) {
        self.query = query
        pages = stride(from: 0, to: read.count, by: Self.pageSize).map { Array(read[$0..<min($0 + Self.pageSize, read.count)]) }
        publish()
    }

    private func publish() {
        let all = Array(pages.joined())
        var index: [String: Int] = [:]
        for (number, page) in pages.enumerated() { for photo in page { index[photo.id] = number } }
        pageOf = index
        nearEnd = Set(all.suffix(Self.prefetchDistance).map(\.id))
        total = query?.count ?? 0
        if photos != all { photos = all }
    }

    private func readAlbums() {
        albumRead?.cancel()
        albumRead = Task { [weak self, browser] in
            let albums = await browser.albums()
            guard !Task.isCancelled, let self else { return }
            self.albums = albums
        }
    }
}

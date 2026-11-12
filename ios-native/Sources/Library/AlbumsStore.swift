import Foundation

protocol AlbumSource: Sendable {
    func cachedAlbums() async throws -> [Album]?
    func albumListing() async throws -> CollectionListing<Album>
}

extension APIClient: AlbumSource {}

/// The album browser keeps its last answer during refresh and reads the saved account index
/// before contacting the server. Only a successful server response may empty an existing list.
@MainActor @Observable final class AlbumsStore {
    private(set) var albums: [Album] = []
    private(set) var isLoading = false
    private(set) var hasSnapshot = false
    private(set) var isOffline = false
    private(set) var failure: String?
    @ObservationIgnored private let source: any AlbumSource
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var changes: [CollectionChange] = []

    init(source: any AlbumSource) { self.source = source }

    func load() async {
        let token = UUID(); generation = token
        let earlierChanges = changes.count
        isLoading = true; failure = nil; isOffline = false
        defer { if generation == token { isLoading = false } }
        if !hasSnapshot, let saved = try? await source.cachedAlbums() {
            guard generation == token, !Task.isCancelled else { return }
            albums = CollectionsStore.applying(changes, to: saved); hasSnapshot = true
        }
        do {
            let result = try await source.albumListing()
            try Task.checkCancellation()
            guard generation == token else { return }
            if result.isOffline {
                if albums.isEmpty { albums = CollectionsStore.applying(changes, to: result.items) }
            } else {
                // The server knows changes confirmed before this request, but not necessarily
                // ones made while it was on its way. Failed/offline reads keep their overlay.
                changes = Array(changes.dropFirst(earlierChanges))
                albums = CollectionsStore.applying(changes, to: result.items)
            }
            hasSnapshot = true; isOffline = result.isOffline
        } catch is CancellationError {
        } catch {
            guard generation == token else { return }
            if CollectionFailure.clearsSavedContent(error) { albums = []; hasSnapshot = false }
            isOffline = CollectionFailure.isOffline(error)
            failure = error.localizedDescription
        }
    }

    func apply(_ change: CollectionChange) {
        changes.append(change)
        albums = CollectionsStore.applying([change], to: albums)
        if !albums.isEmpty { hasSnapshot = true }
    }

    func invalidateSavedContent() {
        generation = UUID(); albums = []; changes = []; hasSnapshot = false; isLoading = false; isOffline = false
    }
}

import SwiftUI

struct AlbumAssetsManager: View {
    enum Mode { case add, remove, cover }
    let api: APIClient
    let pipeline: MediaPipeline
    let album: Album
    let mode: Mode
    let onSaved: (Album) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mutations) private var mutations
    @Environment(\.collectionsService) private var collections
    @State private var assets: [Asset] = []
    @State private var buckets: [TimeBucket] = []
    @State private var nextBucket = 0
    @State private var selection = Set<String>()
    @State private var source = "timeline"
    @State private var generation = UUID()
    @State private var loading = false
    @State private var loaded = false
    @State private var busy = false
    @State private var confirmRemove = false
    @State private var failure: FeatureFailure?
    @State private var notice: String?

    private var title: String { switch mode { case .add: "Add photos"; case .remove: "Remove photos"; case .cover: "Choose cover" } }
    private var action: String { switch mode { case .add: "Add"; case .remove: "Remove"; case .cover: "Set cover" } }
    /// Every photo on its own, stacks opened: the account's timeline or archive to add from, or the
    /// album's photos in its order. Read from the server timeline, as this screen always has.
    private var query: LibraryQuery {
        var query: LibraryQuery
        if mode == .add { query = source == "archive" ? .archive : .library; query.scope = .mine }
        else { query = .album(album.id, ascending: album.order == "asc"); query.visibility = [.timeline, .archive] }
        query.stacks = .all
        return query
    }
    private var timeline: ServerTimelineRequest {
        get throws { try ServerTimelineRequest(query, userID: api.userID) }
    }
    var body: some View {
        ScrollView {
            AlbumUploadStatusView(albumID: album.id) { Task { await refreshAlbum() } }.padding(.horizontal, 20)
            if mode == .add {
                Picker("Choose from", selection: $source) { Text("Library").tag("timeline"); Text("Archive").tag("archive") }.pickerStyle(.segmented).padding()
                NavigationLink {
                    LocalLibraryView(destinationAlbumID: album.id, destinationAlbumName: album.albumName, onBackupFinished: { Task { await refreshAlbum() } })
                } label: { Label("Upload from this phone", systemImage: "icloud.and.arrow.up") }.buttonStyle(.bordered).requiresWriteAccess().padding(.bottom, 12)
            }
            if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary).padding() }
            if loaded && !loading && assets.isEmpty { FeatureEmpty(title: "No photos here", symbol: "photo.on.rectangle", description: mode == .add ? "Try another collection." : "This album has no photos or videos.") }
            LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(assets) { asset in
                    Button { select(asset.id) } label: {
                        ZStack(alignment: .bottomTrailing) {
                            FeatureAssetImage(pipeline: pipeline, asset: asset).aspectRatio(1, contentMode: .fit)
                            if asset.isVideo { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
                            Image(systemName: selection.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3).symbolRenderingMode(.palette).foregroundStyle(selection.contains(asset.id) ? Color.accentColor : Color.white, Color.black.opacity(0.45)).padding(7)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(asset.displayName).accessibilityAddTraits(selection.contains(asset.id) ? .isSelected : [])
                }
            }
            if loading { ProgressView().padding(24) }
            else if nextBucket < buckets.count { Button("Load more") { Task { await loadNext(generation: generation) } }.padding(24) }
        }.navigationTitle(title)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty { Text(mode == .cover ? "1 cover selected" : "\(selection.count.formatted()) selected").font(.subheadline).padding(.horizontal, 24).padding(.vertical, 12).glassEffect().padding(.bottom, 8) }
        }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(action) { if mode == .remove { confirmRemove = true } else { Task { await save() } } }.disabled(selection.isEmpty || busy || loading).requiresWriteAccess() } }
        .disabled(busy)
        .task(id: source) { await reload() }
        .confirmationDialog("Remove \(selection.count) items from this album?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove from album", role: .destructive) { Task { await save() } }.requiresWriteAccess()
        } message: { Text("The photos and videos will stay in your library.") }
        .alert("Couldn’t update album", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    /// After an upload into the album: the album read again, here and in every list showing it.
    private func refreshAlbum() async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        do { onSaved(try await collections.refreshAlbum(album.id)) } catch is CancellationError { } catch { failure = .init(error) }
    }
    private func select(_ id: String) {
        if mode == .cover { selection = selection.contains(id) ? [] : [id] }
        else if !selection.insert(id).inserted { selection.remove(id) }
    }
    private func reload() async {
        let token = UUID(); generation = token
        selection = []; assets = []; buckets = []; nextBucket = 0; loading = true; loaded = false; notice = nil
        do {
            let result = try await api.timeBuckets(try timeline)
            try Task.checkCancellation(); guard generation == token else { return }
            buckets = result; loading = false; loaded = true
            await loadNext(generation: token)
        } catch is CancellationError { if generation == token { loading = false } }
        catch { if generation == token { loading = false; loaded = true; failure = .init(error) } }
    }
    private func loadNext(generation token: UUID) async {
        guard generation == token, !loading, nextBucket < buckets.count else { return }
        loading = true
        defer { if generation == token { loading = false } }
        do {
            let page = try await api.timeBucket(buckets[nextBucket].timeBucket, of: try timeline)
            try Task.checkCancellation(); guard generation == token else { return }
            let existing = Set(assets.map(\.id))
            assets.append(contentsOf: page.filter { !existing.contains($0.id) }); nextBucket += 1
        } catch is CancellationError { } catch { if generation == token { failure = .init(error) } }
    }
    /// The album's photos change through the account's mutations, whose sync reconciles the
    /// album's feed; the account's collections read the album again for the shelves and lists.
    private func save() async {
        guard !selection.isEmpty, !busy else { return }
        guard let mutations else { failure = .init(APIError.signedOut); return }
        busy = true; defer { busy = false }
        let requested = selection
        let records = assets.filter { requested.contains($0.id) }
        do {
            if mode == .cover {
                guard let id = requested.first else { return }
                let result = try await mutations.start(.setAlbumCover(album: album.id, asset: id), on: records).result
                if let updated = result.album { onSaved(updated) }
                dismiss(); return
            }
            // In the grid's order; anything selected that the grid no longer holds goes last.
            let shown = assets.map(\.id).filter(requested.contains)
            let ids = shown + requested.subtracting(shown)
            let request: MutationRequest = mode == .add ? .addToAlbum(album: album.id, assets: ids) : .removeFromAlbum(album: album.id, assets: ids)
            let accepted = Set(try await mutations.start(request, on: records).result.succeeded).intersection(requested)
            selection.subtract(accepted)
            if mode == .remove { assets.removeAll { accepted.contains($0.id) } }
            let updated = try await api.album(id: album.id)
            onSaved(updated)
            if selection.isEmpty { dismiss() }
            else { notice = "\(accepted.count) of \(requested.count) items updated."; throw APIError.invalidResponse("\(selection.count) selected items could not be updated. They may no longer be available or you may not have permission to change them.") }
        } catch { failure = .init(error) }
    }
}

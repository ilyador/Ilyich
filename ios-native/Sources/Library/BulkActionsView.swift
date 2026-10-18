import SwiftUI

struct BulkActionsView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let assets: [Asset]
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [Album] = []
    @State private var share: BulkExport?
    @State private var publicLink = false
    @State private var failure: String?
    @State private var busy = false
    @State private var progress = 0
    @State private var operation: Task<Void, Never>?
    @State private var confirmTrash = false
    @State private var features: ServerFeatures?
    private var ids: [String] { assets.map(\.id) }
    @State private var featuresFailure: String?
    private var owned: Bool {
        guard let userID = api.userID, !assets.isEmpty else { return false }
        return assets.allSatisfy { $0.ownerId == userID }
    }
    private var favorites: Bool { assets.allSatisfy(\.isFavorite) }
    private var archived: Bool { assets.allSatisfy { $0.visibility == .archive } }
    private var writableAlbums: [Album] { albums.filter { $0.albumUsers?.contains(where: { $0.user.id == api.userID && ["owner", "editor"].contains($0.role) }) == true } }

    var body: some View {
        List {
            shareSection
            albumSection
            if owned { organizeSection }
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
            if busy { Section { HStack { ProgressView(); Text(progress > 0 ? "Prepared \(progress) of \(assets.count)" : "Working…") } } }
        }
        .navigationTitle("\(assets.count) selected").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .disabled(busy)
        .overlay(alignment: .bottom) {
            if busy { Button("Cancel") { operation?.cancel() }.buttonStyle(.glass).padding().disabled(false) }
        }
        .task { albums = (try? await api.albums()) ?? []; await loadFeatures() }
        .onDisappear { operation?.cancel() }
        .sheet(item: $share, onDismiss: { share?.clean(); share = nil }) { item in
            BulkShareSheet(urls: item.files).onDisappear { item.clean() }
        }
        .sheet(isPresented: $publicLink) { NavigationStack { SharedLinkEditor(api: api, album: nil, assetIDs: ids) } }
        .confirmationDialog(features?.trash == false ? "Permanently delete \(assets.count) items?" : "Move \(assets.count) items to Trash?", isPresented: $confirmTrash) {
            Button(features?.trash == false ? "Delete permanently" : "Move to Trash", role: .destructive) {
                run { try await api.trashAssets(ids: ids, permanently: features?.trash == false) }
            }
        } message: { Text(features?.trash == false ? "This cannot be undone." : "Photos on your phone are kept.") }
    }
    private var shareSection: some View {
        Section("Share") {
            Button("Share displayed versions", systemImage: "square.and.arrow.up") { prepareShare(original: false) }
            Button("Share originals", systemImage: "doc") { prepareShare(original: true) }
            Button("Create shared link", systemImage: "link") { publicLink = true }.requiresWriteAccess(api)
        }
    }
    private var albumSection: some View {
        Section("Albums") {
            Menu("Add to album") {
                ForEach(writableAlbums) { album in Button(album.albumName) { add(to: album) } }
            }.disabled(writableAlbums.isEmpty).requiresWriteAccess(api)
        }
    }
    private var organizeSection: some View {
        Section("Organize") {
            Button(favorites ? "Remove favorites" : "Favorite", systemImage: "heart") { update(.init(ids: ids, isFavorite: !favorites)) }
            Button(archived ? "Unarchive" : "Archive", systemImage: "archivebox") { update(.init(ids: ids, visibility: archived ? .timeline : .archive)) }
            Button("Move to Locked Folder", systemImage: "lock") { update(.init(ids: ids, visibility: .locked)) }
            if assets.count > 1 { Button("Stack photos", systemImage: "square.stack.3d.up", action: stack) }
            Button(features?.trash == false ? "Delete permanently" : "Move to Trash", systemImage: "trash", role: .destructive) { confirmTrash = true }
                .disabled(features == nil)
            if features == nil, let featuresFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn’t check whether Trash is available, so delete is unavailable. \(featuresFailure)").font(.footnote).foregroundStyle(.secondary)
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await loadFeatures() } }
                }
            }
        }.requiresWriteAccess(api)
    }
    private func loadFeatures() async {
        featuresFailure = nil
        do { let loaded = try await api.serverFeatures(); try Task.checkCancellation(); features = loaded }
        catch is CancellationError { }
        catch { featuresFailure = error.localizedDescription }
    }
    private func add(to album: Album) { run {
        let result = try await api.addToAlbum(id: album.id, assetIDs: ids)
        guard result.allSatisfy({ $0.success || $0.error == "duplicate" }) else { throw APIError.invalidResponse("Some photos could not be added. Refresh the album and try again.") }
    } }
    private func stack() { run { let _: AssetStack = try await api.request(.post, path: "stacks", body: ["assetIds": ids]) } }
    private func update(_ body: SelectionUpdate) { run {
        try await api.requestVoid(.put, path: "assets", body: body)
        if body.visibility == .locked {
            await pipeline.removeAll()
            await TimelineCache.shared.removeAll(scope: api.cacheScope)
        }
    } }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; failure = nil
        operation = Task {
            defer { busy = false }
            do { try await action(); onChanged(); dismiss() }
            catch is CancellationError { } catch { failure = error.localizedDescription }
        }
    }
    private func prepareShare(original: Bool) {
        busy = true; failure = nil; progress = 0
        operation = Task {
            defer { busy = false }
            var files: [URL] = []
            do {
                for asset in assets {
                    try Task.checkCancellation()
                    files.append(try await api.download(asset: asset, original: original)); progress += 1
                }
                try Task.checkCancellation(); share = BulkExport(files: files)
            } catch {
                BulkExport(files: files).clean()
                if !(error is CancellationError) { failure = error.localizedDescription }
            }
        }
    }
}

struct SelectionUpdate: Encodable, Sendable {
    let ids: [String]
    var isFavorite: Bool?
    var visibility: AssetVisibility?
}
private struct BulkExport: Identifiable {
    let id = UUID()
    let files: [URL]
    func clean() { for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
}
private struct BulkShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

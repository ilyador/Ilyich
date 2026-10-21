import SwiftUI

struct BulkActionsView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let assets: [Asset]
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [Album] = []
    @State private var share: ExportedFiles?
    @State private var publicLink = false
    @State private var failure: String?
    /// A change to the selection is running; exports keep their own state.
    @State private var busy = false
    /// Share files and Save to Photos.
    @State private var exports: ExportTracker
    @AppStorage("shareFileType") private var shareFileType = "original"
    @State private var operation: Task<Void, Never>?
    @State private var confirmTrash = false
    @State private var features: ServerFeatures?
    /// What every selected photo allows, worked out when the list appears and when the server's
    /// features arrive, not on each redraw: the list redraws with every step of an export, and a
    /// selection can hold thousands of photos.
    @State private var evaluated: AssetCapabilities?
    private var ids: [String] { assets.map(\.id) }
    @State private var featuresFailure: String?
    @State private var photosOutcome: String?

    init(api: APIClient, pipeline: MediaPipeline, assets: [Asset], onChanged: @escaping () -> Void) {
        self.api = api; self.pipeline = pipeline; self.assets = assets; self.onChanged = onChanged
        _exports = State(initialValue: ExportTracker(api: api))
    }

    private var working: Bool { busy || exports.isRunning }
    private var savingToPhotos: Bool { exports.request?.destination == .photos }
    private var favorites: Bool { assets.allSatisfy(\.isFavorite) }
    private var archived: Bool { assets.allSatisfy { $0.visibility == .archive } }
    private var allLocked: Bool { !assets.isEmpty && assets.allSatisfy { $0.visibility == .locked } }
    private func evaluate(features: ServerFeatures?) -> AssetCapabilities {
        AssetCapabilityPolicy.evaluate(selection: assets, context: CapabilityContext(api: api, features: features))
    }
    private var writableAlbums: [Album] { albums.filter { $0.albumUsers?.contains(where: { $0.user.id == api.userID && ["owner", "editor"].contains($0.role) }) == true } }

    var body: some View {
        let can = evaluated ?? evaluate(features: features)
        // Deleting from a server without Trash, or photos already in it, can't be undone.
        let permanently = !can.shows(.trash)
        List {
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
            if let photosOutcome, !working { Section { Text(photosOutcome) } }
            if working {
                Section {
                    HStack {
                        if let fraction = exports.progress?.fraction { ProgressView(value: fraction).frame(width: 60) } else { ProgressView() }
                        if let progress = exports.progress, savingToPhotos {
                            Text("Saved \(progress.completed) of \(progress.total)" + (progress.committing ? " · Saving to Photos…" : ""))
                        } else if let progress = exports.progress, progress.completed > 0 {
                            Text("Prepared \(progress.completed) of \(progress.total)")
                        } else {
                            Text("Working…")
                        }
                    }
                }
            }
            shareSection(can)
            if can.shows(.addToAlbum) { albumSection(can) }
            if ([.favorite, .archive, .lock, .stack, .trash, .deletePermanently] as [AssetAction]).contains(where: can.shows) {
                organizeSection(can, permanently: permanently)
            }
        }
        .navigationTitle("\(assets.count) selected").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .disabled(working)
        .overlay(alignment: .bottom) {
            if working {
                Button(exports.isCommitting ? "Saving to Photos" : "Cancel") { operation?.cancel(); exports.cancel() }
                    .buttonStyle(.glass).padding().disabled(exports.isCommitting)
            }
        }
        .onAppear { if evaluated == nil { evaluated = can } }
        .task { if can.shows(.addToAlbum) { albums = (try? await api.albums()) ?? [] }; await loadFeatures() }
        .onDisappear { operation?.cancel(); exports.cancel() }
        .sheet(item: $share, onDismiss: { share?.remove(); share = nil }) { files in
            ShareSheet(urls: files.urls).onDisappear { files.remove() }
        }
        .sheet(isPresented: $publicLink) { NavigationStack { SharedLinkEditor(api: api, album: nil, assetIDs: ids) } }
        .confirmationDialog(permanently ? "Permanently delete \(assets.count) items?" : "Move \(assets.count) items to Trash?", isPresented: $confirmTrash) {
            Button(permanently ? "Delete permanently" : "Move to Trash", role: .destructive) {
                run { try await api.trashAssets(ids: ids, permanently: permanently) }
            }
        } message: { Text(permanently ? "This cannot be undone." : "Photos on your phone are kept.") }
    }
    private func shareSection(_ can: AssetCapabilities) -> some View {
        Section {
            if !assets.allSatisfy(\.isVideo) {
                Picker("Photo quality", selection: $shareFileType) { Text("Original").tag("original"); Text("Displayed").tag("preview") }
            }
            action(.share, can, "Share files", systemImage: "square.and.arrow.up") { prepareShare(original: shareFileType != "preview") }
            action(.saveToPhotos, can, "Save to Photos", systemImage: "square.and.arrow.down") { saveToPhotos(original: shareFileType != "preview") }
            action(.sharedLink, can, "Create shared link", systemImage: "link") { publicLink = true }
        } header: { Text("Share") } footer: {
            if !assets.allSatisfy(\.isVideo) { Text("Displayed keeps the edits you see. Videos use originals. Saving a Live Photo keeps its original photo and motion.") }
        }
    }
    private func albumSection(_ can: AssetCapabilities) -> some View {
        Section("Albums") {
            Menu("Add to album") {
                ForEach(writableAlbums) { album in Button(album.albumName) { add(to: album) } }
            }.disabled(writableAlbums.isEmpty || !can.offers(.addToAlbum))
        }
    }
    private func organizeSection(_ can: AssetCapabilities, permanently: Bool) -> some View {
        Section("Organize") {
            // The Locked Folder's selection only leaves the folder or goes to Trash.
            if allLocked {
                action(.lock, can, "Move to Timeline", systemImage: "lock.open") { update(.init(ids: ids, visibility: .timeline)) }
            } else {
                action(.favorite, can, favorites ? "Remove favorites" : "Favorite", systemImage: "heart") { update(.init(ids: ids, isFavorite: !favorites)) }
                action(.archive, can, archived ? "Unarchive" : "Archive", systemImage: "archivebox") { update(.init(ids: ids, visibility: archived ? .timeline : .archive)) }
                action(.lock, can, "Move to Locked Folder", systemImage: "lock") { update(.init(ids: ids, visibility: .locked)) }
            }
            // A stack needs two photos or more.
            if assets.count > 1 { action(.stack, can, "Stack photos", systemImage: "square.stack.3d.up", perform: stack) }
            let deletion: AssetAction = permanently ? .deletePermanently : .trash
            if can.shows(deletion) {
                Button(permanently ? "Delete permanently" : "Move to Trash", systemImage: "trash", role: .destructive) { confirmTrash = true }
                    .disabled(features == nil || !can.offers(deletion))
            }
            if features == nil, let featuresFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn’t check whether Trash is available, so delete is unavailable. \(featuresFailure)").font(.footnote).foregroundStyle(.secondary)
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await loadFeatures() } }
                }
            }
        }
    }
    /// A button for `action`: missing where a selected photo doesn't have it, dimmed where it can't
    /// be used now.
    @ViewBuilder private func action(_ action: AssetAction, _ can: AssetCapabilities, _ title: String, systemImage: String,
                                     perform: @escaping () -> Void) -> some View {
        if can.shows(action) { Button(title, systemImage: systemImage, action: perform).disabled(!can.offers(action)) }
    }
    private func loadFeatures() async {
        featuresFailure = nil
        do {
            let loaded = try await api.serverFeatures(); try Task.checkCancellation()
            features = loaded
            evaluated = evaluate(features: loaded)
        }
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
            await pipeline.forget(assetIDs: Set(ids), revoked: true)
            await TimelineCache.shared.removeAll(scope: api.cacheScope)
        } else if body.visibility == .timeline {
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
    private func saveToPhotos(original: Bool) {
        guard !working, !assets.isEmpty else { return }
        failure = nil; photosOutcome = nil
        let total = assets.count
        exports.start(.saveToPhotos(assets, original: original)) { outcome in
            switch outcome {
            case .saved(let saved): photosOutcome = "Saved \(saved) of \(total) to Photos."
            case .cancelled(let saved): photosOutcome = "Cancelled. Saved \(saved) of \(total) to Photos."
            case .failed(let error, let saved):
                failure = error.localizedDescription
                photosOutcome = "Stopped. Saved \(saved) of \(total) to Photos. Saving again may create duplicates."
            case .files: break
            }
        }
    }
    private func prepareShare(original: Bool) {
        guard !working, !assets.isEmpty else { return }
        failure = nil
        exports.start(.share(assets, original: original)) { outcome in
            switch outcome {
            case .files(let files): share = files
            case .failed(let error, _): failure = error.localizedDescription
            case .saved, .cancelled: break
            }
        }
    }
}

struct SelectionUpdate: Encodable, Sendable {
    let ids: [String]
    var isFavorite: Bool?
    var visibility: AssetVisibility?
}

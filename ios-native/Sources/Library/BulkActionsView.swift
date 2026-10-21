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
    @State private var shareFraction: Double?
    @State private var shareToken: UUID?
    @AppStorage("shareFileType") private var shareFileType = "original"
    @State private var operation: Task<Void, Never>?
    @State private var confirmTrash = false
    @State private var features: ServerFeatures?
    private var ids: [String] { assets.map(\.id) }
    @State private var featuresFailure: String?
    @State private var photosSaving = false
    @State private var photosCommitting = false
    @State private var photosSaved = 0
    @State private var photosOutcome: String?
    private var owned: Bool {
        guard let userID = api.userID, !assets.isEmpty else { return false }
        return assets.allSatisfy { $0.ownerId == userID }
    }
    private var favorites: Bool { assets.allSatisfy(\.isFavorite) }
    private var archived: Bool { assets.allSatisfy { $0.visibility == .archive } }
    private var allLocked: Bool { !assets.isEmpty && assets.allSatisfy { $0.visibility == .locked } }
    private var writableAlbums: [Album] { albums.filter { $0.albumUsers?.contains(where: { $0.user.id == api.userID && ["owner", "editor"].contains($0.role) }) == true } }

    var body: some View {
        List {
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
            if let photosOutcome, !busy { Section { Text(photosOutcome) } }
            if busy {
                Section {
                    HStack {
                        if let shareFraction { ProgressView(value: shareFraction).frame(width: 60) } else { ProgressView() }
                        if photosSaving {
                            Text("Saved \(photosSaved) of \(assets.count)" + (photosCommitting ? " · Saving to Photos…" : ""))
                        } else {
                            Text(progress > 0 ? "Prepared \(progress) of \(assets.count)" : "Working…")
                        }
                    }
                }
            }
            shareSection
            if !allLocked { albumSection }
            if owned { organizeSection }
        }
        .navigationTitle("\(assets.count) selected").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .disabled(busy)
        .overlay(alignment: .bottom) {
            if busy { Button(photosCommitting ? "Saving to Photos" : "Cancel") { operation?.cancel() }.buttonStyle(.glass).padding().disabled(photosCommitting) }
        }
        .task { if !allLocked { albums = (try? await api.albums()) ?? [] }; await loadFeatures() }
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
        Section {
            if !assets.allSatisfy(\.isVideo) {
                Picker("Photo quality", selection: $shareFileType) { Text("Original").tag("original"); Text("Displayed").tag("preview") }
            }
            Button("Share files", systemImage: "square.and.arrow.up") { prepareShare(original: shareFileType != "preview") }
            Button("Save to Photos", systemImage: "square.and.arrow.down") { saveToPhotos(original: shareFileType != "preview") }.requiresWriteAccess()
            if !allLocked { Button("Create shared link", systemImage: "link") { publicLink = true }.requiresWriteAccess() }
        } header: { Text("Share") } footer: {
            if !assets.allSatisfy(\.isVideo) { Text("Displayed keeps the edits you see. Videos use originals. Saving a Live Photo keeps its original photo and motion.") }
        }
    }
    private var albumSection: some View {
        Section("Albums") {
            Menu("Add to album") {
                ForEach(writableAlbums) { album in Button(album.albumName) { add(to: album) } }
            }.disabled(writableAlbums.isEmpty).requiresWriteAccess()
        }
    }
    private var organizeSection: some View {
        Section("Organize") {
            if allLocked {
                Button("Move to Timeline", systemImage: "lock.open") { update(.init(ids: ids, visibility: .timeline)) }
            } else {
                Button(favorites ? "Remove favorites" : "Favorite", systemImage: "heart") { update(.init(ids: ids, isFavorite: !favorites)) }
                Button(archived ? "Unarchive" : "Archive", systemImage: "archivebox") { update(.init(ids: ids, visibility: archived ? .timeline : .archive)) }
                Button("Move to Locked Folder", systemImage: "lock") { update(.init(ids: ids, visibility: .locked)) }
            }
            if assets.count > 1 && !allLocked { Button("Stack photos", systemImage: "square.stack.3d.up", action: stack) }
            Button(features?.trash == false ? "Delete permanently" : "Move to Trash", systemImage: "trash", role: .destructive) { confirmTrash = true }
                .disabled(features == nil)
            if features == nil, let featuresFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn’t check whether Trash is available, so delete is unavailable. \(featuresFailure)").font(.footnote).foregroundStyle(.secondary)
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await loadFeatures() } }
                }
            }
        }.requiresWriteAccess()
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
        guard !busy, !assets.isEmpty else { return }
        busy = true; failure = nil; photosOutcome = nil; progress = 0
        photosSaving = true; photosCommitting = false; photosSaved = 0
        let token = UUID(); shareToken = token; shareFraction = 0
        let total = assets.count
        operation = Task {
            defer {
                busy = false; photosSaving = false; photosCommitting = false
                if shareToken == token { shareToken = nil; shareFraction = nil }
            }
            do {
                try await PhotoLibrarySave.requestPermission(api: api)
                await TransferNotifications.started(id: token, kind: "Save to Photos", total: total)
                try Task.checkCancellation()
                for asset in assets {
                    try Task.checkCancellation()
                    let completed = photosSaved
                    try await PhotoLibrarySave.save(asset, api: api, original: original, progress: { fraction in
                        guard let fraction else { return }
                        Task { @MainActor in if shareToken == token { shareFraction = (Double(completed) + fraction) / Double(total) } }
                    }, beforeCommit: { photosCommitting = true })
                    photosCommitting = false
                    photosSaved += 1
                    shareFraction = Double(photosSaved) / Double(total)
                }
                photosOutcome = "Saved \(photosSaved) of \(total) to Photos."
                await TransferNotifications.finished(id: token, kind: "Save to Photos", total: total, completed: photosSaved, failed: 0)
                if Task.isCancelled { TransferNotifications.cancel(id: token) }
            } catch {
                photosCommitting = false
                if error is CancellationError || Task.isCancelled {
                    TransferNotifications.cancel(id: token)
                    photosOutcome = "Cancelled. Saved \(photosSaved) of \(total) to Photos."
                } else {
                    await TransferNotifications.finished(id: token, kind: "Save to Photos", total: total,
                                                         completed: photosSaved, failed: total - photosSaved)
                    if Task.isCancelled { TransferNotifications.cancel(id: token) }
                    failure = error.localizedDescription
                    photosOutcome = "Stopped. Saved \(photosSaved) of \(total) to Photos. Saving again may create duplicates."
                }
            }
        }
    }
    private func prepareShare(original: Bool) {
        guard !busy, !assets.isEmpty else { return }
        busy = true; failure = nil; progress = 0
        let token = UUID(); shareToken = token; shareFraction = nil
        let total = Double(assets.count)
        operation = Task {
            defer { busy = false; if shareToken == token { shareToken = nil; shareFraction = nil } }
            var files: [URL] = []
            do {
                await TransferNotifications.started(id: token, kind: "Download", total: assets.count)
                for asset in assets {
                    try Task.checkCancellation()
                    let completed = Double(files.count)
                    let file = try await api.download(asset: asset, original: original) { fraction in
                        guard let fraction else { return }
                        Task { @MainActor in if shareToken == token { shareFraction = (completed + fraction) / total } }
                    }
                    guard !Task.isCancelled else { BulkExport(files: [file]).clean(); throw CancellationError() }
                    files.append(file); progress += 1
                    shareFraction = Double(files.count) / total
                }
                try Task.checkCancellation(); share = BulkExport(files: files)
                await TransferNotifications.finished(id: token, kind: "Download", total: assets.count, completed: files.count, failed: 0)
                if Task.isCancelled { TransferNotifications.cancel(id: token) }
            } catch {
                BulkExport(files: files).clean()
                if error is CancellationError || Task.isCancelled { TransferNotifications.cancel(id: token) }
                else {
                    await TransferNotifications.finished(id: token, kind: "Download", total: assets.count,
                                                         completed: files.count, failed: assets.count - files.count)
                    if Task.isCancelled { TransferNotifications.cancel(id: token) }
                    failure = error.localizedDescription
                }
            }
        }
    }
}

struct SelectionUpdate: Encodable, Sendable {
    let ids: [String]
    var isFavorite: Bool?
    var visibility: AssetVisibility?
}
private final class BulkExport: Identifiable {
    let id = UUID()
    let files: [URL]
    init(files: [URL]) { self.files = files }
    deinit { clean() }
    func clean() { for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
}
private struct BulkShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

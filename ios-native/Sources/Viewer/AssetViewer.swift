import Photos
import SwiftUI

@MainActor
struct AssetViewer: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let assets: [Asset]
    let onUpdated: (Asset) -> Void
    let onDeleted: () -> Void
    @State private var selectedID: String
    @State private var replacements: [String: Asset] = [:]
    @State private var controls = true
    @State private var info = false
    @State private var editing = false
    @State private var chooseAlbum = false
    @State private var deleteConfirmation = false
    @State private var error: String?
    @State private var working = false
    @State private var export: ViewerExport?
    @State private var playingLive = false
    @Environment(\.dismiss) private var dismiss

    init(api: APIClient, pipeline: MediaPipeline, assets: [Asset], initial: Asset,
         onUpdated: @escaping (Asset) -> Void, onDeleted: @escaping () -> Void) {
        self.api = api; self.pipeline = pipeline
        self.assets = assets.contains(where: { $0.id == initial.id }) ? assets : [initial] + assets
        self.onUpdated = onUpdated; self.onDeleted = onDeleted
        _selectedID = State(initialValue: initial.id)
        _replacements = State(initialValue: [initial.id: initial])
    }

    private var selectedIndex: Int { assets.firstIndex(where: { $0.id == selectedID }) ?? 0 }
    private var current: Asset { replacements[selectedID] ?? assets[selectedIndex] }
    private var ownsAsset: Bool { current.ownerId == nil || current.ownerId == api.userID }
    private var canEdit: Bool {
        ownsAsset && current.type == .image && current.livePhotoVideoId == nil && current.exifInfo?.projectionType != "equirectangular" && !["gif", "svg"].contains((current.originalFileName as NSString).pathExtension.lowercased())
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $selectedID) {
                ForEach(Array(assets.enumerated()), id: \.element.id) { index, summary in
                    let asset = replacements[summary.id] ?? summary
                    Group {
                        if abs(index - selectedIndex) <= 1 {
                            if asset.isVideo {
                                AuthenticatedVideo(api: api, assetID: asset.id, active: selectedID == asset.id)
                            } else if playingLive, selectedID == asset.id, let videoID = asset.livePhotoVideoId {
                                AuthenticatedVideo(api: api, assetID: videoID, active: true)
                            } else {
                                ViewerPhoto(pipeline: pipeline, asset: asset, onTap: { controls.toggle() }, onDismiss: { dismiss() })
                            }
                        } else { Color.black }
                    }.tag(asset.id)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never)).ignoresSafeArea()
            if controls {
                VStack {
                    header
                    Spacer()
                    footer
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
            if working { ProgressView().padding(20).glassEffect(in: .circle).accessibilityLabel("Preparing photo") }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!controls)
        .task(id: selectedID) {
            playingLive = false
            do {
                let asset = try await api.asset(id: selectedID)
                try Task.checkCancellation(); replacements[asset.id] = asset
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $info) {
            NavigationStack {
                AssetInfoView(api: api, pipeline: pipeline, asset: current, onUpdated: update,
                              onExportOriginal: { exportAsset(original: true) })
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { info = false } } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $editing) {
            PhotoEditor(api: api, pipeline: pipeline, asset: current, onSaved: update)
        }
        .sheet(isPresented: $chooseAlbum) {
            NavigationStack { ViewerAlbumPicker(api: api, assetID: current.id) }
        }
        .sheet(item: $export) { item in
            ViewerShareSheet(url: item.url).onDisappear { item.removeTemporaryFile() }
        }
        .alert("Couldn’t complete action", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(error ?? "") }
        .confirmationDialog(current.isTrashed ? "Delete permanently?" : "Move to Trash?", isPresented: $deleteConfirmation, titleVisibility: .visible) {
            Button(current.isTrashed ? "Delete permanently" : "Move to Trash", role: .destructive) { deleteAsset() }
        } message: {
            Text(current.isTrashed ? "This cannot be undone." : "You can restore this item from Trash. Photos on your phone are kept.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            viewerButton("Close", symbol: "chevron.down") { dismiss() }
            VStack(spacing: 3) {
                if let date = current.localDateTime ?? current.fileCreatedAt {
                    Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: TimeZone(secondsFromGMT: 0)!)))
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                let location = [current.exifInfo?.city, current.exifInfo?.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                if !location.isEmpty { Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.padding(.horizontal, 14).frame(minHeight: 48).frame(maxWidth: .infinity).glassEffect(in: .capsule)
            Menu {
                Button("Add to album", systemImage: "rectangle.stack.badge.plus") { chooseAlbum = true }
                Button("Share displayed version", systemImage: "square.and.arrow.up") { exportAsset(original: false) }
                Button("Download original", systemImage: "arrow.down.document") { exportAsset(original: true) }
                Button("Save to Photos", systemImage: "square.and.arrow.down") { saveToPhotos() }
                if ownsAsset {
                    if current.isTrashed {
                        Button("Restore from Trash", systemImage: "arrow.uturn.backward") { restoreAsset() }
                    } else {
                        Button(current.visibility == .archive ? "Unarchive" : "Archive", systemImage: "archivebox") { changeVisibility(current.visibility == .archive ? .timeline : .archive) }
                        Button(current.visibility == .locked ? "Move out of Locked Folder" : "Move to Locked Folder", systemImage: "lock") { changeVisibility(current.visibility == .locked ? .timeline : .locked) }
                    }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 48, height: 48).glassEffect(in: .circle) }
                .accessibilityLabel("Photo actions").disabled(working)
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            if current.livePhotoVideoId != nil {
                Button(playingLive ? "Still photo" : "Play Live Photo", systemImage: playingLive ? "photo" : "livephoto") { playingLive.toggle() }
                    .buttonStyle(.glass)
            }
            HStack(spacing: 0) {
                viewerButton("Share", symbol: "square.and.arrow.up") { exportAsset(original: false) }
                Spacer()
                viewerButton(current.isFavorite ? "Remove favorite" : "Favorite", symbol: current.isFavorite ? "heart.fill" : "heart") { toggleFavorite() }
                    .tint(current.isFavorite ? .red : .primary).disabled(!ownsAsset)
                Spacer()
                viewerButton("Info", symbol: "info.circle") { info = true }
                if canEdit {
                    Spacer()
                    viewerButton("Edit", symbol: "slider.horizontal.3") { editing = true }
                }
                if ownsAsset {
                    Spacer()
                    viewerButton("Delete", symbol: "trash") { deleteConfirmation = true }
                }
            }.disabled(working)
        }
    }

    private func viewerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3).frame(width: 48, height: 48) }
            .buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel(title)
    }
    private func update(_ asset: Asset) { replacements[asset.id] = asset; onUpdated(asset) }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }; working = true
        Task { defer { working = false }; do { try await operation() } catch is CancellationError { } catch { self.error = error.localizedDescription } }
    }
    private func toggleFavorite() {
        let asset = current
        run { update(try await api.updateFavorite(assetID: asset.id, value: !asset.isFavorite)) }
    }
    private func changeVisibility(_ visibility: AssetVisibility) {
        let id = current.id
        run { update(try await api.updateAsset(id: id, update: .init(visibility: visibility))) }
    }
    private func deleteAsset() {
        let asset = current
        run { try await api.trashAssets(ids: [asset.id], permanently: asset.isTrashed); onDeleted(); dismiss() }
    }
    private func restoreAsset() {
        let id = current.id
        run { _ = try await api.restoreAssets(ids: [id]); onDeleted(); dismiss() }
    }
    private func exportAsset(original: Bool) {
        let asset = current
        run { export = ViewerExport(url: try await api.download(asset: asset, original: original)) }
    }
    private func saveToPhotos() {
        let asset = current
        run {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { throw APIError.invalidResponse("Allow Ilyich to add photos in iPhone Settings, then try again.") }
            let file = ViewerExport(url: try await api.download(asset: asset))
            defer { file.removeTemporaryFile() }
            try await PHPhotoLibrary.shared().performChanges {
                if asset.isVideo { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file.url) }
                else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file.url) }
            }
        }
    }
}

struct ViewerExport: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    func removeTemporaryFile() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct ViewerShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

private struct ViewerAlbumPicker: View {
    let api: APIClient
    let assetID: String
    @State private var albums: [Album] = []
    @State private var error: String?
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(albums) { album in
            Button(album.albumName) {
                adding = true
                Task {
                    defer { adding = false }
                    do {
                        let results = try await api.addToAlbum(id: album.id, assetIDs: [assetID])
                        guard results.allSatisfy({ $0.success || $0.error == "duplicate" }) else { throw APIError.invalidResponse("The photo could not be added to this album.") }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }.disabled(adding)
        }.navigationTitle("Add to album")
            .overlay { if albums.isEmpty && error == nil { ContentUnavailableView("No albums yet", systemImage: "rectangle.stack") } }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { do { albums = try await api.albums() } catch { self.error = error.localizedDescription } }
            .alert("Couldn’t add photo", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { } } message: { Text(error ?? "") }
    }
}

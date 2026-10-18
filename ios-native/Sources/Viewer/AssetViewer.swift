import Photos
import SwiftUI

@MainActor
struct AssetViewer: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let assets: [Asset]
    let onUpdated: (Asset) -> Void
    let onDeleted: () -> Void
    let albumID: String?
    @ObservedObject private var cast = CastController.shared
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
    @State private var slideshow = false
    @State private var sharedLink = false
    @State private var showStack = false
    @State private var albumActivity = false
    @State private var castPresented = false
    @State private var ocrPresented = false
    @State private var similarPresented = false
    @State private var features: ServerFeatures?
    @State private var profilePhoto = false
    @AppStorage("viewerTapToNavigate") private var tapToNavigate = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(api: APIClient, pipeline: MediaPipeline, assets: [Asset], initial: Asset,
         onUpdated: @escaping (Asset) -> Void, onDeleted: @escaping () -> Void, albumID: String? = nil) {
        self.api = api; self.pipeline = pipeline
        self.assets = assets.contains(where: { $0.id == initial.id }) ? assets : [initial] + assets
        self.onUpdated = onUpdated; self.onDeleted = onDeleted
        self.albumID = albumID
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
                                AuthenticatedVideo(api: api, assetID: asset.id, active: selectedID == asset.id && !(cast.connected && cast.currentAssetID == asset.id))
                            } else if playingLive, selectedID == asset.id, let videoID = asset.livePhotoVideoId {
                                AuthenticatedVideo(api: api, assetID: videoID, active: !(cast.connected && cast.currentAssetID == asset.id), onEnded: { playingLive = false })
                            } else {
                                ViewerPhoto(pipeline: pipeline, asset: asset, active: selectedID == asset.id, onTap: handlePhotoTap, onDismiss: { dismiss() })
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
        .task { features = try? await api.serverFeatures() }
        .task(id: selectedID) {
            playingLive = false
            CastController.shared.select(api: api, asset: current)
            do {
                let asset = try await api.asset(id: selectedID)
                try Task.checkCancellation(); replacements[asset.id] = asset
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $profilePhoto) { NavigationStack { ProfilePhotoCropView(api: api, pipeline: pipeline, asset: current) } }
        .sheet(isPresented: $castPresented) { CastView(api: api, asset: current) }
        .fullScreenCover(isPresented: $ocrPresented) { OCRPhotoReader(api: api, pipeline: pipeline, asset: current) }
        .sheet(isPresented: $similarPresented) { SimilarPhotosView(api: api, pipeline: pipeline, reference: current) }
        .sheet(isPresented: $info) {
            NavigationStack {
                AssetInfoView(api: api, pipeline: pipeline, asset: current, onUpdated: update)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { info = false } } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $editing) {
            PhotoEditor(api: api, pipeline: pipeline, asset: current, onSaved: update)
        }
        .sheet(isPresented: $chooseAlbum) {
            NavigationStack { ViewerAlbumPicker(api: api, assetID: current.id) }
        }
        .fullScreenCover(isPresented: $slideshow) { SlideshowView(api: api, pipeline: pipeline, assets: assets.map { replacements[$0.id] ?? $0 }, initial: current) }
        .sheet(isPresented: $sharedLink) { NavigationStack { SharedLinkEditor(api: api, album: nil, assetIDs: [current.id]) } }
        .sheet(isPresented: $showStack) {
            if let stack = current.stack { NavigationStack { ViewerStackView(api: api, pipeline: pipeline, stackID: stack.id, onUpdated: update, onChanged: onDeleted) } }
        }
        .sheet(isPresented: $albumActivity) {
            if let albumID { NavigationStack { AlbumActivityView(api: api, albumID: albumID, assetID: current.id) } }
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
                Button("Add to album", systemImage: "rectangle.stack.badge.plus") { chooseAlbum = true }.requiresWriteAccess(api)
                Button("Slideshow", systemImage: "play.rectangle") { slideshow = true }
                Button("Cast", systemImage: "tv") { castPresented = true }
                if features?.ocr == true, current.type == .image { Button("Select text", systemImage: "text.viewfinder") { ocrPresented = true } }
                if features?.smartSearch == true { Button("Find similar photos", systemImage: "photo.on.rectangle.angled") { similarPresented = true } }
                if !current.isVideo { Button("Set profile photo", systemImage: "person.crop.circle") { profilePhoto = true }.requiresWriteAccess(api) }
                Button("Create shared link", systemImage: "link") { sharedLink = true }.requiresWriteAccess(api)
                if let stack = current.stack { Button("Stack (\(stack.assetCount))", systemImage: "square.stack.3d.up") { showStack = true } }
                if let albumID {
                    Button("Comments and likes", systemImage: "bubble") { albumActivity = true }
                    Button("Set album cover", systemImage: "photo.on.rectangle.angled") {
                        let id = current.id
                        run { let _: Album = try await api.request(.patch, path: "albums/\(albumID)", body: ["albumThumbnailAssetId": id]) }
                    }.requiresWriteAccess(api)
                }
                Button("Share displayed version", systemImage: "square.and.arrow.up") { exportAsset(original: false) }
                Button("Download original", systemImage: "arrow.down.document") { exportAsset(original: true) }
                Button("Save to Photos", systemImage: "square.and.arrow.down") { saveToPhotos() }.requiresWriteAccess(api)
                Button("Open in browser", systemImage: "safari") { openURL(api.baseURL.deletingLastPathComponent().appendingPathComponent("photos/\(current.id)")) }
                if ownsAsset {
                    if current.isTrashed {
                        Button("Restore from Trash", systemImage: "arrow.uturn.backward") { restoreAsset() }.requiresWriteAccess(api)
                    } else {
                        Button(current.visibility == .archive ? "Unarchive" : "Archive", systemImage: "archivebox") { changeVisibility(current.visibility == .archive ? .timeline : .archive) }.requiresWriteAccess(api)
                        Button(current.visibility == .locked ? "Move out of Locked Folder" : "Move to Locked Folder", systemImage: "lock") { changeVisibility(current.visibility == .locked ? .timeline : .locked) }.requiresWriteAccess(api)
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
                viewerButton(current.isFavorite ? "Remove favorite" : "Favorite", symbol: current.isFavorite ? "heart.fill" : "heart") { toggleFavorite() }.requiresWriteAccess(api)
                    .tint(current.isFavorite ? .red : .primary).disabled(!ownsAsset)
                Spacer()
                viewerButton("Info", symbol: "info.circle") { info = true }
                if canEdit {
                    Spacer()
                    viewerButton("Edit", symbol: "slider.horizontal.3") { editing = true }.requiresWriteAccess(api)
                }
                if ownsAsset {
                    Spacer()
                    viewerButton("Delete", symbol: "trash") { deleteConfirmation = true }.requiresWriteAccess(api)
                }
            }.disabled(working)
        }
    }

    private func viewerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3).frame(width: 48, height: 48) }
            .buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel(title)
    }
    private func update(_ asset: Asset) { replacements[asset.id] = asset; onUpdated(asset) }
    private func handlePhotoTap(_ horizontalFraction: Double) {
        if tapToNavigate && horizontalFraction < 0.33 && selectedIndex > 0 { selectedID = assets[selectedIndex - 1].id }
        else if tapToNavigate && horizontalFraction > 0.67 && selectedIndex + 1 < assets.count { selectedID = assets[selectedIndex + 1].id }
        else { controls.toggle() }
    }
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
        run {
            let updated = try await api.updateAsset(id: id, update: .init(visibility: visibility))
            if visibility == .locked {
                await pipeline.removeAll()
                await TimelineCache.shared.removeAll(scope: api.cacheScope)
                onDeleted(); dismiss()
            } else { update(updated) }
        }
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
            guard !api.isReadOnly else { throw ReadOnlyPolicy.ReadOnlyError() }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { throw APIError.invalidResponse("Allow Ilyich to add photos in iPhone Settings, then try again.") }
            // A Live Photo requires the original matching still/video identifiers.
            // Server-rendered JPEGs cannot substitute for the paired still metadata.
            let file = ViewerExport(url: try await api.download(asset: asset, original: asset.livePhotoVideoId != nil))
            defer { file.removeTemporaryFile() }
            var motion: ViewerExport?
            defer { motion?.removeTemporaryFile() }
            if let motionID = asset.livePhotoVideoId {
                let motionAsset = try await api.asset(id: motionID)
                motion = ViewerExport(url: try await api.download(asset: motionAsset, original: true))
            }
            let motionURL = motion?.url
            try Task.checkCancellation()
            guard !api.isReadOnly else { throw ReadOnlyPolicy.ReadOnlyError() }
            try await PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                creation.addResource(with: asset.isVideo ? .video : .photo, fileURL: file.url, options: nil)
                if let motionURL { creation.addResource(with: .pairedVideo, fileURL: motionURL, options: nil) }
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

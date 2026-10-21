import IlyichPlatform
import SwiftUI
@preconcurrency import Photos

struct LocalLibraryView: View {
    var destinationAlbumID: String? = nil
    var destinationAlbumName: String? = nil
    var onBackupFinished: (() -> Void)? = nil
    @State private var initialized = false
    @State private var watchingUploads = false
    @State private var library = LocalPhotoLibrary()
    @State private var backup = BackupCoordinator.shared
    @State private var selection = Set<String>()
    @State private var selecting = false
    @State private var viewing: LocalPhoto?
    @State private var accessPicker = false
    @State private var uploading = false
    @State private var showBackup = false
    @State private var showActions = false
    @State private var actionPhotos: [LocalPhoto] = []
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if [.authorized, .limited].contains(library.permission) { photoGrid }
            else {
                ContentUnavailableView {
                    Label("Photos on this phone", systemImage: "iphone")
                } description: { Text("Choose which photos Ilyich can show and back up. Your server library is available without this permission.") }
                actions: {
                    if library.permission == .notDetermined { Button("Choose Photos access") { Task { await library.requestAccess() } }.buttonStyle(.borderedProminent) }
                    else { Button("Open Settings") { openPhotoSettings() }.buttonStyle(.borderedProminent) }
                }
            }
        }.navigationTitle(destinationAlbumID == nil ? "On this phone" : "Upload photos")
        .toolbar {
            if [.authorized, .limited].contains(library.permission) {
                ToolbarItem(placement: .topBarTrailing) { Button(selecting ? "Done" : "Select") { selecting.toggle(); selection = [] } }
                ToolbarItem(placement: .topBarTrailing) { Menu {
                    NavigationLink("Free up space") { FreeUpSpaceView() }
                    NavigationLink("Backup settings") { BackupSettingsView() }
                    if library.permission == .limited { Button("Choose more photos") { accessPicker = true } }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Device photo options") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    Text("\(selection.count.formatted()) selected").font(.subheadline)
                    Spacer()
                    Button(destinationAlbumID == nil ? "Back up selected" : "Upload to album", systemImage: "icloud.and.arrow.up") { Task { await upload() } }
                        .disabled(selection.isEmpty || uploading || backup.isRunning).requiresWriteAccess()
                    Button("Photo actions", systemImage: "ellipsis") { actionPhotos = library.photos.filter { selection.contains($0.id) }; showActions = true }.labelStyle(.iconOnly).disabled(selection.isEmpty)
                }.padding().glassEffect().padding(.horizontal, 12)
            }
        }
        .task { library.begin(); if !initialized { initialized = true; selecting = destinationAlbumID != nil } }
        .onChange(of: backup.isRunning) { _, running in
            if watchingUploads && !running { onBackupFinished?(); watchingUploads = false }
        }
        .onChange(of: showBackup) { _, shown in if !shown { onBackupFinished?() } }
        .onDisappear { library.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { library.begin() } }
        .onChange(of: library.albumID) { _, _ in selection = []; library.selectAlbum() }
        .onChange(of: library.photos) { _, values in selection.formIntersection(Set(values.map(\.id))) }
        .fullScreenCover(item: $viewing) { LocalPhotoViewer(photo: $0, onChanged: { library.refresh() }) }
        .sheet(isPresented: $showActions) { NavigationStack { LocalPhotoActionsView(photos: actionPhotos) { selection = []; selecting = false; library.refresh() } } }
        .sheet(isPresented: $accessPicker, onDismiss: { library.refresh() }) { LimitedPhotoAccessPicker { accessPicker = false; library.refresh() } }
        .sheet(isPresented: $showBackup) { NavigationStack { BackupSettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showBackup = false } } } } }
    }
    private var photoGrid: some View {
        ScrollView {
            if let destinationAlbumName {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Upload to \(destinationAlbumName)").font(.headline)
                    Text("Selected items upload to your server and are added to this album as each upload completes. You can follow progress or pause in Backup.").font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            if library.permission == .limited {
                HStack { Text("Showing your selected photos").font(.footnote).foregroundStyle(.secondary); Spacer(); Button("Manage") { accessPicker = true }.font(.footnote) }.padding(.horizontal).padding(.top, 8)
            }
            Picker("Album", selection: $library.albumID) {
                Text("All photos").tag("")
                ForEach(library.albums) { Text($0.title).tag($0.id) }
            }.padding(.horizontal)
            if library.photos.isEmpty { FeatureEmpty(title: "No photos available", symbol: "photo.on.rectangle", description: library.permission == .limited ? "Allow more photos to see them here." : "Photos and videos saved on this phone will appear here.") }
            LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(library.photos) { photo in
                    Button {
                        if selecting { if !selection.insert(photo.id).inserted { selection.remove(photo.id) } }
                        else { viewing = photo }
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            LocalPhotoThumbnail(photo: photo).aspectRatio(1, contentMode: .fit)
                            if selecting { Image(systemName: selection.contains(photo.id) ? "checkmark.circle.fill" : "circle").font(.title3).symbolRenderingMode(.palette).foregroundStyle(selection.contains(photo.id) ? Color.accentColor : Color.white, Color.black.opacity(0.4)).padding(7) }
                        }
                    }.buttonStyle(.plain).accessibilityLabel(photo.title).accessibilityAddTraits(selection.contains(photo.id) ? .isSelected : [])
                }
            }
            if library.photos.count < library.total { Button("Load more photos") { library.loadMore() }.padding(24) }
            Text("\(library.total.formatted()) items").font(.caption).foregroundStyle(.secondary).padding()
        }.refreshable { library.refresh() }
    }
    private func upload() async {
        uploading = true; defer { uploading = false }
        watchingUploads = true
        await backup.enqueue(localIDs: Array(selection), albumID: destinationAlbumID)
        if backup.error == nil { selection = []; selecting = false }
        showBackup = true
    }
}

struct FreeUpSpaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("cleanupKeepFavorites") private var keepFavorites = true
    @AppStorage("cleanupKeepMediaType") private var keepMediaType = "none"
    @AppStorage("cleanupKeepAlbumIDs") private var keepAlbumData = Data()
    @AppStorage("cleanupCutoffDaysAgo") private var cutoffDays = -1
    @AppStorage("cleanupDefaultsInitialized") private var defaultsInitialized = false
    @State private var cutoff = Date()
    @State private var albums: [DeviceAlbum] = []
    @State private var filtersReady = false
    @State private var permission = DevicePhotos.authorization
    @State private var photos: [LocalPhoto] = []
    @State private var selection = Set<String>()
    @State private var loading = false
    @State private var checked = false
    @State private var removing = false
    @State private var confirming = false
    @State private var viewing: LocalPhoto?
    @State private var failure: FeatureFailure?
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    /// Names the check a removal came from, in the Photos journal.
    @State private var scan = UUID()
    private var keptAlbums: Set<String> { (try? JSONDecoder().decode(Set<String>.self, from: keepAlbumData)) ?? [] }
    private var policy: CleanupPolicy { .init(cutoff: cutoff, keepFavorites: keepFavorites, keepMediaType: keepMediaType) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keep your backup. Clear space in Photos.").font(.title2.bold())
                Text("Only unchanged originals with a verified copy on your current server appear here. Edited photos and formats without a complete backup stay on your phone.").foregroundStyle(.secondary)
                Text("Removing items also removes them from iCloud Photos and other synced devices. They remain in Apple Photos’ Recently Deleted album until you clear it or it expires.").font(.footnote).foregroundStyle(.secondary)
                if let message { Text(message).font(.subheadline) }
            }.padding(20)
            if ![PHAuthorizationStatus.authorized, .limited].contains(permission) {
                VStack(spacing: 12) {
                    Text("Allow Photos access to check originals stored on this phone.").foregroundStyle(.secondary)
                    if permission == .notDetermined {
                        Button("Choose Photos access") { Task { permission = await PhotoKitAdapter.shared.requestAccess().status; initializeFilters() } }
                    } else { Button("Open Settings") { openPhotoSettings() } }
                }.padding(20)
            }
            VStack(alignment: .leading, spacing: 18) {
                DatePicker("Remove only before", selection: $cutoff, in: ...Date(), displayedComponents: .date)
                Toggle("Keep favorites", isOn: $keepFavorites)
                Picker("Always keep", selection: $keepMediaType) {
                    Text("Neither media type").tag("none")
                    Text("Photos").tag("photos")
                    Text("Videos").tag("videos")
                }
                NavigationLink("Keep albums (\(keptAlbums.count))") {
                    Form {
                        ForEach(albums) { album in
                            Toggle(album.title, isOn: Binding(get: { keptAlbums.contains(album.id) }, set: { value in
                                var ids = keptAlbums
                                if value { ids.insert(album.id) } else { ids.remove(album.id) }
                                keepAlbumData = (try? JSONEncoder().encode(ids)) ?? Data()
                            }))
                        }
                    }.navigationTitle("Keep albums")
                }
                Button("Check eligible backups", systemImage: "checkmark.shield") { operation = Task { await check() } }
                    .disabled(!filtersReady || loading || removing || ![PHAuthorizationStatus.authorized, .limited].contains(permission))
            }.padding(20).disabled(loading || removing)
            if loading { ProgressView("Checking backups with your server…").padding(28) }
            else if checked && photos.isEmpty { FeatureEmpty(title: "Nothing ready to remove", symbol: "checkmark.shield", description: "No verified originals match your removal settings. Your phone’s photos have not been changed.") }
            else if checked {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(photos.count.formatted()) verified items").font(.subheadline)
                        let ids = selection.isEmpty ? Set(photos.map(\.id)) : selection
                        Text("Originals size: \(BackupCoordinator.shared.verifiedOriginalByteCount(for: ids).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(selection.count == photos.count ? "Deselect all" : "Select all") { selection = selection.count == photos.count ? [] : Set(photos.map(\.id)) }
                }.padding(.horizontal, 20).padding(.vertical, 8)
                LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(photos) { photo in
                        Button { if !selection.insert(photo.id).inserted { selection.remove(photo.id) } } label: {
                            ZStack(alignment: .bottomTrailing) {
                                LocalPhotoThumbnail(photo: photo).aspectRatio(1, contentMode: .fit)
                                Image(systemName: selection.contains(photo.id) ? "checkmark.circle.fill" : "circle").font(.title3).symbolRenderingMode(.palette).foregroundStyle(selection.contains(photo.id) ? Color.accentColor : Color.white, Color.black.opacity(0.4)).padding(7)
                            }
                        }.buttonStyle(.plain).accessibilityLabel(photo.title).accessibilityAddTraits(selection.contains(photo.id) ? .isSelected : [])
                        .contextMenu { Button("Preview") { viewing = photo } }
                    }
                }
            }
        }.navigationTitle("Free up space").disabled(removing)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty { Button("Remove \(selection.count) from Photos", role: .destructive) { confirming = true }.buttonStyle(.glassProminent).padding().disabled(loading || removing).requiresWriteAccess() }
        }
        .task {
            guard !filtersReady else { return }
            initializeFilters()
            cutoff = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -(cutoffDays < 0 ? 30 : cutoffDays), to: Date()) ?? Date())
            filtersReady = true
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { initializeFilters() } }
        .onChange(of: policy) { _, _ in invalidate() }
        .onChange(of: keepAlbumData) { _, _ in invalidate() }
        .onDisappear { operation?.cancel(); operation = nil }
        .fullScreenCover(item: $viewing) { LocalPhotoViewer(photo: $0) }
        .confirmationDialog("Remove \(selection.count) items from Apple Photos?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove from Photos", role: .destructive) { operation = Task { await remove() } }.requiresWriteAccess()
        } message: { Text("Their verified server copies will be kept. iCloud Photos will remove them from your other synced devices too. Apple will ask you to confirm.") }
        .alert("Couldn’t free up space", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private func check() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        selection = []; photos = []; checked = false; message = nil; scan = UUID()
        do {
            guard [.authorized, .limited].contains(DevicePhotos.authorization) else { throw BackupError.message("Allow Photos access before checking local items.") }
            cutoffDays = max(0, Calendar.current.dateComponents([.day], from: cutoff, to: Date()).day ?? 0)
            let ids = try await BackupCoordinator.shared.verifiedLocalDeletionCandidates()
            try Task.checkCancellation()
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            let protected = protectedAlbumAssets()
            photos = (0..<fetched.count).map { fetched.object(at: $0) }.filter { eligible($0, protected: protected) }.map(LocalPhoto.init).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            checked = true
        } catch is CancellationError { } catch { failure = .init(error) }
    }
    private func remove() async {
        guard !selection.isEmpty, !removing else { return }
        removing = true; defer { removing = false }
        let requested = selection
        do {
            guard let originalSession = try KeychainCredentialStore().load() else { throw APIError.signedOut }
            guard !ReadOnlyPolicy.isEnabled(server: originalSession.server, userID: originalSession.userID) else { throw ReadOnlyPolicy.ReadOnlyError() }
            let verified = Set(try await BackupCoordinator.shared.verifiedLocalDeletionCandidates())
            try Task.checkCancellation()
            guard requested.isSubset(of: verified) else { throw BackupError.message("A photo or its backup changed since you reviewed it. Nothing was removed. Check again before continuing.") }
            let reviewed = photos.filter { requested.contains($0.id) }
            let revisions = Dictionary(uniqueKeysWithValues: reviewed.map { ($0.id, $0.modified) })
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(requested), options: nil)
            let protected = protectedAlbumAssets()
            guard reviewed.count == requested.count, fetched.count == requested.count, (0..<fetched.count).allSatisfy({ index in
                let asset = fetched.object(at: index)
                return revisions[asset.localIdentifier] == .some(asset.modificationDate) && eligible(asset, protected: protected)
            }) else { throw Self.libraryChanged }
            // Photos removes nothing unless each photo still has the revision it had when reviewed.
            var expected: [DeviceAssetID: AssetRevision] = [:]
            for photo in reviewed {
                guard let modified = photo.modified else { throw Self.libraryChanged }
                expected[DeviceAssetID(rawValue: photo.id)] = AssetRevision(modified)
            }
            guard let currentSession = try KeychainCredentialStore().load(), currentSession.scope == originalSession.scope,
                  currentSession.token == originalSession.token else { throw APIError.signedOut }
            try Task.checkCancellation()
            guard !ReadOnlyPolicy.isEnabled(server: currentSession.server, userID: currentSession.userID) else { throw ReadOnlyPolicy.ReadOnlyError() }
            let removal = DeviceMutation.delete(reviewed.map { DeviceAssetID(rawValue: $0.id) }, expected: expected,
                                                origin: .cleanup(scan: scan, account: currentSession.scope))
            // Once asked, Photos finishes the removal even if this screen goes, and the journal keeps how it ended.
            switch await PhotoKitAdapter.shared.perform(removal).outcome {
            case .committed:
                photos.removeAll { requested.contains($0.id) }; selection = []; message = "Removed \(requested.count) items from Apple Photos. Your server copies are kept."
            case .declined, .interrupted:
                // Declining iOS's prompt is the person's answer, not an error. Nothing was removed.
                break
            case .revisionChanged: throw Self.libraryChanged
            case .notPermitted: throw BackupError.message("Photos does not allow removing one of the selected items. Nothing was removed.")
            case .failed(let reason): throw BackupError.message(reason)
            }
        } catch is CancellationError { } catch { failure = .init(error) }
    }
    private static let libraryChanged = BackupError.message("Your photo library changed. Nothing was removed. Check again before continuing.")
    private func invalidate() { operation?.cancel(); selection = []; photos = []; checked = false; message = nil }
    private func initializeFilters() {
        permission = DevicePhotos.authorization; albums = DevicePhotos.albums()
        if !defaultsInitialized, [.authorized, .limited].contains(permission) {
            let messaging = ["whatsapp", "telegram", "signal", "messenger", "viber", "wechat", "line"]
            let defaults = albums.filter { album in messaging.contains { album.title.localizedCaseInsensitiveContains($0) } }.map(\.id)
            keepAlbumData = (try? JSONEncoder().encode(keptAlbums.union(defaults))) ?? Data(); defaultsInitialized = true
        }
    }
    private func protectedAlbumAssets() -> Set<String> {
        var ids = Set<String>()
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(keptAlbums), options: nil).enumerateObjects { album, _, _ in
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        }
        return ids
    }
    private func eligible(_ asset: PHAsset, protected: Set<String>) -> Bool {
        policy.allows(date: asset.creationDate, favorite: asset.isFavorite, video: asset.mediaType == .video, inKeptAlbum: protected.contains(asset.localIdentifier))
    }
}

@MainActor private func openPhotoSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}

import IlyichPlatform
import SwiftUI
@preconcurrency import Photos

struct LocalLibraryView: View {
    var destinationAlbumID: String? = nil
    var destinationAlbumName: String? = nil
    var onBackupFinished: (() -> Void)? = nil
    @State private var initialized = false
    @State private var watchingUploads = false
    @State private var library = DeviceBrowserStore()
    @State private var backup = BackupStore.shared
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
        .task { if !initialized { initialized = true; selecting = destinationAlbumID != nil }; await library.start() }
        .onChange(of: backup.isRunning) { _, running in
            if watchingUploads && !running { onBackupFinished?(); watchingUploads = false }
        }
        .onChange(of: showBackup) { _, shown in if !shown { onBackupFinished?() } }
        .onDisappear { library.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await library.start() } } }
        .onChange(of: library.albumID) { _, _ in selection = []; Task { await library.selectAlbum() } }
        .onChange(of: library.photos) { _, values in selection.formIntersection(Set(values.map(\.id))) }
        .fullScreenCover(item: $viewing) { LocalPhotoViewer(photo: $0, onChanged: { Task { await library.refresh() } }) }
        .sheet(isPresented: $showActions) { NavigationStack { LocalPhotoActionsView(photos: actionPhotos) { _ in selection = []; selecting = false; Task { await library.refresh() } } } }
        .sheet(isPresented: $accessPicker, onDismiss: { Task { await library.refresh() } }) { LimitedPhotoAccessPicker { accessPicker = false; Task { await library.refresh() } } }
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
                    .onAppear { if library.isNearEnd(photo.id) { Task { await library.loadMore() } } }
                }
            }
            Text("\(library.total.formatted()) item\(library.total == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary).padding()
        }.refreshable { await library.refresh() }
    }
    private func upload() async {
        uploading = true; defer { uploading = false }
        watchingUploads = true
        if await backup.enqueue(localIDs: Array(selection), albumID: destinationAlbumID) == .queued { selection = []; selecting = false }
        showBackup = true
    }
}

@MainActor func openPhotoSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}

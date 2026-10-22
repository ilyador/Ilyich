import SwiftUI
import Photos
import IlyichPlatform

struct LocalPhotoActionsView: View {
    let onChanged: (DevicePhotoChange) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("shareFileType") private var quality = "original"
    @AppStorage("shareDownloadCloud") private var allowCloud = false
    @State private var backup = BackupStore.shared
    @State private var store: DevicePhotoActionsStore
    @State private var operation: Task<Void, Never>?
    @State private var confirmDelete = false

    init(photos: [LocalPhoto], onChanged: @escaping (DevicePhotoChange) -> Void) {
        self.onChanged = onChanged
        _store = State(initialValue: DevicePhotoActionsStore(photos: photos))
    }

    private var photos: [LocalPhoto] { store.photos }
    private var busy: Bool { store.busy }
    var body: some View {
        Form {
            Section {
                Text("\(photos.count.formatted()) \(photos.count == 1 ? "item" : "items") on this phone").font(.headline)
                if photos.count == 1, let photo = photos.first { LocalPhotoThumbnail(photo: photo).frame(height: 160).clipShape(.rect(cornerRadius: 12)) }
            }
            Section {
                if photos.contains(where: { !$0.video }) {
                    Picker("Photo quality", selection: $quality) { Text("Full size").tag("original"); Text("Preview").tag("preview") }.disabled(busy)
                }
                Toggle("Download from iCloud if needed", isOn: $allowCloud).disabled(busy)
                Button("Share", systemImage: "square.and.arrow.up") { operation = Task { await store.prepareShare(preview: quality == "preview", allowCloud: allowCloud) } }.disabled(busy || photos.isEmpty)
                if store.preparing {
                    ProgressView(value: store.progress).accessibilityLabel("Preparing files to share")
                    Button("Cancel preparation", role: .cancel) { operation?.cancel() }
                }
            } header: { Text("Share files") } footer: {
                Text("Previews are smaller JPEGs; videos always use their full-size file. Files are copied to temporary storage. iCloud downloads may use mobile data.")
            }
            Section {
                Button(store.makeFavorite ? "Add to favorites" : "Remove from favorites", systemImage: store.makeFavorite ? "heart" : "heart.slash") { operation = Task { await finish(store.favorite()) } }.disabled(busy || photos.isEmpty).requiresWriteAccess()
                Button("Back up selected", systemImage: "icloud.and.arrow.up") { operation = Task { await store.backUp() } }.disabled(busy || photos.isEmpty || backup.isRunning).requiresWriteAccess()
                Button("Remove from Apple Photos", systemImage: "trash", role: .destructive) { confirmDelete = true }.disabled(busy || photos.isEmpty).requiresWriteAccess()
            } footer: { Text("These actions affect the copies in Apple Photos. Removing them also affects iCloud Photos and other devices that sync with it. Existing server copies stay on the server.") }
        }.navigationTitle("Photo actions").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .confirmationDialog("Remove \(photos.count) \(photos.count == 1 ? "item" : "items") from Apple Photos?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove from Photos", role: .destructive) { operation = Task { await finish(store.remove()) } }.requiresWriteAccess()
        } message: { Text("This also removes them from iCloud Photos and synced devices. They move to Apple Photos’ Recently Deleted album. Items without a server backup could be lost when that album is cleared.") }
        .sheet(item: $store.share, onDismiss: store.cleanupShare) { package in LocalShareSheet(urls: package.urls) { store.share = nil } }
        .sheet(isPresented: $store.showBackup) { NavigationStack { BackupSettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { store.showBackup = false } } } } }
        .alert("Couldn’t complete photo action", isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(store.failure?.message ?? "") }
        .task { await store.refresh() }
        .onDisappear { operation?.cancel(); store.abandon() }
    }

    /// Tells the screen below and closes once a change to Photos is made.
    private func finish(_ change: DevicePhotoChange?) {
        guard let change else { return }
        onChanged(change); dismiss()
    }
}

private struct LocalShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinished: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in Task { @MainActor in onFinished() } }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

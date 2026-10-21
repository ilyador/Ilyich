import SwiftUI
import Photos
import IlyichPlatform

struct LocalPhotoActionsView: View {
    let photos: [LocalPhoto]
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("shareFileType") private var quality = "original"
    @AppStorage("shareDownloadCloud") private var allowCloud = false
    @State private var backup = BackupCoordinator.shared
    @State private var busy = false
    @State private var preparing = false
    @State private var progress: Double?
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var confirmDelete = false
    @State private var failure: FeatureFailure?
    @State private var share: LocalSharePackage?
    @State private var exportFolder: URL?
    @State private var showBackup = false
    private var makeFavorite: Bool { !photos.allSatisfy(\.isFavorite) }
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
                Button("Share", systemImage: "square.and.arrow.up") { operation = Task { await prepareShare() } }.disabled(busy || photos.isEmpty)
                if preparing {
                    ProgressView(value: progress).accessibilityLabel("Preparing files to share")
                    Button("Cancel preparation", role: .cancel) { operation?.cancel() }
                }
            } header: { Text("Share files") } footer: {
                Text("Previews are smaller JPEGs; videos always use their full-size file. Files are copied to temporary storage. iCloud downloads may use mobile data.")
            }
            Section {
                Button(makeFavorite ? "Add to favorites" : "Remove from favorites", systemImage: makeFavorite ? "heart" : "heart.slash") { operation = Task { await favorite() } }.disabled(busy || photos.isEmpty).requiresWriteAccess()
                Button("Back up selected", systemImage: "icloud.and.arrow.up") { operation = Task { await upload() } }.disabled(busy || photos.isEmpty || backup.isRunning).requiresWriteAccess()
                Button("Remove from Apple Photos", systemImage: "trash", role: .destructive) { confirmDelete = true }.disabled(busy || photos.isEmpty).requiresWriteAccess()
            } footer: { Text("These actions affect the copies in Apple Photos. Removing them also affects iCloud Photos and other devices that sync with it. Existing server copies stay on the server.") }
        }.navigationTitle("Photo actions").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .confirmationDialog("Remove \(photos.count) \(photos.count == 1 ? "item" : "items") from Apple Photos?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove from Photos", role: .destructive) { operation = Task { await remove() } }.requiresWriteAccess()
        } message: { Text("This also removes them from iCloud Photos and synced devices. They move to Apple Photos’ Recently Deleted album. Items without a server backup could be lost when that album is cleared.") }
        .sheet(item: $share, onDismiss: cleanupShare) { package in LocalShareSheet(urls: package.urls) { share = nil } }
        .sheet(isPresented: $showBackup) { NavigationStack { BackupSettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showBackup = false } } } } }
        .alert("Couldn’t complete photo action", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
        .onDisappear { operation?.cancel(); generation = UUID(); busy = false; preparing = false; if share == nil { cleanupShare() } }
    }
    private func fetchAssets(checkRevision: Bool) throws -> [PHAsset] {
        guard [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else { throw BackupError.message("Allow Photos access in Settings to use these items.") }
        let ids = photos.map(\.id)
        guard Set(ids).count == ids.count, !ids.isEmpty else { throw BackupError.message("Select the photos again before continuing.") }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let byID = Dictionary(uniqueKeysWithValues: (0..<fetched.count).map { let asset = fetched.object(at: $0); return (asset.localIdentifier, asset) })
        return try photos.map { photo in
            guard let asset = byID[photo.id] else { throw BackupError.message("Some selected photos are no longer available. Refresh your selection and try again.") }
            if checkRevision, asset.modificationDate != photo.modified { throw BackupError.message("A selected photo changed. Refresh your selection before removing it.") }
            return asset
        }
    }
    private func writeSession() throws -> StoredCredential {
        guard let saved = try KeychainCredentialStore().load() else { throw APIError.signedOut }
        guard !ReadOnlyPolicy.isEnabled(server: saved.server, userID: saved.userID) else { throw ReadOnlyPolicy.ReadOnlyError() }
        return saved
    }
    private func favorite() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            _ = try writeSession(); let assets = try fetchAssets(checkRevision: false), value = makeFavorite
            guard assets.allSatisfy({ $0.canPerform(.properties) }) else { throw BackupError.message("Photos does not allow changing one of the selected items.") }
            try Task.checkCancellation(); _ = try writeSession()
            try await PHPhotoLibrary.shared().performChanges(PhotoChanges.favorite(assets.map(\.localIdentifier), value))
            onChanged(); dismiss()
        } catch is CancellationError { } catch { failure = .init(error) }
    }
    private func remove() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            _ = try writeSession(); let assets = try fetchAssets(checkRevision: true)
            guard assets.allSatisfy({ $0.canPerform(.delete) }) else { throw BackupError.message("Photos does not allow removing one of the selected items.") }
            try Task.checkCancellation(); _ = try writeSession()
            try await PHPhotoLibrary.shared().performChanges(PhotoChanges.delete(assets.map(\.localIdentifier)))
            onChanged(); dismiss()
        } catch is CancellationError { } catch { failure = .init(error) }
    }
    private func upload() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            _ = try writeSession(); _ = try fetchAssets(checkRevision: false)
            await backup.enqueue(localIDs: photos.map(\.id))
            if let error = backup.error { throw BackupError.message(error) }
            showBackup = true
        } catch is CancellationError { } catch { failure = .init(error) }
    }
    private func prepareShare() async {
        guard !busy else { return }; busy = true; preparing = true; progress = 0
        let token = UUID(); generation = token
        defer { if generation == token { busy = false; preparing = false } }
        do {
            let assets = try fetchAssets(checkRevision: false)
            let package = try await LocalShareExporter.prepare(assets: assets, preview: quality == "preview", allowCloud: allowCloud) { value in
                Task { @MainActor in if generation == token { progress = value } }
            }
            guard generation == token, !Task.isCancelled else { package.remove(); throw CancellationError() }
            exportFolder = package.folder; share = package
        } catch is CancellationError { } catch { if generation == token { failure = .init(error) } }
    }
    private func cleanupShare() {
        if let exportFolder { try? FileManager.default.removeItem(at: exportFolder) }
        exportFolder = nil
    }
}

private struct LocalSharePackage: Identifiable {
    let id = UUID()
    let folder: URL
    let urls: [URL]
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

@MainActor private enum LocalShareExporter {
    static func prepare(assets: [PHAsset], preview: Bool, allowCloud: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> LocalSharePackage {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IlyichLocalShare-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        let total = assets.count
        do {
            for (index, asset) in assets.enumerated() {
                try Task.checkCancellation()
                let itemFolder = folder.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
                let itemProgress: @Sendable (Double) -> Void = { value in progress((Double(index) + min(1, max(0, value))) / Double(total)) }
                let file: URL
                if preview && asset.mediaType != .video {
                    let resource = PHAssetResource.assetResources(for: asset).first
                    let name = ((resource?.originalFilename ?? "Photo") as NSString).lastPathComponent
                    let base = (name as NSString).deletingPathExtension
                    file = itemFolder.appendingPathComponent((base.isEmpty ? "Photo" : base) + "-preview.jpg")
                    let data = try await LocalSharePreview().jpeg(asset: asset, allowCloud: allowCloud, progress: itemProgress)
                    try data.write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
                } else {
                    let resource = try await DevicePhotos.currentResource(for: asset, allowCloud: allowCloud, allowCellular: true, progress: itemProgress)
                    let name = (resource.originalFilename as NSString).lastPathComponent
                    file = itemFolder.appendingPathComponent(name.isEmpty ? "Photo.\(resource.contentType.preferredFilenameExtension ?? "dat")" : name)
                    let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = allowCloud; options.progressHandler = itemProgress
                    try await PhotoResourceExport(destination: file).write(resource, options: options)
                }
                try Task.checkCancellation(); urls.append(file); progress(Double(index + 1) / Double(total))
            }
            return .init(folder: folder, urls: urls)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}

@MainActor private final class LocalSharePreview {
    private var requestID: PHImageRequestID?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var finished = false
    func jpeg(asset: PHAsset, allowCloud: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let options = PHImageRequestOptions(); options.version = .current; options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = allowCloud; options.progressHandler = { value, _, _, _ in progress(value) }
                requestID = PHImageManager.default().requestImage(for: asset, targetSize: .init(width: 2048, height: 2048), contentMode: .aspectFit, options: options) { image, info in
                    guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                    let data = image?.jpegData(compressionQuality: 0.9)
                    let cancelled = info?[PHImageCancelledKey] as? Bool == true
                    Task { @MainActor in
                        if let data { self.finish(.success(data)) }
                        else if cancelled { self.finish(.failure(CancellationError())) }
                        else { self.finish(.failure(BackupError.message("This photo could not be prepared. If it is stored in iCloud, allow iCloud downloads and retry."))) }
                    }
                }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }
    private func finish(_ result: Result<Data, any Error>) {
        guard !finished else { return }; finished = true
        if case .failure = result, let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        continuation?.resume(with: result); continuation = nil
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

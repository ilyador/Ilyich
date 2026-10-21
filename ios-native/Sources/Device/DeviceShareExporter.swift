import Foundation
import UIKit

/// Files prepared for the share sheet, in a temporary folder of their own.
struct LocalSharePackage: Identifiable, Sendable {
    let id = UUID()
    let folder: URL
    let urls: [URL]
}

/// What sharing phone photos reads from Photos (PhotoKitAdapter implements it).
protocol DeviceShareSource: Sendable {
    /// Copies the asset's current full-size file into `folder` under its original name.
    func exportCurrent(of localID: String, into folder: URL, allowCloud: Bool,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    /// The current version as a still fitted in 2048 pixels.
    func shareStill(of localID: String, allowCloud: Bool,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> DeviceStill
}

extension PhotoKitAdapter: DeviceShareSource {}

/// Prepares phone photos for the share sheet, on a queue of its own: full-size files are copied
/// from Photos, and previews are encoded as JPEG here, never on the main thread. Each share gets a
/// tmp/IlyichLocalShare-* folder, removed when the sheet closes; any a killed app left behind are
/// swept at the next launch.
actor DeviceShareExporter {
    static let shared = DeviceShareExporter()
    static let folderPrefix = "IlyichLocalShare-"

    private nonisolated let queue = DispatchSerialQueue(label: "app.ilyich.share-export", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let source: any DeviceShareSource
    private let directory: URL

    init(source: any DeviceShareSource = PhotoKitAdapter.shared, directory: URL = FileManager.default.temporaryDirectory) {
        self.source = source
        self.directory = directory
    }

    /// Copies or renders each photo, in order. Previews apply to photos only; videos always share
    /// their full-size file. Cancelling, or any failure, removes everything prepared.
    func prepare(_ photos: [LocalPhoto], preview: Bool, allowCloud: Bool,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> LocalSharePackage {
        let folder = directory.appendingPathComponent(Self.folderPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        let total = photos.count
        do {
            for (index, photo) in photos.enumerated() {
                try Task.checkCancellation()
                let itemFolder = folder.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
                let itemProgress: @Sendable (Double) -> Void = { value in progress((Double(index) + min(1, max(0, value))) / Double(total)) }
                let file: URL
                if preview && !photo.video {
                    let still = try await source.shareStill(of: photo.id, allowCloud: allowCloud, progress: itemProgress)
                    let base = (still.filename as NSString).deletingPathExtension
                    file = itemFolder.appendingPathComponent((base.isEmpty ? "Photo" : base) + "-preview.jpg")
                    guard let data = still.image.jpegData(compressionQuality: 0.9) else {
                        throw BackupError.message("This photo could not be prepared. If it is stored in iCloud, allow iCloud downloads and retry.")
                    }
                    try data.write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
                } else {
                    file = try await source.exportCurrent(of: photo.id, into: itemFolder, allowCloud: allowCloud, progress: itemProgress)
                }
                try Task.checkCancellation()
                urls.append(file); progress(Double(index + 1) / Double(total))
            }
            return LocalSharePackage(folder: folder, urls: urls)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Removes a share's folder once the sheet is done with it.
    func remove(_ folder: URL) {
        guard folder.lastPathComponent.hasPrefix(Self.folderPrefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes every share folder in `directory`, as one left by a share the app never finished.
    /// Run at launch, before any share starts. Returns how many it removed.
    @discardableResult
    nonisolated static func sweep(in directory: URL = FileManager.default.temporaryDirectory) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix(folderPrefix) {
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}

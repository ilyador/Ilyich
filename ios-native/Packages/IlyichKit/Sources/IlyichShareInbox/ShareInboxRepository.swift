import Foundation
import IlyichPlatform

/// What a batch folder holds: a batch ready to upload, or one that can't be used.
public enum ShareBatchState: Hashable, Sendable {
    case ready(SharedBatch)
    case damaged(id: UUID, reason: ShareBatchDamage)

    public var id: UUID {
        switch self {
        case .ready(let batch): batch.id
        case .damaged(let id, _): id
        }
    }

    public var batch: SharedBatch? {
        if case .ready(let batch) = self { batch } else { nil }
    }
}

/// The share inbox in the App Group: one folder per batch, holding its files, its manifest and
/// the upload body and outcome files of its attachments. The Share extension stages batches; the
/// app lists them, consumes attachments once uploaded, and discards batches. Each batch is read on
/// its own, so a damaged one never hides the others.
public actor ShareInboxRepository {
    /// The inbox's folder in the App Group container.
    public static let folderName = "ShareInbox"
    /// A batch folder still without a manifest after this long was left by a staging that never
    /// finished.
    public static let abandonedAge: TimeInterval = 24 * 3600

    public nonisolated let root: URL
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - root: the inbox folder, which holds one folder per batch.
    ///   - now: the clock that ages folders without a manifest.
    public init(root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.now = now
    }

    /// The inbox in this bundle's App Group container.
    public static func appGroup() throws(AppGroupError) -> ShareInboxRepository {
        ShareInboxRepository(root: try AppGroupLayout.current().container.appendingPathComponent(folderName, isDirectory: true))
    }

    public nonisolated func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// Every batch, ready ones oldest first, then damaged ones. Folders left without a manifest for
    /// 24 hours are deleted on the way. Throws only when the inbox folder itself can't be listed.
    public func load() throws -> [ShareBatchState] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        var ready: [SharedBatch] = []
        var damaged: [ShareBatchState] = []
        for name in try manager.contentsOfDirectory(atPath: root.path) {
            guard let id = UUID(uuidString: name) else { continue }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard manager.fileExists(atPath: folder.appendingPathComponent(ShareManifest.fileName, isDirectory: false).path) else {
                if isAbandoned(folder) { try? manager.removeItem(at: folder) }
                continue
            }
            do throws(ShareBatchDamage) { ready.append(try read(id: id, folder: folder)) }
            catch { damaged.append(.damaged(id: id, reason: error)) }
        }
        ready.sort { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        damaged.sort { $0.id.uuidString < $1.id.uuidString }
        return ready.map(ShareBatchState.ready) + damaged
    }

    /// One batch, read on its own and validated as `load` reads it: nil when its folder or manifest
    /// is gone.
    public func batch(_ id: UUID) -> ShareBatchState? {
        let folder = folder(for: id)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(ShareManifest.fileName, isDirectory: false).path) else {
            return nil
        }
        do throws(ShareBatchDamage) { return .ready(try read(id: id, folder: folder)) }
        catch { return .damaged(id: id, reason: error) }
    }

    /// Creates the empty folder of a batch about to be staged, excluded from device backups.
    public func createFolder(for id: UUID) throws -> URL {
        var folder = folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder
    }

    /// Writes a staged batch's manifest as version 2, once its files are checked and protected
    /// until the phone's first unlock. Its files must already be in the batch's folder.
    public func save(_ batch: SharedBatch) throws {
        let folder = folder(for: batch.id)
        let batch = try Self.resolved(batch, in: folder)
        try Self.validateFiles(batch, folder: folder)
        for file in batch.attachments.flatMap(\.files) {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: file.url.path)
        }
        try write(batch, folder: folder)
    }

    /// Takes an uploaded attachment out of its batch: the manifest is rewritten without it, as
    /// version 2, before its files are deleted. Consuming the last one deletes the batch. An
    /// attachment or batch that is already gone counts as consumed.
    public func consume(_ attachmentID: String, from id: UUID) throws {
        let folder = folder(for: id)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(ShareManifest.fileName, isDirectory: false).path) else { return }
        var batch = try read(id: id, folder: folder)
        guard let index = batch.attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
        let item = batch.attachments.remove(at: index)
        guard !batch.attachments.isEmpty else { try remove(id); return }
        try write(batch, folder: folder)
        for file in item.files { try? FileManager.default.removeItem(at: file.url) }
    }

    /// Deletes a batch's folder and everything in it. A batch that is already gone is fine.
    public func remove(_ id: UUID) throws {
        do { try FileManager.default.removeItem(at: folder(for: id)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }

    /// Deletes the batch folders that have had no manifest for 24 hours, and returns their IDs.
    @discardableResult public func collectGarbage() -> [UUID] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var removed: [UUID] = []
        for name in names {
            guard let id = UUID(uuidString: name) else { continue }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard isAbandoned(folder), (try? FileManager.default.removeItem(at: folder)) != nil else { continue }
            removed.append(id)
        }
        return removed
    }

    // MARK: Reading and writing

    private func read(id: UUID, folder: URL) throws(ShareBatchDamage) -> SharedBatch {
        let manifest = folder.appendingPathComponent(ShareManifest.fileName, isDirectory: false)
        let data: Data
        do {
            let size = try FileManager.default.attributesOfItem(atPath: manifest.path)[.size] as? Int ?? 0
            guard size <= ShareManifest.maximumSize else { throw ShareBatchDamage.tooLarge }
            data = try Data(contentsOf: manifest)
        } catch let damage as ShareBatchDamage { throw damage }
        catch { throw .unreadable }
        guard data.count <= ShareManifest.maximumSize else { throw .tooLarge }
        let batch = try ShareManifest.decode(data, batch: id, folder: folder)
        try Self.validateFiles(batch, folder: folder)
        return batch
    }

    private func write(_ batch: SharedBatch, folder: URL) throws {
        try ShareManifest.encode(batch).write(to: folder.appendingPathComponent(ShareManifest.fileName, isDirectory: false),
                                              options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// A folder without a manifest whose creation and last change are both 24 hours old.
    private func isAbandoned(_ folder: URL) -> Bool {
        guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]),
              values.isDirectory == true,
              !FileManager.default.fileExists(atPath: folder.appendingPathComponent(ShareManifest.fileName, isDirectory: false).path),
              let latest = [values.creationDate, values.contentModificationDate].compactMap({ $0 }).max() else { return false }
        return now().timeIntervalSince(latest) > Self.abandonedAge
    }

    /// The batch with every file named in `folder`.
    private static func resolved(_ batch: SharedBatch, in folder: URL) throws(ShareBatchDamage) -> SharedBatch {
        guard (1...ShareManifest.maximumAttachments).contains(batch.attachments.count) else { throw .invalid }
        func file(_ file: SharedFile) throws(ShareBatchDamage) -> SharedFile {
            guard ShareManifest.isPlainName(file.name) else { throw .invalid }
            return SharedFile(name: file.name, filename: file.filename, contentType: file.contentType, folder: folder)
        }
        var attachments: [SharedAttachment] = []
        for item in batch.attachments {
            var attachment = SharedAttachment(original: try file(item.original))
            if let motion = item.motion { attachment.motion = try file(motion) }
            if let sidecar = item.sidecar { attachment.sidecar = try file(sidecar) }
            attachments.append(attachment)
        }
        return SharedBatch(id: batch.id, createdAt: batch.createdAt, attachments: attachments)
    }

    /// Path confinement: every file must be a regular file directly inside the batch folder once
    /// symbolic links are resolved.
    static func validateFiles(_ batch: SharedBatch, folder: URL) throws(ShareBatchDamage) {
        let expected = folder.resolvingSymlinksInPath().standardizedFileURL.path
        for file in batch.attachments.flatMap(\.files) {
            let resolved = file.url.resolvingSymlinksInPath().standardizedFileURL
            guard file.url.isFileURL, resolved.deletingLastPathComponent().path == expected,
                  (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { throw .invalid }
        }
    }
}

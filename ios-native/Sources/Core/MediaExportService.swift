import Foundation
import IlyichPlatform
import Photos
import Synchronization

/// What an export makes: files for the share sheet, or new items in Photos.
struct ExportRequest: Hashable, Sendable {
    enum Destination: Hashable, Sendable { case files, photos }

    let assets: [Asset]
    /// The original file rather than the version the app shows, with its edits. A video is always
    /// its original, and a Live Photo saved to Photos is always its original still and motion.
    let original: Bool
    let destination: Destination

    static func share(_ assets: [Asset], original: Bool) -> ExportRequest { .init(assets: assets, original: original, destination: .files) }
    static func saveToPhotos(_ assets: [Asset], original: Bool) -> ExportRequest { .init(assets: assets, original: original, destination: .photos) }

    /// What its notifications call it.
    var kind: String { destination == .photos ? "Save to Photos" : "Download" }
}

/// How far an export has got.
struct ExportProgress: Equatable, Sendable {
    /// Photos finished.
    var completed = 0
    let total: Int
    /// The part of the whole export done, once the server has said how big a file is.
    var fraction: Double?
    /// A photo is being written to Photos. That can't be cancelled, and a cancelled export still
    /// saves it.
    var committing = false
}

enum ExportOutcome: Sendable {
    /// Every photo's file, ready for the share sheet.
    case files(ExportedFiles)
    /// Every photo was saved to Photos.
    case saved(Int)
    case cancelled(saved: Int)
    case failed(any Error, saved: Int)
}

/// Downloaded files waiting for the share sheet. Each sits in a temporary folder of its own, which
/// goes when the files are released or removed.
final class ExportedFiles: Identifiable, Sendable {
    let id = UUID()
    let urls: [URL]

    init(_ urls: [URL]) { self.urls = urls }
    deinit { remove() }

    func remove() { Self.remove(urls) }

    static func remove(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}

/// One running export. The service runs it; its holder can cancel it or wait for how it ends.
struct ExportJob: Sendable {
    let id: UUID
    fileprivate let task: Task<ExportOutcome, Never>

    /// Stops the export. A photo already being written to Photos is still saved.
    func cancel() { task.cancel() }
    var outcome: ExportOutcome { get async { await task.value } }
}

/// Writes downloaded media into the person's Photos library.
protocol PhotoLibraryWriting: Sendable {
    /// Asks to add to Photos, and says whether that is allowed, fully or for limited access.
    func requestAddAccess() async -> Bool
    /// Adds one photo, video or Live Photo. Once it starts it can't be cancelled.
    func add(_ file: URL, isVideo: Bool, pairedVideo: URL?) async throws
}

/// The count-only notifications of a transfer the person started.
protocol ExportNotifying: Sendable {
    func started(id: UUID, kind: String, total: Int) async
    func finished(id: UUID, kind: String, total: Int, completed: Int, failed: Int) async
    func cancel(id: UUID) async
}

/// Downloads server photos to share them or save them to Photos, one photo at a time, with
/// progress, cancellation and the transfer notifications. Downloads stay on disk, never in memory,
/// and every file it makes is removed when the export ends, or for shared files when they are
/// released.
final class MediaExportService: Sendable {
    private let api: APIClient
    private let photos: any PhotoLibraryWriting
    private let notifications: any ExportNotifying

    init(api: APIClient, photos: any PhotoLibraryWriting = SystemPhotoLibrary(),
         notifications: any ExportNotifying = TransferNotificationPoster()) {
        self.api = api; self.photos = photos; self.notifications = notifications
    }

    /// Starts an export. `progress` hears every step, from the export's own task.
    func start(_ request: ExportRequest, id: UUID = UUID(),
               progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }) -> ExportJob {
        let run = ExportRun(request: request, id: id, api: api, photos: photos, notifications: notifications,
                            reporter: ExportProgressReporter(total: request.assets.count, deliver: progress))
        return ExportJob(id: id, task: Task(priority: .userInitiated) { await run.perform() })
    }
}

/// The work of one export.
private struct ExportRun: Sendable {
    let request: ExportRequest
    let id: UUID
    let api: APIClient
    let photos: any PhotoLibraryWriting
    let notifications: any ExportNotifying
    let reporter: ExportProgressReporter

    func perform() async -> ExportOutcome {
        let total = request.assets.count
        var files: [URL] = [], saved = 0, started = false
        do {
            if request.destination == .photos {
                try checkWritable()
                guard await photos.requestAddAccess() else {
                    throw APIError.invalidResponse("Allow Ilyich to add photos in iPhone Settings, then try again.")
                }
                try Task.checkCancellation()
                try checkWritable()
            }
            started = true
            await notifications.started(id: id, kind: request.kind, total: total)
            for (index, asset) in request.assets.enumerated() {
                try Task.checkCancellation()
                switch request.destination {
                case .files:
                    let file = try await api.download(asset: asset, original: request.original, progress: { reporter.item(index, $0) })
                    files.append(file)
                case .photos:
                    try await save(asset, index: index)
                    saved += 1
                }
                reporter.finishItem()
            }
            // A share sheet must not open for an export cancelled after its last download.
            if request.destination == .files { try Task.checkCancellation() }
            await notifications.finished(id: id, kind: request.kind, total: total, completed: total, failed: 0)
            if Task.isCancelled { await notifications.cancel(id: id) }
            return request.destination == .files ? .files(ExportedFiles(files)) : .saved(saved)
        } catch {
            ExportedFiles.remove(files)
            if error is CancellationError || Task.isCancelled {
                if started { await notifications.cancel(id: id) }
                return .cancelled(saved: saved)
            }
            if started {
                let completed = request.destination == .files ? files.count : saved
                await notifications.finished(id: id, kind: request.kind, total: total, completed: completed, failed: total - completed)
                if Task.isCancelled { await notifications.cancel(id: id) }
            }
            return .failed(error, saved: saved)
        }
    }

    /// Downloads one photo and adds it to Photos. A Live Photo needs the original still and motion,
    /// whose matching identifiers pair them; a server-rendered JPEG can't stand in for the still.
    private func save(_ asset: Asset, index: Int) async throws {
        try checkWritable()
        let live = asset.livePhotoVideoId != nil
        let file = try await api.download(asset: asset, original: request.original || live,
                                          progress: { reporter.item(index, live ? $0.map { $0 / 2 } : $0) })
        defer { ExportedFiles.remove([file]) }
        var motion: URL?
        defer { if let motion { ExportedFiles.remove([motion]) } }
        if let motionID = asset.livePhotoVideoId {
            try Task.checkCancellation()
            try checkWritable()
            let motionAsset = try await api.asset(id: motionID)
            try Task.checkCancellation()
            try checkWritable()
            motion = try await api.download(asset: motionAsset, original: true, progress: { reporter.item(index, $0.map { 0.5 + $0 / 2 }) })
        }
        try Task.checkCancellation()
        try checkWritable()
        reporter.committing(true)
        defer { reporter.committing(false) }
        try await photos.add(file, isVideo: asset.isVideo, pairedVideo: motion)
    }

    private func checkWritable() throws {
        if api.isReadOnly { throw ReadOnlyPolicy.ReadOnlyError() }
    }
}

/// Turns each download's progress into the whole export's.
private final class ExportProgressReporter: Sendable {
    private let state: Mutex<ExportProgress>
    private let deliver: @Sendable (ExportProgress) -> Void

    init(total: Int, deliver: @escaping @Sendable (ExportProgress) -> Void) {
        state = Mutex(ExportProgress(total: total))
        self.deliver = deliver
    }

    /// The progress of photo `index`. Nil, when the server gave no size, keeps what is known, and a
    /// late report from a download already done changes nothing, so progress only grows.
    func item(_ index: Int, _ fraction: Double?) {
        guard let fraction else { return }
        update { progress in
            let whole = (Double(index) + min(1, max(0, fraction))) / Double(max(1, progress.total))
            guard index == progress.completed, whole > progress.fraction ?? -1 else { return false }
            progress.fraction = whole
            return true
        }
    }

    func finishItem() {
        update { $0.completed += 1; $0.fraction = Double($0.completed) / Double(max(1, $0.total)); return true }
    }

    func committing(_ value: Bool) { update { $0.committing = value; return true } }

    private func update(_ change: (inout ExportProgress) -> Bool) {
        let changed: ExportProgress? = state.withLock { progress in change(&progress) ? progress : nil }
        if let changed { deliver(changed) }
    }
}

/// Photos itself, for adding only.
struct SystemPhotoLibrary: PhotoLibraryWriting {
    func requestAddAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    func add(_ file: URL, isVideo: Bool, pairedVideo: URL?) async throws {
        try await PHPhotoLibrary.shared().performChanges(Self.changeBlock(file: file, isVideo: isVideo, pairedVideo: pairedVideo))
    }

    // PhotoKit runs this block on its own queue; built outside any actor, it carries no executor
    // check that would trap there.
    private nonisolated static func changeBlock(file: URL, isVideo: Bool, pairedVideo: URL?) -> @Sendable () -> Void {
        {
            let creation = PHAssetCreationRequest.forAsset()
            creation.addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
            if let pairedVideo { creation.addResource(with: .pairedVideo, fileURL: pairedVideo, options: nil) }
        }
    }
}

/// The app's transfer notifications.
struct TransferNotificationPoster: ExportNotifying {
    func started(id: UUID, kind: String, total: Int) async { await TransferNotifications.started(id: id, kind: kind, total: total) }
    func finished(id: UUID, kind: String, total: Int, completed: Int, failed: Int) async {
        await TransferNotifications.finished(id: id, kind: kind, total: total, completed: completed, failed: failed)
    }
    func cancel(id: UUID) async { await TransferNotifications.cancel(id: id) }
}

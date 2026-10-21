import Foundation
import Photos
import Synchronization
import UIKit
import XCTest
@testable import Ilyich

/// The phone-photo actions: backup's own outcome, share folders swept at launch and previews
/// encoded off the main thread, removal after a favorite, and the offline fallback surviving a
/// favorite.
@MainActor final class DevicePhotoActionsTests: XCTestCase {
    private let photo = LocalPhoto(id: "A/L0/001", date: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                   modified: Date(timeIntervalSinceReferenceDate: FakePhotoKit.revision))

    /// Backing up takes the outcome of its own enqueue. An error the coordinator still shows from
    /// an earlier run is not reported for it, and a refusal of this one is.
    func testBackupEnqueueOutcomeIgnoresStaleCoordinatorError() async throws {
        let backup = FakeBackup()
        backup.error = "The server could not be reached."
        let device = FakeDevice(photos: [photo])
        let store = DevicePhotoActionsStore(photos: [photo], device: device, backup: backup, authorize: {})

        await store.backUp()
        XCTAssertNil(store.failure, "The earlier run's error is not this enqueue's.")
        XCTAssertTrue(store.showBackup)
        XCTAssertEqual(backup.enqueued, [[photo.id]])

        store.showBackup = false
        backup.outcome = .failed("Pause backup before adding selected photos.")
        await store.backUp()
        XCTAssertEqual(store.failure?.message, "Pause backup before adding selected photos.")
        XCTAssertFalse(store.showBackup)
    }

    /// Share folders a killed app left in tmp are removed at launch; nothing else there is.
    func testFoldersSweptAtLaunch() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("SweepTest-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let leaked = [tmp.appendingPathComponent("IlyichLocalShare-1", isDirectory: true), tmp.appendingPathComponent("IlyichLocalShare-2", isDirectory: true)]
        let kept = tmp.appendingPathComponent("Other-1", isDirectory: true)
        for folder in leaked + [kept] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("0"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("0/IMG_0001.HEIC"))
        }

        XCTAssertEqual(DeviceShareExporter.sweep(in: tmp), 2)
        for folder in leaked { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    /// A preview share is rendered by Photos and encoded off the main thread, in a share folder that
    /// removing the package deletes.
    func testPreviewShareEncodesOffMainAndRemovesItsFolder() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShareTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let source = FakeShareSource()
        let exporter = DeviceShareExporter(source: source, directory: tmp)

        let package = try await exporter.prepare([photo], preview: true, allowCloud: false) { _ in }

        XCTAssertEqual(package.urls.map(\.lastPathComponent), ["IMG_0001-preview.jpg"])
        XCTAssertTrue(package.folder.lastPathComponent.hasPrefix(DeviceShareExporter.folderPrefix))
        XCTAssertNotNil(UIImage(contentsOfFile: try XCTUnwrap(package.urls.first).path))
        XCTAssertEqual(source.requestsOnMain, 0)
        await exporter.remove(package.folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.folder.path))
    }

    /// Favoriting the phone copy moves its modification date but not its photo. The offline
    /// fallback still uses it, and removing it afterwards holds it to the revision it has now.
    /// An edit ends both.
    func testFavoriteToggleDoesNotDisableOfflineFallback() async throws {
        let photos = FakePhotoKit()
        photos.add(photo.id)
        let adapter = PhotoKitAdapter(library: photos, assets: photos, journal: DeviceDatabase(url: deviceDatabaseURL()), staging: photos)
        await adapter.start()
        var server = Asset(id: "server-1")
        server.hasKnownEditState = true
        let offline = URLError(.notConnectedToInternet)
        let id = DeviceAssetID(rawValue: photo.id)
        let before = AssetRevision(referenceSeconds: FakePhotoKit.revision)
        let favorited = AssetRevision(referenceSeconds: FakePhotoKit.revision + 5)

        var fallback = await LocalMediaFallback.photo(after: offline, asset: server, matched: photo, active: true, device: adapter)
        XCTAssertEqual(fallback, photo)

        // Photos reports the favorite as a change that left the content alone.
        photos.touch(photo.id, revision: favorited.referenceSeconds)
        photos.emit(PhotoLibraryChangeDetails(changed: [id], metadataOnly: [id: RevisionStep(before: before, after: favorited)]))
        fallback = await LocalMediaFallback.photo(after: offline, asset: server, matched: photo, active: true, device: adapter)
        XCTAssertEqual(fallback, photo, "A favorite keeps the offline fallback.")
        let removable = await adapter.currentRevision(of: photo.id, sameContentAs: photo.modified)
        XCTAssertEqual(removable, favorited)

        // An edit changes the content.
        let edited = AssetRevision(referenceSeconds: FakePhotoKit.revision + 10)
        photos.touch(photo.id, revision: edited.referenceSeconds)
        photos.emit(PhotoLibraryChangeDetails(changed: [id]))
        fallback = await LocalMediaFallback.photo(after: offline, asset: server, matched: photo, active: true, device: adapter)
        XCTAssertNil(fallback, "An edit ends the match.")
        let afterEdit = await adapter.currentRevision(of: photo.id, sameContentAs: photo.modified)
        XCTAssertNil(afterEdit)
    }

    /// Removing a photo favorited since it was chosen passes the revision it has now, and tells the
    /// screen which photos went.
    func testRemovalAfterFavoriteNamesTheCurrentRevision() async throws {
        let device = FakeDevice(photos: [photo])
        let current = AssetRevision(referenceSeconds: FakePhotoKit.revision + 5)
        device.revision = current
        let store = DevicePhotoActionsStore(photos: [photo], device: device, backup: FakeBackup(), authorize: {})

        let change = await store.remove()

        XCTAssertEqual(change, .removed([photo.id]))
        XCTAssertEqual(device.performed, [.delete([DeviceAssetID(rawValue: photo.id)], expected: [DeviceAssetID(rawValue: photo.id): current], origin: .user)])
    }
}

@MainActor private final class FakeBackup: BackupEnqueuing {
    var error: String?
    var outcome = BackupEnqueueOutcome.queued
    var enqueued: [[String]] = []
    func enqueue(localIDs: [String], albumID: String?) async -> BackupEnqueueOutcome {
        enqueued.append(localIDs)
        return outcome
    }
}

private final class FakeDevice: DevicePhotoActing, @unchecked Sendable {
    private let lock = NSLock()
    private let photos: [LocalPhoto]
    private var _performed: [DeviceMutation] = []
    private var _revision: AssetRevision?
    init(photos: [LocalPhoto]) { self.photos = photos }
    var performed: [DeviceMutation] { lock.withLock { _performed } }
    var revision: AssetRevision? {
        get { lock.withLock { _revision } }
        set { lock.withLock { _revision = newValue } }
    }
    var authorization: PHAuthorizationStatus { .authorized }
    func perform(_ mutation: DeviceMutation) async -> DeviceMutationResult {
        lock.withLock { _performed.append(mutation) }
        let ids: [DeviceAssetID]
        switch mutation {
        case .delete(let values, _, _), .setFavorite(let values, _, _): ids = values
        case .create: ids = []
        }
        return DeviceMutationResult(id: UUID(), mutation: mutation, outcome: .committed(affected: ids, created: []))
    }
    func photos(withIDs ids: [String]) async -> [LocalPhoto] { photos.filter { ids.contains($0.id) } }
    func currentRevision(of localID: String, sameContentAs recorded: Date?) async -> AssetRevision? { revision }
}

private final class FakeShareSource: DeviceShareSource {
    private let onMain = Mutex(0)
    var requestsOnMain: Int { onMain.withLock { $0 } }
    private static func onMainThread() -> Bool { Thread.isMainThread }
    func exportCurrent(of localID: String, into folder: URL, allowCloud: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if Self.onMainThread() { onMain.withLock { $0 += 1 } }
        let file = folder.appendingPathComponent("IMG_0001.HEIC")
        try Data("original".utf8).write(to: file)
        return file
    }
    func shareStill(of localID: String, allowCloud: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> DeviceStill {
        if Self.onMainThread() { onMain.withLock { $0 += 1 } }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return DeviceStill(image: image, filename: "IMG_0001.HEIC")
    }
}

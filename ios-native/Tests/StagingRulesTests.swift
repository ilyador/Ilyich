import CoreLocation
import Foundation
import IlyichShareInbox
import Photos
import XCTest
@testable import Ilyich

/// What staging a phone photo copies, decided from its resources alone (P2): the current file,
/// RAW or JPEG by the editing input, the Live Photo's motion, XMP sidecars and mobile-app metadata.
final class StagingRulesTests: XCTestCase {
    private func r(_ type: PHAssetResourceType, _ contentType: String = "public.heic", _ filename: String = "IMG_0001.HEIC") -> StagingResource {
        StagingResource(type: type, contentType: contentType, filename: filename)
    }

    func testResourceTable() {
        let table: [(resources: [StagingResource], isVideo: Bool, choice: CurrentResourceChoice)] = [
            ([r(.photo)], false, .resource(0)),
            ([r(.video)], true, .resource(0)),
            // An edit Photos has rendered wins, wherever it is.
            ([r(.photo), r(.adjustmentData), r(.fullSizePhoto)], false, .resource(2)),
            ([r(.video), r(.adjustmentData), r(.fullSizeVideo)], true, .resource(2)),
            ([r(.photo), r(.pairedVideo), r(.fullSizePhoto), r(.fullSizePairedVideo)], false, .resource(2)),
            // A video's rendered edit is its full-size video, never a full-size photo.
            ([r(.video), r(.fullSizePhoto)], true, .resource(0)),
            // Live Photo: the still is the original.
            ([r(.photo), r(.pairedVideo)], false, .resource(0)),
            ([r(.pairedVideo), r(.photo)], false, .resource(1)),
            // RAW and JPEG: Photos' editing input decides.
            ([r(.photo, "public.jpeg"), r(.alternatePhoto, "com.adobe.raw-image")], false, .byEditingInput([0, 1])),
            ([r(.alternatePhoto, "com.adobe.raw-image"), r(.photo, "public.jpeg")], false, .byEditingInput([0, 1])),
            ([r(.photo), r(.photo)], false, .byEditingInput([0, 1])),
            // Nothing to name.
            ([], false, .unidentified),
            ([], true, .unidentified),
            ([r(.video), r(.video)], true, .unidentified),
            ([r(.photo)], true, .unidentified),
            ([r(.pairedVideo)], false, .unidentified),
            ([r(.adjustmentData)], false, .unidentified),
        ]
        for row in table {
            XCTAssertEqual(StagingRules.currentResource(row.resources, isVideo: row.isVideo), row.choice,
                           "\(row.resources.map(\.type.rawValue)) video: \(row.isVideo)")
        }
    }

    func testEditingInputPicksTheOneMatchingOriginal() {
        let raw = [r(.photo, "public.jpeg"), r(.alternatePhoto, "com.adobe.raw-image")]
        XCTAssertEqual(StagingRules.resolve([0, 1], in: raw, editingType: "com.adobe.raw-image"), 1)
        XCTAssertEqual(StagingRules.resolve([0, 1], in: raw, editingType: "public.jpeg"), 0)
        XCTAssertNil(StagingRules.resolve([0, 1], in: raw, editingType: "public.heic"), "No original of that type.")
        let twins = [r(.photo, "public.jpeg"), r(.photo, "public.jpeg")]
        XCTAssertNil(StagingRules.resolve([0, 1], in: twins, editingType: "public.jpeg"), "Two originals of that type name none.")
    }

    func testMotionPrefersTheEditedVideo() {
        XCTAssertEqual(StagingRules.motion([r(.photo), r(.pairedVideo)]), 1)
        XCTAssertEqual(StagingRules.motion([r(.photo), r(.pairedVideo), r(.fullSizePairedVideo)]), 2)
        XCTAssertEqual(StagingRules.motion([r(.photo), r(.fullSizePairedVideo), r(.pairedVideo)]), 1)
        XCTAssertNil(StagingRules.motion([r(.photo), r(.video)]))
    }

    func testOnlyXMPFilesAreSidecars() {
        XCTAssertEqual(StagingRules.sidecar([r(.photo, "com.adobe.raw-image", "DSC_0001.NEF"), r(.alternatePhoto, "public.xmp", "DSC_0001.XMP")]), 1)
        XCTAssertEqual(StagingRules.sidecar([r(.photo), r(.adjustmentData, "public.data", "edit.xmp")]), 1, "The name decides, in any case.")
        XCTAssertNil(StagingRules.sidecar([r(.photo), r(.adjustmentData, "com.apple.photos.adjustment", "Adjustments.plist")]),
                     "Apple's adjustment archive is not XMP.")
        XCTAssertNil(StagingRules.sidecar([r(.photo, "public.heic", "IMG_xmp.HEIC")]))
    }

    func testLivePhotoWithoutMotionIsAnItemFailure() {
        XCTAssertThrowsError(try StagingRules.requireMotion(isLive: true, motion: nil)) { error in
            guard case BackupError.item(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, StagingRules.livePhotoWithoutMotion)
            guard case .item = TransferFailureClassifier.classify(error) else { return XCTFail("Backup moves on to the next photo.") }
        }
        XCTAssertNoThrow(try StagingRules.requireMotion(isLive: true, motion: 1))
        XCTAssertNoThrow(try StagingRules.requireMotion(isLive: false, motion: nil))
    }

    func testMetadataOnlyForUnadjustedAssets() throws {
        XCTAssertTrue(StagingRules.isUnadjusted([.photo]))
        XCTAssertTrue(StagingRules.isUnadjusted([.photo, .pairedVideo]))
        XCTAssertTrue(StagingRules.isUnadjusted([.video]))
        for edit: PHAssetResourceType in [.adjustmentData, .adjustmentBasePhoto, .adjustmentBaseVideo, .fullSizePhoto, .fullSizeVideo, .alternatePhoto] {
            XCTAssertFalse(StagingRules.isUnadjusted([.photo, edit]), "\(edit.rawValue)")
        }

        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let text = try XCTUnwrap(StagingRules.mobileAppMetadata(cloudID: "ABC:001:XYZ", created: created,
                                                                location: CLLocationCoordinate2D(latitude: 52.5, longitude: 13.25)))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["key"] as? String, "mobile-app")
        XCTAssertEqual(decoded[0]["value"] as? [String: String],
                       ["iCloudId": "ABC:001:XYZ", "createdAt": "2023-11-14T22:13:20Z", "latitude": "52.5", "longitude": "13.25"])
        let placeless = try XCTUnwrap(StagingRules.mobileAppMetadata(cloudID: "ABC:001:XYZ", created: created, location: nil))
        XCTAssertFalse(placeless.contains("latitude"))
        XCTAssertNil(try StagingRules.mobileAppMetadata(cloudID: nil, created: created, location: nil))
        XCTAssertNil(try StagingRules.mobileAppMetadata(cloudID: "ABC:", created: created, location: nil), "An unresolved identifier is not sent.")
    }

    func testFields() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(StagingRules.fields(created: created, modified: created.addingTimeInterval(60), isFavorite: true, duration: 2.5),
                       ["fileCreatedAt": "2023-11-14T22:13:20Z", "fileModifiedAt": "2023-11-14T22:14:20Z", "isFavorite": "true", "duration": "2500"])
    }

    func testPendingSkipsOnlyPhotosConfirmedAtTheirRevision() {
        let day = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let found = [DeviceCandidate(id: "c", modified: day), DeviceCandidate(id: "a", modified: day),
                     DeviceCandidate(id: "b", modified: day.addingTimeInterval(1)), DeviceCandidate(id: "d", modified: nil)]
        XCTAssertEqual(StagingRules.pending(found, confirmed: ["a": day, "b": day, "d": day]), ["b", "c", "d"])
    }
}

/// The adapter's discovery and the resource export, with a fake Photos.
@MainActor final class PhotoStagingTests: XCTestCase {
    /// Discovery is asked from the main actor and reads Photos only on the adapter's queue, a batch
    /// at a time, in identifier order, leaving out excluded albums and what Photos no longer has.
    func testCandidatesStreamOffMain() async throws {
        let photos = FakePhotoKit()
        let ids = (0..<600).map { String(format: "%04d/L0/001", $0) }
        for (index, id) in ids.enumerated() { photos.add(id, revision: FakePhotoKit.revision + Double(index)) }
        photos.addAlbum("recents", title: "Recents", members: ids.reversed() + ["gone/L0/001"])
        photos.addAlbum("screenshots", title: "Screenshots", members: Array(ids[10..<20]))
        let adapter = PhotoKitAdapter(library: photos, assets: photos, journal: DeviceDatabase(url: deviceDatabaseURL()), staging: photos)

        var batches: [[DeviceCandidate]] = []
        for try await batch in adapter.candidates(included: ["recents"], excluded: ["screenshots"], batchSize: 250) {
            XCTAssertTrue(Thread.isMainThread)
            batches.append(batch)
        }

        XCTAssertEqual(batches.map(\.count), [250, 250, 90])
        let expected = ids.filter { !ids[10..<20].contains($0) }
        XCTAssertEqual(batches.flatMap { $0 }.map(\.id), expected)
        XCTAssertEqual(batches.flatMap { $0 }.first?.modified, AssetRevision(referenceSeconds: FakePhotoKit.revision).date)
        XCTAssertEqual(photos.readsOnMainThread, 0, "Photos is never read on the main thread.")
        let members = await adapter.albumMembers("screenshots", excluded: [])
        XCTAssertEqual(members, Array(ids[10..<20]))
    }

    /// A favorite doesn't wait behind a long read of albums or their members, as it would if the
    /// read held the adapter's queue.
    func testLongReadsDontHoldUpChanges() async throws {
        let photos = FakePhotoKit()
        photos.add("a")
        photos.addAlbum("all", title: "All", members: ["a"])
        let adapter = PhotoKitAdapter(library: photos, assets: photos, journal: DeviceDatabase(url: deviceDatabaseURL()), staging: photos)
        photos.holdReads()
        let albums = Task { await adapter.albums() }
        let members = Task { await adapter.albumMembers("all", excluded: []) }
        try await waitFor { photos.readsWaiting == 2 }

        let done = Locked(false)
        let favorite = Task {
            let result = await adapter.perform(.setFavorite([DeviceAssetID(rawValue: "a")], true, expected: [:]))
            done.mutate { $0 = true }
            return result
        }
        try await waitFor { done.value }
        photos.releaseReads()
        let result = await favorite.value
        XCTAssertEqual(result.outcome, .committed(affected: [DeviceAssetID(rawValue: "a")], created: []))
        let read = await albums.value
        XCTAssertEqual(read.map(\.title), ["All"])
        let found = await members.value
        XCTAssertEqual(found, ["a"])
    }

    /// Dropping the stream stops discovery between batches.
    func testDroppingTheStreamStopsDiscovery() async throws {
        let photos = FakePhotoKit()
        let ids = (0..<1_000).map { "\($0)" }
        for id in ids { photos.add(id) }
        photos.addAlbum("all", title: "All", members: ids)
        let adapter = PhotoKitAdapter(library: photos, assets: photos, journal: DeviceDatabase(url: deviceDatabaseURL()), staging: photos)
        let reader = Task {
            var count = 0
            for try await batch in adapter.candidates(included: ["all"], excluded: [], batchSize: 10) {
                count += batch.count
                if count >= 20 { break }
            }
            return count
        }
        let count = try await reader.value
        XCTAssertEqual(count, 20)
    }

    /// The album list is read once and kept until Photos reports a change that can alter it.
    func testAlbumListIsCachedUntilAlbumsChange() async throws {
        let photos = FakePhotoKit()
        photos.add("a"); photos.add("b")
        photos.addAlbum("2", title: "Zoo", members: ["a"])
        photos.addAlbum("1", title: "Album 10", members: ["a", "b"])
        photos.addAlbum("3", title: "Album 9", members: ["b"])
        let adapter = PhotoKitAdapter(library: photos, assets: photos, journal: DeviceDatabase(url: deviceDatabaseURL()),
                                      staging: photos, coalescing: .zero)
        await adapter.start()

        let first = await adapter.albums()
        XCTAssertEqual(first.map(\.title), ["Album 9", "Album 10", "Zoo"])
        _ = await adapter.albums()
        XCTAssertEqual(photos.albumReads, 1)

        // A favorite or an edit can change a smart album such as Favorites, which Photos needn't
        // report as a change to the album.
        photos.addAlbum("5", title: "Favorites", members: ["a"])
        photos.emit(PhotoLibraryChangeDetails(changed: [DeviceAssetID(rawValue: "a")]))
        let favorited = await adapter.albums()
        XCTAssertEqual(favorited.map(\.title), ["Album 9", "Album 10", "Favorites", "Zoo"])
        XCTAssertEqual(photos.albumReads, 2)
        _ = await adapter.albums()
        XCTAssertEqual(photos.albumReads, 2, "Kept until the next change.")
        photos.addAlbum("5", title: "Favorites", members: [])

        photos.addAlbum("4", title: "Trip", members: ["b"])
        photos.emit(PhotoLibraryChangeDetails(albumsChanged: true))
        let changed = await adapter.albums()
        XCTAssertEqual(changed.map(\.title), ["Album 9", "Album 10", "Favorites", "Trip", "Zoo"])
        XCTAssertEqual(photos.albumReads, 3)

        // A new photo changes counts.
        photos.emit(PhotoLibraryChangeDetails(inserted: [DeviceAssetID(rawValue: "c")]))
        _ = await adapter.albums()
        XCTAssertEqual(photos.albumReads, 4)

        photos.setStatus(.denied)
        await adapter.refreshAccess()
        let hidden = await adapter.albums()
        XCTAssertEqual(hidden, [], "Without access there are no albums.")
        XCTAssertEqual(photos.readsOnMainThread, 0)
    }

    /// The task is cancelled while PhotoKit is still starting the request, before it has returned
    /// the identifier: the partial file is deleted at once, and the request is cancelled as soon
    /// as it can be named.
    func testCancellationBeforeRequestIDDeletesPartialFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IlyichStaging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("original")
        struct Seen: Sendable { var fileExistedAtStart = false; var cancelled: [PHAssetResourceDataRequestID] = []; var startedOnMain = false }
        let seen = Locked(Seen())
        let request = ResourceDataRequest(start: { received, _ in
            seen.mutate {
                $0.fileExistedAtStart = FileManager.default.fileExists(atPath: destination.path)
                $0.startedOnMain = Thread.isMainThread
            }
            received(Data("partial".utf8))
            // Cancelled from inside PhotoKit's call, before it returns.
            withUnsafeCurrentTask { $0?.cancel() }
            return 42
        }, cancel: { id in seen.mutate { $0.cancelled.append(id) } })

        let export = Task.detached {
            try await PhotoResourceExport(destination: destination).write(request, networkAccess: false)
        }
        do {
            try await export.value
            XCTFail("The export finished.")
        } catch is CancellationError {}

        let result = seen.value
        XCTAssertTrue(result.fileExistedAtStart, "The file was created before the request started.")
        XCTAssertFalse(result.startedOnMain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "The partial file is deleted.")
        XCTAssertEqual(result.cancelled, [42], "The request is cancelled once PhotoKit names it, and only once.")
    }

    /// A completed export keeps its file; a failed one deletes it.
    func testExportWritesOrDeletesItsFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IlyichStaging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        func request(failing: Bool) -> ResourceDataRequest {
            ResourceDataRequest(start: { received, completed in
                DispatchQueue.global().async {
                    received(Data("hello ".utf8)); received(Data("world".utf8))
                    completed(failing ? CocoaError(.fileReadUnknown) : nil)
                }
                return 7
            }, cancel: { _ in XCTFail("Nothing to cancel.") })
        }
        let good = folder.appendingPathComponent("good")
        try await PhotoResourceExport(destination: good).write(request(failing: false), networkAccess: false)
        XCTAssertEqual(try String(contentsOf: good, encoding: .utf8), "hello world")

        let bad = folder.appendingPathComponent("bad")
        do {
            try await PhotoResourceExport(destination: bad).write(request(failing: true), networkAccess: false)
            XCTFail("The export finished.")
        } catch let error as CocoaError { XCTAssertEqual(error.code, .fileReadUnknown) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
    }
}

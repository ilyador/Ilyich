import Foundation
import IlyichPlatform
import Synchronization
import XCTest
@testable import Ilyich

/// Sharing, downloading and saving server photos to Photos.
final class MediaExportServiceTests: XCTestCase {
    // MARK: - Sharing

    /// Each photo lands in a temporary folder of its own, in the order chosen, with the server's
    /// bytes and file name, and the files go when the share sheet lets them go.
    func testSharedFilesHoldTheServersBytesAndGoWhenReleased() async throws {
        let server = makeStubServer()
        let first = Data("first original".utf8), second = Data("second original".utf8)
        let names = ["first-\(UUID().uuidString).JPG", "second-\(UUID().uuidString).JPG"]
        server.route("GET", "assets/first/original", file(first, named: names[0]))
        server.route("GET", "assets/second/original", file(second, named: names[1]))
        let notifications = RecordingNotifications()
        let service = MediaExportService(api: try client(server), photos: FakePhotoLibrary(), notifications: notifications)
        let steps = Mutex<[ExportProgress]>([])

        let job = service.start(.share([Asset(id: "first"), Asset(id: "second")], original: true)) { step in steps.withLock { $0.append(step) } }
        guard case .files(let files) = await job.outcome else { return XCTFail("Both photos are shared.") }

        XCTAssertEqual(files.urls.map(\.lastPathComponent), names)
        XCTAssertEqual(try files.urls.map { try Data(contentsOf: $0) }, [first, second])
        XCTAssertNotEqual(files.urls[0].deletingLastPathComponent(), files.urls[1].deletingLastPathComponent(), "Each file has its own folder.")
        let fractions = steps.withLock { $0 }.compactMap(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted(), "Progress only grows.")
        XCTAssertEqual(steps.withLock { $0.last }, ExportProgress(completed: 2, total: 2, fraction: 1, committing: false))
        XCTAssertEqual(notifications.events, [.started("Download", 2), .finished("Download", 2, completed: 2, failed: 0)])

        files.remove()
        XCTAssertFalse(files.urls.contains { FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) },
                       "The share sheet letting go removes the files and their folders.")
    }

    /// Files nobody shares, such as those of an export the screen has left, go with the last
    /// reference to them.
    func testReleasedFilesAreRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("IMG_0007.JPG")
        try Data("photo".utf8).write(to: url)
        var files: ExportedFiles? = ExportedFiles([url])
        XCTAssertNotNil(files)
        files = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// The displayed version is the server's full-size rendition with the edits; the original is
    /// the unedited file; a video is always its original.
    func testTheDisplayedVersionKeepsEditsAndTheOriginalIsUnedited() async throws {
        let server = makeStubServer()
        server.route("GET", "assets/edited/thumbnail", file(Data("rendered".utf8), named: "rendered.jpg"))
        server.route("GET", "assets/edited/original", file(Data("original".utf8), named: "IMG_0003.HEIC"))
        server.route("GET", "assets/clip/original", file(Data("clip".utf8), named: "clip.mov", type: "video/quicktime"))
        let service = MediaExportService(api: try client(server), photos: FakePhotoLibrary(), notifications: RecordingNotifications())
        var edited = Asset(id: "edited", originalFileName: "IMG_0003.HEIC", mediaRevision: "rev-2")
        edited.isEdited = true

        guard case .files(let displayed) = await service.start(.share([edited], original: false)).outcome else { return XCTFail("Displayed is shared.") }
        XCTAssertEqual(try Data(contentsOf: displayed.urls[0]), Data("rendered".utf8))
        let rendition = try XCTUnwrap(server.requests("GET", "assets/edited/thumbnail").first)
        XCTAssertEqual(query(rendition), ["edited": "true", "size": "fullsize", "c": "rev-2"])

        guard case .files(let original) = await service.start(.share([edited], original: true)).outcome else { return XCTFail("The original is shared.") }
        XCTAssertEqual(try Data(contentsOf: original.urls[0]), Data("original".utf8))
        XCTAssertEqual(query(try XCTUnwrap(server.requests("GET", "assets/edited/original").first)), ["edited": "false", "c": "rev-2"])

        guard case .files(let video) = await service.start(.share([Asset(id: "clip", type: .video)], original: false)).outcome else {
            return XCTFail("A video is shared.")
        }
        XCTAssertEqual(video.urls.map(\.lastPathComponent), ["clip.mov"])
        XCTAssertTrue(server.requests("GET", "assets/clip/thumbnail").isEmpty, "A video's displayed version is its original.")
    }

    /// Cancelling stops the download, removes what was already downloaded and takes back the
    /// notification.
    func testCancellingASharedDownloadLeavesNoFiles() async throws {
        let server = makeStubServer()
        let gate = StubServer.Gate()
        addTeardownBlock { gate.open() }
        let name = "kept-\(UUID().uuidString).JPG"
        server.route("GET", "assets/first/original", file(Data("first".utf8), named: name))
        server.route("GET", "assets/second/original", file(Data("second".utf8), named: "second.JPG").waiting(for: gate))
        let notifications = RecordingNotifications()
        let service = MediaExportService(api: try client(server), photos: FakePhotoLibrary(), notifications: notifications)

        let job = service.start(.share([Asset(id: "first"), Asset(id: "second")], original: true))
        try await until { !server.requests("GET", "assets/second/original").isEmpty }
        XCTAssertEqual(exportedCopies(named: name).count, 1, "The first photo is downloaded.")
        job.cancel()
        guard case .cancelled(saved: 0) = await job.outcome else { return XCTFail("The export ends cancelled.") }

        XCTAssertEqual(exportedCopies(named: name), [], "The first photo's file is removed.")
        XCTAssertEqual(notifications.events, [.started("Download", 2), .cancelled])
    }

    func testAFailedDownloadSaysSoAndLeavesNoFiles() async throws {
        let server = makeStubServer()
        let name = "partial-\(UUID().uuidString).JPG"
        server.route("GET", "assets/first/original", file(Data("first".utf8), named: name))
        server.route("GET", "assets/gone/original", .immichError(404, message: "Not found"))
        let notifications = RecordingNotifications()
        let service = MediaExportService(api: try client(server), photos: FakePhotoLibrary(), notifications: notifications)

        guard case .failed(let error, saved: 0) = await service.start(.share([Asset(id: "first"), Asset(id: "gone")], original: true)).outcome else {
            return XCTFail("A missing original fails the export.")
        }
        XCTAssertEqual(error as? ServerFailure, .notFound)
        XCTAssertEqual(exportedCopies(named: name), [], "What was downloaded is removed.")
        XCTAssertEqual(notifications.events, [.started("Download", 2), .finished("Download", 2, completed: 1, failed: 1)])
    }

    // MARK: - Saving to Photos

    /// A Live Photo is saved from its original still and its original motion together, so Photos
    /// pairs them; the temporary files go afterwards.
    func testSavingALivePhotoAddsItsStillAndMotionTogether() async throws {
        let server = makeStubServer()
        let still = Data("live still".utf8), motion = Data("live motion".utf8)
        server.route("GET", "assets/live/original", file(still, named: "IMG_0004.HEIC"))
        server.route("GET", "assets/motion", .json(#"{"id":"motion","type":"VIDEO","originalFileName":"IMG_0004.MOV","visibility":"hidden"}"#))
        server.route("GET", "assets/motion/original", file(motion, named: "IMG_0004.MOV", type: "video/quicktime"))
        let steps = Mutex<[ExportProgress]>([])
        let photos = FakePhotoLibrary(committing: { steps.withLock { $0.last?.committing == true } })
        let notifications = RecordingNotifications()
        let service = MediaExportService(api: try client(server), photos: photos, notifications: notifications)
        var live = Asset(id: "live", originalFileName: "IMG_0004.HEIC")
        live.livePhotoVideoId = "motion"

        let job = service.start(.saveToPhotos([live], original: false)) { step in steps.withLock { $0.append(step) } }
        guard case .saved(1) = await job.outcome else { return XCTFail("The Live Photo is saved.") }

        XCTAssertEqual(photos.added, [.init(still: still, isVideo: false, pairedVideo: motion)])
        XCTAssertEqual(query(try XCTUnwrap(server.requests("GET", "assets/live/original").first))["edited"], "false",
                       "Even the displayed choice saves a Live Photo's original still.")
        XCTAssertTrue(server.requests("GET", "assets/live/thumbnail").isEmpty)
        XCTAssertTrue(photos.addedWhileCommitting, "Photos is written only once the export says it can no longer be cancelled.")
        XCTAssertFalse(try XCTUnwrap(steps.withLock { $0.last }).committing)
        let fractions = steps.withLock { $0 }.compactMap(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted(), "Still and motion share one progress.")
        XCTAssertEqual(fractions.last, 1)
        XCTAssertFalse(photos.files.contains { FileManager.default.fileExists(atPath: $0.path) }, "The downloads are removed after saving.")
        XCTAssertEqual(notifications.events, [.started("Save to Photos", 1), .finished("Save to Photos", 1, completed: 1, failed: 0)])
    }

    /// Other photos are saved in the chosen version.
    func testSavingAPhotoUsesTheChosenVersion() async throws {
        let server = makeStubServer()
        server.route("GET", "assets/photo/thumbnail", file(Data("rendered".utf8), named: "rendered.jpg"))
        server.route("GET", "assets/photo/original", file(Data("original".utf8), named: "IMG_0005.HEIC"))
        let photos = FakePhotoLibrary()
        let service = MediaExportService(api: try client(server), photos: photos, notifications: RecordingNotifications())

        guard case .saved(1) = await service.start(.saveToPhotos([Asset(id: "photo")], original: false)).outcome,
              case .saved(1) = await service.start(.saveToPhotos([Asset(id: "photo")], original: true)).outcome else {
            return XCTFail("The photo is saved twice.")
        }
        XCTAssertEqual(photos.added, [.init(still: Data("rendered".utf8), isVideo: false, pairedVideo: nil),
                                      .init(still: Data("original".utf8), isVideo: false, pairedVideo: nil)])
    }

    /// Read-only mode refuses to write to Photos before anything is downloaded, and sharing still
    /// works.
    func testReadOnlyModeRefusesSavingButNotSharing() async throws {
        let server = makeStubServer()
        server.route("GET", "assets/photo/original", file(Data("original".utf8), named: "IMG_0006.HEIC"))
        let api = try client(server)
        let key = AccountStoragePaths(AccountID(server: api.baseURL, userID: "alice")).readOnlyKey
        addTeardownBlock { (AppGroup.defaults ?? .standard).removeObject(forKey: key) }
        (AppGroup.defaults ?? .standard).set(true, forKey: key)
        let photos = FakePhotoLibrary()
        let notifications = RecordingNotifications()
        let service = MediaExportService(api: api, photos: photos, notifications: notifications)

        guard case .failed(let error, saved: 0) = await service.start(.saveToPhotos([Asset(id: "photo")], original: true)).outcome else {
            return XCTFail("Saving is refused.")
        }
        XCTAssertTrue(error is ReadOnlyPolicy.ReadOnlyError)
        XCTAssertTrue(server.requests.isEmpty, "Nothing is downloaded.")
        XCTAssertEqual(photos.accessRequests, 0, "Photos isn't asked.")
        XCTAssertEqual(notifications.events, [])

        guard case .files = await service.start(.share([Asset(id: "photo")], original: true)).outcome else { return XCTFail("Sharing still works.") }
    }

    func testRefusedPhotosAccessDownloadsNothing() async throws {
        let server = makeStubServer()
        let photos = FakePhotoLibrary(allowed: false)
        let notifications = RecordingNotifications()
        let service = MediaExportService(api: try client(server), photos: photos, notifications: notifications)

        guard case .failed(let error, saved: 0) = await service.start(.saveToPhotos([Asset(id: "photo")], original: true)).outcome else {
            return XCTFail("Saving needs Photos access.")
        }
        XCTAssertEqual(error.localizedDescription, "Allow Ilyich to add photos in iPhone Settings, then try again.")
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(notifications.events, [])
    }

    /// A photo the server can't give stops the save; the ones already saved are counted.
    func testAFailedPhotoStopsTheSaveAndCountsWhatWasSaved() async throws {
        let server = makeStubServer()
        server.route("GET", "assets/first/original", file(Data("first".utf8), named: "first.HEIC"))
        server.route("GET", "assets/gone/original", .immichError(404, message: "Not found"))
        server.route("GET", "assets/third/original", file(Data("third".utf8), named: "third.HEIC"))
        let photos = FakePhotoLibrary()
        let notifications = RecordingNotifications()
        let service = MediaExportService(api: try client(server), photos: photos, notifications: notifications)

        let request = ExportRequest.saveToPhotos([Asset(id: "first"), Asset(id: "gone"), Asset(id: "third")], original: true)
        guard case .failed(let error, saved: 1) = await service.start(request).outcome else { return XCTFail("The save stops at the missing photo.") }
        XCTAssertEqual(error as? ServerFailure, .notFound)
        XCTAssertEqual(photos.added.count, 1)
        XCTAssertTrue(server.requests("GET", "assets/third/original").isEmpty, "Nothing after it is downloaded.")
        XCTAssertEqual(notifications.events, [.started("Save to Photos", 3), .finished("Save to Photos", 3, completed: 1, failed: 2)])
    }

    /// Writing to Photos can't be undone: a cancel that arrives during it still saves that photo,
    /// then stops before the next.
    func testCancellingWhileWritingToPhotosSavesThatPhotoAndStops() async throws {
        let server = makeStubServer()
        server.route("GET", "assets/first/original", file(Data("first".utf8), named: "first.HEIC"))
        server.route("GET", "assets/second/original", file(Data("second".utf8), named: "second.HEIC"))
        let writing = StubServer.Gate()
        addTeardownBlock { writing.open() }
        let photos = FakePhotoLibrary(gate: writing)
        let notifications = RecordingNotifications()
        let service = MediaExportService(api: try client(server), photos: photos, notifications: notifications)

        let job = service.start(.saveToPhotos([Asset(id: "first"), Asset(id: "second")], original: true))
        try await until { writing.waiting == 1 }
        job.cancel()
        writing.open()
        guard case .cancelled(saved: 1) = await job.outcome else { return XCTFail("The photo being written is saved, then the save stops.") }
        XCTAssertEqual(photos.added.count, 1)
        XCTAssertTrue(server.requests("GET", "assets/second/original").isEmpty)
        XCTAssertEqual(notifications.events, [.started("Save to Photos", 2), .cancelled])
    }

    // MARK: - Support

    private func client(_ server: StubServer) throws -> APIClient {
        let api = try APIClient(baseURL: server.baseURL, accessToken: "session-token", userID: "alice",
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        return api
    }

    private func file(_ body: Data, named name: String, type: String = "image/jpeg") -> StubServer.Response {
        StubServer.Response(status: 200, headers: ["Content-Type": type, "Content-Length": String(body.count),
                                                   "Content-Disposition": "attachment; filename=\"\(name)\""], body: body)
            .inPieces(of: max(1, body.count / 4))
    }

    private func query(_ request: StubServer.Request) -> [String: String] {
        Dictionary(request.query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// The exported copies of a file still in the temporary folder.
    private func exportedCopies(named name: String) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders.map { $0.appendingPathComponent(name) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// What a screen shows of its export.
@MainActor final class ExportTrackerTests: XCTestCase {
    func testAFinishedExportHandsOverItsFilesAndStopsShowing() async throws {
        let server = makeStubServer()
        server.route("GET", "assets/photo/original", StubServer.Response(status: 200, headers: ["Content-Disposition": #"attachment; filename="IMG_0008.JPG""#],
                                                                         body: Data("photo".utf8)))
        let tracker = ExportTracker(service: MediaExportService(api: try client(server), photos: FakePhotoLibrary(), notifications: RecordingNotifications()))
        let ended = expectation(description: "The export ends.")
        var outcomes: [ExportOutcome] = []

        tracker.start(.share([Asset(id: "photo")], original: true)) { outcomes.append($0); ended.fulfill() }
        XCTAssertTrue(tracker.isRunning)
        XCTAssertEqual(tracker.request?.destination, .files)
        tracker.start(.saveToPhotos([Asset(id: "photo")], original: true)) { _ in XCTFail("A second export waits for the first.") }
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertFalse(tracker.isRunning)
        XCTAssertNil(tracker.request)
        guard outcomes.count == 1, case .files(let files) = outcomes[0] else { return XCTFail("The files are handed over once.") }
        XCTAssertEqual(try Data(contentsOf: files.urls[0]), Data("photo".utf8))
        files.remove()
    }

    /// Cancelling takes the export off the screen at once; it then ends as cancelled, with nothing
    /// left on disk.
    func testCancellingStopsShowingAtOnceAndEndsCancelled() async throws {
        let server = makeStubServer()
        let gate = StubServer.Gate()
        addTeardownBlock { gate.open() }
        let name = "cancelled-\(UUID().uuidString).JPG"
        server.route("GET", "assets/photo/original", StubServer.Response(status: 200, headers: ["Content-Disposition": "attachment; filename=\"\(name)\""],
                                                                         body: Data("photo".utf8)).waiting(for: gate))
        let notifications = RecordingNotifications()
        let tracker = ExportTracker(service: MediaExportService(api: try client(server), photos: FakePhotoLibrary(), notifications: notifications))
        let ended = expectation(description: "The export ends.")
        var outcome: ExportOutcome?

        tracker.start(.share([Asset(id: "photo")], original: true)) { outcome = $0; ended.fulfill() }
        try await waitUntil { !server.requests("GET", "assets/photo/original").isEmpty }
        tracker.cancel()
        XCTAssertFalse(tracker.isRunning, "The screen stops showing the export at once.")
        await fulfillment(of: [ended], timeout: 5)

        guard case .cancelled(saved: 0) = outcome else { return XCTFail("The export ends cancelled.") }
        try await waitUntil { notifications.events.last == .cancelled }
        let folders = try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
        XCTAssertFalse(folders.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) })
    }

    private func client(_ server: StubServer) throws -> APIClient {
        let api = try APIClient(baseURL: server.baseURL, accessToken: "session-token", userID: "alice",
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        return api
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Photos, as far as an export sees it: whether adding is allowed, and what was added. Adding can
/// wait for a gate the test opens.
private final class FakePhotoLibrary: PhotoLibraryWriting {
    struct Added: Equatable, Sendable {
        let still: Data
        let isVideo: Bool
        let pairedVideo: Data?
    }

    private struct State {
        var accessRequests = 0
        var added: [Added] = []
        var files: [URL] = []
        var committingFlags: [Bool] = []
    }

    private let allowed: Bool
    private let gate: StubServer.Gate?
    /// Whether the export says it is writing to Photos, asked as each photo is added.
    private let committing: (@Sendable () -> Bool)?
    private let state = Mutex(State())

    init(allowed: Bool = true, gate: StubServer.Gate? = nil, committing: (@Sendable () -> Bool)? = nil) {
        self.allowed = allowed; self.gate = gate; self.committing = committing
    }

    var accessRequests: Int { state.withLock { $0.accessRequests } }
    var added: [Added] { state.withLock { $0.added } }
    /// The files Photos was given.
    var files: [URL] { state.withLock { $0.files } }
    var addedWhileCommitting: Bool { state.withLock { !$0.committingFlags.isEmpty && $0.committingFlags.allSatisfy { $0 } } }

    func requestAddAccess() async -> Bool {
        state.withLock { $0.accessRequests += 1 }
        return allowed
    }

    func add(_ file: URL, isVideo: Bool, pairedVideo: URL?) async throws {
        let flag = committing?() ?? false
        state.withLock { $0.committingFlags.append(flag) }
        let still = try Data(contentsOf: file)
        let paired = try pairedVideo.map { try Data(contentsOf: $0) }
        if let gate { await gate.wait() }
        state.withLock {
            $0.added.append(Added(still: still, isVideo: isVideo, pairedVideo: paired))
            $0.files += [file] + (pairedVideo.map { [$0] } ?? [])
        }
    }

}

/// The notifications an export posted, in order.
private final class RecordingNotifications: ExportNotifying {
    enum Event: Equatable, Sendable {
        case started(String, Int)
        case finished(String, Int, completed: Int, failed: Int)
        case cancelled
    }

    private let state = Mutex<[Event]>([])
    var events: [Event] { state.withLock { $0 } }

    func started(id: UUID, kind: String, total: Int) async { state.withLock { $0.append(.started(kind, total)) } }
    func finished(id: UUID, kind: String, total: Int, completed: Int, failed: Int) async {
        state.withLock { $0.append(.finished(kind, total, completed: completed, failed: failed)) }
    }
    func cancel(id: UUID) async { state.withLock { $0.append(.cancelled) } }
}

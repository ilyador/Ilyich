import AVFoundation
import IlyichPlatform
import Photos
import Synchronization
import XCTest
@testable import Ilyich

/// The viewer's video transport, which hands AVFoundation the server's bytes through URLSession.
@MainActor final class AuthenticatedVideoTransportTests: XCTestCase {
    func testPlaybackIdentityIgnoresFavoriteAndDescriptiveMetadataButTracksMediaAndAccess() {
        var asset = Asset(id: "video", type: .video, mediaRevision: "one")
        let identity = VideoMediaIdentity(asset)
        asset.isFavorite = true; asset.originalFileName = "renamed.mov"; asset.width = 900
        XCTAssertEqual(VideoMediaIdentity(asset), identity)
        asset.mediaRevision = "two"
        XCTAssertNotEqual(VideoMediaIdentity(asset), identity)
        asset.mediaRevision = "one"; asset.hasKnownEditState = true
        XCTAssertNotEqual(VideoMediaIdentity(asset), identity)
        asset.hasKnownEditState = false; asset.visibility = .locked
        XCTAssertNotEqual(VideoMediaIdentity(asset), identity)
    }

    func testFirstFrameDeadlineCanExpireAndCancellationDoesNotReportFailure() async {
        let expired = await VideoFirstFrameDeadline.elapsed(after: .zero, sleep: { _ in })
        XCTAssertTrue(expired)
        let cancelled = Task { await VideoFirstFrameDeadline.elapsed(after: .seconds(30)) }
        cancelled.cancel()
        let elapsed = await cancelled.value
        XCTAssertFalse(elapsed, "Ready, paged-away and background transitions cancel this task.")
        let interrupted = await VideoFirstFrameDeadline.elapsed(after: .zero, sleep: { _ in throw CancellationError() })
        XCTAssertFalse(interrupted)
    }

    func testOnlyTheCurrentLayersFirstFrameCanReplaceThePoster() {
        var readiness = VideoPresentationReadiness()
        let first = readiness.begin()
        XCTAssertEqual(readiness.state, .loading, "Creating a player or a ready item is not a displayed frame.")
        readiness.frameReady(true, request: first)
        XCTAssertEqual(readiness.state, .ready)
        readiness.frameReady(false, request: first)
        XCTAssertEqual(readiness.state, .loading, "A layer without an image keeps the poster visible.")
        readiness.fail("Retry", request: first)
        XCTAssertNotEqual(readiness.requestID, first, "Timeout/failure invalidates delayed preparation and layer callbacks.")
        readiness.frameReady(true, request: first)
        XCTAssertEqual(readiness.state, .failed("Retry"), "A late frame cannot dismiss a failure.")
        let retry = readiness.begin()
        readiness.frameReady(true, request: first)
        readiness.fail("Old error", request: first)
        XCTAssertEqual(readiness.state, .loading)
        readiness.frameReady(true, request: retry)
        XCTAssertEqual(readiness.state, .ready)
    }

    func testLayerObservationsCannotPublishAfterReplacementOrDismantling() async {
        let coordinator = PlayerSurface.Coordinator()
        let layer = AVPlayerLayer()
        var oldCallbacks = 0
        var currentCallbacks = 0
        coordinator.bind(layer, player: AVPlayer(), ready: { _ in oldCallbacks += 1 }, failure: nil)
        let current = AVPlayer()
        coordinator.bind(layer, player: current, ready: { _ in currentCallbacks += 1 }, failure: nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(oldCallbacks, 0)
        XCTAssertEqual(currentCallbacks, 1)
        coordinator.bind(layer, player: AVPlayer(), ready: { _ in oldCallbacks += 1 }, failure: nil)
        coordinator.close()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(oldCallbacks, 0)
    }

    func testPlaybackAccessSurvivesReadOnlyButCannotSurviveRevocationOrRelock() {
        let account = AccountID(server: URL(string: "https://photos.invalid")!, userID: "owner")
        let authorization = AuthorizationState(account: account, token: "token", readOnly: false,
                                               requiresPasswordChange: false, mirror: nil)
        let read = VideoPlaybackAccess(authorization: authorization, locked: false)
        XCTAssertTrue(read.permits)
        authorization.setReadOnly(true)
        XCTAssertTrue(read.permits)
        authorization.setLockedFolderUnlocked(true)
        let locked = VideoPlaybackAccess(authorization: authorization, locked: true)
        XCTAssertTrue(locked.permits)
        authorization.setLockedFolderUnlocked(false)
        authorization.setLockedFolderUnlocked(true)
        XCTAssertFalse(locked.permits)
        authorization.accessChanged()
        XCTAssertFalse(read.permits)
        let fresh = VideoPlaybackAccess(authorization: authorization, locked: false)
        authorization.end()
        XCTAssertFalse(fresh.permits)
    }

    func testLocalPlaybackNeverDownloadsAndRejectsChangedOrRevokedDelivery() async {
        let photo = LocalPhoto(id: "local", date: nil, video: true)
        for changed in [false, true] {
            let device = LocalPlaybackDevice()
            var checks = 0
            let result = await MatchedVideoPlayback.load(photo: photo, motion: false, device: device,
                unchanged: { checks += 1; return !changed || checks == 1 }, permits: { true })
            XCTAssertEqual(device.requests, [.video(network: false)])
            if changed { XCTAssertNil(result) }
            else { if case .player? = result {} else { XCTFail("An unchanged local player should be used.") } }
            XCTAssertEqual(checks, 2)
        }
        let device = LocalPlaybackDevice()
        var allowed = true
        device.onDelivery = { allowed = false }
        let revoked = await MatchedVideoPlayback.load(photo: photo, motion: false, device: device,
                                                     unchanged: { true }, permits: { allowed })
        XCTAssertNil(revoked)
        let untouched = LocalPlaybackDevice()
        let denied = await MatchedVideoPlayback.load(photo: photo, motion: false, device: untouched,
                                                    unchanged: { true }, permits: { false })
        XCTAssertNil(denied)
        XCTAssertTrue(untouched.requests.isEmpty)
    }

    func testHTTPRefusalCannotAuthorizeLocalFallbackAndEditedOrUnknownMediaCannotSubstitute() async throws {
        let photos = FakePhotoKit()
        let photo = LocalPhoto(id: "local", date: nil, modified: Date(timeIntervalSinceReferenceDate: FakePhotoKit.revision), video: true)
        photos.add(photo.id)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let adapter = PhotoKitAdapter(library: photos, assets: photos, journal: DeviceDatabase(url: folder.appendingPathComponent("device.sqlite")), staging: photos)
        await adapter.start()
        var asset = Asset(id: "video", type: .video)
        asset.hasKnownEditState = true
        let valid = await LocalMediaFallback.matchedPhoto(asset: asset, matched: photo, active: true, kind: .video, device: adapter)
        XCTAssertEqual(valid, photo)
        for failure in [ServerFailure.forbidden(nil), .sessionExpired(nil), .notFound] {
            let fallback = await LocalMediaFallback.photo(after: failure, asset: asset, matched: photo, active: true, kind: .video, device: adapter)
            XCTAssertNil(fallback)
        }
        asset.isEdited = true
        let edited = await LocalMediaFallback.matchedPhoto(asset: asset, matched: photo, active: true, kind: .video, device: adapter)
        XCTAssertNil(edited)
        asset.isEdited = false; asset.hasKnownEditState = false
        let unknown = await LocalMediaFallback.matchedPhoto(asset: asset, matched: photo, active: true, kind: .video, device: adapter)
        XCTAssertNil(unknown)
    }
    /// AVFoundation can still ask a closed transport for bytes: a request it queued before the
    /// close arrives after it. Starting a task on the closed transport's invalidated session
    /// raised, which crashed build 3040096 after videos loaded slowly; it turns the request down.
    func testAClosedTransportTurnsDownRequestsInsteadOfStartingATask() async throws {
        let request = URLRequest(url: URL(string: "https://photos.invalid/api/assets/a/video/playback")!)
        let transport = try AuthenticatedVideoTransport(request: request, server: URL(string: "https://photos.invalid")!)
        let asset = try XCTUnwrap(transport.player.currentItem?.asset)
        transport.close()
        do {
            _ = try await asset.load(.duration)
            XCTFail("A closed transport's video loaded")
        } catch {}
    }
}

private final class LocalPlaybackDevice: DeviceMediaProviding, @unchecked Sendable {
    private let recorded = Mutex<[DeviceMediaRequest]>([])
    @MainActor var onDelivery: (() -> Void)?
    @MainActor init() {}
    var requests: [DeviceMediaRequest] { recorded.withLock { $0 } }

    func media(_ localID: String, _ request: DeviceMediaRequest) -> AsyncStream<DeviceMediaEvent> {
        recorded.withLock { $0.append(request) }
        return AsyncStream { continuation in
            Task { @MainActor in
                self.onDelivery?()
                continuation.yield(.player(AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-test-video.mov"))))
                continuation.finish()
            }
        }
    }
}

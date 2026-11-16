import AVFoundation
import IlyichPlatform
import SwiftUI
import UniformTypeIdentifiers

/// A transport or player item is not a displayed video frame.
enum VideoPresentationState: Equatable, Sendable {
    case loading, ready, failed(String)
}

/// Request identity also fences late layer observations and failures from a replaced player.
struct VideoPresentationReadiness {
    private(set) var requestID = UUID()
    private(set) var state: VideoPresentationState = .loading

    mutating func begin() -> UUID {
        requestID = UUID(); state = .loading
        return requestID
    }

    mutating func frameReady(_ ready: Bool, request: UUID) {
        guard request == requestID else { return }
        if case .failed = state { return }
        state = ready ? .ready : .loading
    }

    mutating func fail(_ message: String, request: UUID) {
        guard request == requestID else { return }
        requestID = UUID()
        state = .failed(message)
    }
}

/// The exact account access under which playback began. Read-only changes leave reads alone;
/// sign-out, lost asset access and Locked Folder relocking cannot revive a retained player.
struct VideoPlaybackAccess {
    private let authorization: AuthorizationState?
    private let epoch: AuthorizationEpoch?
    private let privateEpoch: UInt64?
    private let locked: Bool

    init(authorization: AuthorizationState?, locked: Bool) {
        self.authorization = authorization
        epoch = authorization?.snapshot.epoch
        privateEpoch = authorization?.snapshot.privateEpoch
        self.locked = locked
    }

    var permits: Bool {
        guard let authorization else { return true }
        let snapshot = authorization.snapshot
        return authorization.permitsServiceUse && snapshot.allows(.read)
            && epoch.map(authorization.isCurrent) == true
            && (!locked || (snapshot.allows(.lockedMedia) && snapshot.privateEpoch == privateEpoch))
    }
}

struct VideoMediaIdentity: Equatable {
    let sourceID: String
    let revision: String
    let knownEditState: Bool
    let edited: Bool
    let developed: Bool
    let visibility: AssetVisibility
    let trashed: Bool
    let animated: Bool

    init(_ asset: Asset) {
        sourceID = asset.id; revision = asset.cacheRevision
        knownEditState = asset.hasKnownEditState; edited = asset.isEdited; developed = asset.isDeveloped
        visibility = asset.visibility; trashed = asset.isTrashed; animated = asset.isAnimatedImage
    }
}

@MainActor
struct AuthenticatedVideo: View {
    let api: APIClient
    let assetID: String
    let active: Bool
    var onEnded: (() -> Void)? = nil
    /// The still that owns Live Photo motion, or the regular video itself.
    var sourceAsset: Asset? = nil
    var matchedLocalPhoto: LocalPhoto? = nil
    var isLivePhotoMotion = false
    var playback: VideoPlaybackState? = nil
    var pipeline: MediaPipeline? = nil
    var retryToken = 0
    var onPresentationChanged: ((VideoPresentationState) -> Void)? = nil
    @State private var transport: AuthenticatedVideoTransport?
    @State private var attempt = 0
    @State private var loadedKey: PlaybackRequest?
    @State private var localMedia = LocalPhotoMedia()
    @State private var localPhoto: LocalPhoto?
    @State private var usingLocal = false
    @State private var activeNow = false
    @State private var readiness = VideoPresentationReadiness()
    @State private var poster: UIImage?
    @State private var posterKey: String?
    @State private var localPlaybackFailed = false
    @State private var loadWork: (id: UUID, task: Task<Void, Never>)?
    @AppStorage("viewerAutoPlayVideo") private var autoPlay = true
    @AppStorage("viewerLoopVideo") private var loop = true
    @AppStorage("viewerLoadOriginalVideo") private var original = false
    @AppStorage("viewerMuteVideo") private var muted = false
    @Environment(\.scenePhase) private var scenePhase

    private struct PlaybackRequest: Equatable {
        let scope: String
        let assetID: String
        let source: VideoMediaIdentity?
        let attempt: Int
        let retryToken: Int
        let original: Bool
        let localPhoto: LocalPhoto?
        let liveMotion: Bool
        let active: Bool
    }
    private var requestKey: PlaybackRequest {
        PlaybackRequest(scope: api.cacheScope, assetID: assetID, source: sourceAsset.map(VideoMediaIdentity.init),
                        attempt: attempt, retryToken: retryToken,
                        original: original, localPhoto: matchedLocalPhoto, liveMotion: isLivePhotoMotion, active: active)
    }
    private var imageKey: String { api.cacheScope + "|" + (sourceAsset?.id ?? assetID) + "|" + (sourceAsset?.cacheRevision ?? "") }
    private var cachedPoster: UIImage? {
        guard let sourceAsset, sourceAsset.visibility != .locked, permitsMedia else { return nil }
        return (pipeline?.latestImage(assetID: sourceAsset.id, size: .preview, revision: sourceAsset.cacheRevision)
                ?? pipeline?.latestImage(assetID: sourceAsset.id, size: .thumbnail, revision: sourceAsset.cacheRevision))?.uiImage
    }
    private var shownPoster: UIImage? { posterKey == imageKey ? (poster ?? cachedPoster) : cachedPoster }
    private var permitsMedia: Bool {
        guard let authorization = api.authorization else { return true }
        return authorization.permitsServiceUse && authorization.snapshot.allows(.read)
            && (sourceAsset?.visibility != .locked || authorization.snapshot.allows(.lockedMedia))
    }
    private var shownPlayer: AVPlayer? {
        guard active else { return nil }
        return usingLocal ? localMedia.player : transport?.player
    }

    var body: some View {
        let timeoutRequest = readiness.requestID
        ZStack {
            Color.black
            if let player = shownPlayer {
                let request = readiness.requestID
                PlayerSurface(player: player, onReadyForDisplay: { ready in
                    readiness.frameReady(ready, request: request)
                }, onFailure: { failure in
                    guard request == readiness.requestID else { return }
                    if usingLocal { localPlaybackFailed = true; invalidate(); attempt += 1 }
                    else { fail(failure, request: request) }
                })
                    .accessibilityIdentifier(readiness.state == .ready ? "viewer.videoReady" : "viewer.videoPreparingSurface")
            } else if usingLocal, let live = localMedia.livePhoto {
                LocalLivePhoto(livePhoto: live, active: active && scenePhase == .active,
                               autoplay: active && scenePhase == .active && (autoPlay || onEnded != nil), muted: muted,
                               onEnded: { if active, scenePhase == .active { onEnded?() } })
            }
            if readiness.state != .ready, let image = shownPoster {
                Image(uiImage: image).resizable().scaledToFit().allowsHitTesting(false)
                    .accessibilityIdentifier("viewer.videoPoster")
            }
            if onPresentationChanged == nil {
                switch readiness.state {
                case .loading:
                    ViewerMediaNotice(title: "Preparing video", isLoading: true)
                case .failed(let message):
                    ViewerMediaNotice(title: "Video couldn’t load", message: message, retry: { attempt += 1 })
                case .ready: EmptyView()
                }
            }
        }
        .task(id: requestKey) {
            let id = UUID()
            let task = Task { await load() }
            loadWork = (id, task)
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            if loadWork?.id == id { loadWork = nil }
        }
        .modifier(VideoFirstFrameDeadline(request: readiness.requestID.uuidString,
                                         waiting: active && scenePhase == .active && readiness.state == .loading,
                                         onTimeout: {
            guard timeoutRequest == readiness.requestID, readiness.state == .loading, active, scenePhase == .active else { return }
            fail(APIError.invalidResponse("The video is taking longer to load. Try again."), request: timeoutRequest)
        }))
        .task(id: imageKey) {
            let key = imageKey
            localPlaybackFailed = false
            posterKey = key; poster = cachedPoster
            guard poster == nil, let sourceAsset, let pipeline, permitsMedia else { return }
            let epoch = api.authorization?.snapshot.epoch
            let stored = await pipeline.storedThumbnail(for: sourceAsset, pixelSize: 1_024)
            guard !Task.isCancelled, key == imageKey, permitsMedia,
                  epoch.map({ api.authorization?.isCurrent($0) == true }) ?? true else { return }
            poster = stored?.uiImage
        }
        .task {
            guard let authorization = api.authorization else { return }
            let epoch = authorization.snapshot.epoch
            let privateEpoch = authorization.snapshot.privateEpoch
            for await snapshot in authorization.updates() {
                guard !Task.isCancelled else { return }
                if !authorization.isCurrent(epoch) || !permitsMedia
                    || (sourceAsset?.visibility == .locked && snapshot.privateEpoch != privateEpoch) {
                    invalidate(); poster = nil; posterKey = nil
                    return
                }
            }
            if !Task.isCancelled { invalidate(); poster = nil; posterKey = nil }
        }
        .onChange(of: readiness.state, initial: true) { _, state in onPresentationChanged?(state) }
        .onChange(of: active, initial: true) { wasActive, active in
            activeNow = active
            if !active { _ = readiness.begin(); transport?.player.pause(); stopLocal() }
            if wasActive && !active { VideoAudio.finish() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { shownPlayer?.pause() }
            else if active && (autoPlay || onEnded != nil) { shownPlayer?.play() }
        }
        .onChange(of: shownPlayer.map(ObjectIdentifier.init), initial: true) { _, _ in playback?.show(shownPlayer, for: assetID) }
        .onDisappear { playback?.release(assetID); invalidate(); if activeNow { VideoAudio.finish() } }
        .onChange(of: muted) { _, value in
            transport?.player.isMuted = value; localMedia.player?.isMuted = value
            if active { VideoAudio.prepare(foreground: !value && !isLivePhotoMotion) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard active, scenePhase == .active, let item = notification.object as? AVPlayerItem,
                  let player = shownPlayer, item === player.currentItem else { return }
            if let onEnded { onEnded() }
            else if loop { player.seek(to: .zero); player.play() }
        }
    }

    private func load() async {
        guard active, permitsMedia else { return }
        VideoAudio.prepare(foreground: !muted && !isLivePhotoMotion)
        if let transport, loadedKey == requestKey {
            if scenePhase == .active && (autoPlay || onEnded != nil) { transport.player.play() }
            return
        }
        let key = requestKey
        invalidate(cancelLoad: false)
        let requestID = readiness.requestID
        let access = VideoPlaybackAccess(authorization: api.authorization, locked: sourceAsset?.visibility == .locked)
        func current() -> Bool {
            !Task.isCancelled && key == requestKey && requestID == readiness.requestID && permitsMedia
                && access.permits
        }
        do {
            // Admission precedes local substitution too: account refusal never grants fallback.
            let request = try await api.authorizedRequest(path: "assets/\(assetID)/" + (original ? "original" : "video/playback"))
            guard current() else { return }
            if !localPlaybackFailed, let sourceAsset,
               let photo = await LocalMediaFallback.matchedPhoto(asset: sourceAsset, matched: matchedLocalPhoto,
                    active: active, kind: isLivePhotoMotion ? .motion : .video), current() {
                let local = await MatchedVideoPlayback.load(photo: photo, motion: isLivePhotoMotion,
                    unchanged: { await LocalMediaFallback.isUnchanged(photo) }, permits: { current() })
                guard current() else { return }
                if let local {
                    localPhoto = photo; usingLocal = true; loadedKey = key
                    switch local {
                    case .player(let item):
                        localMedia.player = AVPlayer(playerItem: item)
                        localMedia.player?.isMuted = muted
                        if scenePhase == .active && (autoPlay || onEnded != nil) { localMedia.player?.play() }
                    case .livePhoto(let live):
                        localMedia.livePhoto = live
                        readiness.frameReady(true, request: requestID)
                    }
                    return
                }
            }
            guard current() else { return }
            let newTransport = try AuthenticatedVideoTransport(request: request, server: api.baseURL, permits: { access.permits })
            transport = newTransport; loadedKey = key
            newTransport.onFailure = { [weak newTransport] failure in
                guard let newTransport, transport === newTransport else { return }
                fail(failure, request: requestID)
            }
            newTransport.player.isMuted = muted
            if scenePhase == .active && (autoPlay || onEnded != nil) { newTransport.player.play() }
        } catch is CancellationError { }
        catch { if current() { fail(error, request: requestID) } }
    }

    private func fail(_ failure: Error, request: UUID) {
        guard request == readiness.requestID else { return }
        readiness.fail(failure.localizedDescription, request: request)
        loadWork?.task.cancel(); loadWork = nil
        transport?.close(); transport = nil; loadedKey = nil; stopLocal()
    }

    private func invalidate(cancelLoad: Bool = true) {
        if cancelLoad { loadWork?.task.cancel(); loadWork = nil }
        _ = readiness.begin()
        transport?.close(); transport = nil; loadedKey = nil; stopLocal()
    }

    private func stopLocal() {
        localMedia.cancel(); localMedia.livePhoto = nil; localPhoto = nil; usingLocal = false
    }
}

/// A video's sound plays as in Photos: with the phone set to silent too, pausing other audio while
/// it plays and letting that audio resume afterwards. Muted videos and Live Photo motion mix with
/// other audio and follow the silent setting.
enum VideoAudio {
    static func prepare(foreground: Bool) {
        try? AVAudioSession.sharedInstance().setCategory(foreground ? .playback : .ambient,
                                                         mode: foreground ? .moviePlayback : .default)
    }

    /// Deactivating can take a moment, so it happens off the main thread. While another video
    /// still plays, the session stays active.
    static func finish() {
        DispatchQueue.global(qos: .utility).async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// AVFoundation requests byte ranges through URLSession. No token is embedded in a URL or undocumented AVAsset option.
@MainActor
final class AuthenticatedVideoTransport: NSObject, @preconcurrency AVAssetResourceLoaderDelegate, @preconcurrency URLSessionDataDelegate {
    let player: AVPlayer
    private let request: URLRequest
    private let server: URL
    private let permits: () -> Bool
    private var session: URLSession!
    private var observation: NSKeyValueObservation?
    var onFailure: ((Error) -> Void)?
    private struct Transfer {
        let loading: AVAssetResourceLoadingRequest
        var receivedOffset: Int64 = 0
        var contentLength: Int64?
    }
    private var transfers: [Int: Transfer] = [:]
    /// Set by close(); the invalidated session raises on a new task.
    private var closed = false

    init(request: URLRequest, server: URL, permits: @escaping () -> Bool = { true }) throws {
        guard let originalURL = request.url,
              var parts = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else { throw APIError.invalidServerURL }
        parts.scheme = "ilyich-media"
        guard let proxyURL = parts.url else { throw APIError.invalidServerURL }
        self.request = request
        self.server = server
        self.permits = permits
        let asset = AVURLAsset(url: proxyURL)
        player = AVPlayer()
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        asset.resourceLoader.setDelegate(self, queue: .main)
        let item = AVPlayerItem(asset: asset)
        observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let failure: Error = item.error ?? APIError.invalidResponse("This video could not be played.")
            Task { @MainActor [weak self] in self?.onFailure?(failure) }
        }
        player.replaceCurrentItem(with: item)
    }

    func close() {
        closed = true
        observation = nil
        onFailure = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        for transfer in transfers.values { transfer.loading.finishLoading(with: CancellationError()) }
        transfers.removeAll(); session.invalidateAndCancel()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        // A request AVFoundation queued before close() still arrives after it.
        guard !closed else { return false }
        guard permits() else { close(); return false }
        var rangeRequest = request
        if let data = loadingRequest.dataRequest {
            let start = max(data.requestedOffset, data.currentOffset)
            let end = data.requestedOffset + Int64(data.requestedLength) - 1
            rangeRequest.setValue(data.requestsAllDataToEndOfResource ? "bytes=\(start)-" : "bytes=\(start)-\(max(start, end))", forHTTPHeaderField: "Range")
        } else {
            rangeRequest.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: rangeRequest)
        transfers[task.taskIdentifier] = Transfer(loading: loadingRequest)
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let id = transfers.first(where: { $0.value.loading === loadingRequest })?.key else { return }
        transfers.removeValue(forKey: id)
        session.getAllTasks { tasks in tasks.first(where: { $0.taskIdentifier == id })?.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard permits(), let origin = self.request.url, let target = request.url, SameOriginRedirectDelegate.sameOrigin(origin, target) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        ClientCertificateStore.respond(to: challenge, server: server, requestURL: task.originalRequest?.url, completion: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard permits() else { close(); completionHandler(.cancel); return }
        guard var transfer = transfers[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        // The body has not arrived yet; Immich's correlation header still tells it from a proxy.
        do { try ServerFailure.check(response, body: nil) }
        catch {
            transfers.removeValue(forKey: dataTask.taskIdentifier); transfer.loading.finishLoading(with: error)
            completionHandler(.cancel); onFailure?(error); return
        }
        let http = response as? HTTPURLResponse
        let range = http?.value(forHTTPHeaderField: "Content-Range").flatMap(HTTPContentRange.init)
        if http?.statusCode == 206 {
            let expectedStart = transfer.loading.dataRequest.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
            guard let range, range.start == expectedStart,
                  response.expectedContentLength < 0 || response.expectedContentLength == range.end - range.start + 1 else {
                let failure = APIError.invalidResponse("The video server returned an invalid byte range.")
                transfers.removeValue(forKey: dataTask.taskIdentifier); transfer.loading.finishLoading(with: failure)
                completionHandler(.cancel); onFailure?(failure); return
            }
            transfer.receivedOffset = range.start
        }
        let total = range?.total ?? response.expectedContentLength
        transfer.contentLength = total >= 0 ? total : nil
        if let info = transfer.loading.contentInformationRequest {
            info.contentType = response.mimeType.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.movie.identifier
            info.contentLength = max(0, total)
            info.isByteRangeAccessSupported = http?.statusCode == 206 || http?.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        }
        if transfer.loading.dataRequest == nil {
            transfer.loading.finishLoading(); transfers.removeValue(forKey: dataTask.taskIdentifier)
            completionHandler(.cancel); return
        }
        transfers[dataTask.taskIdentifier] = transfer
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard permits() else { close(); return }
        guard var transfer = transfers[dataTask.taskIdentifier], let requested = transfer.loading.dataRequest else { return }
        let wantedStart = max(requested.requestedOffset, requested.currentOffset)
        let chunkStart = transfer.receivedOffset
        let chunkEnd = chunkStart + Int64(data.count)
        let requestEnd = requested.requestsAllDataToEndOfResource ? Int64.max : requested.requestedOffset + Int64(requested.requestedLength)
        let wantedEnd = min(requestEnd, transfer.contentLength ?? Int64.max)
        let start = max(wantedStart, chunkStart)
        let end = min(wantedEnd, chunkEnd)
        if end > start {
            requested.respond(with: data.subdata(in: Int(start - chunkStart)..<Int(end - chunkStart)))
        }
        transfer.receivedOffset = chunkEnd
        if chunkEnd >= wantedEnd {
            transfer.loading.finishLoading(); transfers.removeValue(forKey: dataTask.taskIdentifier); dataTask.cancel()
        } else { transfers[dataTask.taskIdentifier] = transfer }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        if let error {
            transfer.loading.finishLoading(with: error)
            // A cancelled task is not a connectivity failure; AVPlayerItem reports it if playback needs it.
            if (error as? URLError)?.code != .cancelled { onFailure?(error) }
        }
        else if let data = transfer.loading.dataRequest {
            let requestEnd = data.requestsAllDataToEndOfResource ? transfer.contentLength : data.requestedOffset + Int64(data.requestedLength)
            let expectedEnd = requestEnd.map { min($0, transfer.contentLength ?? $0) }
            if let expectedEnd, data.currentOffset < expectedEnd {
                let failure = APIError.invalidResponse("The video transfer ended before the requested data arrived. Try again.")
                transfer.loading.finishLoading(with: failure); onFailure?(failure)
            } else { transfer.loading.finishLoading() }
        } else { transfer.loading.finishLoading() }
    }
}

import AVFoundation
import IlyichPlatform
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AuthenticatedVideo: View {
    let api: APIClient
    let assetID: String
    let active: Bool
    var onEnded: (() -> Void)? = nil
    /// The remote still asset that owns this video (the still itself for a Live Photo's motion).
    var sourceAsset: Asset? = nil
    var matchedLocalPhoto: LocalPhoto? = nil
    /// `assetID` is a Live Photo motion video rather than a regular video.
    var isLivePhotoMotion = false
    /// The viewer's playback pill, which follows this page's player while the page is selected.
    var playback: VideoPlaybackState? = nil
    @State private var transport: AuthenticatedVideoTransport?
    @State private var error: String?
    @State private var attempt = 0
    @State private var loadedKey: PlaybackRequest?
    @State private var localMedia = LocalPhotoMedia()
    @State private var localPhoto: LocalPhoto?
    @State private var usingLocal = false
    @State private var activeNow = false
    @AppStorage("viewerAutoPlayVideo") private var autoPlay = true
    @AppStorage("viewerLoopVideo") private var loop = true
    @AppStorage("viewerLoadOriginalVideo") private var original = false
    @AppStorage("viewerMuteVideo") private var muted = false
    @Environment(\.scenePhase) private var scenePhase
    private struct PlaybackRequest: Equatable {
        let assetID: String
        let revision: String?
        let attempt: Int
        let original: Bool
        let localPhoto: LocalPhoto?
        let liveMotion: Bool
        let active: Bool
    }
    private var requestKey: PlaybackRequest {
        PlaybackRequest(assetID: assetID, revision: sourceAsset?.cacheRevision, attempt: attempt,
                        original: original, localPhoto: matchedLocalPhoto, liveMotion: isLivePhotoMotion, active: active)
    }
    private var shouldPlayLocal: Bool { usingLocal && active && scenePhase == .active && (autoPlay || onEnded != nil) }
    private var shownPlayer: AVPlayer? {
        guard active, playback != nil else { return nil }
        return usingLocal ? localMedia.player : transport?.player
    }
    var body: some View {
        ZStack {
            Color.black
            if usingLocal {
                if let player = localMedia.player { PlayerSurface(player: player) }
                else if let live = localMedia.livePhoto {
                    LocalLivePhoto(livePhoto: live, active: active && scenePhase == .active, autoplay: shouldPlayLocal, muted: muted, onEnded: {
                        if usingLocal, active, scenePhase == .active { onEnded?() }
                    })
                }
                else if localMedia.loading { ProgressView().tint(.white) }
                else {
                    ContentUnavailableView { Label("Video couldn’t load", systemImage: "video.slash") }
                    description: { Text(localMedia.failure ?? error ?? "This item is unavailable.") }
                    actions: { Button("Retry") { attempt += 1 } }
                }
            }
            else if let transport { PlayerSurface(player: transport.player) }
            else if let error {
                ContentUnavailableView { Label("Video couldn’t load", systemImage: "video.slash") }
                description: { Text(error) }
                actions: { Button("Retry") { attempt += 1 } }
            } else { ProgressView().tint(.white) }
        }
        .task(id: requestKey) {
            guard active else { return }
            VideoAudio.prepare(foreground: !muted && !isLivePhotoMotion)
            stopLocal()
            if let transport, loadedKey == requestKey {
                if scenePhase == .active && (autoPlay || onEnded != nil) { transport.player.play() }
                return
            }
            do {
                let request = try await api.authorizedRequest(path: "assets/\(assetID)/" + (original ? "original" : "video/playback"))
                try Task.checkCancellation()
                let newTransport = try AuthenticatedVideoTransport(request: request, server: api.baseURL)
                transport?.close(); transport = newTransport; loadedKey = requestKey
                newTransport.onFailure = { [weak newTransport] failure in
                    guard let newTransport, transport === newTransport else { return }
                    self.error = failure.localizedDescription; transport?.close(); transport = nil
                    startLocalFallback(after: failure)
                }
                newTransport.player.isMuted = muted
                if scenePhase == .active && (autoPlay || onEnded != nil) { newTransport.player.play() }
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
        .onChange(of: active, initial: true) { wasActive, active in
            activeNow = active
            if !active { transport?.player.pause(); stopLocal() }
            if wasActive && !active { VideoAudio.finish() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { transport?.player.pause(); localMedia.player?.pause() }
            else if active && (autoPlay || onEnded != nil) {
                if usingLocal { localMedia.player?.play() } else { transport?.player.play() }
            }
        }
        .onChange(of: localMedia.player) { _, _ in adoptLocal() }
        .onChange(of: localMedia.livePhoto) { _, _ in adoptLocal() }
        .onChange(of: shownPlayer.map(ObjectIdentifier.init), initial: true) { _, _ in playback?.show(shownPlayer, for: assetID) }
        .onDisappear {
            playback?.release(assetID)
            transport?.close(); transport = nil; loadedKey = nil; stopLocal(); if activeNow { VideoAudio.finish() }
        }
        .onChange(of: muted) { _, value in
            transport?.player.isMuted = value; localMedia.player?.isMuted = value
            if active { VideoAudio.prepare(foreground: !value && !isLivePhotoMotion) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard active, scenePhase == .active, let item = notification.object as? AVPlayerItem else { return }
            let player = usingLocal ? localMedia.player : transport?.player
            guard let player, item === player.currentItem else { return }
            if let onEnded { onEnded() }
            else if loop { player.seek(to: .zero); player.play() }
        }
    }

    private func startLocalFallback(after failure: Error) {
        guard let sourceAsset else { return }
        let request = requestKey
        Task {
            guard let photo = await LocalMediaFallback.photo(after: failure, asset: sourceAsset, matched: matchedLocalPhoto, active: activeNow,
                                                             kind: isLivePhotoMotion ? .motion : .video),
                  request == requestKey, activeNow, transport == nil else { return }
            localPhoto = photo; usingLocal = true
            localMedia.load(photo, network: false, motion: isLivePhotoMotion)
        }
    }

    /// A Photos edit during the asynchronous request invalidates the proven match.
    private func adoptLocal() {
        guard usingLocal, let photo = localPhoto else { return }
        Task {
            guard await LocalMediaFallback.isUnchanged(photo) else {
                guard usingLocal, localPhoto == photo else { return }
                stopLocal(); error = "The copy on this phone changed. Try again."; return
            }
            guard usingLocal, localPhoto == photo, let player = localMedia.player else { return }
            player.isMuted = muted
            if shouldPlayLocal { player.play() } else { player.pause() }
        }
    }

    private func stopLocal() {
        guard usingLocal || localPhoto != nil else { return }
        localMedia.cancel(); localPhoto = nil; usingLocal = false
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

    init(request: URLRequest, server: URL) throws {
        guard let originalURL = request.url,
              var parts = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else { throw APIError.invalidServerURL }
        parts.scheme = "ilyich-media"
        guard let proxyURL = parts.url else { throw APIError.invalidServerURL }
        self.request = request
        self.server = server
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
        guard let origin = self.request.url, let target = request.url, SameOriginRedirectDelegate.sameOrigin(origin, target) else {
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

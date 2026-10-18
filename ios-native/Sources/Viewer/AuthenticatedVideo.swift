import AVKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AuthenticatedVideo: View {
    let api: APIClient
    let assetID: String
    let active: Bool
    var onEnded: (() -> Void)? = nil
    @State private var transport: AuthenticatedVideoTransport?
    @State private var error: String?
    @State private var attempt = 0
    @State private var loadedKey: String?
    @AppStorage("viewerAutoPlayVideo") private var autoPlay = true
    @AppStorage("viewerLoopVideo") private var loop = true
    @AppStorage("viewerLoadOriginalVideo") private var original = false
    @AppStorage("viewerMuteVideo") private var muted = false
    private var requestKey: String { assetID + String(attempt) + String(original) }
    var body: some View {
        ZStack {
            Color.black
            if let transport { VideoPlayer(player: transport.player) }
            else if let error {
                ContentUnavailableView { Label("Video couldn’t load", systemImage: "video.slash") }
                description: { Text(error) }
                actions: { Button("Retry") { attempt += 1 } }
            } else { ProgressView().tint(.white) }
        }
        .task(id: requestKey + String(active)) {
            guard active else { return }
            if let transport, loadedKey == requestKey {
                if autoPlay || onEnded != nil { transport.player.play() }
                return
            }
            do {
                let request = try await api.authorizedRequest(path: "assets/\(assetID)/" + (original ? "original" : "video/playback"))
                try Task.checkCancellation()
                let newTransport = try AuthenticatedVideoTransport(request: request, server: api.baseURL)
                transport?.close(); transport = newTransport; loadedKey = requestKey
                newTransport.onFailure = { [weak newTransport] message in
                    guard let newTransport, transport === newTransport else { return }
                    self.error = message; transport?.close(); transport = nil
                }
                newTransport.player.isMuted = muted
                if autoPlay || onEnded != nil { newTransport.player.play() }
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
        .onChange(of: active) { _, active in
            if !active { transport?.player.pause() }
        }
        .onDisappear { transport?.close(); transport = nil; loadedKey = nil }
        .onChange(of: muted) { _, value in transport?.player.isMuted = value }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard active, let item = notification.object as? AVPlayerItem, item === transport?.player.currentItem else { return }
            if let onEnded { onEnded() }
            else if loop { transport?.player.seek(to: .zero); transport?.player.play() }
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
    var onFailure: ((String) -> Void)?
    private struct Transfer {
        let loading: AVAssetResourceLoadingRequest
        var receivedOffset: Int64 = 0
        var contentLength: Int64?
    }
    private var transfers: [Int: Transfer] = [:]

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
            let message = item.error?.localizedDescription ?? "This video could not be played."
            Task { @MainActor [weak self] in self?.onFailure?(message) }
        }
        player.replaceCurrentItem(with: item)
    }

    func close() {
        observation = nil
        onFailure = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        for transfer in transfers.values { transfer.loading.finishLoading(with: CancellationError()) }
        transfers.removeAll(); session.invalidateAndCancel()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
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
        do { try APIClient.validate(response) }
        catch { transfer.loading.finishLoading(with: error); transfers.removeValue(forKey: dataTask.taskIdentifier); completionHandler(.cancel); return }
        let http = response as? HTTPURLResponse
        let range = http?.value(forHTTPHeaderField: "Content-Range").flatMap(HTTPContentRange.init)
        if http?.statusCode == 206 {
            let expectedStart = transfer.loading.dataRequest.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
            guard let range, range.start == expectedStart,
                  response.expectedContentLength < 0 || response.expectedContentLength == range.end - range.start + 1 else {
                transfer.loading.finishLoading(with: APIError.invalidResponse("The video server returned an invalid byte range."))
                transfers.removeValue(forKey: dataTask.taskIdentifier); completionHandler(.cancel); return
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
        if let error { transfer.loading.finishLoading(with: error) }
        else if let data = transfer.loading.dataRequest {
            let requestEnd = data.requestsAllDataToEndOfResource ? transfer.contentLength : data.requestedOffset + Int64(data.requestedLength)
            let expectedEnd = requestEnd.map { min($0, transfer.contentLength ?? $0) }
            if let expectedEnd, data.currentOffset < expectedEnd {
                transfer.loading.finishLoading(with: APIError.invalidResponse("The video transfer ended before the requested data arrived. Try again."))
            } else { transfer.loading.finishLoading() }
        } else { transfer.loading.finishLoading() }
    }
}

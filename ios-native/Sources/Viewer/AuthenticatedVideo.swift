import AVKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AuthenticatedVideo: View {
    let api: APIClient
    let assetID: String
    let active: Bool
    @State private var transport: AuthenticatedVideoTransport?
    @State private var error: String?
    @State private var attempt = 0
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
        .task(id: assetID + String(attempt)) {
            guard active else { return }
            do {
                let request = try await api.authorizedRequest(path: "assets/\(assetID)/video/playback")
                try Task.checkCancellation()
                let newTransport = try AuthenticatedVideoTransport(request: request)
                transport?.close(); transport = newTransport
                newTransport.onFailure = { message in
                    self.error = message; transport?.close(); transport = nil
                }
                newTransport.player.play()
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
        .onChange(of: active) { _, active in
            if active { if transport == nil { attempt += 1 } else { transport?.player.play() } }
            else { transport?.player.pause() }
        }
        .onDisappear { transport?.close(); transport = nil }
    }
}

/// AVFoundation requests byte ranges through URLSession. No token is embedded in a URL or undocumented AVAsset option.
@MainActor
final class AuthenticatedVideoTransport: NSObject, @preconcurrency AVAssetResourceLoaderDelegate, @preconcurrency URLSessionDataDelegate {
    let player: AVPlayer
    private let request: URLRequest
    private var session: URLSession!
    private var observation: NSKeyValueObservation?
    var onFailure: ((String) -> Void)?
    private struct Transfer {
        let loading: AVAssetResourceLoadingRequest
        var receivedOffset: Int64 = 0
    }
    private var transfers: [Int: Transfer] = [:]

    init(request: URLRequest) throws {
        guard let originalURL = request.url,
              var parts = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else { throw APIError.invalidServerURL }
        parts.scheme = "ilyich-media"
        guard let proxyURL = parts.url else { throw APIError.invalidServerURL }
        self.request = request
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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard var transfer = transfers[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        do { try APIClient.validate(response) }
        catch { transfer.loading.finishLoading(with: error); transfers.removeValue(forKey: dataTask.taskIdentifier); completionHandler(.cancel); return }
        let http = response as? HTTPURLResponse
        let contentRange = http?.value(forHTTPHeaderField: "Content-Range")
        let total = contentRange?.split(separator: "/").last.flatMap { Int64($0) } ?? response.expectedContentLength
        if http?.statusCode == 206, let range = contentRange?.split(separator: " ").last?.split(separator: "/").first {
            transfer.receivedOffset = range.split(separator: "-").first.flatMap { Int64($0) } ?? 0
        }
        if let info = transfer.loading.contentInformationRequest {
            info.contentType = response.mimeType.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.movie.identifier
            info.contentLength = max(0, total)
            info.isByteRangeAccessSupported = http?.statusCode == 206 || http?.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        }
        transfers[dataTask.taskIdentifier] = transfer
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var transfer = transfers[dataTask.taskIdentifier], let requested = transfer.loading.dataRequest else { return }
        let wantedStart = max(requested.requestedOffset, requested.currentOffset)
        let chunkStart = transfer.receivedOffset
        let chunkEnd = chunkStart + Int64(data.count)
        let wantedEnd = requested.requestsAllDataToEndOfResource ? Int64.max : requested.requestedOffset + Int64(requested.requestedLength)
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
        else { transfer.loading.finishLoading() }
    }
}

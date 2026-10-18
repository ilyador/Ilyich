import SwiftUI
@preconcurrency import GoogleCast

/// Google’s sender framework owns discovery, session recovery, playback and seek controls.
/// Only short-lived Cast session keys are handed to the receiver.
@MainActor
final class CastController: NSObject, ObservableObject, @preconcurrency GCKSessionManagerListener, @preconcurrency GCKRequestDelegate {
    static let shared = CastController()
    @Published private(set) var connected = false
    @Published private(set) var receiver = ""
    @Published private(set) var loading = false
    @Published var error: String?
    private var api: APIClient?
    private var desiredAsset: Asset?
    @Published private(set) var currentAssetID: String?
    private var operation: Task<Void, Never>?
    private var request: GCKRequest?
    private let manager: GCKSessionManager

    private override init() {
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.startDiscoveryAfterFirstTapOnCastButton = true
        GCKCastContext.setSharedInstanceWith(options)
        let context = GCKCastContext.sharedInstance()
        context.useDefaultExpandedMediaControls = true
        manager = context.sessionManager
        super.init()
        manager.add(self)
        updateConnection()
    }

    func select(api: APIClient, asset: Asset, start: Bool = false) {
        if let previous = self.api, previous.cacheScope != api.cacheScope { disconnect() }
        self.api = api
        desiredAsset = asset
        if connected && (start || currentAssetID != nil) { load() }
    }

    func retry() { load(force: true) }
    func showControls() { GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls() }
    func disconnect() {
        operation?.cancel(); operation = nil; request?.delegate = nil; request = nil
        manager.endSessionAndStopCasting(true)
        currentAssetID = nil; loading = false
        connected = false
    }
    func signOut() {
        let previous = api
        disconnect(); api = nil; desiredAsset = nil; error = nil
        Task { await previous?.revokeCastAuthorization() }
    }

    private func updateConnection() {
        connected = manager.currentCastSession?.connectionState == .connected
        receiver = manager.currentCastSession?.device.friendlyName ?? "Cast device"
    }
    private func load(force: Bool = false) {
        guard connected, let api, let asset = desiredAsset,
              force || currentAssetID != asset.id else { return }
        operation?.cancel(); request?.delegate = nil; request = nil
        loading = true; error = nil
        operation = Task { [weak self] in
            do {
                let media = try await api.prepareCast(asset: asset)
                try Task.checkCancellation()
                guard let self, self.connected, self.desiredAsset?.id == asset.id,
                      let client = self.manager.currentCastSession?.remoteMediaClient else { return }
                let metadata = GCKMediaMetadata(metadataType: asset.isVideo ? .movie : .photo)
                metadata.setString(asset.originalFileName, forKey: kGCKMetadataKeyTitle)
                let information = GCKMediaInformationBuilder(contentURL: media.url)
                information.contentType = media.contentType
                information.streamType = .buffered
                information.metadata = metadata
                let data = GCKMediaLoadRequestDataBuilder()
                data.mediaInformation = information.build()
                data.autoplay = true
                self.currentAssetID = asset.id
                let request = client.loadMedia(with: data.build())
                self.request = request; request.delegate = self
            } catch is CancellationError { }
            catch { self?.loading = false; self?.error = error.localizedDescription }
        }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        updateConnection(); load(force: true)
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        updateConnection()
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        operation?.cancel(); request?.delegate = nil; request = nil
        currentAssetID = nil; loading = false; updateConnection()
        if error != nil { self.error = "The Cast connection ended. Reconnect to your device and try again." }
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        loading = false; updateConnection()
        self.error = "Couldn’t connect to the Cast device. Check that both devices can use the same local network, then try again."
    }
    func requestDidComplete(_ request: GCKRequest) {
        guard self.request === request else { return }
        loading = false
    }
    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        guard self.request === request else { return }
        loading = false; currentAssetID = nil
        self.error = "The Cast device couldn’t open this media. It must reach your server directly; proxy-only headers and client certificates cannot be forwarded to the receiver. Check the server address or try another item."
    }
}

struct CastView: View {
    let api: APIClient
    let asset: Asset
    @ObservedObject private var cast = CastController.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Label(cast.connected ? cast.receiver : "Choose a Cast device", systemImage: "tv")
                        Spacer()
                        NativeCastButton().frame(width: 48, height: 48).accessibilityLabel("Choose Cast device")
                    }
                    if cast.loading { HStack { ProgressView(); Text("Opening media on your TV…") } }
                    if cast.connected {
                        Button("Playback controls", systemImage: "playpause") { cast.showControls() }
                        Button("Stop casting", systemImage: "stop.circle", role: .destructive) { cast.disconnect() }
                    }
                }
                if let error = cast.error {
                    Section { Text(error); if cast.connected { Button("Retry") { cast.retry() } } }
                }
            }
            .navigationTitle("Cast")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { cast.select(api: api, asset: asset, start: true) }
        }.presentationDetents([.medium, .large])
    }
}

private struct NativeCastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton { GCKUICastButton(frame: .zero) }
    func updateUIView(_ view: GCKUICastButton, context: Context) { view.tintColor = .label }
}

import SwiftUI
@preconcurrency import GoogleCast

/// The account Cast works for: its grants and how its media reaches a receiver.
struct CastAccount: Sendable {
    /// The account's cache scope, which the viewer's client must match.
    let scope: String
    let grants: CastGrantStore
    let resolver: any CastMediaResolving
}

/// The receiver connection, as the service sees it. GoogleCastLink in the app; fakes in tests.
@MainActor protocol CastReceiverLink: AnyObject {
    var events: (any CastLinkEvents)? { get set }
    var isConnected: Bool { get }
    var receiverName: String { get }
    /// Opens `media` on the receiver. `finished` is called once, with whether it opened, unless a
    /// later load or `cancelLoad` replaces it first.
    func load(_ media: CastMedia, title: String, isVideo: Bool, finished: @escaping @MainActor (Bool) -> Void)
    func cancelLoad()
    func endSession()
    func showControls()
}

@MainActor protocol CastLinkEvents: AnyObject {
    func castLinkStarted()
    func castLinkResumed()
    func castLinkEnded(withError: Bool)
    func castLinkFailedToStart()
}

/// Casting for the signed-in account (REBUILD_ROADMAP.md W2). Google's sender framework owns
/// discovery, session recovery, playback and seek controls; the receiver gets only a short-lived
/// grant's token, which is revoked when casting stops, the Cast session ends, the account changes
/// and at sign-out. Every load carries a generation, so an older load's answer never overwrites a
/// newer one, and an asset that may not be cast never replaces what is on the TV.
@MainActor
final class CastSessionService: ObservableObject, CastLinkEvents {
    /// The app's service. Made at launch, which sets up the Google Cast context.
    static let shared = CastSessionService(link: GoogleCastLink())

    @Published private(set) var connected = false
    @Published private(set) var receiver = ""
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var currentAssetID: String?
    private let link: any CastReceiverLink
    private var account: CastAccount?
    private var desiredAsset: Asset?
    private var operation: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(link: any CastReceiverLink) {
        self.link = link
        link.events = self
        updateConnection()
    }

    /// Follows the signed-in account. Another account, or none, stops casting and revokes the
    /// previous account's grants.
    func attach(_ account: CastAccount?) {
        guard account?.grants !== self.account?.grants else { return }
        if self.account != nil { stop() }
        self.account = account
        desiredAsset = nil; error = nil
    }

    /// The asset on screen. Casting starts with `start`, and follows the viewer once something is
    /// on the TV. An asset that may not be cast, such as a locked one, keeps the current media.
    func select(api: APIClient, asset: Asset, start: Bool = false) {
        guard let account, account.scope == api.cacheScope, CastEligibility.allows(asset) else { return }
        desiredAsset = asset
        if connected && (start || currentAssetID != nil) { load() }
    }

    func retry() { load(force: true) }
    func showControls() { link.showControls() }

    /// Stop casting: ends the Cast session and revokes the grant.
    func disconnect() { stop() }

    /// Stops casting for sign-out and revokes the account's grants while its token still works.
    /// Sign-out waits for it, before it ends the session on the server.
    func signOut() async {
        let grants = account?.grants
        invalidate(); link.endSession()
        currentAssetID = nil; loading = false; connected = false
        account = nil; desiredAsset = nil; error = nil
        await grants?.revoke()
    }

    private func stop() {
        invalidate(); link.endSession()
        currentAssetID = nil; loading = false; connected = false
        revokeGrants()
    }

    private func revokeGrants() {
        guard let grants = account?.grants else { return }
        Task { await grants.revoke() }
    }

    /// Nothing a load started before this may change the state any more.
    private func invalidate() {
        generation &+= 1
        operation?.cancel(); operation = nil
        link.cancelLoad()
    }

    private func updateConnection() {
        connected = link.isConnected
        receiver = link.receiverName
    }

    private func load(force: Bool = false) {
        guard connected, let account, let asset = desiredAsset,
              force || currentAssetID != asset.id else { return }
        invalidate()
        let generation = generation
        loading = true; error = nil
        operation = Task { [weak self] in
            do {
                let grant = try await account.grants.grant(covering: CastEligibility.need(for: asset))
                let media = try await account.resolver.media(for: asset, grant: grant)
                try Task.checkCancellation()
                guard let self, self.generation == generation, self.connected else { return }
                self.currentAssetID = asset.id
                self.link.load(media, title: asset.originalFileName, isVideo: asset.isVideo) { [weak self] opened in
                    guard let self, self.generation == generation else { return }
                    self.loading = false
                    if !opened { self.currentAssetID = nil; self.error = Self.receiverFailure }
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation else { return }
                self.loading = false; self.error = error.localizedDescription
            }
        }
    }

    static let receiverFailure = "The Cast device couldn’t open this media. It must reach your server directly; proxy-only headers and client certificates cannot be forwarded to the receiver. Check the server address or try another item."

    // MARK: CastLinkEvents

    func castLinkStarted() { updateConnection(); load(force: true) }
    func castLinkResumed() { updateConnection() }
    func castLinkEnded(withError: Bool) {
        invalidate()
        currentAssetID = nil; loading = false; updateConnection()
        if withError { error = "The Cast connection ended. Reconnect to your device and try again." }
        revokeGrants()
    }
    func castLinkFailedToStart() {
        loading = false; updateConnection()
        error = "Couldn’t connect to the Cast device. Check that both devices can use the same local network, then try again."
    }
}

/// The Google Cast sender framework. Its context is set up once, when the app launches.
@MainActor
final class GoogleCastLink: NSObject, CastReceiverLink, @preconcurrency GCKSessionManagerListener, @preconcurrency GCKRequestDelegate {
    weak var events: (any CastLinkEvents)?
    private let manager: GCKSessionManager
    private var request: GCKRequest?
    private var finished: (@MainActor (Bool) -> Void)?

    override init() {
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.startDiscoveryAfterFirstTapOnCastButton = true
        GCKCastContext.setSharedInstanceWith(options)
        let context = GCKCastContext.sharedInstance()
        context.useDefaultExpandedMediaControls = true
        manager = context.sessionManager
        super.init()
        manager.add(self)
    }

    var isConnected: Bool { manager.currentCastSession?.connectionState == .connected }
    var receiverName: String { manager.currentCastSession?.device.friendlyName ?? "Cast device" }

    func load(_ media: CastMedia, title: String, isVideo: Bool, finished: @escaping @MainActor (Bool) -> Void) {
        cancelLoad()
        guard let client = manager.currentCastSession?.remoteMediaClient else { return finished(false) }
        let metadata = GCKMediaMetadata(metadataType: isVideo ? .movie : .photo)
        metadata.setString(title, forKey: kGCKMetadataKeyTitle)
        let information = GCKMediaInformationBuilder(contentURL: media.url)
        information.contentType = media.contentType
        information.streamType = .buffered
        information.metadata = metadata
        let data = GCKMediaLoadRequestDataBuilder()
        data.mediaInformation = information.build()
        data.autoplay = true
        let request = client.loadMedia(with: data.build())
        self.request = request; self.finished = finished
        request.delegate = self
    }

    func cancelLoad() { request?.delegate = nil; request = nil; finished = nil }
    func endSession() { cancelLoad(); manager.endSessionAndStopCasting(true) }
    func showControls() { GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls() }

    private func finish(_ request: GCKRequest, opened: Bool) {
        guard self.request === request, let finished else { return }
        cancelLoad()
        finished(opened)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) { events?.castLinkStarted() }
    func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) { events?.castLinkResumed() }
    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        cancelLoad(); events?.castLinkEnded(withError: error != nil)
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        events?.castLinkFailedToStart()
    }
    func requestDidComplete(_ request: GCKRequest) { finish(request, opened: true) }
    func request(_ request: GCKRequest, didFailWithError error: GCKError) { finish(request, opened: false) }
}

struct CastView: View {
    let api: APIClient
    let asset: Asset
    @ObservedObject private var cast = CastSessionService.shared
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

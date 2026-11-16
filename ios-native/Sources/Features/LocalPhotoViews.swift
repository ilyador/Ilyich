import SwiftUI
import Observation
@preconcurrency import Photos
@preconcurrency import PhotosUI
@preconcurrency import AVFoundation
import AVKit

/// Media for one viewer page, from the Photos adapter's shared image manager. A new load or
/// cancel drops the request before it, so a page never shows an older photo's media.
@MainActor @Observable final class LocalPhotoMedia {
    var image: UIImage?
    var player: AVPlayer?
    var livePhoto: PHLivePhoto?
    var loading = false
    var cloud = false
    var progress: Double?
    var failure: String?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private let device: any DeviceMediaProviding

    init(device: any DeviceMediaProviding = PhotoKitAdapter.shared) { self.device = device }

    func load(_ photo: LocalPhoto, network: Bool, motion: Bool = false, maximumResolution: Bool = false) {
        cancel(); image = nil; livePhoto = nil; cloud = false; progress = nil; failure = nil; loading = true
        let kind: DeviceMediaRequest, missing: String
        if photo.video { kind = .video(network: network); missing = "The video is unavailable on this phone." }
        else if photo.live && motion { kind = .livePhoto(pixels: 1600, network: network); missing = "The Live Photo is unavailable on this phone." }
        else { kind = .image(pixels: maximumResolution ? nil : 3000, network: network); missing = "The photo is unavailable on this phone." }
        let stream = device.media(photo.id, kind)
        request = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .image(let image, let final):
                    self.image = image
                    if final { self.loading = false; self.progress = nil }
                case .livePhoto(let live, let final):
                    self.livePhoto = live
                    if final { self.loading = false; self.progress = nil }
                case .player(let item):
                    self.player = AVPlayer(playerItem: item); self.loading = false; self.progress = nil
                case .progress(let value):
                    self.progress = min(1, max(0, value))
                case .unavailable(let inCloud, let message):
                    self.loading = false
                    self.cloud = inCloud && self.image == nil && self.livePhoto == nil
                    self.progress = nil
                    self.failure = inCloud && message == nil ? nil : (message ?? missing)
                }
            }
        }
    }

    func cancel() {
        request?.cancel(); request = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        loading = false; progress = nil
    }

    func cancelDownload() {
        guard loading else { return }
        cancel()
        cloud = true
        failure = "Download cancelled."
    }
}

/// A grid cell's photo, from the Photos adapter's shared image manager.
struct LocalPhotoThumbnail: View {
    let photo: LocalPhoto
    @State private var image: UIImage?
    @State private var cloud = false
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Color.secondary.opacity(0.1)
                if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                else { Image(systemName: cloud ? "icloud" : "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                if photo.video || photo.live { Image(systemName: photo.video ? "play.fill" : "livephoto").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(7) }
            }.clipped()
        }.task(id: photo) {
            image = nil; cloud = false
            for await event in PhotoKitAdapter.shared.media(photo.id, .thumbnail(pixels: 420)) {
                switch event {
                case .image(let value, _): image = value
                case .unavailable(let inCloud, _): cloud = inCloud && image == nil
                default: break
                }
            }
        }.accessibilityHidden(true)
    }
}

struct LocalPhotoViewer: View {
    /// Photos to swipe through; a single photo when the caller has no neighbors to offer.
    var onChanged: (() -> Void)? = nil
    /// The photos to swipe through, less those removed while the viewer is open.
    @State private var photos: [LocalPhoto]
    @State private var selectedID: String
    @State private var showActions = false
    @State private var actionPhotos: [LocalPhoto] = []
    @State private var motion = false
    @State private var reload = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mediaSources) private var mediaSources

    init(photo: LocalPhoto, photos: [LocalPhoto] = [], onChanged: (() -> Void)? = nil) {
        _photos = State(initialValue: photos.contains(where: { $0.id == photo.id }) ? photos : [photo])
        self.onChanged = onChanged
        _selectedID = State(initialValue: photo.id)
    }

    private var selectedIndex: Int { photos.firstIndex { $0.id == selectedID } ?? 0 }
    private var photo: LocalPhoto { photos[selectedIndex] }
    var body: some View {
        NavigationStack {
            TabView(selection: $selectedID) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, page in
                    Group {
                        if abs(index - selectedIndex) <= 1 {
                            ViewerLocalPage(photo: page, active: page.id == selectedID,
                                            motion: motion && page.id == selectedID, reload: reload,
                                            pipeline: mediaSources?.pipeline, onDismiss: { dismiss() })
                        } else { Color.black }
                    }.tag(page.id)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
            .overlay(alignment: .topLeading) {
                ViewerBackupStatus(photo: photo).id(photo.id).padding(.horizontal, 16).padding(.top, 8)
            }
            .navigationTitle(photo.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Photo actions", systemImage: "ellipsis") { actionPhotos = [photo]; showActions = true }
                }
                if photo.live { ToolbarItem(placement: .topBarTrailing) { Toggle("Live Photo", isOn: $motion).toggleStyle(.button) } }
            }
        }
        .sheet(isPresented: $showActions) {
            NavigationStack {
                LocalPhotoActionsView(photos: actionPhotos) { change in
                    onChanged?()
                    if case .removed(let ids) = change { remove(ids) } else { reload += 1 }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { OrientationLock.viewerAppeared() }
        .onDisappear { OrientationLock.viewerDisappeared() }
        .onChange(of: selectedID) { motion = false }
    }

    /// Takes removed photos out of the pages. The photo after the current one, or else the one
    /// before, shows next; the viewer closes when none is left.
    private func remove(_ ids: [String]) {
        let removed = Set(ids)
        guard photos.contains(where: { removed.contains($0.id) }) else { return }
        let index = selectedIndex
        let remaining = photos.filter { !removed.contains($0.id) }
        guard !remaining.isEmpty else { dismiss(); return }
        if removed.contains(selectedID) {
            let after = photos[index...].first { !removed.contains($0.id) }
            let before = photos[..<index].last { !removed.contains($0.id) }
            selectedID = (after ?? before ?? remaining[0]).id
        }
        photos = remaining
    }

}

private struct LocalPhotoSourceRequestID: Hashable {
    let photo: LocalPhoto
    let active: Bool
    let resolverID: ObjectIdentifier?
    let retry: Int
}

protocol LocalPhotoSourceResolving: Sendable {
    func resolve(_ photo: LocalPhoto) async -> MediaSourceResolution
}

extension MediaSourceResolver: LocalPhotoSourceResolving {}

@MainActor @Observable final class LocalPhotoSourceSelection {
    private(set) var resolution: MediaSourceResolution?
    private(set) var isResolving = false
    @ObservationIgnored private var generation = 0

    func resolve(_ photo: LocalPhoto, using resolver: (any LocalPhotoSourceResolving)?, active: Bool = true) async {
        guard active else { cancel(); return }
        generation += 1
        let request = generation
        resolution = nil
        isResolving = true
        guard let resolver else {
            resolution = .unavailable(message: "Photo sources are unavailable. Try again shortly.")
            isResolving = false
            return
        }
        let next = await resolver.resolve(photo)
        guard !Task.isCancelled, generation == request else { return }
        resolution = next
        isResolving = false
    }

    func viewOnPhone() {
        guard case .serverUnavailable(let photo, _, _) = resolution else { return }
        resolution = .device(photo)
    }

    func cancel() {
        generation += 1
        isResolving = false
    }
}

/// Resolves one page without replacing the pager, toolbar or navigation around it.
struct ViewerLocalPage: View {
    let photo: LocalPhoto
    let active: Bool
    var motion = false
    var reload = 0
    var pipeline: MediaPipeline? = nil
    var sharedPlayback: VideoPlaybackState? = nil
    var showsPlaybackControls = true
    let onDismiss: () -> Void
    var onTap: (Double) -> Void = { _ in }
    var onSwipeUp: () -> Void = {}
    @Environment(\.mediaSources) private var mediaSources
    @State private var source = LocalPhotoSourceSelection()
    @State private var sourceRetry = 0
    @State private var ownedPlayback = VideoPlaybackState()

    private var sourceRequestID: LocalPhotoSourceRequestID {
        LocalPhotoSourceRequestID(photo: photo, active: active, resolverID: mediaSources.map { ObjectIdentifier($0) }, retry: sourceRetry + reload)
    }
    private var playback: VideoPlaybackState { sharedPlayback ?? ownedPlayback }
    private var mediaPipeline: MediaPipeline? { pipeline ?? mediaSources?.pipeline }

    var body: some View {
        ZStack {
            Color.black
            page
        }
        .task(id: sourceRequestID) {
            await source.resolve(photo, using: mediaSources, active: active)
        }
        .onDisappear { source.cancel() }
    }

    @ViewBuilder private var page: some View {
        switch source.resolution {
        case .server(let asset):
            if let mediaSources {
                if asset.isVideo {
                    AuthenticatedVideo(api: mediaSources.api, assetID: asset.id, active: active,
                                       sourceAsset: asset, matchedLocalPhoto: photo, playback: playback, pipeline: mediaPipeline)
                        .overlay(alignment: .bottom) {
                            if showsPlaybackControls {
                                ViewerVideoControls(playback: playback, visible: active)
                                    .frame(maxWidth: 520).padding(.horizontal, 24).padding(.bottom, 16)
                            }
                        }
                        .gesture(ViewerTap { onTap(0.5) })
                        .gesture(ViewerSwipe(direction: .up, action: onSwipeUp))
                        .gesture(ViewerSwipe(direction: .down, action: onDismiss))
                } else if motion, let videoID = asset.livePhotoVideoId {
                    AuthenticatedVideo(api: mediaSources.api, assetID: videoID, active: active,
                                       sourceAsset: asset, matchedLocalPhoto: photo, isLivePhotoMotion: true, pipeline: mediaPipeline)
                } else if let mediaPipeline {
                    ViewerPhoto(pipeline: mediaPipeline, asset: asset, active: active, onTap: onTap,
                                onDismiss: onDismiss, matchedLocalPhoto: photo, onSwipeUp: onSwipeUp, settled: active)
                }
            } else { unavailable("Photo sources are no longer available.") }
        case .device(let current):
            LocalPhotoPage(photo: current, active: active, motion: motion, reload: reload,
                           pipeline: mediaPipeline, sharedPlayback: playback, showsPlaybackControls: showsPlaybackControls,
                           onDismiss: onDismiss, onTap: onTap, onSwipeUp: onSwipeUp)
        case .serverUnavailable(_, _, let message):
            unavailable("The backed-up copy is unavailable.\n\(message)", viewOnPhone: { source.viewOnPhone() })
        case .unavailable(let message): unavailable(message)
        case nil:
            ViewerLocalPoster(photo: photo, pipeline: mediaPipeline)
            if active { ViewerMediaNotice(title: "Opening photo", isLoading: true) }
        }
    }

    private func unavailable(_ message: String, viewOnPhone: (() -> Void)? = nil) -> some View {
        ZStack {
            ViewerLocalPoster(photo: photo, pipeline: mediaPipeline)
            if active {
                VStack(spacing: 18) {
                    ViewerMediaNotice(title: "Photo unavailable", message: message,
                                      isLoading: source.isResolving, retry: { sourceRetry += 1 })
                    if let viewOnPhone {
                        Button("View on this phone", action: viewOnPhone).buttonStyle(.glass).frame(minHeight: 44)
                    }
                }.foregroundStyle(.white)
            }
        }
    }
}

struct LocalPhotoPage: View {
    let photo: LocalPhoto
    let active: Bool
    let motion: Bool
    let reload: Int
    let pipeline: MediaPipeline?
    var sharedPlayback: VideoPlaybackState? = nil
    var showsPlaybackControls = true
    let onDismiss: () -> Void
    var onTap: (Double) -> Void = { _ in }
    var onSwipeUp: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @State private var media = LocalPhotoMedia()
    @State private var network = false
    @State private var retry = 0
    @State private var videoReady = false
    @State private var videoFailure: String?
    @State private var ownedPlayback = VideoPlaybackState()
    @AppStorage("imageLoadOriginal") private var fullResolution = false
    @AppStorage("viewerAutoPlayVideo") private var autoPlay = true
    @AppStorage("viewerMuteVideo") private var muted = false
    @AppStorage("viewerLoopVideo") private var loop = true
    private var playback: VideoPlaybackState { sharedPlayback ?? ownedPlayback }
    private var videoDeadlineRequest: String {
        "\(photo.id)|\(retry)|\(reload)|\(network)|\(media.player.map { String(describing: ObjectIdentifier($0)) } ?? "none")"
    }
    var body: some View {
        let deadlineRequest = videoDeadlineRequest
        ZStack {
            Color.black.ignoresSafeArea()
            ViewerLocalPoster(photo: photo, pipeline: pipeline)
            if let player = media.player {
                PlayerSurface(player: player, onReadyForDisplay: { videoReady = $0 }, onFailure: { failure in
                    videoReady = false; videoFailure = failure.localizedDescription; player.pause()
                })
                .opacity(videoReady && videoFailure == nil ? 1 : 0)
                .contentShape(.rect)
                .gesture(ViewerTap { onTap(0.5) })
                .gesture(ViewerSwipe(direction: .up, action: onSwipeUp))
                .gesture(ViewerSwipe(direction: .down, action: onDismiss))
            }
            else if let live = media.livePhoto { LocalLivePhoto(livePhoto: live, active: active && scenePhase == .active) }
            else if let image = media.image { ZoomablePhoto(image: image, resetZoom: !active, onTap: onTap, onDismiss: onDismiss, onZoom: { }, onSwipeUp: onSwipeUp) }

            if let videoFailure {
                ViewerMediaNotice(title: "Video couldn’t play", message: videoFailure, retry: { retry += 1 })
            } else if media.loading || (media.player != nil && !videoReady) {
                VStack(spacing: 12) {
                    ViewerMediaNotice(title: network ? "Downloading from iCloud" : (photo.video ? "Preparing video" : "Loading photo"),
                                      isLoading: true, progress: media.progress)
                    if network { Button("Cancel download") { media.cancelDownload() }.buttonStyle(.glass).frame(minHeight: 44) }
                }.allowsHitTesting(network)
            }
            else if media.player == nil && media.livePhoto == nil && media.image == nil {
                VStack(spacing: 12) {
                    ViewerMediaNotice(title: media.cloud ? "Original is in iCloud" : "This item couldn’t load",
                                      message: media.cloud ? "The preview is available. Download the original to open it." : media.failure,
                                      retry: media.cloud && !network ? nil : { retry += 1 })
                    if media.cloud && !network {
                        Button("Download from iCloud") { network = true }.buttonStyle(.glass).frame(minHeight: 44)
                    }
                }.foregroundStyle(.white)
            }
        }
        .overlay(alignment: .bottom) {
            if photo.video, showsPlaybackControls {
                ViewerVideoControls(playback: playback, visible: active && videoReady && videoFailure == nil)
                    .frame(maxWidth: 520).padding(.horizontal, 24).padding(.bottom, 16)
            }
        }
        .modifier(VideoFirstFrameDeadline(request: deadlineRequest,
                                          waiting: active && scenePhase == .active && media.player != nil && !videoReady && videoFailure == nil,
                                          onTimeout: {
            guard deadlineRequest == videoDeadlineRequest, active, scenePhase == .active,
                  !videoReady, videoFailure == nil else { return }
            media.player?.pause()
            videoFailure = "This video is taking too long to open. Your preview is kept; try again."
        }))
        .task(id: "\(photo.id)|\(String(describing: photo.modified))|\(active)|\(network)|\(motion)|\(retry)|\(reload)|\(fullResolution)") {
            guard active else { media.cancel(); return }
            videoReady = false; videoFailure = nil
            if active && photo.video { VideoAudio.prepare(foreground: !muted) }
            media.load(photo, network: network, motion: motion, maximumResolution: fullResolution)
        }
        .onChange(of: media.player) { _, player in
            videoReady = false
            playback.show(active ? player : nil, for: photo.id)
            player?.isMuted = muted
            if active && scenePhase == .active && autoPlay { player?.play() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { media.player?.pause() }
            else if active && autoPlay { media.player?.play() }
        }
        .onChange(of: muted) { _, value in
            media.player?.isMuted = value
            if active && photo.video { VideoAudio.prepare(foreground: !value) }
        }
        .onChange(of: active) { _, value in
            if !value { media.player?.pause() }
            playback.show(value ? media.player : nil, for: photo.id)
            if value && scenePhase == .active && autoPlay { media.player?.play() }
            if photo.video { if value { VideoAudio.prepare(foreground: !muted) } else { VideoAudio.finish() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard active, scenePhase == .active, loop, let item = notification.object as? AVPlayerItem,
                  let player = media.player, item === player.currentItem else { return }
            player.seek(to: .zero); player.play()
        }
        .onDisappear { playback.release(photo.id); media.cancel(); if active && photo.video { VideoAudio.finish() } }
    }
}

struct LocalLivePhoto: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let active: Bool
    /// Optional: play once automatically and report the end of playback.
    var autoplay = false
    var muted = false
    var onEnded: (() -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView(); view.contentMode = .scaleAspectFit; view.livePhoto = livePhoto
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onEnded = onEnded
        view.isMuted = muted
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto; coordinator.started = nil }
        if !active { view.stopPlayback(); coordinator.started = nil }
        else if autoplay, coordinator.started !== livePhoto { coordinator.started = livePhoto; view.startPlayback(with: .full) }
    }
    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        coordinator.onEnded = nil; view.delegate = nil; view.stopPlayback(); view.livePhoto = nil
    }
    @MainActor final class Coordinator: NSObject, @preconcurrency PHLivePhotoViewDelegate {
        var onEnded: (() -> Void)?
        var started: PHLivePhoto?
        func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) { onEnded?() }
    }
}

struct LimitedPhotoAccessPicker: UIViewControllerRepresentable {
    let onDone: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(onDone: onDone) }
    func updateUIViewController(_ controller: Controller, context: Context) { }
    @MainActor final class Controller: UIViewController {
        let onDone: () -> Void
        private var presentedPicker = false
        init(onDone: @escaping () -> Void) { self.onDone = onDone; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presentedPicker else { return }; presentedPicker = true
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) { [weak self] _ in Task { @MainActor in self?.onDone() } }
        }
    }
}

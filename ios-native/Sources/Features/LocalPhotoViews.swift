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
    @State private var sourceRetry = 0
    @State private var source = LocalPhotoSourceSelection()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mediaSources) private var mediaSources

    init(photo: LocalPhoto, photos: [LocalPhoto] = [], onChanged: (() -> Void)? = nil) {
        _photos = State(initialValue: photos.contains(where: { $0.id == photo.id }) ? photos : [photo])
        self.onChanged = onChanged
        _selectedID = State(initialValue: photo.id)
    }

    private var selectedIndex: Int { photos.firstIndex { $0.id == selectedID } ?? 0 }
    private var photo: LocalPhoto { photos[selectedIndex] }
    private var sourceRequestID: LocalPhotoSourceRequestID {
        LocalPhotoSourceRequestID(photoID: photo.id, resolverID: mediaSources.map { ObjectIdentifier($0) }, retry: sourceRetry)
    }

    var body: some View {
        resolvedContent
        // Only the viewer turns with the phone; the rest of the app stays upright.
        .onAppear { OrientationLock.viewerAppeared() }
        .onDisappear { OrientationLock.viewerDisappeared() }
        .task(id: sourceRequestID) { await source.resolve(photo, using: mediaSources) }
        .onDisappear { source.cancel() }
        .onChange(of: selectedID) { motion = false }
    }

    @ViewBuilder private var resolvedContent: some View {
        switch source.resolution {
        case .server(let asset):
            if let mediaSources {
                AssetViewer(api: mediaSources.api, pipeline: mediaSources.pipeline,
                            route: ViewerRoute(asset: asset, source: .single, albumContext: nil),
                            window: .single(asset), matchedLocalPhotos: [asset.id: photo], onClose: { dismiss() })
            } else { unavailableSource("Photo sources are no longer available.", retryable: true) }
        case .device(let localPhoto):
            deviceViewer(localPhoto)
        case .serverUnavailable(_, _, let message):
            unavailableSource("The backed-up copy is unavailable.\n\(message)", retryable: true) {
                source.viewOnPhone()
            }
        case .unavailable(let message):
            unavailableSource(message, retryable: true)
        case nil:
            sourceLoadingView
        }
    }

    private func deviceViewer(_ current: LocalPhoto) -> some View {
        NavigationStack {
            TabView(selection: $selectedID) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, page in
                    Group {
                        // Only the current photo and its neighbors hold full-size media.
                        if abs(index - selectedIndex) <= 1 {
                            LocalPhotoPage(photo: page.id == current.id ? current : page,
                                           active: page.id == selectedID, motion: motion && page.id == selectedID,
                                           reload: reload, onDismiss: { dismiss() })
                        } else { Color.black }
                    }.tag(page.id)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(current.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Photo actions", systemImage: "ellipsis") { actionPhotos = [current]; showActions = true }
                }
                if current.live { ToolbarItem(placement: .topBarTrailing) { Toggle("Live Photo", isOn: $motion).toggleStyle(.button) } }
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
    }

    private func unavailableSource(_ message: String, retryable: Bool, viewOnPhone: (() -> Void)? = nil) -> some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 18) {
                    if source.isResolving { ProgressView().tint(.white) }
                    else { Image(systemName: "photo.badge.exclamationmark").font(.largeTitle) }
                    Text(message).multilineTextAlignment(.center)
                    if retryable {
                        Button("Retry") { sourceRetry += 1 }
                    }
                    if let viewOnPhone { Button("View on this phone", action: viewOnPhone) }
                }.padding(28).foregroundStyle(.white)
            }
            .navigationTitle(photo.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private var sourceLoadingView: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ProgressView().tint(.white).accessibilityLabel("Opening photo")
            }
            .navigationTitle(photo.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
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
    let photoID: String
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

    func resolve(_ photo: LocalPhoto, using resolver: (any LocalPhotoSourceResolving)?) async {
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

private struct LocalPhotoPage: View {
    let photo: LocalPhoto
    let active: Bool
    let motion: Bool
    let reload: Int
    let onDismiss: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var media = LocalPhotoMedia()
    @State private var network = false
    @State private var retry = 0
    @AppStorage("imageLoadOriginal") private var fullResolution = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = media.player { VideoPlayer(player: player) }
            else if let live = media.livePhoto { LocalLivePhoto(livePhoto: live, active: active && scenePhase == .active) }
            else if let image = media.image { ZoomablePhoto(image: image, resetZoom: !active, onTap: { _ in }, onDismiss: onDismiss, onZoom: { }) }
            else if media.loading {
                VStack(spacing: 14) {
                    if let progress = media.progress { ProgressView(value: progress).frame(maxWidth: 220) }
                    else { ProgressView().tint(.white) }
                    if network { Button("Cancel download") { media.cancelDownload() } }
                }
            }
            else {
                VStack(spacing: 18) {
                    Image(systemName: media.cloud ? "icloud.and.arrow.down" : "photo.badge.exclamationmark").font(.largeTitle)
                    Text(media.cloud ? (media.failure ?? "This item is stored in iCloud.") : (media.failure ?? "This item is unavailable."))
                        .multilineTextAlignment(.center)
                    if !network { Button("Download from iCloud") { network = true } }
                    else { Button("Retry") { retry += 1 } }
                }.padding(28).foregroundStyle(.white)
            }
        }
        .task(id: "\(photo.id)|\(network)|\(motion)|\(retry)|\(reload)|\(fullResolution)") {
            if active && photo.video { VideoAudio.prepare(foreground: true) }
            media.load(photo, network: network, motion: motion, maximumResolution: fullResolution)
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { media.player?.pause() } }
        .onChange(of: active) { _, value in
            if !value { media.player?.pause() }
            if photo.video { if value { VideoAudio.prepare(foreground: true) } else { VideoAudio.finish() } }
        }
        .onDisappear { media.cancel(); if active && photo.video { VideoAudio.finish() } }
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

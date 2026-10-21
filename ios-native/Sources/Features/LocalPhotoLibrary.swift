import SwiftUI
import Observation
@preconcurrency import Photos
@preconcurrency import PhotosUI
@preconcurrency import AVFoundation
import AVKit

struct LocalPhoto: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date?
    let modified: Date?
    let video: Bool
    let live: Bool
    let duration: Double
    let width: Int
    let height: Int
    let isFavorite: Bool
    let latitude: Double?
    let longitude: Double?
    var title: String { date?.formatted(date: .abbreviated, time: .shortened) ?? (video ? "Video" : "Photo") }
    init(_ asset: PHAsset) {
        id = asset.localIdentifier; date = asset.creationDate; modified = asset.modificationDate
        video = asset.mediaType == .video; live = asset.mediaSubtypes.contains(.photoLive); duration = asset.duration
        width = asset.pixelWidth; height = asset.pixelHeight; isFavorite = asset.isFavorite
        latitude = asset.location?.coordinate.latitude; longitude = asset.location?.coordinate.longitude
    }
    init(id: String, date: Date?, modified: Date? = nil, video: Bool = false, live: Bool = false,
         duration: Double = 0, width: Int = 0, height: Int = 0, isFavorite: Bool = false,
         latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id; self.date = date; self.modified = modified; self.video = video; self.live = live
        self.duration = duration; self.width = width; self.height = height; self.isFavorite = isFavorite
        self.latitude = latitude; self.longitude = longitude
    }
}

/// The photos On this phone shows. It reads Photos again after each burst of changes the Photos
/// adapter reports, while it is shown.
@MainActor @Observable final class LocalPhotoLibrary {
    private(set) var photos: [LocalPhoto] = []
    private(set) var albums: [DeviceAlbum] = []
    private(set) var permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var total = 0
    var albumID = ""
    private var limit = 240
    @ObservationIgnored private var changes: Task<Void, Never>?
    func begin() {
        refresh()
        guard changes == nil else { return }
        let stream = PhotoKitAdapter.shared.changes()
        changes = Task { [weak self] in
            for await _ in stream { self?.refresh() }
        }
    }
    func stop() { changes?.cancel(); changes = nil }
    func requestAccess() async { permission = await PhotoKitAdapter.shared.requestAccess().status; begin() }
    func selectAlbum() { limit = 240; refresh() }
    func loadMore() { limit += 240; refresh() }
    func refresh() {
        permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard [.authorized, .limited].contains(permission) else { photos = []; albums = []; total = 0; return }
        albums = DevicePhotos.albums()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let result: PHFetchResult<PHAsset>
        if !albumID.isEmpty, let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else { result = PHAsset.fetchAssets(with: options) }
        total = result.count
        photos = (0..<min(limit, result.count)).map { LocalPhoto(result.object(at: $0)) }
    }
}

/// Requests are scoped to the visible cell or viewer. PhotoKit can deliver more
/// than one image; the generation prevents recycled cells receiving old results.
@MainActor @Observable final class LocalPhotoMedia {
    var image: UIImage?
    var player: AVPlayer?
    var livePhoto: PHLivePhoto?
    var loading = false
    var cloud = false
    var failure: String?
    private var request = PHInvalidImageRequestID
    private var generation = UUID()
    private let manager = PHImageManager.default()

    func load(_ photo: LocalPhoto, full: Bool, network: Bool, motion: Bool = false, maximumResolution: Bool = false) {
        cancel(); image = nil; livePhoto = nil; cloud = false; failure = nil; loading = true
        let token = generation
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject else { loading = false; failure = "This item is no longer available to Ilyich."; return }
        if full && photo.video {
            let options = PHVideoRequestOptions(); options.version = .current; options.deliveryMode = .automatic; options.isNetworkAccessAllowed = network
            request = manager.requestPlayerItem(forVideo: asset, options: options) { [weak self] item, info in
                let error = (info?[PHImageErrorKey] as? Error)?.localizedDescription
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                Task { @MainActor in
                    guard let self, self.generation == token, !cancelled else { return }
                    self.loading = false; self.cloud = inCloud && item == nil
                    if let item { self.player = AVPlayer(playerItem: item) }
                    else { self.failure = error ?? "The video is unavailable on this phone." }
                }
            }
        } else if full && photo.live && motion {
            let options = PHLivePhotoRequestOptions(); options.version = .current; options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = network
            request = manager.requestLivePhoto(for: asset, targetSize: CGSize(width: 1600, height: 1600), contentMode: .aspectFit, options: options) { [weak self] live, info in
                let error = (info?[PHImageErrorKey] as? Error)?.localizedDescription
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                Task { @MainActor in
                    guard let self, self.generation == token, !cancelled else { return }
                    if let live { self.livePhoto = live }
                    if !degraded { self.loading = false; self.cloud = inCloud && live == nil; self.failure = live == nil ? (error ?? "The Live Photo is unavailable on this phone.") : nil }
                }
            }
        } else {
            let options = PHImageRequestOptions(); options.version = .current; options.deliveryMode = .opportunistic
            options.resizeMode = full && maximumResolution ? .none : .fast; options.isNetworkAccessAllowed = network
            let pixels: CGFloat = full ? 3000 : 420
            let targetSize = full && maximumResolution ? PHImageManagerMaximumSize : CGSize(width: pixels, height: pixels)
            request = manager.requestImage(for: asset, targetSize: targetSize, contentMode: full ? .aspectFit : .aspectFill, options: options) { [weak self] image, info in
                let error = (info?[PHImageErrorKey] as? Error)?.localizedDescription
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                Task { @MainActor in
                    guard let self, self.generation == token, !cancelled else { return }
                    if let image { self.image = image }
                    if !degraded { self.loading = false; self.cloud = inCloud && image == nil; self.failure = image == nil ? (error ?? "The photo is unavailable on this phone.") : nil }
                }
            }
        }
    }
    func cancel() {
        generation = UUID()
        if request != PHInvalidImageRequestID { manager.cancelImageRequest(request); request = PHInvalidImageRequestID }
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        loading = false
    }
}

struct LocalPhotoThumbnail: View {
    let photo: LocalPhoto
    @State private var media = LocalPhotoMedia()
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Color.secondary.opacity(0.1)
                if let image = media.image { Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                else { Image(systemName: media.cloud ? "icloud" : "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                if photo.video || photo.live { Image(systemName: photo.video ? "play.fill" : "livephoto").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(7) }
            }.clipped()
        }.task(id: photo) { media.load(photo, full: false, network: false) }.onDisappear { media.cancel() }.accessibilityHidden(true)
    }
}

struct LocalPhotoViewer: View {
    /// Photos to swipe through; a single photo when the caller has no neighbors to offer.
    let photos: [LocalPhoto]
    var onChanged: (() -> Void)? = nil
    @State private var selectedID: String
    @State private var showActions = false
    @State private var actionPhotos: [LocalPhoto] = []
    @State private var motion = false
    @State private var retry = 0
    @Environment(\.dismiss) private var dismiss

    init(photo: LocalPhoto, photos: [LocalPhoto] = [], onChanged: (() -> Void)? = nil) {
        self.photos = photos.contains(where: { $0.id == photo.id }) ? photos : [photo]
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
                        // Only the current photo and its neighbors hold full-size media.
                        if abs(index - selectedIndex) <= 1 {
                            LocalPhotoPage(photo: page, active: page.id == selectedID, motion: motion && page.id == selectedID,
                                           reload: retry, onDismiss: { dismiss() })
                        } else { Color.black }
                    }.tag(page.id)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(photo.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Photo actions", systemImage: "ellipsis") {
                        if let current = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject { actionPhotos = [LocalPhoto(current)]; showActions = true }
                    }
                }
                if photo.live { ToolbarItem(placement: .topBarTrailing) { Toggle("Live Photo", isOn: $motion).toggleStyle(.button) } }
            }
        }.preferredColorScheme(.dark)
        // Only the viewer turns with the phone; the rest of the app stays upright.
        .onAppear { OrientationLock.viewerAppeared() }
        .onDisappear { OrientationLock.viewerDisappeared() }
        .onChange(of: selectedID) { motion = false }
        .sheet(isPresented: $showActions) {
            NavigationStack {
                LocalPhotoActionsView(photos: actionPhotos) {
                    onChanged?()
                    if PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject == nil { dismiss() }
                    else { retry += 1 }
                }
            }
        }
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
            else if media.loading { ProgressView().tint(.white) }
            else {
                VStack(spacing: 18) {
                    Image(systemName: media.cloud ? "icloud.and.arrow.down" : "photo.badge.exclamationmark").font(.largeTitle)
                    Text(media.failure ?? "This item is unavailable.").multilineTextAlignment(.center)
                    if !network { Button("Download from iCloud") { network = true } }
                    else { Button("Retry") { retry += 1 } }
                }.padding(28).foregroundStyle(.white)
            }
        }
        .task(id: "\(photo.id)|\(network)|\(motion)|\(retry)|\(reload)|\(fullResolution)") {
            if active && photo.video { VideoAudio.prepare(foreground: true) }
            media.load(photo, full: true, network: network, motion: motion, maximumResolution: fullResolution)
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

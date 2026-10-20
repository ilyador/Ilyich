import SwiftUI
import UIKit

struct ViewerPhoto: View {
    let pipeline: MediaPipeline
    let asset: Asset
    let active: Bool
    let onTap: (Double) -> Void
    let onDismiss: () -> Void
    var matchedLocalPhoto: LocalPhoto? = nil
    /// A swipe up at normal size shows the details, as in Photos.
    var onSwipeUp: (() -> Void)? = nil
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var animationFailure: String?
    @State private var loadingFull = false
    @State private var loadingAnimation = false
    @State private var imageLoadID = UUID()
    @State private var animationLoadID = UUID()
    @State private var animatedRevision: String?
    @State private var localMedia = LocalPhotoMedia()
    @State private var usingLocalCopy = false
    @State private var reload = 0
    @State private var zoomed = false
    /// The grid's thumbnail, shown enlarged while the preview loads.
    @State private var placeholder: UIImage?
    @State private var slowPreview = false
    @AppStorage("imageLoadOriginal") private var fullResolution = false
    @Environment(\.displayScale) private var scale
    @Environment(\.scenePhase) private var scenePhase
    private var mediaKey: String { asset.id + "|" + asset.cacheRevision + "|" + String(asset.hasKnownEditState) + String(asset.isEdited) + String(asset.isDeveloped) }
    private var displayedImage: UIImage? { usingLocalCopy ? (localMedia.image ?? image) : image }

    init(pipeline: MediaPipeline, asset: Asset, active: Bool, onTap: @escaping (Double) -> Void,
         onDismiss: @escaping () -> Void, matchedLocalPhoto: LocalPhoto? = nil, onSwipeUp: (() -> Void)? = nil) {
        self.pipeline = pipeline; self.asset = asset; self.active = active
        self.onTap = onTap; self.onDismiss = onDismiss; self.matchedLocalPhoto = matchedLocalPhoto; self.onSwipeUp = onSwipeUp
        // A photo seen before opens sharp at once. Otherwise its grid thumbnail stands in, so a
        // slow preview, such as a developed RAW, never opens on an empty page.
        let preview = pipeline.latestImage(assetID: asset.id, size: .preview, revision: asset.cacheRevision)
        _image = State(initialValue: preview?.uiImage)
        _placeholder = State(initialValue: preview == nil
            ? pipeline.latestImage(assetID: asset.id, size: .thumbnail, revision: asset.cacheRevision)?.uiImage : nil)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = displayedImage { ZoomablePhoto(image: image, resetZoom: !active, onTap: onTap, onDismiss: onDismiss, onZoom: { zoomed = true }, onSwipeUp: onSwipeUp) }
                else if usingLocalCopy && localMedia.loading { ProgressView().tint(.white) }
                else if let failure {
                    ContentUnavailableView { Label("Photo couldn’t load", systemImage: "photo.badge.exclamationmark") }
                    description: { Text(failure) }
                    actions: { Button("Retry") { reload += 1 } }
                } else if let placeholder {
                    Image(uiImage: placeholder).resizable().scaledToFit()
                        .overlay {
                            // Only a preview that keeps the thumbnail up for a while earns a spinner.
                            if slowPreview { ProgressView().tint(.white).padding(12).background(.black.opacity(0.4), in: .circle) }
                        }
                        .contentShape(.rect).onTapGesture { onTap(0.5) }
                } else { ProgressView().tint(.white) }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .overlay(alignment: .bottom) {
                    if active, displayedImage != nil {
                        if let message = animationFailure ?? failure, !(usingLocalCopy && localMedia.image != nil) {
                            HStack(spacing: 12) {
                                Text(message).font(.caption).lineLimit(2)
                                Button("Retry") { reload += 1 }.font(.caption.weight(.semibold))
                            }.padding(.horizontal, 16).padding(.vertical, 10).glassEffect(in: .capsule)
                                .padding(.horizontal, 24).padding(.bottom, 110)
                        } else if loadingFull || loadingAnimation {
                            ProgressView(loadingAnimation ? "Loading animation" : "Loading full resolution")
                                .font(.caption).tint(.white).padding(.horizontal, 16).padding(.vertical, 10)
                                .glassEffect(in: .capsule).padding(.bottom, 110).allowsHitTesting(false)
                        }
                    }
                }
                .task(id: mediaKey) {
                    slowPreview = false
                    try? await Task.sleep(for: .seconds(0.8))
                    slowPreview = !Task.isCancelled
                }
                .task(id: mediaKey + String(reload) + String(zoomed) + String(fullResolution) + String(active) + String(Int(max(geometry.size.width, geometry.size.height) * scale))) {
                    await loadImage(pixels: Int(max(geometry.size.width, geometry.size.height) * scale))
                }
                .task(id: mediaKey + String(reload) + String(active) + String(fullResolution) + String(describing: scenePhase)) {
                    await playAnimation(pixels: Int(max(geometry.size.width, geometry.size.height) * scale))
                }
        }.accessibilityLabel(asset.displayName)
            .accessibilityIdentifier("viewer.photo." + asset.id)
            .onChange(of: active) { _, value in if !value { zoomed = false; localMedia.cancel() } }
            .onChange(of: localMedia.image) { _, _ in
                // A Photos edit during an asynchronous image request invalidates
                // the proven match; it must not replace the server version.
                if let photo = matchedLocalPhoto, !LocalMediaFallback.isUnchanged(photo) {
                    usingLocalCopy = false; localMedia.cancel()
                }
            }
            .onChange(of: matchedLocalPhoto) { _, _ in usingLocalCopy = false; localMedia.cancel() }
            .onDisappear { localMedia.cancel() }
    }
    private func loadImage(pixels: Int) async {
        let loadID = UUID(); imageLoadID = loadID
        failure = nil; loadingFull = false; usingLocalCopy = false; localMedia.cancel()
        defer { if imageLoadID == loadID { loadingFull = false } }
        do {
            let preview = try await pipeline.image(for: asset, size: .preview, pixelSize: pixels)
            try Task.checkCancellation()
            if !active || animatedRevision != mediaKey { image = preview.uiImage }
            // Keep the viewport preview visible while preparing detail for pinch-to-zoom.
            if active && !asset.isAnimatedImage && (fullResolution || zoomed) {
                loadingFull = true
                let full = try await pipeline.image(for: asset, size: .fullsize, pixelSize: fullResolution ? min(8192, max(asset.width ?? 4096, asset.height ?? 4096)) : min(4096, pixels * 2))
                try Task.checkCancellation(); image = full.uiImage
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, imageLoadID == loadID, animatedRevision != mediaKey else { return }
            failure = Self.message(for: error)
            if let photo = LocalMediaFallback.photo(after: error, asset: asset, matched: matchedLocalPhoto, active: active) {
                usingLocalCopy = true
                localMedia.load(photo, full: true, network: false, maximumResolution: fullResolution || zoomed)
            }
        }
    }
    /// A refused photo is not an expired session; only the session check signs out.
    private static func message(for error: Error) -> String {
        if case APIError.unauthorized = error { return "The server refused this photo. Try again." }
        return error.localizedDescription
    }
    private func playAnimation(pixels: Int) async {
        let loadID = UUID(); animationLoadID = loadID
        animationFailure = nil; loadingAnimation = false
        defer { if animationLoadID == loadID { loadingAnimation = false } }
        guard active, scenePhase == .active, asset.hasKnownEditState, asset.isAnimatedImage, !asset.isDeveloped, !asset.isEdited else { return }
        loadingAnimation = true
        do {
            let size = fullResolution ? min(4096, max(asset.width ?? 2048, asset.height ?? 2048)) : min(2048, pixels)
            let animation = try await pipeline.animation(for: asset, pixelSize: size)
            do {
                while let frame = try await animation.next() {
                    try Task.checkCancellation()
                    animatedRevision = mediaKey; loadingAnimation = false; failure = nil
                    image = frame.image.uiImage
                    try await Task.sleep(for: .seconds(frame.duration))
                }
            } catch { await animation.close(); throw error }
            await animation.close()
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, animationLoadID == loadID else { return }
            animationFailure = Self.message(for: error)
            if image == nil { failure = Self.message(for: error) }
        }
    }

}

struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    let resetZoom: Bool
    let onTap: (Double) -> Void
    let onDismiss: () -> Void
    let onZoom: () -> Void
    var recognizedText: [RecognizedText] = []
    var textSelection: Set<String> = []
    var onTextSelection: ((String) -> Void)? = nil
    var onSwipeUp: (() -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, onDismiss: onDismiss, onZoom: onZoom) }
    func makeUIView(context: Context) -> ZoomPhotoScrollView {
        let view = ZoomPhotoScrollView()
        view.delegate = context.coordinator
        view.imageView.image = image
        context.coordinator.scroll = view
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        single.require(toFail: double)
        view.addGestureRecognizer(double); view.addGestureRecognizer(single)
        let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeDown))
        swipe.direction = .down; swipe.delegate = context.coordinator; view.addGestureRecognizer(swipe)
        let up = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeUp))
        up.direction = .up; up.delegate = context.coordinator; view.addGestureRecognizer(up)
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Photo"
        view.accessibilityHint = "Pinch or double-tap to zoom. Swipe down to close."
        return view
    }
    func updateUIView(_ view: ZoomPhotoScrollView, context: Context) {
        context.coordinator.onSwipeUp = onSwipeUp
        if view.imageView.image !== image { view.imageView.image = image; view.setNeedsLayout() }
        if resetZoom && view.zoomScale != 1 { view.setZoomScale(1, animated: false) }
        view.ocrOverlay.configure(recognizedText, selection: textSelection, onSelect: onTextSelection)
        view.isAccessibilityElement = recognizedText.isEmpty
    }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var scroll: ZoomPhotoScrollView?
        let onTap: (Double) -> Void
        let onDismiss: () -> Void
        let onZoom: () -> Void
        var onSwipeUp: (() -> Void)?
        init(onTap: @escaping (Double) -> Void, onDismiss: @escaping () -> Void, onZoom: @escaping () -> Void) { self.onTap = onTap; self.onDismiss = onDismiss; self.onZoom = onZoom }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { scroll?.imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { scroll?.centerImage(); if scrollView.zoomScale > 1.05 { onZoom() } }
        @objc func singleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll else { return }
            let fraction = scroll.zoomScale > 1.01 ? 0.5 : Double((gesture.location(in: scroll).x - scroll.bounds.minX) / max(1, scroll.bounds.width))
            onTap(fraction)
        }
        @objc func swipeDown() { if (scroll?.zoomScale ?? 1) <= 1.01 { onDismiss() } }
        @objc func swipeUp() { if (scroll?.zoomScale ?? 1) <= 1.01 { onSwipeUp?() } }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { (scroll?.zoomScale ?? 1) <= 1.01 }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll else { return }
            if scroll.zoomScale > 1.01 { scroll.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled) }
            else {
                let center = gesture.location(in: scroll.imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
    }
}

@MainActor final class ZoomPhotoScrollView: UIScrollView {
    let imageView = UIImageView()
    let ocrOverlay = OCRSelectionOverlay()
    private var lastSize = CGSize.zero
    private var lastImageRatio: CGFloat = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1; maximumZoomScale = 5
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never; bouncesZoom = true
        // A zoomed photo passes under the viewer's bars without a soft edge drawn over it.
        topEdgeEffect.isHidden = true; bottomEdgeEffect.isHidden = true
        leftEdgeEffect.isHidden = true; rightEdgeEffect.isHidden = true
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.addSubview(ocrOverlay)
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        let imageRatio = image.size.width / image.size.height
        if bounds.size != lastSize || imageView.bounds == .zero || abs(imageRatio - lastImageRatio) > 0.0001 {
            lastSize = bounds.size; zoomScale = 1
            lastImageRatio = imageRatio
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            contentSize = imageView.frame.size
        }
        centerImage()
        ocrOverlay.frame = imageView.bounds
    }
    func centerImage() {
        imageView.center = CGPoint(x: max(contentSize.width, bounds.width) / 2, y: max(contentSize.height, bounds.height) / 2)
    }
}

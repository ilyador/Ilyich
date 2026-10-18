import SwiftUI
import UIKit

struct ViewerPhoto: View {
    let pipeline: MediaPipeline
    let asset: Asset
    let onTap: () -> Void
    let onDismiss: () -> Void
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var reload = 0
    @Environment(\.displayScale) private var scale
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image { ZoomablePhoto(image: image, onTap: onTap, onDismiss: onDismiss) }
                else if let failure {
                    ContentUnavailableView { Label("Photo couldn’t load", systemImage: "photo.badge.exclamationmark") }
                    description: { Text(failure) }
                    actions: { Button("Retry") { reload += 1 } }
                } else { ProgressView().tint(.white) }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .task(id: asset.id + asset.cacheRevision + String(reload)) {
                    failure = nil
                    do {
                        let pixels = Int(max(geometry.size.width, geometry.size.height) * scale)
                        let preview = try await pipeline.image(for: asset, size: .preview, pixelSize: pixels)
                        try Task.checkCancellation(); image = preview.uiImage
                        // A full-size source supports real pinch-to-zoom without decoding the entire RAW.
                        let full = try await pipeline.image(for: asset, size: .fullsize, pixelSize: min(4096, pixels * 2))
                        try Task.checkCancellation(); image = full.uiImage
                    } catch is CancellationError { } catch { if image == nil { failure = error.localizedDescription } }
                }
        }.accessibilityLabel(asset.displayName)
    }
}

struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void
    let onDismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, onDismiss: onDismiss) }
    func makeUIView(context: Context) -> ZoomPhotoScrollView {
        let view = ZoomPhotoScrollView()
        view.delegate = context.coordinator
        view.imageView.image = image
        context.coordinator.scroll = view
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        view.addGestureRecognizer(double); view.addGestureRecognizer(single)
        let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeDown))
        swipe.direction = .down; swipe.delegate = context.coordinator; view.addGestureRecognizer(swipe)
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Photo"
        view.accessibilityHint = "Pinch or double-tap to zoom. Swipe down to close."
        return view
    }
    func updateUIView(_ view: ZoomPhotoScrollView, context: Context) {
        if view.imageView.image !== image { view.imageView.image = image; view.setNeedsLayout() }
    }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var scroll: ZoomPhotoScrollView?
        let onTap: () -> Void
        let onDismiss: () -> Void
        init(onTap: @escaping () -> Void, onDismiss: @escaping () -> Void) { self.onTap = onTap; self.onDismiss = onDismiss }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { scroll?.imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { scroll?.centerImage() }
        @objc func singleTap() { onTap() }
        @objc func swipeDown() { if (scroll?.zoomScale ?? 1) <= 1.01 { onDismiss() } }
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
    private var lastSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1; maximumZoomScale = 5
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never; bouncesZoom = true
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize || imageView.bounds == .zero {
            lastSize = bounds.size; zoomScale = 1
            guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            contentSize = imageView.frame.size
        }
        centerImage()
    }
    func centerImage() {
        imageView.center = CGPoint(x: max(contentSize.width, bounds.width) / 2, y: max(contentSize.height, bounds.height) / 2)
    }
}

import AVFoundation
import UIKit

/// How the viewer comes onto the screen and leaves it, as in Photos. It zooms out of the photo's
/// grid cell. Dragged down, only the photo follows the finger: a copy of it moves while the black
/// behind it fades over the library, which stays at its full size. Let go far or fast enough, the
/// photo zooms into the cell of the photo it shows; let go early, it springs back.
///
/// UIKit's own zoom transition did this before, but on the phone its drag scales the library down
/// behind the photo, which drew the library small inside a black frame, and it can't be turned
/// off. So the viewer drives its transitions itself and UIKit's zoom is never used.
///
/// The viewer is presented over the library, which stays in the window behind it: put back only
/// as a drag began, the library made the first frames of the drag wait while it was drawn again.
/// Closing changes nothing in the viewer's SwiftUI either: the black behind the photo becomes a
/// view of its own, the viewer's photo is masked out and its controls fade with the viewer.
///
/// With Reduce Motion, or with the phone turned sideways, the viewer fades instead (its
/// controller's cross dissolve); with Reduce Motion a drag still moves the photo, which then fades.
@MainActor final class ViewerZoomTransition: NSObject, UIViewControllerTransitioningDelegate, UIGestureRecognizerDelegate {
    /// How long the zoom out of a cell and back into one takes.
    static let duration: TimeInterval = 0.42

    let state: ViewerTransitionState
    /// The grid cell showing a photo, scrolled into view first, or nil when the grid has none.
    private let sourceView: (String) -> UIView?
    private weak var viewer: UIViewController?
    /// The drag closing the viewer, from the moment it takes the photo until the photo has landed
    /// or the viewer is back as it was.
    private var drag: ViewerCloseDrag?

    init(state: ViewerTransitionState, sourceView: @escaping (String) -> UIView?) {
        self.state = state
        self.sourceView = sourceView
    }

    /// Presents and dismisses `viewer`, and lets a drag on its photo close it.
    func attach(to viewer: UIViewController) {
        self.viewer = viewer
        viewer.transitioningDelegate = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        viewer.view.addGestureRecognizer(pan)
    }

    // MARK: Transitions

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        UIAccessibility.isReduceMotionEnabled ? nil : ViewerZoomAnimator(opening: true, zoom: self)
    }

    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        if let drag { return drag }
        guard !UIAccessibility.isReduceMotionEnabled, Self.upright(dismissed.view) else { return nil }
        return ViewerZoomAnimator(opening: false, zoom: self)
    }

    func interactionControllerForDismissal(using animator: any UIViewControllerAnimatedTransitioning) -> (any UIViewControllerInteractiveTransitioning)? {
        animator as? ViewerCloseDrag
    }

    // MARK: The drag

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard let view = pan.view else { return }
        switch pan.state {
        case .began:
            guard let viewer, viewer.presentedViewController == nil else { return }
            // Turned sideways, the viewer closes plainly: the library behind it stands upright.
            guard Self.upright(view) else { viewer.dismiss(animated: true); return }
            let drag = ViewerCloseDrag(zoom: self, start: pan.location(in: view), in: view)
            self.drag = drag
            pan.setTranslation(.zero, in: view)
            viewer.dismiss(animated: true)
            if !viewer.isBeingDismissed { self.drag = nil }
        case .changed:
            drag?.follow(pan.translation(in: view))
        case .ended:
            drag?.release(velocity: pan.velocity(in: view))
        case .cancelled, .failed:
            drag?.release(velocity: .zero, cancelled: true)
        default:
            break
        }
    }

    /// The drag has let go of the viewer: it closed, or the viewer is back as it was.
    fileprivate func dragEnded(_ ended: ViewerCloseDrag) {
        if drag === ended { drag = nil }
    }

    /// A drag closes the viewer when it goes down on a photo or video at its normal size: a
    /// sideways drag pages, an upward one shows the details, a zoomed photo pans, and the bars
    /// keep their own touches.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view, let viewer, drag == nil,
              viewer.presentedViewController == nil, !viewer.isBeingPresented, !viewer.isBeingDismissed else { return false }
        var move = pan.translation(in: view)
        if move == .zero { move = pan.velocity(in: view) }
        guard move.y > 0, move.y > abs(move.x) else { return false }
        let location = pan.location(in: view)
        var hit = view.hitTest(CGPoint(x: location.x - move.x, y: location.y - move.y), with: nil)
        while let current = hit, current !== view {
            if let photo = current as? ZoomPhotoScrollView { return photo.zoomScale <= 1.01 }
            if current is UINavigationBar || current is UIToolbar { return false }
            hit = current.superview
        }
        return true
    }

    /// The pages, and a photo at its normal size, wait to see whether a drag closes the viewer
    /// before they take it; a zoomed photo pans at once, and the thumbnail strip scrubs at once.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard other is UIPanGestureRecognizer, let scroll = other.view as? UIScrollView, let view = recognizer.view,
              scroll.isDescendant(of: view) else { return false }
        if let photo = scroll as? ZoomPhotoScrollView { return photo.zoomScale <= 1.01 }
        return scroll.bounds.height >= view.bounds.height - 1
    }

    // MARK: What the transitions share

    /// The grid cell of the photo on screen, scrolled into view, or nil when the grid has none.
    fileprivate func cell() -> UIView? {
        guard let cell = sourceView(state.currentID), cell.window != nil, !cell.bounds.isEmpty else { return nil }
        return cell
    }

    /// Where the photo on screen sits in `viewer`, in its own coordinates: the photo's own frame
    /// where the viewer draws one, else the photo's shape fitted to the screen.
    fileprivate func photoFrame(in viewer: UIView) -> CGRect {
        if let photo = Self.onScreen(ZoomPhotoScrollView.self, in: viewer), photo.imageView.image != nil {
            return photo.imageView.convert(photo.imageView.bounds, to: viewer)
        }
        if let video = Self.onScreen(PlayerLayerView.self, in: viewer), !video.playerLayer.videoRect.isEmpty {
            return video.convert(video.playerLayer.videoRect, to: viewer)
        }
        let ratio = max(0.01, state.aspectRatio ?? 1)
        return AVMakeRect(aspectRatio: CGSize(width: ratio, height: 1), insideRect: viewer.bounds)
    }

    /// The viewer steps aside for a copy of its photo, placed over the photo in `container`: the
    /// photo's own image, or a snapshot of the video's frame; where the viewer draws neither, such
    /// as the grid's thumbnail while the preview loads, the screen where the photo is. The black
    /// behind the photo becomes `backdrop`, under the viewer, to fade on its own; the viewer's
    /// photo is masked out at once and its controls fade with the viewer. Nothing in the viewer's
    /// SwiftUI changes, so nothing there is laid out again. Its photos hold still meanwhile.
    fileprivate func stepAside(_ viewer: UIView, in container: UIView) -> (copy: ViewerPhotoCopy, backdrop: UIView) {
        let copy: ViewerPhotoCopy
        let photo: CGRect
        if let scroll = Self.onScreen(ZoomPhotoScrollView.self, in: viewer), let image = scroll.imageView.image {
            photo = scroll.imageView.convert(scroll.imageView.bounds, to: viewer)
            let content = UIImageView(image: image)
            content.contentMode = .scaleAspectFill
            content.bounds = CGRect(origin: .zero, size: photo.size)
            copy = ViewerPhotoCopy(content: content, media: content.bounds, frame: viewer.convert(photo, to: container))
        } else if let video = Self.onScreen(PlayerLayerView.self, in: viewer), !video.playerLayer.videoRect.isEmpty,
                  let snapshot = video.snapshotView(afterScreenUpdates: false) {
            let media = video.playerLayer.videoRect
            photo = video.convert(media, to: viewer)
            snapshot.bounds = CGRect(origin: .zero, size: video.bounds.size)
            copy = ViewerPhotoCopy(content: snapshot, media: media, frame: video.convert(media, to: container))
        } else {
            photo = photoFrame(in: viewer)
            let snapshot = viewer.resizableSnapshotView(from: photo, afterScreenUpdates: false, withCapInsets: .zero) ?? UIView()
            snapshot.bounds = CGRect(origin: .zero, size: photo.size)
            copy = ViewerPhotoCopy(content: snapshot, media: snapshot.bounds, frame: viewer.convert(photo, to: container))
        }
        let backdrop = UIView(frame: container.bounds)
        backdrop.backgroundColor = .black
        backdrop.isUserInteractionEnabled = false
        container.insertSubview(backdrop, belowSubview: viewer)
        container.addSubview(copy)
        viewer.backgroundColor = .clear
        let mask = CAShapeLayer()
        mask.frame = viewer.bounds
        let path = UIBezierPath(rect: viewer.bounds)
        path.append(UIBezierPath(rect: photo.insetBy(dx: -1, dy: -1)))
        mask.path = path.cgPath
        mask.fillRule = .evenOdd
        viewer.layer.mask = mask
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            viewer.alpha = 0
        }
        state.onClosing?(true)
        return (copy, backdrop)
    }

    /// A drag let go early: the viewer's controls come back as the photo does. Its photo stays
    /// masked out until the copy is home (`settle`).
    fileprivate func comeBack(_ viewer: UIView) {
        state.onClosing?(false)
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            viewer.alpha = 1
        }
    }

    /// The copy is home: the viewer's own photo and black take its place and the backdrop's, in
    /// one frame, where they look the same.
    fileprivate func settle(_ viewer: UIView, copy: UIView, backdrop: UIView) {
        viewer.layer.mask = nil
        viewer.backgroundColor = .black
        copy.removeFromSuperview()
        backdrop.removeFromSuperview()
    }

    /// A grid cell hides while the photo goes back into it: its place shows empty until the photo lands.
    fileprivate static func setHidden(_ hidden: Bool, _ cell: UIView?) {
        if let cell = cell as? UICollectionViewCell { cell.contentView.isHidden = hidden } else { cell?.isHidden = hidden }
    }

    /// The viewer stands upright: the library behind it is drawn the same way.
    static func upright(_ view: UIView?) -> Bool {
        guard let view else { return true }
        return view.bounds.width <= view.bounds.height
    }

    /// The first view of `type` under `root` that covers the middle of the screen: the page on
    /// screen's, not a page beside it.
    static func onScreen<Found: UIView>(_ type: Found.Type, in root: UIView) -> Found? {
        let middle = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
        var views = [root]
        while let view = views.popLast() {
            if let match = view as? Found, !match.isHidden, match.convert(match.bounds, to: root).contains(middle) { return match }
            views.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The spring's start, as UIKit takes it: the finger's speed over the distance left to go.
    fileprivate static func springVelocity(_ speed: CGFloat, over distance: CGFloat) -> CGVector {
        guard abs(distance) > 1 else { return .zero }
        let relative = min(6, max(-2, speed / distance))
        return CGVector(dx: relative, dy: relative)
    }
}

/// The zoom out of the photo's cell as the viewer opens, and back into the cell of the photo on
/// screen when it closes other than by a drag, such as by its back button.
@MainActor private final class ViewerZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let opening: Bool
    private let zoom: ViewerZoomTransition
    private var context: (any UIViewControllerContextTransitioning)?

    init(opening: Bool, zoom: ViewerZoomTransition) {
        self.opening = opening
        self.zoom = zoom
    }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval { ViewerZoomTransition.duration }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        self.context = context
        if opening { open(context) } else { close(context) }
    }

    private func complete() {
        guard let context else { return }
        self.context = nil
        context.completeTransition(!context.transitionWasCancelled)
    }

    /// The viewer grows out of the cell, the photo lined up with it, while the library behind
    /// darkens. Without a cell it fades in.
    private func open(_ context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let controller = context.viewController(forKey: .to), let viewer = context.view(forKey: .to) else { return complete() }
        let final = context.finalFrame(for: controller)
        viewer.frame = final
        container.addSubview(viewer)
        // Drawn before it moves, so the zoom starts on the photo rather than an empty page.
        viewer.layoutIfNeeded()
        let animator = UIViewPropertyAnimator(duration: ViewerZoomTransition.duration,
                                              timingParameters: UISpringTimingParameters(duration: ViewerZoomTransition.duration, bounce: 0))
        let photo = zoom.photoFrame(in: viewer)
        if let cell = zoom.cell(), !photo.isEmpty {
            let cellFrame = cell.convert(cell.bounds, to: container)
            let scale = max(cellFrame.width / photo.width, cellFrame.height / photo.height)
            let dimming = UIView(frame: container.bounds)
            dimming.backgroundColor = .black
            dimming.alpha = 0
            container.insertSubview(dimming, belowSubview: viewer)
            // Only the part of the viewer over the cell shows at first: the photo, filling the cell.
            let mask = UIView(frame: CGRect(x: photo.midX - cellFrame.width / scale / 2, y: photo.midY - cellFrame.height / scale / 2,
                                            width: cellFrame.width / scale, height: cellFrame.height / scale))
            mask.backgroundColor = .black
            viewer.mask = mask
            viewer.transform = CGAffineTransform(scaleX: scale, y: scale)
            viewer.center = CGPoint(x: cellFrame.midX + (viewer.bounds.midX - photo.midX) * scale,
                                    y: cellFrame.midY + (viewer.bounds.midY - photo.midY) * scale)
            animator.addAnimations {
                viewer.transform = .identity
                viewer.center = CGPoint(x: final.midX, y: final.midY)
                mask.frame = viewer.bounds
                dimming.alpha = 1
            }
            animator.addCompletion { [self] _ in
                viewer.mask = nil
                dimming.removeFromSuperview()
                complete()
            }
        } else {
            viewer.alpha = 0
            animator.addAnimations { viewer.alpha = 1 }
            animator.addCompletion { [self] _ in complete() }
        }
        animator.startAnimation()
    }

    /// Only the photo goes back into its cell; the black behind it fades in place over the library
    /// and the controls fade away. Without a cell the photo fades where it is.
    private func close(_ context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let viewer = context.view(forKey: .from) else { return complete() }
        let (copy, backdrop) = zoom.stepAside(viewer, in: container)
        let cell = zoom.cell()
        let target = cell.map { $0.convert($0.bounds, to: container) }
        ViewerZoomTransition.setHidden(true, cell)
        let animator = UIViewPropertyAnimator(duration: ViewerZoomTransition.duration,
                                              timingParameters: UISpringTimingParameters(duration: ViewerZoomTransition.duration, bounce: 0))
        animator.addAnimations {
            backdrop.alpha = 0
            if let target { copy.land(on: target) } else { copy.alpha = 0 }
        }
        animator.addCompletion { [self] _ in
            ViewerZoomTransition.setHidden(false, cell)
            copy.removeFromSuperview()
            backdrop.removeFromSuperview()
            complete()
        }
        animator.startAnimation()
    }
}

/// A drag closing the viewer, which UIKit runs as its interactive dismissal. Only a copy of the
/// photo moves with the finger, its center and scale alone changing as the finger does.
@MainActor final class ViewerCloseDrag: NSObject, UIViewControllerAnimatedTransitioning, UIViewControllerInteractiveTransitioning {
    private let zoom: ViewerZoomTransition
    /// Where the finger took the photo, in the viewer's coordinates.
    private let start: CGPoint
    private weak var startView: UIView?
    private var translation = CGPoint.zero
    /// A release that came before UIKit started the dismissal, handled once it has.
    private var pendingRelease: (velocity: CGPoint, cancelled: Bool)?
    private var context: (any UIViewControllerContextTransitioning)?
    private var viewer: UIView?
    private var copy: ViewerPhotoCopy?
    private var backdrop: UIView?
    /// The photo's frame at rest, where the copy springs back to.
    private var rest = CGRect.zero
    private var origin = CGPoint.zero
    private var cell: UIView?
    private var released = false
    /// UIKit runs the drag interactively, as it should; false should it ever run it as an animation.
    private var interactive = true

    init(zoom: ViewerZoomTransition, start: CGPoint, in view: UIView) {
        self.zoom = zoom
        self.start = start
        self.startView = view
    }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval { ViewerZoomTransition.duration }

    /// UIKit runs the drag interactively; should it ever run it as an animation, the photo goes
    /// back to its cell.
    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        interactive = false
        startInteractiveTransition(context)
        release(velocity: CGPoint(x: 0, y: 1_000))
    }

    func startInteractiveTransition(_ context: any UIViewControllerContextTransitioning) {
        self.context = context
        let container = context.containerView
        guard let viewer = context.view(forKey: .from) else {
            if interactive { context.cancelInteractiveTransition() }
            context.completeTransition(false)
            zoom.dragEnded(self)
            return
        }
        self.viewer = viewer
        let (copy, backdrop) = zoom.stepAside(viewer, in: container)
        self.copy = copy
        self.backdrop = backdrop
        rest = copy.frame
        origin = (startView ?? viewer).convert(start, to: container)
        follow(translation)
        if let pendingRelease { release(velocity: pendingRelease.velocity, cancelled: pendingRelease.cancelled) }
        // The grid shows the photo's place, empty, while the photo is away from it. Looking the cell
        // up waits for the drag's first frame, which the black still hides the grid in.
        Task { @MainActor [weak self] in
            guard let self, !self.released else { return }
            self.cell = self.zoom.cell()
            ViewerZoomTransition.setHidden(true, self.cell)
        }
    }

    /// The finger moved: the photo follows it, the point it took staying under the finger, and
    /// shrinks a little as it goes down, while the black behind it fades.
    func follow(_ translation: CGPoint) {
        self.translation = translation
        guard let context, let copy, let backdrop, !released else { return }
        let height = max(1, context.containerView.bounds.height)
        let down = max(0, translation.y)
        let scale = 1 - 0.35 * min(1, down / height)
        let finger = CGPoint(x: origin.x + translation.x, y: origin.y + translation.y)
        copy.transform = CGAffineTransform(scaleX: scale, y: scale)
        copy.center = CGPoint(x: finger.x + (rest.midX - origin.x) * scale, y: finger.y + (rest.midY - origin.y) * scale)
        let progress = min(1, down / (height * 0.4))
        backdrop.alpha = 1 - progress
        context.updateInteractiveTransition(progress)
    }

    /// The finger let go: far or fast enough down, the viewer closes; otherwise the photo springs back.
    func release(velocity: CGPoint, cancelled: Bool = false) {
        guard let context else { pendingRelease = (velocity, cancelled); return }
        guard !released else { return }
        released = true
        let closes = !cancelled && (velocity.y > 500 || (translation.y > 100 && velocity.y > -100))
        if closes {
            if interactive { context.finishInteractiveTransition() }
            land(velocity)
        } else {
            if interactive { context.cancelInteractiveTransition() }
            springBack(velocity)
        }
    }

    /// The photo zooms into the cell of the photo it shows, carrying on from the finger's speed, as
    /// the black finishes fading. Without a cell, or with Reduce Motion, it fades where it is.
    private func land(_ velocity: CGPoint) {
        guard let context, let copy, let backdrop else { return }
        let container = context.containerView
        // The grid may have moved under the drag: the cell is looked up again.
        let current = zoom.cell()
        if current !== cell {
            ViewerZoomTransition.setHidden(false, cell)
            ViewerZoomTransition.setHidden(true, current)
            cell = current
        }
        let target = UIAccessibility.isReduceMotionEnabled ? nil : current.map { $0.convert($0.bounds, to: container) }
        if target == nil {
            // The photo fades where it is: its cell needn't wait for it.
            ViewerZoomTransition.setHidden(false, cell)
            cell = nil
        }
        let timing = UISpringTimingParameters(duration: ViewerZoomTransition.duration, bounce: 0,
                                              initialVelocity: ViewerZoomTransition.springVelocity(velocity.y, over: (target?.midY ?? copy.center.y) - copy.center.y))
        let animator = UIViewPropertyAnimator(duration: ViewerZoomTransition.duration, timingParameters: timing)
        animator.addAnimations {
            backdrop.alpha = 0
            if let target { copy.land(on: target) } else { copy.alpha = 0 }
        }
        animator.addCompletion { [self] _ in
            ViewerZoomTransition.setHidden(false, cell)
            copy.removeFromSuperview()
            backdrop.removeFromSuperview()
            context.completeTransition(true)
            zoom.dragEnded(self)
        }
        animator.startAnimation()
    }

    /// The photo springs back into place as the black and the controls come back. The spring
    /// ends at a set time, so the viewer takes touches again as soon as the photo is home.
    private func springBack(_ velocity: CGPoint) {
        guard let context, let copy, let backdrop, let viewer else { return }
        zoom.comeBack(viewer)
        let timing = UISpringTimingParameters(dampingRatio: UIAccessibility.isReduceMotionEnabled ? 1 : 0.82,
                                              initialVelocity: ViewerZoomTransition.springVelocity(velocity.y, over: rest.midY - copy.center.y))
        let animator = UIViewPropertyAnimator(duration: 0.38, timingParameters: timing)
        let rest = rest
        animator.addAnimations {
            backdrop.alpha = 1
            copy.transform = .identity
            copy.center = CGPoint(x: rest.midX, y: rest.midY)
        }
        animator.addCompletion { [self] _ in
            zoom.settle(viewer, copy: copy, backdrop: backdrop)
            ViewerZoomTransition.setHidden(false, cell)
            context.completeTransition(false)
            zoom.dragEnded(self)
        }
        animator.startAnimation()
    }
}

/// A copy of the photo on screen that moves in its place while the viewer closes, cut to the shape
/// it moves into: a grid cell shows the middle of the photo, as the cell itself does.
@MainActor final class ViewerPhotoCopy: UIView {
    private let content: UIView
    /// Where the photo or video lies in `content`, at the content's own size.
    private let media: CGRect

    init(content: UIView, media: CGRect, frame: CGRect) {
        self.content = content
        self.media = media
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        addSubview(content)
        placeContent()
    }

    required init?(coder: NSCoder) { fatalError("ViewerPhotoCopy is created programmatically") }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeContent()
    }

    /// The photo fills the copy, centered, whatever the copy's shape.
    private func placeContent() {
        guard media.width > 0, media.height > 0 else { return }
        let scale = max(bounds.width / media.width, bounds.height / media.height)
        content.transform = CGAffineTransform(scaleX: scale, y: scale)
        content.center = CGPoint(x: bounds.midX + (content.bounds.midX - media.midX) * scale,
                                 y: bounds.midY + (content.bounds.midY - media.midY) * scale)
    }

    /// Takes `frame`'s place and shape. Called inside an animation, the photo zooms into it.
    func land(on frame: CGRect) {
        transform = .identity
        bounds = CGRect(origin: .zero, size: frame.size)
        center = CGPoint(x: frame.midX, y: frame.midY)
        layoutIfNeeded()
    }
}

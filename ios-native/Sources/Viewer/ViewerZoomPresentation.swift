import AVFoundation
import SwiftUI
import UIKit

/// What the zoom transition needs from the open viewer: the photo on screen and its shape, and
/// whether the viewer is closing.
@MainActor @Observable final class ViewerTransitionState {
    var currentID: String
    /// Width over height of the photo on screen, so the zoom lines the cell up with the photo
    /// rather than with the whole screen.
    var aspectRatio: CGFloat?
    /// The viewer is closing, by a drag or a button: its controls step aside so only the photo
    /// goes back to its cell, as in Photos. A drag let go early brings them back.
    var dismissing = false
    init(currentID: String) { self.currentID = currentID }
}

/// Presents the viewer as Photos does: it zooms out of the photo's grid cell, follows the finger
/// when dragged down, and zooms back into the cell of whichever photo it shows when it closes.
/// Without a cell to go back to, it closes plainly.
struct ViewerZoomPresenter: UIViewControllerRepresentable {
    @Binding var item: Asset?
    /// The grid cell showing a photo, scrolled into view first, or nil when the grid has none.
    let sourceView: (String) -> UIView?
    /// What the account may do. The viewer is outside the app's environment, so it is handed on.
    let authorization: AuthorizationSnapshot?
    let onDismiss: () -> Void
    let content: (Asset, ViewerTransitionState, @escaping () -> Void) -> AnyView
    /// Outside the app's scene the viewer would always read as in the background, which keeps
    /// videos and animations from playing, so it is handed the app's phase too.
    @Environment(\.scenePhase) private var scenePhase

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if let asset = item {
            if coordinator.host == nil { coordinator.present(asset, from: anchor) }
            else { coordinator.refresh(asset) }
        } else {
            coordinator.close()
        }
    }

    @MainActor final class Coordinator {
        var parent: ViewerZoomPresenter?
        private(set) var host: ViewerHostingController?
        private var state: ViewerTransitionState?
        private var presentedID: String?

        func present(_ asset: Asset, from anchor: UIViewController) {
            let state = ViewerTransitionState(currentID: asset.id)
            let host = ViewerHostingController(rootView: AnyView(EmptyView()))
            self.state = state; self.host = host; presentedID = asset.id
            host.rootView = root(asset)
            host.modalPresentationStyle = .fullScreen
            // The black behind the photo is the controller's, not the SwiftUI view's, so it can
            // fade with the finger while a drag closes the viewer.
            host.view.backgroundColor = .black
            host.onDismissing = { [weak state] closing in
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.15)) { state?.dismissing = closing }
            }
            // The viewer is always dark. Its own preference reaches this host only after SwiftUI's
            // first pass, which let the zoom start in the system's style and flicker.
            host.overrideUserInterfaceStyle = .dark
            let options = UIViewController.Transition.ZoomOptions()
            options.interactiveDismissShouldBegin = { [weak host] context in
                guard let view = host?.view else { return false }
                return Self.dragMayClose(context, in: view)
            }
            options.alignmentRectProvider = { [weak state] context in
                guard let ratio = state?.aspectRatio, ratio > 0 else { return nil }
                return AVMakeRect(aspectRatio: CGSize(width: ratio, height: 1), insideRect: context.zoomedViewController.view.bounds)
            }
            host.preferredTransition = .zoom(options: options) { [weak self, weak state] _ in
                guard let state else { return nil }
                return self?.parent?.sourceView(state.currentID)
            }
            host.onDismissed = { [weak self, weak host] in
                guard let self, let host else { return }
                self.finish(host)
            }
            // Not in the middle of a view update: present once SwiftUI has finished this one.
            Task { @MainActor [weak self, weak anchor, weak host] in
                guard let self, let anchor, let host else { return }
                await self.show(host, from: anchor)
            }
            watchItem()
        }

        /// While the viewer is up, the screen under it is off the screen, and SwiftUI may not
        /// update it for a change made from outside, such as a link. So the item is watched
        /// here too: once it empties, the viewer closes.
        private func watchItem() {
            withObservationTracking { _ = parent?.item } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, self.host != nil else { return }
                    if self.parent?.item == nil { self.close() } else { self.watchItem() }
                }
            }
        }

        /// Presents once nothing else is presented over the library, such as an alert still on its
        /// way out; UIKit would refuse it until then. If that never happens within two seconds,
        /// the viewer counts as closed, so nothing waits on a viewer that never appeared.
        private func show(_ host: ViewerHostingController, from anchor: UIViewController) async {
            for _ in 0..<20 {
                guard self.host === host, host.presentingViewController == nil else { return }
                if let window = anchor.view.window, window.rootViewController?.presentedViewController == nil {
                    anchor.present(host, animated: true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            finish(host)
        }

        /// The viewer has gone, by its own close, a drag, or never having been shown: whoever
        /// presented it hears so once.
        private func finish(_ host: ViewerHostingController) {
            guard self.host === host else { return }
            self.host = nil; state = nil; presentedID = nil
            if parent?.item != nil { parent?.item = nil }
            parent?.onDismiss()
        }

        /// Keeps the viewer's inputs current, as a cover's content would be; another photo opened
        /// over the viewer replaces it.
        func refresh(_ asset: Asset) {
            guard let host, let state else { return }
            if asset.id != presentedID { presentedID = asset.id; state.currentID = asset.id }
            host.rootView = root(asset)
        }

        func close() {
            guard let host else { return }
            if host.presentingViewController == nil {
                // Closed before it was shown: nothing to dismiss, but it has gone all the same,
                // which is said outside the view update that closed it.
                self.host = nil; state = nil; presentedID = nil
                Task { @MainActor [weak self] in self?.parent?.onDismiss() }
                return
            }
            guard !host.isBeingDismissed else { return }
            if host.presentedViewController != nil {
                // A sheet or cover the viewer opened, such as its details, closes with it.
                host.presentingViewController?.dismiss(animated: true)
            } else {
                host.dismiss(animated: true)
            }
        }

        private func root(_ asset: Asset) -> AnyView {
            guard let parent, let state else { return AnyView(EmptyView()) }
            return AnyView(ViewerRoot(content: parent.content(asset, state, { [weak self] in self?.close() }), authorization: parent.authorization,
                                      scenePhase: parent.scenePhase)
                .id(asset.id))
        }

        /// A drag closes the viewer when it goes down on a photo at normal size: a sideways drag
        /// pages, an upward one shows the details, and a zoomed photo pans.
        private static func dragMayClose(_ context: UIViewController.Transition.ZoomOptions.InteractionContext, in view: UIView) -> Bool {
            guard context.velocity.dy > 0, context.velocity.dy > abs(context.velocity.dx) else { return false }
            var hit = view.hitTest(context.location, with: nil)
            while let current = hit {
                if let photo = current as? ZoomPhotoScrollView { return photo.zoomScale <= 1.01 }
                hit = current.superview
            }
            return true
        }
    }
}

/// The viewer's controller. It reports its dismissal once it has happened: a drag let go of
/// halfway leaves the viewer open, so a dismissal counts only when its transition completes.
final class ViewerHostingController: UIHostingController<AnyView> {
    var onDismissed: (() -> Void)?
    /// Told when the viewer starts closing, and when a drag let go early leaves it open.
    var onDismissing: ((Bool) -> Void)?
    private var dismissingWithoutTransition = false

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else { return }
        onDismissing?(true)
        if let coordinator = transitionCoordinator {
            // The black fades as the photo goes back to its cell; on a drag it follows the finger.
            coordinator.animate(alongsideTransition: { [weak self] _ in self?.view.backgroundColor = .clear }) { [weak self] context in
                guard let self else { return }
                if context.isCancelled {
                    self.view.backgroundColor = .black
                    self.onDismissing?(false)
                } else {
                    self.onDismissed?()
                }
            }
        } else {
            dismissingWithoutTransition = true
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if dismissingWithoutTransition { dismissingWithoutTransition = false; onDismissed?() }
    }
}

/// A presented controller does not inherit the app's environment, so the accent, what the
/// account may do and the scene's phase are applied again.
private struct ViewerRoot: View {
    let content: AnyView
    let authorization: AuthorizationSnapshot?
    let scenePhase: ScenePhase
    @AppStorage(AppearanceAccent.storageKey) private var accentName = AppearanceAccent.design.rawValue
    var body: some View {
        content.tint((AppearanceAccent(rawValue: accentName) ?? .design).tint).environment(\.authorization, authorization)
            .environment(\.scenePhase, scenePhase)
    }
}

extension GridScrollController {
    /// The grid cell showing a photo of `store`'s feed, for the viewer's zoom. A cell scrolled out
    /// of sight is brought into view first, so closing lands on it; without a cell the viewer
    /// closes plainly.
    func zoomSourceView(for assetID: String, in store: LibraryStore) -> UIView? {
        guard let collection,
              let index = store.restoredIndex(for: GridPosition(section: "", item: 0, offset: 0, assetID: assetID)),
              index.section < collection.numberOfSections, index.item < collection.numberOfItems(inSection: index.section) else { return nil }
        let path = IndexPath(item: index.item, section: index.section)
        let visible = collection.bounds.inset(by: collection.adjustedContentInset)
        if let cell = collection.cellForItem(at: path), visible.contains(cell.frame) { return cell }
        collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
        collection.layoutIfNeeded()
        return collection.cellForItem(at: path)
    }
}

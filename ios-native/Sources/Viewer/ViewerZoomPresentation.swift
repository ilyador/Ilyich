import AVFoundation
import SwiftUI
import UIKit

/// What the zoom transition needs from the open viewer: the photo on screen and its shape.
@MainActor final class ViewerTransitionState {
    var currentID: String
    /// Width over height of the photo on screen, so the zoom lines the cell up with the photo
    /// rather than with the whole screen.
    var aspectRatio: CGFloat?
    init(currentID: String) { self.currentID = currentID }
}

/// Presents the viewer as Photos does: it zooms out of the photo's grid cell, follows the finger
/// when dragged down, and zooms back into the cell of whichever photo it shows when it closes.
/// Without a cell to go back to, it closes plainly.
struct ViewerZoomPresenter: UIViewControllerRepresentable {
    @Binding var item: Asset?
    /// The grid cell showing a photo, scrolled into view first, or nil when the grid has none.
    let sourceView: (String) -> UIView?
    let onDismiss: () -> Void
    let content: (Asset, ViewerTransitionState, @escaping () -> Void) -> AnyView

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
                guard let self, let host, self.host === host else { return }
                self.host = nil; self.state = nil; self.presentedID = nil
                if self.parent?.item != nil { self.parent?.item = nil }
                self.parent?.onDismiss()
            }
            // Not in the middle of a view update: present once SwiftUI has finished this one.
            Task { @MainActor [weak self, weak anchor, weak host] in
                guard let self, let anchor, let host, self.host === host, host.presentingViewController == nil else { return }
                anchor.present(host, animated: true)
            }
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
            // Closed before it was shown: nothing to dismiss.
            if host.presentingViewController == nil { self.host = nil; state = nil; presentedID = nil; return }
            guard !host.isBeingDismissed else { return }
            host.dismiss(animated: true)
        }

        private func root(_ asset: Asset) -> AnyView {
            guard let parent, let state else { return AnyView(EmptyView()) }
            return AnyView(ViewerRoot(content: parent.content(asset, state, { [weak self] in self?.close() })).id(asset.id))
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
    private var dismissingWithoutTransition = false

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else { return }
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                if !context.isCancelled { self?.onDismissed?() }
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

/// A presented controller does not inherit the app's environment, so the accent is applied again.
private struct ViewerRoot: View {
    let content: AnyView
    @AppStorage(AppearanceAccent.storageKey) private var accentName = AppearanceAccent.design.rawValue
    var body: some View { content.tint((AppearanceAccent(rawValue: accentName) ?? .design).tint) }
}

extension LibraryStore {
    /// The grid cell showing a photo, for the viewer's zoom. A cell scrolled out of sight is
    /// brought into view first, so closing lands on it; without a cell the viewer closes plainly.
    func zoomSourceView(for assetID: String) -> UIView? {
        guard let collection = scroller.collection,
              let index = restoredIndex(for: GridPosition(section: "", item: 0, offset: 0, assetID: assetID)),
              index.section < collection.numberOfSections, index.item < collection.numberOfItems(inSection: index.section) else { return nil }
        let path = IndexPath(item: index.item, section: index.section)
        let visible = collection.bounds.inset(by: collection.adjustedContentInset)
        if let cell = collection.cellForItem(at: path), visible.contains(cell.frame) { return cell }
        collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
        collection.layoutIfNeeded()
        return collection.cellForItem(at: path)
    }
}

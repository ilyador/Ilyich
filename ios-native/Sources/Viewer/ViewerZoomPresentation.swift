import SwiftUI
import UIKit

/// What the zoom transition needs from the open viewer: the photo on screen and its shape, and
/// whom to tell when the viewer starts closing.
@MainActor @Observable final class ViewerTransitionState {
    var currentID: String
    /// Width over height of the photo on screen, so the zoom lines the cell up with the photo
    /// rather than with the whole screen.
    var aspectRatio: CGFloat?
    /// Told when the viewer starts closing, by a drag or a button, and when a drag let go early
    /// leaves it open: the viewer holds its photos still meanwhile. Not observed, so telling it
    /// changes nothing in SwiftUI while the finger moves.
    @ObservationIgnored var onClosing: ((Bool) -> Void)?
    init(currentID: String) { self.currentID = currentID }
}

/// Presents the viewer as Photos does (ViewerZoomTransition): it zooms out of the photo's grid
/// cell, only the photo follows the finger when dragged down, and the photo zooms back into the
/// cell of whichever photo it shows when the viewer closes. Without a cell to go back to, it
/// closes plainly.
struct ViewerZoomPresenter: UIViewControllerRepresentable {
    /// The viewer to show: the photo it opens on and where its photos come from.
    @Binding var item: ViewerRoute?
    /// The grid cell showing a photo, scrolled into view first, or nil when the grid has none.
    let sourceView: (String) -> UIView?
    /// What the account may do. The viewer is outside the app's environment, so it is handed on.
    let authorization: AuthorizationSnapshot?
    /// The account's mutations, handed on for the same reason.
    var mutations: LibraryMutationService? = nil
    /// The account's bus, its collections and its own settings, handed on for the same reason.
    var bus: LibraryBus? = nil
    var collections: CollectionsService? = nil
    var settings: AccountSettingsService? = nil
    let onDismiss: () -> Void
    let content: (ViewerRoute, ViewerTransitionState, @escaping () -> Void) -> AnyView
    /// Outside the app's scene the viewer would always read as in the background, which keeps
    /// videos and animations from playing, so it is handed the app's phase too.
    @Environment(\.scenePhase) private var scenePhase

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if let route = item {
            if coordinator.host == nil { coordinator.present(route, from: anchor) }
            else { coordinator.refresh(route) }
        } else {
            coordinator.close()
        }
    }

    @MainActor final class Coordinator {
        var parent: ViewerZoomPresenter?
        private(set) var host: ViewerHostingController?
        private var state: ViewerTransitionState?
        private var presentedID: String?

        func present(_ route: ViewerRoute, from anchor: UIViewController) {
            let state = ViewerTransitionState(currentID: route.asset.id)
            let host = ViewerHostingController(rootView: AnyView(EmptyView()))
            self.state = state; self.host = host; presentedID = route.asset.id
            state.aspectRatio = CGFloat(route.asset.aspectRatio)
            host.rootView = root(route)
            // Over the library, which stays in the window: as a drag begins it is already there,
            // at its full size, behind the photo (ViewerZoomTransition). The viewer still decides
            // the status bar, as a full-screen one does.
            host.modalPresentationStyle = .overFullScreen
            host.modalPresentationCapturesStatusBarAppearance = true
            // A plain close, with Reduce Motion or the phone turned sideways, fades.
            host.modalTransitionStyle = .crossDissolve
            // The black behind the photo is the controller's, not the SwiftUI view's: closing hands
            // it to a view of its own, which fades with the finger.
            host.view.backgroundColor = .black
            // A link that closed the viewer while a drag held it closes it once the drag lets go.
            host.onDismissCancelled = { [weak self] in
                Task { @MainActor [weak self] in if let self, self.parent?.item == nil { self.close() } }
            }
            // The viewer is always dark. Its own preference reaches this host only after SwiftUI's
            // first pass, which let the zoom start in the system's style and flicker.
            host.overrideUserInterfaceStyle = .dark
            let zoom = ViewerZoomTransition(state: state) { [weak self] id in self?.parent?.sourceView(id) }
            zoom.attach(to: host)
            host.zoom = zoom
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
        /// over the viewer replaces it. A viewer on its way off the screen, under a drag or going
        /// back to its cell, is left as it is: drawing it again then costs the frames the photo
        /// needs, as the library behind it updates.
        func refresh(_ route: ViewerRoute) {
            guard let host, let state, !host.isBeingDismissed else { return }
            if route.asset.id != presentedID { presentedID = route.asset.id; state.currentID = route.asset.id }
            host.rootView = root(route)
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

        private func root(_ route: ViewerRoute) -> AnyView {
            guard let parent, let state else { return AnyView(EmptyView()) }
            return AnyView(ViewerRoot(content: parent.content(route, state, { [weak self] in self?.close() }), authorization: parent.authorization,
                                      mutations: parent.mutations, bus: parent.bus, collections: parent.collections,
                                      settings: parent.settings, scenePhase: parent.scenePhase)
                .id(route.asset.id))
        }
    }
}

/// The viewer's controller. It reports its dismissal once it has happened: a drag let go of
/// halfway leaves the viewer open, so a dismissal counts only when its transition completes.
final class ViewerHostingController: UIHostingController<AnyView> {
    var onDismissed: (() -> Void)?
    /// Told when a drag let go early leaves the viewer open.
    var onDismissCancelled: (() -> Void)?
    /// The viewer's zoom and drag to close, which UIKit holds only weakly.
    var zoom: ViewerZoomTransition?
    private var dismissingWithoutTransition = false
    /// The screen under the viewer while VoiceOver keeps to the viewer.
    private weak var hiddenLibrary: UIView?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The library stays in the window under the viewer; VoiceOver keeps to the viewer, as it
        // did when the library left the window.
        setLibraryAccessible(false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else { return }
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                if context.isCancelled { self?.onDismissCancelled?(); return }
                self?.setLibraryAccessible(true)
                self?.onDismissed?()
            }
        } else {
            dismissingWithoutTransition = true
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { setLibraryAccessible(true) }
        if dismissingWithoutTransition { dismissingWithoutTransition = false; onDismissed?() }
    }

    /// The screen the viewer is presented over, for VoiceOver and UI tests: hidden while the
    /// viewer is up, back once it has closed.
    private func setLibraryAccessible(_ accessible: Bool) {
        if accessible {
            hiddenLibrary?.accessibilityElementsHidden = false
            hiddenLibrary = nil
        } else if let library = view.window?.rootViewController?.view, !view.isDescendant(of: library) {
            library.accessibilityElementsHidden = true
            hiddenLibrary = library
        }
    }
}

/// A presented controller does not inherit the app's environment, so the accent, what the
/// account may do, its mutations, bus, collections and settings and the scene's phase are applied
/// again.
private struct ViewerRoot: View {
    let content: AnyView
    let authorization: AuthorizationSnapshot?
    let mutations: LibraryMutationService?
    let bus: LibraryBus?
    let collections: CollectionsService?
    let settings: AccountSettingsService?
    let scenePhase: ScenePhase
    @AppStorage(AppearanceAccent.storageKey) private var accentName = AppearanceAccent.design.rawValue
    var body: some View {
        content.tint((AppearanceAccent(rawValue: accentName) ?? .design).tint).environment(\.authorization, authorization)
            .environment(\.mutations, mutations).environment(\.libraryBus, bus).environment(\.collectionsService, collections)
            .environment(\.accountSettings, settings).environment(\.scenePhase, scenePhase)
    }
}

extension GridScrollController {
    /// The grid cell showing a photo of `store`'s feed, for the viewer's zoom. A cell scrolled out
    /// of sight is brought into view first, so closing lands on it; without a cell the viewer
    /// closes plainly.
    func zoomSourceView(for assetID: String, in store: LibraryFeedStore) -> UIView? {
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

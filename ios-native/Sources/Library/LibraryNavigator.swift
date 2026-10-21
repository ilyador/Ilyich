import SwiftUI

/// Everything presented over the library, and the one place it changes.
///
/// Screens come up in layers: the library presents the first, and the screen in each layer can
/// present the next. Layers close from the top down, one at a time; each host reports its close
/// once, and nothing new appears at a level until the layer there has gone. A screen or a link
/// that wants the library itself (a photo, the timeline, a filter, the Earth) sends an intent,
/// which closes every layer and then runs once. Shared files waits for a quiet moment instead.
@MainActor @Observable final class LibraryNavigator {
    struct Layer: Identifiable, Hashable {
        let id = UUID()
        let route: ModalRoute
        /// Asked to close; its host reports when it has.
        fileprivate(set) var isClosing = false
    }

    /// Bottom first: the library presents layers[0], and the screen in each layer the next one.
    private(set) var layers: [Layer] = []
    /// The one alert or question over the library.
    private(set) var alert: LibraryAlert?
    /// What covers the grid besides the presented screens.
    private(set) var overlay = LibraryOverlay()
    /// The intent waiting for every layer to close. A newer one replaces it.
    private(set) var deferred: NavigationIntent?
    /// Moves with every intent, presentation and unwind, so work begun for an older one can tell
    /// it has been overtaken.
    private(set) var generation = 0
    /// A link is being looked up, so nothing waiting for a quiet moment shows meanwhile.
    private(set) var isFollowingLink = false
    /// Routes shown once nothing is presented, asked or covering the grid, oldest first.
    private(set) var waiting: [ModalRoute] = []
    /// The Earth has a sheet or alert of its own up, such as its list of locations, which it
    /// presents from the library's own controller.
    private(set) var earthPresents = false
    /// The Earth is asked to close what it has up; it reports when it has gone.
    private(set) var earthPresentationClosing = false
    /// Runs the intents that change the library itself: the timeline, a filter, the Earth.
    @ObservationIgnored var perform: (NavigationIntent) -> Void = { _ in }
    /// The level the layers are closing down to.
    @ObservationIgnored private var closingTo: Int?
    @ObservationIgnored private var idleCheck: Task<Void, Never>?

    // MARK: What screens and hosts read

    /// Nothing is presented, asked, covering the grid, waiting to run or being looked up.
    var isIdle: Bool {
        layers.isEmpty && alert == nil && overlay.isEmpty && deferred == nil && !isFollowingLink && !earthPresents
    }

    /// A photo is open in either viewer, until it has finished closing.
    var isViewing: Bool {
        switch layers.first?.route {
        case .viewer, .phoneViewer: true
        default: false
        }
    }

    /// The viewer over the library, until it has finished closing.
    var viewerRoute: ViewerRoute? {
        if case .viewer(let route) = layers.first?.route { route } else { nil }
    }

    /// The layer a host at `level` shows in `style`, or nil once it is asked to close.
    func shown(at level: Int, style: PresentationStyle) -> Layer? {
        guard layers.indices.contains(level), !layers[level].isClosing, layers[level].route.style == style else { return nil }
        return layers[level]
    }

    // MARK: Commands

    /// Presents `route` from the screen at `level`, where 0 is the library itself. Over anything
    /// already presented, or what the Earth has up, the library's own presentation closes it
    /// first. A screen presents only while it is the top layer and staying.
    func present(_ route: ModalRoute, from level: Int = 0) {
        if level == 0, !layers.isEmpty || earthPresents { send(.present(route)); return }
        guard level == layers.count, closingTo == nil else { return }
        generation += 1
        waiting.removeAll { $0 == route }
        layers.append(Layer(route: route))
    }

    /// Runs `intent` once everything presented over the library has closed, the top layer first.
    func send(_ intent: NavigationIntent) {
        generation += 1
        deferred = intent
        if layers.isEmpty, !earthPresents { runDeferred() } else { close(downTo: 0) }
    }

    /// Closes everything over the library, and drops the intent waiting and the alert. Returns
    /// the generation that work begun now carries, such as looking up a link.
    @discardableResult func unwind() -> Int {
        generation += 1
        deferred = nil
        alert = nil
        close(downTo: 0)
        idleMayHaveChanged()
        return generation
    }

    /// Closes the layer at `level` and everything above it, the top first.
    func dismiss(level: Int) { close(downTo: level) }

    /// A host's layer has finished closing: the layer at `level`, and anything still above it,
    /// are gone. Once every layer asked to close has gone, the intent waiting runs. Each layer
    /// counts once: a report for a layer that was never asked to close, such as a late one for a
    /// level shown again since, changes nothing.
    func layerDidDismiss(level: Int) {
        guard layers.indices.contains(level), layers[level].isClosing else { return }
        layers.removeSubrange(level...)
        if let target = closingTo, layers.count > target { closeTop(); return }
        closingTo = nil
        if layers.isEmpty, !earthPresents { runDeferred() }
        idleMayHaveChanged()
    }

    /// The Earth has put up, or taken down, a sheet or alert of its own. Once it has gone, and
    /// every layer with it, the intent waiting runs.
    func earthPresentationChanged(_ up: Bool) {
        guard earthPresents != up else { return }
        earthPresents = up
        guard !up else { return }
        earthPresentationClosing = false
        if layers.isEmpty, closingTo == nil { runDeferred() }
        idleMayHaveChanged()
    }

    /// Shows `route` once nothing is presented, asked or covering the grid.
    func presentWhenIdle(_ route: ModalRoute) {
        if isIdle { present(route) } else if !waiting.contains(route) { waiting.append(route) }
    }

    func show(_ alert: LibraryAlert) { self.alert = alert }

    /// `alert` has been answered or dismissed, unless another has replaced it since.
    func alertDidClose(_ alert: LibraryAlert) {
        guard self.alert == alert else { return }
        self.alert = nil
        idleMayHaveChanged()
    }

    func setShelves(_ out: Bool) {
        guard overlay.shelves != out else { return }
        overlay.shelves = out
        idleMayHaveChanged()
    }

    /// The place the Earth turns to as it rises next, or nil to leave it where it was.
    func focusEarth(_ focus: PlaceFocus?) { overlay.earthFocus = focus }

    func raiseEarth() { overlay.earth = true }

    func lowerEarth() {
        guard overlay.earth else { return }
        overlay.earth = false
        idleMayHaveChanged()
    }

    func beginLink() { isFollowingLink = true }

    func endLink() {
        isFollowingLink = false
        idleMayHaveChanged()
    }

    // MARK: Closing and running

    private func close(downTo level: Int) {
        // The Earth presents from the library's own controller, so it closes along with level 0.
        if level == 0, earthPresents { earthPresentationClosing = true }
        guard layers.count > level else { return }
        closingTo = min(closingTo ?? level, level)
        closeTop()
    }

    private func closeTop() {
        guard let top = layers.indices.last, !layers[top].isClosing else { return }
        layers[top].isClosing = true
    }

    private func runDeferred() {
        guard let intent = deferred else { return }
        deferred = nil
        switch intent {
        case .present(let route): present(route)
        case .openAsset(let asset, let album): present(.viewer(ViewerRoute(asset: asset, source: .feed, albumContext: album)))
        case .alert(let alert): self.alert = alert
        case .showInTimeline, .exploreLocation, .showAlbum, .showPerson: perform(intent)
        }
    }

    /// Something that held back the routes waiting may have gone. The next one shows on the next
    /// turn, outside whatever update reported the change.
    private func idleMayHaveChanged() {
        guard !waiting.isEmpty, idleCheck == nil else { return }
        idleCheck = Task { [weak self] in
            guard let self else { return }
            self.idleCheck = nil
            guard self.isIdle, !self.waiting.isEmpty else { return }
            self.present(self.waiting.removeFirst())
        }
    }
}

/// Presents the navigator's layer at one level as a sheet or a full-screen cover, and reports
/// once it has closed. The screen it presents hosts the level above.
struct PresentationHost: ViewModifier {
    let navigator: LibraryNavigator
    let level: Int
    /// The screen for a route presented at a level.
    let screen: (ModalRoute, Int) -> AnyView

    func body(content: Content) -> some View {
        content
            .sheet(item: layer(.sheet), onDismiss: { navigator.layerDidDismiss(level: level) }) { presented($0) }
            .fullScreenCover(item: layer(.cover), onDismiss: { navigator.layerDidDismiss(level: level) }) { presented($0) }
    }

    /// Closing a sheet by a swipe, or from inside with `dismiss`, asks the navigator to close it.
    private func layer(_ style: PresentationStyle) -> Binding<LibraryNavigator.Layer?> {
        Binding(get: { navigator.shown(at: level, style: style) },
                set: { if $0 == nil { navigator.dismiss(level: level) } })
    }

    private func presented(_ layer: LibraryNavigator.Layer) -> AnyView {
        AnyView(screen(layer.route, level).modifier(PresentationHost(navigator: navigator, level: level + 1, screen: screen)))
    }
}

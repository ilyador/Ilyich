import SwiftUI

/// A sheet over the viewer. SwiftUI shows one at a time.
enum ViewerSheet: Identifiable {
    /// The photo's details.
    case info
    /// The photo's place on the Places globe, for a viewer that can't raise the library's Earth.
    case location(PlaceFocus)
    case addToAlbum
    case sharedLink
    /// The photo's stack.
    case stack
    /// The comments and likes on the photo in the album it was opened from.
    case activity
    case cast
    case similar
    case profilePhoto
    /// What can be done to the photo's copy on this phone.
    case phoneCopy
    /// The system share sheet, with the files an export made.
    case share(ExportedFiles)

    var id: String {
        switch self {
        case .info: "info"
        case .location(let focus): "location \(focus.latitude) \(focus.longitude)"
        case .addToAlbum: "addToAlbum"
        case .sharedLink: "sharedLink"
        case .stack: "stack"
        case .activity: "activity"
        case .cast: "cast"
        case .similar: "similar"
        case .profilePhoto: "profilePhoto"
        case .phoneCopy: "phoneCopy"
        case .share(let files): "share \(files.id)"
        }
    }
}

/// A full-screen cover over the viewer.
enum ViewerCover: String, Identifiable {
    case editor, selectText, slideshow
    var id: String { rawValue }
}

/// A question the viewer asks before a change that can't simply be undone.
enum ViewerConfirmation: Hashable {
    /// The photo goes to Trash, or for good when it is in Trash already or the server keeps none.
    case delete(Asset, permanently: Bool)

    var permanently: Bool {
        switch self { case .delete(_, let permanently): permanently }
    }
}

/// What the viewer shows and does (REBUILD_ROADMAP.md N3): the photos it pages through, the photo
/// on screen and the fresher records it has of them, and the one sheet, cover or question up over
/// it. The photos are the source's window around the photo on screen (AssetWindowProvider): read
/// again whenever the source changes, and whenever the photos come to rest, but never while a
/// swipe or a scrub moves them. The viewer's own changes go through the account's mutations (N2);
/// exploring a place is an intent the library's navigator runs.
@MainActor @Observable final class ViewerModel {
    let api: APIClient
    /// What the viewer opened on: the photo, where its photos come from, and the album it was
    /// opened in, for the album's cover and comments.
    let route: ViewerRoute
    let window: AssetWindowProvider
    /// Share, Download original and Save to Photos.
    let exports: ExportTracker
    /// The photos the viewer pages through: the source's window around the photo on screen,
    /// which always holds that photo.
    private(set) var assets: [Asset]
    /// The photo on screen.
    private(set) var selectedID: String
    /// Fresher records than the window's, by photo: what the server said when the photo was shown,
    /// and what the account's changes left of it.
    private(set) var replacements: [String: Asset]
    /// Where the pages rest. A new window moves it in the same change as the photos, so a photo
    /// added or removed beside the one on screen never slides another under the viewer.
    var pagePosition: ScrollPosition
    /// Moves each time a new window puts the photo on screen at another place among the photos.
    /// The thumbnail strip is then laid out afresh around it: a strip scrolled to it in the same
    /// change can land past its end, and one scrolled a change later shows other thumbnails for
    /// a frame.
    private(set) var windowShifts = 0
    var sheet: ViewerSheet?
    var cover: ViewerCover?
    var confirmation: ViewerConfirmation?
    var error: String?
    /// A change to the photo is running; exports keep their own state.
    private(set) var working = false
    private(set) var features: ServerFeatures?
    /// The thumbnail strip is being scrubbed: pages show what memory has and slow work waits.
    private(set) var stripScrubbing = false
    /// Moves with each change the account's library publishes, so the photo on screen is read again.
    private(set) var refreshRevision = 0
    /// Photos whose copy on this phone was removed while the viewer is open.
    private(set) var removedLocalCopies: Set<String> = []
    /// The question last asked, which its dialog keeps showing while it goes away.
    @ObservationIgnored private(set) var lastConfirmation: ViewerConfirmation?
    /// The refresh from which a photo the account may have lost access to must be read again.
    @ObservationIgnored private var accessRefreshRevision = -1
    @ObservationIgnored private let matchedLocalPhotos: [String: LocalPhoto]
    /// The library's navigator, for its own viewer only.
    @ObservationIgnored private weak var navigator: LibraryNavigator?
    @ObservationIgnored private var mutations: LibraryMutationService?
    @ObservationIgnored private let follower = MutationFollower()
    @ObservationIgnored private var closeViewer: () -> Void = {}
    @ObservationIgnored private var started = false
    /// The pages are moving under a finger or an animation.
    @ObservationIgnored private var pagerMoving = false
    /// How long the photos rest before the window is read again around the photo now on screen:
    /// the strip finishes following the photo first, so a strip laid out afresh looks the same.
    @ObservationIgnored private let settleDelay: Duration
    @ObservationIgnored private var settling: Task<Void, Never>?
    /// An intent waiting for the sheet over the viewer to close, such as exploring a place from
    /// the details: the sheet goes first, then the viewer, as the navigator closes its own layers.
    @ObservationIgnored private var intentAfterSheet: NavigationIntent?

    /// `matchedLocalPhotos` are the phone's copies of server photos, by server ID. Only the
    /// library's own viewer is handed the `navigator`: exploring a place there raises the
    /// library's Earth, where any other viewer shows the place over itself. The strip's scroll
    /// to the photo on screen takes 0.3 s, which `settleDelay` waits out. Nothing starts until
    /// `start`, as SwiftUI makes a model each time it makes the view and keeps the first.
    init(api: APIClient, route: ViewerRoute, window: AssetWindowProvider, matchedLocalPhotos: [String: LocalPhoto] = [:],
         navigator: LibraryNavigator? = nil, settleDelay: Duration = .milliseconds(350)) {
        self.api = api
        self.route = route
        self.window = window
        self.matchedLocalPhotos = matchedLocalPhotos
        self.navigator = navigator
        self.settleDelay = settleDelay
        let id = route.asset.id
        assets = AssetWindow.merged(shown: [route.asset], offered: window.window(around: id), selected: id)
        selectedID = id
        replacements = [id: route.asset]
        pagePosition = ScrollPosition(id: id, anchor: .leading)
        exports = ExportTracker(api: api)
    }

    // MARK: What the viewer reads

    /// Where the photo on screen is among the photos.
    var index: Int { assets.firstIndex { $0.id == selectedID } ?? 0 }
    /// The photo on screen, as freshly as the viewer has it.
    var current: Asset { replacements[selectedID] ?? assets.first { $0.id == selectedID } ?? route.asset }
    /// A photo as freshly as the viewer has it.
    func record(_ asset: Asset) -> Asset { replacements[asset.id] ?? asset }
    /// Every photo the viewer pages through, as freshly as it has them.
    var records: [Asset] { assets.map(record) }
    /// The photo on screen once the strip lets go of it: only the photo a scrub stops on is read
    /// again, cast and has its neighbors loaded.
    var settledID: String? { stripScrubbing ? nil : selectedID }
    /// A change or an export is running, so the other actions wait.
    var busy: Bool { working || exports.isRunning }
    /// What the photo on screen offers. Every button and menu item renders from it.
    var capabilities: AssetCapabilities {
        AssetCapabilityPolicy.evaluate(current, context: CapabilityContext(api: api, features: features, album: route.albumContext))
    }
    /// Exploring a place raises the library's Earth, which only the library's own viewer can do.
    var exploresOnTheEarth: Bool { navigator != nil }
    /// The photo's copy on this phone, until it is removed here.
    func localCopy(of asset: Asset) -> LocalPhoto? { removedLocalCopies.contains(asset.id) ? nil : matchedLocalPhotos[asset.id] }
    /// Where the photo on screen was taken, when its details say so.
    var locationFocus: PlaceFocus? {
        let asset = current
        guard let latitude = asset.exifInfo?.latitude, let longitude = asset.exifInfo?.longitude,
              latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return .init(latitude: latitude, longitude: longitude, assetID: asset.id)
    }
    /// What reading the photo on screen again waits on: the photo, once the strip lets go of it,
    /// and each change the library publishes.
    var refreshKey: String { (settledID ?? "") + "|" + String(refreshRevision) }

    // MARK: Following the source and the account

    /// Starts following the source and the account's mutations, once. `close` closes the viewer.
    func start(mutations: LibraryMutationService?, close: @escaping () -> Void) {
        closeViewer = close
        self.mutations = mutations
        follower.follow(mutations, applying: { [weak self] result in self?.apply(result) })
        guard !started else { return }
        started = true
        sourceChanged()
    }

    /// The source changed, or is first watched: its window around the photo on screen shows,
    /// unless the photos are moving or have only just stopped, when it is read once they have
    /// rested. The source stays watched.
    private func sourceChanged() {
        let offered = watchedWindow()
        if !isMoving, settling == nil { show(offered) }
    }

    /// The source's window around the photo on screen. The next change to anything it was read
    /// from tells the model, once; each telling watches again.
    private func watchedWindow() -> [Asset] {
        let window = window, id = selectedID, neighbors = neighborIDs
        return withObservationTracking { Self.offered(by: window, around: id, neighbors: neighbors) } onChange: { [weak self] in
            Task { @MainActor in self?.sourceChanged() }
        }
    }

    /// The window `window` offers around the photo `id`. Where the source no longer holds that
    /// photo, as when it was deleted elsewhere or archived here, the window around a photo beside
    /// it says where it was.
    private static func offered(by window: AssetWindowProvider, around id: String, neighbors: [String]) -> [Asset] {
        let offered = window.window(around: id)
        guard offered.isEmpty else { return offered }
        for neighbor in neighbors {
            let around = window.window(around: neighbor)
            if !around.isEmpty { return around }
        }
        return []
    }

    /// The photos either side of the one on screen, the one before first.
    private var neighborIDs: [String] {
        guard let index = assets.firstIndex(where: { $0.id == selectedID }) else { return [] }
        return [index - 1, index + 1].filter(assets.indices.contains).map { assets[$0].id }
    }

    private var isMoving: Bool { pagerMoving || stripScrubbing }

    /// The photos have come to rest: once they stay at rest a moment, the window is read again
    /// around the photo now on screen.
    private func settle() {
        guard started else { return }
        settling?.cancel()
        settling = nil
        guard settleDelay > .zero else { return showSettledWindow() }
        settling = Task { [weak self, settleDelay] in
            try? await Task.sleep(for: settleDelay)
            guard let self, !Task.isCancelled else { return }
            self.settling = nil
            // Moving again: the window is read once the photos rest again.
            guard !self.isMoving else { return }
            self.showSettledWindow()
        }
    }

    private func showSettledWindow() {
        show(Self.offered(by: window, around: selectedID, neighbors: neighborIDs))
    }

    /// Shows the source's window with the photo on screen kept in it (AssetWindow.merged). The
    /// pages move with the photos in the same change, so the photo on screen stays put.
    private func show(_ offered: [Asset]) {
        let next = AssetWindow.merged(shown: assets, offered: offered, selected: selectedID)
        guard next != assets else { return }
        let moved = next.count != assets.count || zip(next, assets).contains { $0.id != $1.id }
        let shifted = next.firstIndex { $0.id == selectedID } != assets.firstIndex { $0.id == selectedID }
        assets = next
        if moved { pagePosition.scrollTo(id: selectedID, anchor: .leading) }
        if shifted { windowShifts += 1 }
    }

    /// A change the account made, here or on any screen: the photos it changed show their new
    /// records at once, in one write however many it names.
    private func apply(_ result: MutationResult) {
        let changed = result.records(updating: { id in replacements[id] ?? assets.first { $0.id == id } })
        if !changed.isEmpty { replacements.merge(changed) { _, new in new } }
    }

    // MARK: Moving between photos

    /// The pages started or stopped moving, under a finger or an animation.
    func setPagerMoving(_ moving: Bool) {
        guard pagerMoving != moving else { return }
        pagerMoving = moving
        if !isMoving { settle() }
    }

    /// The thumbnail strip started or stopped being scrubbed.
    func setStripScrubbing(_ scrubbing: Bool) {
        guard stripScrubbing != scrubbing else { return }
        stripScrubbing = scrubbing
        if !isMoving { settle() }
    }

    /// A swipe moved the photo on screen to `id`. Once the photos rest the window is read again
    /// around it.
    func select(_ id: String) {
        guard id != selectedID, assets.contains(where: { $0.id == id }) else { return }
        selectedID = id
        if !isMoving { settle() }
    }

    /// The strip picked a photo: the pages jump straight to it, as in Photos.
    func jump(to id: String) {
        guard id != selectedID, assets.contains(where: { $0.id == id }) else { return }
        selectedID = id
        pagePosition.scrollTo(id: id, anchor: .leading)
        if !isMoving { settle() }
    }

    // MARK: Fresher records

    /// The account's library published a change: the photo on screen is read again.
    func libraryChanged(accessChanged: Bool) {
        refreshRevision += 1
        if accessChanged { accessRefreshRevision = refreshRevision }
    }

    /// Reads the photo on screen from the server again: on showing it, and after each change the
    /// library publishes. A photo found gone, locked or put in Trash elsewhere leaves its source
    /// and the viewer closes; any other record shows here, and reaches the source only when it
    /// changes what the source shows of the photo.
    func refreshCurrentAsset() async {
        guard settledID != nil else { return }
        let id = selectedID, revision = refreshRevision
        let previous = current
        let accessMustBeConfirmed = accessRefreshRevision >= 0 && accessRefreshRevision <= revision
        do {
            if revision > 0 { try await Task.sleep(for: .milliseconds(250)) }
            let asset = try await api.asset(id: id)
            try Task.checkCancellation()
            guard selectedID == id, refreshRevision == revision, showDetails(asset, over: previous) else { return }
            accessRefreshRevision = -1
        } catch is CancellationError { }
        catch {
            guard selectedID == id, refreshRevision == revision, !Task.isCancelled else { return }
            switch error {
            case ServerFailure.forbidden, ServerFailure.notFound:
                window.lose(id); close()
            case ServerFailure.sessionExpired, ServerFailure.proxyRejected:
                // Not a deletion: the photo is most likely still there, and only the session check
                // signs out. A photo whose access must be confirmed still closes.
                if accessMustBeConfirmed { close() }
                else if revision == 0 { self.error = error.localizedDescription }
            default:
                if accessMustBeConfirmed { window.lose(id); close() }
                else if revision == 0 { self.error = error.localizedDescription }
            }
        }
    }

    /// Puts a photo's fresh details on screen, or closes the viewer on a photo locked or put in
    /// Trash since `previous` was shown. Says whether the viewer stays.
    @discardableResult func showDetails(_ asset: Asset, over previous: Asset) -> Bool {
        if (asset.visibility == .locked && previous.visibility != .locked) || (asset.isTrashed && !previous.isTrashed) {
            window.lose(asset.id); close(); return false
        }
        take(asset, over: previous)
        return true
    }

    /// A fresher record of a photo the viewer shows, read from the server by its details.
    func take(_ asset: Asset) {
        take(asset, over: replacements[asset.id] ?? assets.first { $0.id == asset.id })
    }

    /// The record shows here at once. The source hears of it only when it changes what the source
    /// shows (Asset.changesListing): a detailed record differs from a timeline row in much that no
    /// list shows, and the feed would lay a month out again for it at every photo opened.
    private func take(_ asset: Asset, over previous: Asset?) {
        replacements[asset.id] = asset
        if let previous, asset.changesListing(from: previous) { window.publish(asset) }
    }

    func loadFeatures() async {
        if let features = try? await api.serverFeatures() { self.features = features }
    }

    // MARK: Changes to the photo

    func toggleFavorite() {
        guard capabilities.offers(.favorite) else { return }
        let asset = current
        run { _ = try await self.mutate(.favorite([asset.id], !asset.isFavorite), on: asset) }
    }

    func changeVisibility(_ visibility: AssetVisibility) {
        let locking = visibility == .locked || current.visibility == .locked
        guard capabilities.offers(locking ? .lock : .archive) else { return }
        let asset = current
        run {
            _ = try await self.mutate(.visibility([asset.id], visibility), on: asset)
            // A locked photo leaves the library, its media gone with it.
            if visibility == .locked { self.close() }
        }
    }

    func setAlbumCover() {
        guard let album = route.albumContext, capabilities.offers(.albumCover) else { return }
        let asset = current
        run { _ = try await self.mutate(.setAlbumCover(album: album, asset: asset.id), on: asset) }
    }

    /// Asks before deleting the photo on screen: to Trash, or for good when the server, asked
    /// again now, keeps no Trash. The question is asked only if the photo is still on screen.
    func requestDeletion() {
        guard capabilities.offers(.trash) || capabilities.offers(.deletePermanently) else { return }
        let asset = current
        run {
            let latest = try await self.api.serverFeatures()
            guard asset.id == self.selectedID else { return }
            self.features = latest
            let question = ViewerConfirmation.delete(asset, permanently: asset.isTrashed || !latest.trash)
            self.lastConfirmation = question
            self.confirmation = question
        }
    }

    /// Deletes the photo the question was asked about, which a swipe may have moved on from the
    /// one opened, and closes the viewer, as it always has (P3 moved only the phone's viewer on).
    func confirmDeletion() {
        guard case .delete(let asset, let permanently) = lastConfirmation, asset.ownerId != nil, asset.ownerId == api.userID else { return }
        run {
            _ = try await self.mutate(permanently ? .deletePermanently([asset.id]) : .trash([asset.id]), on: asset)
            self.close()
        }
    }

    func restore() {
        guard capabilities.offers(.restore) else { return }
        let asset = current
        run {
            _ = try await self.mutate(.restore([asset.id]), on: asset)
            self.close()
        }
    }

    /// Opens the editor. Before the photo's details say whether the server's editor takes it, the
    /// tap reads them itself, as a change runs: the spinner shows, the other actions wait and a
    /// failure is shown. The editor then opens only on the photo still on screen with nothing
    /// opened over it, so a tap never opens it later on its own.
    func openEditor() {
        if capabilities.offers(.edit) { cover = .editor; return }
        guard capabilities[.edit].awaitsDetails else { return }
        let id = selectedID
        run {
            let asset = try await self.api.asset(id: id)
            guard self.selectedID == id, self.showDetails(asset, over: self.current) else { return }
            if self.capabilities.offers(.edit), self.sheet == nil, self.cover == nil { self.cover = .editor }
        }
    }

    /// The phone's copy of a photo was removed from Photos.
    func localCopyRemoved(for id: String) { removedLocalCopies.insert(id) }

    // MARK: Exports

    /// Shares the photo on screen: its original or, with its edits, the version shown. The share
    /// sheet opens only if the photo is still the one on screen.
    func share(original: Bool) {
        guard !busy else { return }
        let asset = current
        exports.start(.share([asset], original: original)) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .files(let files): if self.selectedID == asset.id { self.sheet = .share(files) }
            case .failed(let failure, _): self.error = failure.localizedDescription
            case .saved, .cancelled: break
            }
        }
    }

    func saveToPhotos() {
        guard !busy, capabilities.offers(.saveToPhotos) else { return }
        exports.start(.saveToPhotos([current], original: false)) { [weak self] outcome in
            if case .failed(let failure, _) = outcome { self?.error = failure.localizedDescription }
        }
    }

    /// An export is for the photo it started on: it stops when the viewer leaves that photo or
    /// closes, unless it is already writing to Photos, which finishes.
    func stopExport() { if !exports.isCommitting { exports.cancel() } }

    // MARK: Places

    /// Explores a place. From the library, the viewer closes and the Earth rises turned to it,
    /// after any sheet over the viewer has gone; any other viewer shows the place over itself.
    func exploreLocation(_ focus: PlaceFocus) {
        guard let navigator else { sheet = .location(focus); return }
        if sheet != nil { intentAfterSheet = .exploreLocation(focus); sheet = nil }
        else { navigator.send(.exploreLocation(focus)) }
    }

    /// The sheet over the viewer has gone: an intent waiting for it runs.
    func sheetDidDismiss() {
        guard let intent = intentAfterSheet else { return }
        intentAfterSheet = nil
        navigator?.send(intent)
    }

    // MARK: Support

    func close() { closeViewer() }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        working = true
        Task {
            defer { working = false }
            do { try await operation() } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }

    /// Has the account's mutations make the change to `asset`, and waits for the server's answer.
    /// The viewer and every screen showing the photo take the result from the service, so the
    /// change shows here and in the feed the same whether or not the viewer is still open.
    private func mutate(_ request: MutationRequest, on asset: Asset) async throws -> MutationResult {
        guard let mutations else { throw APIError.signedOut }
        let result = try await mutations.start(request, on: [asset]).result
        if let reason = result.failed.values.first { throw APIError.invalidResponse(reason) }
        return result
    }
}

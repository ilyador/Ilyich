import Photos
import SwiftUI

/// The photo and video viewer. What it shows and does is its model's (ViewerModel): the photos it
/// pages through come from the screen it opened from (AssetWindowProvider), and the photo on screen
/// stays put however that source changes.
@MainActor
struct AssetViewer: View {
    let pipeline: MediaPipeline
    /// Set when the viewer zooms out of a grid cell: it hears which photo is on screen, and the
    /// zoom's drag to close (ViewerZoomTransition) replaces the viewer's own swipe down.
    let transition: ViewerTransitionState?
    /// Closes the viewer when it was presented outside SwiftUI.
    let onClose: (() -> Void)?
    @State private var model: ViewerModel
    @State private var controls = true
    @State private var playingLive = false
    /// Where the bars leave room for the LIVE badge and the video pill, kept while the bars are hidden.
    @State private var chromeInsets = EdgeInsets()
    @State private var playback = VideoPlaybackState()
    /// Only scrolling moves the selection; offsets that change at rest, such as on first showing
    /// the strip or turning the phone, say nothing about it.
    @State private var pagerPhase: ScrollPhase = .idle
    @State private var viewport = CGSize.zero
    @Environment(\.displayScale) private var displayScale
    @AppStorage("viewerTapToNavigate") private var tapToNavigate = false
    /// Shared with the setting and every video, so muting carries on to the next video, as in Photos.
    @AppStorage("viewerMuteVideo") private var muteVideo = false
    @AppStorage("shareFileType") private var shareFileType = "original"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.mutations) private var mutations
    /// The account's bus, where the sync's changes reach the viewer as its mutations' results do.
    @Environment(\.libraryBus) private var bus

    /// `route` names the photo the viewer opens on and where its photos come from, and `window` is
    /// that source. `matchedLocalPhotos` are the phone's copies of server photos, by server ID.
    /// Only the library's own viewer is handed the `navigator`: exploring a place there raises the
    /// library's Earth, where any other viewer shows the place over itself.
    init(api: APIClient, pipeline: MediaPipeline, route: ViewerRoute, window: AssetWindowProvider,
         matchedLocalPhotos: [String: LocalPhoto] = [:], navigator: LibraryNavigator? = nil,
         transition: ViewerTransitionState? = nil, onClose: (() -> Void)? = nil) {
        self.pipeline = pipeline
        self.transition = transition; self.onClose = onClose
        _model = State(initialValue: ViewerModel(api: api, route: route, window: window, matchedLocalPhotos: matchedLocalPhotos,
                                                 navigator: navigator))
    }

    private var api: APIClient { model.api }
    private var current: Asset { model.current }
    /// What the photo on screen offers. Every button and menu item renders from it.
    private var capabilities: AssetCapabilities { model.capabilities }

    private var canvas: some View {
        ZStack {
            // Under the zoom presenter the black is the presenter's, so it fades as the viewer closes.
            if transition == nil { Color.black.ignoresSafeArea() }
            pager
            pageChrome
            if let progress = model.exports.progress, let request = model.exports.request {
                VStack(spacing: 12) {
                    if let fraction = progress.fraction { ProgressView(value: fraction) } else { ProgressView() }
                    Text(progress.committing ? "Saving to Photos…" : Self.exportLabel(request)).font(.subheadline)
                    if !progress.committing { Button("Cancel") { model.exports.cancel() }.buttonStyle(.glass).accessibilityIdentifier("viewer.cancelTransfer") }
                }.frame(width: 220).padding(20).glassEffect(in: .rect(cornerRadius: 24))
                    .accessibilityElement(children: .contain)
            } else if model.working { ProgressView().padding(20).glassEffect(in: .circle).accessibilityLabel("Preparing photo") }
        }
        // The badge and the pill stay where the bars put them while the bars slide away.
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in if controls { chromeInsets = insets } }
        .containerBackground(transition == nil ? Color.black : Color.clear, for: .navigation)
        .toolbar { viewerToolbar }
        .toolbarVisibility(controls ? .visible : .hidden, for: .navigationBar, .bottomBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
        .navigationBarTitleDisplayMode(.inline)
        // Monochrome glyphs, as in Photos, whatever the app's accent.
        .tint(.primary)
        // An export is for the photo it started on; one already writing to Photos finishes.
        .onChange(of: model.selectedID) { model.stopExport() }
        .onDisappear { model.stopExport() }
        .preferredColorScheme(.dark)
        .statusBarHidden(!controls)
        .task { await model.loadFeatures() }
        .onChange(of: model.selectedID) { playingLive = false }
        .onChange(of: model.selectedID, initial: true) {
            // Closing zooms back into the cell of the photo on screen, lined up with the photo.
            transition?.currentID = model.selectedID
            transition?.aspectRatio = CGFloat(current.aspectRatio)
        }
        // Scrubbing the strip passes many photos; only the one it stops on is refreshed.
        .task(id: model.refreshKey) { await model.refreshCurrentAsset() }
        .task(id: model.settledID) { if model.settledID != nil { await prefetchNeighbors() } }
    }

    private static let pageGap: CGFloat = 20

    /// Photos lie side by side on one paging strip with a black gap between them, as in Photos.
    /// The strip is one gap wider than the screen, so each page is a photo plus the gap after it.
    /// Pages keep their place while the selection changes, so a swipe never swaps photos mid-drag,
    /// and the model moves them along with any change to the photos, so none slides under the viewer.
    private var pager: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(model.assets.enumerated()), id: \.element.id) { index, summary in
                        page(index: index, asset: model.record(summary))
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .padding(.trailing, Self.pageGap)
                    }
                }.scrollTargetLayout()
            }
            .frame(width: proxy.size.width + Self.pageGap, alignment: .leading)
            .scrollIndicators(.hidden)
            // The bars float over the photo; no soft edge is drawn under them.
            .scrollEdgeEffectHidden(true, for: .all)
            .scrollTargetBehavior(.paging)
            .scrollPosition($model.pagePosition, anchor: .leading)
            .onScrollGeometryChange(for: Int.self) { geometry in
                Int((geometry.contentOffset.x / max(1, geometry.containerSize.width)).rounded())
            } action: { _, page in
                guard pagerPhase != .idle, model.assets.indices.contains(page) else { return }
                model.select(model.assets[page].id)
            }
            .onScrollPhaseChange { _, phase in
                pagerPhase = phase
                model.setPagerMoving(phase != .idle)
            }
            // Turning the phone resizes every page while the offset stays, which would land on a
            // photo far away; the strip comes back to the selected photo instead.
            .onChange(of: proxy.size, initial: true) { _, size in
                viewport = size
                model.pagePosition.scrollTo(id: model.selectedID, anchor: .leading)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func page(index: Int, asset: Asset) -> some View {
        let selectedID = model.selectedID
        if abs(index - model.index) <= 1 {
            if asset.isVideo {
                videoPage(AuthenticatedVideo(api: api, assetID: asset.id, active: selectedID == asset.id && !model.stripScrubbing,
                                             sourceAsset: asset, matchedLocalPhoto: model.localCopy(of: asset), playback: playback))
            } else if playingLive, selectedID == asset.id, let videoID = asset.livePhotoVideoId {
                videoPage(AuthenticatedVideo(api: api, assetID: videoID, active: true, onEnded: { playingLive = false },
                                             sourceAsset: asset, matchedLocalPhoto: model.localCopy(of: asset), isLivePhotoMotion: true))
            } else {
                ViewerPhoto(pipeline: pipeline, asset: asset, active: selectedID == asset.id, onTap: handlePhotoTap, onDismiss: { if transition == nil { close() } },
                            matchedLocalPhoto: model.localCopy(of: asset), onSwipeUp: { model.sheet = .info }, settled: !model.stripScrubbing)
            }
        } else { Color.black }
    }

    private func showPage(_ index: Int) {
        guard model.assets.indices.contains(index) else { return }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .smooth(duration: 0.3)) {
            model.pagePosition.scrollTo(id: model.assets[index].id, anchor: .leading)
        }
    }

    /// The photos either side load before a swipe reaches them, so paging never lands on a spinner.
    private func prefetchNeighbors() async {
        let pixels = Int(max(viewport.width, viewport.height) * displayScale)
        guard pixels > 0 else { return }
        let assets = model.assets, index = model.index
        for offset in [1, -1, 2] where assets.indices.contains(index + offset) {
            let asset = model.record(assets[index + offset])
            guard !asset.isVideo else { continue }
            _ = try? await pipeline.image(for: asset, size: .preview, pixelSize: pixels)
            if Task.isCancelled { return }
        }
    }

    var body: some View {
        NavigationStack { canvas }
            // One sheet and one cover at a time, as SwiftUI presents them.
            .sheet(item: $model.sheet, onDismiss: { model.sheetDidDismiss() }) { sheet in sheetContent(sheet) }
            .fullScreenCover(item: $model.cover) { cover in coverContent(cover) }
            // Only the viewer turns with the phone; the rest of the app stays upright.
            .onAppear { OrientationLock.viewerAppeared() }
            .onDisappear { OrientationLock.viewerDisappeared() }
            .onAppear {
                // The close handed over holds only what closing needs, not this view.
                let onClose = onClose, dismiss = dismiss
                model.start(mutations: mutations, bus: bus, close: { if let onClose { onClose() } else { dismiss() } })
                // Nothing moves under the photo while the viewer closes.
                let model = model
                transition?.onClosing = { closing in model.setClosing(closing) }
            }
            .alert("Couldn’t complete action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) { }
            } message: { Text(model.error ?? "") }
            .confirmationDialog(deletesPermanently ? "Delete permanently?" : "Move to Trash?",
                                isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
                                titleVisibility: .visible) {
                Button(deletesPermanently ? "Delete permanently" : "Move to Trash", role: .destructive) { model.confirmDeletion() }
            } message: {
                Text(deletesPermanently ? "This cannot be undone. Photos on your phone are kept." : "You can restore this item from Trash. Photos on your phone are kept.")
            }
    }

    /// The question shown, or the one going away.
    private var deletesPermanently: Bool { (model.confirmation ?? model.lastConfirmation)?.permanently ?? false }

    @ViewBuilder private func sheetContent(_ sheet: ViewerSheet) -> some View {
        switch sheet {
        case .info: infoSheet
        case .location(let focus): ViewerPlaceSheet(api: api, pipeline: pipeline, focus: focus)
        case .addToAlbum: NavigationStack { ViewerAlbumPicker(api: api, asset: current) }
        case .sharedLink: NavigationStack { SharedLinkEditor(api: api, album: nil, assetIDs: [current.id]) }
        case .stack:
            if let stack = current.stack { NavigationStack { ViewerStackView(api: api, pipeline: pipeline, stackID: stack.id) } }
        case .activity:
            if let albumID = model.route.albumContext { NavigationStack { AlbumActivityView(api: api, albumID: albumID, assetID: current.id) } }
        case .similar: SimilarPhotosView(api: api, pipeline: pipeline, reference: current)
        case .profilePhoto: NavigationStack { ProfilePhotoCropView(api: api, pipeline: pipeline, asset: current) }
        case .phoneCopy:
            if let photo = model.localCopy(of: current) {
                NavigationStack {
                    LocalPhotoActionsView(photos: [photo]) { change in
                        // Only a removal ends the phone copy; a favorite leaves the photo as it was.
                        if case .removed = change { model.localCopyRemoved(for: current.id) }
                        model.sheet = nil
                    }
                }
            }
        case .share(let files): ShareSheet(urls: files.urls).onDisappear { files.remove() }
        }
    }

    @ViewBuilder private func coverContent(_ cover: ViewerCover) -> some View {
        switch cover {
        case .editor: PhotoEditor(api: api, pipeline: pipeline, asset: current)
        case .selectText: OCRPhotoReader(api: api, pipeline: pipeline, asset: current)
        case .slideshow: SlideshowView(api: api, pipeline: pipeline, assets: model.records, initial: current)
        }
    }

    private var infoSheet: some View {
        NavigationStack {
            AssetInfoView(api: api, pipeline: pipeline, asset: current, viewer: model)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { model.sheet = nil } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    /// The bars, laid out as in Photos: back, the title and the actions menu along the top; Share,
    /// a group of Favorite, Info and Edit, and Delete along the bottom. Glyphs only, in system glass.
    /// Favorite keeps its place for every photo, dimmed where it can't be used.
    @ToolbarContentBuilder private var viewerToolbar: some ToolbarContent {
        let can = capabilities, busy = model.busy
        ToolbarItem(placement: .topBarLeading) {
            Button("Close", systemImage: "chevron.left") { close() }
        }
        ToolbarItem(placement: .principal) { titleCapsule }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) { actionsMenu(can) }
        ToolbarItem(placement: .bottomBar) {
            Button("Share", systemImage: "square.and.arrow.up") { model.share(original: shareFileType != "preview") }
                .disabled(busy || !can.offers(.share))
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItemGroup(placement: .bottomBar) {
            Button(current.isFavorite ? "Remove favorite" : "Favorite", systemImage: current.isFavorite ? "heart.fill" : "heart") { model.toggleFavorite() }
                .tint(current.isFavorite ? .red : .primary).disabled(!can.offers(.favorite) || busy)
            Button("Info", systemImage: "info.circle") { model.sheet = .info }.disabled(busy)
            if can.shows(.edit) {
                // Until the photo's details arrive Edit stays lit, so the bar doesn't flicker as
                // photos pass, and a tap reads them first.
                Button("Edit", systemImage: "slider.horizontal.3") { model.openEditor() }
                    .disabled(!(can.offers(.edit) || can[.edit].awaitsDetails) || busy)
            }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if can.shows(.trash) || can.shows(.deletePermanently) {
            ToolbarItem(placement: .bottomBar) {
                Button("Delete", systemImage: "trash") { model.requestDeletion() }
                    .disabled(!(can.offers(.trash) || can.offers(.deletePermanently)) || busy)
            }
        }
    }

    /// Every action that has no button of its own, in sections as in the Photos menu.
    private func actionsMenu(_ can: AssetCapabilities) -> some View {
        Menu {
            Section {
                menuItem(.addToAlbum, can, "Add to album", systemImage: "rectangle.stack.badge.plus") { model.sheet = .addToAlbum }
                menuItem(.sharedLink, can, "Create shared link", systemImage: "link") { model.sheet = .sharedLink }
                if model.route.albumContext != nil {
                    menuItem(.albumCover, can, "Set album cover", systemImage: "photo.on.rectangle.angled") { model.setAlbumCover() }
                }
                menuItem(.comments, can, "Comments and likes", systemImage: "bubble") { model.sheet = .activity }
            }
            Section {
                Button("Slideshow", systemImage: "play.rectangle") { model.cover = .slideshow }
                menuItem(.selectText, can, "Select text", systemImage: "text.viewfinder") { model.cover = .selectText }
                menuItem(.findSimilar, can, "Find similar photos", systemImage: "photo.on.rectangle.angled") { model.sheet = .similar }
                // Opening the stack only reads it; the stack's own screen disables what read-only
                // mode stops.
                if let stack = current.stack, can.shows(.stack) {
                    Button("Stack (\(stack.assetCount))", systemImage: "square.stack.3d.up") { model.sheet = .stack }
                }
            }
            Section {
                menuItem(.share, can, "Share displayed version", systemImage: "square.and.arrow.up") { model.share(original: false) }
                menuItem(.download, can, "Download original", systemImage: "arrow.down.document") { model.share(original: true) }
                menuItem(.saveToPhotos, can, "Save to Photos", systemImage: "square.and.arrow.down") { model.saveToPhotos() }
                if model.localCopy(of: current) != nil {
                    Button("On this phone", systemImage: "iphone") { model.sheet = .phoneCopy }
                }
                menuItem(.openInBrowser, can, "Open in browser", systemImage: "safari") { openURL(api.baseURL.deletingLastPathComponent().appendingPathComponent("photos/\(current.id)")) }
                menuItem(.profilePhoto, can, "Set profile photo", systemImage: "person.crop.circle") { model.sheet = .profilePhoto }
            }
            if can.shows(.restore) || can.shows(.archive) || can.shows(.lock) {
                Section {
                    menuItem(.restore, can, "Restore from Trash", systemImage: "arrow.uturn.backward") { model.restore() }
                    menuItem(.archive, can, current.visibility == .archive ? "Unarchive" : "Archive", systemImage: "archivebox") {
                        model.changeVisibility(current.visibility == .archive ? .timeline : .archive)
                    }
                    menuItem(.lock, can, current.visibility == .locked ? "Move out of Locked Folder" : "Move to Locked Folder", systemImage: "lock") {
                        model.changeVisibility(current.visibility == .locked ? .timeline : .locked)
                    }
                }
            }
        } label: { Label("Photo actions", systemImage: "ellipsis") }
            .disabled(model.busy)
    }

    /// A menu item for `action`: missing where the photo doesn't have it, dimmed where it can't be
    /// used now.
    @ViewBuilder private func menuItem(_ action: AssetAction, _ can: AssetCapabilities, _ title: String, systemImage: String,
                                       perform: @escaping () -> Void) -> some View {
        if can.shows(action) { Button(title, systemImage: systemImage, action: perform).disabled(!can.offers(action)) }
    }

    /// The title hugs its text, as in Photos. Tapping it explores the photo's location.
    @ViewBuilder private var titleCapsule: some View {
        if let lines = titleLines {
            let label = VStack(spacing: 1) {
                Text(lines.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let subtitle = lines.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 18).frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            if let focus = model.locationFocus {
                Button { model.exploreLocation(focus) } label: { label.contentShape(.capsule) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Explore this location on the globe")
                    .glassEffect(.regular.interactive(), in: .capsule)
            } else {
                label.glassEffect(.regular, in: .capsule)
            }
        }
    }

    /// The place over the date and time, or, without a place, the date over the time.
    private var titleLines: (title: String, subtitle: String?)? {
        let utc = TimeZone(secondsFromGMT: 0)!
        let place = [current.exifInfo?.city, current.exifInfo?.country].compactMap { $0 }.first { !$0.isEmpty }
        guard let date = current.localDateTime ?? current.fileCreatedAt else { return place.map { ($0, nil) } }
        if let place { return (place, date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: utc))) }
        return (date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: utc)),
                date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: utc)))
    }

    /// What floats over the photo besides the bars: the LIVE badge under the top bar, and above the
    /// bottom bar a video's playback pill over the thumbnail strip.
    private var pageChrome: some View {
        VStack(spacing: 0) {
            if current.livePhotoVideoId != nil {
                liveBadge.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 6)
            }
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                if current.isVideo {
                    ViewerVideoControls(playback: playback, visible: controls)
                        .frame(maxWidth: 520).padding(.horizontal, 24)
                }
                if model.assets.count > 1 {
                    // The strip keeps its room while hidden, so nothing above it moves.
                    ZStack {
                        if controls {
                            ZStack {
                                ViewerFilmstrip(pipeline: pipeline, assets: model.assets, replacements: model.replacements, selectedID: model.selectedID,
                                                onSelect: { model.jump(to: $0) }, onScrubbingChange: { model.setStripScrubbing($0) })
                                    // Laid out afresh around the photo on screen when a new window
                                    // moves it. A new strip draws its first frame before it has
                                    // scrolled to the photo, so it comes in under the old one,
                                    // which fades away once the photos have rested and both show
                                    // the same thumbnails.
                                    .id(model.windowShifts)
                                    .zIndex(-Double(model.windowShifts))
                                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                            }
                            .animation(.easeOut(duration: 0.2), value: model.windowShifts)
                            .transition(.opacity)
                        }
                    }
                    .frame(height: ViewerFilmstrip.height)
                }
            }
            .padding(.bottom, 10)
        }
        .padding(chromeInsets)
        .ignoresSafeArea()
    }

    /// Plays the Live Photo's motion, from where Photos puts its LIVE badge. Glass ignores the
    /// opacity around it, so the glass is only a background that hiding swaps for `.identity`; the
    /// button in front leaves with a fade, which also takes it out of the accessibility tree.
    private var liveBadge: some View {
        liveBadgeLabel.hidden()
            .overlay {
                if controls {
                    Button { playingLive.toggle() } label: { liveBadgeLabel.contentShape(.capsule) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .accessibilityLabel(playingLive ? "Still photo" : "Play Live Photo")
                        .transition(.opacity)
                }
            }
            .background { Color.clear.glassEffect(controls ? .regular : .identity, in: .capsule) }
    }

    private var liveBadgeLabel: some View {
        Label("LIVE", systemImage: "livephoto")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).frame(height: 28)
    }

    /// The player draws no controls of its own; the bars and the pill float over the video, which
    /// fills the screen as a photo does.
    private func videoPage(_ video: AuthenticatedVideo) -> some View {
        video
            .gesture(ViewerTap { toggleControls() })
            // A swipe down closes a video as it does a photo; a swipe up shows its details.
            .gesture(ViewerSwipe(direction: .down, enabled: transition == nil) { close() })
            .gesture(ViewerSwipe(direction: .up) { model.sheet = .info })
    }

    private func toggleControls() {
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .smooth(duration: 0.25)) { controls.toggle() }
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    private func handlePhotoTap(_ horizontalFraction: Double) {
        let index = model.index
        if tapToNavigate && horizontalFraction < 0.33 && index > 0 { showPage(index - 1) }
        else if tapToNavigate && horizontalFraction > 0.67 && index + 1 < model.assets.count { showPage(index + 1) }
        else { toggleControls() }
    }
    private static func exportLabel(_ request: ExportRequest) -> String {
        switch request.destination {
        case .photos: "Downloading…"
        case .files: request.original || request.assets.contains(where: \.isVideo) ? "Downloading original…" : "Preparing photo…"
        }
    }
}

/// A photo's place on the Places globe, for a viewer that can't raise the library's Earth. A place
/// chosen there shows its photos.
private struct ViewerPlaceSheet: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let focus: PlaceFocus
    @State private var collection: InfoCollection?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            PlacesView(api: api, pipeline: pipeline, onSelect: { place in
                guard !place.assetIDs.isEmpty else { return }
                collection = .init(title: place.title, filter: SearchFilter(or: place.assetIDs.map { SearchIDAlternative(id: IDFilter(eq: $0)) }))
            }, focus: focus)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $collection) { collection in NavigationStack { InfoCollectionView(api: api, pipeline: pipeline, collection: collection) } }
        }
    }
}

private struct ViewerAlbumPicker: View {
    let api: APIClient
    let asset: Asset
    @State private var albums: [Album] = []
    @State private var error: String?
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mutations) private var mutations
    var body: some View {
        List(albums) { album in
            Button(album.albumName) {
                guard let mutations else { error = APIError.signedOut.localizedDescription; return }
                adding = true
                let handle = mutations.start(.addToAlbum(album: album.id, assets: [asset.id]), on: [asset])
                Task {
                    defer { adding = false }
                    do {
                        // A photo already in the album counts as added.
                        guard try await handle.result.failed.isEmpty else { throw APIError.invalidResponse("The photo could not be added to this album.") }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }.disabled(adding)
        }.navigationTitle("Add to album")
            .overlay { if albums.isEmpty && error == nil { ContentUnavailableView("No albums yet", systemImage: "rectangle.stack") } }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { do { albums = try await api.albums() } catch { self.error = error.localizedDescription } }
            .alert("Couldn’t add photo", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { } } message: { Text(error ?? "") }
    }
}

/// A tap on a video page, recognized alongside the swipes and the pager, as a UIKit recognizer:
/// a SwiftUI tap does not reach through the player's surface.
private struct ViewerTap: UIGestureRecognizerRepresentable {
    let action: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> ViewerSwipe.Coordinator { ViewerSwipe.Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let tap = UITapGestureRecognizer()
        tap.delegate = context.coordinator
        return tap
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action() }
    }
}

/// A quick swipe on a video page, recognized alongside the page's other gestures, so a video closes
/// and shows its details with the same swipes as a photo.
private struct ViewerSwipe: UIGestureRecognizerRepresentable {
    let direction: UISwipeGestureRecognizer.Direction
    var enabled = true
    let action: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UISwipeGestureRecognizer {
        let swipe = UISwipeGestureRecognizer()
        swipe.direction = direction
        swipe.delegate = context.coordinator
        swipe.isEnabled = enabled
        return swipe
    }

    func updateUIGestureRecognizer(_ recognizer: UISwipeGestureRecognizer, context: Context) { recognizer.isEnabled = enabled }

    func handleUIGestureRecognizerAction(_ recognizer: UISwipeGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action() }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

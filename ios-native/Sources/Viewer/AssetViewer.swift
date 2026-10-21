import Photos
import SwiftUI

@MainActor
struct AssetViewer: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let assets: [Asset]
    let onUpdated: (Asset) -> Void
    let onDeleted: () -> Void
    let onExploreLocation: ((PlaceFocus) -> Void)?
    let albumID: String?
    let matchedLocalPhotos: [String: LocalPhoto]
    /// Set when the viewer zooms out of a grid cell: it hears which photo is on screen, and the
    /// system's drag to close replaces the viewer's own swipe down.
    let transition: ViewerTransitionState?
    /// Closes the viewer when it was presented outside SwiftUI.
    let onClose: (() -> Void)?
    @ObservedObject private var cast = CastController.shared
    @State private var selectedID: String
    @State private var replacements: [String: Asset] = [:]
    @State private var controls = true
    @State private var info = false
    @State private var editing = false
    /// Edit was tapped before the photo's details said whether it can be edited.
    @State private var editWhenLoaded: String?
    @State private var chooseAlbum = false
    @State private var deleteConfirmation = false
    @State private var deletePermanently = false
    @State private var deletionTarget: Asset?
    @State private var refreshRevision = 0
    @State private var accessRefreshRevision = -1
    @State private var locationPresented = false
    @State private var pendingLocation: PlaceFocus?
    @State private var locationCollection: InfoCollection?
    @State private var error: String?
    /// A change to the photo is running; exports keep their own state.
    @State private var working = false
    /// Share, Download original and Save to Photos.
    @State private var exports: ExportTracker
    @State private var shared: ExportedFiles?
    @State private var playingLive = false
    @State private var slideshow = false
    @State private var sharedLink = false
    @State private var showStack = false
    @State private var albumActivity = false
    @State private var castPresented = false
    @State private var ocrPresented = false
    @State private var similarPresented = false
    @State private var features: ServerFeatures?
    @State private var profilePhoto = false
    @State private var localPhotoActions = false
    @State private var changedLocalCopies: Set<String> = []
    /// Where the bars leave room for the LIVE badge and the video pill, kept while the bars are hidden.
    @State private var chromeInsets = EdgeInsets()
    @State private var playback = VideoPlaybackState()
    /// While the thumbnail strip is scrubbed, pages show what memory has and slow work waits.
    @State private var stripScrubbing = false
    @State private var pagePosition: ScrollPosition
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

    init(api: APIClient, pipeline: MediaPipeline, assets: [Asset], initial: Asset,
         onUpdated: @escaping (Asset) -> Void, onDeleted: @escaping () -> Void, albumID: String? = nil,
         matchedLocalPhotos: [String: LocalPhoto] = [:], onExploreLocation: ((PlaceFocus) -> Void)? = nil,
         transition: ViewerTransitionState? = nil, onClose: (() -> Void)? = nil) {
        self.api = api; self.pipeline = pipeline
        self.assets = assets.contains(where: { $0.id == initial.id }) ? assets : [initial] + assets
        self.onUpdated = onUpdated; self.onDeleted = onDeleted
        self.onExploreLocation = onExploreLocation
        self.albumID = albumID
        self.matchedLocalPhotos = matchedLocalPhotos
        self.transition = transition; self.onClose = onClose
        _selectedID = State(initialValue: initial.id)
        _pagePosition = State(initialValue: ScrollPosition(id: initial.id, anchor: .leading))
        _replacements = State(initialValue: [initial.id: initial])
        _exports = State(initialValue: ExportTracker(api: api))
    }

    private var selectedIndex: Int { assets.firstIndex(where: { $0.id == selectedID }) ?? 0 }
    private var current: Asset { replacements[selectedID] ?? assets[selectedIndex] }
    /// What the photo on screen offers. Every button and menu item renders from it.
    private var capabilities: AssetCapabilities {
        AssetCapabilityPolicy.evaluate(current, context: CapabilityContext(api: api, features: features, album: albumID))
    }
    /// A change or an export is running, so the other actions wait.
    private var busy: Bool { working || exports.isRunning }

    private func matchedLocalCopy(for asset: Asset) -> LocalPhoto? { changedLocalCopies.contains(asset.id) ? nil : matchedLocalPhotos[asset.id] }

    private var canvas: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
            pageChrome
            if let progress = exports.progress, let request = exports.request {
                VStack(spacing: 12) {
                    if let fraction = progress.fraction { ProgressView(value: fraction) } else { ProgressView() }
                    Text(progress.committing ? "Saving to Photos…" : Self.exportLabel(request)).font(.subheadline)
                    if !progress.committing { Button("Cancel") { exports.cancel() }.buttonStyle(.glass).accessibilityIdentifier("viewer.cancelTransfer") }
                }.frame(width: 220).padding(20).glassEffect(in: .rect(cornerRadius: 24))
                    .accessibilityElement(children: .contain)
            } else if working { ProgressView().padding(20).glassEffect(in: .circle).accessibilityLabel("Preparing photo") }
        }
        // The badge and the pill stay where the bars put them while the bars slide away.
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in if controls { chromeInsets = insets } }
        .toolbar { viewerToolbar }
        .toolbarVisibility(controls ? .visible : .hidden, for: .navigationBar, .bottomBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
        .navigationBarTitleDisplayMode(.inline)
        // Monochrome glyphs, as in Photos, whatever the app's accent.
        .tint(.primary)
        // An export is for the photo it started on; one already writing to Photos finishes.
        .onChange(of: selectedID) { if !exports.isCommitting { exports.cancel() } }
        .onDisappear { if !exports.isCommitting { exports.cancel() } }
        .preferredColorScheme(.dark)
        .statusBarHidden(!controls)
        .task { features = try? await api.serverFeatures() }
        .onChange(of: selectedID) { playingLive = false; editWhenLoaded = nil }
        .onChange(of: selectedID, initial: true) {
            // Closing zooms back into the cell of the photo on screen, lined up with the photo.
            transition?.currentID = selectedID
            transition?.aspectRatio = CGFloat(current.aspectRatio)
        }
        // Scrubbing the strip passes many photos; only the one it stops on is refreshed and cast.
        // A photo that can't be cast, such as a locked one, never reaches the TV.
        .task(id: settledID) {
            guard settledID != nil, capabilities.offers(.cast) else { return }
            CastController.shared.select(api: api, asset: current)
        }
        .task(id: (settledID ?? "") + "|" + String(refreshRevision)) { if settledID != nil { await refreshCurrentAsset() } }
        .task(id: settledID) { if settledID != nil { await prefetchNeighbors() } }
        .onReceive(NotificationCenter.default.publisher(for: .ilyichLibraryChanged)) { note in
            guard note.userInfo?["scope"] as? String == api.cacheScope else { return }
            refreshRevision += 1
            if note.userInfo?["accessChanged"] as? Bool == true { accessRefreshRevision = refreshRevision }
        }
    }

    private static let pageGap: CGFloat = 20

    /// The selection once the strip lets go of it.
    private var settledID: String? { stripScrubbing ? nil : selectedID }

    /// Photos lie side by side on one paging strip with a black gap between them, as in Photos.
    /// The strip is one gap wider than the screen, so each page is a photo plus the gap after it.
    /// Pages keep their place while the selection changes, so a swipe never swaps photos mid-drag.
    private var pager: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(assets.enumerated()), id: \.element.id) { index, summary in
                        page(index: index, asset: replacements[summary.id] ?? summary)
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
            .scrollPosition($pagePosition, anchor: .leading)
            .onScrollGeometryChange(for: Int.self) { geometry in
                Int((geometry.contentOffset.x / max(1, geometry.containerSize.width)).rounded())
            } action: { _, page in
                guard pagerPhase != .idle, assets.indices.contains(page) else { return }
                if assets[page].id != selectedID { selectedID = assets[page].id }
            }
            .onScrollPhaseChange { _, phase in pagerPhase = phase }
            // Turning the phone resizes every page while the offset stays, which would land on a
            // photo far away; the strip comes back to the selected photo instead.
            .onChange(of: proxy.size, initial: true) { _, size in
                viewport = size
                pagePosition.scrollTo(id: selectedID, anchor: .leading)
            }
        }
        .ignoresSafeArea()
        // Photos added to or removed from the list must not slide another photo under the viewer.
        .onChange(of: assets.map(\.id)) { pagePosition.scrollTo(id: selectedID, anchor: .leading) }
    }

    @ViewBuilder private func page(index: Int, asset: Asset) -> some View {
        if abs(index - selectedIndex) <= 1 {
            if asset.isVideo {
                videoPage(AuthenticatedVideo(api: api, assetID: asset.id, active: selectedID == asset.id && !stripScrubbing && !(cast.connected && cast.currentAssetID == asset.id),
                                             sourceAsset: asset, matchedLocalPhoto: matchedLocalCopy(for: asset), playback: playback))
            } else if playingLive, selectedID == asset.id, let videoID = asset.livePhotoVideoId {
                videoPage(AuthenticatedVideo(api: api, assetID: videoID, active: !(cast.connected && cast.currentAssetID == asset.id), onEnded: { playingLive = false },
                                             sourceAsset: asset, matchedLocalPhoto: matchedLocalCopy(for: asset), isLivePhotoMotion: true))
            } else {
                ViewerPhoto(pipeline: pipeline, asset: asset, active: selectedID == asset.id, onTap: handlePhotoTap, onDismiss: { if transition == nil { close() } },
                            matchedLocalPhoto: matchedLocalCopy(for: asset), onSwipeUp: { info = true }, settled: !stripScrubbing)
            }
        } else { Color.black }
    }

    private func showPage(_ index: Int) {
        guard assets.indices.contains(index) else { return }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .smooth(duration: 0.3)) {
            pagePosition.scrollTo(id: assets[index].id, anchor: .leading)
        }
    }

    /// The photos either side load before a swipe reaches them, so paging never lands on a spinner.
    private func prefetchNeighbors() async {
        let pixels = Int(max(viewport.width, viewport.height) * displayScale)
        guard pixels > 0 else { return }
        let index = selectedIndex
        for offset in [1, -1, 2] where assets.indices.contains(index + offset) {
            let asset = replacements[assets[index + offset].id] ?? assets[index + offset]
            guard !asset.isVideo else { continue }
            _ = try? await pipeline.image(for: asset, size: .preview, pixelSize: pixels)
            if Task.isCancelled { return }
        }
    }

    private var mediaSheets: some View {
        NavigationStack { canvas }
        .sheet(isPresented: $locationPresented) {
            if let focus = locationFocus {
                NavigationStack {
                    PlacesView(api: api, pipeline: pipeline, onSelect: { place in
                        guard !place.assetIDs.isEmpty else { return }
                        locationCollection = .init(title: place.title, filter: SearchFilter(or: place.assetIDs.map { SearchIDAlternative(id: IDFilter(eq: $0)) }))
                    }, focus: focus)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { locationPresented = false } } }
                    .sheet(item: $locationCollection) { collection in NavigationStack { InfoCollectionView(api: api, pipeline: pipeline, collection: collection) } }
                }
            }
        }
        .sheet(isPresented: $profilePhoto) { NavigationStack { ProfilePhotoCropView(api: api, pipeline: pipeline, asset: current) } }
        .sheet(isPresented: $castPresented) { CastView(api: api, asset: current) }
        .fullScreenCover(isPresented: $ocrPresented) { OCRPhotoReader(api: api, pipeline: pipeline, asset: current) }
        .sheet(isPresented: $similarPresented) { SimilarPhotosView(api: api, pipeline: pipeline, reference: current) }
        .sheet(isPresented: $localPhotoActions) {
            if let photo = matchedLocalPhotos[current.id], !changedLocalCopies.contains(current.id) {
                NavigationStack {
                    LocalPhotoActionsView(photos: [photo]) {
                        changedLocalCopies.insert(current.id); localPhotoActions = false
                    }
                }
            }
        }
    }

    private var detailSheets: some View {
        mediaSheets
        .sheet(isPresented: $info, onDismiss: finishLocationNavigation) { infoSheet }
        .fullScreenCover(isPresented: $editing) {
            PhotoEditor(api: api, pipeline: pipeline, asset: current, onSaved: update)
        }
        .sheet(isPresented: $chooseAlbum) {
            NavigationStack { ViewerAlbumPicker(api: api, assetID: current.id) }
        }
        .fullScreenCover(isPresented: $slideshow) { SlideshowView(api: api, pipeline: pipeline, assets: assets.map { replacements[$0.id] ?? $0 }, initial: current) }
        .sheet(isPresented: $sharedLink) { NavigationStack { SharedLinkEditor(api: api, album: nil, assetIDs: [current.id]) } }
        .sheet(isPresented: $showStack) {
            if let stack = current.stack { NavigationStack { ViewerStackView(api: api, pipeline: pipeline, stackID: stack.id, onUpdated: update, onChanged: onDeleted) } }
        }
        .sheet(isPresented: $albumActivity) {
            if let albumID { NavigationStack { AlbumActivityView(api: api, albumID: albumID, assetID: current.id) } }
        }
        .sheet(item: $shared) { files in
            ShareSheet(urls: files.urls).onDisappear { files.remove() }
        }
    }

    private var infoLocationAction: ((PlaceFocus) -> Void)? {
        guard onExploreLocation != nil else { return nil }
        return { focus in requestLocationNavigation(focus) }
    }
    private var infoSheet: some View {
        NavigationStack {
            AssetInfoView(api: api, pipeline: pipeline, asset: current, onUpdated: update,
                          onExploreLocation: infoLocationAction)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { info = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    var body: some View {
        detailSheets
        // Only the viewer turns with the phone; the rest of the app stays upright.
        .onAppear { OrientationLock.viewerAppeared() }
        .onDisappear { OrientationLock.viewerDisappeared() }
        .alert("Couldn’t complete action", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(error ?? "") }
        .confirmationDialog(deletePermanently ? "Delete permanently?" : "Move to Trash?", isPresented: $deleteConfirmation, titleVisibility: .visible) {
            Button(deletePermanently ? "Delete permanently" : "Move to Trash", role: .destructive) { deleteAsset() }
        } message: {
            Text(deletePermanently ? "This cannot be undone. Photos on your phone are kept." : "You can restore this item from Trash. Photos on your phone are kept.")
        }
    }

    /// The bars, laid out as in Photos: back, the title and the actions menu along the top; Share,
    /// a group of Favorite, Info and Edit, and Delete along the bottom. Glyphs only, in system glass.
    /// Favorite keeps its place for every photo, dimmed where it can't be used.
    @ToolbarContentBuilder private var viewerToolbar: some ToolbarContent {
        let can = capabilities
        ToolbarItem(placement: .topBarLeading) {
            Button("Close", systemImage: "chevron.left") { close() }
        }
        ToolbarItem(placement: .principal) { titleCapsule }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) { actionsMenu(can) }
        ToolbarItem(placement: .bottomBar) {
            Button("Share", systemImage: "square.and.arrow.up") { exportAsset(original: shareFileType != "preview") }
                .disabled(busy || !can.offers(.share))
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItemGroup(placement: .bottomBar) {
            Button(current.isFavorite ? "Remove favorite" : "Favorite", systemImage: current.isFavorite ? "heart.fill" : "heart") { toggleFavorite() }
                .tint(current.isFavorite ? .red : .primary).disabled(!can.offers(.favorite) || busy)
            Button("Info", systemImage: "info.circle") { info = true }.disabled(busy)
            if can.shows(.edit) {
                // Until the photo's details arrive Edit stays lit, so the bar doesn't flicker as
                // photos pass, and a tap waits for them.
                Button("Edit", systemImage: "slider.horizontal.3") { openEditor() }
                    .disabled(!(can.offers(.edit) || can[.edit].awaitsDetails) || busy)
            }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if can.shows(.trash) || can.shows(.deletePermanently) {
            ToolbarItem(placement: .bottomBar) {
                Button("Delete", systemImage: "trash") { requestDeletion() }
                    .disabled(!(can.offers(.trash) || can.offers(.deletePermanently)) || busy)
            }
        }
    }

    /// Every action that has no button of its own, in sections as in the Photos menu.
    private func actionsMenu(_ can: AssetCapabilities) -> some View {
        Menu {
            Section {
                menuItem(.addToAlbum, can, "Add to album", systemImage: "rectangle.stack.badge.plus") { chooseAlbum = true }
                menuItem(.sharedLink, can, "Create shared link", systemImage: "link") { sharedLink = true }
                if let albumID {
                    menuItem(.albumCover, can, "Set album cover", systemImage: "photo.on.rectangle.angled") {
                        let id = current.id
                        run { let _: Album = try await api.request(.patch, path: "albums/\(albumID)", body: ["albumThumbnailAssetId": id]) }
                    }
                }
                menuItem(.comments, can, "Comments and likes", systemImage: "bubble") { albumActivity = true }
            }
            Section {
                Button("Slideshow", systemImage: "play.rectangle") { slideshow = true }
                menuItem(.cast, can, "Cast", systemImage: "tv") { castPresented = true }
                menuItem(.selectText, can, "Select text", systemImage: "text.viewfinder") { ocrPresented = true }
                menuItem(.findSimilar, can, "Find similar photos", systemImage: "photo.on.rectangle.angled") { similarPresented = true }
                // Opening the stack only reads it; the stack's own screen disables what read-only
                // mode stops.
                if let stack = current.stack, can.shows(.stack) {
                    Button("Stack (\(stack.assetCount))", systemImage: "square.stack.3d.up") { showStack = true }
                }
            }
            Section {
                menuItem(.share, can, "Share displayed version", systemImage: "square.and.arrow.up") { exportAsset(original: false) }
                menuItem(.download, can, "Download original", systemImage: "arrow.down.document") { exportAsset(original: true) }
                menuItem(.saveToPhotos, can, "Save to Photos", systemImage: "square.and.arrow.down") { saveToPhotos() }
                if matchedLocalPhotos[current.id] != nil, !changedLocalCopies.contains(current.id) {
                    Button("On this phone", systemImage: "iphone") { localPhotoActions = true }
                }
                menuItem(.openInBrowser, can, "Open in browser", systemImage: "safari") { openURL(api.baseURL.deletingLastPathComponent().appendingPathComponent("photos/\(current.id)")) }
                menuItem(.profilePhoto, can, "Set profile photo", systemImage: "person.crop.circle") { profilePhoto = true }
            }
            if can.shows(.restore) || can.shows(.archive) || can.shows(.lock) {
                Section {
                    menuItem(.restore, can, "Restore from Trash", systemImage: "arrow.uturn.backward") { restoreAsset() }
                    menuItem(.archive, can, current.visibility == .archive ? "Unarchive" : "Archive", systemImage: "archivebox") {
                        changeVisibility(current.visibility == .archive ? .timeline : .archive)
                    }
                    menuItem(.lock, can, current.visibility == .locked ? "Move out of Locked Folder" : "Move to Locked Folder", systemImage: "lock") {
                        changeVisibility(current.visibility == .locked ? .timeline : .locked)
                    }
                }
            }
        } label: { Label("Photo actions", systemImage: "ellipsis") }
            .disabled(busy)
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
            if let focus = locationFocus {
                Button { exploreLocation(focus) } label: { label.contentShape(.capsule) }
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

    private func exploreLocation(_ focus: PlaceFocus) {
        if let onExploreLocation { onExploreLocation(focus) } else { locationPresented = true }
    }

    private var locationFocus: PlaceFocus? {
        guard let latitude = current.exifInfo?.latitude, let longitude = current.exifInfo?.longitude,
              latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return .init(latitude: latitude, longitude: longitude, assetID: current.id)
    }
    private func requestLocationNavigation(_ focus: PlaceFocus) {
        pendingLocation = focus; info = false
    }
    private func finishLocationNavigation() {
        guard let focus = pendingLocation else { return }
        pendingLocation = nil; onExploreLocation?(focus)
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
                if assets.count > 1 {
                    // The strip keeps its room while hidden, so nothing above it moves.
                    ZStack {
                        if controls {
                            ViewerFilmstrip(pipeline: pipeline, assets: assets, replacements: replacements, selectedID: selectedID,
                                            onSelect: jumpFromStrip, onScrubbingChange: { stripScrubbing = $0 })
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

    /// The strip picked a photo: the pager jumps straight to it, as in Photos.
    private func jumpFromStrip(_ id: String) {
        guard id != selectedID, assets.contains(where: { $0.id == id }) else { return }
        selectedID = id
        pagePosition.scrollTo(id: id, anchor: .leading)
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
            .gesture(ViewerSwipe(direction: .up) { info = true })
    }

    private func toggleControls() {
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .smooth(duration: 0.25)) { controls.toggle() }
    }
    private func update(_ asset: Asset) { replacements[asset.id] = asset; onUpdated(asset) }
    private func openEditor() {
        if capabilities.offers(.edit) { editing = true }
        else if capabilities[.edit].awaitsDetails { editWhenLoaded = selectedID }
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    private func handlePhotoTap(_ horizontalFraction: Double) {
        if tapToNavigate && horizontalFraction < 0.33 && selectedIndex > 0 { showPage(selectedIndex - 1) }
        else if tapToNavigate && horizontalFraction > 0.67 && selectedIndex + 1 < assets.count { showPage(selectedIndex + 1) }
        else { toggleControls() }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; working = true
        Task { defer { working = false }; do { try await operation() } catch is CancellationError { } catch { self.error = error.localizedDescription } }
    }
    private func toggleFavorite() {
        guard capabilities.offers(.favorite) else { return }
        let asset = current
        run { update(try await api.updateFavorite(assetID: asset.id, value: !asset.isFavorite)) }
    }
    private func changeVisibility(_ visibility: AssetVisibility) {
        let locking = visibility == .locked || current.visibility == .locked
        guard capabilities.offers(locking ? .lock : .archive) else { return }
        let id = current.id
        run {
            let updated = try await api.updateAsset(id: id, update: .init(visibility: visibility))
            if visibility == .locked {
                await pipeline.forget(assetIDs: [id], revoked: true)
                await TimelineCache.shared.removeAll(scope: api.cacheScope)
                onDeleted(); close()
            } else { update(updated) }
        }
    }
    private func requestDeletion() {
        guard capabilities.offers(.trash) || capabilities.offers(.deletePermanently) else { return }
        let asset = current
        run {
            let latest = try await api.serverFeatures()
            guard asset.id == selectedID else { return }
            features = latest; deletePermanently = asset.isTrashed || !latest.trash
            deletionTarget = asset; deleteConfirmation = true
        }
    }
    private func deleteAsset() {
        guard let asset = deletionTarget, asset.ownerId != nil, asset.ownerId == api.userID else { return }
        let permanently = deletePermanently
        run { try await api.trashAssets(ids: [asset.id], permanently: permanently); onDeleted(); close() }
    }
    private func restoreAsset() {
        guard capabilities.offers(.restore) else { return }
        let id = current.id
        run { _ = try await api.restoreAssets(ids: [id]); onDeleted(); close() }
    }
    private func refreshCurrentAsset() async {
        let id = selectedID, revision = refreshRevision
        let previous = current
        let accessMustBeConfirmed = accessRefreshRevision >= 0 && accessRefreshRevision <= revision
        do {
            if revision > 0 { try await Task.sleep(for: .milliseconds(250)) }
            let asset = try await api.asset(id: id)
            try Task.checkCancellation()
            guard selectedID == id, refreshRevision == revision else { return }
            if (asset.visibility == .locked && previous.visibility != .locked) || (asset.isTrashed && !previous.isTrashed) {
                onDeleted(); close(); return
            }
            replacements[id] = asset
            accessRefreshRevision = -1
            if editWhenLoaded == id { editWhenLoaded = nil; if capabilities.offers(.edit) { editing = true } }
            if asset != previous { onUpdated(asset) }
        } catch is CancellationError { }
        catch {
            guard selectedID == id, refreshRevision == revision, !Task.isCancelled else { return }
            switch error {
            case ServerFailure.forbidden, ServerFailure.notFound:
                onDeleted(); close()
            case ServerFailure.sessionExpired, ServerFailure.proxyRejected:
                // Not a deletion: the photo is most likely still there, and only the session check
                // signs out. A photo whose access must be confirmed still closes.
                if accessMustBeConfirmed { close() }
                else if revision == 0 { self.error = error.localizedDescription }
            default:
                if accessMustBeConfirmed { onDeleted(); close() }
                else if revision == 0 { self.error = error.localizedDescription }
            }
        }
    }
    /// Shares the photo on screen: its original or, with its edits, the version shown. The share
    /// sheet opens only if the photo is still the one on screen.
    private func exportAsset(original: Bool) {
        guard !busy else { return }
        let asset = current
        exports.start(.share([asset], original: original)) { outcome in
            switch outcome {
            case .files(let files): if selectedID == asset.id { shared = files }
            case .failed(let failure, _): error = failure.localizedDescription
            case .saved, .cancelled: break
            }
        }
    }
    private func saveToPhotos() {
        guard !busy, capabilities.offers(.saveToPhotos) else { return }
        exports.start(.saveToPhotos([current], original: false)) { outcome in
            if case .failed(let failure, _) = outcome { error = failure.localizedDescription }
        }
    }
    private static func exportLabel(_ request: ExportRequest) -> String {
        switch request.destination {
        case .photos: "Downloading…"
        case .files: request.original || request.assets.contains(where: \.isVideo) ? "Downloading original…" : "Preparing photo…"
        }
    }
}

private struct ViewerAlbumPicker: View {
    let api: APIClient
    let assetID: String
    @State private var albums: [Album] = []
    @State private var error: String?
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(albums) { album in
            Button(album.albumName) {
                adding = true
                Task {
                    defer { adding = false }
                    do {
                        let results = try await api.addToAlbum(id: album.id, assetIDs: [assetID])
                        guard results.allSatisfy({ $0.success || $0.error == "duplicate" }) else { throw APIError.invalidResponse("The photo could not be added to this album.") }
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

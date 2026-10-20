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
    @ObservedObject private var cast = CastController.shared
    @State private var selectedID: String
    @State private var replacements: [String: Asset] = [:]
    @State private var controls = true
    @State private var info = false
    @State private var editing = false
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
    @State private var working = false
    @State private var export: ViewerExport?
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
    @State private var transferTask: Task<Void, Never>?
    @State private var transferID: UUID?
    @State private var transferLabel = ""
    @State private var transferProgress: Double?
    @State private var transferSaving = false
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
         matchedLocalPhotos: [String: LocalPhoto] = [:], onExploreLocation: ((PlaceFocus) -> Void)? = nil) {
        self.api = api; self.pipeline = pipeline
        self.assets = assets.contains(where: { $0.id == initial.id }) ? assets : [initial] + assets
        self.onUpdated = onUpdated; self.onDeleted = onDeleted
        self.onExploreLocation = onExploreLocation
        self.albumID = albumID
        self.matchedLocalPhotos = matchedLocalPhotos
        _selectedID = State(initialValue: initial.id)
        _pagePosition = State(initialValue: ScrollPosition(id: initial.id, anchor: .leading))
        _replacements = State(initialValue: [initial.id: initial])
    }

    private var selectedIndex: Int { assets.firstIndex(where: { $0.id == selectedID }) ?? 0 }
    private var current: Asset { replacements[selectedID] ?? assets[selectedIndex] }
    private var ownsAsset: Bool { current.ownerId != nil && current.ownerId == api.userID }
    private var canEdit: Bool {
        ownsAsset && current.type == .image && !current.isAnimatedImage && current.livePhotoVideoId == nil && current.exifInfo?.projectionType != "equirectangular" && !["gif", "svg"].contains((current.originalFileName as NSString).pathExtension.lowercased())
    }

    private func matchedLocalCopy(for asset: Asset) -> LocalPhoto? { changedLocalCopies.contains(asset.id) ? nil : matchedLocalPhotos[asset.id] }

    private var canvas: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
            pageChrome
            if transferID != nil {
                VStack(spacing: 12) {
                    if let transferProgress { ProgressView(value: transferProgress) } else { ProgressView() }
                    Text(transferSaving ? "Saving to Photos…" : transferLabel).font(.subheadline)
                    if !transferSaving { Button("Cancel") { cancelTransfer() }.buttonStyle(.glass).accessibilityIdentifier("viewer.cancelTransfer") }
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
        .onChange(of: selectedID) { if !transferSaving { cancelTransfer() } }
        .onDisappear { if !transferSaving { cancelTransfer() } }
        .preferredColorScheme(.dark)
        .statusBarHidden(!controls)
        .task { features = try? await api.serverFeatures() }
        .onChange(of: selectedID) { playingLive = false }
        // Scrubbing the strip passes many photos; only the one it stops on is refreshed and cast.
        .task(id: settledID) {
            guard settledID != nil else { return }
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
                ViewerPhoto(pipeline: pipeline, asset: asset, active: selectedID == asset.id, onTap: handlePhotoTap, onDismiss: { dismiss() },
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
        .sheet(item: $export) { item in
            ViewerShareSheet(url: item.url).onDisappear { item.removeTemporaryFile() }
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
    @ToolbarContentBuilder private var viewerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Close", systemImage: "chevron.left") { dismiss() }
        }
        ToolbarItem(placement: .principal) { titleCapsule }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) { actionsMenu }
        ToolbarItem(placement: .bottomBar) {
            Button("Share", systemImage: "square.and.arrow.up") { exportAsset(original: shareFileType != "preview") }
                .disabled(working)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItemGroup(placement: .bottomBar) {
            Button(current.isFavorite ? "Remove favorite" : "Favorite", systemImage: current.isFavorite ? "heart.fill" : "heart") { toggleFavorite() }
                .requiresWriteAccess(api).tint(current.isFavorite ? .red : .primary).disabled(!ownsAsset || working)
            Button("Info", systemImage: "info.circle") { info = true }.disabled(working)
            if canEdit {
                Button("Edit", systemImage: "slider.horizontal.3") { editing = true }.requiresWriteAccess(api).disabled(working)
            }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if ownsAsset {
            ToolbarItem(placement: .bottomBar) {
                Button("Delete", systemImage: "trash") { requestDeletion() }.requiresWriteAccess(api).disabled(working)
            }
        }
    }

    /// Every action that has no button of its own, in sections as in the Photos menu.
    private var actionsMenu: some View {
        Menu {
            Section {
                Button("Add to album", systemImage: "rectangle.stack.badge.plus") { chooseAlbum = true }.requiresWriteAccess(api)
                Button("Create shared link", systemImage: "link") { sharedLink = true }.requiresWriteAccess(api)
                if let albumID {
                    Button("Set album cover", systemImage: "photo.on.rectangle.angled") {
                        let id = current.id
                        run { let _: Album = try await api.request(.patch, path: "albums/\(albumID)", body: ["albumThumbnailAssetId": id]) }
                    }.requiresWriteAccess(api)
                    Button("Comments and likes", systemImage: "bubble") { albumActivity = true }
                }
            }
            Section {
                Button("Slideshow", systemImage: "play.rectangle") { slideshow = true }
                Button("Cast", systemImage: "tv") { castPresented = true }
                if features?.ocr == true, current.type == .image { Button("Select text", systemImage: "text.viewfinder") { ocrPresented = true } }
                if features?.smartSearch == true { Button("Find similar photos", systemImage: "photo.on.rectangle.angled") { similarPresented = true } }
                if let stack = current.stack { Button("Stack (\(stack.assetCount))", systemImage: "square.stack.3d.up") { showStack = true } }
            }
            Section {
                Button("Share displayed version", systemImage: "square.and.arrow.up") { exportAsset(original: false) }
                Button("Download original", systemImage: "arrow.down.document") { exportAsset(original: true) }
                Button("Save to Photos", systemImage: "square.and.arrow.down") { saveToPhotos() }.requiresWriteAccess(api)
                if matchedLocalPhotos[current.id] != nil, !changedLocalCopies.contains(current.id) {
                    Button("On this phone", systemImage: "iphone") { localPhotoActions = true }
                }
                Button("Open in browser", systemImage: "safari") { openURL(api.baseURL.deletingLastPathComponent().appendingPathComponent("photos/\(current.id)")) }
                if !current.isVideo { Button("Set profile photo", systemImage: "person.crop.circle") { profilePhoto = true }.requiresWriteAccess(api) }
            }
            if ownsAsset {
                Section {
                    if current.isTrashed, features?.trash == true {
                        Button("Restore from Trash", systemImage: "arrow.uturn.backward") { restoreAsset() }.requiresWriteAccess(api)
                    } else if !current.isTrashed {
                        Button(current.visibility == .archive ? "Unarchive" : "Archive", systemImage: "archivebox") { changeVisibility(current.visibility == .archive ? .timeline : .archive) }.requiresWriteAccess(api)
                        Button(current.visibility == .locked ? "Move out of Locked Folder" : "Move to Locked Folder", systemImage: "lock") { changeVisibility(current.visibility == .locked ? .timeline : .locked) }.requiresWriteAccess(api)
                    }
                }
            }
        } label: { Label("Photo actions", systemImage: "ellipsis") }
            .disabled(working)
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
                    .frame(height: ViewerFilmstrip.cell.height)
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
            .gesture(ViewerSwipe(direction: .down) { dismiss() })
            .gesture(ViewerSwipe(direction: .up) { info = true })
    }

    private func toggleControls() {
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .smooth(duration: 0.25)) { controls.toggle() }
    }
    private func update(_ asset: Asset) { replacements[asset.id] = asset; onUpdated(asset) }
    private func handlePhotoTap(_ horizontalFraction: Double) {
        if tapToNavigate && horizontalFraction < 0.33 && selectedIndex > 0 { showPage(selectedIndex - 1) }
        else if tapToNavigate && horizontalFraction > 0.67 && selectedIndex + 1 < assets.count { showPage(selectedIndex + 1) }
        else { toggleControls() }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }; working = true
        Task { defer { working = false }; do { try await operation() } catch is CancellationError { } catch { self.error = error.localizedDescription } }
    }
    private func toggleFavorite() {
        guard ownsAsset else { return }
        let asset = current
        run { update(try await api.updateFavorite(assetID: asset.id, value: !asset.isFavorite)) }
    }
    private func changeVisibility(_ visibility: AssetVisibility) {
        guard ownsAsset else { return }
        let id = current.id
        run {
            let updated = try await api.updateAsset(id: id, update: .init(visibility: visibility))
            if visibility == .locked {
                await pipeline.forget(assetIDs: [id], revoked: true)
                await TimelineCache.shared.removeAll(scope: api.cacheScope)
                onDeleted(); dismiss()
            } else { update(updated) }
        }
    }
    private func requestDeletion() {
        guard ownsAsset else { return }
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
        run { try await api.trashAssets(ids: [asset.id], permanently: permanently); onDeleted(); dismiss() }
    }
    private func restoreAsset() {
        guard ownsAsset, features?.trash == true else { return }
        let id = current.id
        run { _ = try await api.restoreAssets(ids: [id]); onDeleted(); dismiss() }
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
                onDeleted(); dismiss(); return
            }
            replacements[id] = asset
            accessRefreshRevision = -1
            if asset != previous { onUpdated(asset) }
        } catch is CancellationError { }
        catch {
            guard selectedID == id, refreshRevision == revision, !Task.isCancelled else { return }
            switch error {
            case APIError.forbidden, APIError.notFound, APIError.unauthorized:
                onDeleted(); dismiss()
            default:
                if accessMustBeConfirmed { onDeleted(); dismiss() }
                else if revision == 0 { self.error = error.localizedDescription }
            }
        }
    }
    /// Tracked download pipeline for export and Save to Photos only; ordinary mutations keep using `run`.
    /// `working` stays the shared guard, and `transferID` fences late progress and completions.
    private func transfer(label: String, notificationKind: String,
                          _ operation: @escaping @MainActor (UUID, @escaping @Sendable (Double?) -> Void) async throws -> Void) {
        guard !working else { return }
        let id = UUID()
        working = true; transferID = id; transferLabel = label; transferProgress = nil; transferSaving = false
        let report: @Sendable (Double?) -> Void = { value in
            Task { @MainActor in if transferID == id { transferProgress = value } }
        }
        transferTask = Task {
            defer { if transferID == id { finishTransfer() } }
            await TransferNotifications.started(id: id, kind: notificationKind, total: 1)
            guard transferID == id, !Task.isCancelled else { TransferNotifications.cancel(id: id); return }
            do {
                try await operation(id, report)
                guard transferID == id, !Task.isCancelled else { TransferNotifications.cancel(id: id); return }
                await TransferNotifications.finished(id: id, kind: notificationKind, total: 1, completed: 1, failed: 0)
                if Task.isCancelled || transferID != id { TransferNotifications.cancel(id: id) }
            } catch is CancellationError { TransferNotifications.cancel(id: id) }
            catch {
                if transferID == id, !Task.isCancelled {
                    await TransferNotifications.finished(id: id, kind: notificationKind, total: 1, completed: 0, failed: 1)
                    if Task.isCancelled || transferID != id { TransferNotifications.cancel(id: id) }
                    if transferID == id, !Task.isCancelled { self.error = error.localizedDescription }
                } else { TransferNotifications.cancel(id: id) }
            }
        }
    }
    private func finishTransfer() {
        transferTask = nil; transferID = nil; transferProgress = nil; transferSaving = false; working = false
    }
    private func cancelTransfer() {
        guard transferID != nil else { return }
        if let transferID { TransferNotifications.cancel(id: transferID) }
        transferTask?.cancel()
        finishTransfer()
    }
    private func exportAsset(original: Bool) {
        let asset = current
        transfer(label: original || asset.isVideo ? "Downloading original…" : "Preparing photo…", notificationKind: "Download") { id, report in
            let file = ViewerExport(url: try await api.download(asset: asset, original: original, progress: report))
            guard !Task.isCancelled, transferID == id, selectedID == asset.id else { file.removeTemporaryFile(); throw CancellationError() }
            export = file
        }
    }
    private func saveToPhotos() {
        let asset = current
        transfer(label: "Downloading…", notificationKind: "Save to Photos") { id, report in
            try await PhotoLibrarySave.requestPermission(api: api)
            try await PhotoLibrarySave.save(asset, api: api, original: false, progress: report) {
                guard transferID == id else { throw CancellationError() }
                transferSaving = true
            }
        }
    }
}

final class ViewerExport: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    init(url: URL) { self.url = url }
    deinit { removeTemporaryFile() }
    func removeTemporaryFile() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct ViewerShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
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
    let action: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UISwipeGestureRecognizer {
        let swipe = UISwipeGestureRecognizer()
        swipe.direction = direction
        swipe.delegate = context.coordinator
        return swipe
    }

    func handleUIGestureRecognizerAction(_ recognizer: UISwipeGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action() }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

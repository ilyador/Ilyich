import SwiftUI

/// The month is not drawn over the feed; the rail's lens shows it while scrubbing. VoiceOver
/// still finds it at the top as a heading. A separate view, so only this, not the whole library,
/// observes the timeline position.
private struct FeedMonthHeading: View {
    let store: LibraryFeedStore
    var body: some View {
        Text(store.query.isEmpty || store.isSearching ? store.title : "\(store.totalCount.formatted()) matches")
            .font(.caption).foregroundStyle(.clear)
            .accessibilityIdentifier("library.heading").accessibilityAddTraits(.isHeader)
            .accessibilityValue(store.currentPlaceSummary ?? "")
            .allowsHitTesting(false)
            .padding(.leading, 20).padding(.top, 8)
    }
}

struct LibraryView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let session: AccountSession
    @State private var store: LibraryFeedStore
    /// What is presented over the library, following links, shared files and the Earth's warm-up.
    @State private var model: LibraryScreenModel
    @State private var searchText = ""
    @State private var edgeInteraction = LibraryEdgeInteraction()
    /// How the grid moves: its scroll delegate and the rail's finger both drive it (T4).
    @State private var viewport: GridViewport
    /// The time rail's finger, month and lens, which the edge pan drives in its own callback.
    @State private var rail: TimeRailController
    @State private var librarySize: CGSize = .zero
    @State private var shelf: ShelfLevel = .root
    /// The people, albums, features and shelf order the shelves show.
    @State private var collections: CollectionsStore
    @State private var backupStore = BackupStore.shared
    @State private var placesDrag: CGFloat = 0
    /// The name typed for an album made from the selection.
    @State private var albumName = ""
    /// Where each filter pill sits at the top (N6), by layer: a chosen row rises into its pill.
    @State private var pillFrames: [String: CGRect] = [:]
    /// The filter chosen during the current stroke. It applies at once; once the finger lifts, its
    /// row rises into its pill.
    @State private var chosenThisStroke: String?
    /// The pill a row is rising into: the other pills show as the shelves go, this one only once
    /// the row hands over to it.
    @State private var landingPill: String?
    /// The pill a row last rose into, whose content appears at once when it takes over.
    @State private var handedOffPill: String?
    /// What narrows the shelves and the Earth under the filters stacked (N6).
    @State private var narrowing: ShelfNarrowing
    /// The narrowing the shelves show, and whether they offer Clear: taken as they open and as each
    /// group opens, never while a level is under the finger, so no row moves beneath it.
    @State private var shelfFacets: ShelfFacets?
    @State private var shelfClearable = false
    /// A newer open or close makes a pending close stale.
    @State private var closeGeneration = 0
    @State private var selectionBusy = false
    /// Hands the feed what happens to the account's library (N4): its sync's changes, its
    /// mutations' results, made here or on any screen over it, its collections' changes and a
    /// cleared cache.
    @State private var follower = LibraryFollower()
    /// Height of the chips floating at the top: filter, uploads, search checking, selection.
    @State private var chromeHeight: CGFloat = 0
    @State private var shareInbox = ShareInboxStore.shared
    @AppStorage("gridColumns") private var columns = 4
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(AppearanceAccent.storageKey) private var accentName = AppearanceAccent.design.rawValue
    @AppStorage("timelineGrouping") private var timelineGrouping = "month"
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.authorization) private var authorization
    @Environment(\.mutations) private var mutations
    @Environment(\.libraryBus) private var bus
    @Environment(\.collectionsService) private var collectionsService
    @Environment(\.accountSettings) private var accountSettings

    init(api: APIClient, pipeline: MediaPipeline, session: AccountSession) {
        self.api = api; self.pipeline = pipeline; self.session = session
        let repository = session.libraryRepository ?? LibraryRepository(client: api, index: nil, sync: nil)
        // The feeds' month places are kept in the index and fenced by the account's access epoch;
        // the files an earlier build kept are imported once (F5).
        let places = MonthPlacesService(source: repository, store: session.entities, authorization: session.runtime?.authorization,
                                        legacy: session.entities.map { LegacyPlacesImport.live(scope: api.cacheScope, index: $0) })
        let store = LibraryFeedStore(source: repository, includesDevicePhotos: session.environment.usesDevicePhotos,
                                     choices: SearchChoicesStorage(scope: api.cacheScope), places: places)
        _store = State(initialValue: store)
        let viewport = GridViewport()
        _viewport = State(initialValue: viewport)
        _rail = State(initialValue: TimeRailController(feed: store, viewport: viewport))
        _collections = State(initialValue: CollectionsStore(api: api, people: PeopleDirectory(source: api),
                                                               order: ShelfOrder(scope: api.cacheScope), pipeline: pipeline))
        _model = State(initialValue: LibraryScreenModel(lookup: api, inbox: ShareInboxStore.shared))
        _narrowing = State(initialValue: ShelfNarrowing(source: session.entities))
    }

    private var navigator: LibraryNavigator { model.navigator }
    /// The shelves are out. The navigator keeps this beside the Earth, as what covers the grid.
    private var shelves: Bool {
        get { navigator.overlay.shelves }
        nonmutating set { navigator.setShelves(newValue) }
    }
    /// The Earth has risen from the bottom edge.
    private var showPlaces: Bool { navigator.overlay.earth }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                PhotoGrid(store: store, pipeline: pipeline, columns: max(2, min(6, columns)),
                          showsDayHeaders: timelineGrouping == "day",
                          // The first row starts half a photo down, under the fading edge of the status
                          // bar's blur rather than inside it. Floating chips push it below them instead,
                          // so a short result list is never hidden.
                          topInset: chromeHeight > 0 ? geometry.safeAreaInsets.top + chromeHeight + 14
                                                     : photoSide(width: geometry.size.width) / 2,
                          bottomInset: geometry.safeAreaInsets.bottom + 90 + (showsSearchChoices ? Self.choicesRowHeight : 0),
                          onDensityChange: { columns = $0 }, onOpenLocal: { photo in
                    // While typing, a tap on the grid only puts the keyboard away.
                    if searchFocused { searchFocused = false } else { navigator.present(.phoneViewer(photo)) }
                }, viewport: viewport) { asset in
                    if searchFocused { searchFocused = false }
                    else { navigator.present(.viewer(ViewerRoute(asset: asset, source: .feed, albumContext: nil))) }
                }.ignoresSafeArea()
                if store.isLoading && store.totalCount == 0 { ProgressView("Loading library").frame(maxWidth: .infinity, maxHeight: .infinity).environment(\.colorScheme, .dark) }
                if !store.isLoading && store.totalCount == 0 && store.error == nil && !store.isSearching {
                    ContentUnavailableView {
                        Label(store.hasMore ? "Still looking" : store.isFiltered ? "No matching photos" : "Your library is empty", systemImage: "photo.on.rectangle")
                    } description: {
                        Text(store.hasMore ? "More photos are available to check." : store.isFiltered ? "Try a different description or clear the filters." : "Choose photos to back up in Settings.")
                    } actions: {
                        if store.hasMore { Button("Keep looking", action: store.loadMore).buttonStyle(.glass) }
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.colorScheme, .dark)
                }
                edgeBackdrop(size: geometry.size, safeArea: geometry.safeAreaInsets)
                FeedMonthHeading(store: store)
                GlassEffectContainer(spacing: 4) {
                  ZStack(alignment: .topLeading) {
                    if shelves { LibraryShelfBackdrop(interaction: edgeInteraction, onClose: toggleShelves) }
                    VStack(spacing: 0) {
                        topChips
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0 }
                            // The filter shelf hangs from the left edge, never centered.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.top, 8)
                            .environment(\.colorScheme, .dark).foregroundStyle(.white)
                        if let error = store.error { errorBanner(error, retry: store.retryCurrent) }
                        if !store.failedMonths.isEmpty {
                            errorBanner("Some photos couldn’t load.", retry: store.retryFailedBuckets)
                        }
                        Spacer(minLength: 0)
                        if showPlaces {
                            placesPanel(height: geometry.size.height * 0.4 + geometry.safeAreaInsets.bottom, bottomInset: geometry.safeAreaInsets.bottom)
                                .padding(.bottom, -geometry.safeAreaInsets.bottom)
                                .transition(.move(edge: .bottom))
                        } else if store.isSelecting {
                            selectionBar.padding(.horizontal, 16).padding(.bottom, 8).environment(\.colorScheme, .dark)
                        } else {
                            searchBar.padding(.horizontal, 16).padding(.bottom, 8)
                                .environment(\.colorScheme, .dark).foregroundStyle(.white)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        // The Earth rises from the bottom edge and sinks back into it.
                        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.88), value: showPlaces)
                    if shelves {
                        let rearranging = edgeInteraction.isRearranging
                        let items = rearranging ? reorderItems : shelfItems
                        LibraryShelfFan(items: items, geometry: shelfLayout(count: items.count), interaction: edgeInteraction,
                                        size: geometry.size, chromeY: 30,
                                        nested: shelf != .root,
                                        // Done puts the shelves away once the order is set.
                                        onBack: { if rearranging { finishReordering(); closeShelves(feedback: false) } else { openShelf(.root) } },
                                        // A tap that stopped a coasting list does only that.
                                        onClose: { if !edgeInteraction.consumeScrollCatch() { closeShelves() } },
                                        onDrag: { driveShelf(from: $0.startLocation, to: $0.location) },
                                        onDragEnd: { releaseShelf(at: $0.location, velocity: $0.velocity) },
                                        onSelect: perform,
                                        api: api, pipeline: pipeline,
                                        onReorder: canReorder ? { startReordering() } : nil,
                                        reorderTitle: shelf == .people ? "Reorder people" : "Reorder albums",
                                        onMove: { moveShelfRow(from: $0, to: $1) })
                            .environment(\.colorScheme, .dark).foregroundStyle(.white)
                            .onChange(of: edgeInteraction.openReady) { _, row in
                                // The glow at a row's tip peaked while the finger held there.
                                guard let row else { return }
                                edgeInteraction.openReady = nil
                                handleShelfEvent(.open(row), items: shelfItems,
                                                 at: edgeInteraction.shelfFinger ?? CGPoint(x: 0, y: librarySize.height * 0.45))
                            }
                            .onChange(of: edgeInteraction.backReady) { _, ready in
                                // The glow at the left edge peaked while the finger held there.
                                guard ready else { return }
                                edgeInteraction.backReady = false
                                handleShelfEvent(.back, items: shelfItems,
                                                 at: edgeInteraction.shelfFinger ?? CGPoint(x: 0, y: librarySize.height * 0.45))
                            }
                    } else {
                        Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 42).glassEffect(.clear.tint(.black.opacity(0.18)))
                            .environment(\.colorScheme, .dark).foregroundStyle(.white).offset(x: -9)
                            // The edge cue absorbs taps; only a swipe opens it.
                            .contentShape(Rectangle()).onTapGesture { }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .accessibilityLabel("Open shelves").accessibilityHint("Swipe inward from the left edge")
                            .accessibilityAddTraits(.isButton).accessibilityAction { toggleShelves() }
                            .accessibilityIdentifier("library.shelves")
                    }
                  }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.zIndex(1)
                if !shelves && !searchFocused && store.canScrubTimeline && store.query.isEmpty {
                    TimeRail(store: store, rail: rail, pipeline: pipeline, viewportWidth: geometry.size.width)
                        .frame(width: 44).padding(.top, max(52, chromeHeight + 16)).padding(.bottom, showPlaces ? geometry.size.height * 0.42 : 100)
                        .frame(maxWidth: .infinity, alignment: .trailing).zIndex(2)
                }
            }
            .background(.black)
            .coordinateSpace(name: "library")
            .gesture(LibraryEdgePanGesture(size: geometry.size,
                activeY: (chromeHeight + 16)...max(chromeHeight + 16, geometry.size.height - (showPlaces ? geometry.size.height * 0.4
                                                                                                  : 90 + (showsSearchChoices ? Self.choicesRowHeight : 0))),
                leadingEnabled: !shelves,
                // The rail scrubs above the Earth too; its band ends where the Earth begins.
                trailingEnabled: !shelves && store.canScrubTimeline && store.query.isEmpty,
                enabled: navigator.layers.isEmpty && !store.isSelecting && !searchFocused,
                onChange: handleEdgePan))
            .onChange(of: geometry.size, initial: true) { _, size in librarySize = size }
            // Sheets and covers, each presenting the level above it.
            .modifier(PresentationHost(navigator: navigator, level: 0) { route, level in presented(route, level: level) })
            // The viewer zooms out of its grid cell and back into the cell of the photo it closes on.
            .background {
                ViewerZoomPresenter(item: viewerItem, sourceView: { viewport.scroller.zoomSourceView(for: $0, in: store) }, authorization: authorization,
                                    mutations: mutations, bus: bus, collections: collectionsService, settings: accountSettings,
                                    onDismiss: { navigator.layerDidDismiss(level: 0) }) { route, transition, close in
                    AnyView(assetViewer(route, transition: transition, close: close))
                }
            }
            .alert("Couldn’t complete action", isPresented: alertShown { if case .error = $0 { true } else { false } }) {
                Button("OK", role: .cancel) { }
            } message: { Text(errorMessage) }
            .confirmationDialog(deletesSelectionPermanently ? "Permanently delete \(store.selected.count) items?" : "Move \(store.selected.count) items to Trash?", isPresented: alertShown { $0 == .confirm(.deleteSelection) }, titleVisibility: .visible) {
                Button(deletesSelectionPermanently ? "Delete permanently" : "Move to Trash", role: .destructive) {
                    let permanently = deletesSelectionPermanently
                    changeSelection { permanently ? .deletePermanently($0) : .trash($0) }
                }
            } message: { Text(deletesSelectionPermanently ? "This cannot be undone. Photos on your phone are kept." : "This changes the server library. Photos on your phone are kept.") }
            .confirmationDialog("Sign out of Ilyich?", isPresented: alertShown { $0 == .confirm(.signOut) }, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { store.stop(); Task { await session.signOut() } }
            } message: { Text("Backup will stop on this phone. Photos already on your server are kept.") }
            .alert("New album", isPresented: alertShown { $0 == .newAlbumFromSelection }) {
                TextField("Album name", text: $albumName)
                Button("Create") {
                    // The album reaches the shelves from the account's collections; the name is
                    // used, so the next album starts blank.
                    let name = albumName
                    changeSelection({ .createAlbum(name: name, assets: $0) }) { _ in albumName = "" }
                }.disabled(albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { }
            }
        }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .task {
            model.refreshSharedFiles()
            guard !store.started else { return }; store.started = true
            await store.reload(); await collections.load()
        }
        .onAppear {
            connectNavigator()
            model.start()
            followLibrary()
            // The shelves follow the account's collections: changes apply in place, and a sync
            // change to what they show loads them again.
            collections.follow(bus)
            narrowing.follow(bus)
            // A link closes whatever is open, then opens its photo, filter or screen.
            model.takeLinks(from: session) { [collections] in (collections.albums, collections.people) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in Task { await pipeline.trimMemory() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refreshSharedFiles()
                if store.started { collections.reloadIfFailed() }
            }
        }
        // The account's device index places the phone's photos; it follows Photos, backup and
        // the offline library itself, and works only while the app is in front.
        .task(id: session.runtime?.id) {
            guard let index = session.deviceIndex else { return }
            for await snapshot in await index.snapshots() { store.updateDeviceTimeline(snapshot.timeline) }
        }
        .onChange(of: showPlaces) { _, shown in Haptics.earth(rising: shown) }
        // The shelves and the Earth narrow to the filters stacked (N6).
        .onChange(of: store.stack, initial: true) { _, stack in narrowing.show(stack) }
        .onChange(of: showPlaces, initial: true) { _, shown in narrowing.earthShown(shown) }
        .onAppear { PerfScenarioDriver.shared?.attach(store: store, session: session, viewport: viewport, rail: rail) }
        // Everything presented has closed, so shared files that arrived meanwhile can show.
        .onChange(of: navigator.layers.isEmpty) { _, empty in if empty { model.refreshSharedFiles() } }
        .onChange(of: navigator.isViewing) { _, viewing in session.coverage?.conditions.setViewing(viewing) }
        .onAppear {
            // Keeping the library's thumbnails offline waits whenever the user scrolls or scrubs,
            // and for a moment after.
            let session = session
            viewport.onMotionChange = { moving in session.coverage?.conditions.setMoving(moving) }
        }
    }


    /// Hands the feed what happens to the account's library (N4), in the order the bus carries it
    /// (FeedEventApplier). A mutation's result reaches the feed in place; the sync pass after it
    /// reaches the feed as every pass does, and without an offline library the feed reads its
    /// months again. A filter cleared because its album went takes the search text with it. Only
    /// the store, the search text and the feed's refresh rule are held, not this view.
    private func followLibrary() {
        let store = store, refreshes = !(mutations?.followsUp ?? true), searchText = $searchText
        follower.follow(bus) { event in
            if await FeedEventApplier.apply(event, to: store, refreshes: refreshes) { searchText.wrappedValue = "" }
        }
    }

    /// The side of one photo at the current density.
    private func photoSide(width: CGFloat) -> CGFloat {
        let count = CGFloat(max(2, min(6, columns)))
        return max(0, (width - (count - 1)) / count)
    }

    /// The viewer over the feed. It pages through the feed's photos around the one on screen,
    /// in the album it was opened from or else the album the feed shows; exploring a photo's place
    /// is an intent, which closes the viewer and then raises the Earth turned to it (N3).
    private func assetViewer(_ opened: ViewerRoute, transition: ViewerTransitionState, close: @escaping () -> Void) -> some View {
        let route = ViewerRoute(asset: opened.asset, source: opened.source,
                                albumContext: opened.albumContext ?? filteredAlbumID)
        return AssetViewer(api: api, pipeline: pipeline, route: route, window: .feed(store), matchedLocalPhotos: store.matchingDevicePhotos,
                           navigator: navigator, transition: transition, onClose: close)
    }

    /// The viewer shown, until it is asked to close. Closing it from inside, by its button or a
    /// drag, asks the navigator to close it too.
    private var viewerItem: Binding<ViewerRoute?> {
        Binding(get: { navigator.shown(at: 0, style: .zoom).flatMap { layer in
                    if case .viewer(let route) = layer.route { route } else { nil }
                } },
                set: { if $0 == nil, navigator.viewerRoute != nil { navigator.dismiss(level: 0) } })
    }

    /// Whether the alert slot holds an alert `matches` picks. Answering or dismissing it empties
    /// the slot, unless another alert has taken it since.
    private func alertShown(_ matches: @escaping (LibraryAlert) -> Bool) -> Binding<Bool> {
        Binding(get: { navigator.alert.map(matches) ?? false },
                set: { shown in if !shown, let alert = navigator.alert, matches(alert) { navigator.alertDidClose(alert) } })
    }

    private var errorMessage: String {
        if case .error(let message) = navigator.alert { message } else { "" }
    }

    @ViewBuilder private var selectionTitle: some View {
        if store.canSelectMonth {
            let wrapped = dynamicTypeSize.isAccessibilitySize
            Menu {
                Button("Select this month", systemImage: "checkmark.circle") { store.selectMonth(true) }
                Button("Deselect this month", systemImage: "circle") { store.selectMonth(false) }
            } label: {
                HStack(spacing: 6) {
                    Text(store.title).font(.title3.bold()).lineLimit(wrapped ? nil : 1).minimumScaleFactor(wrapped ? 1 : 0.75)
                        .fixedSize(horizontal: false, vertical: wrapped)
                    if store.isSelectingGroup { ProgressView() }
                    else { Image(systemName: "chevron.down").font(.caption.weight(.semibold)) }
                }.padding(.horizontal, 16).frame(minHeight: 44)
                    .glassEffect(.clear.tint(.black.opacity(0.22)).interactive(), in: .capsule)
            }.disabled(store.isSelectingGroup).accessibilityLabel("Selection for \(store.title)")
        }
    }

    /// Selection starts with a long press on a photo; this chip ends it.
    private var selectionHeader: some View {
        HStack(alignment: .center) {
            selectionTitle
            Spacer(minLength: 8)
            Button("Done") { store.isSelecting = false; store.selected = [] }
                .font(.body.weight(.semibold)).padding(.horizontal, 18).frame(minHeight: 44)
                .buttonStyle(.plain)
                .glassEffect(.clear.tint(.black.opacity(0.22)).interactive(), in: .capsule)
                .foregroundStyle((AppearanceAccent(rawValue: accentName) ?? .design).selectionTint)
                .accessibilityIdentifier("library.doneSelecting")
        }
    }

    /// Only state that must stay in view floats over the top of the feed. Without any, the
    /// photos run to the top edge and the month appears only while they move.
    private var topChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.isSelecting { selectionHeader }
            if !pills.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    pillRow.frame(maxWidth: .infinity, alignment: .leading)
                    if let album = filteredAlbum { albumShareButton(album) }
                }
            }
            if let albumID = filteredAlbumID {
                AlbumUploadStatusView(albumID: albumID) { Task { await store.refreshAfterMutation() } }
            }
            // The store keeps a verification only for results a checked search returned.
            if let verification = store.verification {
                verificationView(verification)
            }
        }
    }

    /// The filters at the top, one pill per layer in the order chosen, then a search typed (N6).
    private var pills: [FilterPill] {
        FilterPill.pills(stack: store.stack, feedTitle: store.filterTitle, feedSymbol: feedSymbol, search: store.query,
                         matches: store.isSearching ? nil : store.totalCount)
    }

    /// A feed that is no layer: a partner's, similar photos, More's filtered library.
    private var feedSymbol: String {
        if case .partner = store.feedQuery.scope { return "person.2" }
        return "line.3.horizontal.decrease"
    }

    /// The pills wrap onto a second line rather than hide a layer. While the shelves are out they
    /// are hidden, glass included; as a chosen row rises the others come back, and its own pill
    /// shows once the row hands over to it. A small spinner follows them while the feed changes.
    private var pillRow: some View {
        FilterPillFlow(spacing: 8) {
            ForEach(pills) { pill in
                FilterPillView(pill: pill, hidden: shelves && (landingPill == nil || landingPill == pill.id),
                               instant: reduceMotion || handedOffPill == pill.id, api: api, pipeline: pipeline,
                               onRemove: { removePill(pill) },
                               onOpen: { searchFocused = false; presentShelves(pill.shelf, at: CGPoint(x: 0, y: 34), anchorID: pill.id) },
                               onDrag: { value in
                                   if !shelves { searchFocused = false; presentShelves(pill.shelf, at: value.location, anchorID: pill.id) }
                                   driveShelf(from: value.location, to: value.location)
                               },
                               onDragEnd: { releaseShelf(at: $0.location, velocity: $0.velocity) },
                               onFrame: { pillFrames[pill.id] = $0 })
            }
            if store.isReplacingFeed && !shelves {
                ProgressView().controlSize(.small).frame(width: 28, height: FilterPillLabel.height)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: pills.map(\.id))
        .onChange(of: pills.map(\.id)) { _, ids in
            pillFrames = pillFrames.filter { ids.contains($0.key) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.filterPills")
    }

    /// A pill's X: a layer goes alone, the search typed ends and the layers stay, and a feed that
    /// is no layer gives way to the library.
    private func removePill(_ pill: FilterPill) {
        Haptics.itemChosen()
        switch pill.removal {
        case .layer(let id): store.remove(id); if !store.isFiltered { searchText = "" }
        case .search: searchText = ""; store.search("")
        case .feed: searchText = ""; store.clearFilters()
        }
    }

    /// A glass view in the shared container, content included, ignores any opacity around it, so
    /// a hidden control drops its glass and hides its content inside it.
    private var tagGlass: Glass { shelves ? .identity : .clear.tint(.black.opacity(0.22)).interactive() }

    /// The share button's content hides at once as the shelves come out, and fades in once they
    /// have gone.
    private struct TagContentFade: ViewModifier {
        let hidden: Bool
        let instant: Bool
        func body(content: Content) -> some View {
            content.opacity(hidden ? 0 : 1)
                .animation(hidden || instant ? nil : .easeOut(duration: 0.2), value: hidden)
        }
    }

    /// The album the feed shows when it is the one album among the filters.
    private var filteredAlbumID: String? {
        let albums = store.feedQuery.predicates.albums
        return albums.count == 1 ? albums.first : nil
    }

    private var filteredAlbum: Album? {
        filteredAlbumID.flatMap { id in albums.first { $0.id == id } }
    }

    /// An album in the feed keeps its sharing at hand, across from its title.
    private func albumShareButton(_ album: Album) -> some View {
        Menu {
            Button("Create link", systemImage: "link") { navigator.present(.albumSharing(album, .link)) }
            Button("Share with people", systemImage: "person.badge.plus") { navigator.present(.albumSharing(album, .people)) }
        } label: {
            Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).frame(width: 50, height: 50)
                .modifier(TagContentFade(hidden: shelves, instant: reduceMotion))
        }
        .glassEffect(tagGlass, in: .circle)
        .allowsHitTesting(!shelves)
        .accessibilityLabel("Share album")
        .accessibilityIdentifier("library.shareAlbum")
    }

    private var searchBar: some View {
        VStack(spacing: 10) {
            if store.isSearching {
                // Only a Photo content search with the AI check on is checked by the server.
                HStack(spacing: 12) { ProgressView(); Text(store.checksPhotoContent ? "Checking photo content…" : "Searching…").font(.subheadline); Spacer() }
                    .padding(16).glassEffect(in: .rect(cornerRadius: 20))
                    .accessibilityIdentifier("search.checking")
            }
            HStack(spacing: 12) {
                // The search options are under the bar, behind More; the glass only marks the field.
                Image(systemName: "magnifyingglass").frame(width: 24, height: 44).accessibilityHidden(true)
                TextField("Search photos", text: $searchText,
                          prompt: Text(searchPrompt).foregroundStyle(.white.opacity(0.65)))
                    .focused($searchFocused).submitLabel(.search).onSubmit { store.search(searchText); searchFocused = false }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("library.search")
                if !searchText.isEmpty {
                    Button { searchText = ""; store.search("") } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("Clear search")
                }
            }.padding(.horizontal, 18).frame(minHeight: 58)
                // The whole capsule is the field: a tap on its padding still starts typing.
                .contentShape(.capsule).onTapGesture { searchFocused = true }
                .glassEffect(.clear.tint(.black.opacity(0.28)).interactive(), in: .capsule)
            if showsSearchChoices { searchChoicesRow.transition(.opacity) }
        }
    }

    /// The row under the bar shows while typing, and while the choices apply to what is shown.
    private var showsSearchChoices: Bool { searchFocused || store.choicesApply }
    /// The row and the spacing above it.
    private static let choicesRowHeight: CGFloat = 54

    /// The prompt names the mode, and the feed searched in.
    private var searchPrompt: String {
        let place = store.searchPlaceTitle
        let within = place.map { " in \($0)" } ?? ""
        switch store.searchMode {
        case .context: return place.map { "Search \($0)" } ?? "Describe a moment"
        case .filename: return "Search filenames" + within
        case .description: return "Search descriptions" + within
        case .ocr: return "Search text in photos" + within
        }
    }

    /// The AI check, More, and a chip for each mode and filter chosen there. A chip's tap
    /// removes it. The AI check belongs to Photo content, so another mode's chip takes its place.
    private var searchChoicesRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if store.searchMode == .context { aiCheckSwitch }
                Button { searchFocused = false; navigator.present(.searchOptions) } label: {
                    Label("More", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.clear.tint(.black.opacity(0.28)).interactive(), in: .capsule)
                .accessibilityHint("Search mode and filters")
                .accessibilityIdentifier("search.more")
                ForEach(store.searchChoices.chips(personName: { id in people.first { $0.id == id }?.name })) { chip in
                    Button { Haptics.itemChosen(); store.removeChoice(chip.kind) } label: {
                        HStack(spacing: 7) {
                            Text(chip.title).lineLimit(1)
                            Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                        }
                        .font(.subheadline.weight(.semibold)).padding(.leading, 16).padding(.trailing, 14).frame(minHeight: 44)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    // A choice in force reads cyan, as the filter tag and the AI check do.
                    .glassEffect(.clear.tint(.cyan.opacity(0.2)).interactive(), in: .capsule)
                    .overlay(Capsule().strokeBorder(.cyan.opacity(0.85), lineWidth: 0.75))
                    .accessibilityLabel("Remove \(chip.title)")
                    .accessibilityIdentifier("search.chip.\(chip.kind.rawValue)")
                }
            }.padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden).scrollClipDisabled()
        .frame(height: 44)
    }

    private var aiCheckSwitch: some View {
        let on = store.searchChoices.checksContent
        return Toggle(isOn: Binding(get: { store.searchChoices.checksContent }, set: { Haptics.itemChosen(); store.setChecksContent($0) })) {
            Label { Text("AI check") } icon: { Image(systemName: "sparkles").foregroundStyle(on ? .cyan : .white.opacity(0.7)) }
                .font(.subheadline.weight(.semibold))
        }
        .toggleStyle(.switch).tint(.cyan).fixedSize()
        .padding(.leading, 16).padding(.trailing, 8).frame(minHeight: 44)
        .glassEffect(.clear.tint(.black.opacity(0.28)).interactive(), in: .capsule)
        .accessibilityHint("Checks photo content results with AI")
        .accessibilityIdentifier("search.aiCheck")
    }

    private func verificationView(_ verification: Verification) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: verification.status == .complete ? "checkmark.viewfinder" : "exclamationmark.magnifyingglass")
                .foregroundStyle(.cyan).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(verificationTitle(verification)).font(.subheadline.weight(.semibold))
                Text("\(verification.checked) checked · \(verification.rejected) excluded in this batch")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if verification.canRetry { Button("Retry", action: store.retrySearch).buttonStyle(.glass).disabled(store.isSearching) }
            else if store.hasMore { Button("Check more", action: store.loadMore).buttonStyle(.glass).disabled(store.isSearching) }
        }.padding(14).glassEffect(in: .rect(cornerRadius: 20))
    }

    private func verificationTitle(_ value: Verification) -> String {
        switch value.status {
        case .complete: "Visually checked"
        case .partial: "Some matches still need checking"
        case .unavailable: "Visual checking is unavailable"
        case .notNeeded: "Matched your filters"
        }
    }

    private var selectionBar: some View {
        let selected = store.selectedAssets
        let owned = !selected.isEmpty && selected.allSatisfy { $0.ownerId == api.userID }
        return HStack {
            Text("\(store.selected.count) selected").font(.subheadline.monospacedDigit())
            Spacer()
            if !store.selectedLocalPhotos.isEmpty {
                Button {
                    let localIDs = store.selectedLocalPhotos.map(\.id)
                    Task { _ = await backupStore.enqueue(localIDs: localIDs, albumID: nil) }
                } label: { Image(systemName: "icloud.and.arrow.up").frame(width: 44, height: 44) }
                    .accessibilityLabel("Back up selected phone photos").requiresWriteAccess().disabled(backupStore.isRunning)
            } else if SelectionCapabilities.isTrash(selected) {
                // A Trash selection only comes back or goes for good (N2).
                let can = SelectionCapabilities.evaluate(selected, context: CapabilityContext(api: api, features: features))
                Button { changeSelection { .restore($0) } } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }
                    .accessibilityLabel("Restore selected photos").requiresWriteAccess().disabled(!can.offers(.restore))
                Button(role: .destructive) { navigator.show(.confirm(.deleteSelection)) } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                    .accessibilityLabel("Delete selection permanently").requiresWriteAccess().disabled(!can.offers(.deletePermanently))
            } else {
                Button { navigator.show(.newAlbumFromSelection) } label: { Image(systemName: "rectangle.stack.badge.plus").frame(width: 44, height: 44) }.accessibilityLabel("Create album from selection").requiresWriteAccess()
                Button { changeSelection { .favorite($0, true) } }
                    label: { Image(systemName: "heart").frame(width: 44, height: 44) }.accessibilityLabel("Favorite selected photos").requiresWriteAccess().disabled(!owned)
                Button(role: .destructive) { navigator.show(.confirm(.deleteSelection)) } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel(features?.trash == false ? "Delete selection permanently" : "Move selection to Trash").requiresWriteAccess().disabled(features == nil || !owned)
            }
            Button { navigator.present(.selectionActions(SelectionSnapshot(assets: store.selectedAssets, local: store.selectedDevicePhotos))) } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }.accessibilityLabel("Selection actions")
        }.padding(.horizontal, 14).padding(.vertical, 6).glassEffect().disabled(store.selected.isEmpty || selectionBusy)
    }

    /// The shelves' rows (ShelfCatalog): the account's people and albums in the owner's order, what
    /// the server offers, and what the feed shows.
    private var catalog: ShelfCatalog {
        ShelfCatalog(features: features, people: orderedPeople, albums: orderedAlbums, selection: store.shelfSelection,
                     sharedFiles: !shareInbox.batches.isEmpty, clearable: shelfClearable, facets: shelfFacets)
    }

    private var shelfItems: [LibraryShelfItem] { catalog.rows(shelf) }

    /// Runs a row as its action says. A group opens its shelf in place. A collection joins the
    /// filters shown at once and keeps the shelves open, so another can be stacked without lifting;
    /// a tap closes them now, and either way the row then rises into its pill. Clear removes every
    /// filter and lowers the Earth. Rows that open a screen, the Earth or a question put the
    /// shelves away first.
    private func perform(_ item: LibraryShelfItem) {
        switch item.action {
        case .open(let group):
            openShelf(group)
        case .show(let collection):
            Haptics.itemChosen()
            // The pill stays hidden until the finger lifts.
            store.show(collection); searchText = ""
            if edgeInteraction.isShelfDragging { chosenThisStroke = item.id } else { closeIntoTag(item.id) }
        case .clear:
            Haptics.itemChosen(); closeShelves(feedback: false)
            searchText = ""; store.clearFilters()
            if showPlaces { navigator.lowerEarth() }
        case .places:
            Haptics.itemChosen(); closeShelves(feedback: false)
            if showPlaces { navigator.lowerEarth() } else { openPlaces() }
        case .present(let route):
            Haptics.itemChosen(); closeShelves(feedback: false)
            navigator.present(route)
        case .confirm(let confirmation):
            Haptics.itemChosen(); closeShelves(feedback: false)
            navigator.show(.confirm(confirmation))
        }
    }

    private func edgeBackdrop(size: CGSize, safeArea: EdgeInsets) -> some View {
        // The bleed extends behind system chrome without becoming an oversized
        // ZStack child that pushes the bottom controls off screen.
        Color.clear.frame(width: size.width, height: size.height).overlay(alignment: .topLeading) {
          VStack(spacing: 0) {
            // Photos start under a soft blur behind the status bar, which fades out a little below it.
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .frame(height: safeArea.top + 30)
            Spacer(minLength: 0)
            if !showPlaces {
                Rectangle().fill(.ultraThinMaterial)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                    .frame(height: safeArea.bottom + 110)
            }
        }
        .frame(width: size.width, height: size.height + safeArea.top + safeArea.bottom)
        .offset(y: -safeArea.top)
        .environment(\.colorScheme, .dark)
        }
        .allowsHitTesting(false)
    }

    private func handleEdgePan(_ value: LibraryEdgePan) {
        switch value.edge {
        case .leading:
            switch value.phase {
            case .began:
                // Recognition already means a slight inward swipe: pop out in full, no stretching.
                searchFocused = false
                presentShelves(.root, at: value.location)
                driveShelf(from: value.location, to: value.location)
            case .changed:
                driveShelf(from: value.location, to: value.location)
            case .ended:
                releaseShelf(at: value.location, velocity: value.velocity)
            default:
                if edgeInteraction.isCancelling { closeShelves() } else { edgeInteraction.endStroke() }
            }
        case .trailing:
            // In the gesture's own callback: once the rail is open, the grid moves before this returns.
            rail.handle(value)
        }
    }

    /// The list position lives in the interaction, so only the fan redraws while a long list moves.
    private func shelfLayout(count: Int) -> LibraryShelfGeometry {
        // Rows start below the fan's own Back and Close row at the top.
        LibraryShelfGeometry(count: count, size: librarySize, topInset: 56,
                             bottomInset: 100, rowStep: shelf == .root ? nil : 60)
    }

    /// `anchorID` names the row put under the finger, such as the pill's that brought them back.
    private func presentShelves(_ value: ShelfLevel, at point: CGPoint, anchorID: String? = nil) {
        // People and albums that failed to load, say while the phone reconnected, load again.
        if store.started { collections.reloadIfFailed() }
        // Opening again stops a close still on its way.
        closeGeneration += 1
        landingPill = nil
        edgeInteraction.morphingID = nil; edgeInteraction.morphSize = nil; edgeInteraction.morphX = nil
        edgeInteraction.endStroke()
        narrowing.shelvesOpened()
        takeShelfNarrowing()
        shelf = value
        placeShelf(at: point, anchorID: anchorID)
        // A fan that is not on screen yet draws folded first; it unfolds once it appears.
        if shelves {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84)) { edgeInteraction.shelfReveal = 1 }
        } else {
            edgeInteraction.shelfReveal = 0
        }
        shelves = true
        Haptics.menuOpened()
    }

    /// The shelves narrow to the filters stacked as they open and as each group opens, from the
    /// counts in by then; a level under the finger never changes its rows.
    private func takeShelfNarrowing() {
        shelfFacets = narrowing.facets(for: store.stack)
        shelfClearable = store.isFiltered
    }

    /// Puts the current choice, the shelf just left, or the first row under the finger.
    private func placeShelf(at point: CGPoint, anchorID: String? = nil) {
        let items = shelfItems
        var layout = shelfLayout(count: items.count)
        let anchor = items.firstIndex { $0.id == anchorID } ?? items.firstIndex(where: \.isSelected) ?? layout.openingRow
        layout.top = layout.top(placing: anchor, at: point.y)
        edgeInteraction.shelfTop = layout.top
        edgeInteraction.shelfFinger = CGPoint(x: point.x, y: layout.center(anchor))
        edgeInteraction.highlighted = nil
    }

    /// One finger drives the shelves: sliding highlights, a swipe toward a row's tip opens it,
    /// and holding at the left edge goes back a level. While reordering it carries rows by their handles.
    private func driveShelf(from start: CGPoint, to point: CGPoint) {
        guard shelves else { return }
        if edgeInteraction.isRearranging {
            let layout = shelfLayout(count: reorderItems.count)
            if !edgeInteraction.isShelfDragging { edgeInteraction.beginRearrangeStroke(at: start, in: layout) }
            if edgeInteraction.moveRearrangeStroke(to: point, in: layout) == .back { finishReordering() }
            return
        }
        if !edgeInteraction.isShelfDragging { chosenThisStroke = nil; edgeInteraction.beginStroke(at: start) }
        let items = shelfItems
        handleShelfEvent(edgeInteraction.moveStroke(to: point, in: shelfLayout(count: items.count), nested: shelf != .root,
                                                    reorder: canReorder, selected: selectedRow(in: items)),
                         items: items, at: point)
    }

    /// The row already chosen, which never activates again. With several chosen (N6), the one
    /// under the finger.
    private func selectedRow(in items: [LibraryShelfItem]) -> Int? {
        if let row = edgeInteraction.highlighted, items.indices.contains(row), items[row].isSelected { return row }
        return items.firstIndex(where: \.isSelected)
    }

    private func handleShelfEvent(_ event: LibraryShelfEvent, items: [LibraryShelfItem], at point: CGPoint) {
        switch event {
        case .none: break
        case .back: openShelf(.root, under: point, armed: false, needsReturn: false)
        case .open(let index):
            guard items.indices.contains(index) else { return }
            // A group opened by a swipe opens under the finger, which keeps scrubbing it.
            if case .open(let group) = items[index].action {
                openShelf(group, under: point)
            } else {
                perform(items[index])
            }
        }
    }

    private func openPlaces(focus: PlaceFocus? = nil) {
        Self.raiseEarth(navigator: navigator, placesDrag: $placesDrag, focus: focus)
    }

    /// The Earth slides up only once it is textured, instead of popping in as a blank sphere.
    private static func raiseEarth(navigator: LibraryNavigator, placesDrag: Binding<CGFloat>, focus: PlaceFocus?) {
        navigator.focusEarth(focus)
        Task {
            await PlacesGlobeView.prepare()
            placesDrag.wrappedValue = 0
            navigator.raiseEarth()
        }
    }

    /// Lifting puts the shelves away, and a filter chosen on the way rises into its pill; over the
    /// reorder button it reorders instead. While reordering, lifting drops a carried row or lets the
    /// list coast.
    private func releaseShelf(at point: CGPoint, velocity: CGSize) {
        guard shelves else { return }
        if edgeInteraction.isRearranging {
            if let carried = edgeInteraction.carried {
                moveShelfRow(from: carried.from, to: carried.to)
                edgeInteraction.carried = nil
                edgeInteraction.endStroke()
                edgeInteraction.settleScroll()
            } else {
                // The list coasts on after a flick, or springs back from past an end.
                edgeInteraction.releaseRearrangeStroke(velocity: velocity.height)
            }
            return
        }
        let items = shelfItems
        handleShelfEvent(edgeInteraction.moveStroke(to: point, in: shelfLayout(count: items.count), nested: shelf != .root,
                                                    reorder: canReorder, selected: selectedRow(in: items)),
                         items: items, at: point)
        guard shelves else { return }
        // Lifting the finger puts the shelves away, and a filter chosen on the way rises into its
        // pill; over the reorder button it reorders instead.
        let reorder = canReorder && edgeInteraction.overReorder
        let folded = edgeInteraction.isCancelling
        let chosen = chosenThisStroke
        chosenThisStroke = nil
        edgeInteraction.endStroke()
        edgeInteraction.highlighted = nil
        if reorder { startReordering() }
        else if folded || !keepsShelvesForUITests { closeShelves(into: chosen) }
    }

    /// UI tests tap rows, which needs the shelves to stay out after a stroke lifts.
    private var keepsShelvesForUITests: Bool { session.environment.keepsShelvesOpen }

    private func placesPanel(height: CGFloat, bottomInset: CGFloat) -> some View {
        PlacesView(api: api, pipeline: pipeline, onSelect: selectPlace, focus: navigator.overlay.earthFocus, compact: true, bottomInset: bottomInset,
                   closesPresentations: navigator.earthPresentationClosing, onPresentation: navigator.earthPresentationChanged,
                   narrowing: narrowing.earth)
            .frame(height: height)
            // Zoomed-in terrain fades out under the handle, so the handle always sits above the Earth's edge.
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 38 / height),
                                       .init(color: .black, location: 62 / height)], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .top) { placesHandle }
            .background(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                               .init(color: .black.opacity(0.65), location: 0.3),
                                               .init(color: .black, location: 0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom))
            .offset(y: placesDrag)
    }

    /// Pulling the handle down sinks the Earth with the finger; a short pull springs back.
    private var placesHandle: some View {
        Capsule().fill(.white.opacity(0.7)).frame(width: 36, height: 5)
            .frame(width: 200, height: 40).contentShape(Rectangle())
            // Global coordinates, because the panel itself moves under the finger.
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { placesDrag = max(0, $0.translation.height) }
                .onEnded { value in
                    if value.translation.height > 80 || value.predictedEndTranslation.height > 200 { navigator.lowerEarth() }
                    else { withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) { placesDrag = 0 } }
                })
            .accessibilityElement().accessibilityLabel("Close globe").accessibilityAddTraits(.isButton)
            .accessibilityHint("Swipe down to close.")
            .accessibilityAction { navigator.lowerEarth() }
    }

    /// The screen for a route the navigator presents at `level`: 0 over the library, 1 over a
    /// screen presented there, and so on.
    private func presented(_ route: ModalRoute, level: Int) -> AnyView {
        switch route {
        case .people, .albums, .more, .settings, .searchOptions, .memories, .activity:
            AnyView(NavigationStack {
                screen(route, level: level)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { navigator.dismiss(level: level) } } }
            })
        case .sharedFiles:
            AnyView(ShareInboxView(api: api))
        case .selectionActions(let selection):
            // The feed takes the change from the account's mutations; only the selection ends here.
            AnyView(NavigationStack {
                SelectionActionsView(api: api, pipeline: pipeline, selection: selection) {
                    store.selected = []; store.isSelecting = false
                }
            })
        case .albumSharing(let album, let sharing):
            AnyView(NavigationStack { albumSharing(album, sharing, level: level) })
        case .newAlbum:
            // The album reaches the shelves from the account's collections.
            AnyView(NavigationStack { AlbumEditor(api: api, pipeline: pipeline, album: nil) })
        case .phoneViewer(let photo):
            AnyView(LocalPhotoViewer(photo: photo, photos: store.availableLocalPhotos(around: photo)))
        case .memoryPlayer(let playback):
            AnyView(MemoryPlaybackView(api: api, pipeline: pipeline, memories: playback.memories, initialID: playback.initialID) { intent in
                navigator.send(intent)
            })
        case .viewer:
            // The zoom presenter shows the viewer.
            AnyView(EmptyView())
        }
    }

    @ViewBuilder private func screen(_ route: ModalRoute, level: Int) -> some View {
        switch route {
        case .memories(let initialID):
            MemoriesView(api: api, pipeline: pipeline, onOpenAsset: { navigator.send(.openAsset($0)) },
                         onPlay: { navigator.present(.memoryPlayer($0), from: level + 1) }, initialID: initialID)
        case .activity(let album, let asset):
            AlbumActivityView(api: api, albumID: album, assetID: asset)
        case .searchOptions:
            SearchOptionsView(api: api, mode: store.searchMode, filter: store.searchChoices.filter) { mode, filter in
                store.applySearchOptions(mode: mode, filter: filter)
            }
        // Choosing from Manage people or Manage albums stacks the choice too (N6).
        case .people: PeopleView(api: api, pipeline: pipeline) { store.show(.person($0)); navigator.dismiss(level: level); searchText = "" }
        case .albums: AlbumsView(api: api, pipeline: pipeline) { store.show(.album($0)); navigator.dismiss(level: level); searchText = "" }
        case .settings(let route):
            if let destination = SettingsDestination(rawValue: route.rawValue) {
                SettingsDestinationView(api: api, destination: destination, pipeline: pipeline, session: session)
            } else {
                SettingsView(api: api, pipeline: pipeline, session: session, onSignOut: { store.stop(); Task { await session.signOut() } })
            }
        case .more:
            // A photo opened from More closes it first, then opens in the viewer.
            // Its collections stack as the More shelf's do (N6); a partner's feed is no layer and
            // replaces the filters.
            MoreCollectionsView(api: api, pipeline: pipeline, onOpenAsset: { navigator.send(.openAsset($0)) }, onFilter: { query, title in
                if let collection = LibraryCollection.more(showing: query) { store.show(collection) } else { store.setFeed(query, title: title) }
                searchText = ""; navigator.dismiss(level: level)
            }, onPlayMemory: { navigator.present(.memoryPlayer($0), from: level + 1) })
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func albumSharing(_ album: Album, _ sharing: AlbumSharing, level: Int) -> some View {
        switch sharing {
        case .link: SharedLinkEditor(api: api, album: album)
        case .people:
            // Leaving closes Sharing. The shelves and the feed hear of it from the account's
            // collections: the album goes from the shelves and the filter clears.
            AlbumMembersView(api: api, album: album, onLeft: { navigator.dismiss(level: level) })
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { navigator.dismiss(level: level) } } }
        }
    }

    /// A place chosen on the Earth joins the filters, taking the place of one already there (N6).
    private func selectPlace(_ place: PlaceCollection) {
        store.add(.place(place.membership, title: place.title)); searchText = ""
    }

    /// Hands the navigator what runs once everything over the library has closed: the timeline,
    /// a filter or the Earth. It keeps the feed, the search text and the Earth's drag, not this
    /// screen, so the screen model never holds the view.
    private func connectNavigator() {
        navigator.perform = { [store = store, weak navigator = model.navigator, searchText = $searchText, placesDrag = $placesDrag] intent in
            switch intent {
            case .showInTimeline(let asset): searchText.wrappedValue = ""; store.showInTimeline(asset)
            case .exploreLocation(let focus):
                if let navigator { Self.raiseEarth(navigator: navigator, placesDrag: placesDrag, focus: focus) }
            case .showAlbum(let album): store.setAlbum(album)
            case .showPerson(let person): store.setPerson(person)
            case .present, .openAsset, .alert: break
            }
        }
    }
    private func errorBanner(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack { Text(message).font(.caption); Spacer(); Button("Retry", action: retry) }
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 16).padding(.top, 8)
    }
    private func toggleShelves() {
        searchFocused = false
        if shelves { closeShelves() } else { presentShelves(.root, at: CGPoint(x: 0, y: librarySize.height * 0.45)) }
    }
    /// Closes once the pills have laid out a filter chosen by a tap, so its row can rise into its
    /// pill.
    private func closeIntoTag(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            closeShelves(feedback: false, into: id)
        }
    }

    /// The rows slide back into the edge, then the shelves go. A filter chosen on the way rises
    /// into its pill instead (N6): the whole column scrolls up until that row is level with the
    /// pill's place, the next one along the pills, while the other rows slide out completely and
    /// the other pills come back; the row slides over into the place as it takes the pill's shape.
    private func closeShelves(feedback: Bool = true, into chosen: String? = nil) {
        guard shelves else { return }
        if feedback { Haptics.menuClosed() }
        edgeInteraction.endStroke(); edgeInteraction.highlighted = nil
        edgeInteraction.carried = nil; edgeInteraction.isRearranging = false
        closeGeneration += 1
        let generation = closeGeneration
        let items = shelfItems
        // Only a filter shown has a pill to rise into.
        let target = chosen.flatMap { id in store.shelfSelection.rows.contains(id) ? pillFrames[id] : nil }
        let rising = target == nil ? nil : chosen.flatMap { id in items.firstIndex { $0.id == id } }
        var layout = shelfLayout(count: items.count)
        layout.top = edgeInteraction.shelfTop
        let morphing = rising != nil && (target?.height ?? 0) > 0
        if morphing { handedOffPill = chosen }
        landingPill = morphing ? chosen : nil
        let finish = {
            guard generation == closeGeneration else { return }
            // A row that rose into its pill already looks exactly like it, so the pill takes over
            // in the same frame.
            withAnimation(reduceMotion || morphing ? nil : .easeOut(duration: 0.14)) { shelves = false; shelf = .root }
            landingPill = nil
            edgeInteraction.morphingID = nil; edgeInteraction.morphSize = nil; edgeInteraction.morphX = nil
        }
        // A rising row moves on a softer spring with a little give.
        let motion: Animation = morphing ? .spring(response: 0.5, dampingFraction: 0.8) : .spring(response: 0.3, dampingFraction: 0.9)
        withAnimation(reduceMotion ? nil : motion) {
            if let rising, morphing, let target {
                edgeInteraction.morphingID = items[rising].id
                edgeInteraction.morphSize = target.size
                edgeInteraction.morphX = target.minX
                edgeInteraction.shelfTop -= layout.center(rising) - target.midY
            }
            edgeInteraction.shelfReveal = 0
        } completion: {
            if !morphing || reduceMotion { finish() }
        }
        // By 0.6 s the spring has settled to within a point, so the row hands over then rather
        // than waiting out the spring's long tail.
        if morphing && !reduceMotion {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                finish()
            }
        }
    }

    private var canReorder: Bool { shelf == .people || shelf == .albums }
    private var people: [Person] { collections.people }
    private var albums: [Album] { collections.albums }
    private var features: ServerFeatures? { collections.features }
    private var orderedPeople: [Person] { collections.orderedPeople }
    private var orderedAlbums: [Album] { collections.orderedAlbums }
    /// Only the people or albums themselves move; New album and Manage stay at the end.
    private var reorderItems: [LibraryShelfItem] {
        shelfItems.filter { $0.id.hasPrefix(shelf == .people ? "person-" : "album-") }
    }

    /// The rows line up in place, each with its handle. A swipe that loaded reordering keeps
    /// going: it scrolls the list, and the left edge finishes.
    private func startReordering() {
        guard canReorder, !edgeInteraction.isRearranging else { return }
        edgeInteraction.highlighted = nil
        Haptics.reorderStarted()
        var layout = shelfLayout(count: reorderItems.count)
        layout.top = edgeInteraction.shelfTop
        animate {
            edgeInteraction.isRearranging = true
            // Without New album and Manage, a list scrolled to its end settles back into place.
            edgeInteraction.shelfTop = layout.clampedTop(edgeInteraction.shelfTop)
        }
    }

    private func finishReordering() {
        guard edgeInteraction.isRearranging else { return }
        Haptics.menuClosed()
        edgeInteraction.carried = nil
        animate { edgeInteraction.isRearranging = false }
    }

    private func moveShelfRow(from: Int, to: Int) {
        if collections.moveRow(from: from, to: to, of: shelf == .people ? .people : .albums) { Haptics.rowDropped() }
    }
    /// A group opens with its choice or first row where the group's own row was; going back puts
    /// the group's row there. Mid-swipe both happen under the finger, which keeps scrubbing the new
    /// level without lifting.
    private func openShelf(_ value: ShelfLevel, under finger: CGPoint? = nil, armed: Bool = true, needsReturn: Bool = true) {
        edgeInteraction.carried = nil; edgeInteraction.isRearranging = false
        let left = shelf
        let items = shelfItems
        var layout = shelfLayout(count: items.count)
        layout.top = edgeInteraction.shelfTop
        let groupRow = items.firstIndex { $0.id == value.rowID }
        let y = finger?.y ?? groupRow.map { layout.center($0) } ?? edgeInteraction.shelfFinger?.y ?? librarySize.height * 0.45
        if value == .root { Haptics.menuClosed() } else { Haptics.menuOpened() }
        animate {
            takeShelfNarrowing()
            shelf = value
            placeShelf(at: CGPoint(x: finger?.x ?? 0, y: y), anchorID: value == .root ? left.rowID : nil)
        }
        if let finger { edgeInteraction.rebase(at: finger, armed: armed, in: shelfLayout(count: shelfItems.count), needsReturn: needsReturn) }
    }
    private func animate(_ changes: () -> Void) { withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88), changes) }
    /// The selection is deleted for good: the server keeps no Trash, or the photos are in it, as
    /// they are in the Trash's feed and searches inside it. Read from the feed rather than the
    /// selected photos, which the library's body would otherwise go through on every update.
    private var deletesSelectionPermanently: Bool { features?.trash == false || store.feedQuery.trash == .trashed }
    /// Has the account's mutations make `request` of the selected photos. The selection ends once
    /// the server has made the change, and the feed takes the change in place from the result.
    private func changeSelection(_ request: ([String]) -> MutationRequest, then: @escaping @MainActor (MutationResult) -> Void = { _ in }) {
        guard !selectionBusy else { return }
        guard let mutations else { return navigator.show(.error(APIError.signedOut.localizedDescription)) }
        let handle = mutations.start(request(Array(store.selected)), on: store.selectedAssets)
        selectionBusy = true
        Task {
            defer { selectionBusy = false }
            do {
                let result = try await handle.result
                then(result)
                guard result.failed.isEmpty else {
                    // The photos the server changed are out of the selection with the change made.
                    store.selected.subtract(result.succeeded)
                    return navigator.show(.error("\(result.failed.count.formatted()) of the selected photos couldn’t be changed."))
                }
                store.selected = []; store.isSelecting = false
            }
            catch { navigator.show(.error(error.localizedDescription)) }
        }
    }
}

private struct SelectionActionsView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let selection: SelectionSnapshot
    let onChanged: () -> Void
    var body: some View {
        if selection.local.isEmpty {
            BulkActionsView(api: api, pipeline: pipeline, assets: selection.assets, onChanged: onChanged)
        } else if selection.assets.isEmpty {
            LocalPhotoActionsView(photos: selection.local) { _ in onChanged() }
        } else {
            List {
                NavigationLink("\(selection.assets.count) server photos") {
                    BulkActionsView(api: api, pipeline: pipeline, assets: selection.assets, onChanged: onChanged)
                }
                NavigationLink("\(selection.local.count) phone photos") {
                    LocalPhotoActionsView(photos: selection.local) { _ in onChanged() }
                }
            }.navigationTitle("Selection actions")
        }
    }
}

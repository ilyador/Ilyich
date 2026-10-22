import SwiftUI

/// The month is not drawn over the feed; the rail's lens shows it while scrubbing. VoiceOver
/// still finds it at the top as a heading. A separate view, so only this, not the whole library,
/// observes the timeline position.
private struct FeedMonthHeading: View {
    let store: LibraryStore
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
    @State private var store: LibraryStore
    /// What is presented over the library, following links, shared files and the Earth's warm-up.
    @State private var model: LibraryScreenModel
    @State private var searchText = ""
    @State private var edgeInteraction = LibraryEdgeInteraction()
    @State private var librarySize: CGSize = .zero
    @State private var shelf: Shelf = .root
    /// The people, albums, features and shelf order the shelves show.
    @State private var collections: CollectionsStore
    @State private var backupStore = BackupStore.shared
    @State private var placesDrag: CGFloat = 0
    /// The name typed for an album made from the selection.
    @State private var albumName = ""
    /// Where the filter tag sits at the top, which a chosen person or album rises into.
    @State private var filterTagFrame: CGRect = .zero
    /// The filter chosen during the current stroke. It applies at once; once the finger lifts, a
    /// person or album rises into the filter tag.
    @State private var chosenThisStroke: String?
    /// A row is rising into the tag, so the tag's content appears at once when it takes over.
    @State private var tagHandoff = false
    /// A newer open or close makes a pending close stale.
    @State private var closeGeneration = 0
    @State private var selectionBusy = false
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

    private enum Shelf { case root, people, albums, more, settings }

    init(api: APIClient, pipeline: MediaPipeline, session: AccountSession) {
        self.api = api; self.pipeline = pipeline; self.session = session
        let repository = session.libraryRepository ?? LibraryRepository(client: api, index: nil, sync: nil)
        // The feeds' month places are kept in the index and fenced by the account's access epoch;
        // the files an earlier build kept are imported once (F5).
        let places = MonthPlacesService(source: repository, store: session.entities, authorization: session.runtime?.authorization,
                                        legacy: session.entities.map { LegacyPlacesImport.live(scope: api.cacheScope, index: $0) })
        _store = State(initialValue: LibraryStore(source: repository, includesDevicePhotos: session.environment.usesDevicePhotos,
                                                     choices: SearchChoicesStorage(scope: api.cacheScope), places: places))
        _collections = State(initialValue: CollectionsStore(api: api, people: PeopleDirectory(source: api),
                                                               order: ShelfOrder(scope: api.cacheScope), pipeline: pipeline))
        _model = State(initialValue: LibraryScreenModel(lookup: api, inbox: ShareInboxStore.shared))
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
                }) { asset in
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
                        if !store.bucketErrors.isEmpty {
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
                    TimeRail(store: store, pipeline: pipeline, viewportWidth: geometry.size.width, interaction: edgeInteraction)
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
                ViewerZoomPresenter(item: viewerItem, sourceView: { store.zoomSourceView(for: $0) }, authorization: authorization,
                                    onDismiss: { navigator.layerDidDismiss(level: 0) }) { asset, transition, close in
                    AnyView(assetViewer(asset, transition: transition, close: close))
                }
            }
            .alert("Couldn’t complete action", isPresented: alertShown { if case .error = $0 { true } else { false } }) {
                Button("OK", role: .cancel) { }
            } message: { Text(errorMessage) }
            .confirmationDialog(features?.trash == false ? "Permanently delete \(store.selected.count) items?" : "Move \(store.selected.count) items to Trash?", isPresented: alertShown { $0 == .confirm(.deleteSelection) }, titleVisibility: .visible) {
                Button(features?.trash == false ? "Delete permanently" : "Move to Trash", role: .destructive) {
                    let permanently = features?.trash == false
                    runSelection { ids in try await api.trashAssets(ids: ids, permanently: permanently); store.removeLocally(Set(ids)) }
                }
            } message: { Text(features?.trash == false ? "This cannot be undone. Photos on your phone are kept." : "This changes the server library. Photos on your phone are kept.") }
            .confirmationDialog("Sign out of Ilyich?", isPresented: alertShown { $0 == .confirm(.signOut) }, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { store.stop(); Task { await session.signOut() } }
            } message: { Text("Backup will stop on this phone. Photos already on your server are kept.") }
            .alert("New album", isPresented: alertShown { $0 == .newAlbumFromSelection }) {
                TextField("Album name", text: $albumName)
                Button("Create") {
                    let name = albumName
                    runSelection { ids in _ = try await api.createAlbum(name: name, assetIDs: ids) }
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
            // A link closes whatever is open, then opens its photo, filter or screen.
            model.takeLinks(from: session) { [collections] in (collections.albums, collections.people) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in Task { await pipeline.trimMemory() } }
        .onReceive(NotificationCenter.default.publisher(for: .ilyichCachesReset)) { notification in
            if notification.userInfo?["scope"] as? String == api.cacheScope { Task { await store.refreshAfterMutation() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ilyichLibraryChanged)) { notification in
            guard notification.userInfo?["scope"] as? String == api.cacheScope else { return }
            let change = notification.userInfo?["change"] as? LibraryChange
            Task {
                // The feed applies the change in place: what it removed leaves at once and only the
                // months it touched are read again. A search with text is not read again.
                if let change { await store.apply(change) }
                else if store.query.isEmpty { await store.reload(preservingPosition: true) }
                if notification.userInfo?["collections"] as? Bool == true { await collections.load() }
            }
        }
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
        .onAppear { PerfScenarioDriver.shared?.attach(store: store, session: session) }
        // Everything presented has closed, so shared files that arrived meanwhile can show.
        .onChange(of: navigator.layers.isEmpty) { _, empty in if empty { model.refreshSharedFiles() } }
        .onChange(of: navigator.isViewing) { _, viewing in session.coverage?.conditions.setViewing(viewing) }
        .onAppear {
            // Keeping the library's thumbnails offline waits whenever the user scrolls or scrubs,
            // and for a moment after.
            let session = session
            store.navigation.onMotionChange = { moving in session.coverage?.conditions.setMoving(moving) }
        }
    }


    /// The side of one photo at the current density.
    private func photoSide(width: CGFloat) -> CGFloat {
        let count = CGFloat(max(2, min(6, columns)))
        return max(0, (width - (count - 1)) / count)
    }

    private func assetViewer(_ asset: Asset, transition: ViewerTransitionState, close: @escaping () -> Void) -> some View {
        // Exploring the photo's place closes the viewer, then raises the Earth turned to it.
        AssetViewer(api: api, pipeline: pipeline, assets: store.availableAssets(around: asset), initial: asset,
                    onUpdated: store.update, onDeleted: { store.removeLocally([transition.currentID]); Task { await store.refreshAfterMutation() } },
                    albumID: navigator.viewerRoute?.albumContext ?? store.feedQuery.predicates.albums.first,
                    matchedLocalPhotos: store.matchingDevicePhotos, onExploreLocation: { navigator.send(.exploreLocation($0)) },
                    transition: transition, onClose: close)
    }

    /// The photo the viewer shows, until it is asked to close. Closing it from inside, by its
    /// button or a drag, asks the navigator to close it too.
    private var viewerItem: Binding<Asset?> {
        Binding(get: { navigator.shown(at: 0, style: .zoom).flatMap { layer in
                    if case .viewer(let route) = layer.route { route.asset } else { nil }
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
            if store.isFiltered {
                HStack(spacing: 8) {
                    filterTab
                    clearFilterButton
                    Spacer(minLength: 0)
                    if let album = filteredAlbum { albumShareButton(album) }
                }
                // While the shelves are out the choice shows on them; the tag returns once they
                // have closed, after a chosen row has risen into its place.
                .opacity(shelves ? 0 : 1)
                .allowsHitTesting(!shelves)
            }
            if let albumID = store.feedQuery.predicates.albums.first {
                AlbumUploadStatusView(albumID: albumID) { Task { await store.refreshAfterMutation() } }
            }
            // The store keeps a verification only for results a checked search returned.
            if let verification = store.verification {
                verificationView(verification)
            }
        }
    }

    /// The active filter sits at the top as its own shelf. Dragging it brings back its shelves
    /// with the current choice under the finger; tapping it opens them in place.
    private var filterTab: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 25, topTrailingRadius: 25)
        return HStack(spacing: 10) {
            filterTabIcon.frame(width: 34, height: 34)
            Text(store.filterTitle ?? store.query).font(.subheadline.weight(.semibold)).lineLimit(1)
            if !store.query.isEmpty && !store.isSearching {
                Text(store.totalCount.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.cyan)
                    .accessibilityLabel("\(store.totalCount.formatted()) matches")
            }
            if store.isReplacingFeed { ProgressView().controlSize(.small) }
        }
        .modifier(TagContentFade(hidden: shelves, instant: tagHandoff || reduceMotion))
        .padding(.leading, 16).padding(.trailing, 18).frame(minHeight: 50)
        .glassEffect(tagGlass, in: shape)
        .overlay(shape.strokeBorder(.cyan.opacity(0.85), lineWidth: 0.75))
        // The glass itself, which a rising row matches exactly; the padding below pulls it to the edge.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("library")) } action: { filterTagFrame = $0 }
        .contentShape(shape)
        .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("library")).onChanged { value in
            if !shelves { searchFocused = false; presentShelves(filterShelf, at: value.location) }
            driveShelf(from: value.location, to: value.location)
        }.onEnded { value in
            releaseShelf(at: value.location, velocity: value.velocity)
        })
        .onTapGesture { searchFocused = false; presentShelves(filterShelf, at: CGPoint(x: 0, y: 34)) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.filterShelf")
        .accessibilityAction(named: "Show shelves") { presentShelves(filterShelf, at: CGPoint(x: 0, y: 34)) }
        .padding(.leading, -16)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Clearing the filter is a round button of its own beside the tag.
    private var clearFilterButton: some View {
        Button { Haptics.itemChosen(); searchText = ""; store.clearFilters() } label: {
            Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 50, height: 50)
                .modifier(TagContentFade(hidden: shelves, instant: reduceMotion))
        }
        .glassEffect(tagGlass, in: .circle)
        .accessibilityLabel("Clear filters")
    }

    /// A glass view in the shared container, content included, ignores any opacity around it.
    /// While the shelves are out the tag row therefore drops its glass and hides its content
    /// inside it; otherwise the hidden tag and its buttons would still show.
    private var tagGlass: Glass { shelves ? .identity : .clear.tint(.black.opacity(0.22)).interactive() }

    /// The tag's content hides at once as the shelves come out, and fades in once they have gone.
    /// After a row has risen into the tag it is there at once, as the row already showed it.
    private struct TagContentFade: ViewModifier {
        let hidden: Bool
        let instant: Bool
        func body(content: Content) -> some View {
            content.opacity(hidden ? 0 : 1)
                .animation(hidden || instant ? nil : .easeOut(duration: 0.2), value: hidden)
        }
    }

    private var filteredAlbum: Album? {
        store.feedQuery.predicates.albums.first.flatMap { id in albums.first { $0.id == id } }
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
        .accessibilityLabel("Share album")
        .accessibilityIdentifier("library.shareAlbum")
    }

    @ViewBuilder private var filterTabIcon: some View {
        if let id = store.feedQuery.predicates.people.first, let person = people.first(where: { $0.id == id }) {
            PersonThumbnail(pipeline: pipeline, person: person, pixelSize: PersonThumbnail.small)
        } else if let id = store.feedQuery.predicates.albums.first, let assetID = albums.first(where: { $0.id == id })?.albumThumbnailAssetId {
            FeatureThumbnail(api: api, pipeline: pipeline, assetID: assetID).clipShape(.circle)
        } else {
            let symbol = store.feedQuery.predicates.people.first != nil ? "person.crop.circle"
                : store.feedQuery.predicates.albums.first != nil ? "rectangle.stack"
                : !store.query.isEmpty ? "magnifyingglass"
                : shelfItems(for: .more).first(where: \.isSelected)?.symbol ?? "line.3.horizontal.decrease"
            Image(systemName: symbol).font(.body.weight(.semibold))
        }
    }

    private var filterShelf: Shelf {
        if store.feedQuery.predicates.people.first != nil { return .people }
        if store.feedQuery.predicates.albums.first != nil { return .albums }
        return shelfItems(for: .more).contains(where: \.isSelected) ? .more : .root
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
        HStack {
            Text("\(store.selected.count) selected").font(.subheadline.monospacedDigit())
            Spacer()
            if store.selectedLocalPhotos.isEmpty {
            Button { navigator.show(.newAlbumFromSelection) } label: { Image(systemName: "rectangle.stack.badge.plus").frame(width: 44, height: 44) }.accessibilityLabel("Create album from selection").requiresWriteAccess()
            Button { runSelection { ids in try await api.requestVoid(.put, path: "assets", body: SelectionUpdate(ids: ids, isFavorite: true)) } }
                label: { Image(systemName: "heart").frame(width: 44, height: 44) }.accessibilityLabel("Favorite selected photos").requiresWriteAccess().disabled(!ownsSelection)
            Button(role: .destructive) { navigator.show(.confirm(.deleteSelection)) } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel(features?.trash == false ? "Delete selection permanently" : "Move selection to Trash").requiresWriteAccess().disabled(features == nil || !ownsSelection)
            } else {
                Button {
                    let localIDs = store.selectedLocalPhotos.map(\.id)
                    Task { _ = await backupStore.enqueue(localIDs: localIDs, albumID: nil) }
                } label: { Image(systemName: "icloud.and.arrow.up").frame(width: 44, height: 44) }
                    .accessibilityLabel("Back up selected phone photos").requiresWriteAccess().disabled(backupStore.isRunning)
            }
            Button { navigator.present(.selectionActions(SelectionSnapshot(assets: store.selectedAssets, local: store.selectedDevicePhotos))) } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }.accessibilityLabel("Selection actions")
        }.padding(.horizontal, 14).padding(.vertical, 6).glassEffect().disabled(store.selected.isEmpty || selectionBusy)
    }

    private var shelfTitle: String {
        switch shelf {
        case .root: "Shelves"
        case .people: "People"
        case .albums: "Albums"
        case .more: "More"
        case .settings: "Settings"
        }
    }

    private var shelfItems: [LibraryShelfItem] { shelfItems(for: shelf) }

    /// Group rows open their shelf in place. Filters apply and keep the shelves open, so another
    /// can be tried without lifting; rows that open a screen or the Earth put the shelves away.
    private func shelfItems(for shelf: Shelf) -> [LibraryShelfItem] {
        var items: [LibraryShelfItem] = []
        func add(_ id: String, _ title: String, _ symbol: String, detail: String? = nil, person: Person? = nil, assetID: String? = nil, selected: Bool = false, opens group: Shelf? = nil, filters: Bool = false, action: @escaping () -> Void = {}) {
            let run: () -> Void = group.map { group in { openShelf(group) } } ?? {
                Haptics.itemChosen()
                if !filters { closeShelves(feedback: false); action(); return }
                // A filter applies at once, so the feed shows it while the finger stays down. The
                // tag stays hidden until the finger lifts; a tap closes now. Either way a person
                // or album then rises into the tag.
                action()
                if edgeInteraction.isShelfDragging { chosenThisStroke = id } else { closeIntoTag(id) }
            }
            items.append(.init(id: id, title: title, symbol: symbol, detail: detail, person: person, assetID: assetID, isSelected: selected, action: run))
        }
        switch shelf {
        case .root:
            if features?.facialRecognition != false {
                add("people", "People", "person.2", detail: people.isEmpty ? nil : people.count.formatted(), opens: .people)
            }
            if features?.map != false {
                add("places", "Places", "globe.europe.africa") { if showPlaces { navigator.lowerEarth() } else { openPlaces() } }
            }
            add("albums", "Albums", "rectangle.stack", detail: albums.isEmpty ? nil : albums.count.formatted(), opens: .albums)
            add("more", "More", "ellipsis", opens: .more)
            add("settings", "Settings", "gearshape", opens: .settings)
        case .people:
            for person in orderedPeople {
                add("person-" + person.id, person.name.isEmpty ? "Unnamed person" : person.name, "person.crop.circle", person: person, selected: store.feedQuery.predicates.people.first == person.id, filters: true) {
                    if store.feedQuery.predicates.people.first != person.id { store.setPerson(person) }; searchText = ""
                }
            }
            add("all-people", "Manage people", "person.2") { navigator.present(.people) }
        case .albums:
            for album in orderedAlbums {
                add("album-" + album.id, album.albumName, "rectangle.stack", detail: album.assetCount.formatted(), assetID: album.albumThumbnailAssetId, selected: store.feedQuery.predicates.albums.first == album.id, filters: true) {
                    if store.feedQuery.predicates.albums.first != album.id { store.setAlbum(album) }; searchText = ""
                }
            }
            add("new-album", "New album", "plus") { navigator.present(.newAlbum) }
            add("all-albums", "Manage albums", "square.grid.2x2") { navigator.present(.albums) }
        case .more:
            add("recent-taken", "Recently taken", "camera", selected: store.filterTitle == "Recently taken", filters: true) { store.setFeed(.recentlyTaken, title: "Recently taken"); searchText = "" }
            add("recent-added", "Recently added", "clock.badge.checkmark", selected: store.filterTitle == "Recently added", filters: true) { store.setFeed(.recentlyAdded, title: "Recently added"); searchText = "" }
            add("videos", "Videos", "video", selected: store.filterTitle == "Videos" && store.searchFilter.type?.eq == "VIDEO", filters: true) {
                store.setMetadataFilter(SearchFilter(type: StringFilter(eq: "VIDEO"), visibility: StringFilter(eq: "timeline")), title: "Videos"); searchText = ""
            }
            add("motion", "Motion", "livephoto", selected: store.filterTitle == "Motion" && store.searchFilter.isMotion?.eq == true, filters: true) {
                store.setMetadataFilter(SearchFilter(isMotion: BoolFilter(eq: true), visibility: StringFilter(eq: "timeline")), title: "Motion"); searchText = ""
            }
            add("lightroom", "Lightroom", "slider.horizontal.3", selected: store.filterTitle == "Lightroom", filters: true) {
                store.setDeveloped(title: "Lightroom"); searchText = ""
            }
            add("favorites", "Favorites", "heart", selected: store.feedQuery.predicates.favorite == true, filters: true) { store.setFeed(.favorites, title: "Favorites"); searchText = "" }
            add("archive", "Archive", "archivebox", selected: store.feedQuery.visibility == .archive, filters: true) { store.setFeed(.archive, title: "Archive"); searchText = "" }
            if features?.trash != false {
                add("trash", "Trash", "trash", selected: store.feedQuery.trash == .trashed, filters: true) { store.setFeed(.trash, title: "Trash"); searchText = "" }
            }
            add("browse-more", "Browse more", "square.grid.2x2") { navigator.present(.more) }
            if !shareInbox.batches.isEmpty {
                add("shared-files", "Shared files", "square.and.arrow.down") { navigator.present(.sharedFiles) }
            }
        case .settings:
            for destination in SettingsDestination.allCases {
                add("settings-" + destination.rawValue, destination.title, destination.symbol) {
                    navigator.present(.settings(SettingsRoute(rawValue: destination.rawValue) ?? .root))
                }
            }
            add("sign-out", "Sign out", "rectangle.portrait.and.arrow.right") { navigator.show(.confirm(.signOut)) }
        }
        return items
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
            edgeInteraction.timePan = value
        }
    }

    /// The list position lives in the interaction, so only the fan redraws while a long list moves.
    private func shelfLayout(count: Int) -> LibraryShelfGeometry {
        // Rows start below the fan's own Back and Close row at the top.
        LibraryShelfGeometry(count: count, size: librarySize, topInset: 56,
                             bottomInset: 100, rowStep: shelf == .root ? nil : 60)
    }

    private func presentShelves(_ value: Shelf, at point: CGPoint) {
        // People and albums that failed to load, say while the phone reconnected, load again.
        if store.started { collections.reloadIfFailed() }
        // Opening again stops a close still on its way.
        closeGeneration += 1
        edgeInteraction.morphingID = nil; edgeInteraction.morphSize = nil
        edgeInteraction.endStroke()
        shelf = value
        placeShelf(at: point)
        // A fan that is not on screen yet draws folded first; it unfolds once it appears.
        if shelves {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84)) { edgeInteraction.shelfReveal = 1 }
        } else {
            edgeInteraction.shelfReveal = 0
        }
        shelves = true
        Haptics.menuOpened()
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
                                                    reorder: canReorder, selected: items.firstIndex(where: \.isSelected)),
                         items: items, at: point)
    }

    private func handleShelfEvent(_ event: LibraryShelfEvent, items: [LibraryShelfItem], at point: CGPoint) {
        switch event {
        case .none: break
        case .back: openShelf(.root, under: point, armed: false, needsReturn: false)
        case .open(let index):
            guard items.indices.contains(index) else { return }
            if shelf == .root, let group = rootShelf(for: items[index].id) {
                openShelf(group, under: point)
            } else {
                items[index].action()
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

    /// Lifting puts the shelves away, and a person or album chosen on the way rises into the
    /// filter tag; over the reorder button it reorders instead. While reordering, lifting drops a
    /// carried row or lets the list coast.
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
                                                    reorder: canReorder, selected: items.firstIndex(where: \.isSelected)),
                         items: items, at: point)
        guard shelves else { return }
        // Lifting the finger puts the shelves away, and a person or album chosen on the way rises
        // into the filter tag; over the reorder button it reorders instead.
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
                   closesPresentations: navigator.earthPresentationClosing, onPresentation: navigator.earthPresentationChanged)
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
            AnyView(NavigationStack {
                SelectionActionsView(api: api, pipeline: pipeline, selection: selection) {
                    store.selected = []; store.isSelecting = false
                    Task { await store.refreshAfterMutation() }
                }
            })
        case .albumSharing(let album, let sharing):
            AnyView(NavigationStack { albumSharing(album, sharing, level: level) })
        case .newAlbum:
            AnyView(NavigationStack {
                AlbumEditor(api: api, pipeline: pipeline, album: nil) { album in collections.albumCreated(album) }
            })
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
        case .people: PeopleView(api: api, pipeline: pipeline) { store.setPerson($0); navigator.dismiss(level: level); searchText = "" }
        case .albums: AlbumsView(api: api, pipeline: pipeline) { store.setAlbum($0); navigator.dismiss(level: level); searchText = "" }
        case .settings(let route):
            if let destination = SettingsDestination(rawValue: route.rawValue) {
                SettingsDestinationView(api: api, destination: destination, pipeline: pipeline, session: session)
            } else {
                SettingsView(api: api, pipeline: pipeline, session: session, onSignOut: { store.stop(); Task { await session.signOut() } })
            }
        case .more:
            // A photo opened from More closes it first, then opens in the viewer.
            MoreCollectionsView(api: api, pipeline: pipeline, onOpenAsset: { navigator.send(.openAsset($0)) }, onFilter: { query, title in
                store.setFeed(query, title: title); navigator.dismiss(level: level)
            }, onPlayMemory: { navigator.present(.memoryPlayer($0), from: level + 1) }, onMetadataFilter: { filter, title in
                store.setMetadataFilter(filter, title: title); searchText = ""; navigator.dismiss(level: level)
            }, onDeveloped: { title in
                store.setDeveloped(title: title); searchText = ""; navigator.dismiss(level: level)
            })
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func albumSharing(_ album: Album, _ sharing: AlbumSharing, level: Int) -> some View {
        switch sharing {
        case .link: SharedLinkEditor(api: api, album: album)
        case .people:
            AlbumMembersView(api: api, album: album, onLeft: {
                collections.albumRemoved(album.id); store.clearFilters()
            })
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { navigator.dismiss(level: level) } } }
        }
    }

    private func selectPlace(_ place: PlaceCollection) {
        store.setPlace(place.membership, title: place.title); searchText = ""
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
    /// Closes once the tag has laid out a filter chosen by a tap, so a person or album can rise
    /// into it.
    private func closeIntoTag(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            closeShelves(feedback: false, into: id)
        }
    }

    /// The rows slide back into the edge, then the shelves go. A person or album chosen on the
    /// way rises into the filter tag instead: the whole column scrolls up until that row sits
    /// where the tag lives, while the other rows slide out completely.
    private func closeShelves(feedback: Bool = true, into chosen: String? = nil) {
        guard shelves else { return }
        if feedback { Haptics.menuClosed() }
        edgeInteraction.endStroke(); edgeInteraction.highlighted = nil
        edgeInteraction.carried = nil; edgeInteraction.isRearranging = false
        closeGeneration += 1
        let generation = closeGeneration
        let items = shelfItems
        let rising = chosen.flatMap { id in (id.hasPrefix("person-") || id.hasPrefix("album-")) ? items.firstIndex { $0.id == id } : nil }
        var layout = shelfLayout(count: items.count)
        layout.top = edgeInteraction.shelfTop
        let morphing = rising != nil && filterTagFrame.height > 0
        tagHandoff = morphing
        let finish = {
            guard generation == closeGeneration else { return }
            // A row that rose into the tag already looks exactly like it, so the tag takes over
            // in the same frame.
            withAnimation(reduceMotion || morphing ? nil : .easeOut(duration: 0.14)) { shelves = false; shelf = .root }
            edgeInteraction.morphingID = nil; edgeInteraction.morphSize = nil
        }
        // A rising row moves on a softer spring with a little give.
        let motion: Animation = morphing ? .spring(response: 0.5, dampingFraction: 0.8) : .spring(response: 0.3, dampingFraction: 0.9)
        withAnimation(reduceMotion ? nil : motion) {
            if let rising, morphing {
                edgeInteraction.morphingID = items[rising].id
                edgeInteraction.morphSize = filterTagFrame.size
                edgeInteraction.shelfTop -= layout.center(rising) - filterTagFrame.midY
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
    private func openShelf(_ value: Shelf, under finger: CGPoint? = nil, armed: Bool = true, needsReturn: Bool = true) {
        edgeInteraction.carried = nil; edgeInteraction.isRearranging = false
        let left = shelf
        let items = shelfItems
        var layout = shelfLayout(count: items.count)
        layout.top = edgeInteraction.shelfTop
        let groupRow = items.firstIndex { $0.id == rootShelfID(value) }
        let y = finger?.y ?? groupRow.map { layout.center($0) } ?? edgeInteraction.shelfFinger?.y ?? librarySize.height * 0.45
        if value == .root { Haptics.menuClosed() } else { Haptics.menuOpened() }
        animate {
            shelf = value
            placeShelf(at: CGPoint(x: finger?.x ?? 0, y: y), anchorID: value == .root ? rootShelfID(left) : nil)
        }
        if let finger { edgeInteraction.rebase(at: finger, armed: armed, in: shelfLayout(count: shelfItems.count), needsReturn: needsReturn) }
    }
    private func rootShelf(for id: String) -> Shelf? {
        switch id {
        case "people": .people
        case "albums": .albums
        case "more": .more
        case "settings": .settings
        default: nil
        }
    }
    private func rootShelfID(_ value: Shelf) -> String? {
        switch value {
        case .root: nil
        case .people: "people"
        case .albums: "albums"
        case .more: "more"
        case .settings: "settings"
        }
    }
    private func animate(_ changes: () -> Void) { withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88), changes) }
    private var ownsSelection: Bool {
        !store.selectedAssets.isEmpty && store.selectedAssets.allSatisfy { $0.ownerId == api.userID }
    }
    private func runSelection(_ action: @escaping @MainActor ([String]) async throws -> Void) {
        guard !selectionBusy else { return }
        let ids = Array(store.selected)
        selectionBusy = true
        Task {
            defer { selectionBusy = false }
            do { try await action(ids); store.selected = []; store.isSelecting = false; await store.refreshAfterMutation() }
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

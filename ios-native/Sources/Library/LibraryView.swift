import SwiftUI

struct LibraryView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let session: SessionStore
    @State private var store: LibraryStore
    @State private var searchText = ""
    @State private var shelves = false
    @State private var shelf: Shelf = .root
    @State private var people: [Person] = []
    @State private var albums: [Album] = []
    @State private var features: ServerFeatures?
    @State private var screen: Screen?
    @State private var viewing: Asset?
    @State private var viewingLocal: LocalPhoto?
    @State private var deviceIndex = DeviceTimelineIndex()
    @State private var backup = BackupCoordinator.shared
    @State private var viewingAlbumID: String?
    @State private var linkedMemoryID: String?
    @State private var memoryLane = MemoryLaneStore()
    @State private var playingMemory: Memory?
    @State private var pendingPhotoDestination: PhotoDestination?
    @ScaledMetric(relativeTo: .subheadline) private var memoryLaneHeight = 132.0
    @State private var activityAlbumID: String?
    @State private var showPlaces = false
    @State private var places: [PlaceCollection] = []
    @State private var actionError: String?
    @State private var confirmDelete = false
    @State private var albumName = ""
    @State private var creatingAlbum = false
    @State private var bulkSelection: BulkSelection?
    @State private var selectionBusy = false
    @State private var headerHeight: CGFloat = 72
    @State private var shareInbox = ShareInboxStore.shared
    @State private var sharedFilesPresented = false
    @State private var seenShareBatches = Set<UUID>()
    @AppStorage("gridColumns") private var columns = 4
    @AppStorage("appearance") private var appearance = "system"
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var glass

    private enum Shelf { case root, people, albums, more, settings }
    private enum Screen: String, Identifiable { case people, albums, more, settings, places, searchOptions, memories, activity; var id: String { rawValue } }

    init(api: APIClient, pipeline: MediaPipeline, session: SessionStore) {
        self.api = api; self.pipeline = pipeline; self.session = session
        _store = State(initialValue: LibraryStore(api: session.libraryAPI ?? api, includesDevicePhotos: !session.isUITesting))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                PhotoGrid(store: store, pipeline: pipeline, columns: max(2, min(6, columns)),
                          topInset: geometry.safeAreaInsets.top + headerHeight,
                          bottomInset: geometry.safeAreaInsets.bottom + (showPlaces ? geometry.size.height * 0.4 : 90),
                          onDensityChange: { columns = $0 }, onOpenLocal: { searchFocused = false; viewingLocal = $0 },
                          memories: visibleMemories, memoryLaneHeight: visibleMemories.isEmpty ? 0 : dynamicTypeSize.isAccessibilitySize ? memoryLaneHeight : min(memoryLaneHeight, 190),
                          onOpenMemory: { searchFocused = false; playingMemory = $0 }) { asset in
                    searchFocused = false; viewingAlbumID = nil; viewing = asset
                }.ignoresSafeArea()
                if store.isLoading && store.totalCount == 0 { ProgressView("Loading library").frame(maxWidth: .infinity, maxHeight: .infinity) }
                if !store.isLoading && store.totalCount == 0 && store.error == nil && !store.isSearching {
                    ContentUnavailableView(store.isFiltered ? "No matching photos" : "Your library is empty",
                                           systemImage: "photo.on.rectangle", description: Text(store.isFiltered ? "Try a different description or clear the filters." : "Choose photos to back up in Settings."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                GlassEffectContainer(spacing: 14) {
                  ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        header.padding(.horizontal, 16).padding(.top, 8)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                        if let error = store.error { errorBanner(error, retry: store.retryCurrent) }
                        if !store.bucketErrors.isEmpty {
                            errorBanner("Some photos couldn’t load.", retry: store.retryFailedBuckets)
                        }
                        if !store.isFiltered && !store.isSelecting && memoryLane.error != nil {
                            errorBanner("Memories couldn’t load.") { Task { await memoryLane.load(api: api, force: true) } }
                        }
                        Spacer(minLength: 0)
                        if showPlaces {
                            placesPanel(height: geometry.size.height * 0.4)
                        } else if store.isSelecting {
                            selectionBar.padding(.horizontal, 16).padding(.bottom, 8)
                        } else {
                            searchBar.padding(.horizontal, 16).padding(.bottom, 8)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if shelves {
                        Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { toggleShelves() }
                        shelfPanel.frame(maxWidth: min(geometry.size.width - 48, 330), alignment: .leading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    } else {
                        Button { toggleShelves() } label: {
                            Image(systemName: "line.3.horizontal.decrease").font(.body.weight(.semibold))
                                .frame(width: 44, height: 56)
                        }.buttonStyle(.plain).glassEffect(.regular.interactive()).offset(x: -10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .accessibilityLabel("Open shelves").accessibilityIdentifier("library.shelves")
                    }
                  }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.zIndex(1)
                if !shelves && !searchFocused && store.query.isEmpty && !store.buckets.isEmpty {
                    TimeRail(store: store, pipeline: pipeline, viewportWidth: geometry.size.width)
                        .frame(width: 44).padding(.top, 130).padding(.bottom, showPlaces ? geometry.size.height * 0.42 : 100)
                        .frame(maxWidth: .infinity, alignment: .trailing).zIndex(2)
                }
            }
            .background(Color(.systemBackground))
            .sheet(item: $screen, onDismiss: finishPhotoNavigation) { destination in
                NavigationStack {
                    destinationView(destination)
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { screen = nil } } }
                }
            }
            .fullScreenCover(item: $viewing) { asset in
                AssetViewer(api: api, pipeline: pipeline, assets: store.availableAssets(around: asset), initial: asset,
                            onUpdated: store.update, onDeleted: { Task { await store.refreshAfterMutation() } }, albumID: viewingAlbumID ?? store.timelineFilter.albumID,
                            matchedLocalPhotos: store.matchingDevicePhotos)
            }
            .fullScreenCover(item: $playingMemory, onDismiss: finishPhotoNavigation) { memory in
                MemoryPlaybackView(api: api, pipeline: pipeline, memories: memoryLane.memories, initialID: memory.id,
                                   onNavigate: requestPhotoNavigation)
            }
            .fullScreenCover(item: $viewingLocal) { LocalPhotoViewer(photo: $0) }
            .sheet(item: $bulkSelection) { selection in
                NavigationStack {
                    SelectionActionsView(api: api, pipeline: pipeline, selection: selection) {
                        store.selected = []; store.isSelecting = false
                        Task { await store.refreshAfterMutation() }
                    }
                }
            }
            .sheet(isPresented: $sharedFilesPresented) { ShareInboxView(api: api) }
            .alert("Couldn’t complete action", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) { }
            } message: { Text(actionError ?? "") }
            .confirmationDialog(features?.trash == false ? "Permanently delete \(store.selected.count) items?" : "Move \(store.selected.count) items to Trash?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(features?.trash == false ? "Delete permanently" : "Move to Trash", role: .destructive) {
                    runSelection { ids in try await api.trashAssets(ids: ids, permanently: features?.trash == false) }
                }
            } message: { Text(features?.trash == false ? "This cannot be undone. Photos on your phone are kept." : "This changes the server library. Photos on your phone are kept.") }
            .alert("New album", isPresented: $creatingAlbum) {
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
            refreshSharedFiles()
            if !session.isUITesting { await backup.activate(); refreshDeviceIndex() }
            guard !store.started else { return }; store.started = true
            async let memories: Void = memoryLane.load(api: api)
            await store.reload(); await loadShelfData(); await memories
        }
        .task(id: session.pendingLink) {
            guard let link = session.pendingLink else { return }
            do {
                switch link {
                case .sharedFiles:
                    shareInbox.refresh()
                    seenShareBatches.formUnion(shareInbox.batches.map(\.id))
                    sharedFilesPresented = true
                case .asset(let id, let albumID):
                    let asset = try await api.asset(id: id)
                    if let albumID { _ = try await api.album(id: albumID) }
                    viewingAlbumID = albumID; viewing = asset
                case .album(let id): store.setAlbum(try await api.album(id: id))
                case .person(let id):
                    let person: Person = try await api.request(.get, path: "people/\(id)")
                    store.setPerson(person)
                case .memory(let id): linkedMemoryID = id; screen = .memories
                case .activity(let albumID):
                    _ = try await api.album(id: albumID)
                    activityAlbumID = albumID; screen = .activity
                }
            } catch is CancellationError {} catch { actionError = error.localizedDescription }
            if session.pendingLink == link { session.pendingLink = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in Task { await pipeline.trimMemory() } }
        .onReceive(NotificationCenter.default.publisher(for: .ilyichCachesReset)) { notification in
            if notification.userInfo?["scope"] as? String == api.cacheScope { Task { await store.refreshAfterMutation() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ilyichLibraryChanged)) { notification in
            guard notification.userInfo?["scope"] as? String == api.cacheScope else { return }
            Task {
                if store.query.isEmpty { await store.reload(preservingPosition: true) }
                if notification.userInfo?["collections"] as? Bool == true {
                    await loadShelfData(); await memoryLane.load(api: api, force: true)
                }
                refreshDeviceIndex()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshSharedFiles(); refreshDeviceIndex(); Task { await memoryLane.load(api: api) } }
            else if phase == .background { deviceIndex.stop() }
        }
        .onChange(of: deviceIndex.revision) { _, _ in store.updateDeviceTimeline(deviceIndex.snapshot) }
        .onChange(of: backup.preferences) { _, _ in refreshDeviceIndex() }
        .onChange(of: backup.isRunning) { _, running in if !running { refreshDeviceIndex() } }
        .onDisappear { deviceIndex.stop() }
        .onChange(of: screen) { _, value in if value == nil { refreshSharedFiles() } }
        .onChange(of: viewing) { _, value in if value == nil { refreshSharedFiles() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            Task { await memoryLane.load(api: api, force: true) }
        }
    }

    private var visibleMemories: [Memory] { store.isFiltered || store.isSelecting ? [] : memoryLane.memories }

    private var headingText: some View {
        let wrapped = dynamicTypeSize.isAccessibilitySize
        return Text(store.query.isEmpty || store.isSearching ? store.title : "\(store.totalCount.formatted()) matches")
            .font(.title.bold()).lineLimit(wrapped ? nil : 1).minimumScaleFactor(wrapped ? 1 : 0.75)
            .fixedSize(horizontal: false, vertical: wrapped)
            .accessibilityIdentifier("library.heading")
    }

    @ViewBuilder private var headerTitle: some View {
        if store.isSelecting && store.canSelectMonth {
            let wrapped = dynamicTypeSize.isAccessibilitySize
            Menu {
                Button("Select this month", systemImage: "checkmark.circle") { store.selectMonth(true) }
                Button("Deselect this month", systemImage: "circle") { store.selectMonth(false) }
            } label: {
                HStack(spacing: 6) {
                    Text(store.title).font(.title.bold()).lineLimit(wrapped ? nil : 1).minimumScaleFactor(wrapped ? 1 : 0.75)
                        .fixedSize(horizontal: false, vertical: wrapped)
                        .accessibilityIdentifier("library.heading")
                    if store.isSelectingGroup { ProgressView() }
                    else { Image(systemName: "chevron.down").font(.caption.weight(.semibold)) }
                }.frame(minHeight: 44)
            }.disabled(store.isSelectingGroup).accessibilityLabel("Selection for \(store.title)")
        } else {
            headingText
        }
    }

    @ViewBuilder private var headerControls: some View {
        Button(store.isSelecting ? "Done" : "Select") {
            store.isSelecting.toggle(); if !store.isSelecting { store.selected = [] }
        }.buttonStyle(.glass).controlSize(.large).tint(store.isSelecting ? Color.cyan : Color.primary).accessibilityIdentifier("library.select")
        if !store.isSelecting {
            Button { screen = .settings } label: {
                Text(String(session.name.prefix(1)).uppercased()).font(.headline).frame(width: 44, height: 44)
            }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).accessibilityLabel("Account and settings")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                headerTitle.frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .center) {
                    Spacer(minLength: 8)
                    headerControls
                }
            } else {
                HStack(alignment: .center) {
                    headerTitle
                    Spacer(minLength: 8)
                    headerControls
                }
            }
            if store.isFiltered {
                HStack(spacing: 8) {
                    Text(store.filterTitle ?? store.query).font(.subheadline.weight(.medium)).lineLimit(1)
                    Button { searchText = ""; store.clearFilters() } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("Clear filters")
                }.padding(.leading, 12).padding(.trailing, 4).glassEffect().fixedSize(horizontal: false, vertical: true)
            }
            if let albumID = store.timelineFilter.albumID {
                AlbumUploadStatusView(albumID: albumID) { Task { await store.refreshAfterMutation() } }
            }
            if !store.query.isEmpty, let verification = store.verification {
                verificationView(verification)
            }
        }
        .padding(.bottom, 12)
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
                .padding(.horizontal, -16).padding(.bottom, -20).ignoresSafeArea(edges: .top)
        }
    }

    private var searchBar: some View {
        VStack(spacing: 10) {
            if store.isSearching {
                HStack(spacing: 12) { ProgressView(); Text("Checking photo content…").font(.subheadline); Spacer() }
                    .padding(16).glassEffect(in: .rect(cornerRadius: 20))
                    .accessibilityIdentifier("search.checking")
            }
            HStack(spacing: 12) {
                Button { searchFocused = false; screen = .searchOptions } label: {
                    Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Search options")
                TextField(store.filterTitle.map { "Search \($0)" } ?? "Describe a moment", text: $searchText)
                    .focused($searchFocused).submitLabel(.search).onSubmit { store.search(searchText); searchFocused = false }
                    .accessibilityIdentifier("library.search")
                if !searchText.isEmpty {
                    Button { searchText = ""; store.search("") } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("Clear search")
                }
            }.padding(.horizontal, 18).frame(minHeight: 58).glassEffect(.regular.interactive())
        }
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
            Button { creatingAlbum = true } label: { Image(systemName: "rectangle.stack.badge.plus").frame(width: 44, height: 44) }.accessibilityLabel("Create album from selection").requiresWriteAccess(api)
            Button { runSelection { ids in try await api.requestVoid(.put, path: "assets", body: SelectionUpdate(ids: ids, isFavorite: true)) } }
                label: { Image(systemName: "heart").frame(width: 44, height: 44) }.accessibilityLabel("Favorite selected photos").requiresWriteAccess(api).disabled(!ownsSelection)
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel(features?.trash == false ? "Delete selection permanently" : "Move selection to Trash").requiresWriteAccess(api).disabled(features == nil || !ownsSelection)
            } else {
                Button {
                    let localIDs = store.selectedLocalPhotos.map(\.id)
                    Task { await backup.enqueue(localIDs: localIDs) }
                } label: { Image(systemName: "icloud.and.arrow.up").frame(width: 44, height: 44) }
                    .accessibilityLabel("Back up selected phone photos").requiresWriteAccess(api).disabled(backup.isRunning)
            }
            Button { bulkSelection = BulkSelection(assets: store.selectedAssets, local: store.selectedDevicePhotos) } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }.accessibilityLabel("Selection actions")
        }.padding(.horizontal, 14).padding(.vertical, 6).glassEffect().disabled(store.selected.isEmpty || selectionBusy)
    }

    private var shelfPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if shelf != .root {
                shelfButton("Back", symbol: "chevron.left", width: 130) { animate { shelf = .root } }
            }
            switch shelf {
            case .root:
                if features?.facialRecognition != false {
                shelfButton("People", symbol: "person.2", width: 260) { animate { shelf = .people } }
                }
                if features?.map != false {
                shelfButton("Places", symbol: "globe.europe.africa", width: 230) { shelves = false; showPlaces.toggle() }
                }
                shelfButton("Albums", symbol: "rectangle.stack", width: 205) { animate { shelf = .albums } }
                shelfButton("More", symbol: "ellipsis", width: 180) { animate { shelf = .more } }
                shelfButton("Settings", symbol: "gearshape", width: 155) { shelves = false; screen = .settings }
            case .people:
                ForEach(Array(people.prefix(7).enumerated()), id: \.element.id) { index, person in
                    shelfButton(person.name.isEmpty ? "Unnamed person" : person.name, symbol: "person.crop.circle", width: CGFloat(290 - index * 16)) {
                        store.setPerson(person); shelves = false; searchText = ""
                    }
                }
                shelfButton("All people", symbol: "person.2", width: 170) { shelves = false; screen = .people }
            case .albums:
                ForEach(Array(albums.prefix(6).enumerated()), id: \.element.id) { index, album in
                    shelfButton(album.albumName, symbol: "rectangle.stack", width: CGFloat(290 - index * 18)) {
                        store.setAlbum(album); shelves = false; searchText = ""
                    }
                }
                shelfButton("All albums", symbol: "square.grid.2x2", width: 170) { shelves = false; screen = .albums }
            case .more:
                shelfButton("Favorites", symbol: "heart", width: 260) { store.setTimeline(TimelineFilter(isFavorite: true), title: "Favorites"); shelves = false }
                shelfButton("Archive", symbol: "archivebox", width: 230) { store.setTimeline(TimelineFilter(visibility: .archive), title: "Archive"); shelves = false }
                if features?.trash != false {
                    shelfButton("Trash", symbol: "trash", width: 205) { store.setTimeline(TimelineFilter(visibility: nil, isTrashed: true), title: "Trash"); shelves = false }
                }
                shelfButton("Browse more", symbol: "square.grid.2x2", width: 185) { shelves = false; screen = .more }
                if !shareInbox.batches.isEmpty {
                    shelfButton("Shared files", symbol: "square.and.arrow.down", width: 185) {
                        shelves = false; sharedFilesPresented = true
                    }
                }
            case .settings:
                EmptyView()
            }
            shelfButton("Close", symbol: "xmark", width: 132) { toggleShelves() }
        }.padding(.leading, -16)
    }

    private func shelfButton(_ title: String, symbol: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Spacer(minLength: 24); Text(title).font(.subheadline.weight(.semibold)).lineLimit(1); Image(systemName: symbol).frame(width: 26) }
                .padding(.trailing, 12).frame(width: width, height: 44)
                .glassEffect(.regular.interactive()).glassEffectID(title, in: glass)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private func placesPanel(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Button { showPlaces = false } label: { Image(systemName: "chevron.down").frame(width: 60, height: 44) }
                .buttonStyle(.glass).accessibilityLabel("Close globe")
            PlacesView(api: api, pipeline: pipeline, onSelect: selectPlace, compact: true)
                .frame(height: height)
        }
    }

    @ViewBuilder private func destinationView(_ destination: Screen) -> some View {
        switch destination {
        case .memories: MemoriesView(api: api, pipeline: pipeline,
                                    onOpenAsset: { requestPhotoNavigation(.viewer($0)) },
                                    onShowInTimeline: { requestPhotoNavigation(.timeline($0)) }, initialID: linkedMemoryID)
        case .activity:
            if let activityAlbumID { AlbumActivityView(api: api, albumID: activityAlbumID) }
        case .searchOptions: SearchOptionsView(api: api, mode: store.searchMode, filter: store.searchFilter) { mode, filter in
            store.applySearchOptions(mode: mode, filter: filter)
        }
        case .people: PeopleView(api: api, pipeline: pipeline) { store.setPerson($0); screen = nil; searchText = "" }
        case .albums: AlbumsView(api: api, pipeline: pipeline) { store.setAlbum($0); screen = nil; searchText = "" }
        case .places: PlacesView(api: api, pipeline: pipeline, onSelect: selectPlace)
        case .settings: SettingsView(api: api, pipeline: pipeline, session: session, onSignOut: { store.stop(); Task { await session.signOut() } })
        case .more: MoreCollectionsView(api: api, pipeline: pipeline, onOpenAsset: { requestPhotoNavigation(.viewer($0)) }, onFilter: { filter, title in
            store.setTimeline(filter, title: title); screen = nil
        }, onShowInTimeline: { requestPhotoNavigation(.timeline($0)) })
        }
    }
    private func selectPlace(_ place: PlaceCollection) {
        store.setPlace(assetIDs: place.assetIDs, title: place.title); searchText = ""; screen = nil
    }
    private func requestPhotoNavigation(_ destination: PhotoDestination) {
        let dismissing = screen != nil || playingMemory != nil
        pendingPhotoDestination = destination
        screen = nil; playingMemory = nil
        if !dismissing { finishPhotoNavigation() }
    }
    private func finishPhotoNavigation() {
        guard screen == nil, playingMemory == nil else { return }
        guard let destination = pendingPhotoDestination else { refreshSharedFiles(); return }
        pendingPhotoDestination = nil
        switch destination {
        case .viewer(let asset): viewingAlbumID = nil; viewing = asset
        case .timeline(let asset): searchText = ""; store.showInTimeline(asset)
        }
    }
    private func refreshSharedFiles() {
        shareInbox.refresh()
        let ids = Set(shareInbox.batches.map(\.id))
        seenShareBatches.formIntersection(ids)
        guard !ids.subtracting(seenShareBatches).isEmpty, screen == nil, viewing == nil, viewingLocal == nil,
              playingMemory == nil, pendingPhotoDestination == nil, bulkSelection == nil else { return }
        seenShareBatches.formUnion(ids)
        sharedFilesPresented = true
    }
    private func refreshDeviceIndex() {
        guard !session.isUITesting else { return }
        deviceIndex.configure(scope: api.cacheScope, entities: session.entities,
                              preferences: backup.preferences, receipts: backup.associations)
    }
    private func errorBanner(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack { Text(message).font(.caption); Spacer(); Button("Retry", action: retry) }
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 16).padding(.top, 8)
    }
    private func toggleShelves() { searchFocused = false; animate { shelves.toggle(); if !shelves { shelf = .root } } }
    private func animate(_ changes: () -> Void) { withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88), changes) }
    private func loadShelfData() async {
        async let featuresResult = try? api.serverFeatures()
        async let peopleResult = try? api.people()
        async let albumResult = try? api.albums()
        people = await peopleResult?.people ?? []; albums = await albumResult ?? []; features = await featuresResult
    }
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
            catch { actionError = error.localizedDescription }
        }
    }
}

private struct BulkSelection: Identifiable {
    let id = UUID()
    let assets: [Asset]
    let local: [LocalPhoto]
}

private struct SelectionActionsView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let selection: BulkSelection
    let onChanged: () -> Void
    var body: some View {
        if selection.local.isEmpty {
            BulkActionsView(api: api, pipeline: pipeline, assets: selection.assets, onChanged: onChanged)
        } else if selection.assets.isEmpty {
            LocalPhotoActionsView(photos: selection.local, onChanged: onChanged)
        } else {
            List {
                NavigationLink("\(selection.assets.count) server photos") {
                    BulkActionsView(api: api, pipeline: pipeline, assets: selection.assets, onChanged: onChanged)
                }
                NavigationLink("\(selection.local.count) phone photos") {
                    LocalPhotoActionsView(photos: selection.local, onChanged: onChanged)
                }
            }.navigationTitle("Selection actions")
        }
    }
}

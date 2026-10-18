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
    @State private var screen: Screen?
    @State private var viewing: Asset?
    @State private var showPlaces = false
    @State private var places: [PlaceCollection] = []
    @State private var actionError: String?
    @State private var confirmDelete = false
    @State private var albumName = ""
    @State private var creatingAlbum = false
    @AppStorage("gridColumns") private var columns = 4
    @AppStorage("appearance") private var appearance = "system"
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    private enum Shelf { case root, people, albums, more, settings }
    private enum Screen: String, Identifiable { case people, albums, more, settings, places; var id: String { rawValue } }

    init(api: APIClient, pipeline: MediaPipeline, session: SessionStore) {
        self.api = api; self.pipeline = pipeline; self.session = session
        _store = State(initialValue: LibraryStore(api: api))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                PhotoGrid(store: store, pipeline: pipeline, columns: max(2, min(6, columns)),
                          topInset: geometry.safeAreaInsets.top + 104,
                          bottomInset: geometry.safeAreaInsets.bottom + (showPlaces ? geometry.size.height * 0.4 : 90)) { asset in
                    searchFocused = false; viewing = asset
                }.ignoresSafeArea()
                if store.isLoading && store.totalCount == 0 { ProgressView("Loading library").frame(maxWidth: .infinity, maxHeight: .infinity) }
                if !store.isLoading && store.totalCount == 0 && store.error == nil && !store.isSearching {
                    ContentUnavailableView(store.isFiltered ? "No matching photos" : "Your library is empty",
                                           systemImage: "photo.on.rectangle", description: Text(store.isFiltered ? "Try a different description or clear the filters." : "Choose photos to back up in Settings."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 0) {
                        header.padding(.horizontal, 16).padding(.top, 8)
                        if let error = store.error { errorBanner(error, retry: store.retrySearch) }
                        if !store.bucketErrors.isEmpty {
                            errorBanner("Some photos couldn’t load.", retry: store.retryFailedBuckets)
                        }
                        Spacer(minLength: 0)
                        if showPlaces {
                            placesPanel(height: geometry.size.height * 0.4)
                        } else if store.isSelecting {
                            selectionBar.padding(.horizontal, 16).padding(.bottom, 8)
                        } else {
                            searchBar.padding(.horizontal, 16).padding(.bottom, 8)
                        }
                    }
                    if shelves {
                        Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { toggleShelves() }
                        shelfPanel.frame(maxWidth: min(geometry.size.width - 48, 330), alignment: .leading)
                            .frame(maxHeight: .infinity, alignment: .center)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    } else {
                        Button { toggleShelves() } label: {
                            Image(systemName: "line.3.horizontal.decrease").font(.body.weight(.semibold))
                                .frame(width: 44, height: 56)
                        }.buttonStyle(.glass).offset(x: -10)
                            .frame(maxHeight: .infinity, alignment: .center)
                            .accessibilityLabel("Open shelves").accessibilityIdentifier("library.shelves")
                    }
                }
                if !shelves && !searchFocused && store.query.isEmpty && !store.buckets.isEmpty {
                    TimeRail(buckets: store.buckets) { bucket in store.scrollTarget = bucket.id }
                        .frame(width: 44).padding(.top, 130).padding(.bottom, showPlaces ? geometry.size.height * 0.42 : 100)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .background(Color(.systemBackground))
            .sheet(item: $screen) { destination in
                NavigationStack {
                    destinationView(destination)
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { screen = nil } } }
                }
            }
            .fullScreenCover(item: $viewing) { asset in
                AssetViewer(api: api, pipeline: pipeline, assets: store.availableAssets(around: asset), initial: asset,
                            onUpdated: store.update, onDeleted: { Task { await store.reload() } })
            }
            .alert("Couldn’t complete action", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) { }
            } message: { Text(actionError ?? "") }
            .confirmationDialog("Move \(store.selected.count) items to Trash?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) { runSelection { try await api.trashAssets(ids: Array(store.selected)) } }
            } message: { Text("This changes the server library. Photos on your phone are kept.") }
            .alert("New album", isPresented: $creatingAlbum) {
                TextField("Album name", text: $albumName)
                Button("Create") {
                    runSelection { _ = try await api.createAlbum(name: albumName, assetIDs: Array(store.selected)) }
                }.disabled(albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { }
            }
        }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .task { await store.reload(); await loadShelfData() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(store.query.isEmpty || store.isSearching ? store.title : "\(store.totalCount.formatted()) matches")
                    .font(.title.bold()).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                Button(store.isSelecting ? "Done" : "Select") {
                    store.isSelecting.toggle(); if !store.isSelecting { store.selected = [] }
                }.buttonStyle(.glass).accessibilityIdentifier("library.select")
                if !store.isSelecting {
                    Button { screen = .settings } label: {
                        Text(String(session.name.prefix(1)).uppercased()).font(.headline).frame(width: 44, height: 44)
                    }.buttonStyle(.glass).accessibilityLabel("Account and settings")
                }
            }
            if store.isFiltered {
                HStack(spacing: 8) {
                    Text(store.filterTitle ?? store.query).font(.subheadline.weight(.medium)).lineLimit(1)
                    Button { searchText = ""; store.clearFilters() } label: { Image(systemName: "xmark.circle.fill").frame(width: 32, height: 32) }
                        .accessibilityLabel("Clear filters")
                }.padding(.leading, 12).padding(.trailing, 4).glassEffect().fixedSize(horizontal: false, vertical: true)
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
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                TextField(store.filterTitle.map { "Search \($0)" } ?? "Describe a moment", text: $searchText)
                    .focused($searchFocused).submitLabel(.search).onSubmit { store.search(searchText); searchFocused = false }
                    .accessibilityIdentifier("library.search")
                if !searchText.isEmpty {
                    Button { searchText = ""; store.search("") } label: { Image(systemName: "xmark.circle.fill").frame(width: 32, height: 36) }
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
            Button { creatingAlbum = true } label: { Image(systemName: "rectangle.stack.badge.plus").frame(width: 44, height: 44) }.accessibilityLabel("Create album from selection")
            Button { runSelection { for id in store.selected { _ = try await api.updateFavorite(assetID: id, value: true) } } }
                label: { Image(systemName: "heart").frame(width: 44, height: 44) }.accessibilityLabel("Favorite selected photos")
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel("Move selection to Trash")
        }.padding(.horizontal, 14).padding(.vertical, 6).glassEffect().disabled(store.selected.isEmpty)
    }

    private var shelfPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if shelf != .root {
                shelfButton("Back", symbol: "chevron.left", width: 130) { animate { shelf = .root } }
            }
            switch shelf {
            case .root:
                shelfButton("People", symbol: "person.2", width: 260) { animate { shelf = .people } }
                shelfButton("Places", symbol: "globe.europe.africa", width: 230) { shelves = false; showPlaces.toggle() }
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
                shelfButton("Trash", symbol: "trash", width: 205) { store.setTimeline(TimelineFilter(visibility: nil, isTrashed: true), title: "Trash"); shelves = false }
                shelfButton("Browse more", symbol: "square.grid.2x2", width: 185) { shelves = false; screen = .more }
            case .settings:
                EmptyView()
            }
            shelfButton("Close", symbol: "xmark", width: 110) { toggleShelves() }
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
        case .people: PeopleView(api: api, pipeline: pipeline) { store.setPerson($0); screen = nil; searchText = "" }
        case .albums: AlbumsView(api: api, pipeline: pipeline) { store.setAlbum($0); screen = nil; searchText = "" }
        case .places: PlacesView(api: api, pipeline: pipeline, onSelect: selectPlace)
        case .settings: SettingsView(api: api, onSignOut: { Task { await session.signOut() } })
        case .more: MoreCollectionsView(api: api, pipeline: pipeline, onOpenAsset: { viewing = $0; screen = nil }, onFilter: { filter, title in
            store.setTimeline(filter, title: title); screen = nil
        })
        }
    }
    private func selectPlace(_ place: PlaceCollection) {
        store.setPlace(assetIDs: place.assetIDs, title: place.title); searchText = ""; screen = nil
    }
    private func errorBanner(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack { Text(message).font(.caption); Spacer(); Button("Retry", action: retry) }
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 16).padding(.top, 8)
    }
    private func toggleShelves() { searchFocused = false; animate { shelves.toggle(); if !shelves { shelf = .root } } }
    private func animate(_ changes: () -> Void) { withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88), changes) }
    private func loadShelfData() async {
        async let peopleResult = try? api.people()
        async let albumResult = try? api.albums()
        people = await peopleResult?.people ?? []; albums = await albumResult ?? []
    }
    private func runSelection(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action(); store.selected = []; store.isSelecting = false; await store.reload() }
            catch { actionError = error.localizedDescription }
        }
    }
}

private struct TimeRail: View {
    let buckets: [TimeBucket]
    let onSelect: (TimeBucket) -> Void
    @State private var selected: Int?
    @State private var dragging = false
    private var total: Int { max(1, buckets.reduce(0) { $0 + $1.count }) }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                Capsule().fill(.secondary.opacity(0.35)).frame(width: dragging ? 5 : 2).padding(.trailing, 8)
                if dragging, let selected {
                    Text(buckets[selected].date?.formatted(.dateTime.month(.abbreviated).year()) ?? "")
                        .font(.headline.monospacedDigit()).padding(12).glassEffect().fixedSize().offset(x: -24)
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.bold))
                    .frame(width: 32, height: 48).glassEffect()
                    .position(x: 24, y: dragging ? position(selected ?? 0) * geometry.size.height : 24)
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    dragging = true
                    let value = min(1, max(0, value.location.y / max(1, geometry.size.height)))
                    let target = Int(value * Double(total))
                    var sum = 0
                    let index = buckets.firstIndex { bucket in sum += bucket.count; return sum > target } ?? max(0, buckets.count - 1)
                    if selected != index { selected = index; onSelect(buckets[index]); UISelectionFeedbackGenerator().selectionChanged() }
                }.onEnded { _ in dragging = false })
                .accessibilityElement().accessibilityLabel("Timeline month")
                .accessibilityValue(selected.flatMap { buckets[$0].date?.formatted(.dateTime.month(.wide).year()) } ?? "Most recent")
                .accessibilityAdjustableAction { direction in
                    let next = min(buckets.count - 1, max(0, (selected ?? 0) + (direction == .increment ? 1 : -1)))
                    selected = next; onSelect(buckets[next])
                }.accessibilityIdentifier("library.timeRail")
        }
    }
    private func position(_ index: Int) -> CGFloat { CGFloat(buckets.prefix(index).reduce(0) { $0 + $1.count }) / CGFloat(total) }
}

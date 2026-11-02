import SwiftUI
import MapKit

struct PlaceFocus: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    /// A photo's own location, which the Earth comes in closer to and shows the place of.
    var assetID: String? = nil
    /// A place chosen, which the Earth turns to and shows at its zoom.
    var placeID: String? = nil
}

/// A place chosen on the Earth or in its list: the whole place, with its photos as the place
/// filter knows them (REBUILD_ROADMAP.md L1).
struct PlaceCollection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let country: String?
    let latitude: Double
    let longitude: Double
    let membership: PlaceMembership
    var assetIDs: [String] { membership.assetIDs }
    var focus: PlaceFocus { .init(latitude: latitude, longitude: longitude, placeID: id) }

    init(_ node: PlaceHierarchy.Node, in hierarchy: PlaceHierarchy) {
        id = node.id; title = node.title; country = node.level == .country ? nil : node.countryName
        latitude = node.latitude; longitude = node.longitude
        membership = hierarchy.membership(of: node)
    }
}

extension EnvironmentValues {
    /// The signed-in account's places (REBUILD_ROADMAP.md L1). Nil while nobody is signed in.
    @Entry var placeDirectory: PlaceDirectory? = nil
}

/// A place in the list of locations, by its ID.
struct PlaceRoute: Hashable {
    let id: String
}

struct PlacesView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onSelect: (PlaceCollection) -> Void
    var focus: PlaceFocus? = nil
    var compact = false
    var bottomInset: CGFloat = 0
    /// Asks this view to close its own sheets and alert, as a link does over the library.
    var closesPresentations = false
    /// Told when this view's own sheets and alert come up, and once they have all gone.
    var onPresentation: (Bool) -> Void = { _ in }
    /// Under a stack of filters the Earth keeps only these photos of its places (REBUILD_ROADMAP.md
    /// N6); nil keeps every one.
    var narrowing: PlaceNarrowing? = nil
    @Environment(\.placeDirectory) private var directory
    /// Every place, whole: a place chosen is always the whole place.
    @State private var hierarchy = PlaceHierarchy.empty
    /// The places shown and their lights: every one, or under a stack of filters only those holding
    /// its photos, each counting only those.
    @State private var shown = PlaceHierarchy.empty
    @State private var lights: GlobePhotoLights?
    /// What `shown` was arranged for: the narrowing's identity and the hierarchy's.
    @State private var arrangedFor: String?
    /// Where the Earth first turns with nothing chosen: its biggest city, decided once, so the
    /// places built again never turn it back.
    @State private var firstFocus: PlaceFocus?
    @State private var selected: PlaceHierarchy.Node?
    @State private var loading = true
    @State private var failure: String?
    @State private var mapPlace: PlaceHierarchy.Node?
    @State private var favoritesOnly = false
    @State private var includeArchived = false
    @State private var includePartners = true
    @State private var mapEnabled: Bool?
    @State private var dateFilter = false
    @State private var startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var showingDates = false
    @State private var showingLocations = false
    /// A sheet is up or still on its way out; it has gone once its onDismiss runs.
    @State private var sheetUp = false

    var body: some View {
        GeometryReader { geometry in
            if mapEnabled == false {
                FeatureEmpty(title: "Maps are turned off", symbol: "globe", description: "Enable maps on your server to browse photo locations.")
            } else if compact {
                PlacesGlobeView(hierarchy: shown, lights: lights, focus: globeFocus, compact: true, api: api, pipeline: pipeline,
                                onSelect: { selected = $0; onSelect(whole($0)) })
                    .overlay(alignment: .bottomTrailing) {
                        Button("All locations", systemImage: "list.bullet") { showingLocations = true }
                            .font(.subheadline).buttonStyle(.glass).foregroundStyle(.primary)
                            .padding(16).padding(.bottom, bottomInset).disabled(loading || shown.roots.isEmpty)
                    }
                    .overlay { if loading { ProgressView() } }
            } else {
                ScrollView {
                    PlacesGlobeView(hierarchy: hierarchy, lights: lights, focus: selected.map { $0.focus } ?? focus, api: api, pipeline: pipeline, onSelect: { selected = $0 })
                        .frame(height: min(geometry.size.height * 0.55, 460)).clipped()
                    if let selected {
                        HStack(spacing: 14) {
                            FeatureThumbnail(api: api, pipeline: pipeline, assetID: selected.coverID).frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 9))
                            VStack(alignment: .leading) { Text(selected.title).font(.headline); Text(Self.items(selected.count)).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Open photos") { onSelect(whole(selected)) }.buttonStyle(.borderedProminent)
                        }.padding(.horizontal, 20).padding(.bottom, 12)
                    }
                    if loading { ProgressView().padding() }
                    else if hierarchy.roots.isEmpty { FeatureEmpty(title: "No locations yet", symbol: "globe.europe.africa", description: "Photos with location data will appear on your globe.") }
                    PlaceRows(hierarchy: hierarchy, parent: nil, api: api, pipeline: pipeline, inline: true,
                              onSelect: { onSelect(whole($0)) }, onFocus: { selected = $0 }, onMap: { mapPlace = $0 })
                        .padding(.horizontal, 20)
                }
                .navigationDestination(for: PlaceRoute.self) { route in
                    PlaceRows(hierarchy: hierarchy, parent: hierarchy[route.id], api: api, pipeline: pipeline, inline: false,
                              onSelect: { onSelect(whole($0)) }, onFocus: { selected = $0 }, onMap: { mapPlace = $0 })
                        .navigationTitle(hierarchy[route.id]?.title ?? "")
                }
            }
        }.navigationTitle(compact ? "" : "Places")
        .toolbar {
            if !compact { ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Favorites only", isOn: $favoritesOnly)
                    Toggle("Include archived", isOn: $includeArchived)
                    Toggle("Include partners", isOn: $includePartners)
                    Button(dateFilter ? "Change date range" : "Filter by date") { showingDates = true }
                    if dateFilter { Button("Clear date range") { dateFilter = false } }
                } label: { Image(systemName: "line.3.horizontal.decrease") }.accessibilityLabel("Filter places")
            }
            }
        }
        .task(id: query) { await follow() }
        // The filters stacked changed or were counted again, or the places loaded under an older
        // narrowing: shown again.
        .task(id: "\(narrowing?.identity ?? "")|\(hierarchy.identity)") { await arrange() }
        .refreshable { await directory?.reload(query) }
        .sheet(isPresented: $showingDates, onDismiss: sheetDismissed) {
            NavigationStack {
                Form {
                    Toggle("Use date range", isOn: $dateFilter)
                    DatePicker("From", selection: $startDate, in: ...endDate, displayedComponents: .date)
                    DatePicker("Through", selection: $endDate, in: startDate...Date(), displayedComponents: .date)
                }.navigationTitle("Photo dates")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDates = false } } }
            }.presentationDetents([.medium])
        }
        .sheet(item: $mapPlace, onDismiss: sheetDismissed) { place in NavigationStack { PlaceMapDetail(place: place, onSelect: { onSelect(whole($0)) }) } }
        .sheet(isPresented: $showingLocations, onDismiss: sheetDismissed) {
            NavigationStack {
                PlacesListView(hierarchy: shown, api: api, pipeline: pipeline) { place in
                    selected = place; showingLocations = false; onSelect(whole(place))
                }
            }
            .presentationDetents([.height(300), .medium])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
        }
        .alert("Couldn’t load places", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("Retry") { Task { await directory?.reload(query) } }; Button("Cancel", role: .cancel) { }
        } message: { Text(failure ?? "") }
        .onChange(of: presenting) { _, up in
            if up { sheetUp = sheetUp || showingDates || showingLocations || mapPlace != nil; onPresentation(true) }
            else if !sheetUp { onPresentation(false) }
        }
        .onChange(of: closesPresentations, initial: true) { _, close in
            guard close else { return }
            showingDates = false; showingLocations = false; mapPlace = nil; failure = nil
        }
        .onDisappear { onPresentation(false) }
    }

    static func items(_ count: Int) -> String { "\(count.formatted()) item\(count == 1 ? "" : "s")" }

    private var presenting: Bool { showingDates || showingLocations || mapPlace != nil || failure != nil }

    private func sheetDismissed() {
        sheetUp = false
        if !presenting { onPresentation(false) }
    }

    private var globeFocus: PlaceFocus? {
        selected.map { $0.focus } ?? focus ?? firstFocus
    }

    /// The photos the places are found in: the library's, with the filters chosen here.
    private var query: MapMarkerQuery {
        var fileCreatedAfter: Date?
        var fileCreatedBefore: Date?
        if dateFilter {
            let calendar = Calendar.current
            fileCreatedAfter = calendar.startOfDay(for: startDate)
            fileCreatedBefore = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
        }
        return MapMarkerQuery(withPartners: includePartners, withSharedAlbums: true, isArchived: includeArchived,
                              isFavorite: favoritesOnly ? true : nil, fileCreatedAfter: fileCreatedAfter, fileCreatedBefore: fileCreatedBefore)
    }

    /// The whole place of one shown, which may count only the photos of a stack of filters.
    private func whole(_ place: PlaceHierarchy.Node) -> PlaceCollection {
        PlaceCollection(hierarchy[place.id] ?? place, in: hierarchy)
    }

    /// Follows the account's places for the query: what is known at once, then each change.
    private func follow() async {
        guard let directory else { loading = false; failure = "Places need a signed-in account."; return }
        if let features = try? await api.serverFeatures() {
            mapEnabled = features.map
            guard features.map else { hierarchy = .empty; shown = .empty; lights = nil; selected = nil; loading = false; return }
        }
        for await snapshot in await directory.places(query) {
            guard !Task.isCancelled else { return }
            switch snapshot {
            case .loading: loading = hierarchy.roots.isEmpty
            case .failed(let message): loading = false; failure = message
            case .loaded(let loaded):
                hierarchy = loaded; loading = false; failure = nil
                if firstFocus == nil, let city = loaded.cities.first { firstFocus = .init(latitude: city.latitude, longitude: city.longitude) }
                // A place's ID moves as its locality comes in (its country gains its code, its
                // city its name), so a place chosen is found again by its cover photo.
                if let previous = selected {
                    selected = loaded[previous.id] ?? loaded.leaf(of: previous.coverID).flatMap { leaf in
                        loaded.lineage(of: leaf.id).first { $0.level <= previous.level }
                    }
                }
                else if compact, let assetID = focus?.assetID, let place = loaded.leaf(of: assetID) {
                    selected = place; onSelect(PlaceCollection(place, in: loaded))
                }
            }
        }
    }

    /// Shows the places again for the latest narrowing, from the hierarchy loaded, when they were
    /// arranged for another.
    private func arrange() async {
        let narrowing = self.narrowing, hierarchy = self.hierarchy
        let identity = "\(narrowing?.identity ?? "")|\(hierarchy.identity)"
        guard !hierarchy.roots.isEmpty, identity != arrangedFor else { return }
        let arranged = await Task.detached(priority: .userInitiated) {
            let shown = narrowing.map { hierarchy.narrowed(to: $0.ids) } ?? hierarchy
            return (shown, GlobePhotoLights(photos: shown.photos))
        }.value
        guard !Task.isCancelled else { return }
        shown = arranged.0; lights = arranged.1; arrangedFor = identity
    }
}

extension PlaceHierarchy.Node {
    var focus: PlaceFocus { .init(latitude: latitude, longitude: longitude, placeID: id) }
}

/// The places under one, or at the top every city under its country: a place with parts opens
/// into them, and any place's photos open from its row or its country's heading.
private struct PlaceRows: View {
    let hierarchy: PlaceHierarchy
    let parent: PlaceHierarchy.Node?
    let api: APIClient
    let pipeline: MediaPipeline
    /// Inline rows sit in a scroll view; otherwise they are a list of their own.
    let inline: Bool
    let onSelect: (PlaceHierarchy.Node) -> Void
    let onFocus: (PlaceHierarchy.Node) -> Void
    let onMap: (PlaceHierarchy.Node) -> Void

    var body: some View {
        if inline {
            LazyVStack(spacing: 0) { rows }
        } else {
            List { rows }.listStyle(.plain)
        }
    }

    @ViewBuilder private var rows: some View {
        if let parent {
            PlaceRow(place: parent, title: "All of \(parent.title)", api: api, pipeline: pipeline, opens: false, onSelect: onSelect, onFocus: onFocus, onMap: onMap)
            ForEach(hierarchy.children(of: parent)) { child in
                PlaceRow(place: child, title: child.title, api: api, pipeline: pipeline, opens: !child.childIDs.isEmpty, onSelect: onSelect, onFocus: onFocus, onMap: onMap)
            }
        } else {
            ForEach(hierarchy.countries) { country in
                if country.level == .country {
                    Section {
                        ForEach(hierarchy.descendants(of: country, at: .city)) { city in
                            PlaceRow(place: city, title: city.title, api: api, pipeline: pipeline, opens: !city.childIDs.isEmpty, onSelect: onSelect, onFocus: onFocus, onMap: onMap)
                        }
                    } header: {
                        Button { onSelect(country) } label: {
                            HStack {
                                Text(country.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Text(PlacesView.items(country.count)).font(.caption).foregroundStyle(.tertiary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.top, 14).padding(.bottom, 4)
                        .accessibilityLabel("All of \(country.title), \(PlacesView.items(country.count))")
                    }
                } else {
                    PlaceRow(place: country, title: country.title, api: api, pipeline: pipeline, opens: !country.childIDs.isEmpty, onSelect: onSelect, onFocus: onFocus, onMap: onMap)
                }
            }
        }
    }
}

private struct PlaceRow: View {
    let place: PlaceHierarchy.Node
    let title: String
    let api: APIClient
    let pipeline: MediaPipeline
    /// The row opens the place's parts; otherwise it opens its photos.
    let opens: Bool
    let onSelect: (PlaceHierarchy.Node) -> Void
    let onFocus: (PlaceHierarchy.Node) -> Void
    let onMap: (PlaceHierarchy.Node) -> Void

    var body: some View {
        HStack(spacing: 14) {
            if opens {
                NavigationLink(value: PlaceRoute(id: place.id)) { label }.buttonStyle(.plain)
            } else {
                Button { onSelect(place) } label: { label }.buttonStyle(.plain)
            }
            Menu {
                Button("Open photos", systemImage: "photo.on.rectangle") { onSelect(place) }
                Button("Show on the Earth", systemImage: "globe") { onFocus(place) }
                Button("Map details", systemImage: "map") { onMap(place) }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Actions for \(place.title)")
        }.padding(.vertical, 10)
    }

    private var label: some View {
        HStack(spacing: 14) {
            FeatureThumbnail(api: api, pipeline: pipeline, assetID: place.coverID).frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text([place.level == .country ? nil : place.countryName, PlacesView.items(place.count)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if opens { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }.contentShape(Rectangle())
    }
}

/// The sheet of locations over the library's Earth: the places by continent and country, each
/// opening into its parts, and a search over every place by name.
private struct PlacesListView: View {
    let hierarchy: PlaceHierarchy
    let api: APIClient
    let pipeline: MediaPipeline
    let onSelect: (PlaceHierarchy.Node) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        Group {
            if query.isEmpty {
                PlaceRows(hierarchy: hierarchy, parent: nil, api: api, pipeline: pipeline, inline: false, onSelect: onSelect, onFocus: onSelect, onMap: onSelect)
            } else {
                List(matches) { place in
                    PlaceRow(place: place, title: place.title, api: api, pipeline: pipeline, opens: false, onSelect: onSelect, onFocus: onSelect, onMap: onSelect)
                }.listStyle(.plain)
            }
        }
        .accessibilityIdentifier("places.list")
        .navigationTitle("Locations").searchable(text: $query, prompt: "Find a location")
        .navigationDestination(for: PlaceRoute.self) { route in
            PlaceRows(hierarchy: hierarchy, parent: hierarchy[route.id], api: api, pipeline: pipeline, inline: false, onSelect: onSelect, onFocus: onSelect, onMap: onSelect)
                .navigationTitle(hierarchy[route.id]?.title ?? "")
        }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private var matches: [PlaceHierarchy.Node] {
        hierarchy.nodes.values.filter { $0.title.localizedStandardContains(query) || ($0.countryName?.localizedStandardContains(query) == true) }
            .sorted(by: PlaceHierarchy.biggestFirst)
    }
}

private struct PlaceMapDetail: View {
    let place: PlaceHierarchy.Node
    let onSelect: (PlaceHierarchy.Node) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mapDetailStyle") private var style = "satellite"
    var body: some View {
        Map(initialPosition: .region(.init(center: .init(latitude: place.latitude, longitude: place.longitude), span: .init(latitudeDelta: 0.15, longitudeDelta: 0.15)))) {
            Marker(place.title, coordinate: .init(latitude: place.latitude, longitude: place.longitude))
        }.mapStyle(style == "standard" ? .standard(elevation: .realistic) : style == "hybrid" ? .hybrid(elevation: .realistic) : .imagery(elevation: .realistic))
        .navigationTitle(place.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Open photos") { dismiss(); onSelect(place) } }
            ToolbarItem(placement: .bottomBar) {
                Picker("Map style", selection: $style) { Text("Map").tag("standard"); Text("Satellite").tag("satellite"); Text("Hybrid").tag("hybrid") }.pickerStyle(.segmented)
            }
        }
    }
}

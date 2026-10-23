import SwiftUI
import MapKit

struct PlaceFocus: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    var assetID: String? = nil
}

struct PlaceCollection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let city: String?
    let country: String?
    let latitude: Double
    let longitude: Double
    let assetIDs: [String]
    /// What the place's feed is known by: its photos and the marker query that found them.
    let membership: PlaceMembership
    var focus: PlaceFocus { .init(latitude: latitude, longitude: longitude, assetID: assetIDs.first) }

    init(id: String, title: String, city: String?, country: String?, latitude: Double, longitude: Double,
         assetIDs: [String], markerQuery: String = "") {
        self.id = id; self.title = title; self.city = city; self.country = country
        self.latitude = latitude; self.longitude = longitude; self.assetIDs = assetIDs
        membership = PlaceMembership(placeID: id, assetIDs: assetIDs, markerQuery: markerQuery)
    }

    static func group(_ markers: [MapMarker], markerQuery: String = "") -> [PlaceCollection] {
        let valid = markers.filter { $0.lat.isFinite && $0.lon.isFinite && (-90...90).contains($0.lat) && (-180...180).contains($0.lon) }
        let grouped = Dictionary(grouping: valid) { marker in
            if let city = marker.city, !city.isEmpty { return [marker.country ?? "", marker.state ?? "", city].joined(separator: "|") }
            return "\(Int((marker.lat * 10).rounded()))|\(Int((marker.lon * 10).rounded()))"
        }
        return grouped.map { key, markers in
            let first = markers[0]
            let title = first.city?.isEmpty == false ? first.city! : first.country?.isEmpty == false ? first.country! : String(format: "%.2f°, %.2f°", first.lat, first.lon)
            // Circular mean avoids a center at Greenwich for a group straddling the date line.
            let radians = markers.map { $0.lon * .pi / 180 }
            let longitude = atan2(radians.reduce(0) { $0 + sin($1) }, radians.reduce(0) { $0 + cos($1) }) * 180 / .pi
            return PlaceCollection(id: key, title: title, city: first.city, country: first.country,
                latitude: markers.reduce(0) { $0 + $1.lat } / Double(markers.count), longitude: longitude, assetIDs: Array(Set(markers.map(\.id))).sorted(),
                markerQuery: markerQuery)
        }.sorted { $0.assetIDs.count == $1.assetIDs.count ? $0.title < $1.title : $0.assetIDs.count > $1.assetIDs.count }
    }
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
    /// Every place, whole: a place chosen is always the whole place.
    @State private var places: [PlaceCollection] = []
    /// The places shown and their lights: every one, or under a stack of filters only those holding
    /// its photos, each counting only those.
    @State private var shown: [PlaceCollection] = []
    @State private var lights: GlobePhotoLights?
    @State private var markers: [MapMarker] = []
    @State private var markerQuery = ""
    /// Moves each time markers load, so what is shown is arranged again for the latest narrowing.
    @State private var markersRevision = 0
    /// The narrowing `shown` was arranged for, by its identity: the stack and its count.
    @State private var arrangedFor: String?
    @State private var selected: PlaceCollection?
    @State private var loading = true
    @State private var failure: FeatureFailure?
    @State private var mapPlace: PlaceCollection?
    @State private var favoritesOnly = false
    @State private var includeArchived = false
    @State private var includePartners = true
    @State private var mapEnabled: Bool?
    @State private var generation = UUID()
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
                PlacesGlobeView(places: shown, lights: lights, focus: globeFocus, compact: true, api: api, pipeline: pipeline,
                                onSelect: { selected = $0; onSelect(whole($0)) })
                    .overlay(alignment: .bottomTrailing) {
                        Button("All locations", systemImage: "list.bullet") { showingLocations = true }
                            .font(.subheadline).buttonStyle(.glass).foregroundStyle(.primary)
                            .padding(16).padding(.bottom, bottomInset).disabled(loading || shown.isEmpty)
                    }
                    .overlay { if loading { ProgressView() } }
            } else {
            ScrollView {
                PlacesGlobeView(places: places, lights: lights, focus: selected?.focus ?? focus, api: api, pipeline: pipeline, onSelect: { selected = $0 })
                    .frame(height: min(geometry.size.height * 0.55, 460)).clipped()
                if let selected {
                    HStack(spacing: 14) {
                        FeatureThumbnail(api: api, pipeline: pipeline, assetID: selected.assetIDs.first).frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 9))
                        VStack(alignment: .leading) { Text(selected.title).font(.headline); Text("\(selected.assetIDs.count.formatted()) items").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Open photos") { onSelect(selected) }.buttonStyle(.borderedProminent)
                    }.padding(.horizontal, 20).padding(.bottom, 12)
                }
                if loading { ProgressView().padding() }
                else if places.isEmpty { FeatureEmpty(title: "No locations yet", symbol: "globe.europe.africa", description: "Photos with location data will appear on your globe.") }
                LazyVStack(spacing: 0) {
                    ForEach(places) { place in
                        HStack(spacing: 14) {
                            Button { selected = place } label: {
                                HStack(spacing: 14) {
                                    FeatureThumbnail(api: api, pipeline: pipeline, assetID: place.assetIDs.first).frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 9))
                                    VStack(alignment: .leading, spacing: 3) { Text(place.title).font(.headline); Text([place.country, "\(place.assetIDs.count.formatted()) items"].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Menu {
                                Button("Open photos", systemImage: "photo.on.rectangle") { onSelect(place) }
                                Button("Map details", systemImage: "map") { mapPlace = place }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Actions for \(place.title)")
                        }.padding(.vertical, 10)
                    }
                }.padding(.horizontal, 20)
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
        .task(id: "\(favoritesOnly)|\(includeArchived)|\(includePartners)|\(dateFilter)|\(startDate)|\(endDate)") { await load() }
        // The filters stacked changed or were counted again, or markers loaded under an older
        // narrowing: shown again.
        .task(id: "\(narrowing?.identity ?? "")|\(markersRevision)") { await arrange() }
        .refreshable { await load() }
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
        .sheet(item: $mapPlace, onDismiss: sheetDismissed) { place in NavigationStack { PlaceMapDetail(place: place, onSelect: onSelect) } }
        .sheet(isPresented: $showingLocations, onDismiss: sheetDismissed) {
            NavigationStack {
                PlacesListView(places: shown, api: api, pipeline: pipeline) { place in
                    selected = place; showingLocations = false; onSelect(whole(place))
                }
            }
            .presentationDetents([.height(300), .medium])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
        }
        .alert("Couldn’t load places", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("Retry") { Task { await load() } }; Button("Cancel", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
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

    private var presenting: Bool { showingDates || showingLocations || mapPlace != nil || failure != nil }

    private func sheetDismissed() {
        sheetUp = false
        if !presenting { onPresentation(false) }
    }
    private var globeFocus: PlaceFocus? {
        selected?.focus ?? focus ?? places.first.map { .init(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func load() async {
        let requestGeneration = UUID(); generation = requestGeneration
        loading = true; failure = nil
        defer { if requestGeneration == generation { loading = false } }
        do {
            let features = try await api.serverFeatures()
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            mapEnabled = features.map
            guard features.map else { places = []; shown = []; lights = nil; markers = []; selected = nil; return }
            var fileCreatedAfter: Date?
            var fileCreatedBefore: Date?
            if dateFilter {
                let calendar = Calendar.current
                let first = calendar.startOfDay(for: startDate)
                let last = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
                fileCreatedAfter = first
                fileCreatedBefore = last
            }
            let query = MapMarkerQuery(withPartners: includePartners, withSharedAlbums: true,
                                       isArchived: includeArchived, isFavorite: favoritesOnly ? true : nil,
                                       fileCreatedAfter: fileCreatedAfter, fileCreatedBefore: fileCreatedBefore)
            let markers = try await api.mapMarkers(query)
            let markerQuery = query.queryItems.map { $0.name + "=" + ($0.value ?? "") }.joined(separator: "&")
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            let narrowing = self.narrowing
            let arranged = await Task.detached(priority: .userInitiated) {
                Self.arrange(markers, markerQuery: markerQuery, narrowing: narrowing)
            }.value
            try Task.checkCancellation(); guard generation == requestGeneration else { return }
            places = arranged.all; shown = arranged.shown; lights = arranged.lights
            self.markers = markers; self.markerQuery = markerQuery; arrangedFor = narrowing?.identity; markersRevision += 1
            if let previous = selected { selected = places.first { $0.id == previous.id } }
            else if compact, let assetID = focus?.assetID, let place = places.first(where: { $0.assetIDs.contains(assetID) }) {
                selected = place; onSelect(place)
            }
        } catch is CancellationError { } catch {
            if generation == requestGeneration { places = []; shown = []; lights = nil; markers = []; selected = nil; failure = .init(error) }
        }
    }

    /// Shows the places again for the latest narrowing, from the markers loaded, when they were
    /// arranged for another.
    private func arrange() async {
        let narrowing = self.narrowing, markers = self.markers, markerQuery = self.markerQuery
        guard !markers.isEmpty, narrowing?.identity != arrangedFor else { return }
        let arranged = await Task.detached(priority: .userInitiated) {
            Self.arrange(markers, markerQuery: markerQuery, narrowing: narrowing)
        }.value
        guard !Task.isCancelled else { return }
        shown = arranged.shown; lights = arranged.lights; arrangedFor = narrowing?.identity
    }

    /// The whole place of one shown, which may count only the photos of a stack of filters.
    private func whole(_ place: PlaceCollection) -> PlaceCollection {
        places.first { $0.id == place.id } ?? place
    }

    /// Every place, and those shown with their lights: under a narrowing only its photos, so a
    /// place without any is left out and the others count only theirs. Pure; off the main actor.
    nonisolated static func arrange(_ markers: [MapMarker], markerQuery: String, narrowing: PlaceNarrowing?)
        -> (all: [PlaceCollection], shown: [PlaceCollection], lights: GlobePhotoLights) {
        let all = PlaceCollection.group(markers, markerQuery: markerQuery)
        guard let narrowing else { return (all, all, GlobePhotoLights(markers: markers)) }
        let kept = markers.filter { narrowing.ids.contains($0.id) }
        return (all, PlaceCollection.group(kept, markerQuery: markerQuery), GlobePhotoLights(markers: kept))
    }
}

private struct PlacesListView: View {
    let places: [PlaceCollection]
    let api: APIClient
    let pipeline: MediaPipeline
    let onSelect: (PlaceCollection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        List {
            ForEach(places.filter { query.isEmpty || $0.title.localizedStandardContains(query) || ($0.country?.localizedStandardContains(query) == true) }) { place in
                Button { onSelect(place) } label: {
                    HStack(spacing: 14) {
                        FeatureThumbnail(api: api, pipeline: pipeline, assetID: place.assetIDs.first).frame(width: 48, height: 48).clipShape(.rect(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(place.title).font(.headline).foregroundStyle(.primary)
                            Text([place.country, "\(place.assetIDs.count.formatted()) items"].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }.accessibilityElement(children: .combine)
            }
        }.accessibilityIdentifier("places.list")
        .navigationTitle("Locations").searchable(text: $query, prompt: "Find a location")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

private struct PlaceMapDetail: View {
    let place: PlaceCollection
    let onSelect: (PlaceCollection) -> Void
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

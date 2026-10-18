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
    var focus: PlaceFocus { .init(latitude: latitude, longitude: longitude, assetID: assetIDs.first) }

    static func group(_ markers: [MapMarker]) -> [PlaceCollection] {
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
                latitude: markers.reduce(0) { $0 + $1.lat } / Double(markers.count), longitude: longitude, assetIDs: Array(Set(markers.map(\.id))).sorted())
        }.sorted { $0.assetIDs.count == $1.assetIDs.count ? $0.title < $1.title : $0.assetIDs.count > $1.assetIDs.count }
    }
}

struct PlacesView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onSelect: (PlaceCollection) -> Void
    var focus: PlaceFocus? = nil
    var compact = false
    @State private var places: [PlaceCollection] = []
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
    var body: some View {
        GeometryReader { geometry in
            if mapEnabled == false {
                FeatureEmpty(title: "Maps are turned off", symbol: "globe", description: "Enable maps on your server to browse photo locations.")
            } else if compact {
                PlacesGlobeView(places: places, focus: selected?.focus ?? focus, compact: true, api: api, pipeline: pipeline, onSelect: { selected = $0; onSelect($0) })
                    .overlay(alignment: .bottom) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(places.prefix(20)) { place in
                                    Button { selected = place; onSelect(place) } label: {
                                        VStack(spacing: 3) { Text(place.title).font(.subheadline.weight(.semibold)); Text(place.assetIDs.count.formatted()).font(.caption).foregroundStyle(.secondary) }
                                            .padding(.horizontal, 16).padding(.vertical, 10)
                                    }.buttonStyle(.glass)
                                }
                            }.padding(16)
                        }
                    }
                    .overlay { if loading { ProgressView() } }
            } else {
            ScrollView {
                PlacesGlobeView(places: places, focus: selected?.focus ?? focus, api: api, pipeline: pipeline, onSelect: { selected = $0 })
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
        .refreshable { await load() }
        .sheet(isPresented: $showingDates) {
            NavigationStack {
                Form {
                    Toggle("Use date range", isOn: $dateFilter)
                    DatePicker("From", selection: $startDate, in: ...endDate, displayedComponents: .date)
                    DatePicker("Through", selection: $endDate, in: startDate...Date(), displayedComponents: .date)
                }.navigationTitle("Photo dates")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDates = false } } }
            }.presentationDetents([.medium])
        }
        .sheet(item: $mapPlace) { place in NavigationStack { PlaceMapDetail(place: place, onSelect: onSelect) } }
        .alert("Couldn’t load places", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("Retry") { Task { await load() } }; Button("Cancel", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
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
            guard features.map else { places = []; selected = nil; return }
            var query = [URLQueryItem(name: "withPartners", value: String(includePartners)), .init(name: "withSharedAlbums", value: "true")]
            if favoritesOnly { query.append(.init(name: "isFavorite", value: "true")) }
            if !includeArchived { query.append(.init(name: "isArchived", value: "false")) }
            if dateFilter {
                let calendar = Calendar.current
                let first = calendar.startOfDay(for: startDate)
                let last = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
                query.append(.init(name: "fileCreatedAfter", value: first.ISO8601Format()))
                query.append(.init(name: "fileCreatedBefore", value: last.ISO8601Format()))
            }
            let markers: [MapMarker] = try await api.request(.get, path: "map/markers", query: query)
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            places = PlaceCollection.group(markers)
            if let previous = selected { selected = places.first { $0.id == previous.id } }
        } catch is CancellationError { } catch {
            if generation == requestGeneration { places = []; selected = nil; failure = .init(error) }
        }
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

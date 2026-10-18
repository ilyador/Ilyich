import SwiftUI
import MapKit
import CoreLocation
import Observation

struct LocationPickerView: View {
    let api: APIClient
    let onSelect: (CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PlaceFocus?
    @State private var camera: MapCameraPosition
    @State private var center = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @State private var query = ""
    @State private var results: [LocationSearchResult] = []
    @State private var search: MKLocalSearch?
    @State private var searching = false
    @State private var failure: String?
    @State private var mapEnabled: Bool?
    @State private var locator = LocationFixSource()
    @State private var generation = UUID()
    @AppStorage("mapDetailStyle") private var style = "satellite"

    init(api: APIClient, initial: CLLocationCoordinate2D? = nil, onSelect: @escaping (CLLocationCoordinate2D) -> Void) {
        self.api = api; self.onSelect = onSelect
        let valid = initial.flatMap { CLLocationCoordinate2DIsValid($0) ? $0 : nil }
        _selected = State(initialValue: valid.map { .init(latitude: $0.latitude, longitude: $0.longitude) })
        _camera = State(initialValue: valid.map { .region(.init(center: $0, span: .init(latitudeDelta: 0.03, longitudeDelta: 0.03))) } ?? .region(.init(center: .init(latitude: 0, longitude: 0), span: .init(latitudeDelta: 120, longitudeDelta: 180))))
    }
    var body: some View {
        VStack(spacing: 0) {
            if mapEnabled == false {
                FeatureEmpty(title: "Maps are turned off", symbol: "map", description: "Enable maps on your server before selecting a photo location.")
            } else if mapEnabled == nil {
                Spacer(); ProgressView("Loading map settings"); Spacer()
            } else {
                mapCanvas
                if !query.isEmpty {
                    searchResults.frame(maxHeight: 220)
                }
                VStack(spacing: 12) {
                    if let selected { Text(String(format: "%.5f°, %.5f°", selected.latitude, selected.longitude)).font(.subheadline.monospacedDigit()) }
                    else { Text("Tap the map to choose a location.").font(.subheadline).foregroundStyle(.secondary) }
                    HStack {
                        Button("Use map center", systemImage: "scope") { choose(center) }.buttonStyle(.glass)
                        Button { locator.request() } label: {
                            if locator.waiting { ProgressView() } else { Label("My location", systemImage: "location") }
                        }.buttonStyle(.glass).disabled(locator.waiting)
                    }
                    if let message = locator.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                        if locator.denied { Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } }
                    }
                    Text("Address search uses Apple Maps. Your location is requested only when you tap My location.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(16)
            }
            if let failure {
                HStack { Text(failure).font(.footnote); Button("Retry") { Task { if mapEnabled == nil { await loadFeatures() } else { await find() } } } }.padding()
            }
        }.navigationTitle("Choose location").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search an address or place")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use location") {
                    guard let selected else { return }
                    onSelect(.init(latitude: selected.latitude, longitude: selected.longitude)); dismiss()
                }.disabled(selected == nil || mapEnabled != true).requiresWriteAccess(api)
            }
        }
        .task { await loadFeatures() }
        .task(id: query + String(mapEnabled ?? false)) {
            search?.cancel(); generation = UUID()
            do { if !query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }; try Task.checkCancellation(); await find() } catch { }
        }
        .onChange(of: locator.coordinate) { _, coordinate in
            if let coordinate { choose(.init(latitude: coordinate.latitude, longitude: coordinate.longitude), recenter: true) }
        }
        .onDisappear { generation = UUID(); search?.cancel(); locator.stop() }
    }
    private var mapCanvas: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let selected { Marker("Selected location", coordinate: .init(latitude: selected.latitude, longitude: selected.longitude)) }
            }
            .mapStyle(style == "standard" ? .standard(elevation: .realistic) : style == "hybrid" ? .hybrid(elevation: .realistic) : .imagery(elevation: .realistic))
            .onMapCameraChange(frequency: .onEnd) { center = $0.region.center }
            .onTapGesture { point in if let coordinate = proxy.convert(point, from: .local) { choose(coordinate) } }
            .accessibilityLabel("Choose a photo location on the map")
        }.frame(minHeight: 200)
    }
    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if searching { ProgressView("Searching addresses").padding() }
                else if results.isEmpty && failure == nil { Text("No matching addresses or places.").foregroundStyle(.secondary).padding() }
                ForEach(results) { result in
                    Button { choose(result.coordinate, recenter: true); query = "" } label: {
                        VStack(alignment: .leading, spacing: 4) { Text(result.name).font(.headline); Text(result.address).font(.caption).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.background(.bar)
    }
    private func choose(_ coordinate: CLLocationCoordinate2D, recenter: Bool = false) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        selected = .init(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if recenter { camera = .region(.init(center: coordinate, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02))) }
    }
    private func loadFeatures() async {
        do { mapEnabled = try await api.serverFeatures().map; failure = nil }
        catch is CancellationError { } catch { failure = error.localizedDescription }
    }
    private func find() async {
        search?.cancel()
        let token = UUID(); generation = token
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, mapEnabled == true else { results = []; searching = false; return }
        searching = true; failure = nil
        defer { if generation == token { searching = false } }
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        if let selected { request.region = .init(center: .init(latitude: selected.latitude, longitude: selected.longitude), span: .init(latitudeDelta: 1, longitudeDelta: 1)) }
        let operation = MKLocalSearch(request: request); search = operation
        do {
            let response = try await operation.start()
            try Task.checkCancellation()
            guard generation == token else { return }
            results = response.mapItems.compactMap { item in
                let coordinate = item.location.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                return .init(name: item.name ?? "Location", address: item.address?.fullAddress ?? "", coordinate: coordinate)
            }
        } catch is CancellationError { } catch { if generation == token, !Task.isCancelled { results = []; failure = "Address search is unavailable. Choose a point on the map or try again." } }
    }
}

private struct LocationSearchResult: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
}

@MainActor @Observable private final class LocationFixSource: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var waiting = false
    private(set) var coordinate: PlaceFocus?
    private(set) var message: String?
    var denied: Bool { [.denied, .restricted].contains(manager.authorizationStatus) }
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
    func request() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") is String else {
            message = "Location access is unavailable in this build. You can still choose a point on the map."; return
        }
        message = nil; waiting = true
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: waiting = false; message = "Allow location access in Settings, or choose a point on the map."
        }
    }
    func stop() { waiting = false; manager.stopUpdatingLocation() }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard waiting else { return }
        if [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) { manager.requestLocation() }
        else if manager.authorizationStatus != .notDetermined { waiting = false; message = "Location access was not allowed. Choose a point on the map." }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard waiting else { return }; waiting = false
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { message = "Your location could not be found. Try again."; return }
        coordinate = .init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard waiting else { return }; waiting = false; message = "Your location is unavailable. Try again or choose a point on the map."
    }
}

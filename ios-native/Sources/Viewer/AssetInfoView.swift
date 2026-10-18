import SwiftUI
import MapKit

@MainActor
struct AssetInfoView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onUpdated: (Asset) -> Void
    let onExportOriginal: () -> Void
    @State private var asset: Asset
    @State private var caption: String
    @State private var albums: [Album] = []
    @State private var text: [RecognizedText] = []
    @State private var loading = true
    @State private var error: String?
    @State private var editingMetadata = false
    @State private var editingFaces = false
    @State private var collection: InfoCollection?
    @State private var saving = false

    init(api: APIClient, pipeline: MediaPipeline, asset: Asset, onUpdated: @escaping (Asset) -> Void, onExportOriginal: @escaping () -> Void) {
        self.api = api; self.pipeline = pipeline; self.onUpdated = onUpdated; self.onExportOriginal = onExportOriginal
        _asset = State(initialValue: asset); _caption = State(initialValue: asset.exifInfo?.description ?? "")
    }
    private var ownsAsset: Bool { asset.ownerId == nil || asset.ownerId == api.userID }
    var body: some View {
        Form {
            Section {
                if let date = asset.localDateTime ?? asset.fileCreatedAt {
                    LabeledContent("Taken", value: date.formatted(Date.FormatStyle(date: .long, time: .shortened, timeZone: TimeZone(secondsFromGMT: 0)!)))
                }
                if ownsAsset { Button("Adjust date and location") { editingMetadata = true } }
                TextField("Add a caption", text: $caption, axis: .vertical).disabled(!ownsAsset).lineLimit(2...6)
                if caption != (asset.exifInfo?.description ?? "") {
                    Button("Save caption") { saveCaption() }.disabled(saving)
                }
            }
            if let exif = asset.exifInfo {
                if let latitude = exif.latitude, let longitude = exif.longitude {
                    Section {
                        NavigationLink {
                            PlacesView(api: api, pipeline: pipeline, onSelect: { place in
                                guard !place.assetIDs.isEmpty else { return }
                                collection = .init(title: place.title, filter: SearchFilter(or: place.assetIDs.map { SearchIDAlternative(id: IDFilter(eq: $0)) }))
                            }, focus: .init(latitude: latitude, longitude: longitude, assetID: asset.id))
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Map(initialPosition: .region(MKCoordinateRegion(center: .init(latitude: latitude, longitude: longitude), latitudinalMeters: 3000, longitudinalMeters: 3000)), interactionModes: []) {
                                    Marker("Photo location", coordinate: .init(latitude: latitude, longitude: longitude))
                                }.frame(height: 140).clipShape(.rect(cornerRadius: 12)).accessibilityHidden(true)
                                Label([exif.city, exif.state, exif.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "), systemImage: "globe.europe.africa")
                                Text(String(format: "%.5f°, %.5f°", latitude, longitude)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.accessibilityLabel("Explore this location on the globe")
                    }
                }
                Section {
                    if let model = exif.model { Label(model, systemImage: "camera") }
                    if let lens = exif.lensModel { Text(lens).foregroundStyle(.secondary) }
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                        GridRow {
                            exifMetric("Aperture", value: exif.fNumber.map { "ƒ\($0.formatted())" })
                            exifMetric("Shutter", value: exif.exposureTime.map { "\($0) s" })
                        }
                        GridRow {
                            exifMetric("ISO", value: exif.iso.map { $0.formatted(.number.precision(.fractionLength(0))) })
                            exifMetric("Focal length", value: exif.focalLength.map { "\($0.formatted()) mm" })
                        }
                    }.padding(.vertical, 4)
                }
            }
            Section {
                Text(asset.originalFileName).font(.headline).textSelection(.enabled)
                if let width = asset.width, let height = asset.height {
                    Text("\((Double(width) * Double(height) / 1_000_000).formatted(.number.precision(.fractionLength(1)))) MP · \(width) × \(height)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let bytes = asset.exifInfo?.fileSizeInByte { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).foregroundStyle(.secondary) }
                if asset.isDeveloped {
                    Label("Lightroom edit", systemImage: "slider.horizontal.3")
                    Text("Preview developed from the XMP sidecar.").font(.caption).foregroundStyle(.secondary)
                }
                if asset.isEdited { Label("Edited in Ilyich", systemImage: "crop.rotate") }
                Button("Download original", systemImage: "arrow.down.document", action: onExportOriginal)
            }
            if !(asset.people ?? []).isEmpty || ownsAsset {
                Section("People") {
                    ForEach(asset.people ?? []) { person in
                        Button { collection = .init(title: person.name.isEmpty ? "Unnamed person" : person.name, filter: .init(personIds: .init(all: [person.id]))) } label: {
                            HStack { PersonThumbnail(pipeline: pipeline, person: person).frame(width: 40, height: 40); Text(person.name.isEmpty ? "Unnamed person" : person.name) }
                        }
                    }
                    if ownsAsset { Button("Fix faces", systemImage: "person.crop.rectangle.badge.plus") { editingFaces = true } }
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in
                        Button(album.albumName) { collection = .init(title: album.albumName, filter: .init(albumIds: .init(all: [album.id]))) }
                    }
                }
            }
            if !text.isEmpty {
                Section("Text in this photo") {
                    Text(text.map(\.text).joined(separator: "\n")).textSelection(.enabled)
                    Button("Copy all text", systemImage: "doc.on.doc") { UIPasteboard.general.string = text.map(\.text).joined(separator: "\n") }
                    Menu("Find this text in other photos", systemImage: "text.magnifyingglass") {
                        ForEach(text) { item in
                            Button(item.text) { collection = .init(title: item.text, filter: .init(ocr: .init(matches: item.text))) }
                        }
                    }
                }
            }
            if loading { Section { ProgressView("Loading details") } }
            if let error { Section { Text(error).foregroundStyle(.secondary); Button("Retry details") { Task { await loadDetails() } } } }
        }
        .navigationTitle("Info").navigationBarTitleDisplayMode(.inline)
        .task { await loadDetails() }
        .sheet(isPresented: $editingMetadata) { NavigationStack { MetadataEditor(api: api, asset: asset, onUpdated: update) } }
        .sheet(isPresented: $editingFaces) { NavigationStack { FaceAssignmentView(api: api, pipeline: pipeline, asset: asset, onChanged: { Task { if let fresh = try? await api.asset(id: asset.id) { update(fresh) } } }) } }
        .sheet(item: $collection) { selection in
            NavigationStack { InfoCollectionView(api: api, pipeline: pipeline, collection: selection) }
        }
    }
    private func exifMetric(_ title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(value ?? "—").font(.headline); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func update(_ asset: Asset) { self.asset = asset; caption = asset.exifInfo?.description ?? ""; onUpdated(asset) }
    private func saveCaption() {
        saving = true
        Task { defer { saving = false }; do { update(try await api.updateAsset(id: asset.id, update: .init(description: caption))) } catch { self.error = error.localizedDescription } }
    }
    private func loadDetails() async {
        loading = true; error = nil
        defer { loading = false }
        let api = api, id = asset.id
        async let albumsResult = Result { try await api.assetAlbums(id: id) }
        async let textResult = Result { try await api.assetOCR(id: id) }
        switch await albumsResult { case .success(let albums): self.albums = albums; case .failure(let failure): error = failure.localizedDescription }
        switch await textResult { case .success(let text): self.text = text; case .failure(let failure): error = failure.localizedDescription }
    }
}

private extension Result where Failure == Error, Success: Sendable {
    init(_ operation: @Sendable () async throws -> Success) async {
        do { self = .success(try await operation()) } catch { self = .failure(error) }
    }
}

private struct MetadataEditor: View {
    let api: APIClient
    let asset: Asset
    let onUpdated: (Asset) -> Void
    @State private var date: Date
    @State private var latitude: String
    @State private var longitude: String
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    init(api: APIClient, asset: Asset, onUpdated: @escaping (Asset) -> Void) {
        self.api = api; self.asset = asset; self.onUpdated = onUpdated
        _date = State(initialValue: asset.fileCreatedAt ?? .now)
        _latitude = State(initialValue: asset.exifInfo?.latitude.map(String.init) ?? "")
        _longitude = State(initialValue: asset.exifInfo?.longitude.map(String.init) ?? "")
    }
    var body: some View {
        Form {
            Section("Date and time") { DatePicker("Taken", selection: $date); Text("Time zone: \(TimeZone.current.identifier)").font(.caption).foregroundStyle(.secondary) }
            Section("Location") {
                TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Adjust information")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(saving) }
            }.interactiveDismissDisabled(saving)
    }
    private func save() {
        let lat = Double(latitude), lon = Double(longitude)
        if !latitude.isEmpty || !longitude.isEmpty {
            guard let lat, let lon, lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { error = "Enter a latitude from −90 to 90 and longitude from −180 to 180."; return }
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                let updated = try await api.updateAsset(id: asset.id, update: .init(dateTimeOriginal: date.ISO8601Format(), latitude: lat, longitude: lon))
                onUpdated(updated); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct InfoCollection: Identifiable {
    let id = UUID()
    let title: String
    let filter: SearchFilter
}

private struct InfoCollectionView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let collection: InfoCollection
    @State private var assets: [Asset] = []
    @State private var cursor: String?
    @State private var more = true
    @State private var loading = false
    @State private var error: String?
    @State private var viewing: Asset?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(assets) { asset in
                    Button { viewing = asset } label: { InfoThumbnail(pipeline: pipeline, asset: asset).aspectRatio(1, contentMode: .fit) }.buttonStyle(.plain)
                }
            }
            if let error { Text(error).padding(); Button("Retry") { Task { await load() } } }
            else if more { ProgressView().padding().task { await load() } }
            if assets.isEmpty && !loading && !more { ContentUnavailableView("No photos", systemImage: "photo") }
        }.navigationTitle(collection.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $viewing) { asset in
                AssetViewer(api: api, pipeline: pipeline, assets: assets, initial: asset,
                            onUpdated: { fresh in if let i = assets.firstIndex(where: { $0.id == fresh.id }) { assets[i] = fresh } },
                            onDeleted: { assets.removeAll { $0.id == asset.id } })
            }
    }
    private func load() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do {
            let response = try await api.metadataSearch(.init(filter: collection.filter, cursor: cursor))
            let seen = Set(assets.map(\.id)); assets += response.assets.items.filter { !seen.contains($0.id) }
            cursor = response.assets.nextCursor; more = cursor != nil
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
}

private struct InfoThumbnail: View {
    let pipeline: MediaPipeline
    let asset: Asset
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack { Color.secondary.opacity(0.15); if let image { Image(uiImage: image).resizable().scaledToFill() } }
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.task(id: asset.id + asset.cacheRevision) { if let result = try? await pipeline.image(for: asset, pixelSize: 450) { image = result.uiImage } }
    }
}

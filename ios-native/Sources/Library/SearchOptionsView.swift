import SwiftUI

struct SearchOptionsView: View {
    let api: APIClient
    let onApply: (SearchMode, SearchFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: SearchMode
    @State private var filter: SearchFilter
    @State private var people: [Person] = []
    @State private var tags: [AssetTag] = []
    @State private var features: ServerFeatures?
    @State private var failure: String?
    @State private var dateEnabled: Bool
    @State private var start: Date
    @State private var end: Date

    init(api: APIClient, mode: SearchMode, filter: SearchFilter, onApply: @escaping (SearchMode, SearchFilter) -> Void) {
        self.api = api; self.onApply = onApply
        _mode = State(initialValue: mode); _filter = State(initialValue: filter)
        _dateEnabled = State(initialValue: filter.takenAt != nil)
        _start = State(initialValue: filter.takenAt?.gte ?? Calendar.current.date(byAdding: .month, value: -1, to: Date())!)
        _end = State(initialValue: filter.takenAt?.lt ?? Date())
    }
    var body: some View {
        Form {
            Section("Search in") {
                Picker("Search mode", selection: $mode) {
                    ForEach(SearchMode.allCases.filter { $0 != .context || features?.smartSearch != false }.filter { $0 != .ocr || features?.ocr != false }) {
                        Text($0.rawValue).tag($0)
                    }
                }
            }
            Section("People and tags") {
                NavigationLink("People", value: "people")
                NavigationLink("Tags", value: "tags")
                if let count = filter.personIds?.all?.count { Text("\(count) people required").font(.footnote).foregroundStyle(.secondary) }
                if let count = filter.tagIds?.all?.count { Text("\(count) tags required").font(.footnote).foregroundStyle(.secondary) }
            }
            Section("Location") {
                TextField("Country", text: text(\.country))
                TextField("State or region", text: text(\.state))
                TextField("City", text: text(\.city))
            }
            Section("Camera") {
                TextField("Make", text: text(\.make))
                TextField("Model", text: text(\.model))
            }
            Section("Date taken") {
                Toggle("Limit dates", isOn: $dateEnabled)
                if dateEnabled {
                    DatePicker("From", selection: $start, displayedComponents: .date)
                    DatePicker("Through", selection: $end, in: start..., displayedComponents: .date)
                    Menu("Quick dates") {
                        Button("Today") { setDays(0) }
                        Button("Last 7 days") { setDays(6) }
                        Button("Last 30 days") { setDays(29) }
                        Button("This year") {
                            start = Calendar.current.date(from: Calendar.current.dateComponents([.year], from: Date())) ?? Date(); end = Date()
                        }
                    }
                }
            }
            Section("Media") {
                Picker("Type", selection: Binding(get: { filter.type?.eq ?? "" }, set: { filter.type = $0.isEmpty ? nil : .init(eq: $0) })) {
                    Text("Photos and videos").tag(""); Text("Photos").tag("IMAGE"); Text("Videos").tag("VIDEO")
                }
                Toggle("Favorites only", isOn: flag(\.isFavorite))
                Toggle("Motion photos only", isOn: flag(\.isMotion))
                Toggle("Not in an album", isOn: Binding(get: { filter.hasAlbums?.eq == false }, set: { filter.hasAlbums = $0 ? .init(eq: false) : nil }))
                Picker("Rating", selection: Binding(get: { filter.rating.map { $0.eq ?? 0 } ?? -1 }, set: { filter.rating = $0 == -1 ? nil : .init(eq: $0 == 0 ? nil : $0) })) {
                    Text("Any rating").tag(-1); Text("Unrated").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) stars").tag($0) }
                }
                Picker("Visibility", selection: Binding(get: { filter.visibility?.eq ?? "" }, set: { filter.visibility = $0.isEmpty ? nil : .init(eq: $0) })) {
                    Text("Library and archive").tag(""); Text("Library").tag("timeline"); Text("Archive").tag("archive")
                }
            }
            if let failure { Section { Text(failure).foregroundStyle(.red); Button("Retry") { Task { await load() } } } }
        }
        .navigationTitle("Search options")
        .navigationDestination(for: String.self) { page in
            if page == "people" { choices(people.map { ($0.id, $0.name.isEmpty ? "Unnamed person" : $0.name) }, path: \.personIds, title: "People") }
            else { choices(tags.map { ($0.id, $0.value) }, path: \.tagIds, title: "Tags") }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Reset") { filter = SearchFilter(); mode = .context; dateEnabled = false } }
            ToolbarItem(placement: .confirmationAction) { Button("Apply") {
                if dateEnabled {
                    filter.takenAt = .init(gte: Calendar.current.startOfDay(for: start), lt: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)))
                } else { filter.takenAt = nil }
                onApply(mode, filter); dismiss()
            }.disabled(dateEnabled && end < start) }
        }
        .task { await load() }
    }
    private func choices(_ items: [(String, String)], path: WritableKeyPath<SearchFilter, IDsFilter?>, title: String) -> some View {
        List(items, id: \.0) { id, label in
            Toggle(label, isOn: Binding(get: { filter[keyPath: path]?.all?.contains(id) == true }, set: { checked in
                var selected = filter[keyPath: path]?.all ?? []
                selected.removeAll { $0 == id }; if checked { selected.append(id) }
                filter[keyPath: path] = selected.isEmpty ? nil : .init(all: selected)
            }))
        }.navigationTitle(title)
    }
    private func text(_ path: WritableKeyPath<SearchFilter, StringFilter?>) -> Binding<String> {
        .init(get: { filter[keyPath: path]?.eq ?? "" }, set: { filter[keyPath: path] = $0.isEmpty ? nil : .init(eq: $0) })
    }
    private func flag(_ path: WritableKeyPath<SearchFilter, BoolFilter?>) -> Binding<Bool> {
        .init(get: { filter[keyPath: path]?.eq == true }, set: { filter[keyPath: path] = $0 ? .init(eq: true) : nil })
    }
    private func setDays(_ days: Int) { end = Date(); start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end }
    private func load() async {
        failure = nil
        do {
            async let personResponse = api.people()
            async let tagResponse: [AssetTag] = api.request(.get, path: "tags")
            async let featureResponse = api.serverFeatures()
            people = try await personResponse.people; tags = try await tagResponse; features = try await featureResponse
            if mode == .context && features?.smartSearch == false { mode = .filename }
        } catch { failure = error.localizedDescription }
    }
}

import SwiftUI

struct SearchOptionsView: View {
    let api: APIClient
    let onApply: (SearchMode, SearchFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: SearchMode
    @State private var filter: SearchFilter
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
        _end = State(initialValue: filter.takenAt?.lt.flatMap { Calendar.current.date(byAdding: .day, value: -1, to: $0) } ?? Date())
    }
    var body: some View {
        Form {
            Section("Search in") {
                if let features { Picker("Search mode", selection: $mode) {
                    ForEach(SearchMode.allCases.filter { $0 != .context || features.smartSearch }.filter { $0 != .ocr || features.ocr }) {
                        Text($0.rawValue).tag($0)
                    }
                } } else { ProgressView("Checking search features") }
            }
            Section("People and tags") {
                NavigationLink("People", value: "people")
                NavigationLink("Tags", value: "tags")
                if let count = filter.personIds?.all?.count { Text(count == 1 ? "1 person required" : "\(count) people required").font(.footnote).foregroundStyle(.secondary) }
                if let count = filter.tagIds?.all?.count { Text(count == 1 ? "1 tag required" : "\(count) tags required").font(.footnote).foregroundStyle(.secondary) }
            }
            Section("Place") {
                SearchMetadataField(title: "Country", api: api, request: .init(kind: .country), value: text(\.country))
                SearchMetadataField(title: "State or region", api: api, request: .init(kind: .state, country: filter.country?.eq), value: text(\.state))
                SearchMetadataField(title: "City", api: api, request: .init(kind: .city, country: filter.country?.eq, state: filter.state?.eq), value: text(\.city))
            }
            Section("Camera") {
                SearchMetadataField(title: "Make", api: api, request: .init(kind: .make), value: text(\.make))
                SearchMetadataField(title: "Model", api: api, request: .init(kind: .model, make: filter.make?.eq), value: text(\.model))
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
            Section("Media type") {
                Picker("Type", selection: Binding(get: { filter.type?.eq ?? "" }, set: { filter.type = $0.isEmpty ? nil : .init(eq: $0) })) {
                    Text("Photos and videos").tag(""); Text("Photos").tag("IMAGE"); Text("Videos").tag("VIDEO")
                }
                Toggle("Motion photos only", isOn: flag(\.isMotion))
            }
            Section("Display options") {
                Toggle("Favorites only", isOn: flag(\.isFavorite))
                Toggle("Not in an album", isOn: Binding(get: { filter.hasAlbums?.eq == false }, set: { filter.hasAlbums = $0 ? .init(eq: false) : nil }))
                Picker("Archived", selection: Binding(get: { filter.visibility.flatMap { $0.eq ?? ($0.in?.count == 1 ? $0.in?.first : nil) } ?? "" },
                                                      set: { filter.visibility = $0.isEmpty ? nil : .init(eq: $0) })) {
                    Text("Included").tag(""); Text("Left out").tag("timeline"); Text("Only archived").tag("archive")
                }
                Picker("Rating", selection: Binding(get: { filter.rating.map { $0.eq ?? 0 } ?? -1 }, set: { filter.rating = $0 == -1 ? nil : .init(eq: $0 == 0 ? nil : $0) })) {
                    Text("Any rating").tag(-1); Text("Unrated").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) stars").tag($0) }
                }
            }
            if let failure { Section { Text(failure).foregroundStyle(.red); Button("Retry") { Task { await load() } } } }
        }
        .navigationTitle("Search options")
        .navigationDestination(for: String.self) { page in
            if page == "people" { SearchPeoplePicker(api: api, selected: requiredIDs(\.personIds)) }
            else { SearchTagPicker(api: api, selected: requiredIDs(\.tagIds)) }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Reset") { filter = SearchFilter(); mode = features?.smartSearch == false ? .filename : .context; dateEnabled = false } }
            ToolbarItem(placement: .confirmationAction) { Button("Apply") {
                if dateEnabled {
                    filter.takenAt = .init(gte: Calendar.current.startOfDay(for: start), lt: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)))
                } else { filter.takenAt = nil }
                onApply(mode, filter); dismiss()
            }.disabled(features == nil || (dateEnabled && end < start)) }
        }
        .task { await load() }
    }
    private func requiredIDs(_ path: WritableKeyPath<SearchFilter, IDsFilter?>) -> Binding<[String]> {
        .init(get: { filter[keyPath: path]?.all ?? [] }, set: { ids in
            var value = filter[keyPath: path] ?? IDsFilter()
            value.all = ids.isEmpty ? nil : ids
            filter[keyPath: path] = value.all == nil && value.any == nil && value.none == nil ? nil : value
        })
    }
    private func text(_ path: WritableKeyPath<SearchFilter, StringFilter?>) -> Binding<String> {
        .init(get: { filter[keyPath: path]?.eq ?? "" }, set: { value in
            guard value != filter[keyPath: path]?.eq else { return }
            filter[keyPath: path] = value.isEmpty ? nil : .init(eq: value)
            if path == \.country { filter.state = nil; filter.city = nil }
            if path == \.state { filter.city = nil }
            if path == \.make { filter.model = nil }
        })
    }
    private func flag(_ path: WritableKeyPath<SearchFilter, BoolFilter?>) -> Binding<Bool> {
        .init(get: { filter[keyPath: path]?.eq == true }, set: { filter[keyPath: path] = $0 ? .init(eq: true) : nil })
    }
    private func setDays(_ days: Int) { end = Date(); start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end }
    private func load() async {
        failure = nil
        do {
            features = try await api.serverFeatures()
            if mode == .context && features?.smartSearch == false { mode = .filename }
            if mode == .ocr && features?.ocr == false { mode = .filename }
        } catch is CancellationError { } catch { failure = error.localizedDescription }
    }
}

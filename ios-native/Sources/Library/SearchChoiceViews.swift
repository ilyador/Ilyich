import SwiftUI

struct SearchPeoplePicker: View {
    let api: APIClient
    @Binding var selected: [String]
    @State private var query = ""
    /// The pages of people, by name, with the offline library standing in when the server is away.
    @State private var pager: PeoplePager
    @State private var pageTask: Task<Void, Never>?

    init(api: APIClient, selected: Binding<[String]>) {
        self.api = api; _selected = selected
        _pager = State(initialValue: PeoplePager(source: api))
    }

    var body: some View {
        List {
            if !selected.isEmpty { Section { Text("\(selected.count) people required"); Button("Clear people") { selected = [] } } }
            ForEach(pager.people) { person in
                Toggle(person.name.isEmpty ? "Unnamed person" : person.name, isOn: selectedBinding(person.id))
            }
            if pager.isLoading { ProgressView("Loading people") }
            if let failure = pager.failure {
                Text(failure).font(.footnote).foregroundStyle(.secondary)
                Button("Retry") { pageTask = Task { await pager.loadMore() } }.disabled(pager.isLoading)
            } else if pager.hasMore {
                Button("Load more people") { pageTask = Task { await pager.loadMore() } }.disabled(pager.isLoading)
            } else if pager.people.isEmpty && !pager.isLoading {
                ContentUnavailableView(query.isEmpty ? "No people found" : "No matching people", systemImage: "person.2")
            }
        }.navigationTitle("People").searchable(text: $query, prompt: "Find a person")
        .task(id: query) {
            pageTask?.cancel()
            await pager.start(query: query, debounce: query.isEmpty ? .zero : .milliseconds(250))
        }
        .onDisappear { pageTask?.cancel(); pager.cancel() }
    }
    private func selectedBinding(_ id: String) -> Binding<Bool> {
        .init(get: { selected.contains(id) }, set: { checked in selected.removeAll { $0 == id }; if checked { selected.append(id) } })
    }
}

struct SearchTagPicker: View {
    let api: APIClient
    @Binding var selected: [String]
    @State private var tags: [AssetTag] = []
    @State private var query = ""
    @State private var loading = true
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        List {
            if !selected.isEmpty { Section { Text("\(selected.count) tags required"); Button("Clear tags") { selected = [] } } }
            ForEach(tags.filter { query.isEmpty || $0.value.localizedStandardContains(query) }) { tag in
                Toggle(tag.value, isOn: Binding(get: { selected.contains(tag.id) }, set: { checked in
                    selected.removeAll { $0 == tag.id }; if checked { selected.append(tag.id) }
                }))
            }
            if loading { ProgressView("Loading tags") }
            if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary); Button("Retry") { retry += 1 } }
            else if !loading && tags.isEmpty { ContentUnavailableView("No tags yet", systemImage: "tag") }
        }.navigationTitle("Tags").searchable(text: $query, prompt: "Find a tag")
        .task(id: retry) {
            loading = true; failure = nil; defer { loading = false }
            do {
                let result: [AssetTag] = try await api.request(.get, path: "tags")
                try Task.checkCancellation()
                tags = result.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
            } catch is CancellationError { } catch { failure = error.localizedDescription }
        }
    }
}

struct SearchMetadataField: View {
    let title: String
    let api: APIClient
    let request: SearchSuggestionRequest
    @Binding var value: String
    @State private var suggesting = false
    var body: some View {
        HStack {
            TextField(title, text: $value).autocorrectionDisabled()
            Button("Choose \(title.lowercased()) from your photos", systemImage: "list.bullet") { suggesting = true }
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
        }
        .sheet(isPresented: $suggesting) {
            NavigationStack { SearchSuggestionPicker(api: api, title: title, request: request, selected: $value) }
        }
    }
}

private struct SearchSuggestionPicker: View {
    let api: APIClient
    let title: String
    let request: SearchSuggestionRequest
    @Binding var selected: String
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String] = []
    @State private var query = ""
    @State private var loading = true
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        List {
            Button("Any \(title.lowercased())") { selected = ""; dismiss() }
            ForEach(values.filter { query.isEmpty || $0.localizedStandardContains(query) }, id: \.self) { value in
                Button { selected = value; dismiss() } label: {
                    HStack { Text(value).foregroundStyle(.primary); Spacer(); if value == selected { Image(systemName: "checkmark").foregroundStyle(.cyan) } }
                }.accessibilityAddTraits(value == selected ? .isSelected : [])
            }
            if loading { ProgressView("Loading suggestions") }
            if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary); Button("Retry") { retry += 1 } }
            else if !loading && values.isEmpty { Text("No matching metadata was found in your photos. You can still type a value in Search options.").foregroundStyle(.secondary) }
        }.navigationTitle(title).searchable(text: $query, prompt: "Find \(title.lowercased())")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task(id: retry) {
            loading = true; failure = nil; defer { loading = false }
            do {
                let result: [String] = try await api.request(.get, path: "search/suggestions", query: request.query)
                try Task.checkCancellation(); values = Array(Set(result.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            } catch is CancellationError { } catch { failure = error.localizedDescription }
        }
    }
}

import SwiftUI

struct PeopleView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onSelect: (Person) -> Void
    @State private var people: [Person] = []
    @State private var query = ""
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var failure: FeatureFailure?
    @State private var editing: Person?
    @State private var generation = UUID()
    var body: some View {
        ScrollView {
            if people.isEmpty && !loading {
                FeatureEmpty(title: "People in your photos", symbol: "person.2", description: "Faces appear here after your server finishes recognizing them.")
            }
            LazyVGrid(columns: [.init(.adaptive(minimum: 100), spacing: 20)], spacing: 28) {
                ForEach(people.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { person in
                    Button { onSelect(person) } label: {
                        VStack(spacing: 10) {
                            PersonThumbnail(pipeline: pipeline, person: person).aspectRatio(1, contentMode: .fit)
                            Text(person.name.isEmpty ? "Unnamed person" : person.name).font(.subheadline.weight(.medium)).lineLimit(2)
                        }
                    }.buttonStyle(.plain)
                    .contextMenu { Button("Edit person", systemImage: "pencil") { editing = person } }
                }
            }.padding(20)
            if hasMore {
                Button { Task { await loadMore() } } label: {
                    if loading { ProgressView() } else { Text("Load more people") }
                }.disabled(loading).padding()
            }
        }
        .navigationTitle("People").searchable(text: $query, prompt: "Find a person")
        .task(id: query) {
            do { if !query.isEmpty { try await Task.sleep(for: .milliseconds(250)) }; await loadMore(replacing: true) } catch { }
        }
        .refreshable { await loadMore(replacing: true) }
        .sheet(item: $editing) { person in
            NavigationStack { PersonEditor(api: api, person: person) { updated in
                if let index = people.firstIndex(where: { $0.id == updated.id }) { people[index] = updated }
            } }
        }
        .alert("Couldn’t load people", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("Retry") { Task { await loadMore() } }; Button("Cancel", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func loadMore(replacing: Bool = false) async {
        guard replacing || !loading else { return }
        if replacing { generation = UUID() }
        let requestGeneration = generation, requestedPage = replacing ? 1 : page
        loading = true; defer { if requestGeneration == generation { loading = false } }
        do {
            var parameters = [URLQueryItem(name: "page", value: String(requestedPage)), .init(name: "size", value: "100")]
            if !query.isEmpty { parameters.append(.init(name: "name", value: query)) }
            let result: PeopleResponse = try await api.request(.get, path: "people", query: parameters)
            guard requestGeneration == generation else { return }
            if replacing { people = [] }
            let known = Set(people.map(\.id))
            people += result.people.filter { !known.contains($0.id) }
            hasMore = result.hasNextPage ?? (result.people.count == 100)
            page = requestedPage + 1
        } catch is CancellationError { } catch { if requestGeneration == generation { failure = .init(error) } }
    }
}

private struct PersonEditor: View {
    let api: APIClient
    let person: Person
    let onSaved: (Person) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hasBirthday = false
    @State private var birthday = Date()
    @State private var saving = false
    @State private var failure: FeatureFailure?
    var body: some View {
        Form {
            TextField("Name", text: $name).textContentType(.name)
            Toggle("Birthday", isOn: $hasBirthday)
            if hasBirthday { DatePicker("Date", selection: $birthday, in: ...Date(), displayedComponents: .date) }
        }.navigationTitle("Edit person")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving) }
        }
        .task {
            name = person.name
            if let value = person.birthDate, let date = APIDate.parse(value) { hasBirthday = true; birthday = date }
        }
        .alert("Couldn’t save person", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func save() async {
        struct Update: Encodable, Sendable {
            let name: String
            let birthDate: String?
            enum CodingKeys: String, CodingKey { case name, birthDate }
            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(name, forKey: .name)
                if let birthDate { try values.encode(birthDate, forKey: .birthDate) }
                else { try values.encodeNil(forKey: .birthDate) }
            }
        }
        saving = true; defer { saving = false }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        do {
            let updated: Person = try await api.request(.put, path: "people/\(person.id)", body: Update(name: name, birthDate: hasBirthday ? formatter.string(from: birthday) : nil))
            onSaved(updated); dismiss()
        } catch { failure = .init(error) }
    }
}

import SwiftUI

struct PeopleView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onSelect: (Person) -> Void
    /// The pages of people, by name, with the offline library standing in when the server is away.
    @State private var pager: PeoplePager
    @State private var query = ""
    @State private var editing: Person?

    init(api: APIClient, pipeline: MediaPipeline, onSelect: @escaping (Person) -> Void) {
        self.api = api; self.pipeline = pipeline; self.onSelect = onSelect
        _pager = State(initialValue: PeoplePager(source: api))
    }

    private var people: [Person] { pager.people }
    private var loading: Bool { pager.isLoading }
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
                            if let value = person.birthDate, let birthday = PersonBirthday.label(value) {
                                Text(birthday).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                        }
                    }.buttonStyle(.plain)
                    .contextMenu { Button("Edit person", systemImage: "pencil") { editing = person }.requiresWriteAccess() }
                }
            }.padding(20)
            if pager.hasMore {
                Button { Task { await pager.loadMore() } } label: {
                    if loading { ProgressView() } else { Text("Load more people") }
                }.disabled(loading).padding()
            }
        }
        .navigationTitle("People").searchable(text: $query, prompt: "Find a person")
        // The people shown stay, filtered here, until the server's answer replaces them, and stay
        // when it fails.
        .task(id: query) { await pager.start(query: query, debounce: query.isEmpty ? .zero : .milliseconds(250), keepingPeople: true) }
        .refreshable { await pager.start(query: query, keepingPeople: true) }
        .sheet(item: $editing) { person in
            NavigationStack { PersonEditor(api: api, person: person) { updated in pager.replace(updated) } }
        }
        .alert("Couldn’t load people", isPresented: Binding(get: { pager.failure != nil }, set: { if !$0 { pager.dismissFailure() } })) {
            Button("Retry") { Task { await pager.loadMore() } }; Button("Cancel", role: .cancel) { }
        } message: { Text(pager.failure ?? "") }
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
            if hasBirthday {
                DatePicker("Date", selection: $birthday, in: ...Date(), displayedComponents: .date).environment(\.calendar, PersonBirthday.calendar())
                if let age = PersonBirthday.age(birthday) { Text(age).foregroundStyle(.secondary) }
            }
        }.navigationTitle("Edit person")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving).requiresWriteAccess() }
        }
        .task {
            name = person.name
            if let value = person.birthDate, let date = PersonBirthday.parse(value) { hasBirthday = true; birthday = date }
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
        do {
            let updated: Person = try await api.request(.put, path: "people/\(person.id)", body: Update(name: name, birthDate: hasBirthday ? PersonBirthday.encode(birthday) : nil))
            onSaved(updated); dismiss()
        } catch { failure = .init(error) }
    }
}

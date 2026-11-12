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
    private var visiblePeople: [Person] { people.filter { query.isEmpty || $0.name.localizedStandardContains(query) } }
    private var loading: Bool { pager.isLoading }
    var body: some View {
        ScrollView {
            if pager.isOffline || pager.failure != nil {
                CollectionConnectionNotice(isOffline: pager.isOffline, hasSnapshot: pager.hasSnapshot, failure: pager.failure) {
                    Task {
                        if pager.failure != nil && pager.nextPage > 1 { await pager.loadMore() }
                        else { await pager.start(query: query, keepingPeople: true) }
                    }
                }
            }
            if !pager.hasSnapshot && pager.failure == nil { ProgressView().padding(60) }
            else if visiblePeople.isEmpty && pager.failure != nil {
                FeatureEmpty(title: pager.isOffline ? (pager.hasSnapshot ? "No saved people" : "People aren’t saved on this phone") : "People couldn’t load", symbol: "person.2",
                             description: pager.isOffline ? "Connect to your server to load the people in your photos." : "Try again when your server is available.")
            }
            else if loading && visiblePeople.isEmpty { ProgressView("Refreshing people").padding(60) }
            else if visiblePeople.isEmpty && !loading {
                FeatureEmpty(title: pager.isOffline ? "No saved people" : (query.isEmpty ? "People in your photos" : "No matching people"), symbol: "person.2",
                             description: pager.isOffline ? "Connect to your server to refresh the people in your photos." : (query.isEmpty ? "Faces appear here after your server finishes recognizing them." : "Try another name."))
            }
            LazyVGrid(columns: [.init(.adaptive(minimum: 100), spacing: 20)], spacing: 28) {
                ForEach(visiblePeople) { person in
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
            if pager.hasMore && pager.hasSnapshot {
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
        .onCollectionChange { change in if case .personUpdated(let person) = change { pager.replace(person) } }
        .onLibraryChange { change in
            if change.reset || !change.accessLost.isEmpty { pager.invalidateSavedContent() }
            if change.reloadsCollections || !change.accessLost.isEmpty { Task { await pager.start(query: query, keepingPeople: true) } }
        }
        .sheet(item: $editing) { person in
            // The shelves and the feed hear of the change from the account's collections.
            NavigationStack { PersonEditor(person: person) { updated in pager.replace(updated) } }
        }
    }
}

/// A person's name and birthday, saved through the account's collections (N4).
private struct PersonEditor: View {
    let person: Person
    let onSaved: (Person) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.collectionsService) private var collections
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
        guard let collections else { failure = .init(APIError.signedOut); return }
        saving = true; defer { saving = false }
        do {
            let updated = try await collections.updatePerson(person.id, name: name, birthDate: hasBirthday ? PersonBirthday.encode(birthday) : nil)
            onSaved(updated); dismiss()
        } catch { failure = .init(error) }
    }
}

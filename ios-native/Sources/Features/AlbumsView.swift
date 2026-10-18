import SwiftUI

struct AlbumsView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onSelect: (Album) -> Void
    @State private var albums: [Album] = []
    @State private var query = ""
    @State private var loading = true
    @State private var failure: FeatureFailure?
    @State private var creating = false
    @State private var editing: Album?
    @State private var sort = AlbumSort.updated

    private enum AlbumSort: String, CaseIterable { case updated = "Recently updated", name = "Name", count = "Photo count" }
    private var visible: [Album] {
        albums.filter { query.isEmpty || $0.albumName.localizedStandardContains(query) }.sorted {
            switch sort {
            case .updated: ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            case .name: $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending
            case .count: $0.assetCount > $1.assetCount
            }
        }
    }
    var body: some View {
        ScrollView {
            if loading && albums.isEmpty { ProgressView().padding(60) }
            else if visible.isEmpty {
                FeatureEmpty(title: query.isEmpty ? "Your albums" : "No matching albums", symbol: "rectangle.stack", description: query.isEmpty ? "Create an album to keep a story together." : "Try another album name.")
            } else {
                LazyVGrid(columns: [.init(.adaptive(minimum: 155), spacing: 16)], spacing: 24) {
                    ForEach(visible) { album in
                        Button { onSelect(album) } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                FeatureThumbnail(api: api, pipeline: pipeline, assetID: album.albumThumbnailAssetId, revision: album.updatedAt?.description ?? "")
                                    .aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 14))
                                HStack(alignment: .firstTextBaseline) {
                                    Text(album.albumName).font(.headline).lineLimit(2)
                                    Spacer(minLength: 2)
                                    if album.shared { Image(systemName: "person.2.fill").font(.caption).foregroundStyle(.secondary) }
                                }
                                Text("\(album.assetCount.formatted()) items").font(.caption).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .contextMenu { Button("Album details", systemImage: "slider.horizontal.3") { editing = album } }
                        .accessibilityHint("Open album. More actions are available in the context menu.")
                    }
                }.padding(20)
            }
        }
        .navigationTitle("Albums")
        .searchable(text: $query, prompt: "Find an album")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu { Picker("Sort albums", selection: $sort) { ForEach(AlbumSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } } }
                label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel("Sort albums")
            }
            ToolbarItem(placement: .topBarTrailing) { Button("Create album", systemImage: "plus") { creating = true } }
        }
        .task { await load() }.refreshable { await load() }
        .sheet(isPresented: $creating) { NavigationStack { AlbumEditor(api: api, pipeline: pipeline, album: nil) { album in albums.insert(album, at: 0) } } }
        .sheet(item: $editing) { album in
            NavigationStack { AlbumEditor(api: api, pipeline: pipeline, album: album, onSaved: { updated in
                if let index = albums.firstIndex(where: { $0.id == updated.id }) { albums[index] = updated }
            }, onDeleted: { albums.removeAll { $0.id == album.id } }) }
        }
        .alert("Couldn’t load albums", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("Retry") { Task { await load() } }; Button("Cancel", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func load() async {
        loading = true
        defer { loading = false }
        do { albums = try await api.albums() } catch is CancellationError { } catch { failure = .init(error) }
    }
}

private struct AlbumEditor: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let album: Album?
    let onSaved: (Album) -> Void
    var onDeleted: () -> Void = { }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var detail = ""
    @State private var order = "desc"
    @State private var latest: Album?
    @State private var initialized = false
    @State private var busy = false
    @State private var failure: FeatureFailure?
    @State private var confirmDelete = false
    private var current: Album? { latest ?? album }
    private var canEdit: Bool { album == nil || current?.albumUsers?.contains { $0.user.id == api.userID && ["owner", "editor"].contains($0.role) } == true }
    private var isOwner: Bool { current?.albumUsers?.contains { $0.user.id == api.userID && $0.role == "owner" } == true }
    var body: some View {
        Form {
            Section("Album") {
                TextField("Name", text: $name).disabled(!canEdit)
                TextField("Description", text: $detail, axis: .vertical).lineLimit(3...8).disabled(!canEdit)
                if album != nil { Picker("Photo order", selection: $order) { Text("Newest first").tag("desc"); Text("Oldest first").tag("asc") }.disabled(!canEdit) }
            }
            if let album = current {
                if canEdit {
                    Section("Photos") {
                        NavigationLink("Add photos") { AlbumAssetsManager(api: api, pipeline: pipeline, album: album, mode: .add, onSaved: didUpdate) }
                        NavigationLink("Remove photos") { AlbumAssetsManager(api: api, pipeline: pipeline, album: album, mode: .remove, onSaved: didUpdate) }.disabled(album.assetCount == 0)
                        NavigationLink("Choose cover") { AlbumAssetsManager(api: api, pipeline: pipeline, album: album, mode: .cover, onSaved: didUpdate) }.disabled(album.assetCount == 0)
                    }
                }
                Section {
                    LabeledContent("Photos and videos", value: album.assetCount.formatted())
                    NavigationLink("Members") { AlbumMembersView(api: api, album: album) }
                    NavigationLink("Comments and likes") { AlbumActivityView(api: api, albumID: album.id) }
                }
                if isOwner {
                    Section {
                        NavigationLink("Create a shared link") { SharedLinkEditor(api: api, album: album) }
                        Button("Delete album", role: .destructive) { confirmDelete = true }
                    } footer: { Text("Deleting an album keeps its photos and videos in your library.") }
                }
            }
        }
        .navigationTitle(album == nil ? "New album" : "Album details")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            if canEdit { ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            } }
        }
        .disabled(busy)
        .task {
            guard !initialized else { return }
            initialized = true; name = album?.albumName ?? ""; detail = album?.description ?? ""; order = album?.order ?? "desc"
            if let album { do { latest = try await api.album(id: album.id) } catch { failure = .init(error) } }
        }
        .confirmationDialog("Delete this album?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete album", role: .destructive) { Task { await delete() } }
        } message: { Text("The album will be removed for everyone. Its photos will stay in the library.") }
        .alert("Couldn’t save changes", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func save() async {
        busy = true; defer { busy = false }
        struct Body: Encodable, Sendable { let albumName: String; let description: String; let order: String? }
        do {
            let body = Body(albumName: name.trimmingCharacters(in: .whitespacesAndNewlines), description: detail, order: album == nil ? nil : order)
            let updated: Album = try await api.request(album == nil ? .post : .patch, path: album.map { "albums/\($0.id)" } ?? "albums", body: body)
            onSaved(updated); dismiss()
        } catch { failure = .init(error) }
    }
    private func didUpdate(_ updated: Album) { latest = updated; onSaved(updated) }
    private func delete() async {
        guard let album else { return }
        busy = true; defer { busy = false }
        do { try await api.deleteAlbum(id: album.id); onDeleted(); dismiss() } catch { failure = .init(error) }
    }
}

private struct AlbumMembersView: View {
    let api: APIClient
    let album: Album
    @State private var members: [AlbumUser] = []
    @State private var users: [User] = []
    @State private var failure: FeatureFailure?
    @State private var busy = false
    private var owner: Bool { members.contains { $0.user.id == api.userID && $0.role == "owner" } }
    var body: some View {
        List {
            Section("Members") {
                ForEach(members, id: \.user.id) { member in
                    HStack {
                        Text(member.user.name); Spacer()
                        if owner && member.role != "owner" {
                            Menu(member.role.capitalized) {
                                Button("Viewer") { Task { await update(member, role: "viewer") } }
                                Button("Editor") { Task { await update(member, role: "editor") } }
                                Button("Remove member", role: .destructive) { Task { await remove(member) } }
                            }
                        } else { Text(member.role.capitalized).foregroundStyle(.secondary) }
                    }
                }
            }
            if owner {
                Section("Add a member") {
                    ForEach(users.filter { user in !members.contains { $0.user.id == user.id } }) { user in
                        Menu(user.name) {
                            Button("Add as viewer") { Task { await add(user, role: "viewer") } }
                            Button("Add as editor") { Task { await add(user, role: "editor") } }
                        }
                    }
                }
            }
        }.navigationTitle("Members").disabled(busy)
        .task {
            members = album.albumUsers ?? []
            if owner { do { users = try await api.request(.get, path: "users") } catch { failure = .init(error) } }
        }
        .alert("Couldn’t update members", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func refresh() async throws { members = try await api.album(id: album.id).albumUsers ?? [] }
    private func update(_ member: AlbumUser, role: String) async {
        busy = true; defer { busy = false }
        do { try await api.requestVoid(.put, path: "albums/\(album.id)/user/\(member.user.id)", body: ["role": role]); try await refresh() } catch { failure = .init(error) }
    }
    private func remove(_ member: AlbumUser) async {
        busy = true; defer { busy = false }
        do { try await api.requestVoid(.delete, path: "albums/\(album.id)/user/\(member.user.id)"); try await refresh() } catch { failure = .init(error) }
    }
    private func add(_ user: User, role: String) async {
        struct Member: Encodable, Sendable { let userId: String; let role: String }
        struct Body: Encodable, Sendable { let albumUsers: [Member] }
        busy = true; defer { busy = false }
        do { try await api.requestVoid(.put, path: "albums/\(album.id)/users", body: Body(albumUsers: [.init(userId: user.id, role: role)])); try await refresh() } catch { failure = .init(error) }
    }
}

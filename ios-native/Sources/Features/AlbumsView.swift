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
    @AppStorage("albumLayout") private var layout = "grid"

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
                if layout == "list" {
                    LazyVStack(spacing: 12) {
                        ForEach(visible) { album in
                            Button { onSelect(album) } label: {
                                HStack(spacing: 14) {
                                    FeatureThumbnail(api: api, pipeline: pipeline, assetID: album.albumThumbnailAssetId, revision: album.updatedAt?.description ?? "")
                                        .frame(width: 72, height: 72).clipShape(.rect(cornerRadius: 10))
                                    albumLabels(album)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .contextMenu { Button("Album details", systemImage: "slider.horizontal.3") { editing = album } }
                        }
                    }.padding(20)
                } else {
                    LazyVGrid(columns: [.init(.adaptive(minimum: 155), spacing: 16)], spacing: 24) {
                        ForEach(visible) { album in
                            Button { onSelect(album) } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    FeatureThumbnail(api: api, pipeline: pipeline, assetID: album.albumThumbnailAssetId, revision: album.updatedAt?.description ?? "")
                                        .aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 14))
                                    albumLabels(album)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .contextMenu { Button("Album details", systemImage: "slider.horizontal.3") { editing = album } }
                            .accessibilityHint("Open album. More actions are available in the context menu.")
                        }
                    }.padding(20)
                }
            }
        }
        .navigationTitle("Albums")
        .searchable(text: $query, prompt: "Find an album")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort albums", selection: $sort) { ForEach(AlbumSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("Layout", selection: $layout) { Text("Grid").tag("grid"); Text("List").tag("list") }
                }
                label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel("Sort albums")
            }
            ToolbarItem(placement: .topBarTrailing) { Button("Create album", systemImage: "plus") { creating = true }.requiresWriteAccess() }
        }
        .task { await load() }.refreshable { await load() }
        // An album made, changed, deleted or left anywhere, this screen's editors included, shows
        // here at once (N4).
        .onCollectionChange { change in albums = CollectionsStore.applying([change], to: albums) }
        .sheet(isPresented: $creating) { NavigationStack { AlbumEditor(api: api, pipeline: pipeline, album: nil) } }
        .sheet(item: $editing) { album in NavigationStack { AlbumEditor(api: api, pipeline: pipeline, album: album) } }
        .alert("Couldn’t load albums", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("Retry") { Task { await load() } }; Button("Cancel", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func albumLabels(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(album.albumName).font(.headline).lineLimit(2)
                if album.shared { Image(systemName: "person.2.fill").font(.caption).foregroundStyle(.secondary) }
            }
            Text("\(album.assetCount.formatted()) items").font(.caption).foregroundStyle(.secondary)
            if let dates = albumDateRange(album) { Text(dates).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func load() async {
        loading = true
        defer { loading = false }
        do { albums = try await api.albums() } catch is CancellationError { } catch { failure = .init(error) }
    }
}

/// Makes an album, or shows and changes one: its name, description and order, its photos, members,
/// links and activity. Every change goes through the account's collections, which every list
/// showing the album applies (N4).
struct AlbumEditor: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let album: Album?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.collectionsService) private var collections
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
                TextField("Name", text: $name).disabled(!canEdit).requiresWriteAccess()
                TextField("Description", text: $detail, axis: .vertical).lineLimit(3...8).disabled(!canEdit).requiresWriteAccess()
                if album != nil { Picker("Photo order", selection: $order) { Text("Newest first").tag("desc"); Text("Oldest first").tag("asc") }.disabled(!canEdit).requiresWriteAccess() }
            }
            if let album = current {
                Section {
                    AlbumUploadStatusView(albumID: album.id) { Task { await refreshAlbum() } }
                }
                if canEdit {
                    Section("Photos") {
                        NavigationLink("Add photos") { AlbumAssetsManager(api: api, pipeline: pipeline, album: album, mode: .add, onSaved: didUpdate) }.requiresWriteAccess()
                        NavigationLink("Remove photos") { AlbumAssetsManager(api: api, pipeline: pipeline, album: album, mode: .remove, onSaved: didUpdate) }.disabled(album.assetCount == 0).requiresWriteAccess()
                        NavigationLink("Choose cover") { AlbumAssetsManager(api: api, pipeline: pipeline, album: album, mode: .cover, onSaved: didUpdate) }.disabled(album.assetCount == 0).requiresWriteAccess()
                    }
                }
                Section {
                    LabeledContent("Photos and videos", value: album.assetCount.formatted())
                    if let dates = albumDateRange(album) { LabeledContent("Dates", value: dates) }
                    NavigationLink("Members") { AlbumMembersView(api: api, album: album, onLeft: { dismiss() }) }
                    NavigationLink("Comments and likes") { AlbumActivityView(api: api, albumID: album.id) }
                }
                if isOwner {
                    Section {
                        NavigationLink("Create a shared link") { SharedLinkEditor(api: api, album: album) }.requiresWriteAccess()
                        Button("Delete album", role: .destructive) { confirmDelete = true }.requiresWriteAccess()
                    } footer: { Text("Deleting an album keeps its photos and videos in your library.") }
                }
            }
        }
        .navigationTitle(album == nil ? "New album" : "Album details")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            if canEdit { ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy).requiresWriteAccess()
            } }
        }
        .disabled(busy)
        .task {
            guard !initialized else { return }
            initialized = true; name = album?.albumName ?? ""; detail = album?.description ?? ""; order = album?.order ?? "desc"
            if album != nil { await refreshAlbum() }
        }
        .confirmationDialog("Delete this album?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete album", role: .destructive) { Task { await delete() } }.requiresWriteAccess()
        } message: { Text("The album will be removed for everyone. Its photos will stay in the library.") }
        .alert("Couldn’t save changes", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func save() async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        busy = true; defer { busy = false }
        let albumName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let album { _ = try await collections.updateAlbum(album.id, name: albumName, description: detail, order: order) }
            else { _ = try await collections.createAlbum(name: albumName, description: detail) }
            dismiss()
        } catch { failure = .init(error) }
    }
    /// The album as its photos' screen left it. The lists hear of it from the account's collections.
    private func didUpdate(_ updated: Album) { latest = updated }
    /// The album read again, here and in every list showing it.
    private func refreshAlbum() async {
        guard let album else { return }
        guard let collections else { failure = .init(APIError.signedOut); return }
        do { latest = try await collections.refreshAlbum(album.id) } catch is CancellationError { } catch { failure = .init(error) }
    }
    private func delete() async {
        guard let album else { return }
        guard let collections else { failure = .init(APIError.signedOut); return }
        busy = true; defer { busy = false }
        do { try await collections.deleteAlbum(album.id); dismiss() } catch { failure = .init(error) }
    }
}

/// An album's members, their roles and its shared links, with leaving a shared album. Every change
/// goes through the account's collections (N4).
struct AlbumMembersView: View {
    let api: APIClient
    let album: Album
    /// The account left the album; the screen that showed this one closes it.
    let onLeft: () -> Void
    @Environment(\.collectionsService) private var collections
    @State private var confirmLeave = false
    @State private var members: [AlbumUser] = []
    @State private var users: [User] = []
    @State private var failure: FeatureFailure?
    @State private var busy = false
    /// Links sharing this album: an album shared only by link is still shared.
    @State private var links: [SharedLink] = []
    @State private var editingLink: SharedLink?
    @State private var removingLink: SharedLink?
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
                            }.requiresWriteAccess()
                        } else { Text(member.role.capitalized).foregroundStyle(.secondary) }
                    }
                }
            }
            if !links.isEmpty {
                Section("Shared links") {
                    ForEach(links) { link in
                        SharedLinkRow(api: api, link: link, onEdit: { editingLink = link }, onRemove: { removingLink = link })
                    }
                }
            }
            if owner {
                Section("Add a member") {
                    ForEach(users.filter { user in !members.contains { $0.user.id == user.id } }) { user in
                        Menu(user.name) {
                            Button("Add as viewer") { Task { await add(user, role: "viewer") } }
                            Button("Add as editor") { Task { await add(user, role: "editor") } }
                        }.requiresWriteAccess()
                    }
                }
            }
            if !owner, members.contains(where: { $0.user.id == api.userID }) {
                Section {
                    Button("Leave album", role: .destructive) { confirmLeave = true }.requiresWriteAccess()
                } footer: { Text("You will lose access to this shared album. Photos you own remain in your library.") }
            }
        }.navigationTitle("Sharing").disabled(busy)
        .confirmationDialog("Leave this shared album?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave album", role: .destructive) { Task { await leave() } }.requiresWriteAccess()
        } message: { Text("An album owner will need to invite you again to restore access.") }
        .task {
            members = album.albumUsers ?? []
            // An album from a list can arrive without its members.
            if members.isEmpty { try? await refresh() }
            await loadLinks()
            if owner, let collections { do { users = try await collections.users() } catch { failure = .init(error) } }
        }
        .sheet(item: $editingLink) { link in
            NavigationStack { SharedLinkEditor(api: api, album: link.album, link: link, onSaved: { Task { await loadLinks() } }) }
        }
        .confirmationDialog("Remove this shared link?", isPresented: Binding(get: { removingLink != nil }, set: { if !$0 { removingLink = nil } }), titleVisibility: .visible) {
            Button("Remove link", role: .destructive) { if let link = removingLink { Task { await removeLink(link) } } }.requiresWriteAccess()
        } message: { Text("Anyone with the link will lose access. Your photos stay in your library.") }
        .alert("Couldn’t update members", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    /// Leaving takes the album off the shelves, the albums list and the feed it filters, through
    /// the account's collections; then the screen that showed this one closes it.
    private func leave() async {
        guard !owner else { return }
        guard let collections else { failure = .init(APIError.signedOut); return }
        busy = true; defer { busy = false }
        do { try await collections.leaveAlbum(album.id); onLeft() }
        catch { failure = .init(error) }
    }
    private func refresh() async throws {
        guard let collections else { throw APIError.signedOut }
        members = try await collections.refreshAlbum(album.id).albumUsers ?? []
    }
    /// The members part still works when the links cannot load, so a failure only leaves them out.
    private func loadLinks() async { links = (try? await collections?.sharedLinks(albumID: album.id)) ?? links }
    private func removeLink(_ link: SharedLink) async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        do { try await collections.deleteLink(link.id); links.removeAll { $0.id == link.id }; removingLink = nil }
        catch { failure = .init(error) }
    }
    private func update(_ member: AlbumUser, role: String) async {
        await changeMembers { try await $0.setRole(role, of: member.user.id, in: album.id) }
    }
    private func remove(_ member: AlbumUser) async {
        await changeMembers { try await $0.removeMember(member.user.id, from: album.id) }
    }
    private func add(_ user: User, role: String) async {
        await changeMembers { try await $0.addMembers([user.id], role: role, to: album.id) }
    }
    /// A change to the members, which come back with the album as the server then has it.
    private func changeMembers(_ change: (CollectionsService) async throws -> Album) async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        busy = true; defer { busy = false }
        do { members = try await change(collections).albumUsers ?? [] } catch { failure = .init(error) }
    }
}

private func albumDateRange(_ album: Album) -> String? {
    guard let start = album.startDate else { return nil }
    let style = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(secondsFromGMT: 0)!)
    let first = start.formatted(style)
    guard let end = album.endDate, end.formatted(style) != first else { return first }
    return first + " – " + end.formatted(style)
}

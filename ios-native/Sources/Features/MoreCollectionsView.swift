import SwiftUI

struct MoreCollectionsView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onOpenAsset: (Asset) -> Void
    /// Shows a feed: one of More's collections, which the library stacks with its other filters
    /// (REBUILD_ROADMAP.md N6), or a partner's.
    let onFilter: (LibraryQuery, String) -> Void
    /// Plays memories over More.
    let onPlayMemory: (MemoryPlayback) -> Void
    var body: some View {
        List {
            Section("On your device") {
                NavigationLink { LocalLibraryView() } label: { Label("On this phone", systemImage: "iphone") }
                NavigationLink { FreeUpSpaceView() } label: { Label("Free up space", systemImage: "internaldrive") }
            }
            Section {
                Button { onFilter(.recentlyTaken, "Recently taken") } label: { Label("Recently taken", systemImage: "camera") }
                Button { onFilter(.recentlyAdded, "Recently added") } label: { Label("Recently added", systemImage: "clock.badge.checkmark") }
                Button { onFilter(.favorites, "Favorites") } label: { Label("Favorites", systemImage: "heart") }
                Button { onFilter(.videos, "Videos") } label: { Label("Videos", systemImage: "video") }
                Button { onFilter(.motion, "Motion") } label: { Label("Motion", systemImage: "livephoto") }
                Button { onFilter(.lightroom, "Lightroom") } label: { Label("Lightroom", systemImage: "slider.horizontal.3") }
                NavigationLink { MemoriesView(api: api, pipeline: pipeline, onOpenAsset: onOpenAsset, onPlay: onPlayMemory) } label: { Label("On this day", systemImage: "clock.arrow.circlepath") }
            }
            Section("Shared") {
                NavigationLink { PartnersView(api: api, onFilter: onFilter) } label: { Label("Partners", systemImage: "person.2") }
                NavigationLink { SharedLinksView(api: api) } label: { Label("Shared links", systemImage: "link") }
            }
            Section("Library") {
                NavigationLink { FoldersView(api: api, pipeline: pipeline, onOpenAsset: onOpenAsset) } label: { Label("Folders", systemImage: "folder") }
                NavigationLink { DuplicatesView(api: api, pipeline: pipeline, onOpenAsset: onOpenAsset) } label: { Label("Duplicates", systemImage: "square.on.square") }
                Button { onFilter(.archive, "Archive") } label: { Label("Archive", systemImage: "archivebox") }
                NavigationLink { LockedFolderView(api: api, pipeline: pipeline, onOpenAsset: onOpenAsset) } label: { Label("Locked folder", systemImage: "lock") }
                NavigationLink { TrashView(api: api, pipeline: pipeline, onOpenAsset: onOpenAsset) } label: { Label("Trash", systemImage: "trash") }
            }
        }.navigationTitle("More")
    }
}

struct MemoriesView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onOpenAsset: (Asset) -> Void
    /// Plays memories over this screen. Opening a photo or showing it in the timeline from the
    /// player goes through the library's navigator, which closes the player and this screen first.
    let onPlay: (MemoryPlayback) -> Void
    var initialID: String? = nil
    @Environment(\.collectionsService) private var collections
    @State private var openedInitial = false
    @State private var memories: [Memory] = []
    @State private var savedOnly = false
    @State private var loading = true
    @State private var failure: FeatureFailure?
    var body: some View {
        ScrollView {
            if loading { ProgressView().padding(50) }
            else if memories.isEmpty { FeatureEmpty(title: "Memories will appear here", symbol: "clock.arrow.circlepath", description: "Look back at moments from your library.") }
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(memories) { memory in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(memoryTitle(memory)).font(.title2.bold()); Spacer()
                            Button("Play memory", systemImage: "play.fill") { onPlay(MemoryPlayback(memories: memories, initialID: memory.id)) }.labelStyle(.iconOnly).disabled(memory.assets.isEmpty)
                            Button { Task { await toggleSaved(memory) } } label: { Image(systemName: memory.isSaved ? "bookmark.fill" : "bookmark") }
                                .accessibilityLabel(memory.isSaved ? "Unsave memory" : "Save memory").requiresWriteAccess()
                        }.padding(.horizontal, 20)
                        FeatureAssetGrid(pipeline: pipeline, assets: memory.assets, onOpenAsset: onOpenAsset)
                    }
                }
            }.padding(.vertical, 16)
        }.navigationTitle(savedOnly ? "Saved memories" : "On this day")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Toggle("Saved memories", isOn: $savedOnly).toggleStyle(.button) } }
        .task(id: savedOnly) { await load() }.refreshable { await load() }
        .alert("Couldn’t update memories", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func memoryTitle(_ memory: Memory) -> String {
        if let name = memory.data.personName { return name }
        return memory.memoryAt.formatted(.dateTime.month(.wide).day()) + " · " + String(memory.data.year)
    }
    private func load() async {
        loading = true; defer { loading = false }
        guard let collections else { failure = .init(APIError.signedOut); return }
        do {
            if let initialID, !openedInitial {
                let memory = try await collections.memory(initialID)
                try Task.checkCancellation()
                memories = [memory]; openedInitial = true
                onPlay(MemoryPlayback(memories: [memory], initialID: memory.id))
            } else {
                let loaded = try await collections.memories(savedOnly: savedOnly)
                try Task.checkCancellation()
                memories = loaded
            }
        } catch is CancellationError { } catch { failure = .init(error) }
    }
    private func toggleSaved(_ memory: Memory) async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        do { try await collections.setMemorySaved(memory.id, !memory.isSaved); await load() } catch { failure = .init(error) }
    }
}

/// Who shares their library with the account and whom it shares its own with. Every change goes
/// through the account's collections (N4), and the feed reads itself again.
struct PartnersView: View {
    let api: APIClient
    let onFilter: (LibraryQuery, String) -> Void
    @Environment(\.collectionsService) private var collections
    @State private var incoming: [Partner] = []
    @State private var outgoing: [Partner] = []
    @State private var candidates: [User] = []
    @State private var failure: FeatureFailure?
    @State private var loading = true
    @State private var pendingRemoval: Partner?
    @State private var pendingShare: User?
    var body: some View {
        List {
            if loading { ProgressView() }
            Section("Shared with you") {
                ForEach(incoming) { partner in
                    VStack(alignment: .leading, spacing: 10) {
                        Button(partner.name) { onFilter(.partner(partner.id), partner.name) }
                        Toggle("Show in your timeline", isOn: Binding(get: { partner.inTimeline == true }, set: { value in Task { await setTimeline(partner, value: value) } })).font(.subheadline).requiresWriteAccess()
                    }.padding(.vertical, 4)
                }
                if incoming.isEmpty && !loading { Text("No partner libraries yet").foregroundStyle(.secondary) }
            }
            Section("You’re sharing with") {
                ForEach(outgoing) { partner in Text(partner.name).swipeActions { Button("Stop sharing", role: .destructive) { pendingRemoval = partner }.requiresWriteAccess() } }
                if outgoing.isEmpty && !loading { Text("Your library is not shared with any partners.").foregroundStyle(.secondary) }
            }
            Section("Share your library") {
                ForEach(candidates.filter { user in user.id != api.userID && !outgoing.contains { $0.id == user.id } }) { user in
                    Button(user.name) { pendingShare = user }.requiresWriteAccess()
                }
            }
        }.navigationTitle("Partners").task { await load() }.refreshable { await load() }
        .confirmationDialog("Share your library with \(pendingShare?.name ?? "this person")?", isPresented: Binding(get: { pendingShare != nil }, set: { if !$0 { pendingShare = nil } }), titleVisibility: .visible) {
            Button("Share library") { if let user = pendingShare { Task { await share(user) } } }.requiresWriteAccess()
        } message: { Text("They will be able to browse your shared library. Locked photos stay private.") }
        .confirmationDialog("Stop sharing your library?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) { if let partner = pendingRemoval { Task { await remove(partner) } } }.requiresWriteAccess()
        }
        .alert("Couldn’t update partners", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func load() async {
        defer { loading = false }
        guard let collections else { failure = .init(APIError.signedOut); return }
        do {
            let lists = try await collections.partners()
            (incoming, outgoing, candidates) = (lists.incoming, lists.outgoing, lists.candidates)
        } catch { failure = .init(error) }
    }
    private func setTimeline(_ partner: Partner, value: Bool) async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        do { try await collections.showPartnerInTimeline(partner.id, value); await load() } catch { failure = .init(error) }
    }
    private func share(_ user: User) async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        do { try await collections.sharePartner(with: user.id); pendingShare = nil; await load() } catch { failure = .init(error) }
    }
    private func remove(_ partner: Partner) async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        do { try await collections.removePartner(partner.id); pendingRemoval = nil; await load() } catch { failure = .init(error) }
    }
}

struct FoldersView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onOpenAsset: (Asset) -> Void
    @State private var folders: [String] = []
    @State private var query = ""
    @State private var loading = true
    @State private var failure: FeatureFailure?
    var body: some View {
        List {
            if loading { ProgressView() }
            if !loading && folders.isEmpty { FeatureEmpty(title: "No folders", symbol: "folder", description: "Folders from external libraries appear here.") }
            ForEach(folders.filter { query.isEmpty || $0.localizedStandardContains(query) }, id: \.self) { path in
                NavigationLink { FolderAssetsView(api: api, pipeline: pipeline, path: path, onOpenAsset: onOpenAsset) } label: {
                    Label { VStack(alignment: .leading) { Text((path as NSString).lastPathComponent); Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(2) } } icon: { Image(systemName: "folder") }
                }
            }
        }.navigationTitle("Folders").searchable(text: $query, prompt: "Find a folder")
        .task { do { folders = try await api.folders().sorted() } catch { failure = .init(error) }; loading = false }
        .alert("Couldn’t load folders", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
}
private struct FolderAssetsView: View {
    let api: APIClient; let pipeline: MediaPipeline; let path: String; let onOpenAsset: (Asset) -> Void
    @State private var assets: [Asset] = []
    @State private var loading = true
    @State private var failure: FeatureFailure?
    @State private var generation = 0
    var body: some View {
        ScrollView {
            if loading { ProgressView().padding(40) }
            SelectableFeatureAssetGrid(api: api, pipeline: pipeline, assets: assets, onOpenAsset: onOpenAsset)
            if !loading && assets.isEmpty { FeatureEmpty(title: "This folder is empty", symbol: "folder", description: "No photos are available in this folder.") }
        }.navigationTitle((path as NSString).lastPathComponent)
        .task { await load() }
        .refreshable { await load() }
        // A photo deleted, archived or locked leaves the folder in place; others show their change.
        .onMutationApplied { assets = $0.applied(to: assets, keeping: CollectionMembership.folder) }
        .alert("Couldn’t load folder", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    /// Cancellation (a newer reload token or leaving the view) never replaces the current assets.
    private func load() async {
        generation += 1
        let current = generation
        loading = true; failure = nil
        defer { if current == generation { loading = false } }
        do {
            let loaded = try await api.folderAssets(path: path)
            try Task.checkCancellation()
            guard current == generation else { return }
            assets = loaded
        } catch is CancellationError { } catch { if current == generation { failure = .init(error) } }
    }
}

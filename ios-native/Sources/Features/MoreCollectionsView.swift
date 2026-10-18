import SwiftUI

struct MoreCollectionsView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onOpenAsset: (Asset) -> Void
    let onFilter: (TimelineFilter, String) -> Void
    var body: some View {
        List {
            Section("On your device") {
                NavigationLink { LocalLibraryView() } label: { Label("On this phone", systemImage: "iphone") }
                NavigationLink { FreeUpSpaceView() } label: { Label("Free up space", systemImage: "internaldrive") }
            }
            Section {
                Button {
                    var filter = TimelineFilter(); filter.userID = api.userID; filter.isTrashed = false; filter.orderBy = "takenAt"
                    onFilter(filter, "Recently taken")
                } label: { Label("Recently taken", systemImage: "camera") }
                Button {
                    var filter = TimelineFilter(); filter.userID = api.userID; filter.visibility = nil; filter.isTrashed = false; filter.orderBy = "createdAt"
                    onFilter(filter, "Recently added")
                } label: { Label("Recently added", systemImage: "clock.badge.checkmark") }
                Button { var filter = TimelineFilter(); filter.isFavorite = true; onFilter(filter, "Favorites") } label: { Label("Favorites", systemImage: "heart") }
                NavigationLink { MediaCollectionView(api: api, pipeline: pipeline, category: .videos, onOpenAsset: onOpenAsset) } label: { Label("Videos", systemImage: "video") }
                NavigationLink { MediaCollectionView(api: api, pipeline: pipeline, category: .motion, onOpenAsset: onOpenAsset) } label: { Label("Motion", systemImage: "livephoto") }
                NavigationLink { MediaCollectionView(api: api, pipeline: pipeline, category: .developed, onOpenAsset: onOpenAsset) } label: { Label("Lightroom", systemImage: "slider.horizontal.3") }
                NavigationLink { MemoriesView(api: api, pipeline: pipeline, onOpenAsset: onOpenAsset) } label: { Label("On this day", systemImage: "clock.arrow.circlepath") }
            }
            Section("Shared") {
                NavigationLink { PartnersView(api: api, onFilter: onFilter) } label: { Label("Partners", systemImage: "person.2") }
                NavigationLink { SharedLinksView(api: api) } label: { Label("Shared links", systemImage: "link") }
            }
            Section("Library") {
                NavigationLink { FoldersView(api: api, pipeline: pipeline, onOpenAsset: onOpenAsset) } label: { Label("Folders", systemImage: "folder") }
                NavigationLink { DuplicatesView(api: api, pipeline: pipeline, onOpenAsset: onOpenAsset) } label: { Label("Duplicates", systemImage: "square.on.square") }
                Button { var filter = TimelineFilter(); filter.visibility = .archive; onFilter(filter, "Archive") } label: { Label("Archive", systemImage: "archivebox") }
                NavigationLink { LockedFolderView(api: api, pipeline: pipeline, onOpenAsset: onOpenAsset) } label: { Label("Locked folder", systemImage: "lock") }
                NavigationLink { TrashView(api: api, pipeline: pipeline, onOpenAsset: onOpenAsset) } label: { Label("Trash", systemImage: "trash") }
            }
        }.navigationTitle("More")
    }
}

private enum MediaCategory: String { case videos = "Videos", motion = "Motion", developed = "Lightroom" }
private struct MediaCollectionView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let category: MediaCategory
    let onOpenAsset: (Asset) -> Void
    @State private var assets: [Asset] = []
    @State private var cursor: String?
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var examined = 0
    @State private var failure: FeatureFailure?
    @State private var generation = 0
    @State private var failedFresh = true
    @State private var reloadToken = 0
    @State private var loadedToken = -1
    var body: some View {
        ScrollView {
            if category == .developed { Text("Photos developed from Lightroom XMP sidecars.").font(.subheadline).foregroundStyle(.secondary).padding() }
            SelectableFeatureAssetGrid(api: api, pipeline: pipeline, assets: assets, onOpenAsset: onOpenAsset, onChanged: { reloadToken += 1 })
            if assets.isEmpty && !loading && !hasMore { FeatureEmpty(title: "No \(category.rawValue.lowercased()) yet", symbol: "photo", description: "Matching photos and videos will appear here.") }
            if hasMore {
                Button { Task { await load() } } label: {
                    if loading { ProgressView() } else { Text(category == .developed ? "Find more developed photos" : "Load more") }
                }.disabled(loading).padding(24)
            }
            if category == .developed && examined > 0 && hasMore { Text("Checked \(examined.formatted()) library items").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle(category.rawValue)
        .task(id: reloadToken) { if assets.isEmpty || loadedToken != reloadToken { loadedToken = reloadToken; await load(fresh: true) } }
        .refreshable { await load(fresh: true) }
        .alert("Couldn’t load collection", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("Retry") { Task { await load(fresh: failedFresh) } }; Button("Cancel", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    /// A fresh load restarts paging and supersedes any in-flight load; stale results are discarded.
    private func load(fresh: Bool = false) async {
        guard fresh || !loading else { return }
        struct Filter: Encodable, Sendable { var type: StringFilter?; var isMotion: BoolFilter?; var visibility = StringFilter(eq: "timeline") }
        struct Query: Encodable, Sendable { let filter: Filter; let cursor: String?; let page: Int?; let size = 200; let withExif = true }
        if fresh { generation += 1 }
        let current = generation
        let startCursor = fresh ? nil : cursor, startPage = fresh ? 1 : page
        loading = true; failure = nil
        defer { if current == generation { loading = false } }
        do {
            var filter = Filter()
            if category == .videos { filter.type = .init(eq: "VIDEO") }
            if category == .motion { filter.isMotion = .init(eq: true) }
            let result: SearchResponse = try await api.request(.post, path: "search/metadata", body: Query(filter: filter, cursor: startCursor, page: startCursor == nil ? startPage : nil))
            try Task.checkCancellation()
            guard current == generation else { return }
            let base = fresh ? [] : assets
            let known = Set(base.map(\.id))
            examined = (fresh ? 0 : examined) + result.assets.items.count
            assets = base + result.assets.items.filter { !known.contains($0.id) && (category != .developed || $0.isDeveloped) }
            cursor = result.assets.nextCursor
            page = result.assets.nextPage.flatMap(Int.init) ?? startPage + 1
            hasMore = result.assets.hasMore
        } catch is CancellationError { } catch { if current == generation { failedFresh = fresh; failure = .init(error) } }
    }
}

struct MemoriesView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onOpenAsset: (Asset) -> Void
    var initialID: String? = nil
    @State private var openedInitial = false
    @State private var memories: [Memory] = []
    @State private var savedOnly = false
    @State private var playingMemory: Memory?
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
                            Button("Play memory", systemImage: "play.fill") { playingMemory = memory }.labelStyle(.iconOnly).disabled(memory.assets.isEmpty)
                            Button { Task { await toggleSaved(memory) } } label: { Image(systemName: memory.isSaved ? "bookmark.fill" : "bookmark") }
                                .accessibilityLabel(memory.isSaved ? "Unsave memory" : "Save memory").requiresWriteAccess(api)
                        }.padding(.horizontal, 20)
                        FeatureAssetGrid(pipeline: pipeline, assets: memory.assets, onOpenAsset: onOpenAsset)
                    }
                }
            }.padding(.vertical, 16)
        }.navigationTitle(savedOnly ? "Saved memories" : "On this day")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Toggle("Saved memories", isOn: $savedOnly).toggleStyle(.button) } }
        .task(id: savedOnly) { await load() }.refreshable { await load() }
        .fullScreenCover(item: $playingMemory) { memory in
            MemoryPlaybackView(api: api, pipeline: pipeline, memories: memories, initialID: memory.id, onOpenAsset: onOpenAsset)
        }
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
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        let query = savedOnly ? [URLQueryItem(name: "isSaved", value: "true")] : [.init(name: "for", value: formatter.string(from: Date()))]
        do {
            if let initialID, !openedInitial {
                let memory: Memory = try await api.request(.get, path: "memories/\(initialID)")
                try Task.checkCancellation()
                memories = [memory]; playingMemory = memory; openedInitial = true
            } else { memories = try await api.request(.get, path: "memories", query: query) }
        } catch is CancellationError { } catch { failure = .init(error) }
    }
    private func toggleSaved(_ memory: Memory) async {
        do { try await api.requestVoid(.put, path: "memories/\(memory.id)", body: ["isSaved": !memory.isSaved]); await load() } catch { failure = .init(error) }
    }
}

struct PartnersView: View {
    let api: APIClient
    let onFilter: (TimelineFilter, String) -> Void
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
                        Button(partner.name) { var filter = TimelineFilter(); filter.userID = partner.id; filter.visibility = nil; onFilter(filter, partner.name) }
                        Toggle("Show in your timeline", isOn: Binding(get: { partner.inTimeline == true }, set: { value in Task { await setTimeline(partner, value: value) } })).font(.subheadline).requiresWriteAccess(api)
                    }.padding(.vertical, 4)
                }
                if incoming.isEmpty && !loading { Text("No partner libraries yet").foregroundStyle(.secondary) }
            }
            Section("You’re sharing with") {
                ForEach(outgoing) { partner in Text(partner.name).swipeActions { Button("Stop sharing", role: .destructive) { pendingRemoval = partner }.requiresWriteAccess(api) } }
                if outgoing.isEmpty && !loading { Text("Your library is not shared with any partners.").foregroundStyle(.secondary) }
            }
            Section("Share your library") {
                ForEach(candidates.filter { user in user.id != api.userID && !outgoing.contains { $0.id == user.id } }) { user in
                    Button(user.name) { pendingShare = user }.requiresWriteAccess(api)
                }
            }
        }.navigationTitle("Partners").task { await load() }.refreshable { await load() }
        .confirmationDialog("Share your library with \(pendingShare?.name ?? "this person")?", isPresented: Binding(get: { pendingShare != nil }, set: { if !$0 { pendingShare = nil } }), titleVisibility: .visible) {
            Button("Share library") { if let user = pendingShare { Task { await share(user) } } }.requiresWriteAccess(api)
        } message: { Text("They will be able to browse your shared library. Locked photos stay private.") }
        .confirmationDialog("Stop sharing your library?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) { if let partner = pendingRemoval { Task { await remove(partner) } } }.requiresWriteAccess(api)
        }
        .alert("Couldn’t update partners", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func load() async {
        defer { loading = false }
        do {
            async let received = api.partners(direction: "shared-with")
            async let sent = api.partners(direction: "shared-by")
            async let users: [User] = api.request(.get, path: "users")
            (incoming, outgoing, candidates) = try await (received, sent, users)
        } catch { failure = .init(error) }
    }
    private func setTimeline(_ partner: Partner, value: Bool) async {
        do { try await api.requestVoid(.put, path: "partners/\(partner.id)", body: ["inTimeline": value]); await load() } catch { failure = .init(error) }
    }
    private func share(_ user: User) async {
        do { try await api.requestVoid(.post, path: "partners", body: ["sharedWithId": user.id]); pendingShare = nil; await load() } catch { failure = .init(error) }
    }
    private func remove(_ partner: Partner) async {
        do { try await api.requestVoid(.delete, path: "partners/\(partner.id)"); pendingRemoval = nil; await load() } catch { failure = .init(error) }
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
    @State private var reloadToken = 0
    @State private var generation = 0
    var body: some View {
        ScrollView {
            if loading { ProgressView().padding(40) }
            SelectableFeatureAssetGrid(api: api, pipeline: pipeline, assets: assets, onOpenAsset: onOpenAsset, onChanged: { reloadToken += 1 })
            if !loading && assets.isEmpty { FeatureEmpty(title: "This folder is empty", symbol: "folder", description: "No photos are available in this folder.") }
        }.navigationTitle((path as NSString).lastPathComponent)
        .task(id: reloadToken) { await load() }
        .refreshable { await load() }
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

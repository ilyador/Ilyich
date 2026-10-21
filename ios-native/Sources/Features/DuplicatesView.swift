import SwiftUI

struct DuplicatesView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onOpenAsset: (Asset) -> Void
    @State private var groups: [DuplicateGroup] = []
    @State private var keep: [String: Set<String>] = [:]
    @State private var loading = true
    @State private var busy = false
    @State private var confirming: DuplicateGroup?
    @State private var trashEnabled = false
    @State private var failure: FeatureFailure?
    var body: some View {
        ScrollView {
            if loading { ProgressView().padding(50) }
            else if groups.isEmpty { FeatureEmpty(title: "No duplicates to review", symbol: "square.on.square", description: "Similar photos found by your server will appear here.") }
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 14) {
                        Text("\(group.assets.count) similar items").font(.headline)
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(group.assets) { asset in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Button { onOpenAsset(asset) } label: { FeatureAssetImage(pipeline: pipeline, asset: asset).frame(width: 150, height: 150).clipShape(.rect(cornerRadius: 10)) }.buttonStyle(.plain)
                                        Button { toggle(asset, in: group) } label: {
                                            Label("Keep", systemImage: selected(group).contains(asset.id) ? "checkmark.circle.fill" : "circle")
                                        }.buttonStyle(.bordered).accessibilityLabel("Keep \(asset.displayName)")
                                        Text(asset.originalFileName).font(.caption).lineLimit(1).frame(width: 150, alignment: .leading)
                                    }
                                }
                            }
                        }
                        HStack {
                            Button("Not duplicates") { Task { await dismissGroup(group) } }.requiresWriteAccess()
                            Spacer()
                            Button("Move others to trash") { confirming = group }.buttonStyle(.borderedProminent).requiresWriteAccess()
                                .disabled(!trashEnabled || selected(group).isEmpty || selected(group).count == group.assets.count)
                        }.font(.subheadline)
                    }.padding(.horizontal, 20)
                }
            }.padding(.vertical, 20)
        }.navigationTitle("Duplicates").disabled(busy)
        .task { await load() }.refreshable { await load() }
        .confirmationDialog("Move \(confirming.map { $0.assets.count - selected($0).count } ?? 0) items to trash?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            Button("Move to trash", role: .destructive) { if let group = confirming { Task { await resolve(group) } } }.requiresWriteAccess()
        } message: { Text("The items marked Keep will remain in your library.") }
        .alert("Couldn’t update duplicates", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private func selected(_ group: DuplicateGroup) -> Set<String> { keep[group.id] ?? Set(group.suggestedKeepAssetIds.isEmpty ? Array(group.assets.prefix(1).map(\.id)) : group.suggestedKeepAssetIds) }
    private func toggle(_ asset: Asset, in group: DuplicateGroup) { var ids = selected(group); if !ids.insert(asset.id).inserted { ids.remove(asset.id) }; keep[group.id] = ids }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            trashEnabled = try await api.serverFeatures().trash
            groups = try await api.duplicates()
        } catch is CancellationError { } catch { failure = .init(error) }
    }
    private func dismissGroup(_ group: DuplicateGroup) async {
        busy = true; defer { busy = false }
        do { try await api.requestVoid(.delete, path: "duplicates/\(group.id)"); groups.removeAll { $0.id == group.id } } catch { failure = .init(error) }
    }
    private func resolve(_ group: DuplicateGroup) async {
        struct Group: Encodable, Sendable { let duplicateId: String; let keepAssetIds: [String]; let trashAssetIds: [String] }
        struct Body: Encodable, Sendable { let groups: [Group] }
        busy = true; defer { busy = false }
        let kept = selected(group), trashed = group.assets.map(\.id).filter { !kept.contains($0) }
        do {
            guard try await api.serverFeatures().trash else { throw APIError.invalidResponse("Trash is turned off on this server. No photos were removed.") }
            let result: [BulkResult] = try await api.request(.post, path: "duplicates/resolve", body: Body(groups: [.init(duplicateId: group.id, keepAssetIds: Array(kept), trashAssetIds: trashed)]))
            guard result.allSatisfy(\.success) else { throw APIError.invalidResponse("Some items could not be moved. Refresh this collection and try again.") }
            groups.removeAll { $0.id == group.id }; confirming = nil
            await invalidateBrowsingCache(api: api, pipeline: pipeline)
        } catch { failure = .init(error) }
    }
}

struct TrashView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onOpenAsset: (Asset) -> Void
    @State private var assets: [Asset] = []
    @State private var buckets: [TimeBucket] = []
    @State private var nextBucket = 0
    @State private var loading = false
    @State private var initialized = false
    @State private var selection = Set<String>()
    @State private var failure: FeatureFailure?
    @State private var confirmPermanent = false
    @State private var confirmAll = false
    @State private var emptyAll = false
    @State private var trashEnabled: Bool?
    @State private var resultMessage: String?
    var body: some View {
        ScrollView {
            if trashEnabled == false { FeatureEmpty(title: "Trash is turned off", symbol: "trash.slash", description: "Your server does not keep deleted photos in trash.") }
            if let resultMessage { Text(resultMessage).font(.subheadline).foregroundStyle(.secondary).padding() }
            if trashEnabled == true && !loading && initialized && assets.isEmpty { FeatureEmpty(title: "Trash is empty", symbol: "trash", description: "Deleted photos stay here until your server’s retention period ends.") }
            LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(assets) { asset in
                    Button { if !selection.insert(asset.id).inserted { selection.remove(asset.id) } } label: {
                        FeatureAssetImage(pipeline: pipeline, asset: asset).aspectRatio(1, contentMode: .fit)
                            .overlay(alignment: .topTrailing) { Image(systemName: selection.contains(asset.id) ? "checkmark.circle.fill" : "circle").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6)).padding(7) }
                    }.buttonStyle(.plain).contextMenu { Button("Preview") { onOpenAsset(asset) } }.accessibilityLabel("Select \(asset.displayName)")
                }
            }
            if loading { ProgressView().padding(30) }
            if nextBucket < buckets.count { Button("Load more") { Task { await loadNext() } }.padding() }
        }.navigationTitle(selection.isEmpty ? "Trash" : "\(selection.count) selected")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button(selection.count == assets.count && !assets.isEmpty ? "Deselect" : "Select loaded") { selection = selection.count == assets.count ? [] : Set(assets.map(\.id)) }.disabled(assets.isEmpty) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Restore all items") { emptyAll = false; confirmAll = true }
                    Button("Empty trash", role: .destructive) { emptyAll = true; confirmAll = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Trash actions")
                    .disabled(loading || trashEnabled != true || buckets.isEmpty).requiresWriteAccess()
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Restore", systemImage: "arrow.uturn.backward") { Task { await restore() } }.disabled(selection.isEmpty || loading).requiresWriteAccess()
                Spacer()
                Button("Delete forever", systemImage: "trash", role: .destructive) { confirmPermanent = true }.disabled(selection.isEmpty || loading).requiresWriteAccess()
            }
        }
        .task { await reload() }.refreshable { await reload() }
        .confirmationDialog("Permanently delete \(selection.count) items?", isPresented: $confirmPermanent, titleVisibility: .visible) {
            Button("Delete forever", role: .destructive) { Task { await remove() } }.requiresWriteAccess()
        } message: { Text("These photos and videos will be permanently removed from your server. This cannot be undone.") }
        .confirmationDialog(emptyAll ? "Permanently delete everything in trash?" : "Restore every item in trash?", isPresented: $confirmAll, titleVisibility: .visible) {
            if emptyAll { Button("Empty trash", role: .destructive) { Task { await changeAll(permanently: true) } }.requiresWriteAccess() }
            else { Button("Restore all items") { Task { await changeAll(permanently: false) } }.requiresWriteAccess() }
        } message: { Text(emptyAll ? "This removes all of your trashed photos and videos from the server, including items you have not loaded here. This cannot be undone." : "All of your trashed photos and videos will return to their previous visibility, including items you have not loaded here.") }
        .alert("Couldn’t update trash", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private var filter: TimelineFilter { var filter = TimelineFilter(); filter.visibility = nil; filter.isTrashed = true; filter.withStacked = false; return filter }
    private func reload() async {
        guard !loading else { return }
        loading = true
        do {
            trashEnabled = try await api.serverFeatures().trash
            guard trashEnabled == true else { assets = []; buckets = []; selection = []; loading = false; initialized = true; return }
            buckets = try await api.timeBuckets(filter: filter); assets = []; nextBucket = 0; selection = []; initialized = true
        } catch is CancellationError { } catch { failure = .init(error) }
        loading = false
        if !buckets.isEmpty { await loadNext() }
    }
    private func loadNext() async {
        guard !loading, nextBucket < buckets.count else { return }
        loading = true; defer { loading = false }
        do { assets += try await api.timeBucket(buckets[nextBucket].timeBucket, filter: filter); nextBucket += 1 } catch { failure = .init(error) }
    }
    private func restore() async {
        loading = true; defer { loading = false }
        do {
            let result = try await api.restoreAssets(ids: Array(selection))
            await invalidateBrowsingCache(api: api, pipeline: pipeline)
            resultMessage = "Restored \(result.count.formatted()) items."
            loading = false; await reload()
        } catch { failure = .init(error) }
    }
    private func remove() async {
        loading = true; defer { loading = false }
        do {
            try await api.trashAssets(ids: Array(selection), permanently: true)
            await invalidateBrowsingCache(api: api, pipeline: pipeline, deleted: selection)
            loading = false; await reload()
        } catch { failure = .init(error) }
    }
    private func changeAll(permanently: Bool) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            guard try await api.serverFeatures().trash else { throw APIError.invalidResponse("Trash is turned off on this server.") }
            let result: TrashResult = try await api.request(.post, path: permanently ? "trash/empty" : "trash/restore")
            resultMessage = permanently ? "Permanently removed \(result.count.formatted()) items." : "Restored \(result.count.formatted()) items."
            // The sync forgets the rest of an emptied Trash as their deletions arrive.
            await invalidateBrowsingCache(api: api, pipeline: pipeline, deleted: permanently ? Set(assets.map(\.id)) : [])
            loading = false; await reload()
        } catch { failure = .init(error) }
    }
}

/// The timeline reloads after a change made here. Trashed and restored photos keep their media;
/// photos deleted for good lose theirs.
@MainActor private func invalidateBrowsingCache(api: APIClient, pipeline: MediaPipeline, deleted: Set<String> = []) async {
    await TimelineCache.shared.removeAll(scope: api.cacheScope)
    await pipeline.forget(assetIDs: deleted)
    LegacyNotificationBridge.cachesReset(scope: api.cacheScope)
}

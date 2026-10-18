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
                            Button("Not duplicates") { Task { await dismissGroup(group) } }
                            Spacer()
                            Button("Move others to trash") { confirming = group }.buttonStyle(.borderedProminent)
                                .disabled(selected(group).isEmpty || selected(group).count == group.assets.count)
                        }.font(.subheadline)
                    }.padding(.horizontal, 20)
                }
            }.padding(.vertical, 20)
        }.navigationTitle("Duplicates").disabled(busy)
        .task { await load() }.refreshable { await load() }
        .confirmationDialog("Move \(confirming.map { $0.assets.count - selected($0).count } ?? 0) items to trash?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            Button("Move to trash", role: .destructive) { if let group = confirming { Task { await resolve(group) } } }
        } message: { Text("The items marked Keep will remain in your library.") }
        .alert("Couldn’t update duplicates", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private func selected(_ group: DuplicateGroup) -> Set<String> { keep[group.id] ?? Set(group.suggestedKeepAssetIds.isEmpty ? Array(group.assets.prefix(1).map(\.id)) : group.suggestedKeepAssetIds) }
    private func toggle(_ asset: Asset, in group: DuplicateGroup) { var ids = selected(group); if !ids.insert(asset.id).inserted { ids.remove(asset.id) }; keep[group.id] = ids }
    private func load() async { defer { loading = false }; do { groups = try await api.duplicates() } catch { failure = .init(error) } }
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
            let result: [BulkResult] = try await api.request(.post, path: "duplicates/resolve", body: Body(groups: [.init(duplicateId: group.id, keepAssetIds: Array(kept), trashAssetIds: trashed)]))
            guard result.allSatisfy(\.success) else { throw APIError.invalidResponse("Some items could not be moved. Refresh this collection and try again.") }
            groups.removeAll { $0.id == group.id }; confirming = nil
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
    var body: some View {
        ScrollView {
            if !loading && initialized && assets.isEmpty { FeatureEmpty(title: "Trash is empty", symbol: "trash", description: "Deleted photos stay here until your server’s retention period ends.") }
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
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Restore", systemImage: "arrow.uturn.backward") { Task { await restore() } }.disabled(selection.isEmpty || loading)
                Spacer()
                Button("Delete forever", systemImage: "trash", role: .destructive) { confirmPermanent = true }.disabled(selection.isEmpty || loading)
            }
        }
        .task { await reload() }.refreshable { await reload() }
        .confirmationDialog("Permanently delete \(selection.count) items?", isPresented: $confirmPermanent, titleVisibility: .visible) {
            Button("Delete forever", role: .destructive) { Task { await remove() } }
        } message: { Text("These photos and videos will be permanently removed from your server. This cannot be undone.") }
        .alert("Couldn’t update trash", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private var filter: TimelineFilter { var filter = TimelineFilter(); filter.visibility = nil; filter.isTrashed = true; filter.withStacked = false; return filter }
    private func reload() async {
        guard !loading else { return }
        loading = true
        do { buckets = try await api.timeBuckets(filter: filter); assets = []; nextBucket = 0; selection = []; initialized = true } catch { failure = .init(error) }
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
        do { _ = try await api.restoreAssets(ids: Array(selection)); assets.removeAll { selection.contains($0.id) }; selection = [] } catch { failure = .init(error) }
    }
    private func remove() async {
        loading = true; defer { loading = false }
        do { try await api.trashAssets(ids: Array(selection), permanently: true); assets.removeAll { selection.contains($0.id) }; selection = [] } catch { failure = .init(error) }
    }
}

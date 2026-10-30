import SwiftUI

struct DuplicatesView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onOpenAsset: (Asset) -> Void
    @Environment(\.mutations) private var mutations
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
        // A group resolved or dismissed goes, and a photo deleted elsewhere leaves its group.
        .onMutationApplied { groups = DuplicateGroups.applying($0, to: groups) }
        .confirmationDialog(moveToTrashTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            Button("Move to trash", role: .destructive) { if let group = confirming { Task { await resolve(group) } } }.requiresWriteAccess()
        } message: { Text("The items marked Keep will remain in your library.") }
        .alert("Couldn’t update duplicates", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private var moveToTrashTitle: String {
        let count = confirming.map { $0.assets.count - selected($0).count } ?? 0
        return "Move \(count) item\(count == 1 ? "" : "s") to trash?"
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
        await change(.dismissDuplicate(group: group.id), on: group)
    }
    /// The others go to Trash, never for good, so their thumbnails stay on the phone and a restore
    /// shows them at once; the account's mutations refuse a server without a Trash.
    private func resolve(_ group: DuplicateGroup) async {
        let kept = selected(group), trashed = group.assets.map(\.id).filter { !kept.contains($0) }
        let keep = group.assets.map(\.id).filter(kept.contains)
        if await change(.resolveDuplicate(group: group.id, keep: keep, trash: trashed), on: group) { confirming = nil }
    }
    /// Has the account's mutations make the change. The group leaves the list from the result,
    /// as do photos the feed and other screens show.
    @discardableResult private func change(_ request: MutationRequest, on group: DuplicateGroup) async -> Bool {
        guard let mutations else { failure = .init(APIError.signedOut); return false }
        busy = true; defer { busy = false }
        do { _ = try await mutations.start(request, on: group.assets).result; return true }
        catch { failure = .init(error); return false }
    }
}

struct TrashView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onOpenAsset: (Asset) -> Void
    @Environment(\.mutations) private var mutations
    @Environment(\.libraryBus) private var bus
    /// What the Trash shows and does, following the account's changes (G1).
    @State private var trash: TrashModel
    @State private var confirmPermanent = false
    @State private var confirmAll = false
    @State private var emptyAll = false

    init(api: APIClient, pipeline: MediaPipeline, onOpenAsset: @escaping (Asset) -> Void) {
        self.api = api; self.pipeline = pipeline; self.onOpenAsset = onOpenAsset
        _trash = State(initialValue: TrashModel(api: api))
    }

    var body: some View {
        ScrollView {
            if trash.trashEnabled == false { FeatureEmpty(title: "Trash is turned off", symbol: "trash.slash", description: "Your server does not keep deleted photos in trash.") }
            if let resultMessage = trash.resultMessage { Text(resultMessage).font(.subheadline).foregroundStyle(.secondary).padding() }
            if trash.trashEnabled == true && !trash.loading && trash.initialized && trash.assets.isEmpty { FeatureEmpty(title: "Trash is empty", symbol: "trash", description: "Deleted photos stay here until your server’s retention period ends.") }
            LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(trash.assets) { asset in
                    Button { if !trash.selection.insert(asset.id).inserted { trash.selection.remove(asset.id) } } label: {
                        FeatureAssetImage(pipeline: pipeline, asset: asset).aspectRatio(1, contentMode: .fit)
                            .overlay(alignment: .topTrailing) { Image(systemName: trash.selection.contains(asset.id) ? "checkmark.circle.fill" : "circle").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6)).padding(7) }
                    }.buttonStyle(.plain).contextMenu { Button("Preview") { onOpenAsset(asset) } }.accessibilityLabel("Select \(asset.displayName)")
                }
            }
            if trash.loading { ProgressView().padding(30) }
            if trash.nextBucket < trash.buckets.count { Button("Load more") { Task { await trash.loadNext() } }.padding() }
        }.navigationTitle(trash.selection.isEmpty ? "Trash" : "\(trash.selection.count) selected")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button(trash.selection.count == trash.assets.count && !trash.assets.isEmpty ? "Deselect" : "Select loaded") { trash.selection = trash.selection.count == trash.assets.count ? [] : Set(trash.assets.map(\.id)) }.disabled(trash.assets.isEmpty) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Restore all items") { emptyAll = false; confirmAll = true }
                    Button("Empty trash", role: .destructive) { emptyAll = true; confirmAll = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Trash actions")
                    .disabled(trash.loading || trash.trashEnabled != true || trash.buckets.isEmpty).requiresWriteAccess()
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Restore", systemImage: "arrow.uturn.backward") { Task { await trash.restoreSelected() } }.disabled(trash.selection.isEmpty || trash.loading).requiresWriteAccess()
                Spacer()
                Button("Delete forever", systemImage: "trash", role: .destructive) { confirmPermanent = true }.disabled(trash.selection.isEmpty || trash.loading).requiresWriteAccess()
            }
        }
        // Photos restored, deleted or put in Trash, here, from their viewer or anywhere else the
        // account changes them, leave or join in place.
        .task { trash.follow(mutations: mutations, bus: bus); await trash.reload() }.refreshable { await trash.reload() }
        .confirmationDialog("Permanently delete \(trash.selection.count) item\(trash.selection.count == 1 ? "" : "s")?", isPresented: $confirmPermanent, titleVisibility: .visible) {
            Button("Delete forever", role: .destructive) { Task { await trash.deleteSelected() } }.requiresWriteAccess()
        } message: { Text("These photos and videos will be permanently removed from your server. This cannot be undone.") }
        .confirmationDialog(emptyAll ? "Permanently delete everything in trash?" : "Restore every item in trash?", isPresented: $confirmAll, titleVisibility: .visible) {
            if emptyAll { Button("Empty trash", role: .destructive) { Task { await trash.changeAll(permanently: true) } }.requiresWriteAccess() }
            else { Button("Restore all items") { Task { await trash.changeAll(permanently: false) } }.requiresWriteAccess() }
        } message: { Text(emptyAll ? "This removes all of your trashed photos and videos from the server, including items you have not loaded here. This cannot be undone." : "All of your trashed photos and videos will return to their previous visibility, including items you have not loaded here.") }
        .alert("Couldn’t update trash", isPresented: Binding(get: { trash.failure != nil }, set: { if !$0 { trash.failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(trash.failure?.message ?? "") }
    }
}

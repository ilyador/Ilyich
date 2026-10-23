import SwiftUI

/// Reusable at album and photo level; photo activity must keep the containing album ID. Reads and
/// changes go through the account's collections (the critic's correction to N4).
struct AlbumActivityView: View {
    let api: APIClient
    let albumID: String
    var assetID: String? = nil
    @Environment(\.collectionsService) private var collections
    @State private var activities: [AlbumActivity] = []
    @State private var comment = ""
    @State private var enabled = true
    @State private var owner = false
    @State private var loading = true
    @State private var saving = false
    @State private var failure: FeatureFailure?
    @State private var pendingDelete: AlbumActivity?
    private var ownLike: AlbumActivity? { activities.first { $0.type == "like" && $0.user.id == api.userID } }
    var body: some View {
        List {
            if owner { Section { Toggle("Allow comments and likes", isOn: Binding(get: { enabled }, set: { value in Task { await setEnabled(value) } })).disabled(saving).requiresWriteAccess() } }
            if enabled {
                Section {
                    Button { Task { await toggleLike() } } label: {
                        Label("\(activities.filter { $0.type == "like" }.count) likes", systemImage: ownLike == nil ? "heart" : "heart.fill")
                    }.disabled(saving).requiresWriteAccess()
                }
                Section("Comments") {
                    if loading { ProgressView() }
                    ForEach(activities.filter { $0.type == "comment" }) { activity in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack { Text(activity.user.name).font(.subheadline.bold()); Spacer(); Text(activity.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary) }
                            Text(activity.comment ?? "")
                        }.padding(.vertical, 5)
                        .swipeActions { if owner || activity.user.id == api.userID { Button("Delete", role: .destructive) { pendingDelete = activity }.requiresWriteAccess() } }
                    }
                    if !loading && !activities.contains(where: { $0.type == "comment" }) { Text("Be the first to leave a comment.").foregroundStyle(.secondary) }
                }
            } else { Text("Comments and likes are turned off for this album.").foregroundStyle(.secondary) }
        }.navigationTitle("Comments and likes")
        .safeAreaInset(edge: .bottom) {
            if enabled {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Add a comment", text: $comment, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                    Button("Send", systemImage: "arrow.up") { Task { await postComment() } }.labelStyle(.iconOnly).buttonStyle(.glassProminent)
                        .disabled(saving || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).requiresWriteAccess()
                }.padding().background(.bar)
            }
        }
        .task { await load() }.refreshable { await load() }
        .confirmationDialog("Delete this comment?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete comment", role: .destructive) { if let activity = pendingDelete { Task { await remove(activity) } } }.requiresWriteAccess()
        }
        .alert("Couldn’t update activity", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private func load() async {
        defer { loading = false }
        guard let collections else { failure = .init(APIError.signedOut); return }
        do {
            let state = try await collections.activity(album: albumID, asset: assetID)
            enabled = state.enabled; owner = state.owner
            if state.enabled { activities = state.activities }
        } catch { failure = .init(error) }
    }
    private func postComment() async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        saving = true; defer { saving = false }
        do {
            let activity = try await collections.comment(comment.trimmingCharacters(in: .whitespacesAndNewlines), album: albumID, asset: assetID)
            activities.append(activity); comment = ""
        } catch { failure = .init(error) }
    }
    private func toggleLike() async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        saving = true; defer { saving = false }
        do {
            if let like = ownLike { try await collections.deleteActivity(like.id); activities.removeAll { $0.id == like.id } }
            else { activities.append(try await collections.like(album: albumID, asset: assetID)) }
        } catch { failure = .init(error) }
    }
    private func remove(_ activity: AlbumActivity) async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        do { try await collections.deleteActivity(activity.id); activities.removeAll { $0.id == activity.id }; pendingDelete = nil } catch { failure = .init(error) }
    }
    private func setEnabled(_ value: Bool) async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        saving = true; defer { saving = false }
        do { try await collections.setActivityEnabled(value, album: albumID); enabled = value; if value { await load() } } catch { failure = .init(error) }
    }
}

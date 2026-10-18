import SwiftUI

/// Reusable at album and photo level; photo activity must keep the containing album ID.
struct AlbumActivityView: View {
    let api: APIClient
    let albumID: String
    var assetID: String? = nil
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
            if owner { Section { Toggle("Allow comments and likes", isOn: Binding(get: { enabled }, set: { value in Task { await setEnabled(value) } })).disabled(saving) } }
            if enabled {
                Section {
                    Button { Task { await toggleLike() } } label: {
                        Label("\(activities.filter { $0.type == "like" }.count) likes", systemImage: ownLike == nil ? "heart" : "heart.fill")
                    }.disabled(saving)
                }
                Section("Comments") {
                    if loading { ProgressView() }
                    ForEach(activities.filter { $0.type == "comment" }) { activity in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack { Text(activity.user.name).font(.subheadline.bold()); Spacer(); Text(activity.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary) }
                            Text(activity.comment ?? "")
                        }.padding(.vertical, 5)
                        .swipeActions { if owner || activity.user.id == api.userID { Button("Delete", role: .destructive) { pendingDelete = activity } } }
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
                        .disabled(saving || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding().background(.bar)
            }
        }
        .task { await load() }.refreshable { await load() }
        .confirmationDialog("Delete this comment?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete comment", role: .destructive) { if let activity = pendingDelete { Task { await remove(activity) } } }
        }
        .alert("Couldn’t update activity", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private func load() async {
        struct ActivityState: Decodable, Sendable { let isActivityEnabled: Bool; let albumUsers: [AlbumUser] }
        defer { loading = false }
        do {
            let state: ActivityState = try await api.request(.get, path: "albums/\(albumID)")
            enabled = state.isActivityEnabled; owner = state.albumUsers.contains { $0.user.id == api.userID && $0.role == "owner" }
            if enabled {
                var query = [URLQueryItem(name: "albumId", value: albumID), .init(name: "level", value: assetID == nil ? "album" : "asset")]
                if let assetID { query.append(.init(name: "assetId", value: assetID)) }
                activities = try await api.request(.get, path: "activities", query: query)
            }
        } catch { failure = .init(error) }
    }
    private func postComment() async {
        saving = true; defer { saving = false }
        do {
            let activity: AlbumActivity = try await api.request(.post, path: "activities", body: ActivityCreation(albumId: albumID, assetId: assetID, type: "comment", comment: comment.trimmingCharacters(in: .whitespacesAndNewlines)))
            activities.append(activity); comment = ""
        } catch { failure = .init(error) }
    }
    private func toggleLike() async {
        saving = true; defer { saving = false }
        do {
            if let like = ownLike { try await api.requestVoid(.delete, path: "activities/\(like.id)"); activities.removeAll { $0.id == like.id } }
            else { let activity: AlbumActivity = try await api.request(.post, path: "activities", body: ActivityCreation(albumId: albumID, assetId: assetID, type: "like", comment: nil)); activities.append(activity) }
        } catch { failure = .init(error) }
    }
    private func remove(_ activity: AlbumActivity) async {
        do { try await api.requestVoid(.delete, path: "activities/\(activity.id)"); activities.removeAll { $0.id == activity.id }; pendingDelete = nil } catch { failure = .init(error) }
    }
    private func setEnabled(_ value: Bool) async {
        saving = true; defer { saving = false }
        do { try await api.requestVoid(.patch, path: "albums/\(albumID)", body: ["isActivityEnabled": value]); enabled = value; if value { await load() } } catch { failure = .init(error) }
    }
}
private struct AlbumActivity: Decodable, Identifiable, Sendable {
    let id: String
    let assetId: String?
    let comment: String?
    let createdAt: Date
    let type: String
    let user: User
}
private struct ActivityCreation: Encodable, Sendable { let albumId: String; let assetId: String?; let type: String; let comment: String? }

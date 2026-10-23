import SwiftUI

struct SharedLinksView: View {
    let api: APIClient
    @Environment(\.collectionsService) private var collections
    @State private var links: [SharedLink] = []
    @State private var failure: FeatureFailure?
    @State private var deleting: SharedLink?
    @State private var editing: SharedLink?
    @State private var loading = true
    var body: some View {
        List {
            if loading { ProgressView() }
            if !loading && links.isEmpty { FeatureEmpty(title: "No shared links", symbol: "link", description: "Share photos or an album to create a link.") }
            ForEach(links) { link in
                SharedLinkRow(api: api, link: link, onEdit: { editing = link }, onRemove: { deleting = link })
            }
        }.navigationTitle("Shared links")
        .task { await load() }.refreshable { await load() }
        .sheet(item: $editing) { link in NavigationStack { SharedLinkEditor(api: api, album: link.album, link: link, onSaved: { Task { await load() } }) } }
        .confirmationDialog("Remove this shared link?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Remove link", role: .destructive) { if let link = deleting { Task { await remove(link) } } }.requiresWriteAccess()
        } message: { Text("Anyone with the link will lose access. Your photos stay in your library.") }
        .alert("Couldn’t update shared links", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func load() async {
        defer { loading = false }
        guard let collections else { failure = .init(APIError.signedOut); return }
        do { links = try await collections.sharedLinks() } catch { failure = .init(error) }
    }
    private func remove(_ link: SharedLink) async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        do { try await collections.deleteLink(link.id); links.removeAll { $0.id == link.id }; deleting = nil } catch { failure = .init(error) }
    }
}

/// One shared link: what it shares and until when, with sharing, editing and removing it.
struct SharedLinkRow: View {
    let api: APIClient
    let link: SharedLink
    let onEdit: () -> Void
    let onRemove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(link.description?.isEmpty == false ? link.description! : link.album?.albumName ?? "Shared photos").font(.headline)
            if let expiry = link.expiresAt { Text(expiry < Date() ? "Expired" : "Expires \(expiry.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
            HStack {
                if let url = sharedURL(link: link, api: api) { ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") } }
                Spacer()
                Button("Edit", action: onEdit).requiresWriteAccess()
            }.buttonStyle(.borderless)
        }.padding(.vertical, 4)
        .swipeActions { Button("Remove", role: .destructive, action: onRemove).requiresWriteAccess() }
    }
}

struct SharedLinkEditor: View {
    let api: APIClient
    let album: Album?
    var assetIDs: [String] = []
    var link: SharedLink?
    var onSaved: () -> Void = { }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.collectionsService) private var collections
    @State private var description = ""
    @State private var password = ""
    @State private var slug = ""
    @State private var passwordChange = false
    @State private var expiryEnabled = false
    @State private var expiry = Date().addingTimeInterval(7 * 86400)
    @State private var download = true
    @State private var upload = false
    @State private var metadata = false
    @State private var saving = false
    @State private var result: SharedLink?
    @State private var failure: FeatureFailure?
    var body: some View {
        Form {
            if let result, let url = sharedURL(link: result, api: api) {
                Section { ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") } }
            }
            Section("Link details") {
                TextField("Description", text: $description)
                TextField("Custom link name (optional)", text: $slug).textInputAutocapitalization(.never).autocorrectionDisabled()
                if link != nil { Toggle("Change password", isOn: $passwordChange) }
                if link == nil || passwordChange { SecureField("Password (optional)", text: $password) }
                Toggle("Expire link", isOn: $expiryEnabled)
                if expiryEnabled { DatePicker("Expires", selection: $expiry, in: Date()...) }
            }.disabled(result != nil)
            Section("Access") {
                Toggle("Allow downloads", isOn: $download)
                Toggle("Allow uploads", isOn: $upload)
                Toggle("Show photo metadata", isOn: $metadata)
            }.disabled(result != nil)
        }.navigationTitle(link == nil ? (album == nil ? "Share photos" : "Share album") : "Edit shared link")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(result == nil ? "Save" : "Done") {
            if result != nil { dismiss() } else { Task { await save() } }
        }.disabled(saving).requiresWriteAccess(when: result == nil) } }
        .task {
            if let link {
                description = link.description ?? ""; slug = link.slug ?? ""; download = link.allowDownload; upload = link.allowUpload; metadata = link.showMetadata
                expiryEnabled = link.expiresAt != nil; expiry = link.expiresAt ?? expiry
            } else { description = album?.albumName ?? "" }
        }
        .alert("Couldn’t save shared link", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func save() async {
        guard let collections else { failure = .init(APIError.signedOut); return }
        saving = true; defer { saving = false }
        do {
            if let link {
                let update = SharedLinkUpdate(description: description, slug: slug.isEmpty ? nil : slug, expiresAt: expiryEnabled ? expiry : nil, password: password.isEmpty ? nil : password, changePassword: passwordChange, allowDownload: download, allowUpload: upload, showMetadata: metadata)
                result = try await collections.updateLink(link.id, update)
            } else {
                guard album != nil || !assetIDs.isEmpty else { throw APIError.invalidResponse("Choose some photos or an album to share.") }
                result = try await collections.createLink(SharedLinkDraft(type: album == nil ? "INDIVIDUAL" : "ALBUM", albumId: album?.id, assetIds: album == nil ? assetIDs : nil, description: description, slug: slug.isEmpty ? nil : slug, expiresAt: expiryEnabled ? expiry : nil, password: password.isEmpty ? nil : password, allowDownload: download, allowUpload: upload, showMetadata: metadata))
            }
            onSaved()
        } catch { failure = .init(error) }
    }
}

private func sharedURL(link: SharedLink, api: APIClient) -> URL? {
    let base = api.baseURL.deletingLastPathComponent()
    return base.appendingPathComponent(link.slug == nil ? "share" : "s").appendingPathComponent(link.slug ?? link.key)
}


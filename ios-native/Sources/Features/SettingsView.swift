import SwiftUI

enum SettingsDestination: String, CaseIterable {
    case account, backup, readOnly, appearance, grid, network, notifications, server, diagnostics, about
    var title: String {
        switch self {
        case .readOnly: "Read-only mode"
        default: rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .backup: "icloud.and.arrow.up"
        case .readOnly: "pencil.slash"
        case .appearance: "circle.lefthalf.filled"
        case .grid: "square.grid.3x3"
        case .network: "network"
        case .notifications: "bell"
        case .server: "externaldrive.connected.to.line.below"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}

struct SettingsDestinationView: View {
    let api: APIClient
    let destination: SettingsDestination
    var pipeline: MediaPipeline? = nil
    var session: SessionStore? = nil

    @ViewBuilder var body: some View {
        switch destination {
        case .account:
            AccountSettingsView(api: api)
        case .backup:
            BackupSettingsView()
        case .readOnly:
            Form { ReadOnlySettingsSection(session: session) }
                .navigationTitle("Read-only mode")
        case .network:
            NetworkSettingsView(api: api, server: api.baseURL)
        case .notifications:
            NotificationSettingsView()
        case .diagnostics:
            DiagnosticsView(api: api, pipeline: pipeline, session: session)
        case .appearance:
            Form { AppearanceSettingsSection() }
                .navigationTitle("Appearance")
        case .grid:
            Form { GridSettingsSection() }
                .navigationTitle("Grid")
        case .server:
            ServerSettingsView(api: api)
        case .about:
            AboutIlyichView()
        }
    }
}

struct SettingsView: View {
    let api: APIClient
    var pipeline: MediaPipeline? = nil
    var session: SessionStore? = nil
    let onSignOut: () -> Void
    @State private var user: User?
    @State private var failure: FeatureFailure?
    @State private var confirmSignOut = false
    var body: some View {
        Form {
            Section {
                NavigationLink { SettingsDestinationView(api: api, destination: .account) } label: {
                    Label { VStack(alignment: .leading) { Text(user?.name ?? "Account"); if let email = user?.email { Text(email).font(.caption).foregroundStyle(.secondary) } } } icon: { Image(systemName: "person.crop.circle") }
                }
                NavigationLink { SettingsDestinationView(api: api, destination: .backup) } label: { Label("Backup", systemImage: "icloud.and.arrow.up") }
            }
            ReadOnlySettingsSection(session: session)
            Section("Library") {
                NavigationLink { SettingsDestinationView(api: api, destination: .appearance) } label: { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                NavigationLink { SettingsDestinationView(api: api, destination: .grid) } label: { Label("Grid", systemImage: "square.grid.3x3") }
            }
            Section {
                NavigationLink { NetworkSettingsView(api: api, server: api.baseURL) } label: { Label("Network", systemImage: "network") }
                NavigationLink { NotificationSettingsView() } label: { Label("Notifications", systemImage: "bell") }
                NavigationLink { SettingsDestinationView(api: api, destination: .server) } label: { Label("Server", systemImage: "externaldrive.connected.to.line.below") }
                NavigationLink { DiagnosticsView(api: api, pipeline: pipeline, session: session) } label: { Label("Diagnostics", systemImage: "stethoscope") }
                NavigationLink { SettingsDestinationView(api: api, destination: .about) } label: { Label("About", systemImage: "info.circle") }
            }
            Section { Button("Sign out", role: .destructive) { confirmSignOut = true } }
        }.navigationTitle("Settings")
        .task { do { user = try await api.currentUser() } catch { failure = .init(error) } }
        .confirmationDialog("Sign out of Ilyich?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { onSignOut() }
        } message: { Text("Backup will stop on this phone. Photos already on your server are kept.") }
        .alert("Couldn’t load account", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
}

/// Read-only mode, shown in Settings and as its own row on the Settings shelf. The setting is the
/// session's: the toggle shows the account's authorization and asks the session to change it.
private struct ReadOnlySettingsSection: View {
    let session: SessionStore?
    @Environment(\.authorization) private var authorization

    var body: some View {
        Section {
            Toggle("Read-only mode", isOn: Binding(get: { authorization?.readOnly == true }, set: { session?.setReadOnly($0) }))
                // Until uploads have paused, when the last change turned it on.
                .disabled(session == nil || authorization == nil || session?.isApplyingReadOnly == true)
        } footer: { Text("Browse and search without changing photos, albums or account details. Turning this on pauses uploads. Backup stays paused until you start it again.") }
    }
}

private struct AppearanceSettingsSection: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(AppearanceAccent.storageKey) private var accentName = AppearanceAccent.design.rawValue

    var body: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Picker("Accent color", selection: $accentName) {
                ForEach(AppearanceAccent.allCases) { Text($0.title).tag($0.rawValue) }
            }
            NavigationLink("Photo and video viewer") { ViewerSettingsView() }
            NavigationLink("Slideshow") { SlideshowSettingsView() }
        }
    }
}

private struct GridSettingsSection: View {
    @AppStorage("gridColumns") private var columns = 4
    @AppStorage("timelineGrouping") private var timelineGrouping = "month"
    @AppStorage("hapticFeedback") private var haptics = true

    var body: some View {
        Section("Grid") {
            Picker("Grid", selection: $columns) {
                ForEach(2...6, id: \.self) { Text("\($0) columns").tag($0) }
            }
            Picker("Timeline", selection: $timelineGrouping) {
                Text("Month").tag("month")
                Text("Day").tag("day")
            }
            Toggle("Haptic feedback", isOn: $haptics)
        }
    }
}

private struct ViewerSettingsView: View {
    @AppStorage("viewerAutoPlayVideo") private var autoplay = true
    @AppStorage("viewerLoopVideo") private var loop = true
    @AppStorage("viewerMuteVideo") private var mute = false
    @AppStorage("viewerLoadOriginalVideo") private var originalVideo = false
    @AppStorage("viewerTapToNavigate") private var tapNavigation = false
    @AppStorage("imageLoadOriginal") private var originalImage = false
    @AppStorage("shareFileType") private var shareFileType = "original"
    var body: some View {
        Form {
            Section {
                Toggle("Full-resolution photos", isOn: $originalImage)
                Toggle("Tap edges to navigate", isOn: $tapNavigation)
            } header: { Text("Photos") } footer: { Text("Full-resolution photos use more data. Lightroom edits are preserved.") }
            Section {
                Picker("Share photos as", selection: $shareFileType) { Text("Original").tag("original"); Text("Displayed").tag("preview") }
            } footer: { Text("Displayed keeps the edits you see in the viewer. Videos are always shared as originals.") }
            Section {
                Toggle("Play automatically", isOn: $autoplay)
                Toggle("Repeat videos", isOn: $loop)
                Toggle("Start muted", isOn: $mute)
                Toggle("Play original videos", isOn: $originalVideo)
            } header: { Text("Videos") } footer: { Text("Original files can use more data and take longer to load. Video formats unsupported by this phone may need server playback.") }
        }.navigationTitle("Photo and video viewer")
    }
}

private struct AccountSettingsView: View {
    let api: APIClient
    @State private var name = ""
    @State private var email = ""
    @State private var loading = true
    @State private var saving = false
    @State private var saved = false
    @State private var account: User?
    @State private var failure: FeatureFailure?
    var body: some View {
        Form {
            Section("Profile") { TextField("Name", text: $name).textContentType(.name); LabeledContent("Email", value: email) }
            Section {
                NavigationLink("Profile photo") { ProfilePhotoSettingsView(api: api) }
                NavigationLink("Change password") { ChangePasswordView(api: api) }
                NavigationLink("Locked folder PIN") { PINSettingsView(api: api) }
            }
            if let account { AccountStorageSection(user: account) }
            if let account, account.quotaSizeInBytes == nil { ServerStorageSection(api: api) }
            if saved { Label("Profile saved", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
        }.navigationTitle("Account").disabled(loading || saving)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(loading || saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).requiresWriteAccess() } }
        .task {
            do { let user = try await api.currentUser(); account = user; name = user.name; email = user.email ?? "" } catch { failure = .init(error) }
            loading = false
        }
        .alert("Couldn’t update account", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func save() async {
        saving = true; saved = false; defer { saving = false }
        do { let _: User = try await api.request(.put, path: "users/me", body: ["name": name]); saved = true } catch { failure = .init(error) }
    }
}

struct ChangePasswordView: View {
    let api: APIClient
    var onChanged: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var invalidate = false
    @State private var saving = false
    @State private var failure: FeatureFailure?
    var body: some View {
        Form {
            Section {
                SecureField("Current password", text: $current).textContentType(.password)
                SecureField("New password", text: $password).textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmation).textContentType(.newPassword)
            } footer: { Text("Use at least 8 characters.") }
            Toggle("Sign out other devices", isOn: $invalidate)
        }.navigationTitle("Change password")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving || current.isEmpty || password.count < 8 || password != confirmation).requiresWriteAccess() } }
        .alert("Couldn’t change password", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func save() async {
        struct Body: Encodable, Sendable { let password: String; let newPassword: String; let invalidateSessions: Bool }
        saving = true; defer { saving = false }
        do {
            try await api.requestVoid(.post, path: "auth/change-password", body: Body(password: current, newPassword: password, invalidateSessions: invalidate))
            current = ""; password = ""; confirmation = ""
            if let onChanged { onChanged() } else { dismiss() }
        } catch { failure = .init(error) }
    }
}

private struct ServerSettingsView: View {
    let api: APIClient
    @State private var stats: AssetStatistics?
    @State private var version = ""
    @State private var failure: FeatureFailure?
    var body: some View {
        Form {
            Section("Connection") { LabeledContent("Server", value: api.baseURL.deletingLastPathComponent().absoluteString); if !version.isEmpty { LabeledContent("Version", value: version) } }
            if let stats { Section("Your library") { LabeledContent("Photos", value: stats.images.formatted()); LabeledContent("Videos", value: stats.videos.formatted()); LabeledContent("Total", value: stats.total.formatted()) } }
            ServerStorageSection(api: api)
        }.navigationTitle("Server")
        .task {
            struct Version: Decodable, Sendable { let major: Int; let minor: Int; let patch: Int }
            do {
                stats = try await api.assetStatistics()
                let response: Version = try await api.request(.get, path: "server/version")
                version = "\(response.major).\(response.minor).\(response.patch)"
            } catch { failure = .init(error) }
        }
        .alert("Couldn’t load server details", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
}

private struct AboutIlyichView: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) { Image("IlyichLogo").resizable().scaledToFit().frame(width: 48, height: 48); VStack(alignment: .leading) { Text("Ilyich").font(.headline); Text("Your memories, with you.").foregroundStyle(.secondary) } }
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
                Link("Source code", destination: URL(string: "https://github.com/ilyador/Ilyich")!)
            }
            Section("Credits") {
                Text("Based on Immich. Licensed under the GNU AGPL v3.")
                Text("Made with Natural Earth. Free vector and raster map data @ naturalearthdata.com.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("About")
    }
}

private struct AccountStorageSection: View {
    let user: User
    var body: some View {
        Section("Your storage") {
            if let used = user.quotaUsageInBytes {
                LabeledContent("Used", value: storageBytes(used))
                if let limit = user.quotaSizeInBytes {
                    ProgressView(value: min(1, max(0, Double(used) / Double(max(1, limit)))))
                        .accessibilityLabel("Account storage").accessibilityValue("\(storageBytes(used)) of \(storageBytes(limit))")
                }
            } else { Text("Your server has not reported account usage.").foregroundStyle(.secondary) }
            if let limit = user.quotaSizeInBytes { LabeledContent("Account limit", value: storageBytes(limit)) }
            else { LabeledContent("Account limit", value: "Unlimited") }
        }
    }
}

private struct ServerStorageSection: View {
    let api: APIClient
    @State private var storage: Storage?
    @State private var failure: String?
    @State private var loading = false
    private struct Storage: Decodable, Sendable {
        let diskSizeRaw: Int64
        let diskUseRaw: Int64
        let diskAvailableRaw: Int64
    }
    var body: some View {
        Section("Server storage") {
            if let storage {
                ProgressView(value: min(1, max(0, Double(storage.diskUseRaw) / Double(max(1, storage.diskSizeRaw)))))
                    .accessibilityLabel("Server storage").accessibilityValue("\(storageBytes(storage.diskUseRaw)) of \(storageBytes(storage.diskSizeRaw))")
                LabeledContent("Used", value: storageBytes(storage.diskUseRaw))
                LabeledContent("Available", value: storageBytes(storage.diskAvailableRaw))
                LabeledContent("Total", value: storageBytes(storage.diskSizeRaw))
            }
            if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary); Button("Retry storage details") { Task { await load() } }.disabled(loading) }
            if loading { ProgressView() }
        }.task { await load() }
    }
    private func load() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do { storage = try await api.request(.get, path: "server/storage"); failure = nil }
        catch is CancellationError { }
        catch ServerFailure.forbidden { failure = "Server storage information is unavailable for this account." }
        catch { failure = error.localizedDescription }
    }
}
private func storageBytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file) }

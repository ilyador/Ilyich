import SwiftUI
import Photos

struct BackupSettingsView: View {
    @State private var backup = BackupCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                Label(backup.activity, systemImage: backup.isRunning ? "arrow.triangle.2.circlepath" : "icloud.and.arrow.up")
                if let progress = backup.progress { ProgressView(value: progress).accessibilityLabel("Current file progress") }
                if backup.totalTransferBytes > 0 {
                    LabeledContent("Transferred", value: "\(ByteCountFormatter.string(fromByteCount: backup.bytesTransferred, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: backup.totalTransferBytes, countStyle: .file))")
                }
                if let rate = backup.transferRate { LabeledContent("Upload speed", value: "\(ByteCountFormatter.string(fromByteCount: rate, countStyle: .file))/s") }
                LabeledContent("Remaining", value: backup.remaining.formatted())
                LabeledContent("Confirmed uploads", value: backup.confirmed.formatted())
                if let error = backup.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("backup.error") }
                if backup.isRunning {
                    Button("Pause backup", role: .destructive) { Task { await backup.pause() } }
                } else {
                    Button(backup.remaining > 0 ? "Resume backup" : "Back up now") { Task { await backup.start() } }
                        .disabled(![PHAuthorizationStatus.authorized, .limited].contains(backup.permission) || backup.preferences.includedAlbums.isEmpty)
                }
            } header: { Text("Backup") } footer: {
                Text("Original files stay in Photos. Transfers already started can continue while Ilyich is in the background.")
            }

            if !backup.failures.isEmpty {
                Section("Uploads needing retry") {
                    ForEach(backup.failures) { failure in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.filename)
                            Text(failure.message).font(.footnote).foregroundStyle(.secondary)
                            Text(failure.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if backup.permission == .notDetermined {
                Section {
                    Button("Choose Photos access") { Task { await backup.requestAccess() } }
                }
            } else if backup.permission == .denied || backup.permission == .restricted {
                Section {
                    Text("Allow Photos access in Settings to choose albums for backup.")
                    Button("Open Settings") { openSettings() }
                }
            } else {
                if backup.permission == .limited {
                    Section {
                        Text("Only the photos you allowed are available for backup.")
                        Button("Change Photos access") { openSettings() }
                    }
                }
                Section("Albums") {
                    Toggle("Sync albums to server", isOn: $backup.preferences.syncAlbums).disabled(backup.isRunning)
                    ForEach(backup.albums) { album in
                        Picker(selection: Binding(get: { selection(for: album.id) }, set: { setSelection($0, for: album.id) })) {
                            Text("Off").tag(0)
                            Text("Back up").tag(1)
                            Text("Exclude").tag(2)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(album.title)
                                Text("\(album.count.formatted()) items\(album.isShared ? " · Shared album" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(backup.isRunning)
                    }
                }
                Section {
                    Toggle("Automatic backup", isOn: $backup.preferences.automatic)
                    Toggle("Only while charging", isOn: $backup.preferences.requireCharging)
                    Stepper("Wait \(backup.preferences.triggerDelay) seconds", value: $backup.preferences.triggerDelay, in: 0...3600, step: 30)
                    Toggle("Use cellular for photos", isOn: $backup.preferences.cellularPhotos)
                    Toggle("Use cellular for videos", isOn: $backup.preferences.cellularVideos)
                    Toggle("Download iCloud originals", isOn: $backup.preferences.downloadCloudOriginals)
                } header: { Text("Transfers") } footer: {
                    Text("iOS decides when background work can run. Cellular settings apply to uploads and iCloud downloads. With downloads off, unavailable originals pause backup for you to review.")
                }
                .disabled(backup.isRunning)
            }
        }
        .navigationTitle("Device backup")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await backup.activate()
            while !Task.isCancelled {
                await backup.refreshProgress()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: backup.preferences) { _, _ in backup.savePreferences() }
        .onChange(of: scenePhase) { _, value in if value == .active { backup.refreshLibrary() } }
    }

    private func selection(for id: String) -> Int {
        backup.preferences.excludedAlbums.contains(id) ? 2 : backup.preferences.includedAlbums.contains(id) ? 1 : 0
    }
    private func setSelection(_ value: Int, for id: String) {
        backup.preferences.includedAlbums.remove(id); backup.preferences.excludedAlbums.remove(id)
        if value == 1 { backup.preferences.includedAlbums.insert(id) }
        if value == 2 { backup.preferences.excludedAlbums.insert(id) }
    }
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

import SwiftUI
import Photos

/// Settings-only choice; `PhotoSelectionScope` remains the engine's stable scope contract.
private enum BackupScopeChoice: Hashable {
    case selectedAlbums
    case entireLibrary
    case newPhotosOnly
}

struct BackupSettingsView: View {
    @State private var backup = BackupStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            BackupStatusSection()

            if !backup.failures.isEmpty {
                Section("Uploads needing retry") {
                    Button("Retry failed uploads") { Task { await backup.retryFailures() } }
                        .disabled(backup.isRunning || backup.isSettingUpNewPhotos).requiresWriteAccess()
                    ForEach(backup.failures, id: \.source) { failure in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.displayName ?? "Photo in selected album")
                            Text(failure.message ?? "").font(.footnote).foregroundStyle(.secondary)
                            if let date = failure.failedAt { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
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
                        Text("Photos access is limited to the items you selected. Choose Full Access in Settings to back up your entire library.")
                        Text("New photos from now also needs Full Access so Ilyich can record a complete starting point.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Open Photos Settings") { openSettings() }
                    }
                }
                Section {
                    Picker("Photos to back up", selection: Binding(get: { selectedScope }, set: setScope)) {
                        Text("Selected albums").tag(BackupScopeChoice.selectedAlbums)
                        Text("Back up entire library").tag(BackupScopeChoice.entireLibrary)
                        Text("New photos from now")
                            .tag(BackupScopeChoice.newPhotosOnly)
                            .disabled(backup.permission != .authorized)
                    }
                    .accessibilityIdentifier("backup.scope")
                    .disabled(backup.isRunning || backup.isSettingUpNewPhotos)
                    .requiresWriteAccess()
                    if selectedScope == .newPhotosOnly {
                        if let baseline = backup.preferences.newPhotosBaselineStartedAt {
                            LabeledContent("Starting point", value: baseline.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                        }
                        Text("Existing photos and videos, including later edits, stay excluded. New items added after the starting point are backed up. Old originals are not checked or downloaded.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("backup.scope.newPhotosHelp")
                    } else if selectedScope == .entireLibrary {
                        Text("Existing server copies are checked before upload. Includes hidden photos and burst frames.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("backup.scope.entireLibraryHelp")
                    } else {
                        Text("Choose albums below. Existing server copies are checked before upload.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Automatic backup", isOn: $backup.preferences.automatic)
                        .disabled(backup.isRunning || backup.isSettingUpNewPhotos).requiresWriteAccess()
                    Toggle("Download iCloud originals", isOn: $backup.preferences.downloadCloudOriginals)
                        .disabled(backup.isRunning || backup.isSettingUpNewPhotos).requiresWriteAccess()
                } header: { Text("Backup scope") } footer: {
                    if backup.isSettingUpNewPhotos {
                        Label("Setting a new-photo starting point…", systemImage: "clock")
                    } else if selectedScope == .newPhotosOnly {
                        Text("Automatic backup checks for items added after the starting point while Ilyich is open and when iOS grants background time. Download iCloud originals applies to those new items only.")
                    } else {
                        Text("Automatic backup checks your selected scope for new items while Ilyich is open and when iOS grants background time. Download iCloud originals lets Ilyich upload files kept only in iCloud. You can also start a backup manually above.")
                    }
                }

                Section {
                    Toggle("Create matching albums on server", isOn: $backup.preferences.syncAlbums)
                        .disabled(backup.isRunning || backup.isSettingUpNewPhotos).requiresWriteAccess()
                    ForEach(backup.albums) { album in
                        Picker(selection: Binding(get: { selection(for: album.id) }, set: { setSelection($0, for: album.id) })) {
                            Text("Off").tag(0)
                            Text(backup.preferences.scope == .selectedAlbums ? "Back up" : "Copy album").tag(1)
                            Text("Exclude").tag(2)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(album.title)
                                Text("\(album.count.formatted()) item\(album.count == 1 ? "" : "s")\(album.isShared ? " · Shared album" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(backup.isRunning || backup.isSettingUpNewPhotos)
                    }
                } header: { Text("Apple Photos albums") } footer: {
                    if selectedScope == .newPhotosOnly {
                        Text("Only new photos and videos are backed up. Copy album adds those new items to matching server albums. Exclude skips new items in that album.")
                    } else if backup.preferences.scope == .entireLibrary {
                        Text("The entire library supplies files for backup. Choose Copy album to recreate only those album groupings on the server. Excluded albums stay out of the file backup.")
                    } else {
                        Text("Back up adds an album’s photos and videos to the backup. Exclude leaves those items out, even if they also appear in another selected album.")
                    }
                    Text("When enabled, Ilyich creates or matches a server album for each selected album and adds backed-up photos to it. Removing items in Photos does not remove them from server albums.")
                }

                Section {
                    DisclosureGroup("Advanced transfer settings") {
                        Toggle("Only while charging", isOn: $backup.preferences.requireCharging)
                        Stepper("Check Photos after \(backup.preferences.triggerDelay) seconds", value: $backup.preferences.triggerDelay, in: 0...3600, step: 30)
                        Toggle("Use cellular for photos", isOn: $backup.preferences.cellularPhotos)
                        Toggle("Use cellular for videos", isOn: $backup.preferences.cellularVideos)
                    }
                } footer: {
                    Text("Only while charging limits new uploads and background scheduling; transfers already under way may finish. The delay applies before checking Photos for new items after changes. iOS decides when background work can run. Cellular settings apply to uploads and iCloud downloads. Unavailable originals stay in the retry list while other files continue.")
                }
                .disabled(backup.isRunning || backup.isSettingUpNewPhotos)
            }
        }
        .navigationTitle("Device backup")
        .navigationBarTitleDisplayMode(.inline)
        // The account's backup is taken up as it signs in; progress arrives as it is sent.
        .task { await backup.refreshLibrary() }
        .onChange(of: backup.preferences) { _, _ in backup.preferencesChanged() }
        .onDisappear { Task { await backup.flushPreferences() } }
        .onChange(of: scenePhase) { _, value in if value == .active { Task { await backup.refreshLibrary() } } }
    }

    private var selectedScope: BackupScopeChoice {
        if backup.preferences.newPhotosOnly { return .newPhotosOnly }
        return backup.preferences.scope == .entireLibrary ? .entireLibrary : .selectedAlbums
    }

    private func setScope(_ choice: BackupScopeChoice) {
        guard !backup.isSettingUpNewPhotos else { return }
        switch choice {
        case .newPhotosOnly:
            guard backup.permission == .authorized else { return }
            Task { await backup.enableNewPhotosBackup() }
        case .entireLibrary:
            backup.preferences.newPhotosOnly = false
            backup.preferences.scope = .entireLibrary
            backup.preferencesChanged()
        case .selectedAlbums:
            backup.preferences.newPhotosOnly = false
            backup.preferences.scope = .selectedAlbums
            backup.preferencesChanged()
        }
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


/// Transfer ticks update this small section rather than rebuilding every album picker.
private struct BackupStatusSection: View {
    @State private var backup = BackupStore.shared
    var body: some View {
    Section {
        Label(backup.activity, systemImage: backup.isRunning ? "arrow.triangle.2.circlepath" : "icloud.and.arrow.up")
        BackupStatisticsSummary(statistics: backup.statistics,
                                newPhotosBaselineStartedAt: backup.newPhotosStartingPoint)
        if let selection = backup.statistics.selectionProgress {
            LabeledContent(backup.newPhotosStartingPoint == nil ? "Library checked" : "New items checked",
                           value: selection.checkedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
        if backup.statistics.failed > 0 {
            LabeledContent("Uploads needing retry", value: backup.statistics.failed.formatted())
        }
        if let fraction = backup.statistics.preparationFraction {
            BackupPreparationDetail(fraction: fraction)
        }
        if let progress = backup.statistics.currentTransfer, progress.expectedBytes != nil || progress.sentBytes > 0 {
            BackupTransferDetail(progress: progress)
        }
        if backup.remaining > 0 {
            NavigationLink("View pending items") {
                BackupQueueView()
            }
        }
        if backup.newPhotosStartingPoint != nil {
            NavigationLink("Backup history") { BackupQueueView(showCompleted: true) }
        } else if backup.confirmed > 0 {
            NavigationLink("View verified backups") { BackupQueueView(showCompleted: true) }
        }
        if backup.confirmed > 0 && backup.newPhotosStartingPoint == nil {
            NavigationLink("Link archived originals") { ArchiveOriginalMatchingView() }
                .accessibilityIdentifier("backup.originalMatching")
                .requiresWriteAccess()
        }
        if let issue = backup.snapshot.backgroundIssue {
            Label(issue.title, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
            Text(issue.message).font(.footnote).foregroundStyle(.secondary)
            if issue.canOpenSettings {
                Button("Open app settings") { openSettings() }
            }
        }
        if let error = backup.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("backup.error") }
        if backup.isRunning {
            Button("Pause backup", role: .destructive) { Task { await backup.pause() } }
        } else {
            Button(backup.remaining > 0 ? "Resume backup" : "Back up now") { Task { await backup.start() } }
                .disabled(backup.isSettingUpNewPhotos || ![PHAuthorizationStatus.authorized, .limited].contains(backup.permission) || (backup.remaining == 0 && !backup.preferences.hasSelection))
                .requiresWriteAccess()
        }
    } header: { Text("Backup") } footer: {
        if backup.newPhotosStartingPoint != nil {
            Text("Only items added after the starting point are included. Existing photos, videos, and later edits are left out.")
        } else {
            Text("Verified means this phone has checked the server copy; it is not a count of new uploads. Unchecked photos may already be backed up. When a file cannot be identified from saved records, Ilyich may need to read or download its original to compare it. Identical files are skipped.")
        }
    }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

import SwiftUI

struct DiagnosticsView: View {
    let api: APIClient
    let pipeline: MediaPipeline?
    var session: AccountSession? = nil
    @AppStorage(DiagnosticsStore.levelKey) private var level = DiagnosticLevel.errors.rawValue
    @AppStorage(ThumbnailLimitSetting.defaultsKey) private var thumbnailLimit = ThumbnailDiskStore.defaultLimit
    @State private var events: [DiagnosticEvent] = []
    @State private var media: MediaCacheUsage?
    @State private var syncStatistics: EntityStoreStatistics?
    @State private var statisticsError: String?
    @State private var backup = BackupStore.shared
    @State private var clearing = false
    @State private var confirmReset = false
    @State private var resetMessage: String?
    @State private var confirmMetadataReset = false
    var body: some View {
        Form {
            Section("App") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown")
                LabeledContent("System", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                LabeledContent("Read-only mode", value: api.isReadOnly ? "On" : "Off")
            }
            Section("Backup queue") {
                LabeledContent("State", value: backup.isRunning ? "Running" : "Paused")
                LabeledContent("Remaining", value: backup.remaining.formatted())
                LabeledContent("Confirmed", value: backup.confirmed.formatted())
                LabeledContent("Failed", value: backup.snapshot.failed.formatted())
                NavigationLink("Backup details") { BackupSettingsView() }
            }
            if let session, session.runtime?.transfers != nil {
                Section {
                    LabeledContent("Engine") { Text(TransferHost.shared.summary).multilineTextAlignment(.trailing) }
                } header: { Text("Backup records") } footer: {
                    Text("This account’s backup runs on Ilyich’s backup engine.")
                }
            }
            Section {
                if let session {
                    LabeledContent("State", value: session.isSyncing ? "Syncing" : (session.syncError != nil ? "Needs attention" : (syncStatistics?.isComplete == true ? "Ready" : "Waiting for first sync")))
                    if session.isSyncing { ProgressView().accessibilityLabel("Synchronizing library metadata") }
                    if let message = session.syncError { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { session.startSync() }.disabled(session.isSyncing)
                    Button("Reset local library metadata", systemImage: "arrow.counterclockwise", role: .destructive) { confirmMetadataReset = true }.disabled(session.isSyncing)
                }
                if let statistics = syncStatistics {
                    if let date = statistics.lastSync { LabeledContent("Last completed sync") { Text(date, format: .dateTime.year().month().day().hour().minute()).multilineTextAlignment(.trailing) } }
                    DisclosureGroup("Saved library metadata") {
                        ForEach(entityLabels, id: \.key) { item in
                            LabeledContent(item.name, value: (statistics.counts[item.key] ?? 0).formatted())
                        }
                    }
                } else if let statisticsError { Text(statisticsError).font(.footnote).foregroundStyle(.secondary) }
                else { Text("Metadata counts will appear after the local library connects.").foregroundStyle(.secondary) }
            } header: { Text("Library sync") } footer: {
                Text("Keeps library metadata on this phone for browsing and applies server changes. Counts exclude the locked folder. Downloaded photo previews have a separate cache; an indexed photo is not necessarily available offline.")
            }
            Section {
                if let coverage = session?.coverage, coverage.board.progress.total > 0 {
                    let progress = coverage.board.progress
                    LabeledContent("Thumbnails kept offline", value: "\(progress.stored.formatted()) of \(progress.total.formatted())")
                }
                if let media {
                    // In binary units, which the cap is set in, so it reads as it was set.
                    LabeledContent("Offline thumbnails", value: "\(bytes(media.thumbnailBytes, .binary)) of \(bytes(media.thumbnailLimit, .binary))")
                    Picker("Offline thumbnail limit", selection: $thumbnailLimit) {
                        ForEach(ThumbnailLimitSetting.choices, id: \.self) { Text(bytes($0, .binary)).tag($0) }
                    }
                    LabeledContent("Photo download cache", value: bytes(media.diskBytes))
                    LabeledContent("Downloads held in memory", value: bytes(media.memoryBytes))
                    LabeledContent("Decoded image memory limit", value: bytes(media.decodedMemoryLimit))
                    LabeledContent("Image requests", value: media.pendingLoads.formatted())
                }
                if let resetMessage { Text(resetMessage).font(.footnote).foregroundStyle(.secondary) }
                if session != nil { Button("Clear browsing cache", role: .destructive) { confirmReset = true }.disabled(clearing) }
            } header: { Text("Browsing cache") } footer: {
                Text("Offline thumbnails let you browse without a connection, up to the limit; a lower limit removes those viewed least recently. Clear browsing cache removes this account’s downloaded previews and the images held in memory; previews download again when you view them. Offline thumbnails stay. Originals, backup receipts, your upload queue and photos on the server stay intact.")
            }
            Section {
                Picker("Record", selection: $level) { ForEach(DiagnosticLevel.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
                if !events.isEmpty {
                    ShareLink(item: report, preview: SharePreview("Ilyich diagnostics")) { Label("Export diagnostics", systemImage: "square.and.arrow.up") }
                    Button("Clear log", role: .destructive) { Task { await DiagnosticsStore.shared.clearRequests(); await refresh() } }
                }
                if events.isEmpty { Text("No recorded events in this session.").foregroundStyle(.secondary) }
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("\(event.method) · \(event.category)").font(.subheadline.monospaced())
                            Spacer()
                            Text(event.statusCode.map(String.init) ?? event.outcome.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack { Text(event.date, style: .time); Spacer(); Text("\(event.milliseconds) ms · \(event.outcome.rawValue)") }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }
            } header: { Text("Request log") } footer: {
                Text("Keeps up to 300 events until the app closes or you sign out. Only time, request type, category, status and duration are recorded. No server address, photo identifiers, search terms, headers or credentials are included.")
            }
        }.navigationTitle("Diagnostics")
        .task { await refresh() }
        .onChange(of: session?.lastSyncDate) { _, _ in Task { await refresh() } }
        .onChange(of: session?.isSyncing) { _, syncing in if syncing == false { Task { await refresh() } } }
        .refreshable { await refresh() }
        // A lower cap trims at once; a higher one lets coverage fill the room now.
        .onChange(of: thumbnailLimit) { _, bytes in
            pipeline?.thumbnails.setLimit(bytes)
            session?.coverage?.roomChanged()
            Task { await refresh() }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(clearing) } }
        .confirmationDialog("Clear this account’s browsing cache?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Clear browsing cache", role: .destructive) { Task { await clearCache() } }
        } message: { Text("Downloaded previews will be unavailable offline until you view them again. Offline thumbnails, your photos and backup records are kept.") }
        .confirmationDialog("Reset local library metadata?", isPresented: $confirmMetadataReset, titleVisibility: .visible) {
            Button("Reset metadata", role: .destructive) { Task { await resetLibraryMetadata() } }
        } message: { Text("Library metadata will be recreated from your server.") }
    }
    private func bytes(_ count: Int, _ style: ByteCountFormatter.CountStyle = .file) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: style)
    }
    private var entityLabels: [(key: String, name: String)] {
        [("asset", "Photos and videos"), ("exif", "EXIF records"), ("album", "Albums"), ("albumAsset", "Album items"),
         ("albumUser", "Album memberships"), ("person", "People"), ("face", "Face associations"), ("ocr", "Text regions"),
         ("memory", "Memories"), ("memoryAsset", "Memory items"), ("edit", "Photo edits"), ("stack", "Stacks"),
         ("user", "Users"), ("partner", "Partner relationships")]
    }
    private var report: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "Ilyich \(version) (\(build))\n\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)\n\n"
            + DiagnosticsStore.report(events: events)
    }
    private func refresh() async {
        events = await DiagnosticsStore.shared.snapshot()
        if let pipeline { media = await pipeline.cacheUsage() }
        do { syncStatistics = try await api.syncStatistics(); statisticsError = nil }
        catch is CancellationError { }
        catch { statisticsError = "Saved metadata counts could not be read. Refresh to try again." }
    }
    private func clearCache() async {
        guard let session, !clearing else { return }
        clearing = true; defer { clearing = false }
        await session.clearBrowsingCache()
        resetMessage = "Browsing cache cleared. Offline thumbnails were kept."
        await refresh()
    }
    private func resetLibraryMetadata() async {
        guard let session else { return }
        await session.resetLibraryMetadata()
        await refresh()
    }
}

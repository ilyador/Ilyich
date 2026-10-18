import SwiftUI

struct DiagnosticsView: View {
    let api: APIClient
    let pipeline: MediaPipeline?
    @AppStorage(DiagnosticsStore.levelKey) private var level = DiagnosticLevel.errors.rawValue
    @State private var events: [DiagnosticEvent] = []
    @State private var media: MediaCacheUsage?
    @State private var timeline: CachedTimelineUsage?
    @State private var backup = BackupCoordinator.shared
    @State private var clearing = false
    @State private var confirmReset = false
    @State private var resetMessage: String?
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
                LabeledContent("Failed", value: backup.failures.count.formatted())
                NavigationLink("Backup details") { BackupSettingsView() }
            }
            Section {
                if let timeline {
                    LabeledContent("Visited timeline snapshots", value: timeline.snapshotCount.formatted())
                    LabeledContent("Timeline cache", value: bytes(timeline.diskBytes))
                }
                if let media {
                    LabeledContent("Photo download cache", value: bytes(media.diskBytes))
                    LabeledContent("Downloads held in memory", value: bytes(media.memoryBytes))
                    LabeledContent("Decoded image memory limit", value: bytes(media.decodedMemoryLimit))
                    LabeledContent("Image requests", value: media.pendingLoads.formatted())
                }
                if let resetMessage { Text(resetMessage).font(.footnote).foregroundStyle(.secondary) }
                if pipeline != nil { Button("Clear browsing cache", role: .destructive) { confirmReset = true }.disabled(clearing) }
            } header: { Text("Browsing cache") } footer: {
                Text("Clears downloaded previews and visited timeline metadata for this account. Offline previews will need to download again. Originals, backup receipts, your upload queue and photos on the server stay intact.")
            }
            Section {
                Picker("Record", selection: $level) { ForEach(DiagnosticLevel.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
                if !events.isEmpty {
                    ShareLink(item: report, preview: SharePreview("Ilyich diagnostics")) { Label("Export diagnostics", systemImage: "square.and.arrow.up") }
                    Button("Clear log", role: .destructive) { Task { await DiagnosticsStore.shared.clear(); await refresh() } }
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
        .refreshable { await refresh() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(clearing) } }
        .confirmationDialog("Clear this account’s browsing cache?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Clear browsing cache", role: .destructive) { Task { await clearCache() } }
        } message: { Text("Downloaded previews will be unavailable offline until you view them again. Your photos and backup records are kept.") }
    }
    private func bytes(_ count: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) }
    private var report: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "Ilyich \(version) (\(build))\n\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)\n\n" + DiagnosticsStore.report(events: events)
    }
    private func refresh() async {
        events = await DiagnosticsStore.shared.snapshot()
        if let pipeline { media = await pipeline.cacheUsage() }
        timeline = await TimelineCache.shared.cacheUsage(scope: api.cacheScope)
    }
    private func clearCache() async {
        guard let pipeline, !clearing else { return }
        clearing = true; defer { clearing = false }
        await pipeline.removeAll()
        await TimelineCache.shared.removeAll(scope: api.cacheScope)
        NotificationCenter.default.post(name: .ilyichCachesReset, object: nil, userInfo: ["scope": api.cacheScope])
        resetMessage = "Browsing cache cleared. Visible photos may download again immediately."
        await refresh()
    }
}

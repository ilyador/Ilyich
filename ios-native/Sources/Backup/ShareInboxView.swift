import IlyichShareInbox
import SwiftUI

struct ShareInboxView: View {
    let api: APIClient
    @State private var inbox: ShareInboxModel
    @State private var selection = Set<String>()
    @State private var discard: SharedBatch?
    @Environment(\.dismiss) private var dismiss

    init(api: APIClient) {
        self.api = api
        _inbox = State(initialValue: ShareInboxModel(api: api))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Upload selected files to \(api.baseURL.host() ?? "your server").")
                        .foregroundStyle(.secondary)
                    if inbox.completed > 0 { Text("\(inbox.completed) uploaded") }
                    if inbox.isRunning {
                        if let progress = inbox.progress { ProgressView(value: progress) }
                        else { ProgressView("Uploading") }
                        Button("Pause upload", role: .destructive) { Task { await inbox.pause() } }
                    } else if !inbox.batches.isEmpty {
                        Button("Upload \(selection.count) selected") { let selected = selection; Task { await inbox.upload(selected: selected) } }
                            .disabled(selection.isEmpty || api.isReadOnly)
                    }
                    if let error = inbox.error { Text(error).foregroundStyle(.red) }
                    if inbox.unreadableBatches > 0 { Text("Some shared files couldn’t be read and aren’t listed.").foregroundStyle(.red) }
                    if api.isReadOnly { Text("Turn off Read-only mode in Settings to upload.").foregroundStyle(.secondary) }
                }
                if inbox.batches.isEmpty {
                    ContentUnavailableView("No pending shares", systemImage: "checkmark.circle", description: Text("Files you share to Ilyich appear here before upload."))
                }
                ForEach(inbox.batches) { batch in
                    Section {
                        ForEach(batch.attachments) { item in
                            Button { toggle(item.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.original.filename).foregroundStyle(.primary)
                                        if item.motion != nil { Label("Live Photo", systemImage: "livephoto").font(.caption) }
                                        if item.sidecar != nil { Text("Includes XMP edits").font(.caption).foregroundStyle(.secondary) }
                                        if let error = inbox.errors[item.id] { Text(error).font(.footnote).foregroundStyle(.red) }
                                    }
                                    if inbox.currentID == item.id { Spacer(); ProgressView() }
                                }
                            }.disabled(inbox.isRunning)
                        }
                        Button("Discard shared copies", role: .destructive) { discard = batch }.disabled(inbox.isRunning)
                    } header: { Text(batch.createdAt.formatted(date: .abbreviated, time: .shortened)) }
                }
            }
            .navigationTitle("Shared files")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Discard these shared copies?", isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } })) {
                Button("Discard copies", role: .destructive) { if let discard { inbox.discard(discard) }; discard = nil }
            } message: { Text("Originals in Photos and the source app stay unchanged.") }
            .task {
                await inbox.refresh()
                selection = Set(inbox.batches.flatMap { $0.attachments.map(\.id) })
            }
            .onChange(of: inbox.batches.flatMap { $0.attachments.map(\.id) }) { _, ids in selection.formIntersection(ids) }
        }
    }

    private func toggle(_ id: String) {
        if !selection.insert(id).inserted { selection.remove(id) }
    }
}

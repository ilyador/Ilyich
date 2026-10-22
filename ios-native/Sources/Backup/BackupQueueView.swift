import SwiftUI

/// The upload queue or the confirmed uploads, a page at a time from the backup store; each row
/// reads its photo's details from the Photos adapter.
struct BackupQueueView: View {
    var showCompleted = false
    @State private var backup = BackupStore.shared
    @State private var viewing: LocalPhoto?
    @State private var queued: [TransferQueueItem] = []
    @State private var completed: [TransferHistoryItem] = []
    @State private var loaded = false
    @State private var exhausted = false
    private static let pageSize = 200

    /// What changes the list: a photo leaving or joining the queue, or failing.
    private var listChange: [Int] {
        showCompleted ? [backup.confirmed] : [backup.remaining, backup.snapshot.failed]
    }

    var body: some View {
        List {
            if showCompleted {
                Section {
                    ForEach(completed, id: \.localID) { item in
                        BackupQueueRow(localID: item.localID.rawValue, confirmedAt: item.confirmedAt) { viewing = $0 }
                            .onAppear { if item.localID == completed.last?.localID { Task { await loadMore() } } }
                    }
                } footer: {
                    Text("These files were verified when their backups completed. Ilyich checks the server again before offering to remove a local copy.")
                }
            } else {
                if loaded && queued.isEmpty {
                    ContentUnavailableView("No pending uploads", systemImage: "checkmark.icloud")
                } else {
                    ForEach(queued, id: \.source) { item in
                        BackupQueueRow(localID: item.localID, failure: item.message) { viewing = $0 }
                            .onAppear { if item.source == queued.last?.source { Task { await loadMore() } } }
                    }
                }
            }
        }
        .navigationTitle(showCompleted ? "Confirmed uploads" : "Upload queue")
        .task(id: listChange) { await reload() }
        .sheet(item: $viewing) { LocalPhotoViewer(photo: $0) }
    }

    /// Reads again from the start, as many rows as are shown, at least a page.
    private func reload() async {
        let limit = max(Self.pageSize, showCompleted ? completed.count : queued.count)
        if showCompleted {
            guard let page = try? await backup.backend.historyPage(offset: 0, limit: limit), !Task.isCancelled else { return }
            completed = page; exhausted = page.count < limit
        } else {
            guard let page = try? await backup.backend.queuePage(lane: .library, after: nil, limit: limit), !Task.isCancelled else { return }
            queued = page; exhausted = page.count < limit
        }
        loaded = true
    }

    private func loadMore() async {
        guard loaded, !exhausted else { return }
        if showCompleted {
            let offset = completed.count
            guard let page = try? await backup.backend.historyPage(offset: offset, limit: Self.pageSize), completed.count == offset else { return }
            completed += page; exhausted = page.count < Self.pageSize
        } else {
            let last = queued.last?.seq
            guard let page = try? await backup.backend.queuePage(lane: .library, after: last, limit: Self.pageSize), queued.last?.seq == last else { return }
            queued += page; exhausted = page.count < Self.pageSize
        }
    }
}

private extension TransferQueueItem {
    var localID: String {
        switch source {
        case .photo(let id): id.rawValue
        case .shared(_, let attachment): attachment
        }
    }
}

private struct BackupQueueRow: View {
    let localID: String
    /// The failure's message, for a photo that needs retry.
    var failure: String?
    var confirmedAt: Date?
    let onOpen: (LocalPhoto) -> Void
    @State private var photo: LocalPhoto?
    @State private var filename = "Photo in selected album"
    @State private var sourceAlbums = ""
    var body: some View {
        Button { if let photo { onOpen(photo) } } label: {
            HStack(spacing: 12) {
                if let photo { LocalPhotoThumbnail(photo: photo).frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 8)) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(filename).foregroundStyle(.primary)
                    if let date = photo?.date { Text(date, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary) }
                    if !sourceAlbums.isEmpty { Text(sourceAlbums).font(.caption).foregroundStyle(.secondary) }
                    if let date = confirmedAt { Text("Backed up \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                }
            }
        }.disabled(photo == nil)
        .task(id: localID) {
            guard let details = await PhotoKitAdapter.shared.details(of: localID) else {
                filename = "No longer available in Photos"; return
            }
            photo = details.photo
            filename = details.filename ?? details.photo.title
            sourceAlbums = details.albumTitles.sorted().joined(separator: " · ")
        }
    }
}

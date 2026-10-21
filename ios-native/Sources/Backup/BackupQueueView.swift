import SwiftUI

struct BackupQueueView: View {
    var showCompleted = false
    @State private var backup = BackupCoordinator.shared
    @State private var viewing: LocalPhoto?
    @State private var completedIDs: [String] = []
    var body: some View {
        List {
            if showCompleted {
                Section {
                    ForEach(completedIDs, id: \.self) { id in
                        BackupQueueRow(localID: id, receipt: backup.associations[id]) { viewing = $0 }
                    }
                } footer: {
                    Text("These files were verified when their backups completed. Ilyich checks the server again before offering to remove a local copy.")
                }
            } else {
                if backup.queuedLocalIDs.isEmpty {
                    ContentUnavailableView("No pending uploads", systemImage: "checkmark.icloud")
                } else {
                    ForEach(backup.queuedLocalIDs, id: \.self) { id in
                        BackupQueueRow(localID: id, failure: backup.failure(for: id)) { viewing = $0 }
                    }
                }
            }
        }
        .navigationTitle(showCompleted ? "Confirmed uploads" : "Upload queue")
        .task(id: backup.confirmed) {
            guard showCompleted else { return }
            let receipts = backup.associations
            let ids = await Task.detached(priority: .utility) {
                receipts.sorted {
                    let left = $0.value.confirmedAt ?? .distantPast, right = $1.value.confirmedAt ?? .distantPast
                    return left == right ? $0.key < $1.key : left > right
                }.map(\.key)
            }.value
            if !Task.isCancelled { completedIDs = ids }
        }
        .sheet(item: $viewing) { LocalPhotoViewer(photo: $0) }
    }
}

private struct BackupQueueRow: View {
    let localID: String
    var failure: BackupFailure?
    var receipt: BackupReceipt?
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
                    if let date = receipt?.confirmedAt { Text("Backed up \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    if let failure { Text(failure.message).font(.footnote).foregroundStyle(.red) }
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

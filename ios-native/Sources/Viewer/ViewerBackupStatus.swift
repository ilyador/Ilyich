import SwiftUI

/// Presentation of one item's backup record. Server presence and playable video are separate:
/// an asset in the server library can exist before its playback rendition is ready.
struct ViewerBackupStatus: View {
    var asset: Asset? = nil
    var photo: LocalPhoto? = nil
    var detailed = false
    @State private var backup = BackupStore.shared
    @State private var status: PhotoBackupStatus?
    @State private var showingDetails = false

    private var presentation: PhotoBackupPresentation {
        // A new edit must not briefly inherit the previous revision’s active transfer.
        let current = status.flatMap { value in
            value.localID == photo?.id && value.revision == photo?.modified.map(AssetRevision.init) ? value : nil
        }
        return PhotoBackupPresentation(status: current, isServerAsset: asset != nil)
    }

    var body: some View {
        Group {
            if detailed {
                Label(presentation.title, systemImage: presentation.symbol)
                Text(presentation.detail).font(.footnote).foregroundStyle(.secondary)
            } else if presentation.isActive {
                Button { showingDetails = true } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            if presentation.progress == nil { ProgressView().controlSize(.mini) }
                            Label(presentation.title, systemImage: presentation.symbol)
                                .font(.caption.weight(.medium)).lineLimit(2)
                        }
                        if let progress = presentation.progress {
                            ProgressView(value: progress).tint(.white)
                                .accessibilityLabel("Backup progress")
                                .accessibilityIdentifier("viewer.backupProgress")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 44)
                    .frame(maxWidth: 280, alignment: .leading)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityHint("Show backup status details")
                .popover(isPresented: $showingDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(presentation.title, systemImage: presentation.symbol).font(.headline)
                        Text(presentation.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(20).frame(idealWidth: 280, maxWidth: 340)
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
        .accessibilityIdentifier("viewer.backupStatus")
        .task(id: photo) {
            status = nil
            guard let photo else { return }
            // Follow the existing event stream only while this item is shown. No timer, library
            // discovery, checksum read or work is started by opening its status.
            for await _ in await backup.backend.snapshots() {
                guard !Task.isCancelled else { return }
                let next = await backup.photoBackupStatus(localID: photo.id, revision: photo.modified.map(AssetRevision.init))
                guard !Task.isCancelled else { return }
                status = next ?? PhotoBackupStatus(localID: photo.id, revision: photo.modified.map(AssetRevision.init), phase: .unknown)
            }
        }
    }
}

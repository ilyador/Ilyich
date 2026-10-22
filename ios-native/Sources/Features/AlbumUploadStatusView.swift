import SwiftUI

struct AlbumUploadStatusView: View {
    let albumID: String
    var onCompleted: () -> Void = { }
    @State private var backup = BackupStore.shared
    @State private var showingBackup = false
    private var pending: Int { backup.albumUploads[albumID]?.pending ?? 0 }
    private var failed: Int { backup.albumUploads[albumID]?.failed ?? 0 }
    var body: some View {
        Group {
            if pending > 0 {
                Button { showingBackup = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: failed > 0 ? "exclamationmark.icloud" : "icloud.and.arrow.up").font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(pending.formatted()) \(pending == 1 ? "photo or video" : "photos and videos") waiting for this album").font(.subheadline.weight(.medium))
                            Text(failed > 0 ? "\(failed.formatted()) need retry. Open backup details." : (backup.isRunning ? "Uploading and adding to album…" : "Backup is paused. Open details to continue."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                    }.foregroundStyle(.primary).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityElement(children: .combine)
            }
        }
        .onChange(of: pending) { old, current in if old > 0 && current == 0 { onCompleted() } }
        .onChange(of: backup.isRunning) { _, running in if !running && pending > 0 { onCompleted() } }
        .sheet(isPresented: $showingBackup, onDismiss: onCompleted) {
            NavigationStack { BackupSettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingBackup = false } } } }
        }
    }
}

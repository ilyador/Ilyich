import SwiftUI

/// An explicit maintenance action for existing backups, separate from the upload controls.
struct ArchiveOriginalMatchingView: View {
    @State private var backup = BackupStore.shared
    @State private var work: Task<Void, Never>?
    @State private var scanned = 0
    @State private var matched = 0
    @State private var scheduled = 0
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Text("Find originals already on your server and group them with their backed-up edits. Both versions are kept.")
                Text("This checks existing backups only. It does not upload photos or resume backup. Originals may need to download from iCloud using your backup settings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Backups checked", value: scanned.formatted())
                LabeledContent("Originals matched", value: matched.formatted())
                if scheduled > 0 {
                    Text("\(scheduled.formatted()) grouping requests saved. Existing groups are preserved; unsuccessful requests stay queued for retry.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.footnote).accessibilityIdentifier("backup.originalMatching.message") }
                if work != nil {
                    HStack { ProgressView(); Text("Checking originals…") }
                    Button("Stop checking") { work?.cancel() }
                } else {
                    Button("Check for matching originals") { start() }
                        .accessibilityIdentifier("backup.originalMatching.start")
                        .disabled(backup.snapshot.intent != .paused)
                        .requiresWriteAccess()
                }
            } footer: {
                if backup.snapshot.intent != .paused { Text("Pause backup before checking existing edits.") }
            }
        }
        .navigationTitle("Link archived originals")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { work?.cancel() }
    }

    private func start() {
        guard work == nil else { return }
        scanned = 0; matched = 0; scheduled = 0; message = nil
        let backend = backup.backend
        work = Task {
            defer { work = nil }
            var cursor: String?
            var deferred = 0
            do {
                repeat {
                    try Task.checkCancellation()
                    let page = try await backend.matchArchivedOriginals(after: cursor, limit: 25)
                    try Task.checkCancellation()
                    scanned += page.scanned; matched += page.matched; scheduled += page.scheduled
                    deferred += page.deferred
                    if !page.hasMore { break }
                    guard let next = page.after, next != cursor else { throw APIError.invalidResponse("Original matching could not continue.") }
                    cursor = next
                } while true
                if deferred > 0 {
                    message = "Some originals are not available yet. Their checks are saved and will retry automatically. Backup remains paused."
                } else {
                    message = matched == 0 ? "No exact original matches found in the backups checked." : "Check complete. Backup remains paused."
                }
            } catch is CancellationError {
                message = "Checking stopped. Completed matches were kept."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

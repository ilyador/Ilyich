import SwiftUI

/// A screen's exports, one at a time. MediaExportService does the work; this holds what the screen
/// shows while it runs. An export stops when its screen goes away, unless it is writing a photo to
/// Photos then: that finishes, as the viewer's save always has. A screen with longer exports
/// cancels them itself when it disappears.
@MainActor @Observable final class ExportTracker {
    /// The running export and how far it has got; nil when none runs.
    private(set) var request: ExportRequest?
    private(set) var progress: ExportProgress?
    @ObservationIgnored private let service: MediaExportService
    @ObservationIgnored private var job: ExportJob?

    init(service: MediaExportService) { self.service = service }

    /// One service per screen, until the account runtime owns one per account (C7).
    convenience init(api: APIClient) { self.init(service: MediaExportService(api: api)) }

    isolated deinit { if !isCommitting { job?.cancel() } }

    var isRunning: Bool { progress != nil }
    /// A photo is being written to Photos, which can no longer be cancelled.
    var isCommitting: Bool { progress?.committing == true }

    /// Starts an export unless one runs. `finished` hears how it ended; an export cancelled from
    /// here ends as cancelled, and its files are removed.
    func start(_ request: ExportRequest, finished: @escaping @MainActor (ExportOutcome) -> Void) {
        guard job == nil else { return }
        let id = UUID()
        self.request = request
        progress = ExportProgress(total: request.assets.count)
        let job = service.start(request, id: id) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.job?.id == id else { return }
                self.progress = snapshot
            }
        }
        self.job = job
        Task { [weak self] in
            var outcome = await job.outcome
            guard let self else { return }
            if self.job?.id == id {
                self.job = nil; self.request = nil; self.progress = nil
            } else {
                // Cancelled here: whatever it finished, nothing is shared and no error is shown.
                switch outcome {
                case .files: outcome = .cancelled(saved: 0)
                case .failed(_, let saved): outcome = .cancelled(saved: saved)
                case .saved, .cancelled: break
                }
            }
            finished(outcome)
        }
    }

    /// Stops the export at once. A photo already being written to Photos is still saved.
    func cancel() {
        job?.cancel()
        job = nil; request = nil; progress = nil
    }
}

/// The system share sheet for downloaded files.
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

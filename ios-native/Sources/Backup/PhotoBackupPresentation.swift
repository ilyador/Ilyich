import Foundation

/// Shared labels and symbols for feed badges and the opened photo. Backup proof and server presence are distinct.
struct PhotoBackupPresentation: Equatable {
    let title: String
    let symbol: String
    let detail: String
    /// Only work currently happening belongs over the photo. Saved status stays in Info.
    let isActive: Bool
    let progress: Double?

    init(status: PhotoBackupStatus?, isServerAsset: Bool) {
        switch status?.phase {
        case .uploading(let fraction), .preparing(let fraction):
            isActive = true
            progress = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        default:
            isActive = false
            progress = nil
        }
        switch status?.phase {
        case .completed:
            title = "Backed up"; symbol = "checkmark.icloud"
            detail = "The backup of this version completed. Video playback may still need time to become available."
        case .uploading:
            title = progress.map { "Uploading · \($0.formatted(.percent.precision(.fractionLength(0))))" } ?? "Uploading"
            symbol = "icloud.and.arrow.up"
            detail = "This item is being sent to your server. Any percentage is for the file currently uploading; a Live Photo can contain more than one file."
        case .preparing:
            title = progress.map { "Downloading from iCloud · \($0.formatted(.percent.precision(.fractionLength(0))))" } ?? "Preparing backup"
            symbol = "arrow.triangle.2.circlepath.icloud"
            detail = "Ilyich is preparing this item for backup. It may be reading the original from Photos or downloading it from iCloud."
        case .waiting(let message):
            title = "Waiting to back up"; symbol = "clock"
            detail = message ?? "This item is in the backup queue. It will continue when its transfer conditions are met."
        case .paused:
            title = "Backup paused"; symbol = "pause.circle"
            detail = "Backup is paused. Resume it in Device backup to continue queued items."
        case .needsAttention(let message):
            title = "Backup needs attention"; symbol = "exclamationmark.icloud"
            detail = message ?? "The last backup attempt failed. Open Device backup to review and retry it."
        case .outsideAutomaticBackup where !isServerAsset:
            title = "Outside automatic backup"; symbol = "icloud.slash"
            detail = "This item predates your New photos from now starting point. Ilyich leaves it alone; it may already be on your server."
        case .notQueued where !isServerAsset:
            title = "Backup not scheduled"; symbol = "icloud"
            detail = "This item has no current backup job. It may already exist on your server; this status does not verify past backups."
        case .unknown where !isServerAsset:
            title = "Backup status unavailable"; symbol = "questionmark.circle"
            detail = "There isn’t enough saved information to identify the backup of this version. Opening this photo does not check past backups."
        default:
            title = isServerAsset ? "On server" : "Checking backup status"
            symbol = isServerAsset ? "externaldrive" : "questionmark.circle"
            detail = isServerAsset
                ? "This item is in your server library. Playback readiness is separate from backup status."
                : "Reading the saved backup record for this item. This does not download or verify the original."
        }
    }
}

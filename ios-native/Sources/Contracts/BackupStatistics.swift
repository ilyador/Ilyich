import Foundation

/// Bytes for the current part of each active photo upload. Live Photos have more than one
/// part, so these values reset as parts and photos change; they are not cumulative run bytes.
struct TransferProgress: Hashable, Sendable {
    let activeFileCount: Int
    let sentBytes: Int64
    /// Unknown until every active upload has reported a positive expected size.
    let expectedBytes: Int64?

    var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(max(Double(sentBytes) / Double(expectedBytes), 0), 1)
    }
}

/// The eligible unique photos in the last successful check of the current selection. Only
/// confirmations of those exact revisions count; historical or outside uploads never do.
struct SelectionProgress: Hashable, Sendable {
    let total: Int
    let backedUp: Int
    /// No current server-presence/absence check has established whether these need uploading.
    let unchecked: Int
    let checkedAt: Date
    var remaining: Int { total - backedUp }
    var pending: Int { remaining - unchecked }
    var fraction: Double? { total > 0 && unchecked == 0 ? Double(backedUp) / Double(total) : nil }

    init(total: Int, backedUp: Int, unchecked: Int = 0, checkedAt: Date) {
        self.total = max(total, 0)
        self.backedUp = min(max(backedUp, 0), self.total)
        self.unchecked = min(max(unchecked, 0), self.total - self.backedUp)
        self.checkedAt = checkedAt
    }

    init(total: Int, backedUp: Int, pending: Int, checkedAt: Date) {
        let unfinished = max(total - backedUp, 0)
        self.init(total: total, backedUp: backedUp, unchecked: unfinished - min(max(pending, 0), unfinished), checkedAt: checkedAt)
    }
}

/// Shared presentation of the account's backup state. Constructed from the backend's presented
/// snapshot, whose queue remaining count includes failures. Measured selection progress is
/// separate from historical confirmations, the open queue and active uploads' current parts.
struct BackupStatistics: Equatable, Sendable {
    /// Photos this account has confirmed on this device, including earlier sessions and server
    /// duplicates. An edited photo may have an earlier confirmation and still be queued again.
    let backedUp: Int
    /// All unfinished photos, including those that need an explicit retry.
    let remaining: Int
    let failed: Int
    /// Unfinished photos that do not need an explicit retry (may be waiting or paused).
    let queued: Int
    let intent: RunIntent
    let phase: TransferPhase
    let activity: String
    let selectionChecked: Bool
    let selectionProgress: SelectionProgress?
    let checkingExistingBackups: Bool
    let preparingServerLibrary: Bool
    let currentTransfer: TransferProgress?
    let preparationFraction: Double?

    init(snapshot: TransferSnapshot) {
        backedUp = max(snapshot.confirmed, 0)
        failed = max(snapshot.failed, 0)
        remaining = max(snapshot.remaining, failed)
        queued = remaining - failed
        intent = snapshot.intent
        phase = snapshot.backupPhase ?? snapshot.phase
        activity = snapshot.activity ?? "Choose photos to back up"
        selectionChecked = snapshot.backupSelectionChecked
        selectionProgress = snapshot.selectionProgress
        checkingExistingBackups = snapshot.checkingExistingBackups
        preparingServerLibrary = snapshot.preparingServerLibrary && snapshot.intent != .paused
        currentTransfer = phase == .running ? snapshot.backupProgress : nil
        preparationFraction = phase == .running ? snapshot.backupPreparationFraction.flatMap {
            $0.isFinite ? min(max($0, 0), 1) : nil
        } : nil
    }
}

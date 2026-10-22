import Foundation
import Observation

/// What a backup receipt proves for cleanup, without the sizes the server last reported. Two are
/// equal only when the revision's bits, the server IDs and the checksums are.
struct CleanupReceipt: Hashable, Sendable {
    struct RemoteCopy: Hashable, Sendable {
        let id: String
        let checksum: String
    }

    let localID: String
    let revision: AssetRevision
    let original: RemoteCopy
    let motion: RemoteCopy?
    /// Cleanup removed the photo from the phone.
    var locallyDeleted = false

    init(localID: String, revision: AssetRevision, original: RemoteCopy, motion: RemoteCopy?, locallyDeleted: Bool = false) {
        self.localID = localID
        self.revision = revision
        self.original = original
        self.motion = motion
        self.locallyDeleted = locallyDeleted
    }

    init(localID: String, _ receipt: BackupReceipt) {
        self.init(localID: localID, revision: AssetRevision(receipt.modificationDate),
                  original: RemoteCopy(id: receipt.original.id, checksum: receipt.original.checksum),
                  motion: receipt.motion.map { RemoteCopy(id: $0.id, checksum: $0.checksum) })
    }

    /// The server assets the receipt names.
    var remoteIDs: [String] { [original.id] + (motion.map { [$0.id] } ?? []) }
}

/// Sizes the server reported for a receipt's files during a check.
struct VerifiedSize: Hashable, Sendable {
    let receipt: CleanupReceipt
    let original: Int64?
    let motion: Int64?
}

/// The receipts cleanup reads (DS12: exactly one is authoritative): the transfers database's once
/// the engine runs the account's backup, else today's backup state (CutoverReceipts).
protocol ReceiptRepository: Sendable {
    /// The account's receipts by local ID, or nil when they can't be read for that account now.
    func receipts(account: String) async -> [String: CleanupReceipt]?
    /// Keeps the sizes measured, each only where the receipt is still the one measured.
    func recordSizes(_ sizes: [String: VerifiedSize], account: String) async
    /// The photos cleanup removed. Only after Photos committed the removal.
    func markLocallyDeleted(_ localIDs: [String], account: String) async
    /// Tells of every change to the receipts from now on, merged while unread.
    func changes() async -> AsyncStream<Void>
}

/// The temporary receipts adapter over today's backup state, for the way back (P4 -> B10).
/// BackupCoordinator keeps the receipts on the main actor; this reads them there and hands back a
/// value copy, which is cheap.
///
/// The backup state has no field for a local deletion, and B1's shadow database is rebuilt from
/// it, so until B9 a cleanup removal is recorded only in the device_mutation journal (origin
/// cleanup, with the account and the expected revisions), which B9's importer reads into
/// receipts.local_deleted_at. A photo removed from the phone is no longer found there, so a later
/// check never offers it again.
struct LegacyStateReceipts: ReceiptRepository {
    private let coordinator: @MainActor @Sendable () -> BackupCoordinator

    init(coordinator: @escaping @MainActor @Sendable () -> BackupCoordinator = { .shared }) {
        self.coordinator = coordinator
    }

    func receipts(account: String) async -> [String: CleanupReceipt]? {
        let coordinator = coordinator
        var legacy = await MainActor.run { coordinator().cleanupReceipts(scope: account) }
        if legacy == nil {
            // Not taken up yet, as the old check did first: AccountManager normally has.
            legacy = await MainActor.run { coordinator() }.activateForCleanup(scope: account)
        }
        guard let legacy else { return nil }
        // Converted off the main actor.
        var result: [String: CleanupReceipt] = [:]
        result.reserveCapacity(legacy.count)
        for (localID, receipt) in legacy { result[localID] = CleanupReceipt(localID: localID, receipt) }
        return result
    }

    func recordSizes(_ sizes: [String: VerifiedSize], account: String) async {
        guard !sizes.isEmpty else { return }
        let coordinator = coordinator
        await MainActor.run { coordinator().recordVerifiedSizes(sizes, scope: account) }
    }

    func markLocallyDeleted(_ localIDs: [String], account: String) async {
        // Kept in the device_mutation journal until B9; see the type's comment.
    }

    func changes() async -> AsyncStream<Void> {
        let coordinator = coordinator
        return await MainActor.run { ReceiptWatch.stream(coordinator()) }
    }
}

/// Follows the backup state through Observation, so nothing polls. Every change to it is
/// reported; a reader compares the receipts it cares about.
@MainActor private final class ReceiptWatch {
    private let coordinator: BackupCoordinator
    private let continuation: AsyncStream<Void>.Continuation
    private var stopped = false

    private init(coordinator: BackupCoordinator, continuation: AsyncStream<Void>.Continuation) {
        self.coordinator = coordinator
        self.continuation = continuation
    }

    static func stream(_ coordinator: BackupCoordinator) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let watch = ReceiptWatch(coordinator: coordinator, continuation: continuation)
        continuation.onTermination = { _ in Task { @MainActor in watch.stopped = true } }
        watch.arm()
        return stream
    }

    private func arm() {
        guard !stopped else { return }
        withObservationTracking {
            _ = coordinator.associations
            _ = coordinator.activeScope
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.continuation.yield()
                self.arm()
            }
        }
    }
}

import Foundation

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

    /// The server assets the receipt names.
    var remoteIDs: [String] { [original.id] + (motion.map { [$0.id] } ?? []) }
}

/// Sizes the server reported for a receipt's files during a check.
struct VerifiedSize: Hashable, Sendable {
    let receipt: CleanupReceipt
    let original: Int64?
    let motion: Int64?
}

/// The receipts cleanup reads (DS12: exactly one is authoritative): the transfers database's, once
/// the engine runs the account's backup (CutoverReceipts).
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

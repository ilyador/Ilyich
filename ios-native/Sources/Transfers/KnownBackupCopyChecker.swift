import Foundation
import IlyichPlatform

enum KnownBackupCopyResult: Sendable {
    case backedUp(JobResult)
    case absent(AssetRevision)
    case unknown
}

protocol KnownBackupCopyChecking: Sendable {
    func check(_ localID: String, context: JobContext) async throws -> KnownBackupCopyResult
}

struct BackupIdentityIndexNotReady: LocalizedError, Sendable {
    var errorDescription: String? { "Waiting for the server library to finish syncing." }
}

/// Checks reusable account-scoped identity before staging can download an iCloud original.
/// This deliberately handles only unadjusted single originals. A cloud identity can confirm
/// presence, but never creates a checksum receipt that would authorize device cleanup.
struct KnownBackupCopyChecker: KnownBackupCopyChecking {
    let account: AccountID
    let reader: any DeviceIndexReading
    let database: DeviceDatabase
    let identities: any DeviceIndexServer
    let server: any TransferServerAPI
    private let catalog = KnownBackupIdentityCatalog()

    init(account: AccountID, reader: any DeviceIndexReading, database: DeviceDatabase,
         identities: any DeviceIndexServer, server: any TransferServerAPI) {
        self.account = account
        self.reader = reader
        self.database = database
        self.identities = identities
        self.server = server
    }

    func check(_ localID: String, context: JobContext) async throws -> KnownBackupCopyResult {
        try await context.ensureOwned()
        let access = await reader.access()
        try await context.ensureOwned()
        guard access.status == .authorized || access.status == .limited,
              let item = try await reader.items([localID]).first else { return .unknown }
        try await context.ensureOwned()
        guard item.unadjusted, item.shape == .singleOriginal, let modified = item.photo.modified else { return .unknown }
        let revision = AssetRevision(modified)
        let fingerprint = try await database.fingerprint(for: localID)
        try await context.ensureOwned()
        let checksum = fingerprint.flatMap { $0.isCurrent(for: modified) ? $0.checksum : nil }
        if let checksum {
            let answers = try await server.bulkUploadCheck([UploadCheck.Item(id: localID, checksum: checksum)])
            try await context.ensureOwned()
            if let answer = answers.first(where: { $0.id == localID }) {
                if answer.action == "accept" {
                    guard await unchanged(item, access: access) else { return .unknown }
                    try await context.ensureOwned()
                    return .absent(revision)
                }
                if answer.action == "reject", answer.reason == "duplicate", answer.isTrashed != true, let id = answer.assetId {
                    let remote = try await server.remoteAsset(id: id)
                    try await context.ensureOwned()
                    guard remote.id == id, eligible(remote), remote.checksum == checksum, await unchanged(item, access: access) else { return .unknown }
                    try await context.ensureOwned()
                    let receipt = TransferReceipt(localID: localID, revision: revision, original: .init(id: id, checksum: checksum),
                                                  motion: nil, confirmedAt: nil)
                    return .backedUp(.backedUp(revision: revision, assetID: id, receipt: receipt))
                }
            }
            return .unknown
        }
        guard let cloudID = item.cloudID else { return .unknown }
        let rows = try await catalog.candidates(cloudID: cloudID, source: identities)
        try await context.ensureOwned()
        let matches = Dictionary(rows.filter { $0.cloudID == cloudID && LocalIdentityMatch.matches(item.photo, remote: $0) }
            .map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first })
        guard matches.count == 1, let match = matches.values.first else { return .unknown }
        let remote = try await server.remoteAsset(id: match.assetID)
        try await context.ensureOwned()
        guard remote.id == match.assetID, eligible(remote), remote.checksum == match.checksum, await unchanged(item, access: access) else { return .unknown }
        try await context.ensureOwned()
        return .backedUp(.backedUp(revision: revision, assetID: remote.id, receipt: nil))
    }

    private func eligible(_ remote: BackupRemoteAsset) -> Bool {
        remote.ownerId == account.userID && !remote.isTrashed && remote.visibility != "locked" && remote.isOffline != true
    }

    private func unchanged(_ item: DeviceTimelineItem, access: DeviceAccess) async -> Bool {
        let current = try? await reader.items([item.photo.id]).first
        let after = await reader.access()
        return access == after && current == item
    }
}

/// One metadata snapshot per runtime/minute, not a JSON table scan for every selected photo.
/// Current server reads still validate a candidate before it can confirm anything.
private actor KnownBackupIdentityCatalog {
    private var loadedAt: Date?
    private var byCloud: [String: [LocalAssetMatch]] = [:]

    func candidates(cloudID: String, source: any DeviceIndexServer) async throws -> [LocalAssetMatch] {
        guard try await source.identityIndexComplete() else { throw BackupIdentityIndexNotReady() }
        if loadedAt == nil || Date().timeIntervalSince(loadedAt!) > 60 {
            guard let rows = try await source.identities() else { throw BackupIdentityIndexNotReady() }
            byCloud = Dictionary(grouping: rows.filter { $0.cloudID != nil }, by: { $0.cloudID! })
            loadedAt = Date()
        }
        return byCloud[cloudID] ?? []
    }
}

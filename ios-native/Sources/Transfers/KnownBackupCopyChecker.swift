import Foundation
import IlyichPlatform

enum KnownBackupCopyResult: Sendable {
    case backedUp(JobResult)
    case absent(AssetRevision)
    case unknown
}

protocol KnownBackupCopyChecking: Sendable {
    func check(_ localID: String, context: JobContext) async throws -> KnownBackupCopyResult
    func reconcileConfirmations(in store: TransferStore) async throws
}

extension KnownBackupCopyChecking {
    func reconcileConfirmations(in store: TransferStore) async throws {}
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
    private let allowsReconciliation: @Sendable () -> Bool

    init(account: AccountID, reader: any DeviceIndexReading, database: DeviceDatabase,
         identities: any DeviceIndexServer, server: any TransferServerAPI,
         allowsReconciliation: @escaping @Sendable () -> Bool = { true }) {
        self.account = account
        self.reader = reader
        self.database = database
        self.identities = identities
        self.server = server
        self.allowsReconciliation = allowsReconciliation
    }

    func reconcileConfirmations(in store: TransferStore) async throws {
        try Task.checkCancellation()
        guard allowsReconciliation() else { return }
        let checkedIDs = try await store.confirmationRemoteIDs()
        guard try await identities.identityIndexComplete(), var rows = try await identities.identities(ids: checkedIDs) else { return }
        let indexed = Set(rows.map(\.assetID))
        // The local sync may not yet contain an upload that just completed. Absence in that
        // catalog cannot erase its receipt; only an exact server read can establish it is gone.
        let missing = checkedIDs.subtracting(indexed)
        for id in missing.sorted() {
            do {
                let remote = try await server.remoteAsset(id: id)
                rows.append(LocalAssetMatch(assetID: id, checksum: remote.checksum, cloudID: nil, createdAt: nil, adjustmentTime: nil,
                                            latitude: nil, longitude: nil, visible: remote.visibility == "timeline",
                                            checksumAlgorithm: remote.checksumAlgorithm, contentChecksum: remote.contentChecksum,
                                            isExternal: remote.isExternal, backupAvailable: remote.id == id && eligible(remote)))
            } catch ServerFailure.notFound {
                // An authorized exact read confirmed the deletion.
            }
            // Any transport/auth failure aborts before the store changes a single confirmation.
        }
        try Task.checkCancellation()
        guard allowsReconciliation() else { return }
        _ = try await store.reconcileConfirmations(with: rows, checkedRemoteIDs: checkedIDs)
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
                    guard remote.id == id, eligible(remote), remote.fileChecksum == checksum, await unchanged(item, access: access) else { return .unknown }
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

/// Read-only account work, independent of backup run intent. One subscription coalesces
/// catalog changes; it never discovers Photos, stages files, or runs an upload executor.
actor BackupConfirmationObserver {
    private let checker: any KnownBackupCopyChecking
    private let store: TransferStore
    private let refreshed: @Sendable () async -> Void
    private let permits: @Sendable () -> Bool
    private var watcher: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var pending = false
    private var stopped = false

    init(checker: any KnownBackupCopyChecking, store: TransferStore,
         permits: @escaping @Sendable () -> Bool = { true }, refreshed: @escaping @Sendable () async -> Void) {
        self.checker = checker
        self.store = store
        self.permits = permits
        self.refreshed = refreshed
    }

    func start(changes: AsyncStream<LibraryChange>) {
        guard watcher == nil, !stopped else { return }
        request()
        watcher = Task { [weak self] in
            for await change in changes {
                guard !Task.isCancelled else { return }
                await self?.receive(change)
            }
        }
    }

    private func receive(_ change: LibraryChange) async {
        guard !stopped else { return }
        if change.routingChanged || change.reset || change.overflow || (change.syncedThrough != nil && change.isEmpty) {
            request()
            return
        }
        guard let watched = try? await store.confirmationRemoteIDs() else { return }
        if !watched.isDisjoint(with: change.upserted.keys) || !watched.isDisjoint(with: change.removed)
            || !watched.isDisjoint(with: change.accessLost) || !watched.isDisjoint(with: change.mediaRevisions.keys) { request() }
    }

    /// Coming forward retries a read that failed offline; condition events never resume backup.
    func request() {
        guard !stopped else { return }
        pending = true
        guard work == nil else { return }
        work = Task { await self.serve() }
    }

    private func serve() async {
        while pending, !stopped, !Task.isCancelled {
            pending = false
            do {
                // Fold bursts of sync batches into one account-level catalog read.
                try await Task.sleep(for: .milliseconds(200))
                pending = false
                guard permits(), !stopped else { break }
                try await checker.reconcileConfirmations(in: store)
                guard permits(), !stopped, !Task.isCancelled else { break }
                await refreshed()
            } catch {
                // Preserve history when the server cannot be checked. The UI calls these
                // previous verifications; a later sync/foreground event tries again.
            }
        }
        work = nil
    }

    func stop() async {
        stopped = true
        pending = false
        watcher?.cancel()
        work?.cancel()
        await watcher?.value
        await work?.value
        watcher = nil
        work = nil
    }
}

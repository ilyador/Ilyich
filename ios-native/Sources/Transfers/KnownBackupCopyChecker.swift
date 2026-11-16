import Foundation
import IlyichPlatform
import Synchronization

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
        guard try await store.pastBackupVerificationAllowed() else { return }
        let checkedIDs = try await store.confirmationRemoteIDs()
        guard try await identities.identityIndexComplete(), var rows = try await identities.identities(ids: checkedIDs) else { return }
        let indexed = Set(rows.map(\.assetID))
        // The local sync may not yet contain an upload that just completed. Absence in that
        // catalog cannot erase its receipt; only an exact server read can establish it is gone.
        let missing = checkedIDs.subtracting(indexed)
        for id in missing.sorted() {
            guard try await store.pastBackupVerificationAllowed() else { return }
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
        guard try await store.pastBackupVerificationAllowed() else { return }
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
    private typealias LoadResult = (rows: [LocalAssetMatch], loadedAt: Date)
    private var loadedAt: Date?
    private var byCloud: [String: [LocalAssetMatch]] = [:]
    private var loading: (id: UUID, task: Task<LoadResult, any Error>)?

    func candidates(cloudID: String, source: any DeviceIndexServer) async throws -> [LocalAssetMatch] {
        guard try await source.identityIndexComplete() else { throw BackupIdentityIndexNotReady() }
        try Task.checkCancellation()
        if loadedAt == nil || Date().timeIntervalSince(loadedAt!) > 60 {
            let load: (id: UUID, task: Task<LoadResult, any Error>)
            if let loading { load = loading }
            else {
                load = (UUID(), Task {
                    try Task.checkCancellation()
                    guard let rows = try await source.identities() else { throw BackupIdentityIndexNotReady() }
                    try Task.checkCancellation()
                    return (rows, Date())
                })
                loading = load
            }
            let result: LoadResult
            do { result = try await KnownBackupCatalogWaiter<LoadResult>().value(of: load.task) }
            catch {
                if !Task.isCancelled, loading?.id == load.id { loading = nil }
                throw error
            }
            // One cancelled waiter cannot cancel a catalog still needed by another job.
            // A later active waiter publishes it, only within the same short cache interval.
            try Task.checkCancellation()
            if Date().timeIntervalSince(result.loadedAt) > 60 {
                if loading?.id == load.id { loading = nil }
                return try await candidates(cloudID: cloudID, source: source)
            }
            if loading?.id == load.id {
                byCloud = Dictionary(grouping: result.rows.filter { $0.cloudID != nil }, by: { $0.cloudID! })
                loadedAt = result.loadedAt
                loading = nil
            }
        }
        return byCloud[cloudID] ?? []
    }
}

/// Lets an individual job stop waiting promptly without cancelling a shared metadata read.
/// Exactly one of completion or cancellation resumes the continuation.
private final class KnownBackupCatalogWaiter<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var result: Result<Value, any Error>?
    }
    private let state = Mutex(State())

    func value(of task: Task<Value, any Error>) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<Value, any Error>? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
                else { Task { self.finish(await task.result) } }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<Value, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
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
    private var policySuspended = false

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
        guard !stopped, !policySuspended else { return }
        guard (try? await store.pastBackupVerificationAllowed()) == true else { return }
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
        guard !policySuspended, work == nil else { return }
        work = Task { await self.serve() }
    }

    private func serve() async {
        while pending, !stopped, !policySuspended, !Task.isCancelled {
            pending = false
            do {
                // Fold bursts of sync batches into one account-level catalog read.
                try await Task.sleep(for: .milliseconds(200))
                pending = false
                guard permits(), !stopped, !policySuspended else { break }
                guard try await store.pastBackupVerificationAllowed() else { break }
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

    func suspendForNewPhotosPolicyChange() async {
        policySuspended = true
        work?.cancel()
        await work?.value
    }

    func resumeAfterNewPhotosPolicyChange() {
        guard !stopped else { return }
        policySuspended = false
        request()
    }
}

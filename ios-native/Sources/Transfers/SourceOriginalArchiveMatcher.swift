import Foundation
import IlyichPlatform

enum SourceOriginalMatchResult: Hashable, Sendable {
    case matched(SourceOriginalAssociation)
    case notApplicable(SourceOriginalReason)
    case deferred(SourceOriginalReason)
}

/// Source matches are candidates for association, never proof of the current rendition.
struct SourceOriginalArchiveMatcher: Sendable {
    let account: AccountID
    let store: TransferStore
    let staging: any PhotoLibraryStaging
    let server: any TransferServerAPI

    func match(_ localID: String, revision: AssetRevision, policy: StagingPolicy,
               ensureOwned: @Sendable () async throws -> Void = { try Task.checkCancellation() }) async throws -> SourceOriginalAssociation? {
        if case .matched(let source) = try await attempt(localID, revision: revision, policy: policy, ensureOwned: ensureOwned) { return source }
        return nil
    }

    func attempt(_ localID: String, revision: AssetRevision, policy: StagingPolicy,
                 ensureOwned: @Sendable () async throws -> Void = { try Task.checkCancellation() }) async throws -> SourceOriginalMatchResult {
        try await ensureOwned()
        let old = try await store.sourceOriginal(for: localID, revision: revision)
        try await ensureOwned()
        var fingerprint: SourceOriginalFingerprint?
        if let cached = old?.fingerprint, cached.revision == revision, cached.checksum == old?.checksum {
            let validation = try await validateSource(localID, fingerprint: cached, policy: policy)
            try await ensureOwned()
            switch validation {
            case .current: fingerprint = cached
            case .deferred(let reason): return .deferred(reason)
            case .stale(.revisionSuperseded):
                try await store.forgetSourceOriginal(localID, revision: revision)
                return .notApplicable(.revisionSuperseded)
            case .stale: break // Missing/obsolete cache metadata needs a new guarded source read.
            }
        }
        if fingerprint == nil {
            let read = try await readSource(localID, revision: revision, policy: policy)
            try await ensureOwned()
            switch read {
            case .fingerprint(let computed): fingerprint = computed
            case .deferred(let reason): return .deferred(reason) // Keep any cached candidate.
            case .notApplicable(let reason):
                try await store.forgetSourceOriginal(localID, revision: revision)
                return .notApplicable(reason)
            }
        }
        guard let fingerprint, fingerprint.revision == revision, !fingerprint.checksum.isEmpty else { return .deferred(.sourceUnavailable) }
        try await store.saveSourceOriginal(.init(localID: localID, revision: revision, checksum: fingerprint.checksum,
                                                 remoteID: old?.checksum == fingerprint.checksum ? old?.remoteID : nil, fingerprint: fingerprint))
        try await ensureOwned()
        var remoteID: String?
        if old?.checksum == fingerprint.checksum, let id = old?.remoteID,
           try await verifiedRemote(id, checksum: fingerprint.checksum, ensureOwned: ensureOwned) { remoteID = id }
        if remoteID == nil {
            let answers = try await server.bulkUploadCheck([.init(id: localID, checksum: fingerprint.checksum)])
            try await ensureOwned()
            let exact = answers.filter { $0.id == localID }
            if exact.count == 1, let answer = exact.first, answer.action == "reject", answer.reason == "duplicate",
               answer.isTrashed != true, let id = answer.assetId,
               try await verifiedRemote(id, checksum: fingerprint.checksum, ensureOwned: ensureOwned) { remoteID = id }
        }
        let validation = try await validateSource(localID, fingerprint: fingerprint, policy: policy)
        try await ensureOwned()
        switch validation {
        case .deferred(let reason): return .deferred(reason)
        case .stale(let reason):
            try await store.forgetSourceOriginal(localID, revision: revision)
            return reason == .revisionSuperseded ? .notApplicable(reason) : .deferred(reason)
        case .current: break
        }
        let source = SourceOriginalAssociation(localID: localID, revision: revision, checksum: fingerprint.checksum,
                                               remoteID: remoteID, fingerprint: fingerprint)
        try await store.saveSourceOriginal(source)
        try await ensureOwned()
        return remoteID == nil ? .deferred(.archiveNotFound) : .matched(source)
    }

    private func readSource(_ localID: String, revision: AssetRevision, policy: StagingPolicy) async throws -> SourceOriginalReadResult {
        do { return try await staging.probeSourceOriginal(localID, revision: revision, policy: policy) }
        catch {
            guard let reason = SourceOriginalReason.deferredSourceRead(error) else { throw error }
            return .deferred(reason)
        }
    }

    func validateSource(_ localID: String, fingerprint: SourceOriginalFingerprint, policy: StagingPolicy) async throws -> SourceOriginalValidation {
        do { return try await staging.validateSourceOriginal(localID, fingerprint: fingerprint, policy: policy) }
        catch {
            guard let reason = SourceOriginalReason.deferredSourceRead(error) else { throw error }
            return .deferred(reason)
        }
    }

    func sourceIsCurrent(_ localID: String, fingerprint: SourceOriginalFingerprint, policy: StagingPolicy) async throws -> Bool {
        try await validateSource(localID, fingerprint: fingerprint, policy: policy) == .current
    }

    private func verifiedRemote(_ id: String, checksum: String,
                                ensureOwned: @Sendable () async throws -> Void) async throws -> Bool {
        do {
            let remote = try await server.remoteAsset(id: id)
            try await ensureOwned()
            return eligible(remote, id: id, checksum: checksum)
        } catch ServerFailure.notFound {
            try await ensureOwned()
            return false
        }
    }

    func eligible(_ remote: BackupRemoteAsset, id: String, checksum: String) -> Bool {
        remote.id == id && remote.ownerId == account.userID && !remote.isTrashed
            && remote.visibility != "locked" && remote.isOffline != true && remote.fileChecksum == checksum
    }
}

struct SourceOriginalReconciliationReport: Hashable, Sendable {
    let scanned: Int
    let matched: Int
    let scheduled: Int
    let after: String?
    let hasMore: Bool
    var deferred = 0
}

/// Explicit, bounded linking for edits already backed up. It never invokes discovery, an
/// upload executor, changes run intent, or writes a confirmation/cleanup receipt.
struct SourceOriginalArchiveReconciler: Sendable {
    let account: AccountID
    let store: TransferStore
    let staging: any PhotoLibraryStaging
    let server: any TransferServerAPI
    let permits: @Sendable () -> Bool

    init(account: AccountID, store: TransferStore, staging: any PhotoLibraryStaging, server: any TransferServerAPI,
         permits: @escaping @Sendable () -> Bool = { true }) {
        self.account = account
        self.store = store
        self.staging = staging
        self.server = server
        self.permits = permits
    }

    func reconcile(after localID: String? = nil, limit: Int = 25, policy: StagingPolicy) async throws -> SourceOriginalReconciliationReport {
        try ensurePermitted()
        guard try await store.pastBackupVerificationAllowed() else {
            throw BackupError.message("Past backup checks are off while backing up new photos only.")
        }
        let size = min(max(limit, 1), 100)
        let receipts = try await store.confirmedReceiptsForSourceMatching(after: localID, limit: size)
        try ensurePermitted()
        let matcher = SourceOriginalArchiveMatcher(account: account, store: store, staging: staging, server: server)
        var matched = 0
        var scheduled = 0
        var deferred = 0
        for receipt in receipts {
            try ensurePermitted()
            try await store.requestSourceMatch(receipt, permits: permits)
            let attempted = try await matcher.attempt(receipt.localID, revision: receipt.revision, policy: policy,
                                                     ensureOwned: { try ensurePermitted() })
            let source: SourceOriginalAssociation
            switch attempted {
            case .matched(let value): source = value
            case .deferred: deferred += 1; continue
            case .notApplicable: continue
            }
            // An original match cannot stand in for proof of the confirmed current rendition.
            let current = try await server.remoteAsset(id: receipt.original.id)
            try ensurePermitted()
            guard matcher.eligible(current, id: receipt.original.id, checksum: receipt.original.checksum) else { continue }
            if let motion = receipt.motion {
                let remoteMotion = try await server.remoteAsset(id: motion.id)
                try ensurePermitted()
                guard matcher.eligible(remoteMotion, id: motion.id, checksum: motion.checksum), current.livePhotoVideoId == motion.id else { continue }
            }
            guard let fingerprint = source.fingerprint,
                  try await matcher.sourceIsCurrent(receipt.localID, fingerprint: fingerprint, policy: policy) else {
                try ensurePermitted()
                deferred += 1
                continue
            }
            try ensurePermitted()
            matched += 1
            if try await store.enqueueSourceOriginalStack(ifCurrent: receipt, expectedSource: source, permits: permits, retryFailed: true) { scheduled += 1 }
            try ensurePermitted()
        }
        return .init(scanned: receipts.count, matched: matched, scheduled: scheduled, after: receipts.last?.localID ?? localID,
                     hasMore: receipts.count == size, deferred: deferred)
    }

    private func ensurePermitted() throws {
        try Task.checkCancellation()
        guard permits() else { throw CancellationError() }
    }
}

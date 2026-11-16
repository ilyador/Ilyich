import Foundation
import IlyichPlatform
import Photos

/// Finds archive bytes for an edited photo's untouched source. The current rendition still
/// follows the normal upload/duplicate and receipt path, independent of this association.
struct SourceOriginalArchiveMatcher: Sendable {
    let account: AccountID
    let store: TransferStore
    let staging: any PhotoLibraryStaging
    let server: any TransferServerAPI

    func match(_ localID: String, revision: AssetRevision, policy: StagingPolicy,
               ensureOwned: @Sendable () async throws -> Void = { try Task.checkCancellation() }) async throws -> SourceOriginalAssociation? {
        try await ensureOwned()
        let old = try await store.sourceOriginal(for: localID, revision: revision)
        try await ensureOwned()
        let fingerprint: SourceOriginalFingerprint
        if let cached = old?.fingerprint, cached.revision == revision, cached.checksum == old?.checksum,
           try await sourceIsCurrent(localID, fingerprint: cached, policy: policy) {
            fingerprint = cached
        } else if let computed = try await readSource(localID, revision: revision, policy: policy),
                  computed.revision == revision, !computed.checksum.isEmpty {
            fingerprint = computed
        } else {
            try await ensureOwned()
            try await store.forgetSourceOriginal(localID, revision: revision)
            return nil
        }
        try await ensureOwned()
        // Persist the source checksum before a lookup/upload. It has no backup semantics.
        try await store.saveSourceOriginal(.init(localID: localID, revision: revision, checksum: fingerprint.checksum,
                                                 remoteID: old?.checksum == fingerprint.checksum ? old?.remoteID : nil,
                                                 fingerprint: fingerprint))
        try await ensureOwned()
        var remoteID: String?
        // A stored association is a candidate, freshly checked against server file bytes.
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
        guard try await sourceIsCurrent(localID, fingerprint: fingerprint, policy: policy) else {
            try await ensureOwned()
            try await store.forgetSourceOriginal(localID, revision: revision)
            return nil
        }
        try await ensureOwned()
        let result = SourceOriginalAssociation(localID: localID, revision: revision, checksum: fingerprint.checksum, remoteID: remoteID, fingerprint: fingerprint)
        try await store.saveSourceOriginal(result)
        try await ensureOwned()
        return remoteID == nil ? nil : result
    }

    private func readSource(_ localID: String, revision: AssetRevision, policy: StagingPolicy) async throws -> SourceOriginalFingerprint? {
        do { return try await staging.sourceOriginal(localID, revision: revision, policy: policy) }
        catch where Self.sourceReadUnavailable(error) { return nil }
    }

    func sourceIsCurrent(_ localID: String, fingerprint: SourceOriginalFingerprint, policy: StagingPolicy) async throws -> Bool {
        do { return try await staging.sourceOriginalIsCurrent(localID, fingerprint: fingerprint, policy: policy) }
        catch where Self.sourceReadUnavailable(error) { return false }
    }

    /// Only optional PhotoKit source reads use this classification. Server lookup/proof,
    /// account restrictions, lease loss and cancellation always retain their normal failures.
    private static func sourceReadUnavailable(_ error: any Error) -> Bool {
        if case BackupDeferral.waitingForWiFi = error { return true }
        let details = error as NSError
        if details.domain == PHPhotosErrorDomain {
            guard let code = PHPhotosError.Code(rawValue: details.code) else { return false }
            return [.identifierNotFound, .invalidResource, .missingResource, .requestNotSupportedForAsset,
                    .networkAccessRequired, .networkError].contains(code)
        }
        if details.domain == NSCocoaErrorDomain {
            return [.fileNoSuchFile, .fileReadNoSuchFile, .fileReadCorruptFile].contains(CocoaError.Code(rawValue: details.code))
        }
        if details.domain == NSURLErrorDomain {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
                    .notConnectedToInternet, .resourceUnavailable, .dataNotAllowed, .fileDoesNotExist]
                .contains(URLError.Code(rawValue: details.code))
        }
        return false
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
        let size = min(max(limit, 1), 100)
        let receipts = try await store.confirmedReceiptsForSourceMatching(after: localID, limit: size)
        try ensurePermitted()
        let matcher = SourceOriginalArchiveMatcher(account: account, store: store, staging: staging, server: server)
        var matched = 0
        var scheduled = 0
        for receipt in receipts {
            try ensurePermitted()
            guard let source = try await matcher.match(receipt.localID, revision: receipt.revision, policy: policy,
                                                       ensureOwned: { try ensurePermitted() }) else { continue }
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
                try await store.forgetSourceOriginal(receipt.localID, revision: receipt.revision)
                continue
            }
            try ensurePermitted()
            matched += 1
            if try await store.enqueueSourceOriginalStack(ifCurrent: receipt, permits: permits, retryFailed: true) { scheduled += 1 }
            try ensurePermitted()
        }
        return .init(scanned: receipts.count, matched: matched, scheduled: scheduled, after: receipts.last?.localID ?? localID,
                     hasMore: receipts.count == size)
    }

    private func ensurePermitted() throws {
        try Task.checkCancellation()
        guard permits() else { throw CancellationError() }
    }
}

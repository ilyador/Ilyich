import Foundation
import IlyichPlatform

/// The session ended while cleanup checked with the server (DS4: a 401 aborts the check).
struct CleanupAborted: LocalizedError, Equatable {
    var errorDescription: String? { "Your server ended this session. Sign in again, then check again. Nothing was removed." }
}

/// Checks with the server, strictly, that a receipt's copies are there (DS4): a fresh GET each,
/// never the offline library. The copy must have the same ID, belong to the user, have the
/// receipt's checksum, be neither in the trash nor in the Locked Folder, and not be offline. A
/// Live Photo's still must name the receipt's video, which must pass the same checks. Any other
/// answer excludes only this photo; a 401 aborts the whole check.
struct RemoteCopyVerifier: Sendable {
    enum Verdict: Equatable, Sendable {
        case verified(VerifiedSize)
        case excluded(CleanupExclusion)
    }

    let ownerID: String
    /// GET assets/<id>, strict (TransferServerAPI.remoteAsset).
    let fetch: @Sendable (String) async throws -> BackupRemoteAsset

    func verify(_ receipt: CleanupReceipt) async throws -> Verdict {
        let original: BackupRemoteAsset
        do { original = try await fetch(receipt.original.id) } catch { return .excluded(try Self.exclusion(after: error)) }
        if let exclusion = check(original, against: receipt.original) { return .excluded(exclusion) }
        guard let motion = receipt.motion else {
            return .verified(VerifiedSize(receipt: receipt, original: original.knownByteCount, motion: nil))
        }
        guard original.livePhotoVideoId == motion.id else { return .excluded(.livePairMismatch) }
        let video: BackupRemoteAsset
        do { video = try await fetch(motion.id) } catch { return .excluded(try Self.exclusion(after: error)) }
        if let exclusion = check(video, against: motion) { return .excluded(exclusion == .checksumMismatch ? .livePairMismatch : exclusion) }
        return .verified(VerifiedSize(receipt: receipt, original: original.knownByteCount, motion: video.knownByteCount))
    }

    private func check(_ asset: BackupRemoteAsset, against copy: CleanupReceipt.RemoteCopy) -> CleanupExclusion? {
        guard asset.id == copy.id else { return .notOnServer }
        guard asset.ownerId == ownerID else { return .otherOwner }
        guard asset.checksum == copy.checksum else { return .checksumMismatch }
        guard !asset.isTrashed else { return .inServerTrash }
        guard asset.visibility != "locked" else { return .inLockedFolder }
        guard asset.isOffline != true else { return .serverCopyOffline }
        return nil
    }

    /// The exclusion a failed GET makes, or the abort a 401 makes. Cancelling cancels.
    static func exclusion(after error: any Error) throws -> CleanupExclusion {
        if error is CancellationError { throw error }
        if let failure = error as? ServerFailure {
            switch failure {
            case .sessionExpired, .proxyRejected(401): throw CleanupAborted()
            case .notFound: return .notOnServer
            case .forbidden, .proxyRejected: return .serverRefused
            case .undecodable: return .unreadableAnswer
            case .http, .credentialsRejected, .readOnly, .passwordChangeRequired: return .serverError
            }
        }
        if let error = error as? URLError, error.code == .cancelled, Task.isCancelled { throw CancellationError() }
        if error is DecodingError { return .unreadableAnswer }
        return .unreachable
    }
}

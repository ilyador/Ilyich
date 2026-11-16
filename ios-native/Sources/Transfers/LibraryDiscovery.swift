import Foundation
import Photos

/// Finds the photos to back up (B3): every readable photo and video in the chosen scope,
/// minus excluded albums, read from Photos a batch at a time through P2's
/// PhotoLibraryStaging, then merged in one transaction at commit time (TransferStore
/// mergeDiscovery). A photo gets a job unless a confirmation has its date or a job has it already,
/// judged as the tables are at the merge, so a photo confirmed while discovery read Photos is not
/// queued again.
///
/// A job whose photo has left Photos is dropped (the owner's decision). Only full access can tell
/// a photo is gone, as limited access hides every photo outside the selection, so with limited
/// access nothing is dropped.
struct LibraryDiscovery: Sendable {
    let store: TransferStore
    let staging: any PhotoLibraryStaging
    /// The photos queued count in a backup notification batch, as the app's discovery does.
    var notifying = false
    /// Process-local access, rechecked after Photos/database awaits. No entitlement is persisted.
    var allowsDiscovery: @Sendable () -> Bool = { true }

    var revalidateConfirmations: @Sendable () async throws -> Void = {}

    func run() async throws -> DiscoveryMerge {
        guard allowsDiscovery() else { throw PurchaseAccessRequired() }
        guard let preferences = try await store.preferences(), preferences.hasSelection else { return DiscoveryMerge() }
        guard allowsDiscovery() else { throw PurchaseAccessRequired() }
        let access = staging.authorization
        guard access == .authorized || access == .limited else { throw PHPhotosError(.accessUserDenied) }
        guard try await store.newPhotosPolicyChanging() == false else { throw NewPhotosBackupError.changingPolicy }
        if preferences.newPhotosOnly {
            guard access == .authorized else { throw PHPhotosError(.accessUserDenied) }
            guard try await store.newPhotosBaselineStartedAt() != nil else { throw NewPhotosBackupError.missingBaseline }
        }
        var found: [DeviceCandidate] = []
        for try await batch in staging.candidates(scope: preferences.scope, included: preferences.includedAlbums, excluded: preferences.excludedAlbums) {
            guard allowsDiscovery() else { throw PurchaseAccessRequired() }
            guard try await store.newPhotosPolicyChanging() == false, try await store.preferences() == preferences,
                  !preferences.newPhotosOnly || staging.authorization == .authorized else { throw CancellationError() }
            if preferences.newPhotosOnly { found += try await store.filterNewPhotosCandidates(batch) }
            else { found += batch }
        }
        try Task.checkCancellation()
        guard allowsDiscovery() else { throw PurchaseAccessRequired() }
        var gone: [String] = []
        if access == .authorized {
            let unseen = Set(try await store.libraryJobKeys()).subtracting(found.map(\.id))
            if !unseen.isEmpty {
                let present = try await staging.existing(Array(unseen))
                gone = unseen.subtracting(present).sorted()
            }
        }
        try Task.checkCancellation()
        guard allowsDiscovery() else { throw PurchaseAccessRequired() }
        guard try await store.newPhotosPolicyChanging() == false, try await store.preferences() == preferences else { throw CancellationError() }
        if !preferences.newPhotosOnly { try await revalidateConfirmations() }
        guard allowsDiscovery() else { throw PurchaseAccessRequired() }
        return try await store.mergeDiscovery(found, gone: gone, notifying: notifying, expectedNewPhotosOnly: preferences.newPhotosOnly)
    }
}

import Foundation
import Photos

/// Finds the photos to back up (B3): every photo and video in the selected
/// albums and in none of the excluded ones, read from Photos a batch at a time through P2's
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

    func run() async throws -> DiscoveryMerge {
        guard let preferences = try await store.preferences(), !preferences.includedAlbums.isEmpty else { return DiscoveryMerge() }
        let access = staging.authorization
        guard access == .authorized || access == .limited else { throw PHPhotosError(.accessUserDenied) }
        var found: [DeviceCandidate] = []
        for try await batch in staging.candidates(included: preferences.includedAlbums, excluded: preferences.excludedAlbums) {
            found += batch
        }
        try Task.checkCancellation()
        var gone: [String] = []
        if access == .authorized {
            let unseen = Set(try await store.libraryJobKeys()).subtracting(found.map(\.id))
            if !unseen.isEmpty {
                let present = try await staging.existing(Array(unseen))
                gone = unseen.subtracting(present).sorted()
            }
        }
        try Task.checkCancellation()
        return try await store.mergeDiscovery(found, gone: gone, notifying: notifying)
    }
}

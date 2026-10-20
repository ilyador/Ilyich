import IlyichPlatform
import Photos

/// Saves server assets into the user's Apple Photos library, one asset (or one Live Photo pair) at a time.
@MainActor
enum PhotoLibrarySave {
    static func requestPermission(api: APIClient) async throws {
        try Task.checkCancellation()
        guard !api.isReadOnly else { throw ReadOnlyPolicy.ReadOnlyError() }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw APIError.invalidResponse("Allow Ilyich to add photos in iPhone Settings, then try again.") }
        try Task.checkCancellation()
        guard !api.isReadOnly else { throw ReadOnlyPolicy.ReadOnlyError() }
    }

    /// `beforeCommit` runs immediately before the Photos change begins. Once it returns, cancellation can no longer undo the save.
    static func save(_ asset: Asset, api: APIClient, original: Bool, progress: @escaping @Sendable (Double?) -> Void, beforeCommit: @MainActor () throws -> Void) async throws {
        try Task.checkCancellation()
        guard !api.isReadOnly else { throw ReadOnlyPolicy.ReadOnlyError() }
        // A Live Photo requires the original matching still/video identifiers.
        // Server-rendered JPEGs cannot substitute for the paired still metadata.
        let live = asset.livePhotoVideoId != nil
        let file = try await api.download(asset: asset, original: original || live, progress: live ? { progress($0.map { $0 / 2 }) } : progress)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var motionURL: URL?
        defer { if let motionURL { try? FileManager.default.removeItem(at: motionURL.deletingLastPathComponent()) } }
        if let motionID = asset.livePhotoVideoId {
            try Task.checkCancellation()
            guard !api.isReadOnly else { throw ReadOnlyPolicy.ReadOnlyError() }
            let motionAsset = try await api.asset(id: motionID)
            try Task.checkCancellation()
            guard !api.isReadOnly else { throw ReadOnlyPolicy.ReadOnlyError() }
            motionURL = try await api.download(asset: motionAsset, original: true, progress: { progress($0.map { 0.5 + $0 / 2 }) })
        }
        try Task.checkCancellation()
        guard !api.isReadOnly else { throw ReadOnlyPolicy.ReadOnlyError() }
        try beforeCommit()
        let isVideo = asset.isVideo
        let pairedURL = motionURL
        try await PHPhotoLibrary.shared().performChanges(changeBlock(file: file, isVideo: isVideo, pairedURL: pairedURL))
    }

    // PhotoKit executes this callback on its own queue; building it outside the
    // MainActor method prevents an inherited executor check from trapping there.
    private nonisolated static func changeBlock(file: URL, isVideo: Bool, pairedURL: URL?) -> @Sendable () -> Void {
        {
            let creation = PHAssetCreationRequest.forAsset()
            creation.addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
            if let pairedURL { creation.addResource(with: .pairedVideo, fileURL: pairedURL, options: nil) }
        }
    }
}

import Foundation

/// The server calls transfers make (architecture section 2). Every read is strict: it asks the
/// server and never falls back to the offline library, since a backup decision taken on a cached
/// answer could be wrong.
protocol TransferServerAPI: Sendable {
    /// POST assets/bulk-upload-check: what the server holds for each checksum.
    func bulkUploadCheck(_ items: [UploadCheck.Item]) async throws -> [UploadCheckResponse.Result]
    /// A lightweight empty bulk check. Nil when an older server has no preparation status.
    func contentFingerprintStatus() async throws -> UploadCheckResponse.ContentFingerprintStatus?
    /// An authorized POST assets request for a multipart body with `boundary`, allowed onto
    /// cellular and other expensive networks only when `allowsCellular`.
    func uploadRequest(boundary: String, allowsCellular: Bool) async throws -> URLRequest
    /// GET assets/<id>, strict.
    func remoteAsset(id: String) async throws -> BackupRemoteAsset
    /// The video an asset is paired with as a Live Photo, strict.
    func livePhotoVideoID(of assetID: String) async throws -> String?
    /// Pairs a still with its Live Photo video.
    func setLivePhotoVideo(assetID: String, motionID: String) async throws
    /// Stacks the assets, the first on top.
    func createStack(_ assetIDs: [String]) async throws
    func createStack(_ assetIDs: [String], expectedChecksums: [String: String]) async throws
    func addToAlbum(_ albumID: String, assetIDs: [String]) async throws -> [BulkResult]
    /// The albums the user owns, strict.
    func ownedAlbums() async throws -> [Album]
    func createAlbum(name: String) async throws -> Album
}

extension TransferServerAPI {
    func contentFingerprintStatus() async throws -> UploadCheckResponse.ContentFingerprintStatus? { nil }
    func createStack(_ assetIDs: [String], expectedChecksums: [String: String]) async throws {
        for (id, checksum) in expectedChecksums {
            let remote = try await remoteAsset(id: id)
            guard remote.id == id, !remote.isTrashed, remote.isOffline != true, remote.fileChecksum == checksum else {
                throw ServerFailure.http(400, "A photo changed before its versions could be linked.")
            }
        }
        try Task.checkCancellation()
        try await createStack(assetIDs)
    }
}

/// TransferServerAPI over the account's one client, AccountRuntime.api: its transport, its
/// address choice and its read-only fence. Transfers never make a client of their own.
struct APITransferServer: TransferServerAPI {
    let client: APIClient

    func bulkUploadCheck(_ items: [UploadCheck.Item]) async throws -> [UploadCheckResponse.Result] {
        let response: UploadCheckResponse = try await client.request(.post, path: "assets/bulk-upload-check", body: UploadCheck(assets: items))
        return response.results
    }

    func contentFingerprintStatus() async throws -> UploadCheckResponse.ContentFingerprintStatus? {
        let response: UploadCheckResponse = try await client.request(.post, path: "assets/bulk-upload-check", body: UploadCheck(assets: []))
        return response.contentFingerprintStatus
    }

    func uploadRequest(boundary: String, allowsCellular: Bool) async throws -> URLRequest {
        var request = try await client.authorizedRequest(path: "assets")
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsCellular
        return request
    }

    func remoteAsset(id: String) async throws -> BackupRemoteAsset {
        try await client.request(.get, path: "assets/\(id)")
    }

    func livePhotoVideoID(of assetID: String) async throws -> String? {
        try await remoteAsset(id: assetID).livePhotoVideoId
    }

    func setLivePhotoVideo(assetID: String, motionID: String) async throws {
        try await client.requestVoid(.put, path: "assets/\(assetID)", body: ["livePhotoVideoId": motionID])
    }

    func createStack(_ assetIDs: [String]) async throws {
        try await createStack(assetIDs, expectedChecksums: [:])
    }

    func createStack(_ assetIDs: [String], expectedChecksums: [String: String]) async throws {
        struct StackCreation: Encodable, Sendable { let assetIds: [String] }
        guard let ownerID = client.userID else { throw APIError.signedOut }
        var assets: [BackupRemoteAsset] = []
        for id in assetIDs {
            try Task.checkCancellation()
            let asset = try await remoteAsset(id: id)
            guard asset.id == id else { throw APIError.invalidResponse("The server returned a different photo while linking versions.") }
            assets.append(asset)
        }
        for asset in assets {
            if let expected = expectedChecksums[asset.id], asset.fileChecksum != expected {
                throw ServerFailure.http(400, "A photo changed before its versions could be linked.")
            }
        }
        let existing: BackupStackSnapshot?
        if let id = assets.compactMap({ $0.stack?.id }).first {
            existing = try await client.request(.get, path: "stacks/\(id)")
        } else { existing = nil }
        guard let ids = try BackupStackPlan.assetIDs(for: assets, existing: existing, ownerID: ownerID) else { return }
        // A slow stack read can outlive a user's grouping change. Revalidate every planned
        // input, even history tasks without checksum proof, before using the earlier plan.
        var refreshed: [BackupRemoteAsset] = []
        for asset in assets {
            let remote = try await remoteAsset(id: asset.id)
            guard remote.id == asset.id, remote.ownerId == ownerID, !remote.isTrashed, remote.isOffline != true,
                  remote.visibility != "locked", remote.visibility != "hidden",
                  expectedChecksums[asset.id].map({ remote.fileChecksum == $0 }) ?? true else {
                throw ServerFailure.http(400, "A photo changed before its versions could be linked.")
            }
            guard remote.stack?.id == asset.stack?.id else {
                throw ServerFailure.http(400, "A photo's group changed before its versions could be linked. Try again.")
            }
            refreshed.append(remote)
        }
        let refreshedExisting: BackupStackSnapshot?
        if let existing {
            let current: BackupStackSnapshot = try await client.request(.get, path: "stacks/\(existing.id)")
            guard current.id == existing.id, current.primaryAssetId == existing.primaryAssetId,
                  Set(current.assets.map(\.id)) == Set(existing.assets.map(\.id)) else {
                throw ServerFailure.http(400, "The photo group's cover or members changed. Their group was preserved.")
            }
            for asset in current.assets {
                if let expected = expectedChecksums[asset.id], asset.fileChecksum != expected {
                    throw ServerFailure.http(400, "A photo changed before its versions could be linked.")
                }
            }
            refreshedExisting = current
        } else { refreshedExisting = nil }
        guard let refreshedIDs = try BackupStackPlan.assetIDs(for: refreshed, existing: refreshedExisting, ownerID: ownerID),
              refreshedIDs.first == ids.first, Set(refreshedIDs) == Set(ids) else {
            throw ServerFailure.http(400, "The photo group changed before its versions could be linked. Try again.")
        }
        try Task.checkCancellation()
        let _: StackDetails = try await client.request(.post, path: "stacks", body: StackCreation(assetIds: ids))
    }

    func addToAlbum(_ albumID: String, assetIDs: [String]) async throws -> [BulkResult] {
        try await client.request(.put, path: "albums/\(albumID)/assets", body: BulkIDs(ids: assetIDs))
    }

    func ownedAlbums() async throws -> [Album] {
        try await client.request(.get, path: "albums", query: [URLQueryItem(name: "isOwned", value: "true")])
    }

    func createAlbum(name: String) async throws -> Album {
        try await client.createAlbum(name: name)
    }
}

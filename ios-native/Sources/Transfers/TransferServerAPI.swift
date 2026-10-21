import Foundation

/// The server calls transfers make (architecture section 2). Every read is strict: it asks the
/// server and never falls back to the offline library, since a backup decision taken on a cached
/// answer could be wrong.
protocol TransferServerAPI: Sendable {
    /// POST assets/bulk-upload-check: what the server holds for each checksum.
    func bulkUploadCheck(_ items: [UploadCheck.Item]) async throws -> [UploadCheckResponse.Result]
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
    func addToAlbum(_ albumID: String, assetIDs: [String]) async throws -> [BulkResult]
    /// The albums the user owns, strict.
    func ownedAlbums() async throws -> [Album]
    func createAlbum(name: String) async throws -> Album
}

/// TransferServerAPI over the account's one client, AccountRuntime.api: its transport, its
/// address choice and its read-only fence. Transfers never make a client of their own.
struct APITransferServer: TransferServerAPI {
    let client: APIClient

    func bulkUploadCheck(_ items: [UploadCheck.Item]) async throws -> [UploadCheckResponse.Result] {
        let response: UploadCheckResponse = try await client.request(.post, path: "assets/bulk-upload-check", body: UploadCheck(assets: items))
        return response.results
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
        struct StackCreation: Encodable, Sendable { let assetIds: [String] }
        let _: StackDetails = try await client.request(.post, path: "stacks", body: StackCreation(assetIds: assetIDs))
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

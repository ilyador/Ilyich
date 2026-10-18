import Foundation

enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

enum APIError: Error, LocalizedError, Sendable {
    case invalidServerURL
    case unauthorized
    case forbidden
    case notFound
    case http(Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Enter a valid HTTP or HTTPS server address without a password, query, or fragment."
        case .unauthorized: "Your session has expired. Please sign in again."
        case .forbidden: "This account cannot access that item. It may require unlocking."
        case .notFound: "This item is unavailable. Refresh and try again."
        case .http(let code): "The server could not complete the request (HTTP \(code))."
        case .invalidResponse(let message): message
        }
    }
}

actor APIClient {
    nonisolated let baseURL: URL
    nonisolated let userID: String?
    private nonisolated let anonymousScope = UUID().uuidString
    nonisolated var cacheScope: String { baseURL.absoluteString + "|" + (userID ?? anonymousScope) }
    private let accessToken: String?
    private let session: URLSession
    private let connection: ServerConnection
    private var castAuthorization: CastAuthorization?

    init(baseURL: URL, accessToken: String? = nil, userID: String? = nil, session: URLSession? = nil, networkConfiguration: NetworkConfiguration? = nil) throws {
        self.baseURL = try Self.normalizedBaseURL(baseURL)
        self.accessToken = accessToken
        self.userID = userID
        self.connection = try ServerConnection(server: self.baseURL, configuration: networkConfiguration)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 75
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration, delegate: SameOriginRedirectDelegate(origin: self.baseURL), delegateQueue: nil)
        }
    }

    nonisolated static func normalizedBaseURL(_ input: URL) throws -> URL {
        do { return try ServerAddress.normalized(input) }
        catch { throw APIError.invalidServerURL }
    }

    func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        do { return try ServerAddress.url(base: baseURL, path: path, query: query) }
        catch { throw APIError.invalidServerURL }
    }

    func authorizedRequest(path: String, query: [URLQueryItem] = []) async throws -> URLRequest {
        try await connection.request(path: path, query: query, token: accessToken)
    }
    func networkConfiguration() async -> NetworkConfiguration { await connection.settings() }
    func updateNetworkConfiguration(_ configuration: NetworkConfiguration) async throws { try await connection.update(configuration) }
    func activeEndpoint() async throws -> URL { try await connection.endpoint() }

    func request<T: Decodable & Sendable>(_ method: HTTPMethod, path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await perform(method, path: path, query: query)
        return try decode(T.self, data: data)
    }

    func request<T: Decodable & Sendable, Body: Encodable & Sendable>(_ method: HTTPMethod, path: String, body: Body,
                                                                   query: [URLQueryItem] = []) async throws -> T {
        let data = try await perform(method, path: path, query: query, body: APIJSON.encoder().encode(body))
        return try decode(T.self, data: data)
    }

    func requestVoid(_ method: HTTPMethod, path: String, query: [URLQueryItem] = []) async throws {
        _ = try await perform(method, path: path, query: query)
    }

    func requestVoid<Body: Encodable & Sendable>(_ method: HTTPMethod, path: String, body: Body) async throws {
        _ = try await perform(method, path: path, body: APIJSON.encoder().encode(body))
    }

    private func perform(_ method: HTTPMethod, path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        var request = try await authorizedRequest(path: path, query: query)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { await connection.invalidate(); throw error }
        try Self.validate(response)
        try Task.checkCancellation()
        return data
    }

    nonisolated static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse("The server returned an invalid response.") }
        switch response.statusCode {
        case 200..<300: return
        case 401: throw APIError.unauthorized
        case 403: throw APIError.forbidden
        case 404: throw APIError.notFound
        default: throw APIError.http(response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do { return try APIJSON.decoder().decode(type, from: data) }
        catch { throw APIError.invalidResponse("The server returned data this version of Ilyich could not read.") }
    }

    func login(email: String, password: String) async throws -> LoginResponse {
        try await request(.post, path: "auth/login", body: LoginBody(email: email, password: password))
    }
    func logout() async throws { try await requestVoid(.post, path: "auth/logout") }
    func validateToken() async throws { try await requestVoid(.post, path: "auth/validateToken") }
    func serverFeatures() async throws -> ServerFeatures { try await request(.get, path: "server/features") }
    func serverConfig() async throws -> ServerConfig { try await request(.get, path: "server/config") }
    func authStatus() async throws -> AuthStatus { try await request(.get, path: "auth/status") }
    func unlock(pin: String) async throws { try await requestVoid(.post, path: "auth/session/unlock", body: ["pinCode": pin]) }
    func lock() async throws { try await requestVoid(.post, path: "auth/session/lock") }
    func currentUser() async throws -> User { try await request(.get, path: "users/me") }

    func timeBuckets(filter: TimelineFilter = .init()) async throws -> [TimeBucket] {
        try await request(.get, path: "timeline/buckets", query: filter.queryItems)
    }
    func timeBucket(_ bucket: String, filter: TimelineFilter = .init()) async throws -> [Asset] {
        let payload: TimeBucketPayload = try await request(.get, path: "timeline/bucket", query: filter.queryItems + [.init(name: "timeBucket", value: bucket)])
        return try payload.assets()
    }
    func asset(id: String) async throws -> Asset { try await request(.get, path: "assets/\(id)") }
    func assetStatistics() async throws -> AssetStatistics { try await request(.get, path: "assets/statistics") }
    func search(_ query: SearchQuery) async throws -> SearchResponse { try await request(.post, path: "search/smart", body: query) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { try await request(.post, path: "search/metadata", body: query) }
    func albums() async throws -> [Album] { try await request(.get, path: "albums") }
    func album(id: String) async throws -> Album { try await request(.get, path: "albums/\(id)") }
    func people(page: Int = 1, size: Int = 100) async throws -> PeopleResponse {
        try await request(.get, path: "people", query: [.init(name: "page", value: String(page)), .init(name: "size", value: String(size))])
    }
    func person(id: String) async throws -> Person { try await request(.get, path: "people/\(id)") }
    func mapMarkers() async throws -> [MapMarker] { try await request(.get, path: "map/markers") }
    func updateFavorite(assetID: String, value: Bool) async throws -> Asset {
        try await request(.put, path: "assets/\(assetID)", body: ["isFavorite": value])
    }

    func updateAsset(id: String, update: AssetUpdate) async throws -> Asset { try await request(.put, path: "assets/\(id)", body: update) }
    func trashAssets(ids: [String], permanently: Bool = false) async throws {
        try await requestVoid(.delete, path: "assets", body: AssetDeletion(ids: ids, force: permanently))
    }
    func restoreAssets(ids: [String]) async throws -> TrashResult { try await request(.post, path: "trash/restore/assets", body: BulkIDs(ids: ids)) }
    func emptyTrash() async throws -> TrashResult { try await request(.post, path: "trash/empty") }
    func createAlbum(name: String, assetIDs: [String] = []) async throws -> Album {
        try await request(.post, path: "albums", body: AlbumCreation(albumName: name, assetIds: assetIDs))
    }
    func renameAlbum(id: String, name: String) async throws -> Album { try await request(.patch, path: "albums/\(id)", body: ["albumName": name]) }
    func deleteAlbum(id: String) async throws { try await requestVoid(.delete, path: "albums/\(id)") }
    func addToAlbum(id: String, assetIDs: [String]) async throws -> [BulkResult] {
        try await request(.put, path: "albums/\(id)/assets", body: BulkIDs(ids: assetIDs))
    }
    func removeFromAlbum(id: String, assetIDs: [String]) async throws -> [BulkResult] {
        try await request(.delete, path: "albums/\(id)/assets", body: BulkIDs(ids: assetIDs))
    }
    func memories() async throws -> [Memory] { try await request(.get, path: "memories") }
    func partners(direction: String = "shared-with") async throws -> [Partner] {
        try await request(.get, path: "partners", query: [.init(name: "direction", value: direction)])
    }
    func sharedLinks() async throws -> [SharedLink] { try await request(.get, path: "shared-links") }
    func createSharedLink(_ body: SharedLinkCreation) async throws -> SharedLink { try await request(.post, path: "shared-links", body: body) }
    func deleteSharedLink(id: String) async throws { try await requestVoid(.delete, path: "shared-links/\(id)") }
    func duplicates() async throws -> [DuplicateGroup] { try await request(.get, path: "duplicates") }
    func folders() async throws -> [String] { try await request(.get, path: "view/folder/unique-paths") }
    func folderAssets(path: String) async throws -> [Asset] { try await request(.get, path: "view/folder", query: [.init(name: "path", value: path)]) }
    func assetOCR(id: String) async throws -> [RecognizedText] { try await request(.get, path: "assets/\(id)/ocr") }
    func assetAlbums(id: String) async throws -> [Album] { try await request(.get, path: "albums", query: [.init(name: "assetId", value: id)]) }
    func assetEdits(id: String) async throws -> AssetEdits { try await request(.get, path: "assets/\(id)/edits") }
    func saveEdits(id: String, edits: [PhotoEdit]) async throws -> AssetEdits { try await request(.put, path: "assets/\(id)/edits", body: EditSubmission(edits: edits)) }
    func removeEdits(id: String) async throws { try await requestVoid(.delete, path: "assets/\(id)/edits") }
    func updateRating(id: String, rating: Int?) async throws -> Asset { try await request(.put, path: "assets/\(id)", body: RatingUpdate(rating: rating)) }

    func profileImage(userID: String) async throws -> Data {
        try await perform(.get, path: "users/\(userID)/profile-image")
    }
    func uploadProfileImage(jpeg: Data) async throws {
        let boundary = "Ilyich-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"profile-picture.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        body.append(jpeg); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = try await authorizedRequest(path: "users/profile-image")
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, from: body)
        try Self.validate(response)
    }

    func prepareCast(asset: Asset) async throws -> CastMedia {
        let authorization: CastAuthorization
        if let saved = castAuthorization, let expiry = saved.expiresAt, expiry > Date().addingTimeInterval(10) { authorization = saved }
        else {
            authorization = try await request(.post, path: "sessions", body: CastSessionCreation())
            castAuthorization = authorization
        }
        let path = "assets/\(asset.id)/" + (asset.isVideo ? "video/playback" : "thumbnail")
        let query: [URLQueryItem] = asset.isVideo ? [] : [.init(name: "size", value: "fullsize"), .init(name: "edited", value: "true"), .init(name: "c", value: asset.cacheRevision)]
        var mediaRequest = try await authorizedRequest(path: path, query: query)
        mediaRequest.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: mediaRequest)
        try Self.validate(response)
        guard let mime = response.mimeType, var parts = URLComponents(url: try await connection.request(path: path, query: query).url!, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse("The server did not identify this media type for casting.")
        }
        parts.queryItems = (parts.queryItems ?? []) + [.init(name: "sessionKey", value: authorization.token)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw APIError.invalidServerURL }
        return CastMedia(url: url, contentType: mime)
    }
    func revokeCastAuthorization() async {
        guard let authorization = castAuthorization else { return }
        castAuthorization = nil
        try? await requestVoid(.delete, path: "sessions/\(authorization.id)")
    }

    /// Download only on explicit export/share. Keep large originals out of memory.
    func download(asset: Asset, original: Bool = false) async throws -> URL {
        let useOriginal = original || asset.isVideo
        let path = "assets/\(asset.id)/" + (useOriginal ? "original" : "thumbnail")
        var query = [URLQueryItem(name: "edited", value: useOriginal ? "false" : "true"), .init(name: "c", value: asset.cacheRevision)]
        if !useOriginal { query.append(.init(name: "size", value: "fullsize")) }
        let downloadRequest = try await authorizedRequest(path: path, query: query)
        let (temporaryURL, response) = try await session.download(for: downloadRequest)
        try Self.validate(response)
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rawName = response.suggestedFilename ?? (useOriginal ? asset.originalFileName : "photo.jpg")
        let name = (rawName as NSString).lastPathComponent.replacingOccurrences(of: "\\", with: "_")
        let destination = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "photo" : name)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }
}

struct RatingUpdate: Encodable, Sendable {
    let rating: Int?
    private enum CodingKeys: String, CodingKey { case rating }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rating, forKey: .rating)
    }
}

private struct LoginBody: Encodable, Sendable { let email: String; let password: String }
struct BulkIDs: Encodable, Sendable { let ids: [String] }
private struct AssetDeletion: Encodable, Sendable { let ids: [String]; let force: Bool }
private struct AlbumCreation: Encodable, Sendable { let albumName: String; let assetIds: [String] }
struct AssetUpdate: Encodable, Sendable {
    var isFavorite: Bool?
    var visibility: AssetVisibility?
    var description: String?
    var dateTimeOriginal: String?
    var latitude: Double?
    var longitude: Double?
}
struct SharedLinkCreation: Encodable, Sendable {
    var type = "INDIVIDUAL"
    var assetIds: [String]?
    var albumId: String?
    var description: String?
    var expiresAt: Date?
    var password: String?
    var allowDownload = true
    var allowUpload = false
    var showMetadata = false
}

struct CastMedia: Sendable { let url: URL; let contentType: String }
private struct CastSessionCreation: Encodable, Sendable {
    let deviceType = "Cast"
    let deviceOS = "Google Cast"
    let duration = 900
}
private struct CastAuthorization: Decodable, Sendable { let id: String; let token: String; let expiresAt: Date? }

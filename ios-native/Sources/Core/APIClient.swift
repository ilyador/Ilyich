import Foundation
import CryptoKit
import IlyichPlatform

enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

/// Failures found on the phone. What the server answers is a ServerFailure, and a request that
/// got no answer fails with a URLError or a TransportFailure.
enum APIError: Error, LocalizedError, Sendable {
    case invalidServerURL
    /// No session is saved, or it changed while the work ran.
    case signedOut
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Enter a valid HTTP or HTTPS server address without a password, query, or fragment."
        case .signedOut: "You’re signed out. Sign in again to continue."
        case .invalidResponse(let message): message
        }
    }
}

actor APIClient {
    nonisolated let baseURL: URL
    nonisolated let userID: String?
    private nonisolated let anonymousScope = UUID().uuidString
    nonisolated var cacheScope: String { baseURL.absoluteString + "|" + (userID ?? anonymousScope) }
    nonisolated var isReadOnly: Bool { userID.map { ReadOnlyPolicy.isEnabled(server: baseURL, userID: $0) } ?? false }
    nonisolated func setReadOnly(_ enabled: Bool) {
        if let userID { ReadOnlyPolicy.setEnabled(enabled, server: baseURL, userID: userID) }
    }
    private let accessToken: String?
    /// The sessions and the address choice every request of this client goes through.
    nonisolated let transport: ServerTransport
    private nonisolated var connection: ServerConnection { transport.connection }
    private var castAuthorization: CastAuthorization?
    private var entityStore: EntityStore?
    private var cachedServerFeatures: ServerFeatures?

    /// `sessionConfiguration` replaces the transport's default configuration, for tests.
    init(baseURL: URL, accessToken: String? = nil, userID: String? = nil, sessionConfiguration: URLSessionConfiguration? = nil,
         networkConfiguration: NetworkConfiguration? = nil, wifiName: any WiFiNameProviding = SystemWiFiName()) throws {
        let server = try Self.normalizedBaseURL(baseURL)
        self.baseURL = server
        self.accessToken = accessToken
        self.userID = userID
        transport = try ServerTransport(server: server, token: accessToken,
                                        configuration: networkConfiguration ?? NetworkConfigurationStore.connectionSettings(server: server),
                                        sessionConfiguration: sessionConfiguration, wifiName: wifiName,
                                        writeCheck: { method, path in
                                            guard let userID else { return }
                                            try ReadOnlyPolicy.check(enabled: ReadOnlyPolicy.isEnabled(server: server, userID: userID), method: method, path: path)
                                        })
    }

    /// Ends this client's requests and lets its sessions go. Requests made afterwards throw
    /// CancellationError. Called when the client is replaced, for example at sign-out.
    nonisolated func shutdown() async { await transport.shutdown() }

    nonisolated static func normalizedBaseURL(_ input: URL) throws -> URL {
        do { return try ServerAddress.normalized(input) }
        catch { throw APIError.invalidServerURL }
    }

    func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        do { return try ServerAddress.url(base: baseURL, path: path, query: query) }
        catch { throw APIError.invalidServerURL }
    }

    func authorizedRequest(path: String, query: [URLQueryItem] = []) async throws -> URLRequest {
        try await transport.prepare(path: path, query: query).request
    }
    func networkConfiguration() async -> NetworkConfiguration { await connection.settings() }
    func updateNetworkConfiguration(_ configuration: NetworkConfiguration) async throws {
        let validated = try configuration.validated()
        try NetworkConfigurationStore.save(validated, server: baseURL)
        try await connection.update(validated)
    }
    func activeEndpoint() async throws -> URL { try await connection.endpoint() }

    func request<T: Decodable & Sendable>(_ method: HTTPMethod, path: String, query: [URLQueryItem] = []) async throws -> T {
        try await transport.send(.json(method, path, query: query))
    }

    func request<T: Decodable & Sendable, Body: Encodable & Sendable>(_ method: HTTPMethod, path: String, body: Body,
                                                                   query: [URLQueryItem] = []) async throws -> T {
        try await transport.send(.json(method, path, body: body, query: query))
    }

    func requestVoid(_ method: HTTPMethod, path: String, query: [URLQueryItem] = []) async throws {
        _ = try await transport.send(.void(method, path, query: query))
    }

    func requestVoid<Body: Encodable & Sendable>(_ method: HTTPMethod, path: String, body: Body) async throws {
        _ = try await transport.send(.void(method, path, body: try APIJSON.encoder().encode(body)))
    }

    func login(email: String, password: String) async throws -> LoginResponse {
        try await request(.post, path: "auth/login", body: LoginBody(email: email, password: password))
    }
    func logout() async throws { try await requestVoid(.post, path: "auth/logout") }
    func validateToken() async throws { try await requestVoid(.post, path: "auth/validateToken") }
    func serverFeatures() async throws -> ServerFeatures {
        do {
            let features: ServerFeatures = try await request(.get, path: "server/features")
            cachedServerFeatures = features
            if let entityStore { try? await entityStore.persistCachedServerFeatures(features) }
            return features
        } catch {
            guard canReadOffline(error), let entityStore, try await entityStore.isComplete() else { throw error }
            let saved: ServerFeatures?
            if let cachedServerFeatures {
                saved = cachedServerFeatures
            } else {
                saved = try await entityStore.cachedServerFeatures()
            }
            guard let saved else { throw error }
            return saved
        }
    }
    func persistCachedServerFeatures() async {
        guard let cachedServerFeatures, let entityStore else { return }
        try? await entityStore.persistCachedServerFeatures(cachedServerFeatures)
    }
    func serverConfig() async throws -> ServerConfig { try await request(.get, path: "server/config") }
    func authStatus() async throws -> AuthStatus { try await request(.get, path: "auth/status") }
    func unlock(pin: String) async throws { try await requestVoid(.post, path: "auth/session/unlock", body: ["pinCode": pin]) }
    func lock() async throws { try await requestVoid(.post, path: "auth/session/lock") }
    func currentUser() async throws -> User { try await request(.get, path: "users/me") }

    // The server cannot narrow its timeline to a place, and would answer with the whole library.
    func timeBuckets(filter: TimelineFilter = .init()) async throws -> [TimeBucket] {
        guard filter.place == nil else { throw LibraryAPIError.placeNeedsOfflineLibrary }
        return try await request(.get, path: "timeline/buckets", query: filter.queryItems)
    }
    func timeBucket(_ bucket: String, filter: TimelineFilter = .init()) async throws -> [Asset] {
        guard filter.place == nil else { throw LibraryAPIError.placeNeedsOfflineLibrary }
        let payload: TimeBucketPayload = try await request(.get, path: "timeline/bucket", query: filter.queryItems + [.init(name: "timeBucket", value: bucket)])
        return try payload.assets()
    }
    func attachEntityStore(_ store: EntityStore?) async {
        entityStore = store.flatMap { $0.scope == cacheScope && $0.userID == userID ? $0 : nil }
        if let cachedServerFeatures, let entityStore {
            try? await entityStore.persistCachedServerFeatures(cachedServerFeatures)
        }
    }
    func syncStatistics() async throws -> EntityStoreStatistics? { try await entityStore?.statistics() }
    private func canReadOffline(_ error: any Error) -> Bool {
        TransportFailure.isDefinite(error) && !Task.isCancelled
    }
    func asset(id: String) async throws -> Asset {
        do { return try await request(.get, path: "assets/\(id)") }
        catch { if canReadOffline(error), let cached = try await entityStore?.asset(id: id) { return cached }; throw error }
    }
    func assetStatistics() async throws -> AssetStatistics { try await request(.get, path: "assets/statistics") }
    func search(_ query: SearchQuery) async throws -> SearchResponse { try await request(.post, path: "search/smart", body: query) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { try await request(.post, path: "search/metadata", body: query) }
    func albums() async throws -> [Album] {
        do { return try await request(.get, path: "albums") }
        catch { if canReadOffline(error), let store = entityStore, try await store.isComplete() { return try await store.albums() }; throw error }
    }
    func album(id: String) async throws -> Album {
        do { return try await request(.get, path: "albums/\(id)") }
        catch {
            guard canReadOffline(error), let store = entityStore, try await store.isComplete(), let cached = try await store.album(id: id) else { throw error }
            return cached
        }
    }
    func people(page: Int = 1, size: Int = 100, name: String? = nil) async throws -> PeopleResponse {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var query = [URLQueryItem(name: "page", value: String(page)), .init(name: "size", value: String(size))]
        if !name.isEmpty { query.append(.init(name: "name", value: name)) }
        do { return try await request(.get, path: "people", query: query) }
        catch {
            guard canReadOffline(error), let store = entityStore, try await store.isComplete() else { throw error }
            let all = try await store.people().filter { name.isEmpty || $0.name.localizedStandardContains(name) }
            let visible = all.filter { $0.isHidden != true }
            let safeSize = min(max(size, 1), 1_000), start = min(max(page - 1, 0), visible.count) * min(max(size, 1), 1_000)
            return PeopleResponse(people: Array(visible.dropFirst(start).prefix(safeSize)), total: all.count, hidden: all.count - visible.count, hasNextPage: start + safeSize < visible.count)
        }
    }
    func person(id: String) async throws -> Person {
        do { return try await request(.get, path: "people/\(id)") }
        catch {
            guard canReadOffline(error), let store = entityStore, try await store.isComplete(), let cached = try await store.person(id: id) else { throw error }
            return cached
        }
    }
    func mapMarkers(_ query: MapMarkerQuery = .init()) async throws -> [MapMarker] {
        do { return try await request(.get, path: "map/markers", query: query.queryItems) }
        catch {
            guard canReadOffline(error), let entityStore, try await entityStore.isComplete() else { throw error }
            return try await entityStore.mapMarkers(query)
        }
    }
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
    func memories(on date: Date = Date()) async throws -> [Memory] {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
        do {
            let preferences: MemoryPreferences = try await request(.get, path: "users/me/preferences")
            guard preferences.memories.enabled else { return [] }
            return try await request(.get, path: "memories", query: [.init(name: "for", value: day)])
        }
        catch {
            guard canReadOffline(error), let store = entityStore, try await store.isComplete() else { throw error }
            return try await store.memories(onCivilDate: day)
        }
    }
    func partners(direction: String = "shared-with") async throws -> [Partner] {
        guard ["shared-with", "shared-by"].contains(direction) else { throw APIError.invalidResponse("Unsupported partner direction.") }
        do { return try await request(.get, path: "partners", query: [.init(name: "direction", value: direction)]) }
        catch { if canReadOffline(error), let store = entityStore, try await store.isComplete() { return try await store.partners(direction: direction) }; throw error }
    }
    /// All of the owner's links, or only those sharing one album.
    func sharedLinks(albumID: String? = nil) async throws -> [SharedLink] {
        try await request(.get, path: "shared-links", query: albumID.map { [URLQueryItem(name: "albumId", value: $0)] } ?? [])
    }
    func createSharedLink(_ body: SharedLinkCreation) async throws -> SharedLink { try await request(.post, path: "shared-links", body: body) }
    func deleteSharedLink(id: String) async throws { try await requestVoid(.delete, path: "shared-links/\(id)") }
    func duplicates() async throws -> [DuplicateGroup] { try await request(.get, path: "duplicates") }
    func folders() async throws -> [String] { try await request(.get, path: "view/folder/unique-paths") }
    func folderAssets(path: String) async throws -> [Asset] { try await request(.get, path: "view/folder", query: [.init(name: "path", value: path)]) }
    func assetOCR(id: String) async throws -> [RecognizedText] {
        do { return try await request(.get, path: "assets/\(id)/ocr") }
        catch { if canReadOffline(error), let store = entityStore, try await store.isComplete(), try await store.asset(id: id) != nil { return try await store.assetOCR(id: id) }; throw error }
    }
    func assetAlbums(id: String) async throws -> [Album] { try await request(.get, path: "albums", query: [.init(name: "assetId", value: id)]) }
    func assetEdits(id: String) async throws -> AssetEdits { try await request(.get, path: "assets/\(id)/edits") }
    func saveEdits(id: String, edits: [PhotoEdit]) async throws -> AssetEdits { try await request(.put, path: "assets/\(id)/edits", body: EditSubmission(edits: edits)) }
    func removeEdits(id: String) async throws { try await requestVoid(.delete, path: "assets/\(id)/edits") }
    func updateRating(id: String, rating: Int?) async throws -> Asset { try await request(.put, path: "assets/\(id)", body: RatingUpdate(rating: rating)) }

    func profileImage(userID: String) async throws -> Data {
        try await transport.send(.data(.get, "users/\(userID)/profile-image"))
    }
    func uploadProfileImage(jpeg: Data) async throws {
        let boundary = "Ilyich-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"profile-picture.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        body.append(jpeg); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        _ = try await transport.send(.void(.post, "users/profile-image", body: body, contentType: "multipart/form-data; boundary=\(boundary)"))
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
        let (head, response) = try await transport.data(for: mediaRequest)
        try ServerFailure.check(response, body: head, path: path)
        let castRequest = try await connection.request(path: path, query: query)
        guard let mime = response.mimeType, let castURL = castRequest.url, var parts = URLComponents(url: castURL, resolvingAgainstBaseURL: false) else {
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
    func download(asset: Asset, original: Bool = false, progress: (@Sendable (Double?) -> Void)? = nil) async throws -> URL {
        let useOriginal = original || asset.isVideo
        let path = "assets/\(asset.id)/" + (useOriginal ? "original" : "thumbnail")
        var query = [URLQueryItem(name: "edited", value: useOriginal ? "false" : "true"), .init(name: "c", value: asset.cacheRevision)]
        if !useOriginal { query.append(.init(name: "size", value: "fullsize")) }
        let downloadRequest = try await authorizedRequest(path: path, query: query)
        let observer = DownloadProgressObserver { progress?($0) }
        defer { observer.stopObserving() }
        let (temporaryURL, response) = try await transport.download(downloadRequest, starting: { observer.observe($0) })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try ServerFailure.check(response, body: Self.errorBody(of: response, at: temporaryURL), path: path)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let rawName = response.suggestedFilename ?? (useOriginal ? asset.originalFileName : "photo.jpg")
            let name = (rawName as NSString).lastPathComponent.replacingOccurrences(of: "\\", with: "_")
            let destination = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "photo" : name)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The start of a failed download's body, which says whether the server or a proxy refused it.
    private nonisolated static func errorBody(of response: URLResponse, at file: URL) -> Data? {
        guard let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status),
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 64 * 1024)
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
private struct MemoryPreferences: Decodable {
    struct Memories: Decodable { let enabled: Bool }
    let memories: Memories
}
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


extension APIClient {
    /// Only a digest enters the offline database; the actual session remains in Keychain.
    func syncSessionFingerprint() throws -> String {
        guard let accessToken, userID != nil else { throw APIError.signedOut }
        return SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func acknowledgeSync(_ acks: [String]) async throws {
        guard !acks.isEmpty else { return }
        try await requestVoid(.post, path: "sync/ack", body: ["acks": acks])
    }
    func consumeSyncStream(reset: Bool, onBatch: @Sendable ([EntitySyncEvent]) async throws -> Void) async throws {
        let startedAt = Date()
        var status: Int?
        var route: ServerConnection.Route?
        do {
            var (request, chosen) = try await transport.prepare(path: "sync/stream")
            route = chosen
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/jsonlines+json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(EntitySyncRequest(reset: reset))
            let (response, body) = try await transport.stream(request, path: "sync/stream")
            status = response.statusCode
            var batch: [EntitySyncEvent] = []
            var ended = false
            let lines = ResponseLines(body: body, limit: 4 * 1_024 * 1_024) { APIError.invalidResponse("The server returned an invalid sync stream.") }
            for try await line in lines {
                try Task.checkCancellation()
                guard !line.isEmpty else { continue }
                guard !ended else { throw APIError.invalidResponse("The server returned an invalid sync stream.") }
                let event: EntitySyncEvent
                do { event = try JSONDecoder().decode(EntitySyncEvent.self, from: line) }
                catch { throw APIError.invalidResponse("The server returned an unreadable sync record. The last saved batch can be resumed.") }
                batch.append(event)
                ended = ["SyncCompleteV1", "SyncResetV1"].contains(event.type)
                if batch.count == 200 || ended { try await onBatch(batch); batch.removeAll(keepingCapacity: true) }
            }
            if !batch.isEmpty { try await onBatch(batch) }
            guard ended else { throw APIError.invalidResponse("Synchronization was interrupted before completion. It will resume from the last saved batch.") }
            await DiagnosticsStore.shared.record(method: "POST", path: "sync/stream", statusCode: status, startedAt: startedAt, outcome: .success)
        } catch {
            if (error as? URLError)?.meansEndpointUnreachable == true, let route { await connection.routeFailed(route) }
            await ServerTransport.record(error, method: "POST", path: "sync/stream", status: status, startedAt: startedAt)
            throw error
        }
    }
    func serverEvents() async throws -> ServerEventConnection {
        var request = try await authorizedRequest(path: "socket.io/", query: [.init(name: "EIO", value: "4"), .init(name: "transport", value: "websocket")])
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw APIError.invalidServerURL }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        request.url = components.url
        let socket = try transport.webSocket(with: request)
        socket.maximumMessageSize = 4 * 1_024 * 1_024
        let events = AsyncThrowingStream<ServerInvalidation, any Error>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                socket.resume()
                do {
                    try await withTaskCancellationHandler {
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            let text: String
                            switch message { case .string(let value): text = value; case .data(let data): text = String(decoding: data, as: UTF8.self); @unknown default: continue }
                            switch try SocketEventPacket.parse(text) {
                            case .open: try await socket.send(.string("40"))
                            case .ping(let payload): try await socket.send(.string("3" + payload))
                            case .invalidation(let event): continuation.yield(event)
                            case .ignore: break
                            }
                        }
                    } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
                socket.cancel(with: .goingAway, reason: nil)
            }
            continuation.onTermination = { _ in task.cancel(); socket.cancel(with: .goingAway, reason: nil) }
        }
        return ServerEventConnection(events: events, close: { socket.cancel(with: .goingAway, reason: nil) })
    }
}

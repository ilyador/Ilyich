import Foundation

/// What the receiver opens: a URL that carries only the grant's token, and the media type.
struct CastMedia: Sendable, Equatable { let url: URL; let contentType: String }

/// Turns an asset and a grant into what the receiver opens. Live: CastMediaResolver; fakes in tests.
protocol CastMediaResolving: Sendable {
    func media(for asset: Asset, grant: CastGrant) async throws -> CastMedia
}

/// Builds the receiver's URL with the grant's token and checks it first with a HEAD that carries
/// that token and not the app's, so the TV is handed only what the grant itself can open.
struct CastMediaResolver: CastMediaResolving {
    let api: APIClient

    func media(for asset: Asset, grant: CastGrant) async throws -> CastMedia {
        let path = "assets/\(asset.id)/" + (asset.isVideo ? "video/playback" : "thumbnail")
        var query: [URLQueryItem] = asset.isVideo ? [] : [.init(name: "size", value: "fullsize"), .init(name: "edited", value: "true"), .init(name: "c", value: asset.cacheRevision)]
        query.append(.init(name: "sessionKey", value: grant.token))
        // No account token: the receiver has only the grant's.
        var request = try await api.transport.connection.request(path: path, query: query)
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw APIError.invalidServerURL }
        // A token's "+" would read as a space in a query.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let castURL = parts.url else { throw APIError.invalidServerURL }
        request.url = castURL
        request.httpMethod = "HEAD"
        let (head, response) = try await api.transport.data(for: request)
        try ServerFailure.check(response, body: head, path: path)
        guard let mime = response.mimeType else {
            throw APIError.invalidResponse("The server did not identify this media type for casting.")
        }
        return CastMedia(url: castURL, contentType: mime)
    }
}

extension APIClient: CastGrantServer {
    func createCastGrant(seconds: Int) async throws -> CastGrant {
        let session: CastSessionResponse = try await request(.post, path: "sessions", body: CastSessionCreation(duration: seconds))
        // Never the app's own session, and only an id that names exactly one session.
        guard session.current != true, CastGrant.isRevocable(id: session.id), !session.token.isEmpty else { throw CastGrantError.unusableGrant }
        return CastGrant(id: session.id, token: session.token, expiresAt: session.expiresAt ?? Date().addingTimeInterval(TimeInterval(seconds)))
    }

    func revokeCastGrant(id: String) async throws {
        guard CastGrant.isRevocable(id: id) else { return }
        try await requestVoid(.delete, path: "sessions/\(id)")
    }
}

private struct CastSessionCreation: Encodable, Sendable {
    let deviceType = "Cast"
    let deviceOS = "Google Cast"
    let duration: Int
}
private struct CastSessionResponse: Decodable, Sendable { let id: String; let token: String; let expiresAt: Date?; let current: Bool? }

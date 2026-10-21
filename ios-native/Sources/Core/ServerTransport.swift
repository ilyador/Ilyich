import Foundation
import IlyichPlatform

/// One request to the server's API, and how its answer is read.
struct Endpoint<Response: Sendable>: Sendable {
    let method: HTTPMethod
    /// The path below /api.
    let path: String
    var query: [URLQueryItem] = []
    var body: Data?
    var contentType: String?
    let decode: @Sendable (Data) throws -> Response

    /// A read, which may go once more to another address after its route was lost. Anything that
    /// changes the server is never sent twice: whether the first attempt reached it is unknown.
    var isIdempotent: Bool { method == .get }
}

/// What an endpoint that answers with nothing to read returns.
struct NoContent: Sendable {}

extension Endpoint where Response: Decodable {
    static func json(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = []) -> Endpoint {
        Endpoint(method: method, path: path, query: query, decode: { try APIJSON.decoder().decode(Response.self, from: $0) })
    }

    static func json<Body: Encodable & Sendable>(_ method: HTTPMethod, _ path: String, body: Body, query: [URLQueryItem] = []) throws -> Endpoint {
        Endpoint(method: method, path: path, query: query, body: try APIJSON.encoder().encode(body), contentType: "application/json",
                 decode: { try APIJSON.decoder().decode(Response.self, from: $0) })
    }
}

extension Endpoint where Response == NoContent {
    static func void(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                     contentType: String? = nil) -> Endpoint {
        Endpoint(method: method, path: path, query: query, body: body, contentType: contentType ?? (body == nil ? nil : "application/json"),
                 decode: { _ in NoContent() })
    }
}

extension Endpoint where Response == Data {
    static func data(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = []) -> Endpoint {
        Endpoint(method: method, path: path, query: query, decode: { $0 })
    }
}

/// Sends one account's requests over sessions made once, which shutdown invalidates. An answer
/// that is not a success becomes a ServerFailure. When a request loses its way to the server it
/// tells the connection which route failed; a read is then sent once more if the connection
/// chooses another address, and nothing else is ever sent twice.
actor ServerTransport {
    nonisolated let server: URL
    nonisolated let connection: ServerConnection
    private let token: String?
    /// Ordinary requests, with the API's timeouts.
    private nonisolated let session: GuardedURLSession
    /// The sync stream, the event socket and downloads, which take as long as they need.
    private nonisolated let streaming: GuardedURLSession
    /// Refuses a write while read-only mode is on. It runs before the address is chosen and again
    /// just before sending, because choosing can take seconds.
    private let writeCheck: @Sendable (_ method: String, _ path: String) throws -> Void

    /// `sessionConfiguration`, when given, is used as it is for every request, and a copy of it
    /// for the address checks: tests route both to a stub server, and a quick check sets short
    /// timeouts.
    init(server: URL, token: String?, configuration: NetworkConfiguration, sessionConfiguration: URLSessionConfiguration? = nil,
         wifiName: any WiFiNameProviding = SystemWiFiName(),
         writeCheck: @escaping @Sendable (_ method: String, _ path: String) throws -> Void = { _, _ in }) throws {
        let primary = try ServerAddress.normalized(server)
        self.server = primary
        self.token = token
        self.writeCheck = writeCheck
        let probes = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        connection = try ServerConnection(server: primary, configuration: configuration, wifiName: wifiName, probeConfiguration: probes)
        if let sessionConfiguration {
            session = GuardedURLSession(configuration: sessionConfiguration, origin: primary)
            streaming = GuardedURLSession(configuration: sessionConfiguration, origin: primary)
        } else {
            let ordinary = URLSessionConfiguration.ephemeral
            ordinary.timeoutIntervalForRequest = 75
            ordinary.timeoutIntervalForResource = 120
            session = GuardedURLSession(configuration: ordinary, origin: primary)
            let long = URLSessionConfiguration.ephemeral
            long.timeoutIntervalForRequest = 75
            long.timeoutIntervalForResource = 3_600
            streaming = GuardedURLSession(configuration: long, origin: primary)
        }
    }

    /// Ends every request of this transport and lets its sessions go. Requests made afterwards
    /// throw CancellationError, and are never sent.
    nonisolated func shutdown() async {
        session.invalidate()
        streaming.invalidate()
        await connection.shutdown()
    }

    nonisolated var isShutDown: Bool { session.isInvalidated }

    /// Sends an endpoint and reads its answer.
    func send<Response>(_ endpoint: Endpoint<Response>) async throws -> Response {
        let startedAt = Date()
        var status: Int?
        do {
            try Task.checkCancellation()
            try writeCheck(endpoint.method.rawValue, endpoint.path)
            var route = try await connection.route()
            var retried = false
            while true {
                var request = try await connection.request(path: endpoint.path, query: endpoint.query, token: token, route: route)
                try writeCheck(endpoint.method.rawValue, endpoint.path)
                request.httpMethod = endpoint.method.rawValue
                request.httpBody = endpoint.body
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                if let contentType = endpoint.contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
                do {
                    let (data, response) = try await session.data(for: request)
                    status = (response as? HTTPURLResponse)?.statusCode
                    try ServerFailure.check(response, body: data, path: endpoint.path)
                    let value: Response
                    do { value = try endpoint.decode(data) } catch { throw ServerFailure.undecodable }
                    try Task.checkCancellation()
                    await DiagnosticsStore.shared.record(method: endpoint.method.rawValue, path: endpoint.path, statusCode: status,
                                                         startedAt: startedAt, outcome: .success)
                    return value
                } catch let error as URLError where error.meansEndpointUnreachable {
                    await connection.routeFailed(route)
                    guard endpoint.isIdempotent, !retried, !Task.isCancelled else { throw error }
                    // A read goes once more, if the connection now chooses another address.
                    guard let next = try? await connection.route(), next.endpoint != route.endpoint else { throw error }
                    retried = true
                    route = next
                    status = nil
                }
            }
        } catch {
            let failure = settled(error)
            await Self.record(failure, method: endpoint.method.rawValue, path: endpoint.path, status: status, startedAt: startedAt)
            throw failure
        }
    }

    /// A request to `path` with the token, on the address the connection chooses, and the route
    /// it was built for, so a caller that sends it itself can report a lost route.
    func prepare(path: String, query: [URLQueryItem] = []) async throws -> (request: URLRequest, route: ServerConnection.Route) {
        let route = try await connection.route()
        return (try await connection.request(path: path, query: query, token: token, route: route), route)
    }

    /// The answer to a request built here, as URLSession gives it, without reading its status.
    nonisolated func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) } catch { throw settled(error) }
    }

    /// Downloads a request's answer into a temporary file the caller owns. `starting` sees the
    /// task before it runs.
    nonisolated func download(_ request: URLRequest, starting: (@Sendable (URLSessionTask) -> Void)? = nil) async throws -> (URL, URLResponse) {
        do { return try await streaming.download(for: request, starting: starting) } catch { throw settled(error) }
    }

    /// Sends a request whose answer is read as it arrives, once its status says it succeeded.
    /// Otherwise the start of its body is read to tell what refused it, and that is thrown.
    nonisolated func stream(_ request: URLRequest, path: String) async throws -> (HTTPURLResponse, ResponseBody) {
        do {
            let (response, body) = try await streaming.stream(for: request)
            guard let http = response as? HTTPURLResponse else { throw ServerFailure.undecodable }
            if !(200..<300).contains(http.statusCode) {
                var start = Data()
                for try await chunk in body {
                    start.append(chunk)
                    if start.count >= 64 * 1024 { break }
                }
                try ServerFailure.check(http, body: start, path: path)
            }
            return (http, body)
        } catch { throw settled(error) }
    }

    /// A WebSocket for a request built here, not yet resumed.
    nonisolated func webSocket(with request: URLRequest) throws -> URLSessionWebSocketTask {
        guard let task = streaming.webSocketTask(with: request) else { throw CancellationError() }
        return task
    }

    /// URLSession ends a cancelled task with URLError.cancelled. When the caller was cancelled, or
    /// the transport shut down, that is a cancellation and nothing more.
    private nonisolated func settled(_ error: any Error) -> any Error {
        guard (error as? URLError)?.code == .cancelled, Task.isCancelled || isShutDown else { return error }
        return CancellationError()
    }

    static func record(_ error: any Error, method: String, path: String, status: Int?, startedAt: Date) async {
        let outcome: DiagnosticOutcome
        if error is ReadOnlyPolicy.ReadOnlyError { outcome = .blocked }
        else if error is CancellationError || (error as? URLError)?.code == .cancelled { outcome = .cancelled }
        else { outcome = .failed }
        await DiagnosticsStore.shared.record(method: method, path: path, statusCode: status, startedAt: startedAt, outcome: outcome)
    }
}

/// The lines of a streamed answer, split at line feeds, without their line endings. A line longer
/// than the limit fails the stream rather than filling memory.
struct ResponseLines: AsyncSequence, Sendable {
    typealias Element = Data
    let body: ResponseBody
    let limit: Int
    let tooLong: @Sendable () -> any Error

    struct AsyncIterator: AsyncIteratorProtocol {
        var chunks: ResponseBody.AsyncIterator
        let limit: Int
        let tooLong: @Sendable () -> any Error
        /// Bytes received, and where the unread ones start. Lines are cut from it without moving
        /// the rest, which is rebased once per arriving piece.
        var buffer = Data()
        var cursor = 0
        var finished = false

        mutating func next() async throws -> Data? { try await next(isolation: nil) }

        mutating func next(isolation actor: isolated (any Actor)?) async throws -> Data? {
            while true {
                if let end = buffer[cursor...].firstIndex(of: 0x0A) {
                    let line = Self.line(buffer[cursor..<end])
                    cursor = buffer.index(after: end)
                    guard line.count <= limit else { throw tooLong() }
                    return line
                }
                guard buffer.endIndex - cursor <= limit else { throw tooLong() }
                if finished {
                    guard cursor < buffer.endIndex else { return nil }
                    defer { cursor = buffer.endIndex }
                    return Self.line(buffer[cursor...])
                }
                guard let chunk = try await chunks.next(isolation: actor) else { finished = true; continue }
                var rest = Data(buffer[cursor...])
                rest.append(chunk)
                buffer = rest
                cursor = buffer.startIndex
            }
        }

        /// A line without a carriage return before its line feed.
        private static func line(_ bytes: Data.SubSequence) -> Data {
            bytes.last == 0x0D ? Data(bytes.dropLast()) : Data(bytes)
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(chunks: body.makeAsyncIterator(), limit: limit, tooLong: tooLong) }
}

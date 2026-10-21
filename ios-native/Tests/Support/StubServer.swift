import Foundation
import Synchronization
import XCTest

/// A fake server for one test, behind URLProtocol. Each server answers on its own host, so tests
/// never share routes. Routes are matched by method and path below /api; their answers are used
/// in order and the last one repeats. An answer can wait for a gate the test opens, or for a
/// delay. Unrouted requests get a 404 with an Immich error body.
final class StubServer: Sendable {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        /// The request fails without a response, as a lost network does.
        var failure: URLError.Code?
        var delay: Duration?
        var gate: Gate?
        /// Delivers the body this many bytes at a time, as a network would.
        var pieceSize: Int?

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
        }

        static func json<T: Encodable>(_ value: T, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], body: (try? JSONEncoder().encode(value)) ?? Data())
        }

        static func empty(_ status: Int = 204) -> Response { Response(status: status) }

        /// An error from Immich itself: a JSON body with a message and the correlation header,
        /// as the server's GlobalExceptionFilter writes them.
        static func immichError(_ status: Int, message: String) -> Response {
            let body = (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data()
            return Response(status: status, headers: ["Content-Type": "application/json", "X-Correlation-ID": UUID().uuidString.lowercased()], body: body)
        }

        /// A refusal from a proxy in front of the server: an HTML page, no Immich body.
        static func proxyError(_ status: Int) -> Response {
            let title = switch status {
            case 401: "401 Authorization Required"
            case 403: "403 Forbidden"
            case 407: "407 Proxy Authentication Required"
            default: "\(status) Error"
            }
            var headers = ["Content-Type": "text/html"]
            if status == 401 { headers["WWW-Authenticate"] = "Basic realm=\"Restricted\"" }
            if status == 407 { headers["Proxy-Authenticate"] = "Basic realm=\"Proxy\"" }
            let page = "<html>\r\n<head><title>\(title)</title></head>\r\n<body>\r\n<center><h1>\(title)</h1></center>\r\n<hr><center>nginx</center>\r\n</body>\r\n</html>\r\n"
            return Response(status: status, headers: headers, body: Data(page.utf8))
        }

        static func transportFailure(_ code: URLError.Code) -> Response { Response(status: 0, failure: code) }

        func delayed(by delay: Duration) -> Response { var copy = self; copy.delay = delay; return copy }
        func waiting(for gate: Gate) -> Response { var copy = self; copy.gate = gate; return copy }
        func inPieces(of size: Int) -> Response { var copy = self; copy.pieceSize = size; return copy }
    }

    /// Holds answers back until the test opens it. Opening is permanent.
    final class Gate: Sendable {
        private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

        init() {}

        func open() {
            let waiters = state.withLock { state in
                state.open = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let open = state.withLock { state in
                    if !state.open { state.waiters.append(continuation) }
                    return state.open
                }
                if open { continuation.resume() }
            }
        }

        /// How many answers are held back.
        var waiting: Int { state.withLock { $0.waiters.count } }
    }

    /// A request as the server saw it.
    struct Request: Sendable {
        let method: String
        /// The path below /api, without a leading slash.
        let path: String
        let query: [URLQueryItem]
        let headers: [String: String]
        let body: Data?
    }

    let host: String
    private let state = Mutex<(routes: [String: [Response]], requests: [Request])>(([:], []))

    init() {
        host = "stub-" + UUID().uuidString.lowercased() + ".test"
        Self.servers.withLock { $0[host] = self }
    }

    /// The server's API address, as a saved session would hold it.
    var baseURL: URL { URL(string: "https://\(host)/api")! }

    /// A configuration whose requests reach this server and every other stub.
    func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    func route(_ method: String, _ path: String, _ responses: Response...) {
        route(method, path, responses: responses)
    }

    func route(_ method: String, _ path: String, responses: [Response]) {
        state.withLock { $0.routes[Self.key(method, path)] = responses }
    }

    var requests: [Request] { state.withLock { $0.requests } }
    func requests(_ method: String, _ path: String) -> [Request] {
        requests.filter { $0.method == method.uppercased() && $0.path == path }
    }

    /// Stops answering. Requests to the host fail afterwards.
    func stop() { _ = Self.servers.withLock { $0.removeValue(forKey: host) } }

    fileprivate func answer(_ request: URLRequest) -> Response {
        let recorded = Self.record(request)
        return state.withLock { state in
            state.requests.append(recorded)
            let key = Self.key(recorded.method, recorded.path)
            guard var responses = state.routes[key], let first = responses.first else {
                return Response.immichError(404, message: "Not found")
            }
            if responses.count > 1 { responses.removeFirst(); state.routes[key] = responses }
            return first
        }
    }

    fileprivate static let servers = Mutex<[String: StubServer]>([:])

    private static func key(_ method: String, _ path: String) -> String {
        method.uppercased() + " " + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func record(_ request: URLRequest) -> Request {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        var path = components?.path ?? ""
        if path.hasPrefix("/api/") { path.removeFirst(5) } else if path.hasPrefix("/") { path.removeFirst() }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        }
        return Request(method: request.httpMethod ?? "GET", path: path, query: components?.queryItems ?? [],
                       headers: request.allHTTPHeaderFields ?? [:], body: body)
    }
}

extension XCTestCase {
    /// A stub server that stops when the test ends.
    func makeStubServer() -> StubServer {
        let server = StubServer()
        addTeardownBlock { server.stop() }
        return server
    }
}

/// Serves requests to registered stub hosts.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private let delivery = Mutex<Task<Void, Never>?>(nil)

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return StubServer.servers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host, let server = StubServer.servers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = server.answer(request)
        // URLProtocol isn't Sendable, but its client may be called from any thread.
        nonisolated(unsafe) let connection = self
        let task = Task {
            if let gate = response.gate { await gate.wait() }
            if let delay = response.delay { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            connection.deliver(response)
        }
        delivery.withLock { $0 = task }
    }

    override func stopLoading() {
        delivery.withLock { $0?.cancel() }
    }

    private func deliver(_ response: Response) {
        if let failure = response.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        guard let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        var start = response.body.startIndex
        while start < response.body.endIndex {
            let end = response.body.index(start, offsetBy: response.pieceSize ?? response.body.count, limitedBy: response.body.endIndex) ?? response.body.endIndex
            client?.urlProtocol(self, didLoad: response.body[start..<end])
            start = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private typealias Response = StubServer.Response
}

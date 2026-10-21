import Foundation
import Network
import Synchronization

/// A plain HTTP/1.1 server on the loopback interface, for tests that need a real connection: a
/// redirect as URLSession follows it, or an answer too long to hold. Each connection serves one
/// request, answered by the handler, and is closed after the answer.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        /// The path with its query, as the request line had it.
        let target: String
        /// Header names in lower case.
        let headers: [String: String]
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()

        static func json(_ text: String) -> Response {
            Response(status: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
        }

        static func redirect(to location: String) -> Response { Response(status: 302, headers: ["Location": location]) }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.ilyich.tests.loopback-http")
    private let handler: @Sendable (Request) -> Response
    private let state = Mutex<(start: CheckedContinuation<UInt16, any Error>?, requests: [Request], connections: [NWConnection])>((nil, [], []))

    init(handler: @escaping @Sendable (Request) -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    var requests: [Request] { state.withLock { $0.requests } }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.start = continuation }
            listener.stateUpdateHandler = { [weak self] update in self?.listenerChanged(update) }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        for connection in state.withLock({ $0.connections }) { connection.cancel() }
        listener.cancel()
    }

    private func listenerChanged(_ update: NWListener.State) {
        let result: Result<UInt16, any Error>
        switch update {
        case .ready: result = .success(listener.port?.rawValue ?? 0)
        case .failed(let error): result = .failure(error)
        default: return
        }
        let start = state.withLock { state -> CheckedContinuation<UInt16, any Error>? in
            defer { state.start = nil }
            return state.start
        }
        start?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        state.withLock { $0.connections.append(connection) }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                return
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ").map(String.init) ?? []
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let request = Request(method: parts.first ?? "", target: parts.count > 1 ? parts[1] : "", headers: headers)
            self.state.withLock { $0.requests.append(request) }
            self.send(self.handler(request), on: connection)
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized)\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }
}

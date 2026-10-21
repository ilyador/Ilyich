import Foundation
import Network
import Synchronization

/// A WebSocket server on the loopback interface, playing an Engine.IO server: it opens each
/// connection's session and then sends it the same packets. It counts the connections, so a test
/// can tell when a client connects again.
final class LoopbackSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.ilyich.tests.loopback-socket")
    private let packets: [String]
    private let state = Mutex<(start: CheckedContinuation<UInt16, any Error>?, connections: [NWConnection])>((nil, []))

    init(packets: [String]) throws {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.packets = packets
    }

    /// How many connections the server has accepted.
    var connections: Int { state.withLock { $0.connections.count } }

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
        connection.stateUpdateHandler = { [weak self, weak connection] update in
            guard case .ready = update, let self, let connection else { return }
            let open = #"0{"sid":"loopback","upgrades":[],"pingInterval":25000,"pingTimeout":20000}"#
            for packet in [open] + self.packets { self.send(packet, on: connection) }
            self.discardMessages(on: connection)
        }
        connection.start(queue: queue)
    }

    private func send(_ text: String, on connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "packet", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Reads what the client sends, such as its namespace connect, until the connection ends.
    private func discardMessages(on connection: NWConnection) {
        connection.receiveMessage { [weak self] _, _, _, error in
            guard let self, error == nil, case .ready = connection.state else { return }
            self.discardMessages(on: connection)
        }
    }
}

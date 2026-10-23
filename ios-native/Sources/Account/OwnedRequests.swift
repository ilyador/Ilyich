import Foundation
import IlyichPlatform
import Synchronization

/// The requests an account service runs as its own work (REBUILD_ROADMAP.md N4). A change runs in
/// a task the service owns, so it ends the same whether the screen that asked waits, closes or is
/// gone; it is refused in read-only mode before it is sent. A read belongs to the screen that asks
/// and ends with it. Once the service shuts down nothing new starts, and the changes still running
/// are cancelled and waited for.
final class OwnedRequests: Sendable {
    private struct Running {
        let cancel: @Sendable () -> Void
        let done: Task<Void, Never>
    }
    private struct State {
        var open = true
        var running: [UUID: Running] = [:]
    }
    private let state = Mutex(State())
    private let readOnly: @Sendable () -> Bool

    /// `readOnly` says whether read-only mode is on now.
    init(readOnly: @escaping @Sendable () -> Bool) {
        self.readOnly = readOnly
    }

    var isOpen: Bool { state.withLock { $0.open } }

    /// How many changes are on their way.
    var runningCount: Int { state.withLock { $0.running.count } }

    /// A change: refused in read-only mode before it is sent, then run as the service's own work.
    func change<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        if readOnly() { throw ReadOnlyPolicy.ReadOnlyError() }
        let key = UUID()
        let task = state.withLock { state -> Task<T, any Error>? in
            guard state.open else { return nil }
            let task = Task { try await work() }
            state.running[key] = Running(cancel: { task.cancel() }, done: Task { _ = await task.result })
            return task
        }
        guard let task else { throw MutationError.closed }
        defer { _ = state.withLock { $0.running.removeValue(forKey: key) } }
        return try await task.value
    }

    /// A read, for the screen that asks: it ends if that screen goes away.
    func read<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        guard isOpen else { throw MutationError.closed }
        return try await work()
    }

    /// Runs `body` only while the service is open, under the lock, so nothing it does happens once
    /// shutdown has begun.
    func whileOpen(_ body: () -> Void) {
        state.withLock { state in if state.open { body() } }
    }

    /// Nothing new starts; the changes still running are cancelled and waited for.
    func shutdown() async {
        let running = state.withLock { state -> [Running] in
            state.open = false
            defer { state.running = [:] }
            return Array(state.running.values)
        }
        for work in running { work.cancel() }
        for work in running { await work.done.value }
    }
}

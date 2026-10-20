import Foundation
import Synchronization

/// A clock that moves only when the test says so. Sleepers wake in deadline order once
/// `advance` passes their deadline, and a cancelled sleeper throws CancellationError at once.
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol, CustomStringConvertible {
        /// Time since the clock started.
        let offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
        var description: String { "TestClock.Instant(\(offset))" }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    init() {}

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// How many tasks are asleep on this clock.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has come, earliest first.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits, in real time, until at least `count` tasks sleep on this clock, so a test advances
    /// only once its subject is waiting.
    func waitForSleepers(_ count: Int = 1, timeout: Duration = .seconds(5)) async throws {
        let limit = ContinuousClock.now.advanced(by: timeout)
        while sleeperCount < count {
            guard ContinuousClock.now < limit else { throw TimeoutError(expected: count, sleeping: sleeperCount) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    struct TimeoutError: Error, CustomStringConvertible {
        let expected: Int
        let sleeping: Int
        var description: String { "Expected \(expected) sleepers on the test clock, found \(sleeping)." }
    }
}

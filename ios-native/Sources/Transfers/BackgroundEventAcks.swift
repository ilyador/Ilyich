import Foundation
import os

private let logger = Logger(subsystem: "app.ilyich.native", category: "Transfers")

/// The completion handlers iOS passes to application(_:handleEventsForBackgroundURLSession:
/// completionHandler:). iOS suspends the app once a handler runs, so each runs only after the
/// engine has durably committed what its session delivered, or after a 20-second deadline,
/// whichever comes first; iOS allows about 30. Dormant until B9, whose app delegate registers the
/// handler first and only then touches the session.
///
/// A session can drain before iOS hands over its handler, when the session already existed. The
/// engine's commit for that drain is remembered, and a handler registered within the deadline is
/// answered at once instead of waiting it out. An identifier this app never created is answered
/// at once.
@MainActor final class BackgroundEventAcks<C: Clock> where C.Duration == Duration {
    private struct Waiter {
        let id: UInt64
        let completion: @MainActor () -> Void
        let deadline: Task<Void, Never>
    }

    private let clock: C
    private let deadline: Duration
    private let isKnown: (String) -> Bool
    private var waiters: [String: [Waiter]] = [:]
    /// Commits that came while no handler waited, by when.
    private var unclaimedCommits: [String: C.Instant] = [:]
    private var nextID: UInt64 = 0

    init(clock: C, deadline: Duration = .seconds(20), isKnown: @escaping (String) -> Bool = { TransferSessionID(identifier: $0) != nil }) {
        self.clock = clock
        self.deadline = deadline
        self.isKnown = isKnown
    }

    /// How many handlers wait.
    var waiting: Int { waiters.values.reduce(0) { $0 + $1.count } }

    /// Takes iOS's completion handler for a session's events. Call it before touching the session.
    func register(identifier: String, completion: @escaping @MainActor () -> Void) {
        guard isKnown(identifier) else {
            completion()
            return
        }
        if let committed = unclaimedCommits.removeValue(forKey: identifier), committed.duration(to: clock.now) <= deadline {
            completion()
            return
        }
        nextID += 1
        let id = nextID
        let timer = Task { [clock, deadline] in
            do { try await clock.sleep(for: deadline) } catch { return }
            self.expire(identifier, id)
        }
        waiters[identifier, default: []].append(Waiter(id: id, completion: completion, deadline: timer))
    }

    /// The engine has durably committed every outcome the session delivered up to its latest drain.
    func committed(identifier: String) {
        guard let answered = waiters.removeValue(forKey: identifier), !answered.isEmpty else {
            unclaimedCommits[identifier] = clock.now
            return
        }
        for waiter in answered {
            waiter.deadline.cancel()
            waiter.completion()
        }
    }

    private func expire(_ identifier: String, _ id: UInt64) {
        guard var list = waiters[identifier], let index = list.firstIndex(where: { $0.id == id }) else { return }
        let waiter = list.remove(at: index)
        waiters[identifier] = list.isEmpty ? nil : list
        logger.notice("Answered iOS for \(identifier, privacy: .public) at the deadline, before a commit")
        waiter.completion()
    }
}

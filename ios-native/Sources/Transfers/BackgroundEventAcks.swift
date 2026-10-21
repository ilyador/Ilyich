import Foundation
import os

private let logger = Logger(subsystem: "app.ilyich.native", category: "Transfers")

/// The completion handlers iOS passes to application(_:handleEventsForBackgroundURLSession:
/// completionHandler:). iOS suspends the app once a handler runs, so each runs only after the
/// engine has durably committed what its session delivered, or after a 20-second deadline,
/// whichever comes first; iOS allows about 30. Dormant until B9, whose app delegate registers the
/// handler first and only then touches the session.
///
/// A handler belongs to one drain of its session, numbered by the transport, and only a commit
/// through that drain answers it. It waits for the session's next drain, so a commit that comes
/// late, for a drain whose handler the deadline already answered, answers no later handler. A
/// session can drain before iOS hands over its handler, when the session already existed: the next
/// handler takes a drain no handler waited for, and is answered at once if that drain's commit came
/// within the deadline. An identifier this app never created is answered at once.
@MainActor final class BackgroundEventAcks<C: Clock> where C.Duration == Duration {
    private struct Waiter {
        let id: UInt64
        /// The drain whose commit answers it.
        let drain: Int
        let completion: @MainActor () -> Void
        let deadline: Task<Void, Never>
    }

    /// One session's waiting handlers and how far its drains have got.
    private struct Session {
        var waiters: [Waiter] = []
        /// The latest drain a handler waited for or was answered by.
        var claimed = 0
        /// The latest drain the engine committed through, and when it said so.
        var committed = 0
        var committedAt: C.Instant?
    }

    private let clock: C
    private let deadline: Duration
    private let drains: (String) -> Int?
    private var sessions: [String: Session] = [:]
    private var nextID: UInt64 = 0

    /// `drains` says how many times the session an identifier names has drained in this process, or
    /// nil for an identifier this app never created: TransportRegistry.drains(identifier:).
    init(clock: C, deadline: Duration = .seconds(20), drains: @escaping (String) -> Int?) {
        self.clock = clock
        self.deadline = deadline
        self.drains = drains
    }

    /// How many handlers wait.
    var waiting: Int { sessions.values.reduce(0) { $0 + $1.waiters.count } }

    /// Takes iOS's completion handler for a session's events. Call it before touching the session.
    func register(identifier: String, completion: @escaping @MainActor () -> Void) {
        guard let drained = drains(identifier) else {
            completion()
            return
        }
        var session = sessions[identifier] ?? Session()
        // The handler waits for the next drain, unless the session drained while no handler waited:
        // iOS delivered this launch's events before handing the handler over.
        var drain = drained + 1
        if drained > session.claimed {
            if drained > session.committed {
                drain = drained
            } else if let committedAt = session.committedAt, committedAt.duration(to: clock.now) <= deadline {
                session.claimed = drained
                sessions[identifier] = session
                completion()
                return
            }
        }
        session.claimed = max(session.claimed, drain)
        nextID += 1
        let id = nextID
        let timer = Task { [clock, deadline] in
            do { try await clock.sleep(for: deadline) } catch { return }
            self.expire(identifier, id)
        }
        session.waiters.append(Waiter(id: id, drain: drain, completion: completion, deadline: timer))
        sessions[identifier] = session
    }

    /// The engine has durably committed every outcome the session delivered up to the drain its
    /// drained event numbered. Answers the handlers waiting for that drain or an earlier one.
    func committed(identifier: String, through drain: Int) {
        var session = sessions[identifier] ?? Session()
        if drain > session.committed {
            session.committed = drain
            session.committedAt = clock.now
        }
        let answered = session.waiters.filter { $0.drain <= drain }
        session.waiters.removeAll { $0.drain <= drain }
        sessions[identifier] = session
        for waiter in answered {
            waiter.deadline.cancel()
            waiter.completion()
        }
    }

    private func expire(_ identifier: String, _ id: UInt64) {
        guard let index = sessions[identifier]?.waiters.firstIndex(where: { $0.id == id }),
              let waiter = sessions[identifier]?.waiters.remove(at: index) else { return }
        logger.notice("Answered iOS for \(identifier, privacy: .public) at the deadline, before a commit")
        waiter.completion()
    }
}

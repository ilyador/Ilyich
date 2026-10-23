import Foundation
import Synchronization

/// One thing that happened to an account's library, as its bus carries it (REBUILD_ROADMAP.md N4).
enum LibraryEvent: Sendable {
    /// A change the account's sync published, once media has taken it in. `accessChanged` says
    /// the account may have lost access to photos, so a photo on screen is confirmed before it
    /// stays.
    case changed(LibraryChange, accessChanged: Bool)
    /// A library mutation's result (N2): the server's answer, then the same result with the
    /// follow-up sync's change.
    case mutation(MutationEvent)
    /// One of the account's albums, people, partners or memories changed on the server.
    case collection(CollectionChange)
    /// The account's downloaded previews were cleared, from Diagnostics.
    case cachesCleared
}

/// An account's library events, in one order for every subscriber (REBUILD_ROADMAP.md N4): its
/// sync's changes, its mutations' results, its collections' changes and a cleared cache. It
/// replaces the notification dictionaries the screens used to observe. AccountRuntime makes one per
/// account and closes it first at teardown, so nothing the account does afterwards reaches a
/// screen. Posting never waits: each subscriber has a mailbox that keeps every event in order and
/// folds sync changes it hasn't taken yet, one after another, into one, so a slow subscriber still
/// sees every effect and none is dropped.
final class LibraryBus: Sendable {
    private struct State {
        var open = true
        var mailboxes: [UUID: LibraryEventMailbox] = [:]
    }
    private let state = Mutex(State())

    init() {}

    /// Hands `event` to every subscriber. Ignored once the bus is closed.
    func post(_ event: LibraryEvent) {
        // Under the lock, so every subscriber hears every event in one order.
        state.withLock { state in
            guard state.open else { return }
            for mailbox in state.mailboxes.values { mailbox.put(event) }
        }
    }

    /// Every event posted from now on, until the bus closes or the stream is let go.
    func events() -> AsyncStream<LibraryEvent> { subscribe { $0 } }

    /// The events `transform` keeps, as it maps them; an event it maps to nil is never queued.
    func subscribe<Value: Sendable>(_ transform: @escaping @Sendable (LibraryEvent) -> Value?) -> AsyncStream<Value> {
        let mailbox = LibraryEventMailbox(keeps: { transform($0) != nil })
        let id = UUID()
        let subscribed = state.withLock { state -> Bool in
            guard state.open else { return false }
            state.mailboxes[id] = mailbox
            return true
        }
        if !subscribed { mailbox.close() }
        return AsyncStream(unfolding: {
            while let event = await mailbox.next() {
                if let value = transform(event) { return value }
            }
            return nil
        }, onCancel: { [weak self] in
            mailbox.close()
            self?.unsubscribe(id)
        })
    }

    /// Ends every subscriber's stream once it has taken what was already posted; later posts are
    /// dropped.
    func close() {
        let mailboxes = state.withLock { state -> [LibraryEventMailbox] in
            state.open = false
            defer { state.mailboxes.removeAll() }
            return Array(state.mailboxes.values)
        }
        for mailbox in mailboxes { mailbox.close() }
    }

    var isOpen: Bool { state.withLock { $0.open } }

    /// How many streams are open: one for each screen or service following the account.
    var subscriberCount: Int { state.withLock { $0.mailboxes.count } }

    private func unsubscribe(_ id: UUID) {
        _ = state.withLock { $0.mailboxes.removeValue(forKey: id) }
    }
}

/// One subscriber's events not yet taken, in order. A sync change put right after another one not
/// yet taken is merged into it.
final class LibraryEventMailbox: Sendable {
    private struct State {
        var pending: [LibraryEvent] = []
        var waiter: CheckedContinuation<LibraryEvent?, Never>?
        var closed = false
    }
    private let state = Mutex(State())
    private let keeps: @Sendable (LibraryEvent) -> Bool

    init(keeps: @escaping @Sendable (LibraryEvent) -> Bool = { _ in true }) {
        self.keeps = keeps
    }

    func put(_ event: LibraryEvent) {
        guard keeps(event) else { return }
        let waiter = state.withLock { state -> CheckedContinuation<LibraryEvent?, Never>? in
            guard !state.closed else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            if case .changed(let later, let laterAccess) = event, case .changed(var earlier, let earlierAccess)? = state.pending.last {
                earlier.merge(later)
                state.pending[state.pending.count - 1] = .changed(earlier, accessChanged: earlierAccess || laterAccess)
            } else {
                state.pending.append(event)
            }
            return nil
        }
        waiter?.resume(returning: event)
    }

    /// Events already put are still taken; after them, nil.
    func close() {
        let waiter = state.withLock { state -> CheckedContinuation<LibraryEvent?, Never>? in
            state.closed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    /// The oldest event not yet taken, waiting for one if there is none. Nil once closed and
    /// emptied, or when the caller is cancelled.
    func next() async -> LibraryEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LibraryEvent?, Never>) in
                let ready = state.withLock { state -> LibraryEvent?? in
                    if !state.pending.isEmpty { return .some(state.pending.removeFirst()) }
                    if state.closed || Task.isCancelled { return .some(nil) }
                    state.waiter = continuation
                    return .none
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            close()
        }
    }
}

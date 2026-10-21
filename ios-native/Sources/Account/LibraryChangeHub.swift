import Foundation
import Synchronization

/// Where an account's library changes go, one per runtime. A change reaches media first, so a
/// screen that reloads never draws what the change took away, then the screens through the
/// legacy notifications, then every subscriber. Each subscriber has a mailbox that folds the
/// changes it hasn't taken yet into one, so a slow subscriber still sees every effect and none is
/// dropped.
actor LibraryChangeHub {
    private let pipeline: MediaPipeline
    private let scope: String
    private var mailboxes: [UUID: LibraryChangeMailbox] = [:]
    private var isOpen = true

    init(pipeline: MediaPipeline, scope: String) {
        self.pipeline = pipeline
        self.scope = scope
    }

    func publish(_ change: LibraryChange, accessChanged: Bool) async {
        guard isOpen, !change.isEmpty else { return }
        await pipeline.apply(change)
        guard isOpen else { return }
        await LegacyNotificationBridge.libraryChanged(change, scope: scope, accessChanged: accessChanged)
        for mailbox in mailboxes.values { mailbox.put(change) }
    }

    /// Every change published from now on, until the account closes.
    func subscribe() -> AsyncStream<LibraryChange> {
        let mailbox = LibraryChangeMailbox()
        let id = UUID()
        if isOpen { mailboxes[id] = mailbox } else { mailbox.close() }
        return AsyncStream(unfolding: { await mailbox.next() }, onCancel: { [weak self] in
            mailbox.close()
            Task { await self?.unsubscribe(id) }
        })
    }

    func close() {
        isOpen = false
        for mailbox in mailboxes.values { mailbox.close() }
        mailboxes.removeAll()
    }

    private func unsubscribe(_ id: UUID) { mailboxes[id] = nil }
}

/// One subscriber's changes not yet taken, merged into one.
final class LibraryChangeMailbox: Sendable {
    private struct State {
        var pending: LibraryChange?
        var waiter: CheckedContinuation<LibraryChange?, Never>?
        var closed = false
    }
    private let state = Mutex(State())

    func put(_ change: LibraryChange) {
        let waiter = state.withLock { state -> CheckedContinuation<LibraryChange?, Never>? in
            guard !state.closed else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            if state.pending == nil { state.pending = change } else { state.pending?.merge(change) }
            return nil
        }
        waiter?.resume(returning: change)
    }

    /// Changes already put are still taken; after them, nil.
    func close() {
        let waiter = state.withLock { state -> CheckedContinuation<LibraryChange?, Never>? in
            state.closed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    /// The changes put since the last call, merged, waiting for one if there are none. Nil once
    /// closed, or when the caller is cancelled.
    func next() async -> LibraryChange? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LibraryChange?, Never>) in
                let ready = state.withLock { state -> LibraryChange?? in
                    if let pending = state.pending {
                        state.pending = nil
                        return .some(pending)
                    }
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

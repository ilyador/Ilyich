import Foundation

/// Posts and withdraws the count-only transfer notifications, as TransferNotifications does today.
@MainActor protocol TransferNotificationPosting: AnyObject {
    func started(id: UUID, kind: String, total: Int) async
    func finished(id: UUID, kind: String, total: Int, completed: Int, failed: Int) async
    func withdraw(id: UUID)
}

/// The system's notifications, through today's TransferNotifications: identifiers
/// transfer.<UUID>, the same words, and its own epoch, which signing out moves.
@MainActor final class SystemTransferNotificationPoster: TransferNotificationPosting {
    func started(id: UUID, kind: String, total: Int) async {
        await TransferNotifications.started(id: id, kind: kind, total: total)
    }

    func finished(id: UUID, kind: String, total: Int, completed: Int, failed: Int) async {
        await TransferNotifications.finished(id: id, kind: kind, total: total, completed: completed, failed: failed)
    }

    func withdraw(id: UUID) { TransferNotifications.cancel(id: id) }
}

/// Turns notification_batches into notifications (B4). Each account's TransferRuntime runs one
/// (B9); today's backup, on the way back, posts its own.
///
/// It watches the database, never the engine's work: the engine wakes it through `changed()`, or a
/// stream of its snapshots, and never waits for it, so a notification that hangs holds up nothing
/// but the next notification. Each batch gets a started notification once, when it has jobs to
/// run, and a last one once, when none is left to run: finished, or needing attention when some
/// failed. The database records each as posted, so neither goes out again after a relaunch; one
/// whose batch finished before its start was posted gets only the last. A batch that finished and
/// then got jobs again (more files approved, a failure retried) starts over: a started
/// notification, then a last one counting the whole batch. A batch whose every job
/// was cancelled is withdrawn quietly. A post that completes after `stop()` (sign-out, the end of
/// the account's runtime) or after the session ended is withdrawn and not recorded.
@MainActor final class TransferNotifier {
    private let store: TransferStore
    private let poster: any TransferNotificationPosting
    private let authorization: any TransferAuthorizing
    private var task: Task<Void, Never>?
    private var wakes: AsyncStream<Void>.Continuation?
    /// Moved by stop(): a post begun under an older value is withdrawn.
    private var epoch: UInt64 = 0

    init(store: TransferStore, poster: any TransferNotificationPosting, authorization: any TransferAuthorizing) {
        self.store = store
        self.poster = poster
        self.authorization = authorization
    }

    /// Starts watching: one read now, then one after each change, merged while a read runs.
    func start() {
        guard task == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wakes = continuation
        continuation.yield()
        task = Task { [weak self] in
            for await _ in stream {
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    /// Something changed: read the batches again soon. Never waits.
    func changed() { wakes?.yield() }

    /// Wakes on every snapshot the engine sends, until the stream ends.
    func follow(_ snapshots: AsyncStream<TransferSnapshot>) -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in snapshots { self?.changed() }
        }
    }

    /// Stops watching. A post under way is withdrawn when it completes.
    func stop() {
        epoch &+= 1
        task?.cancel()
        task = nil
        wakes?.finish()
        wakes = nil
    }

    /// Reads every batch and posts what is due, one at a time.
    func refresh() async {
        let started = epoch
        guard let batches = try? await store.notificationBatches() else { return }
        for batch in batches {
            guard started == epoch, !Task.isCancelled else { return }
            if batch.isFinished {
                guard !batch.terminalPosted else { continue }
                // Jobs left failed count as failures; a legacy batch that ended before its last
                // notification carries its own count.
                let failed = max(batch.failedJobs, batch.recordedFailures ?? 0)
                let total = batch.completed + failed
                if total == 0 {
                    // Every job was cancelled: nothing to report.
                    poster.withdraw(id: batch.id)
                } else {
                    guard authorization.current() != nil else { return }
                    await poster.finished(id: batch.id, kind: batch.kind.title, total: total, completed: batch.completed, failed: failed)
                    guard posted(batch.id, since: started) else { return }
                }
                try? await store.markTerminalPosted(batch.id, failed: failed)
            } else if batch.terminalPosted || !batch.startedPosted {
                // Finished once, and given jobs again: it starts over. The store reopens it when it
                // requeues; this catches any other way a job comes back.
                if batch.terminalPosted { try? await store.reopenNotificationBatch(batch.id) }
                guard authorization.current() != nil else { return }
                await poster.started(id: batch.id, kind: batch.kind.title, total: batch.total)
                guard posted(batch.id, since: started) else { return }
                try? await store.markStartedPosted(batch.id)
            }
        }
        if started == epoch { _ = try? await store.pruneNotificationBatches() }
    }

    /// Whether a post begun at `epoch` still stands: otherwise it is withdrawn.
    private func posted(_ id: UUID, since started: UInt64) -> Bool {
        guard started == epoch, authorization.current() != nil else {
            poster.withdraw(id: id)
            return false
        }
        return true
    }
}

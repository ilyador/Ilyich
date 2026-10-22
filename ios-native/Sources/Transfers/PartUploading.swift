import Foundation
import Synchronization

/// How the library job executor hands a part's body to the background transport and learns how
/// its upload ended (B3). The real one runs over a background session's transport and its events
/// (TransferRuntime); tests use a fake.
protocol PartUploading: Sendable {
    /// Hands the attempt's body to the transport and returns the task's ID. A task iOS still holds
    /// for the attempt is adopted rather than sent again.
    func submit(_ request: URLRequest, key: AttemptKey) async throws -> Int
    /// The attempt's outcome file, if one is on disk: a result nobody applied yet.
    func recordedOutcome(for key: AttemptKey) throws -> OutcomeRecord?
    /// Waits for a submitted attempt's outcome, reporting the bytes sent as they go. Throws
    /// UploadOutcomeFailure.unrecorded when the transport could not record it.
    func outcome(for key: AttemptKey, progress: @escaping @Sendable (_ sent: Int64, _ expected: Int64) -> Void) async throws -> OutcomeRecord
    /// Deletes the attempt's outcome file, and its body unless `keepingBody`, once what it says is
    /// committed.
    func acknowledge(_ key: AttemptKey, keepingBody: Bool) throws
    /// Whether iOS still holds a live task for the attempt, sent by this build or an earlier one.
    func holdsTask(for attempt: AttemptID) async -> Bool
}

extension PartUploading {
    func holdsTask(for attempt: AttemptID) async -> Bool { false }
}

/// A part's upload ended without a receipt.
enum UploadOutcomeFailure: Error, Equatable, Sendable, LocalizedError {
    /// The outcome file's record: an HTTP status, an error, or neither.
    case failed(OutcomeRecord)
    /// Nothing durable says how the task ended. Never a success: the part is checked again.
    case unrecorded(String)

    var errorDescription: String? {
        switch self {
        case .failed(let record):
            if let status = record.httpStatus { return "The server answered the upload with HTTP \(status)." }
            return record.error ?? "The upload was interrupted."
        case .unrecorded: return "The upload’s result could not be saved on the phone."
        }
    }
}

/// PartUploading over one background session's transport and the events it reports.
final class TransportPartUploader: PartUploading {
    private let transport: any TransferTransport
    private let outcomes: TransportOutcomes

    init(transport: any TransferTransport, outcomes: TransportOutcomes) {
        self.transport = transport
        self.outcomes = outcomes
    }

    func submit(_ request: URLRequest, key: AttemptKey) async throws -> Int {
        try await transport.submit(request, key: key)
    }

    func recordedOutcome(for key: AttemptKey) throws -> OutcomeRecord? {
        try transport.outcome(for: key)
    }

    func outcome(for key: AttemptKey, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> OutcomeRecord {
        let transport = self.transport
        let journal = try await outcomes.wait(for: key.attempt, progress: progress) { try transport.outcome(for: key) }
        switch journal {
        case .recorded(let record): return record
        case .unrecorded(let reason): throw UploadOutcomeFailure.unrecorded(reason)
        }
    }

    func acknowledge(_ key: AttemptKey, keepingBody: Bool) throws {
        try transport.acknowledge(key, keepingBody: keepingBody)
    }

    func holdsTask(for attempt: AttemptID) async -> Bool {
        await transport.inventory().task(for: attempt) != nil
    }
}

/// Matches the transport's finished events to the attempts waiting for them. An event that comes
/// before anyone waits is kept for a while, and a waiter also reads the outcome file, which the
/// transport writes before it reports a task finished, so no result is missed whatever the order.
final class TransportOutcomes: Sendable {
    /// Finished events kept for attempts nobody waits for yet.
    static let kept = 256

    private struct State {
        var finished: [AttemptID: TransportCompletion.Journal] = [:]
        var order: [AttemptID] = []
        var waiters: [AttemptID: (id: UUID, continuation: CheckedContinuation<TransportCompletion.Journal, any Error>)] = [:]
        var progress: [AttemptID: @Sendable (Int64, Int64) -> Void] = [:]
    }

    private let state = Mutex(State())
    private let consumer = Mutex<Task<Void, Never>?>(nil)

    /// Reads `events` until they end or this is shut down.
    init(events: AsyncStream<TransportEvent>) {
        let task = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.receive(event)
            }
        }
        consumer.withLock { $0 = task }
    }

    deinit { consumer.withLock { $0?.cancel() } }

    func shutdown() { consumer.withLock { $0?.cancel() } }

    /// Waits for the attempt's outcome: a finished event, or the outcome file `recorded` reads.
    func wait(for attempt: AttemptID, progress: @escaping @Sendable (Int64, Int64) -> Void,
              recorded: @escaping @Sendable () throws -> OutcomeRecord?) async throws -> TransportCompletion.Journal {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransportCompletion.Journal, any Error>) in
                enum Start { case done(TransportCompletion.Journal), cancelled, waiting }
                let start = state.withLock { state -> Start in
                    if Task.isCancelled { return .cancelled }
                    if let journal = state.finished.removeValue(forKey: attempt) {
                        state.order.removeAll { $0 == attempt }
                        return .done(journal)
                    }
                    // One waiter per attempt: the executor has one lease on its job.
                    state.waiters[attempt]?.continuation.resume(throwing: CancellationError())
                    state.waiters[attempt] = (id, continuation)
                    state.progress[attempt] = progress
                    return .waiting
                }
                switch start {
                case .done(let journal): return continuation.resume(returning: journal)
                case .cancelled: return continuation.resume(throwing: CancellationError())
                case .waiting: break
                }
                // The file is written before the event is sent: one already on disk answers now.
                let onDisk: Result<OutcomeRecord?, any Error> = Result { try recorded() }
                switch onDisk {
                case .success(nil): return
                case .success(let record?): self.finish(attempt, id: id, with: .success(.recorded(record)))
                case .failure(let error): self.finish(attempt, id: id, with: .failure(error))
                }
            }
        } onCancel: {
            self.finish(attempt, id: id, with: .failure(CancellationError()))
        }
    }

    private func receive(_ event: TransportEvent) {
        switch event {
        case .progress(_, let progress):
            let handler = state.withLock { $0.progress[progress.attempt] }
            handler?(progress.sent, progress.expected)
        case .finished(_, let completion):
            let waiter = state.withLock { state -> CheckedContinuation<TransportCompletion.Journal, any Error>? in
                if let waiter = state.waiters.removeValue(forKey: completion.attempt) {
                    state.progress[completion.attempt] = nil
                    return waiter.continuation
                }
                if state.finished.updateValue(completion.journal, forKey: completion.attempt) == nil { state.order.append(completion.attempt) }
                if state.order.count > Self.kept { state.finished[state.order.removeFirst()] = nil }
                return nil
            }
            waiter?.resume(returning: completion.journal)
        case .drained:
            break
        }
    }

    /// Ends the wait `id` for the attempt, if it still waits.
    private func finish(_ attempt: AttemptID, id: UUID, with result: Result<TransportCompletion.Journal, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<TransportCompletion.Journal, any Error>? in
            guard state.waiters[attempt]?.id == id else { return nil }
            state.progress[attempt] = nil
            return state.waiters.removeValue(forKey: attempt)?.continuation
        }
        waiter?.resume(with: result)
    }
}

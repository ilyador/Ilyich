import Foundation
import IlyichPlatform
import os
import Synchronization

/// One background URLSession for one TransferSessionID, backup or share-upload, which TransferHost
/// creates once the process runs the transfer engine (B9).
///
/// New tasks get a version 2 descriptor. A task iOS still holds for an attempt, from this launch or
/// an earlier one, is adopted by its attempt rather than sent again. A task a build before B9
/// described is never adopted (B10): recovery cancels it.
final class BackgroundTransport: TransferTransport {
    let session: TransferSessionID
    private let tasks: any TransportSession
    private let journal: any OutcomeJournaling
    private let events: TransportEventProcessor
    private let submitting = Mutex<Set<AttemptID>>([])

    /// `makeSession` is handed the event handler that the session's delegate must call.
    init(session: TransferSessionID, journal: any OutcomeJournaling, emit: @escaping @Sendable (TransportEvent) -> Void,
         uptime: @escaping @Sendable () -> Duration = BackgroundTransport.uptime,
         makeSession: (any TaskEventHandling) -> any TransportSession) {
        self.session = session
        self.journal = journal
        events = TransportEventProcessor(session: session, journal: journal, emit: emit, uptime: uptime)
        tasks = makeSession(events)
    }

    /// How many times the session has drained in this process: the number of its latest drained event.
    var drains: Int { events.drains }

    /// The real transport for a session, recording outcomes in the App Group.
    static func live(_ session: TransferSessionID, emit: @escaping @Sendable (TransportEvent) -> Void) -> BackgroundTransport {
        BackgroundTransport(session: session, journal: FileOutcomeJournal(layout: try? AppGroupLayout.current()), emit: emit) {
            URLSessionTransportSession(session, handler: $0)
        }
    }

    func submit(_ request: URLRequest, key: AttemptKey) async throws(TransportSubmitError) -> Int {
        guard key.isValid, let description = key.descriptor.taskDescription else { throw .invalidKey }
        guard submitting.withLock({ $0.insert(key.attempt).inserted }) else { throw .alreadySubmitting }
        defer { submitting.withLock { _ = $0.remove(key.attempt) } }
        let held = await inventory().tasks(for: key.attempt)
        if let live = held.first(where: \.isLive) {
            await tasks.resumeTask(live.taskID)
            return live.taskID
        }
        // A cancelled or finished task writes its outcome to the attempt's file once iOS reports it,
        // so a new task beside it would have its result overwritten or mistaken for the old one's.
        guard held.isEmpty else { throw .outcomePending }
        // A new task would overwrite an outcome nobody applied, or a stale one would be read as its result.
        guard !journal.exists(key.outcomePath) else { throw .unacknowledgedOutcome }
        guard let body = journal.url(for: key.bodyPath) else { throw .unavailable }
        guard FileManager.default.fileExists(atPath: body.path) else { throw .missingBody }
        return tasks.startUpload(request, fromFile: body, description: description)
    }

    func outcome(for key: AttemptKey) throws -> OutcomeRecord? { try journal.read(key.outcomePath) }

    func acknowledge(_ key: AttemptKey, keepingBody: Bool) throws {
        try journal.remove(key.outcomePath)
        if !keepingBody { try journal.remove(key.bodyPath) }
    }

    func inventory() async -> TransportInventory {
        TransportInventory(session: session, tasks: await tasks.tasks().map {
            TransportTaskSnapshot(taskID: $0.id, descriptor: TaskDescriptor(taskDescription: $0.description), state: $0.state,
                                  sent: $0.sent, expected: $0.expected)
        })
    }

    func cancel(scope: String) async -> Int {
        let matching = await inventory().tasks(scope: scope).filter(\.isLive)
        for task in matching { await tasks.cancelTask(task.taskID) }
        return matching.count
    }

    func cancel(tasks ids: [Int]) async {
        for id in ids { await tasks.cancelTask(id) }
    }

    /// Monotonic time, for throttling progress.
    static func uptime() -> Duration { ContinuousClock.now - origin }
    private static let origin = ContinuousClock.now
}

/// The delegate's work for one session, on its serial delegate queue. It buffers each answer up to
/// 64 KiB and cancels a task whose answer is larger, writes a finished task's outcome file before
/// reporting it, reports progress at most four times a second per task and reports the session
/// drained, with the drain's number, once iOS has delivered everything it queued.
final class TransportEventProcessor: TaskEventHandling {
    /// Upload answers are small JSON. An arbitrary answer is never buffered.
    static let responseLimit = 64 * 1024
    static let progressInterval: Duration = .milliseconds(250)

    let session: TransferSessionID
    private let journal: any OutcomeJournaling
    private let emit: @Sendable (TransportEvent) -> Void
    private let uptime: @Sendable () -> Duration

    private struct State {
        var responses: [Int: Data] = [:]
        var oversized: Set<Int> = []
        var progressSentAt: [Int: Duration] = [:]
        var drains = 0
    }
    private let state = Mutex(State())
    private static let logger = Logger(subsystem: "app.ilyich.native", category: "Transfers")

    init(session: TransferSessionID, journal: any OutcomeJournaling, emit: @escaping @Sendable (TransportEvent) -> Void,
         uptime: @escaping @Sendable () -> Duration) {
        self.session = session
        self.journal = journal
        self.emit = emit
        self.uptime = uptime
    }

    func task(_ id: Int, didReceive data: Data) -> Bool {
        state.withLock { state in
            guard !state.oversized.contains(id) else { return false }
            guard (state.responses[id]?.count ?? 0) + data.count <= Self.responseLimit else {
                state.responses[id] = nil
                state.oversized.insert(id)
                return false
            }
            state.responses[id, default: Data()].append(data)
            return true
        }
    }

    func task(_ id: Int, description: String?, didSend sent: Int64, of expected: Int64) {
        let now = uptime()
        let due = state.withLock { state in
            let last = expected > 0 && sent >= expected
            if !last, let previous = state.progressSentAt[id], now - previous < Self.progressInterval { return false }
            state.progressSentAt[id] = now
            return true
        }
        guard due, let attempt = TaskDescriptor(taskDescription: description).attempt else { return }
        emit(.progress(session, TransportProgress(taskID: id, attempt: attempt, sent: sent, expected: expected)))
    }

    func taskDidComplete(_ task: CompletedTask) {
        let (response, oversized) = state.withLock { state in
            state.progressSentAt[task.id] = nil
            return (state.responses.removeValue(forKey: task.id) ?? Data(), state.oversized.remove(task.id) != nil)
        }
        let descriptor = TaskDescriptor(taskDescription: task.description)
        guard let attempt = descriptor.attempt else {
            Self.logger.error("Task \(task.id) of \(self.session.rawValue, privacy: .public) ended without a description this build wrote")
            return
        }
        let outcome = Self.outcome(of: task, response: response, oversized: oversized)
        let journal: TransportCompletion.Journal
        if let path = descriptor.outcomePath {
            do {
                try self.journal.write(outcome, to: path)
                journal = .recorded(outcome)
            } catch {
                Self.logger.error("Outcome of task \(task.id) of \(self.session.rawValue, privacy: .public) not recorded: \(error.localizedDescription, privacy: .public)")
                journal = .unrecorded(reason: error.localizedDescription)
            }
        } else {
            journal = .unrecorded(reason: "The task’s outcome file is outside the App Group.")
        }
        emit(.finished(session, TransportCompletion(taskID: task.id, attempt: attempt, outcomePath: descriptor.outcomePath, journal: journal)))
    }

    /// How many times the session has drained in this process.
    var drains: Int { state.withLock { $0.drains } }

    func sessionDidFinishEvents() {
        // Counted before it is reported, so whoever reads the count after the event sees it.
        let drain = state.withLock { state in
            state.drains += 1
            return state.drains
        }
        emit(.drained(session, drain: drain))
    }

    /// What a finished task's outcome file says: what happened, unclassified. The engine classifies.
    static func outcome(of task: CompletedTask, response: Data, oversized: Bool) -> OutcomeRecord {
        // Another server's answer is never the upload's: a receipt from it confirms nothing, and its
        // status would read as this server's (a 401 as being signed out, even in older builds).
        guard !task.leftOrigin else {
            return OutcomeRecord(error: "The upload was redirected to another server.", errorDomain: TransportOutcomeCode.domain,
                                 errorCode: TransportOutcomeCode.redirected.rawValue, v: OutcomeRecord.version)
        }
        var outcome = OutcomeRecord(httpStatus: task.httpStatus, v: OutcomeRecord.version)
        if oversized {
            outcome.error = "The server’s answer was too large to read."
            outcome.errorDomain = TransportOutcomeCode.domain
            outcome.errorCode = TransportOutcomeCode.responseTooLarge.rawValue
        } else if let failure = task.failure {
            outcome.error = failure.description
            outcome.errorDomain = failure.domain
            outcome.errorCode = failure.code
            outcome.cancelReason = failure.cancelReason
        } else if let status = task.httpStatus, !(200..<300).contains(status) {
            outcome.error = serverMessage(in: response) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        } else if task.httpStatus == nil {
            outcome.error = "The upload ended without an answer from the server."
            outcome.errorDomain = TransportOutcomeCode.domain
            outcome.errorCode = TransportOutcomeCode.noResponse.rawValue
        } else if let receipt = try? JSONDecoder().decode(OutcomeRecord.Receipt.self, from: response),
                  UUID(uuidString: receipt.id) != nil, ["created", "duplicate"].contains(receipt.status) {
            outcome.receipt = receipt
        } else {
            outcome.error = "The server did not confirm this upload."
            outcome.errorDomain = TransportOutcomeCode.domain
            outcome.errorCode = TransportOutcomeCode.invalidReceipt.rawValue
        }
        return outcome
    }

    /// The message of an Immich error answer, which is a string or, for validation errors, a list.
    private static func serverMessage(in response: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else { return nil }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        if let messages = object["message"] as? [String], !messages.isEmpty { return messages.joined(separator: "\n") }
        return nil
    }
}

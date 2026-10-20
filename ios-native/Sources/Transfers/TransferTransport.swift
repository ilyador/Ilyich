import Foundation

/// One background session as the transfer engine uses it. Its results, progress and drains arrive
/// on TransportRegistry's merged event stream rather than here. Dormant until B9.
protocol TransferTransport: Sendable {
    var session: TransferSessionID { get }
    /// Uploads the attempt's body and returns the task's ID. A task iOS still holds for the attempt,
    /// sent before a relaunch or by an earlier build, is adopted instead of sending a second one.
    func submit(_ request: URLRequest, key: AttemptKey) async throws(TransportSubmitError) -> Int
    /// The attempt's outcome file, legacy or version 2, or nil when there is none.
    func outcome(for key: AttemptKey) throws -> OutcomeRecord?
    /// Deletes the attempt's outcome file and body, once its result is committed.
    func acknowledge(_ key: AttemptKey) throws
    /// The tasks iOS holds for the session, with their descriptors decoded.
    func inventory() async -> TransportInventory
    /// Cancels every live task of an account and returns how many.
    func cancel(scope: String) async -> Int
}

extension TransferSessionID {
    /// The session an identifier from iOS names, or nil for one this app never created.
    init?(identifier: String, bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        guard let session = Self.allCases.first(where: { $0.identifier(bundleIdentifier: bundleIdentifier) == identifier }) else { return nil }
        self = session
    }
}

/// One upload attempt's account and files. Every build has kept an attempt's body and outcome side
/// by side, named after it: <folder>/<attempt>.multipart and <folder>/<attempt>.receipt, where the
/// folder is a backup stage (Backup/<digest>/<uuid>) or a share batch (ShareInbox/<batch>).
struct AttemptKey: Hashable, Sendable {
    let attempt: AttemptID
    /// The account digest.
    let scope: String
    /// The attempt's folder, relative to the App Group.
    let folder: String

    var bodyPath: String { folder + "/" + attempt.rawValue + ".multipart" }
    var outcomePath: String { folder + "/" + attempt.rawValue + ".receipt" }
    /// A new task's description: version 2, with the outcome relative to the App Group.
    var descriptor: TaskDescriptor { .v2(attempt: attempt, scope: scope, outcome: outcomePath) }

    /// Whether the names stay inside the App Group: a relative folder without . or .. parts, and
    /// an attempt that is one file name.
    var isValid: Bool {
        let name = attempt.rawValue
        let parts = folder.split(separator: "/", omittingEmptySubsequences: false)
        return !name.isEmpty && !name.contains("/") && name != "." && name != ".." && !scope.isEmpty
            && !folder.contains("://") && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

enum TransportSubmitError: Error, Equatable, Sendable {
    /// The key names files outside the App Group.
    case invalidKey
    /// The App Group container is unavailable.
    case unavailable
    /// The attempt's body file is missing.
    case missingBody
    /// The attempt's last outcome is still on disk. Sending again would replay or lose it, so the
    /// engine applies and acknowledges it first.
    case unacknowledgedOutcome
    /// Another submit of the same attempt is under way.
    case alreadySubmitting
}

/// What the background sessions report, merged across sessions by TransportRegistry.
enum TransportEvent: Equatable, Sendable {
    /// Bytes sent so far: at most four times a second per task, plus the last.
    case progress(TransferSessionID, TransportProgress)
    /// A task ended. A recorded outcome was written to its file before this event was sent.
    case finished(TransferSessionID, TransportCompletion)
    /// The session has delivered every event iOS had queued for it. Its finished events all came first.
    case drained(TransferSessionID)
}

struct TransportProgress: Equatable, Sendable {
    let taskID: Int
    let attempt: AttemptID
    let sent: Int64
    /// Negative when unknown.
    let expected: Int64
}

struct TransportCompletion: Equatable, Sendable {
    enum Journal: Equatable, Sendable {
        /// The outcome, as written to its file.
        case recorded(OutcomeRecord)
        /// The outcome could not be written, so nothing durable says how the task ended. This is
        /// never a success, even when the server confirmed: re-check the attempt by its checksum.
        case unrecorded(reason: String)
    }

    let taskID: Int
    let attempt: AttemptID
    /// The outcome file relative to the App Group, or nil for a legacy task described outside it.
    let outcomePath: String?
    let journal: Journal
}

/// A task iOS holds for a session.
struct TransportTaskSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable { case running, suspended, canceling, completed }

    let taskID: Int
    let descriptor: TaskDescriptor
    let state: State
    let sent: Int64
    let expected: Int64

    var attempt: AttemptID? { descriptor.attempt }
    /// Able to finish: neither cancelled nor done.
    var isLive: Bool { state == .running || state == .suspended }
}

struct TransportInventory: Equatable, Sendable {
    let session: TransferSessionID
    let tasks: [TransportTaskSnapshot]

    /// The live task for an attempt, whichever build sent it. A legacy task is found by its stage ID
    /// or share identity, whatever container path its descriptor recorded.
    func task(for attempt: AttemptID) -> TransportTaskSnapshot? { tasks.first { $0.isLive && $0.attempt == attempt } }

    /// Tasks of one account: version 2 by the scope they name, legacy backups by their Backup
    /// folder. A legacy share task names no account and is never listed.
    func tasks(scope: String) -> [TransportTaskSnapshot] { tasks.filter { $0.descriptor.scope == scope } }

    /// Tasks this app did not describe, or whose description is unreadable.
    var foreign: [TransportTaskSnapshot] { tasks.filter { $0.descriptor == .foreign } }
}

extension TaskDescriptor {
    /// The account a task belongs to: a version 2 descriptor names it, and a legacy backup's
    /// outcome sits in Backup/<digest>/. A legacy share descriptor names no account.
    var scope: String? {
        switch self {
        case .v2(_, let scope, _): return scope
        case .legacy:
            guard let parts = outcomePath?.split(separator: "/"), parts.count > 2, parts[0] == "Backup" else { return nil }
            return String(parts[1])
        case .foreign: return nil
        }
    }
}

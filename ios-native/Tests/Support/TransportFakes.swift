import Foundation
import IlyichPlatform
import Synchronization
@testable import Ilyich

/// iOS's side of a background session for BackgroundTransport tests: the tasks it holds and what
/// the transport asked of it. It keeps the delegate handler the transport created, so a test can
/// play the session's events through the TaskEventHandling seam.
final class FakeTransportSession: TransportSession {
    struct Upload: Equatable, Sendable {
        let id: Int
        let url: URL?
        let body: URL
        let description: String
    }

    private struct State {
        var tasks: [SessionTask]
        var uploads: [Upload] = []
        var resumed: [Int] = []
        var cancelled: [Int] = []
        var nextID = 100
        var handler: (any TaskEventHandling)?
    }

    private let state: Mutex<State>
    /// When set, listing the tasks waits for it, so a test can hold a submit mid-way.
    let listGate: StubServer.Gate?

    init(tasks: [SessionTask] = [], listGate: StubServer.Gate? = nil) {
        state = Mutex(State(tasks: tasks))
        self.listGate = listGate
    }

    /// Keeps the handler the transport passes to its session factory.
    func attach(_ handler: any TaskEventHandling) -> FakeTransportSession {
        state.withLock { $0.handler = handler }
        return self
    }

    var handler: any TaskEventHandling { state.withLock { $0.handler! } }
    var uploads: [Upload] { state.withLock { $0.uploads } }
    var resumed: [Int] { state.withLock { $0.resumed } }
    var cancelled: [Int] { state.withLock { $0.cancelled } }
    var current: [SessionTask] { state.withLock { $0.tasks } }

    func tasks() async -> [SessionTask] {
        if let listGate { await listGate.wait() }
        return state.withLock { $0.tasks }
    }

    func startUpload(_ request: URLRequest, fromFile body: URL, description: String) -> Int {
        state.withLock { state in
            state.nextID += 1
            state.tasks.append(SessionTask(id: state.nextID, description: description, state: .running, sent: 0, expected: -1))
            state.uploads.append(Upload(id: state.nextID, url: request.url, body: body, description: description))
            return state.nextID
        }
    }

    func resumeTask(_ id: Int) async { state.withLock { $0.resumed.append(id) } }

    func cancelTask(_ id: Int) async {
        state.withLock { state in
            state.cancelled.append(id)
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
            let task = state.tasks[index]
            state.tasks[index] = SessionTask(id: id, description: task.description, state: .canceling, sent: task.sent, expected: task.expected)
        }
    }

    /// iOS forgets a finished task.
    func forget(_ id: Int) { state.withLock { $0.tasks.removeAll { $0.id == id } } }
}

/// A value shared with closures that run elsewhere, behind a lock.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    var value: Value { mutex.withLock { $0 } }

    @discardableResult func mutate<Result: Sendable>(_ change: (inout Value) -> Result) -> Result {
        mutex.withLock { value in change(&value) }
    }
}

/// Events a transport emitted, in order.
final class TransportEventLog: Sendable {
    private let events = Mutex<[TransportEvent]>([])
    var all: [TransportEvent] { events.withLock { $0 } }
    var emit: @Sendable (TransportEvent) -> Void { { event in self.events.withLock { $0.append(event) } } }
}

/// A journal whose writes all fail, as on a full disk or a removed folder.
struct FailingJournal: OutcomeJournaling {
    let layout: AppGroupLayout
    func url(for path: String) -> URL? { layout.url(forRelativePath: path) }
    func write(_ record: OutcomeRecord, to path: String) throws { throw CocoaError(.fileWriteOutOfSpace) }
    func read(_ path: String) throws -> OutcomeRecord? { nil }
    func exists(_ path: String) -> Bool { false }
    func remove(_ path: String) throws {}
}

/// A throwaway App Group container in the temporary folder.
struct TemporaryAppGroup {
    let container: URL

    init() throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("IlyichTransfers-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    var layout: AppGroupLayout { AppGroupLayout(container: container) }
    var journal: FileOutcomeJournal { FileOutcomeJournal(layout: layout) }
    func url(_ path: String) -> URL { layout.url(forRelativePath: path) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

    /// Writes a file, creating its folders.
    func write(_ text: String, to path: String) throws {
        let file = url(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func makeFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    func text(_ path: String) throws -> String { String(decoding: try Data(contentsOf: url(path)), as: UTF8.self) }

    func remove() { try? FileManager.default.removeItem(at: container) }
}

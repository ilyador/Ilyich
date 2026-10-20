import XCTest
@testable import Ilyich

/// When iOS gets its completion handler back after relaunching the app for a background session
/// (rebuild milestone B5): only after the engine durably committed what the session delivered, or
/// at the 20-second deadline. The transport is played through its delegate seam into an event
/// stream that a stand-in engine reads.
@MainActor final class BackgroundEventAcksTests: XCTestCase {
    private typealias G = LegacyGoldens
    private static let receiptJSON = #"{"id":"e1f2a3b4-c5d6-4e7f-8091-a2b3c4d5e6f7","status":"created"}"#
    private let backup = TransferSessionID.backup.identifier

    func testCompletionSurvivesDrainBeforeRegistration() async throws {
        let group = try temporaryGroup()
        let clock = TestClock()
        let acks = BackgroundEventAcks(clock: clock)
        let (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        let engine = StandInEngine()
        engine.start(events, acks: acks)
        defer { engine.stop() }
        let session = makeSession(journal: group.journal) { _ = continuation.yield($0) }
        let key = try stagedKey(in: group)

        // The session already existed, so iOS delivered its events before handing over the handler.
        try deliverUpload(key, through: session)
        session.handler.sessionDidFinishEvents()
        try await until("The engine did not commit the drained session.") { engine.drains == 1 }
        XCTAssertEqual(engine.committed, [key.attempt])

        var answered = 0
        acks.register(identifier: backup) { answered += 1 }
        XCTAssertEqual(answered, 1, "Answered at once, not after the deadline.")
        XCTAssertEqual(acks.waiting, 0)
        XCTAssertEqual(clock.sleeperCount, 0, "No deadline was set.")
    }

    func testACommitLongBeforeRegistrationWaitsForTheNextOne() async throws {
        let clock = TestClock()
        let acks = BackgroundEventAcks(clock: clock)
        acks.committed(identifier: backup)
        clock.advance(by: .seconds(21))
        var answered = 0
        acks.register(identifier: backup) { answered += 1 }
        XCTAssertEqual(answered, 0, "A commit older than the deadline belongs to an earlier batch.")
        acks.committed(identifier: backup)
        XCTAssertEqual(answered, 1)
        clock.advance(by: .seconds(20))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(answered, 1, "Answered once.")
    }

    func testSystemCompletionOnlyAfterDurableCommit() async throws {
        let group = try temporaryGroup()
        let clock = TestClock()
        let acks = BackgroundEventAcks(clock: clock)
        let gate = StubServer.Gate()
        let engine = StandInEngine(commitGate: gate)
        let (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        engine.start(events, acks: acks)
        defer { engine.stop() }

        // iOS relaunched the app for the session; the handler is registered before the session is touched.
        var committedWhenAnswered: [AttemptID]?
        acks.register(identifier: backup) { committedWhenAnswered = engine.committed }
        let session = makeSession(journal: group.journal) { _ = continuation.yield($0) }
        let key = try stagedKey(in: group)
        try deliverUpload(key, through: session)
        session.handler.sessionDidFinishEvents()

        try await until("The engine did not start its commit.") { gate.waiting == 1 }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(committedWhenAnswered, "Not answered while the commit is under way.")
        XCTAssertTrue(group.exists(key.outcomePath), "Meanwhile the outcome is on disk, so a suspension would lose nothing.")
        gate.open()
        try await until("Not answered after the commit.") { committedWhenAnswered != nil }
        XCTAssertEqual(committedWhenAnswered, [key.attempt], "Answered once the upload was committed.")
        XCTAssertEqual(acks.waiting, 0)
    }

    func testJournalFailureNeverReportsSuccessOrHangs() async throws {
        let group = try temporaryGroup()
        let clock = TestClock()
        let acks = BackgroundEventAcks(clock: clock)
        let log = TransportEventLog()
        let (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        let engine = StandInEngine()
        engine.start(events, acks: acks)
        defer { engine.stop() }
        var answered = 0
        acks.register(identifier: backup) { answered += 1 }
        let session = makeSession(journal: FailingJournal(layout: group.layout)) { event in
            log.emit(event)
            _ = continuation.yield(event)
        }
        let key = try stagedKey(in: group)

        // The server confirms the upload, but its outcome cannot be written.
        try deliverUpload(key, through: session)
        guard case .finished(.backup, let completion)? = log.all.last else { return XCTFail("\(log.all)") }
        XCTAssertEqual(completion.attempt, key.attempt)
        XCTAssertFalse(completion.journal.isRecorded, "Reported \(completion.journal) without a durable outcome.")
        XCTAssertFalse(group.exists(key.outcomePath))

        // The session still drains, and iOS still gets its handler back.
        session.handler.sessionDidFinishEvents()
        try await until("The handler waited although the session drained.") { answered == 1 }
        XCTAssertEqual(engine.committed, [], "Nothing is committed as backed up without a durable outcome.")
        XCTAssertEqual(engine.recheck, [key.attempt], "The attempt is re-checked by its checksum instead.")

        // With no engine committing, as when the account cannot open, the deadline answers iOS, once.
        var unattended = 0
        let alone = BackgroundEventAcks(clock: clock)
        alone.register(identifier: backup) { unattended += 1 }
        try await clock.waitForSleepers(1)
        clock.advance(by: .seconds(19))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(unattended, 0)
        clock.advance(by: .seconds(1))
        try await until("The deadline did not answer iOS.") { unattended == 1 }
        alone.committed(identifier: backup)
        XCTAssertEqual(unattended, 1, "Answered exactly once.")
        XCTAssertEqual(alone.waiting, 0)
    }

    func testEveryWaitingHandlerIsAnsweredOnce() async throws {
        let clock = TestClock()
        let acks = BackgroundEventAcks(clock: clock)
        var answers: [String] = []
        acks.register(identifier: backup) { answers.append("first") }
        acks.register(identifier: backup) { answers.append("second") }
        acks.register(identifier: TransferSessionID.shareUpload.identifier) { answers.append("share") }
        XCTAssertEqual(acks.waiting, 3)
        acks.committed(identifier: backup)
        XCTAssertEqual(answers, ["first", "second"], "Only the committed session's handlers, in order.")
        try await clock.waitForSleepers(1)
        clock.advance(by: .seconds(20))
        try await until("The share's handler was not answered at its deadline.") { answers.count == 3 }
        clock.advance(by: .seconds(20))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(answers, ["first", "second", "share"])
        XCTAssertEqual(acks.waiting, 0)
    }

    func testUnknownIdentifiersAreAnsweredAtOnce() {
        let acks = BackgroundEventAcks(clock: TestClock())
        var answered = 0
        acks.register(identifier: "com.example.downloads") { answered += 1 }
        XCTAssertEqual(answered, 1)
        XCTAssertEqual(acks.waiting, 0)
    }

    // MARK: Support

    private func temporaryGroup() throws -> TemporaryAppGroup {
        let group = try TemporaryAppGroup()
        addTeardownBlock { group.remove() }
        return group
    }

    /// A backup session whose delegate events the test plays.
    private func makeSession(journal: any OutcomeJournaling, emit: @escaping @Sendable (TransportEvent) -> Void) -> FakeTransportSession {
        let fake = FakeTransportSession()
        _ = BackgroundTransport(session: .backup, journal: journal, emit: emit) { fake.attach($0) }
        return fake
    }

    /// A new attempt whose stage folder exists.
    private func stagedKey(in group: TemporaryAppGroup) throws -> AttemptKey {
        let key = AttemptKey(attempt: AttemptID(), scope: G.digest, folder: "Backup/\(G.digest)/\(UUID().uuidString)")
        try group.makeFolder(key.folder)
        return key
    }

    /// The server's 201 for the attempt's upload, through the delegate seam.
    private func deliverUpload(_ key: AttemptKey, through session: FakeTransportSession) throws {
        let description = try XCTUnwrap(key.descriptor.taskDescription)
        XCTAssertTrue(session.handler.task(1, didReceive: Data(Self.receiptJSON.utf8)))
        session.handler.taskDidComplete(CompletedTask(id: 1, description: description, httpStatus: 201, failure: nil))
    }

    private func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail(message); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// The transfer engine's part in a background relaunch, in order: it commits each upload whose
/// outcome was recorded, sets aside for a checksum re-check any whose outcome was not, and once
/// the session has drained, tells the acks that everything it delivered is committed.
@MainActor private final class StandInEngine {
    private(set) var committed: [AttemptID] = []
    private(set) var recheck: [AttemptID] = []
    private(set) var drains = 0
    private let commitGate: StubServer.Gate?
    private var loop: Task<Void, Never>?

    init(commitGate: StubServer.Gate? = nil) { self.commitGate = commitGate }

    func start(_ events: AsyncStream<TransportEvent>, acks: BackgroundEventAcks<TestClock>) {
        loop = Task {
            for await event in events {
                switch event {
                case .finished(_, let completion):
                    guard case .recorded(let outcome) = completion.journal, outcome.receipt != nil else {
                        recheck.append(completion.attempt)
                        continue
                    }
                    if let commitGate { await commitGate.wait() }
                    committed.append(completion.attempt)
                case .drained(let session):
                    drains += 1
                    acks.committed(identifier: session.identifier)
                case .progress:
                    break
                }
            }
        }
    }

    func stop() { loop?.cancel() }
}

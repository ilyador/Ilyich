import XCTest
@testable import Ilyich

/// When iOS gets its completion handler back after relaunching the app for a background session
/// (rebuild milestone B5): only after the engine durably committed what the session delivered, or
/// at the 20-second deadline. The sessions are wired as B9's app delegate will wire them: a
/// registry whose transport plays a fake session through its delegate seam, a stand-in engine
/// reading the registry's event stream, and acks reading the registry's drain counts.
@MainActor final class BackgroundEventAcksTests: XCTestCase {
    private let backup = TransferSessionID.backup.identifier

    func testCompletionSurvivesDrainBeforeRegistration() async throws {
        let launch = try launch()
        let engine = StandInEngine()
        engine.start(launch)
        defer { engine.stop() }
        let key = try launch.stagedKey()

        // The session already existed, so iOS delivered its events before handing over the handler.
        try launch.deliverUpload(key)
        launch.session.handler.sessionDidFinishEvents()
        try await until("The engine did not commit the drained session.") { engine.drains == 1 }
        XCTAssertEqual(engine.committed, [key.attempt])

        var answered = 0
        launch.acks.register(identifier: backup) { answered += 1 }
        XCTAssertEqual(answered, 1, "Answered at once, not after the deadline.")
        XCTAssertEqual(launch.acks.waiting, 0)
        XCTAssertEqual(launch.clock.sleeperCount, 0, "No deadline was set.")

        // The next relaunch's events drain before its handler too, but their commit is still under way.
        let next = try launch.stagedKey()
        let gate = StubServer.Gate()
        engine.slowCommits[next.attempt] = gate
        try launch.deliverUpload(next, task: 2)
        launch.session.handler.sessionDidFinishEvents()
        try await until("The engine did not start its commit.") { gate.waiting == 1 }
        launch.acks.register(identifier: backup) { answered += 1 }
        XCTAssertEqual(answered, 1, "Not answered before its drain is committed.")
        gate.open()
        try await until("Not answered after its drain's commit.") { answered == 2 }
        XCTAssertEqual(engine.committed, [key.attempt, next.attempt])
    }

    func testACommitLongBeforeRegistrationWaitsForTheNextOne() async throws {
        let launch = try launch()
        let engine = StandInEngine()
        engine.start(launch)
        defer { engine.stop() }
        launch.session.handler.sessionDidFinishEvents()
        try await until("The engine did not commit the drain.") { engine.drains == 1 }
        launch.clock.advance(by: .seconds(21))

        var answered = 0
        launch.acks.register(identifier: backup) { answered += 1 }
        XCTAssertEqual(answered, 0, "A commit older than the deadline belongs to an earlier batch.")
        launch.session.handler.sessionDidFinishEvents()
        try await until("Not answered after the next drain's commit.") { answered == 1 }
        launch.clock.advance(by: .seconds(20))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(answered, 1, "Answered once.")
    }

    func testALateCommitDoesNotAnswerTheNextRelaunch() async throws {
        try await playLateCommit(endingBeforeTheNextRelaunch: false)
    }

    func testALateCommitEndingBeforeTheNextRelaunchDoesNotAnswerIt() async throws {
        try await playLateCommit(endingBeforeTheNextRelaunch: true)
    }

    func testSystemCompletionOnlyAfterDurableCommit() async throws {
        let launch = try launch()
        let engine = StandInEngine()
        engine.start(launch)
        defer { engine.stop() }

        // iOS relaunched the app for the session; the handler is registered before the session is touched.
        var committedWhenAnswered: [AttemptID]?
        launch.acks.register(identifier: backup) { committedWhenAnswered = engine.committed }
        XCTAssertEqual(launch.registry.connected, [], "Registering the handler created no session.")
        let key = try launch.stagedKey()
        let gate = StubServer.Gate()
        engine.slowCommits[key.attempt] = gate
        try launch.deliverUpload(key)
        launch.session.handler.sessionDidFinishEvents()

        try await until("The engine did not start its commit.") { gate.waiting == 1 }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(committedWhenAnswered, "Not answered while the commit is under way.")
        XCTAssertTrue(launch.group.exists(key.outcomePath), "Meanwhile the outcome is on disk, so a suspension would lose nothing.")
        gate.open()
        try await until("Not answered after the commit.") { committedWhenAnswered != nil }
        XCTAssertEqual(committedWhenAnswered, [key.attempt], "Answered once the upload was committed.")
        XCTAssertEqual(launch.acks.waiting, 0)
    }

    func testJournalFailureNeverReportsSuccessOrHangs() async throws {
        let launch = try launch(failingJournal: true)
        let engine = StandInEngine()
        engine.start(launch)
        defer { engine.stop() }
        var answered = 0
        launch.acks.register(identifier: backup) { answered += 1 }
        let key = try launch.stagedKey()

        // The server confirms the upload, but its outcome cannot be written.
        try launch.deliverUpload(key)
        guard case .finished(.backup, let completion)? = launch.log.all.last else { return XCTFail("\(launch.log.all)") }
        XCTAssertEqual(completion.attempt, key.attempt)
        XCTAssertFalse(completion.journal.isRecorded, "Reported \(completion.journal) without a durable outcome.")
        XCTAssertFalse(launch.group.exists(key.outcomePath))

        // The session still drains, and iOS still gets its handler back.
        launch.session.handler.sessionDidFinishEvents()
        try await until("The handler waited although the session drained.") { answered == 1 }
        XCTAssertEqual(engine.committed, [], "Nothing is committed as backed up without a durable outcome.")
        XCTAssertEqual(engine.recheck, [key.attempt], "The attempt is re-checked by its checksum instead.")

        // With no engine committing, as when the account cannot open, the deadline answers iOS, once.
        var unattended = 0
        let alone = BackgroundEventAcks(clock: launch.clock, drains: Self.neverDrains)
        alone.register(identifier: backup) { unattended += 1 }
        try await launch.clock.waitForSleepers(1)
        launch.clock.advance(by: .seconds(19))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(unattended, 0)
        launch.clock.advance(by: .seconds(1))
        try await until("The deadline did not answer iOS.") { unattended == 1 }
        alone.committed(identifier: backup, through: 1)
        XCTAssertEqual(unattended, 1, "Answered exactly once.")
        XCTAssertEqual(alone.waiting, 0)
    }

    func testEveryWaitingHandlerIsAnsweredOnce() async throws {
        let clock = TestClock()
        let acks = BackgroundEventAcks(clock: clock, drains: Self.neverDrains)
        var answers: [String] = []
        acks.register(identifier: backup) { answers.append("first") }
        acks.register(identifier: backup) { answers.append("second") }
        acks.register(identifier: TransferSessionID.shareUpload.identifier) { answers.append("share") }
        XCTAssertEqual(acks.waiting, 3)
        acks.committed(identifier: backup, through: 1)
        XCTAssertEqual(answers, ["first", "second"], "Only the committed session's handlers, in order.")
        try await clock.waitForSleepers(1)
        clock.advance(by: .seconds(20))
        try await until("The share's handler was not answered at its deadline.") { answers.count == 3 }
        clock.advance(by: .seconds(20))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(answers, ["first", "second", "share"])
        XCTAssertEqual(acks.waiting, 0)
    }

    func testUnknownIdentifiersAreAnsweredAtOnce() throws {
        let launch = try launch()
        var answered = 0
        launch.acks.register(identifier: "com.example.downloads") { answered += 1 }
        XCTAssertEqual(answered, 1)
        XCTAssertEqual(launch.acks.waiting, 0)
        XCTAssertEqual(launch.registry.connected, [])
    }

    // MARK: Support

    /// Sessions that exist and never drain.
    nonisolated private static func neverDrains(_ identifier: String) -> Int? {
        TransferSessionID(identifier: identifier) == nil ? nil : 0
    }

    private func launch(failingJournal: Bool = false) throws -> Launch {
        let group = try TemporaryAppGroup()
        addTeardownBlock { group.remove() }
        return Launch(group: group, journal: failingJournal ? FailingJournal(layout: group.layout) : group.journal)
    }

    /// The first relaunch's commit outlasts the deadline, which answers its handler, and iOS suspends
    /// the app mid-commit. The next upload relaunches it, and that late commit ends before or after
    /// the new handler arrives. Either way only the second relaunch's own commit answers it.
    private func playLateCommit(endingBeforeTheNextRelaunch: Bool) async throws {
        let launch = try launch()
        let engine = StandInEngine()
        engine.start(launch)
        defer { engine.stop() }
        let first = try launch.stagedKey(), second = try launch.stagedKey()
        let gate = StubServer.Gate()
        engine.slowCommits[first.attempt] = gate
        var answers: [String] = []
        launch.acks.register(identifier: backup) { answers.append("first") }
        try launch.deliverUpload(first)
        launch.session.handler.sessionDidFinishEvents()
        try await until("The engine did not start its commit.") { gate.waiting == 1 }
        try await launch.clock.waitForSleepers(1)
        launch.clock.advance(by: .seconds(20))
        try await until("The deadline did not answer the first relaunch.") { answers == ["first"] }

        func finishTheLateCommit() async throws {
            gate.open()
            try await until("The first drain was not committed.") { engine.drains == 1 }
        }
        if endingBeforeTheNextRelaunch { try await finishTheLateCommit() }
        launch.acks.register(identifier: backup) { answers.append("second") }
        if !endingBeforeTheNextRelaunch { try await finishTheLateCommit() }
        XCTAssertEqual(answers, ["first"], "The first drain's commit does not answer the second relaunch.")
        XCTAssertEqual(launch.acks.waiting, 1)

        try launch.deliverUpload(second, task: 2)
        launch.session.handler.sessionDidFinishEvents()
        try await until("The second relaunch was not answered after its commit.") { answers.count == 2 }
        XCTAssertEqual(answers, ["first", "second"])
        XCTAssertEqual(engine.committed, [first.attempt, second.attempt])
    }

    private func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail(message); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// One process's background sessions as B9's app delegate wires them: a registry whose backup
/// transport plays a fake session through its delegate seam, and acks reading its drain counts.
@MainActor private final class Launch {
    static let receiptJSON = #"{"id":"e1f2a3b4-c5d6-4e7f-8091-a2b3c4d5e6f7","status":"created"}"#

    let group: TemporaryAppGroup
    let clock: TestClock
    let registry: TransportRegistry
    let acks: BackgroundEventAcks<TestClock>
    /// Every event the transports emitted, as they emitted it.
    let log: TransportEventLog
    private let fakes: Locked<[TransferSessionID: FakeTransportSession]>

    init(group: TemporaryAppGroup, journal: any OutcomeJournaling) {
        let clock = TestClock(), log = TransportEventLog(), fakes = Locked<[TransferSessionID: FakeTransportSession]>([:])
        let registry = TransportRegistry { session, emit in
            BackgroundTransport(session: session, journal: journal, emit: { log.emit($0); emit($0) }) { handler in
                let fake = FakeTransportSession().attach(handler)
                fakes.mutate { $0[session] = fake }
                return fake
            }
        }
        self.group = group
        self.clock = clock
        self.registry = registry
        self.log = log
        self.fakes = fakes
        acks = BackgroundEventAcks(clock: clock, drains: { registry.drains(identifier: $0) })
    }

    /// The backup session, created the first time it is touched, as iOS's events or the engine touch it.
    var session: FakeTransportSession {
        _ = registry.transport(.backup)
        return fakes.value[.backup]!
    }

    /// A new attempt whose stage folder exists.
    func stagedKey() throws -> AttemptKey {
        let key = AttemptKey(attempt: AttemptID(), scope: LegacyGoldens.digest, folder: "Backup/\(LegacyGoldens.digest)/\(UUID().uuidString)")
        try group.makeFolder(key.folder)
        return key
    }

    /// The server's 201 for the attempt's upload task, through the backup session's delegate seam.
    func deliverUpload(_ key: AttemptKey, task id: Int = 1) throws {
        let description = try XCTUnwrap(key.descriptor.taskDescription)
        XCTAssertTrue(session.handler.task(id, didReceive: Data(Self.receiptJSON.utf8)))
        session.handler.taskDidComplete(CompletedTask(id: id, description: description, httpStatus: 201, failure: nil))
    }
}

/// The transfer engine's part in a background relaunch, in order: it commits each upload whose
/// outcome was recorded, sets aside for a checksum re-check any whose outcome was not, and once
/// the session has drained, tells the acks that everything up to that drain is committed.
@MainActor private final class StandInEngine {
    private(set) var committed: [AttemptID] = []
    private(set) var recheck: [AttemptID] = []
    private(set) var drains = 0
    /// Commits that take until the test opens their gate.
    var slowCommits: [AttemptID: StubServer.Gate] = [:]
    private var loop: Task<Void, Never>?

    func start(_ launch: Launch) {
        let events = launch.registry.events, acks = launch.acks
        loop = Task {
            for await event in events {
                switch event {
                case .finished(_, let completion):
                    guard case .recorded(let outcome) = completion.journal, outcome.receipt != nil else {
                        recheck.append(completion.attempt)
                        continue
                    }
                    if let gate = slowCommits[completion.attempt] { await gate.wait() }
                    committed.append(completion.attempt)
                case .drained(let session, let drain):
                    drains += 1
                    acks.committed(identifier: session.identifier, through: drain)
                case .progress:
                    break
                }
            }
        }
    }

    func stop() { loop?.cancel() }
}

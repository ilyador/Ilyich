import Foundation
import IlyichPlatform
import Synchronization
import XCTest
@testable import Ilyich

/// An account's authorization that a test changes by hand.
final class FakeTransferAuthorization: TransferAuthorizing {
    private struct State {
        var snapshot: AuthorizationSnapshot
        var ended = false
        var observers: [UUID: AsyncStream<AuthorizationSnapshot>.Continuation] = [:]
    }

    static let account = AccountID(server: URL(string: "https://photos.example/api")!, userID: "owner")
    private let state: Mutex<State>

    init(token: String = "token-1") {
        state = Mutex(State(snapshot: AuthorizationSnapshot(epoch: AuthorizationEpoch(account: Self.account, value: 1), writeGeneration: 1,
                                                            privateEpoch: 1, tokenDigest: token, readOnly: false, requiresPasswordChange: false,
                                                            lockedFolderUnlocked: false)))
    }

    func current() -> AuthorizationSnapshot? { state.withLock { $0.ended ? nil : $0.snapshot } }

    func updates() -> AsyncStream<AuthorizationSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: AuthorizationSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let ended = state.withLock { state -> Bool in
            continuation.yield(state.snapshot)
            if !state.ended { state.observers[id] = continuation }
            return state.ended
        }
        if ended { continuation.finish() }
        return stream
    }

    func setToken(_ token: String) { change { $0.tokenDigest = token } }

    func setReadOnly(_ readOnly: Bool) {
        change {
            $0.readOnly = readOnly
            $0.writeGeneration += 1
        }
    }

    func accessChanged() { change { $0.epoch = AuthorizationEpoch(account: Self.account, value: $0.epoch.value + 1) } }

    func end() {
        let observers = state.withLock { state in
            state.ended = true
            defer { state.observers = [:] }
            return Array(state.observers.values)
        }
        for observer in observers { observer.finish() }
    }

    private func change(_ update: (inout AuthorizationSnapshot) -> Void) {
        let (snapshot, observers) = state.withLock { state in
            update(&state.snapshot)
            return (state.snapshot, Array(state.observers.values))
        }
        for observer in observers { observer.yield(snapshot) }
    }
}

/// Holds an executor until the test opens it. Waiting ignores cancellation, as a slow upload or a
/// server answer already on its way would.
final class TransferGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    var waiting: Int { state.withLock { $0.waiters.count } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let open = state.withLock { state -> Bool in
                if !state.open { state.waiters.append(continuation) }
                return state.open
            }
            if open { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// An executor that follows a script per photo: stage, then the step, then submit and succeed.
/// It checks its lease after every await, as a real one must, unless a step says not to.
final class FakeJobExecutor: JobExecuting {
    enum Step: Sendable {
        case succeed
        /// Fails with the error after staging, before anything is submitted.
        case fail(@Sendable () -> any Error)
        /// Waits at the gate after reaching the submitting stage, then checks its lease and submits.
        case hold(TransferGate)
        /// Waits at the gate, then returns success without looking at its lease: a late result.
        case holdThenReturn(TransferGate)
        /// Reports progress `count` times, waits at the gate, then succeeds.
        case report(count: Int, TransferGate)
    }

    struct Call: Equatable, Sendable {
        let key: String
        let lease: Lease
        let state: JobState
        let phase: String?
        let retryCount: Int
    }

    private struct State {
        var script: [String: [Step]] = [:]
        var calls: [Call] = []
        var submitted: [String] = []
    }

    private let state = Mutex(State())

    func script(_ key: String, _ steps: Step...) { state.withLock { $0.script[key, default: []].append(contentsOf: steps) } }
    var calls: [Call] { state.withLock { $0.calls } }
    var submitted: [String] { state.withLock { $0.submitted } }
    func calls(_ key: String) -> Int { calls.filter { $0.key == key }.count }

    func execute(_ job: LeasedJob, context: JobContext) async throws -> JobResult {
        let key = job.source.key
        let step = state.withLock { state -> Step in
            state.calls.append(Call(key: key, lease: job.lease, state: job.state, phase: job.phase, retryCount: job.retryCount))
            guard var steps = state.script[key], !steps.isEmpty else { return .succeed }
            let step = steps.removeFirst()
            state.script[key] = steps
            return step
        }
        if job.state == .queued || job.state == .retryScheduled { try await context.advance(to: .staged, phase: "staged") }
        switch step {
        case .succeed:
            break
        case .fail(let error):
            throw error()
        case .hold(let gate):
            try await context.advance(to: .submitting, phase: "original")
            await gate.wait()
            try await context.ensureOwned()
        case .holdThenReturn(let gate):
            try await context.advance(to: .submitting, phase: "original")
            await gate.wait()
            return Self.result(for: job)
        case .report(let count, let gate):
            for sent in 1...count { await context.progress(sent: Int64(sent) * 100, expected: Int64(count) * 100) }
            await gate.wait()
            try await context.ensureOwned()
        }
        try await context.ensureOwned()
        state.withLock { $0.submitted.append(key) }
        return Self.result(for: job)
    }

    static func result(for job: LeasedJob) -> JobResult {
        switch job.source {
        case .photo(let id):
            let revision = AssetRevision(referenceSeconds: 700_000_000.25)
            return .backedUp(revision: revision, assetID: "asset-" + id.rawValue,
                             receipt: TransferReceipt(localID: id.rawValue, revision: revision,
                                                      original: RemoteCopy(id: "asset-" + id.rawValue, checksum: "sum-" + id.rawValue),
                                                      motion: nil, confirmedAt: nil))
        case .shared:
            return .shared(remoteID: "shared-asset")
        }
    }
}

/// A transfer engine on a fresh database it owns, with a test clock, fake authorization and the
/// fake executor. Jitter is zero: the first retry waits exactly 30 seconds.
struct TransferEngineHarness {
    let folder: URL
    let store: TransferStore
    let clock = TestClock()
    let authorization = FakeTransferAuthorization()
    let executor = FakeJobExecutor()
    let engine: TransferEngine<TestClock>
    static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init(claim: Bool = true) async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TransferEngine-" + UUID().uuidString, isDirectory: true)
        store = TransferStore(url: folder.appendingPathComponent("transfers.sqlite"))
        if claim { try await store.claimForEngine() }
        engine = Self.engine(store: store, clock: clock, authorization: authorization, executor: executor)
    }

    static func engine(store: TransferStore, clock: TestClock, authorization: FakeTransferAuthorization,
                       executor: FakeJobExecutor) -> TransferEngine<TestClock> {
        TransferEngine(store: store, executor: executor, authorization: authorization, clock: clock,
                       now: { base.addingTimeInterval(TimeInterval(clock.now.offset.components.seconds) + TimeInterval(clock.now.offset.components.attoseconds) / 1e18) },
                       random: { 0.5 })
    }

    func photo(_ id: String) -> TransferRequest {
        TransferRequest(source: .photo(DeviceAssetID(rawValue: id)), origin: .discovery, revision: AssetRevision(referenceSeconds: 700_000_000.25))
    }

    func job(_ id: String) async throws -> StoredJob? { try await store.job(lane: .library, sourceKey: id) }

    struct Missing: Error {}

    func requireJob(_ id: String) async throws -> StoredJob {
        guard let job = try await job(id) else { throw Missing() }
        return job
    }

    func requireLease() async throws -> Lease {
        guard let lease = await engine.runningLease else { throw Missing() }
        return lease
    }

    func confirmed(_ id: String) async throws -> Bool {
        try await store.receipts(for: [id])[id] != nil
    }

    func allConfirmed(_ ids: String...) async throws -> Bool {
        try await store.receipts(for: ids).count == ids.count
    }

    func tearDown() async {
        await engine.stop()
        await store.close()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Polls, in real time, until the condition holds, or fails the test.
func untilTransfers(_ message: String, timeout: Duration = .seconds(5), isolation: isolated (any Actor)? = #isolation,
                    file: StaticString = #filePath, line: UInt = #line, _ condition: () async throws -> Bool) async rethrows {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        guard ContinuousClock.now < deadline else { return XCTFail("Timed out: \(message)", file: file, line: line) }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

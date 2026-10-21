import Foundation
import Synchronization
import XCTest
@testable import Ilyich

/// The transfer engine's one loop against commands that arrive while a job runs (B2).
final class TransferEngineRaceTests: XCTestCase {
    func testASecondStartNeverClearsRunningOrResetsTheActiveStage() async throws {
        let h = try await TransferEngineHarness()
        let gate = TransferGate()
        h.executor.script("a", .hold(gate))
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The job reaches the transport.") { gate.waiting == 1 }
        let lease = try await h.requireLease()

        // Back up now, twice, and the engine started again, all while the upload runs.
        try await h.engine.start()
        try await h.engine.setIntent(.manual)
        try await h.engine.setIntent(.manual)
        try await h.engine.start()

        let running = await h.engine.runningLease
        XCTAssertEqual(running, lease, "The running job keeps its lease.")
        let job = try await h.requireJob("a")
        XCTAssertEqual(job.state, .submitting, "The job's stage stays where the executor put it.")
        XCTAssertEqual(job.phase, "original")
        let phase = await h.engine.currentSnapshot.phase
        XCTAssertEqual(phase, .running)
        XCTAssertEqual(h.executor.calls("a"), 1, "Nothing starts the job a second time.")

        gate.open()
        try await untilTransfers("The upload commits.") { try await h.confirmed("a") }
        let left = try await h.job("a")
        XCTAssertNil(left)
        XCTAssertEqual(h.executor.submitted, ["a"])
        await h.tearDown()
    }

    func testOverlappingStartsRunOneLoop() async throws {
        let h = try await TransferEngineHarness()
        let gate = TransferGate()
        h.executor.script("a", .hold(gate))
        h.executor.script("b", .hold(gate))
        _ = try await h.engine.enqueue([h.photo("a"), h.photo("b")])
        try await h.engine.setIntent(.automatic)
        // A scene foreground and a background task at launch, both before either has loaded.
        async let first: Void = h.engine.start()
        async let second: Void = h.engine.start()
        _ = try await (first, second)
        await untilTransfers("A job runs.") { gate.waiting >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(gate.waiting, 1, "One loop runs one job at a time.")
        XCTAssertEqual(h.executor.calls.map(\.key), ["a"])
        let lease = try await h.requireLease()
        let stored = try await h.requireJob("a")
        XCTAssertEqual(stored.state, .submitting)
        XCTAssertEqual(lease.job, stored.id, "No second start gave the running job's lease back.")

        gate.open()
        try await untilTransfers("Both commit in turn.") { try await h.allConfirmed("a", "b") }
        XCTAssertEqual(h.executor.submitted, ["a", "b"])
        await h.tearDown()
    }

    func testAStopDuringStartKeepsTheEngineStopped() async throws {
        let h = try await TransferEngineHarness()
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.automatic)
        async let starting: Void = h.engine.start()
        await h.engine.stop()
        try await starting
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(h.executor.calls.isEmpty, "A stopped engine never runs a loop, whichever came first.")
        let lease = await h.engine.runningLease
        XCTAssertNil(lease)
        await h.tearDown()
    }

    func testALateResultAfterAReleasedLeaseIsDiscarded() async throws {
        let h = try await TransferEngineHarness()
        let gate = TransferGate()
        h.executor.script("a", .holdThenReturn(gate), .succeed)
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The job runs.") { gate.waiting == 1 }
        let stale = try await h.requireLease()

        // Pausing gives the lease back; the upload's answer then arrives anyway.
        try await h.engine.setIntent(.paused)
        let released = await h.engine.runningLease
        XCTAssertNil(released)
        gate.open()
        try await Task.sleep(for: .milliseconds(100))

        let confirmed = try await h.confirmed("a")
        XCTAssertFalse(confirmed, "A result without its lease commits nothing.")
        let job = try await h.requireJob("a")
        XCTAssertEqual(job.state, .submitting, "The job keeps its stage for the next lease.")
        XCTAssertEqual(h.executor.calls("a"), 1, "A paused library lane leases nothing.")

        // The store refuses the stale lease too.
        let completion = TransferCompletion(job: stale.job, lease: stale.token, localID: "a", revision: AssetRevision(referenceSeconds: 1),
                                            assetID: "x", receipt: nil, confirmedAt: Date())
        let committed = try await h.store.complete(completion)
        XCTAssertFalse(committed, "A commit WHERE the lease no longer matches changes nothing.")

        try await h.engine.setIntent(.automatic)
        try await untilTransfers("The job runs again under a new lease.") { try await h.confirmed("a") }
        let calls = h.executor.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertNotEqual(calls.last?.lease.token, stale.token)
        XCTAssertEqual(calls.last?.state, .submitting, "The second lease resumes from the stage the first reached.")
        await h.tearDown()
    }

    func testARelaunchResumesAnInterruptedJobFromItsStage() async throws {
        let h = try await TransferEngineHarness()
        let gate = TransferGate()
        h.executor.script("a", .hold(gate))
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The job runs.") { gate.waiting == 1 }
        // The engine ends with the job part way: its lease goes, its stage stays. The upload's
        // own answer comes after the end and is dropped.
        let stopping = Task { await h.engine.stop() }
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        await stopping.value
        let left = try await h.requireJob("a")
        XCTAssertEqual(left.state, .submitting)
        XCTAssertTrue(h.executor.submitted.isEmpty, "A stopped engine's job sends nothing.")

        let next = TransferEngineHarness.engine(store: h.store, clock: h.clock, authorization: h.authorization, executor: h.executor)
        try await next.start()
        try await untilTransfers("The job runs in the new process.") { try await h.confirmed("a") }
        let resumed = try XCTUnwrap(h.executor.calls.last)
        XCTAssertEqual(resumed.state, .submitting)
        XCTAssertEqual(resumed.phase, "original")
        let intent = await next.currentSnapshot.intent
        XCTAssertEqual(intent, .automatic, "The intent is kept across launches.")
        await next.stop()
        await h.tearDown()
    }

    func testCancelReleasesTheRunningJobAndRemovesIt() async throws {
        let h = try await TransferEngineHarness()
        let gate = TransferGate()
        h.executor.script("a", .holdThenReturn(gate))
        _ = try await h.engine.enqueue([h.photo("a"), h.photo("b")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The first job runs.") { gate.waiting == 1 }
        try await h.engine.cancel([.photo(.init(rawValue: "a"))])
        gate.open()
        try await untilTransfers("The next job runs.") { try await h.confirmed("b") }
        let removed = try await h.job("a")
        XCTAssertNil(removed)
        let confirmed = try await h.confirmed("a")
        XCTAssertFalse(confirmed, "A cancelled job's late result is dropped.")
        await h.tearDown()
    }

    func testTheEngineNeverRunsOnTheShadowCopy() async throws {
        let h = try await TransferEngineHarness(claim: false)
        do {
            try await h.engine.start()
            XCTFail("A database BackupCoordinator's shadow import owns is not the engine's.")
        } catch let error as TransferEngine<TestClock>.StartError {
            XCTAssertEqual(error, .notOwned)
        }
        await h.tearDown()
    }

    func testSnapshotsComeAtMostFourTimesASecond() async throws {
        let h = try await TransferEngineHarness()
        let gate = TransferGate()
        h.executor.script("a", .report(count: 20, gate))
        let received = Mutex<[TransferSnapshot]>([])
        let stream = await h.engine.snapshots()
        let reader = Task {
            for await snapshot in stream { received.withLock { $0.append(snapshot) } }
        }
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The executor reports its progress.") { gate.waiting == 1 }
        try await Task.sleep(for: .milliseconds(50))

        // The clock has not moved: after the first snapshot, everything waits for the interval.
        let early = received.withLock { $0 }
        XCTAssertLessThanOrEqual(early.count, 2, "Twenty progress reports in no time give one snapshot, not twenty.")
        h.clock.advance(by: .milliseconds(250))
        await untilTransfers("The latest snapshot goes out at the end of the interval.") {
            received.withLock { $0.last?.fileProgress } == 1
        }
        let latest = received.withLock { $0.last }
        XCTAssertEqual(latest?.phase, .running)
        XCTAssertEqual(latest?.bytesSent, 2_000)
        reader.cancel()
        gate.open()
        await h.tearDown()
    }
}

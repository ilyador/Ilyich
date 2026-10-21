import Foundation
import XCTest
@testable import Ilyich

/// The engine running several jobs at once, and the transport's answers reaching the attempts
/// that wait for them (B3).
final class TransferPipelineTests: XCTestCase {
    /// Several leases run side by side; a pause gives every library one back, and each job runs
    /// again from where it got to once the run resumes.
    func testAPauseReleasesEveryRunningLibraryJob() async throws {
        let h = try await TransferEngineHarness()
        let engine = TransferEngine(store: h.store, executor: h.executor, authorization: h.authorization, clock: h.clock, concurrency: 3,
                                    now: { TransferEngineHarness.base }, random: { 0.5 })
        let gate = TransferGate()
        for id in ["a", "b", "c", "d"] { h.executor.script(id, .hold(gate)) }
        _ = try await engine.enqueue(["a", "b", "c", "d"].map(h.photo))
        try await engine.setIntent(.automatic)
        try await engine.start()
        await untilTransfers("Three jobs run at once.") { gate.waiting == 3 }
        let leases = await engine.runningLeases
        XCTAssertEqual(Set(leases.map(\.job)).count, 3)
        let phase = await engine.currentSnapshot.phase
        XCTAssertEqual(phase, .running)

        try await engine.setIntent(.paused)
        let running = await engine.runningLeases
        XCTAssertTrue(running.isEmpty, "A pause gives every library lease back.")
        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        let confirmed = try await h.store.counts().confirmed
        XCTAssertEqual(confirmed, 0, "What the released jobs return is dropped.")
        for id in ["a", "b", "c"] {
            let job = try await h.job(id)
            XCTAssertEqual(job?.state, .submitting, "\(id) keeps how far it got.")
        }

        try await engine.setIntent(.automatic)
        try await untilTransfers("Every job runs again and finishes.") { try await h.allConfirmed("a", "b", "c", "d") }
        await engine.stop()
        await h.tearDown()
    }

    /// An answer is matched to its attempt whether the finished event comes before the wait, during
    /// it, or only as a file on disk; progress reaches the waiter, and a cancelled wait ends.
    func testTransportOutcomesReachTheirAttemptsWhateverTheOrder() async throws {
        let (events, emit) = AsyncStream.makeStream(of: TransportEvent.self)
        let outcomes = TransportOutcomes(events: events)
        let early = AttemptID(), live = AttemptID(), onDisk = AttemptID(), cancelled = AttemptID()
        let created = OutcomeRecord(receipt: .init(id: "asset", status: "created"), v: 2)
        func finished(_ attempt: AttemptID, _ journal: TransportCompletion.Journal) -> TransportEvent {
            .finished(.backup, TransportCompletion(taskID: 1, attempt: attempt, outcomePath: nil, journal: journal))
        }

        emit.yield(finished(early, .recorded(created)))
        try await Task.sleep(for: .milliseconds(50))
        let first = try await outcomes.wait(for: early, progress: { _, _ in }) { nil }
        XCTAssertEqual(first, .recorded(created), "An event that came first is kept for its attempt.")

        let sent = Locked<[Int64]>([])
        let waiting = Task { try await outcomes.wait(for: live, progress: { value, _ in sent.mutate { $0.append(value) } }) { nil } }
        try await Task.sleep(for: .milliseconds(50))
        emit.yield(.progress(.backup, TransportProgress(taskID: 2, attempt: live, sent: 512, expected: 1_024)))
        emit.yield(finished(AttemptID(), .unrecorded(reason: "another attempt's")))
        emit.yield(finished(live, .unrecorded(reason: "disk full")))
        let second = try await waiting.value
        XCTAssertEqual(second, .unrecorded(reason: "disk full"))
        XCTAssertEqual(sent.value, [512])

        let third = try await outcomes.wait(for: onDisk, progress: { _, _ in }) { created }
        XCTAssertEqual(third, .recorded(created), "A file written before the wait answers it.")

        let abandoned = Task { try await outcomes.wait(for: cancelled, progress: { _, _ in }) { nil } }
        try await Task.sleep(for: .milliseconds(50))
        abandoned.cancel()
        do {
            _ = try await abandoned.value
            XCTFail("A cancelled wait ends.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        outcomes.shutdown()
        emit.finish()
    }

    /// Waits for a turn end when their task is cancelled, and give nothing away.
    func testACancelledWaitForATurnTakesNone() async throws {
        let pipeline = TransferPipeline(limits: TransferPipeline.Limits(staged: 1, submitted: 1, stagingBytes: 100))
        let held = try await pipeline.acquireStaging()
        let waiting = Task { try await pipeline.acquireStaging() }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("The cancelled wait ends.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        pipeline.release(held)
        pipeline.release(held)
        XCTAssertEqual(pipeline.stagedCount, 0, "A second release changes nothing.")
        let next = try await pipeline.acquireStaging()
        pipeline.record(bytes: 1_000, for: next)
        XCTAssertEqual(pipeline.peaks.stagedBytes, 1_000, "One stage may pass the budget alone.")
        pipeline.release(next)
    }
}

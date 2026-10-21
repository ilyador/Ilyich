import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// The transfer engine against changes of authorization while it works (B2).
final class TransferEngineFenceTests: XCTestCase {
    func testATokenChangeGivesAnExplicitBlock() async throws {
        let h = try await TransferEngineHarness()
        let gate = TransferGate()
        h.executor.script("a", .hold(gate))
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The job reaches the transport.") { gate.waiting == 1 }

        h.authorization.setToken("token-2")
        await untilTransfers("The engine blocks.") { await h.engine.currentSnapshot.phase == .blocked(.sessionExpired) }
        let lease = await h.engine.runningLease
        XCTAssertNil(lease, "The running job gives its lease back.")
        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(h.executor.submitted.isEmpty, "Nothing is sent under the new token by a job leased under the old one.")
        let job = try await h.requireJob("a")
        XCTAssertEqual(job.state, .submitting, "The job keeps its stage.")

        let refused = try await h.engine.enqueue([h.photo("b")])
        XCTAssertEqual(refused, .refused(.sessionExpired), "New work is refused, and says why.")
        try await h.engine.setIntent(.manual)
        let phase = await h.engine.currentSnapshot.phase
        XCTAssertEqual(phase, .blocked(.sessionExpired), "Not even the user lifts it: the session that changed tokens is over.")
        XCTAssertEqual(h.executor.calls("a"), 1)
        await h.tearDown()
    }

    func testReadOnlyStopsSubmission() async throws {
        let h = try await TransferEngineHarness()
        let gate = TransferGate()
        h.executor.script("a", .hold(gate), .succeed)
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The job is about to submit.") { gate.waiting == 1 }

        h.authorization.setReadOnly(true)
        await untilTransfers("Read-only blocks the engine.") { await h.engine.currentSnapshot.phase == .blocked(.readOnly) }
        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(h.executor.submitted.isEmpty, "The job checks its lease before it submits, and stops.")
        let saved = try await h.store.engineState()
        XCTAssertEqual(saved?.blocker, "readOnly", "The block is kept across launches.")
        let refused = try await h.engine.enqueue([h.photo("b")])
        XCTAssertEqual(refused, .refused(.readOnly))

        // Read-only off is an automatic trigger: the block stays until the user acts, as
        // BackupCoordinator's pause does today.
        h.authorization.setReadOnly(false)
        try await Task.sleep(for: .milliseconds(100))
        let stillBlocked = await h.engine.currentSnapshot.phase
        XCTAssertEqual(stillBlocked, .blocked(.readOnly))
        await h.engine.conditionsChanged()
        let afterConditions = await h.engine.currentSnapshot.phase
        XCTAssertEqual(afterConditions, .blocked(.readOnly), "A condition event never lifts an account block.")
        XCTAssertEqual(h.executor.calls("a"), 1)

        try await h.engine.setIntent(.automatic)
        try await untilTransfers("The user's command resumes the job.") { try await h.confirmed("a") }
        XCTAssertEqual(h.executor.submitted, ["a"])
        let cleared = try await h.store.engineState()
        XCTAssertNil(cleared?.blocker)
        await h.tearDown()
    }

    func testALocalReadOnlyRefusalPausesWithoutBlamingThePhoto() async throws {
        let h = try await TransferEngineHarness()
        // The request client refused before the engine saw the snapshot change.
        h.executor.script("a", .fail { ReadOnlyPolicy.ReadOnlyError() }, .succeed)
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("Read-only blocks the engine.") { await h.engine.currentSnapshot.phase == .blocked(.readOnly) }
        let job = try await h.requireJob("a")
        XCTAssertEqual(job.retryCount, 0, "The refusal is not counted against the photo.")
        XCTAssertNil(job.errorClass)
        XCTAssertNotEqual(job.state, .failed)

        try await h.engine.setIntent(.automatic)
        try await untilTransfers("The user's command resumes the job.") { try await h.confirmed("a") }
        await h.tearDown()
    }

    func testAFencedWriteRunsAgainUncounted() async throws {
        let h = try await TransferEngineHarness()
        // Read-only went on and off while the request waited.
        h.executor.script("a", .fail { WriteFenced() }, .succeed)
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("The job runs again at once.") { try await h.confirmed("a") }
        XCTAssertEqual(h.executor.calls.map(\.retryCount), [0, 0], "Neither lease counted a failure.")
        let phase = await h.engine.currentSnapshot.phase
        XCTAssertNotEqual(phase, .blocked(.readOnly))
        await h.tearDown()
    }

    func testTheUserCannotLiftReadOnlyWhileItIsOn() async throws {
        let h = try await TransferEngineHarness()
        h.authorization.setReadOnly(true)
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("Read-only blocks the engine.") { await h.engine.currentSnapshot.phase == .blocked(.readOnly) }
        try await h.engine.retry(nil)
        let phase = await h.engine.currentSnapshot.phase
        XCTAssertEqual(phase, .blocked(.readOnly))
        await h.tearDown()
    }

    func testAnAccessChangeLeavesUploadsAlone() async throws {
        let h = try await TransferEngineHarness()
        let gate = TransferGate()
        h.executor.script("a", .hold(gate))
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The job runs.") { gate.waiting == 1 }
        // Losing access to an album's photos fences library reads, not the write generation.
        h.authorization.accessChanged()
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        try await untilTransfers("The upload commits.") { try await h.confirmed("a") }
        await h.tearDown()
    }

    func testAnEndedSessionStopsWithoutBlockingTheNextOne() async throws {
        let h = try await TransferEngineHarness()
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        h.authorization.end()
        await untilTransfers("The engine stops for the ended session.") { await h.engine.currentSnapshot.phase == .blocked(.signedOut) }
        await h.engine.stop()

        let next = TransferEngineHarness.engine(store: h.store, clock: h.clock, authorization: FakeTransferAuthorization(token: "token-2"),
                                                executor: h.executor)
        _ = try await next.enqueue([h.photo("a")])
        try await next.start()
        try await untilTransfers("The next session's engine runs.") { try await h.confirmed("a") }
        await next.stop()
        await h.tearDown()
    }
}

import Foundation
import XCTest
@testable import Ilyich

/// How the transfer engine retries, waits and leaves failures to the user (B2).
final class RetryTests: XCTestCase {
    func testTransientRetriesKeepAutomaticEligible() async throws {
        let h = try await TransferEngineHarness()
        h.executor.script("a", .fail { URLError(.timedOut) }, .succeed)
        // BACKUP-1: a server error retries; it never blocks automatic backup.
        h.executor.script("b", .fail { ServerFailure.http(500, "Internal server error") }, .succeed)
        _ = try await h.engine.enqueue([h.photo("a"), h.photo("b")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("Both jobs schedule a retry.") {
            let a = try await h.job("a")?.state, b = try await h.job("b")?.state
            return a == .retryScheduled && b == .retryScheduled
        }
        let a = try await h.requireJob("a")
        XCTAssertEqual(a.retryCount, 1)
        XCTAssertEqual(a.errorClass, "transient")
        XCTAssertEqual(a.phase, "staged", "A retry keeps the stage.")
        let snapshot = await h.engine.currentSnapshot
        XCTAssertEqual(snapshot.phase, .idle, "Nothing blocks or waits: the jobs are only scheduled.")
        XCTAssertEqual(snapshot.intent, .automatic)
        XCTAssertEqual(snapshot.failed, 0)
        XCTAssertEqual(snapshot.remaining, 2)

        // The first retry waits 30 seconds.
        h.clock.advance(by: .seconds(29))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.executor.calls.count, 2, "Not yet.")
        h.clock.advance(by: .seconds(2))
        try await untilTransfers("Both jobs run again by themselves.") { try await h.allConfirmed("a", "b") }
        XCTAssertEqual(h.executor.calls.map(\.retryCount), [0, 0, 1, 1])
        let retried = h.executor.calls.filter { $0.key == "a" }.last
        XCTAssertEqual(retried?.state, .retryScheduled, "The state says why the job runs again.")
        XCTAssertEqual(retried?.phase, "staged", "The phase says how far it got, so the executor resumes from there.")
        await h.tearDown()
    }

    func testEnvironmentalWaitResumesForManualIntent() async throws {
        let h = try await TransferEngineHarness()
        h.executor.script("a", .fail { URLError(.notConnectedToInternet) }, .succeed)
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.manual)
        try await h.engine.start()
        await untilTransfers("The engine waits for a connection.") { await h.engine.currentSnapshot.phase == .waiting(.connectivity) }
        let job = try await h.requireJob("a")
        XCTAssertEqual(job.retryCount, 0, "A wait is not a failure of the photo.")
        XCTAssertEqual(job.state, .staged)

        // Time alone doesn't end it.
        h.clock.advance(by: .seconds(7_200))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.executor.calls.count, 1)

        await h.engine.conditionsChanged()
        try await untilTransfers("The manual run carries on.") { try await h.confirmed("a") }
        let intent = await h.engine.currentSnapshot.intent
        XCTAssertEqual(intent, .manual)
        await h.tearDown()
    }

    func testAJobWaitingForWiFiLetsTheOthersRun() async throws {
        let h = try await TransferEngineHarness()
        h.executor.script("a", .fail { TransferDeferral.unmeteredNetwork }, .succeed)
        _ = try await h.engine.enqueue([h.photo("a"), h.photo("b")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("The next photo runs.") { try await h.confirmed("b") }
        let waiting = try await h.job("a")
        XCTAssertEqual(waiting?.state, .waiting)
        let phase = await h.engine.currentSnapshot.phase
        XCTAssertEqual(phase, .idle)

        await h.engine.conditionsChanged()
        try await untilTransfers("The waiting photo runs once conditions change.") { try await h.confirmed("a") }
        await h.tearDown()
    }

    func testAutomaticRunSkipsItemFailuresWhileManualRetriesThem() async throws {
        let h = try await TransferEngineHarness()
        h.executor.script("a", .fail { ServerFailure.http(415, "Unsupported file type") }, .succeed)
        _ = try await h.engine.enqueue([h.photo("a"), h.photo("b")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("The run passes the failed photo.") {
            let a = try await h.job("a")?.state
            return try await h.confirmed("b") ? a == .failed : false
        }
        let failures = try await h.engine.failures(limit: 10)
        XCTAssertEqual(failures.map(\.source), [.photo(.init(rawValue: "a"))])
        XCTAssertEqual(failures.first?.message, "Unsupported file type")

        // Time, conditions and another automatic start leave it for the user.
        h.clock.advance(by: .seconds(7_200))
        await h.engine.conditionsChanged()
        try await h.engine.setIntent(.automatic)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.executor.calls("a"), 1)
        let snapshot = await h.engine.currentSnapshot
        XCTAssertEqual(snapshot.failed, 1)
        XCTAssertEqual(snapshot.remaining, 0)

        try await h.engine.setIntent(.manual)
        try await untilTransfers("A manual run retries it.") { try await h.confirmed("a") }
        let none = try await h.engine.failures(limit: 10)
        XCTAssertTrue(none.isEmpty)
        await h.tearDown()
    }

    func testUnknownFailuresRetryFiveTimesThenWaitForTheUser() async throws {
        let h = try await TransferEngineHarness()
        for _ in 0..<6 { h.executor.script("a", .fail { NSError(domain: "Unknown", code: 1) }) }
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        for attempt in 1...5 {
            try await untilTransfers("Retry \(attempt) is scheduled.") { try await h.job("a")?.retryCount == attempt }
            h.clock.advance(by: .seconds(3_600))
        }
        try await untilTransfers("The sixth failure is the photo's.") { try await h.job("a")?.state == .failed }
        XCTAssertEqual(h.executor.calls("a"), 6)
        await h.tearDown()
    }

    func testThreeServerErrorsInARowBackOffTheEngine() async throws {
        let h = try await TransferEngineHarness()
        for key in ["a", "b", "c"] { h.executor.script(key, .fail { ServerFailure.http(503, nil) }, .succeed) }
        _ = try await h.engine.enqueue([h.photo("a"), h.photo("b"), h.photo("c")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The engine backs off.") { await h.engine.currentSnapshot.phase == .waiting(.serverBackoff) }
        let c = try await h.job("c")
        XCTAssertEqual(c?.retryCount, 0, "The photo that met the third error isn't blamed.")

        await h.engine.conditionsChanged()
        h.clock.advance(by: .seconds(60))
        try await untilTransfers("Everything runs again.") { try await h.allConfirmed("a", "b", "c") }
        await h.tearDown()
    }

    func testServerBackoffEndsByItself() async throws {
        let h = try await TransferEngineHarness()
        for key in ["a", "b", "c"] { h.executor.script(key, .fail { ServerFailure.http(502, nil) }, .succeed) }
        _ = try await h.engine.enqueue([h.photo("a"), h.photo("b"), h.photo("c")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The engine backs off.") { await h.engine.currentSnapshot.phase == .waiting(.serverBackoff) }
        h.clock.advance(by: .seconds(3_600))
        try await untilTransfers("The backoff ends without a condition event.") {
            try await h.allConfirmed("a", "b", "c")
        }
        await h.tearDown()
    }
}

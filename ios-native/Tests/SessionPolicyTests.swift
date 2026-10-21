import Foundation
import IlyichPlatform
import Synchronization
import XCTest
@testable import Ilyich

/// Signing in again re-syncs the whole library, so only Immich saying the session is gone, twice,
/// signs out.
final class SessionPolicyTests: XCTestCase {
    /// Counts the second checks, and answers them as told.
    private final class Recheck: Sendable {
        private let calls = Mutex(0)
        private let failure: (any Error & Sendable)?
        init(failing failure: (any Error & Sendable)? = nil) { self.failure = failure }
        var count: Int { calls.withLock { $0 } }
        func run() throws {
            calls.withLock { $0 += 1 }
            if let failure { throw failure }
        }
    }

    private func signsOut(after failure: any Error, recheck: Recheck) async -> Bool {
        await SessionPolicy.confirmsExpiry(after: failure, delay: .zero) { try recheck.run() }
    }

    func testProxyUnauthorizedNeverSignsOut() async throws {
        for status in [401, 403, 407] {
            let recheck = Recheck(failing: ServerFailure.sessionExpired(nil))
            let signedOut = await signsOut(after: ServerFailure.proxyRejected(status), recheck: recheck)
            XCTAssertFalse(signedOut, "A proxy's \(status) is not the session ending.")
            XCTAssertEqual(recheck.count, 0, "It is not even checked again.")
        }

        // The same, from the answer as a proxy sends it.
        let server = makeStubServer()
        server.route("POST", "auth/validateToken", .proxyError(401))
        let api = try APIClient(baseURL: server.baseURL, accessToken: "session-token", userID: "alice",
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        var failure: (any Error)?
        do { try await api.validateToken() } catch { failure = error }
        let refusal = try XCTUnwrap(failure)
        XCTAssertEqual(refusal as? ServerFailure, .proxyRejected(401))
        let signedOut = await SessionPolicy.confirmsExpiry(after: refusal, delay: .zero) { try await api.validateToken() }
        XCTAssertFalse(signedOut)
        XCTAssertEqual(server.requests("POST", "auth/validateToken").count, 1)
    }

    func testForbiddenAndNetworkFailuresNeverSignOut() async {
        let failures: [any Error] = [ServerFailure.forbidden("Forbidden"), ServerFailure.forbidden(nil), ServerFailure.notFound,
                                     ServerFailure.http(500, nil), ServerFailure.credentialsRejected("Incorrect email or password"),
                                     URLError(.notConnectedToInternet), URLError(.timedOut), TransportFailure.allEndpointsUnavailable,
                                     CancellationError(), APIError.signedOut]
        for failure in failures {
            let recheck = Recheck(failing: ServerFailure.sessionExpired(nil))
            let signedOut = await signsOut(after: failure, recheck: recheck)
            XCTAssertFalse(signedOut, "\(failure)")
            XCTAssertEqual(recheck.count, 0, "\(failure)")
        }
    }

    func testAnExpiredSessionSignsOutOnlyWhenTheSecondCheckAgrees() async {
        let expired = ServerFailure.sessionExpired("Invalid user token")
        let confirmed = Recheck(failing: ServerFailure.sessionExpired("Invalid user token"))
        let signedOut = await signsOut(after: expired, recheck: confirmed)
        XCTAssertTrue(signedOut)
        XCTAssertEqual(confirmed.count, 1)

        // The second check finds the session, or can't tell: the session stays.
        let outcomes: [(any Error & Sendable)?] = [nil, ServerFailure.proxyRejected(401), ServerFailure.forbidden(nil), URLError(.networkConnectionLost),
                                        ServerFailure.http(503, nil)]
        for outcome in outcomes {
            let recheck = Recheck(failing: outcome)
            let signedOut = await signsOut(after: expired, recheck: recheck)
            XCTAssertFalse(signedOut, "\(String(describing: outcome))")
            XCTAssertEqual(recheck.count, 1)
        }
    }

    func testACancelledCheckKeepsTheSession() async {
        let task = Task {
            await SessionPolicy.confirmsExpiry(after: ServerFailure.sessionExpired(nil), delay: .seconds(30)) {
                throw ServerFailure.sessionExpired(nil)
            }
        }
        task.cancel()
        let signedOut = await task.value
        XCTAssertFalse(signedOut)
    }

    /// Immich's socket says unauthorized whenever its connection handler fails, a passing database
    /// error among them. When the session check finds the session and keeps it, live updates
    /// carry on: the event stream connects again, as after any other failure.
    @MainActor func testALiveConnectionRefusalTheCheckDoesNotConfirmIsTriedAgain() async throws {
        let server = try LoopbackSocketServer(packets: [#"42["error","unauthorized"]"#])
        let port = try await server.start()
        defer { server.stop() }
        let socket = try APIClient(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), accessToken: "session-token", userID: "alice",
                                   networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await socket.shutdown() }
        // The session check finds the session, so it signs nobody out.
        let harness = try makeSyncHarness(foreground: true, sessionEnds: false, connect: { try await socket.serverEvents() })
        try await harness.primeIndex()

        await harness.engine.start()
        let reconnected = await becomesTrue { server.connections >= 2 }

        XCTAssertTrue(reconnected, "The live connection connects again.")
        XCTAssertTrue(harness.expiries.all.contains { $0.contains("sessionExpired") }, "The refusal reaches the session check as an expired session.")
        let explained = await becomesTrue { harness.status.status.error == "The server rejected the live connection. The library will reconnect." }
        XCTAssertTrue(explained, "Diagnostics says the live connection was refused and will reconnect.")
    }
}

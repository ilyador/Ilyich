import XCTest
@testable import Ilyich

/// The test clock and the stub server behave as later tests rely on.
final class TestSupportTests: XCTestCase {
    func testClockWakesSleepersOnlyWhenTimeReachesThem() async throws {
        let clock = TestClock()
        let woken = Woken()
        let first = Task { try await clock.sleep(for: .seconds(30)); woken.append("30 s") }
        let second = Task { try await clock.sleep(for: .seconds(10)); woken.append("10 s") }
        try await clock.waitForSleepers(2)
        clock.advance(by: .seconds(9))
        XCTAssertEqual(clock.sleeperCount, 2)
        clock.advance(by: .seconds(1))
        try await second.value
        XCTAssertEqual(woken.values, ["10 s"])
        clock.advance(by: .seconds(20))
        try await first.value
        XCTAssertEqual(woken.values, ["10 s", "30 s"])
        XCTAssertEqual(clock.now, TestClock.Instant(offset: .seconds(30)))
        // A deadline already passed returns at once.
        try await clock.sleep(until: clock.now.advanced(by: .seconds(-1)))
    }

    func testCancelledSleeperThrowsAtOnce() async throws {
        let clock = TestClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(60)) }
        try await clock.waitForSleepers()
        sleeper.cancel()
        do { try await sleeper.value; XCTFail("A cancelled sleep must throw.") } catch is CancellationError {}
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testStubServerAnswersInOrderAndRecordsRequests() async throws {
        let server = makeStubServer()
        server.route("POST", "assets/bulk-upload-check", .json(#"{"results":[]}"#), .immichError(401, message: "Invalid user token"))
        let session = URLSession(configuration: server.configuration())
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: server.baseURL.appendingPathComponent("assets/bulk-upload-check"))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"assets":[]}"#.utf8)
        let (body, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"results":[]}"#)
        for _ in 0..<2 {
            let (error, rejected) = try await session.data(for: request)
            let http = try XCTUnwrap(rejected as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 401, "The last answer repeats.")
            XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNotNil(http.value(forHTTPHeaderField: "X-Correlation-ID"), "Immich marks its own errors.")
            XCTAssertEqual(try JSONSerialization.jsonObject(with: error) as? [String: String], ["message": "Invalid user token"])
        }
        let recorded = server.requests("POST", "assets/bulk-upload-check")
        XCTAssertEqual(recorded.count, 3)
        XCTAssertEqual(recorded.first?.body, Data(#"{"assets":[]}"#.utf8))

        let (_, missing) = try await session.data(from: server.baseURL.appendingPathComponent("albums"))
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
    }

    func testStubServerProxyErrorsAndTransportFailures() async throws {
        let server = makeStubServer()
        server.route("GET", "users/me", .proxyError(401), .proxyError(407), .transportFailure(.networkConnectionLost))
        let session = URLSession(configuration: server.configuration())
        defer { session.invalidateAndCancel() }
        let url = server.baseURL.appendingPathComponent("users/me")
        let (page, response) = try await session.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 401)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/html")
        XCTAssertNil(http.value(forHTTPHeaderField: "X-Correlation-ID"))
        XCTAssertNil(try? JSONSerialization.jsonObject(with: page), "A proxy's page is not an Immich error body.")
        let (_, proxy) = try await session.data(from: url)
        XCTAssertEqual((proxy as? HTTPURLResponse)?.statusCode, 407)
        XCTAssertNotNil((proxy as? HTTPURLResponse)?.value(forHTTPHeaderField: "Proxy-Authenticate"))
        do { _ = try await session.data(from: url); XCTFail("The connection was lost.") }
        catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
    }

    func testStubServerGatesAndDelaysAnswers() async throws {
        let server = makeStubServer()
        let gate = StubServer.Gate()
        server.route("GET", "server/ping", StubServer.Response.json(#"{"res":"pong"}"#).waiting(for: gate))
        server.route("GET", "server/version", StubServer.Response.json(#"{"major":2}"#).delayed(by: .milliseconds(300)))
        let session = URLSession(configuration: server.configuration())
        defer { session.invalidateAndCancel() }
        let ping = server.baseURL.appendingPathComponent("server/ping")
        let held = Task { try await session.data(from: ping).0 }
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while gate.waiting == 0, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gate.waiting, 1, "The answer waits for the gate.")
        gate.open()
        let pong = try await held.value
        XCTAssertEqual(String(decoding: pong, as: UTF8.self), #"{"res":"pong"}"#)

        let start = ContinuousClock.now
        _ = try await session.data(from: server.baseURL.appendingPathComponent("server/version"))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(300))
    }

    func testServersNeverShareRoutes() async throws {
        let first = makeStubServer(), second = makeStubServer()
        first.route("GET", "server/ping", .json(#"{"res":"pong"}"#))
        let session = URLSession(configuration: first.configuration())
        defer { session.invalidateAndCancel() }
        let (_, answered) = try await session.data(from: first.baseURL.appendingPathComponent("server/ping"))
        let (_, unrouted) = try await session.data(from: second.baseURL.appendingPathComponent("server/ping"))
        XCTAssertEqual((answered as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((unrouted as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(second.requests.count, 1)
        XCTAssertNotEqual(first.host, second.host)
    }

    private final class Woken: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ value: String) { lock.withLock { stored.append(value) } }
        var values: [String] { lock.withLock { stored } }
    }
}

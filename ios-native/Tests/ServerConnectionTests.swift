import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// How the connection chooses among the configured addresses, checked against stub servers that
/// play Immich, a share-only proxy and addresses that stop answering.
final class ServerConnectionTests: XCTestCase {
    /// A stub that answers the address check as Immich does.
    private func immich(_ pings: StubServer.Response...) -> StubServer {
        let server = makeStubServer()
        server.route("GET", "server/ping", .json(#"{"res":"pong"}"#))
        if !pings.isEmpty { server.route("GET", "server/ping", responses: pings) }
        server.route("GET", "users/me", .immichError(401, message: "Authentication required"))
        return server
    }

    private func connection(preferring addresses: [StubServer], primary: StubServer? = nil) throws -> ServerConnection {
        let configuration = NetworkConfiguration(alternateEndpoints: addresses.map(\.baseURL), automaticallySwitchEndpoints: true)
        return try ServerConnection(server: (primary ?? addresses[0]).baseURL, configuration: configuration, wifiName: NoWiFi(),
                                    probeConfiguration: addresses[0].configuration())
    }

    func testStormOfLostRoutesStartsOneNewCheck() async throws {
        let home = immich(), away = immich()
        let connection = try connection(preferring: [home, away])
        let first = try await connection.route()
        XCTAssertEqual(first.endpoint, home.baseURL)

        // Fifty requests on that route lose it at once, as a scroll does when the network changes.
        let started = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<50 { group.addTask { await connection.routeFailed(first) } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        XCTAssertEqual(started, 1, "Only the first report of a lost route starts a new choice.")
        let routes = await withTaskGroup(of: ServerConnection.Route?.self) { group in
            for _ in 0..<50 { group.addTask { try? await connection.route() } }
            return await group.reduce(into: [ServerConnection.Route?]()) { $0.append($1) }
        }
        let checks = await connection.checks
        XCTAssertEqual(checks, 2, "One check at the start and one for the whole burst.")
        XCTAssertEqual(Set(routes.compactMap { $0 }).count, 1, "Every waiting request gets the same new route.")
        XCTAssertTrue(routes.allSatisfy { $0 != nil && $0?.generation != first.generation })
        // A late report from the old generation changes nothing.
        let late = await connection.routeFailed(first)
        XCTAssertFalse(late)
    }

    func testReportAboutAnAddressNotInUseIsIgnored() async throws {
        let home = immich(), away = immich()
        let connection = try connection(preferring: [home, away])
        let route = try await connection.route()
        XCTAssertEqual(route.endpoint, home.baseURL)
        let stale = await connection.routeFailed(ServerConnection.Route(endpoint: away.baseURL, generation: route.generation))
        XCTAssertFalse(stale, "A request that went elsewhere says nothing about the chosen address.")
        let again = try await connection.route()
        let checks = await connection.checks
        XCTAssertEqual(again, route)
        XCTAssertEqual(checks, 1)
    }

    func testShareOnlyProxyIsNotChosen() async throws {
        // It answers ping, but hides the API: Immich answers an anonymous users/me with 401, never 404.
        let shareProxy = makeStubServer()
        shareProxy.route("GET", "server/ping", .json(#"{"res":"pong"}"#))
        shareProxy.route("GET", "users/me", .json(#"{"message":"Cannot GET /api/users/me"}"#, status: 404))
        let server = immich()
        let connection = try connection(preferring: [shareProxy, server])
        let endpoint = try await connection.endpoint()
        XCTAssertEqual(endpoint, server.baseURL)
        XCTAssertEqual(shareProxy.requests("GET", "users/me").count, 1, "The proxy was checked, and turned down.")
    }

    func testLastGoodAddressIsKeptWhenEveryCheckFails() async throws {
        let home = immich(.json(#"{"res":"pong"}"#), .transportFailure(.timedOut))
        let away = immich(.transportFailure(.cannotConnectToHost))
        let connection = try connection(preferring: [home, away])
        let first = try await connection.route()
        XCTAssertEqual(first.endpoint, home.baseURL)
        await connection.routeFailed(first)
        // A busy server that misses a check keeps its place rather than failing every request.
        let second = try await connection.route()
        XCTAssertEqual(second.endpoint, home.baseURL)
        XCTAssertNotEqual(second.generation, first.generation)
    }

    func testNothingAnsweringAndNothingKnownIsAnHonestFailure() async throws {
        let home = immich(.transportFailure(.cannotConnectToHost)), away = immich(.transportFailure(.timedOut))
        let connection = try connection(preferring: [home, away])
        do {
            _ = try await connection.route()
            XCTFail("No address answered.")
        } catch {
            XCTAssertEqual(error as? TransportFailure, .allEndpointsUnavailable)
        }
    }

    func testAddressesAreCheckedTogetherInPreferenceOrder() async throws {
        let gate = StubServer.Gate()
        let home = immich(StubServer.Response.json(#"{"res":"pong"}"#).waiting(for: gate))
        let away = immich()
        let connection = try connection(preferring: [home, away])
        let chosen = Task { try await connection.endpoint() }
        // The second address is checked in full while the first is still out.
        try await until { away.requests("GET", "users/me").count == 1 && gate.waiting == 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(home.requests("GET", "users/me").count, 0)
        gate.open()
        let endpoint = try await chosen.value
        XCTAssertEqual(endpoint, home.baseURL, "The preferred address wins once it answers, though it answered last.")
    }

    func testAPreferredAddressThatFailsLetsTheNextOneIn() async throws {
        let gate = StubServer.Gate()
        let home = immich(StubServer.Response.transportFailure(.cannotConnectToHost).waiting(for: gate))
        let away = immich()
        let connection = try connection(preferring: [home, away])
        let chosen = Task { try await connection.endpoint() }
        try await until { away.requests("GET", "users/me").count == 1 }
        gate.open()
        let endpoint = try await chosen.value
        XCTAssertEqual(endpoint, away.baseURL)
    }

    func testRequestsWaitingForACheckMoveToTheNewOne() async throws {
        let gate = StubServer.Gate()
        let home = immich(StubServer.Response.json(#"{"res":"pong"}"#).waiting(for: gate), .json(#"{"res":"pong"}"#))
        let connection = try connection(preferring: [home, immich()])
        let waiters = (0..<5).map { _ in Task { try await connection.route() } }
        try await until { gate.waiting == 1 }
        await connection.invalidate()
        gate.open()
        for waiter in waiters {
            let route = try await waiter.value
            XCTAssertEqual(route.endpoint, home.baseURL, "A replaced check hands its waiters to the new one.")
        }
        let checks = await connection.checks
        XCTAssertEqual(checks, 2)
    }

    func testShutdownEndsWaitersAndLaterRequests() async throws {
        let gate = StubServer.Gate()
        let home = immich(StubServer.Response.json(#"{"res":"pong"}"#).waiting(for: gate))
        let connection = try connection(preferring: [home, immich()])
        let waiter = Task { try await connection.route() }
        try await until { gate.waiting == 1 }
        await connection.shutdown()
        gate.open()
        do { _ = try await waiter.value; XCTFail("A shut down connection chooses nothing.") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        do { _ = try await connection.route(); XCTFail("A shut down connection chooses nothing.") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func testWithoutSwitchingThePrimaryAddressIsUsedUnchecked() async throws {
        let server = immich()
        let connection = try ServerConnection(server: server.baseURL, configuration: NetworkConfiguration(), wifiName: NoWiFi(),
                                              probeConfiguration: server.configuration())
        let route = try await connection.route()
        let checks = await connection.checks
        XCTAssertEqual(route.endpoint, server.baseURL)
        XCTAssertEqual(checks, 0)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testPreferredAnswerWaitsOnlyForEarlierAddresses() {
        XCTAssertEqual(ServerConnection.preferredAnswer([true, nil, nil]), 0)
        XCTAssertNil(ServerConnection.preferredAnswer([nil, true, true]), "The first address is still being checked.")
        XCTAssertEqual(ServerConnection.preferredAnswer([false, true, nil]), 1)
        XCTAssertEqual(ServerConnection.preferredAnswer([false, false, true]), 2)
        XCTAssertNil(ServerConnection.preferredAnswer([false, false, false]))
        XCTAssertNil(ServerConnection.preferredAnswer([]))
    }

    // MARK: - Saved settings

    /// An entry a newer rule rejects costs only that entry; loading keeps the rest and never fails.
    func testSavedSettingsLoseOnlyTheEntriesNoLongerAllowed() throws {
        let saved = NetworkConfiguration(customHeaders: ["CF-Access-Client-Id": "id", "x-immich-user-token": "override", "Bad Name": "x"],
                                         alternateEndpoints: [URL(string: "https://tailnet.example")!, URL(string: "ftp://old.example")!,
                                                              URL(string: "https://tailnet.example/api")!],
                                         automaticallySwitchEndpoints: true, preferredWifiName: "  Home  ",
                                         localEndpoint: URL(string: "file:///not-a-server")!)
        XCTAssertThrowsError(try saved.validated(), "Saving still refuses them.")
        let (usable, dropped) = saved.usable()
        XCTAssertEqual(dropped, 4)
        XCTAssertEqual(usable.customHeaders, ["CF-Access-Client-Id": "id"])
        XCTAssertEqual(usable.alternateEndpoints, [URL(string: "https://tailnet.example/api")!])
        XCTAssertNil(usable.localEndpoint)
        XCTAssertEqual(usable.preferredWifiName, "Home")
        XCTAssertTrue(usable.automaticallySwitchEndpoints)
        XCTAssertNoThrow(try usable.validated())

        let valid = try FixtureLoader.decode(NetworkConfiguration.self, from: "session/network-config-v1.json")
        XCTAssertEqual(valid.usable().configuration, try valid.validated())
        XCTAssertEqual(valid.usable().dropped, 0)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for the checks.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// No Wi-Fi network, so no local address is preferred.
struct NoWiFi: WiFiNameProviding {
    func currentName() async -> String? { nil }
}

import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// Work begun under one authorization never lands under another: writes queued across a
/// read-only toggle, places counted across an access change. Coverage after sign-out is pinned
/// in CoverageWorkerTests.
@MainActor final class FencingTests: XCTestCase {
    // MARK: - Writes

    /// Writes wait while the address is chosen. Read-only mode coming on meanwhile refuses them,
    /// and so does read-only mode coming on and going off again, since they were asked for under
    /// the setting before. Reads waiting with them go as usual.
    func testReadOnlyToggleFencesQueuedWrites() async throws {
        let server = makeStubServer()
        let firstCheck = StubServer.Gate(), secondCheck = StubServer.Gate()
        let pong = StubServer.Response.json(#"{"res":"pong"}"#)
        server.route("GET", "server/ping", pong.waiting(for: firstCheck), pong.waiting(for: secondCheck))
        server.route("GET", "users/me", .immichError(401, message: "Authentication required"))
        server.route("GET", "albums", .json("[]"))
        server.route("POST", "albums", .immichError(500, message: "Not expected"))
        let state = AuthorizationState(account: AccountID(server: server.baseURL, userID: "alice"), token: "session-token", readOnly: false,
                                       requiresPasswordChange: false, mirror: nil)
        let api = try APIClient(baseURL: server.baseURL, accessToken: "session-token", userID: "alice", sessionConfiguration: server.configuration(),
                                networkConfiguration: NetworkConfiguration(alternateEndpoints: [server.baseURL], automaticallySwitchEndpoints: true),
                                wifiName: NoWiFi(), authorization: state)
        addTeardownBlock { await api.shutdown() }

        // Read-only mode comes on while a write waits.
        let write = Task { try await api.createAlbum(name: "Trip") }
        try await until("The write did not wait for the address.") { firstCheck.waiting == 1 }
        let read = Task { try await api.albums() }
        state.setReadOnly(true)
        firstCheck.open()
        let albums = try await read.value
        XCTAssertEqual(albums, [], "A read waiting with it still goes.")
        do { _ = try await write.value; XCTFail("A write queued before read-only mode is not sent.") }
        catch { XCTAssertTrue(error is ReadOnlyPolicy.ReadOnlyError, "\(error)") }
        do { _ = try await api.createAlbum(name: "Now"); XCTFail("Nor is one asked for while it is on.") }
        catch { XCTAssertTrue(error is ReadOnlyPolicy.ReadOnlyError, "\(error)") }

        // Read-only mode comes on and goes off again while another write waits.
        state.setReadOnly(false)
        await api.transport.connection.invalidate()
        let later = Task { try await api.createAlbum(name: "Later") }
        try await until("The second write did not wait for the address.") { secondCheck.waiting == 1 }
        state.setReadOnly(true)
        state.setReadOnly(false)
        secondCheck.open()
        do { _ = try await later.value; XCTFail("A write queued across a read-only toggle is not sent.") }
        catch { XCTAssertEqual(error as? WriteFenced, WriteFenced(), "\(error)") }
        let reads = try await api.albums()
        XCTAssertEqual(reads, [])
        XCTAssertTrue(server.requests("POST", "albums").isEmpty, "No queued write reached the server.")
    }

    // MARK: - Places

    /// The index keeps a feed's places only while the access epoch they were counted under is
    /// current: a write whose epoch moved meanwhile is refused, one under the current epoch is
    /// kept, and an access change drops every feed's places.
    func testPlacesKeptUnderAStaleEpochAreRefused() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FencingTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let index = try LibraryIndex(scope: "https://fencing.example.test/api|alice", userID: "alice", directory: directory)
        let authorization = AuthorizationState(account: AccountID(server: URL(string: "https://fencing.example.test/api")!, userID: "alice"),
                                               token: "session", readOnly: false, requiresPasswordChange: false, mirror: nil)
        let rows = [MonthPlaceCount(bucket: "2026-02-01", city: "Kyoto", country: "Japan", count: 4)]
        let key = LibraryQuery.library.stableKey

        let before = authorization.snapshot.epoch
        authorization.accessChanged()
        try await index.keepMonthPlaces(rows, forKey: key, ifCurrent: { authorization.isCurrent(before) })
        let refused = try await index.monthPlaces(forKey: key)
        XCTAssertNil(refused, "Places counted before the access change are refused.")

        let now = authorization.snapshot.epoch
        try await index.keepMonthPlaces(rows, forKey: key, ifCurrent: { authorization.isCurrent(now) })
        let kept = try await index.monthPlaces(forKey: key)
        XCTAssertEqual(kept, rows, "Places counted after it are kept.")
        // A read-only toggle moves no access epoch, so it keeps them too.
        authorization.setReadOnly(true)
        XCTAssertTrue(authorization.isCurrent(now))

        try await index.clearMonthPlaces()
        let cleared = try await index.monthPlaces(forKey: key)
        XCTAssertNil(cleared, "An access change drops every feed's places.")
    }

    // MARK: - Support

    private func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

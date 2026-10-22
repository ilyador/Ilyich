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

    /// A clear of an account's places moves its epoch: a save made under the epoch from before is
    /// refused, one made under the new epoch is kept, and other accounts are untouched.
    func testPlacesSavedUnderAStaleEpochAreRefused() async throws {
        let scope = "test-fencing-" + UUID().uuidString, other = "test-fencing-" + UUID().uuidString
        let cache = TimelinePlacesCache.shared
        addTeardownBlock { await cache.removeAll(scope: scope); await cache.removeAll(scope: other) }
        let places = TimelinePlaces(counts: [MonthPlaceCount(bucket: "2026-02-01", city: "Kyoto", country: "Japan", count: 4)])
        let before = await cache.epoch(scope: scope), otherBefore = await cache.epoch(scope: other)

        await cache.removeAll(scope: scope)
        let stale = await cache.save(places, scope: scope, query: .library, epoch: before)
        XCTAssertFalse(stale, "Places counted before the clear are refused.")
        let refused = await cache.load(scope: scope, query: .library)
        XCTAssertNil(refused)

        let current = await cache.save(places, scope: scope, query: .library, epoch: cache.epoch(scope: scope))
        XCTAssertTrue(current)
        let kept = await cache.load(scope: scope, query: .library)
        XCTAssertEqual(kept, places, "Places counted after it are kept.")
        let untouched = await cache.save(places, scope: other, query: .library, epoch: otherBefore)
        XCTAssertTrue(untouched, "Another account's clear changes nothing here.")
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

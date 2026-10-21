import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// Work begun under one authorization never lands under another: the warmer after sign-out,
/// writes queued across a read-only toggle, places counted across an access change.
@MainActor final class FencingTests: XCTestCase {
    // MARK: - Warmer

    /// Sign-out stops the warmer while it is still checking that the offline library is
    /// complete. The check finishing afterwards, or a sync finishing after sign-out, must not
    /// start it: it would download the signed-out account's thumbnails.
    func testWarmerCannotStartAfterSignOut() async throws {
        let (entities, pipeline) = try library()
        let session = AuthorizationState(account: LegacyGoldens.account, token: "session-token", readOnly: false,
                                         requiresPasswordChange: false, mirror: nil)
        let warmer = ThumbnailWarmer(session: session)
        let checking = StubServer.Gate(), answer = StubServer.Gate()
        warmer.start(when: { checking.open(); await answer.wait(); return true }, entities: entities, pipeline: pipeline)
        await checking.wait()

        // Sign-out ends the session and stops the warmer, as SessionStore.signOut does.
        session.end()
        warmer.stop()
        answer.open()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(warmer.isRunning, "A check that finishes after sign-out does not start the warmer.")
        warmer.start(entities: entities, pipeline: pipeline)
        XCTAssertFalse(warmer.isRunning, "Nor does a sync that finishes after sign-out.")

        // The session alone fences it, should anything forget to stop the warmer.
        let ended = ThumbnailWarmer(session: session)
        ended.start(entities: entities, pipeline: pipeline)
        XCTAssertFalse(ended.isRunning, "A warmer of an ended session never starts.")
        ended.stop()
    }

    /// Without sign-out, the same check starts the warmer once the library is complete.
    func testWarmerStartsOnceTheLibraryIsComplete() async throws {
        let (entities, pipeline) = try library()
        let session = AuthorizationState(account: LegacyGoldens.account, token: "session-token", readOnly: false,
                                         requiresPasswordChange: false, mirror: nil)
        let warmer = ThumbnailWarmer(session: session)
        defer { warmer.stop() }
        let incomplete = ThumbnailWarmer(session: session)
        defer { incomplete.stop() }
        incomplete.start(when: { false }, entities: entities, pipeline: pipeline)
        warmer.start(when: { true }, entities: entities, pipeline: pipeline)
        try await until("The warmer did not start.") { warmer.isRunning }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(incomplete.isRunning, "An incomplete library is not warmed.")
    }

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
        let stale = await cache.save(places, scope: scope, filter: TimelineFilter(), epoch: before)
        XCTAssertFalse(stale, "Places counted before the clear are refused.")
        let refused = await cache.load(scope: scope, filter: TimelineFilter())
        XCTAssertNil(refused)

        let current = await cache.save(places, scope: scope, filter: TimelineFilter(), epoch: cache.epoch(scope: scope))
        XCTAssertTrue(current)
        let kept = await cache.load(scope: scope, filter: TimelineFilter())
        XCTAssertEqual(kept, places, "Places counted after it are kept.")
        let untouched = await cache.save(places, scope: other, filter: TimelineFilter(), epoch: otherBefore)
        XCTAssertTrue(untouched, "Another account's clear changes nothing here.")
    }

    // MARK: - Support

    /// An empty offline library and a media pipeline of its own, removed when the test ends.
    private func library() throws -> (EntityStore, MediaPipeline) {
        let userID = "fencing-" + UUID().uuidString
        let api = try APIClient(baseURL: XCTUnwrap(URL(string: "https://fencing.example")), accessToken: "session-token", userID: userID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FencingTests-" + UUID().uuidString, isDirectory: true)
        let entities = try EntityStore(scope: api.cacheScope, userID: userID, directory: directory)
        let pipeline = MediaPipeline(client: api)
        addTeardownBlock {
            await pipeline.removeAll()
            await api.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        return (entities, pipeline)
    }

    private func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

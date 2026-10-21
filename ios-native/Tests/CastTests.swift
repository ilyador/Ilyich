import Foundation
import IlyichPlatform
import Synchronization
import XCTest
@testable import Ilyich

/// Cast grants and the Cast session (REBUILD_ROADMAP.md W2), over fakes of the server and the
/// receiver.
final class CastTests: XCTestCase {
    // MARK: - Grants

    func testConcurrentRequestsCreateOneChildSession() async throws {
        let server = FakeCastServer(), gate = StubServer.Gate()
        server.hold(gate)
        let store = CastGrantStore(server: server, now: server.now)

        let grants = (0..<5).map { _ in Task { try await store.grant(covering: 0) } }
        try await until("The first ask reached the server.") { server.created.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        var ids = Set<String>()
        for grant in grants { ids.insert(try await grant.value.id) }

        XCTAssertEqual(server.created, [900], "One child session, of the shortest lifetime, for every ask.")
        XCTAssertEqual(ids, ["grant-1"])
        _ = try await store.grant(covering: 0)
        XCTAssertEqual(server.created.count, 1, "A grant with time left is reused.")
    }

    func testVideoGrantCoversPlaybackDuration() async throws {
        XCTAssertEqual(CastGrantStore.duration(covering: 0), 900, "A photo gets the shortest grant.")
        XCTAssertEqual(CastGrantStore.duration(covering: 7_200), 7_500, "A video gets its length and five minutes.")
        XCTAssertEqual(CastGrantStore.duration(covering: 36_000), 21_600, "Never longer than six hours.")
        var video = Asset(id: "video", type: .video)
        video.duration = 7_199_400
        XCTAssertEqual(CastEligibility.need(for: video), 7_200)
        XCTAssertEqual(CastEligibility.need(for: Asset(id: "photo")), 0)

        let server = FakeCastServer()
        let store = CastGrantStore(server: server, now: server.now)
        let photo = try await store.grant(covering: 0)
        let long = try await store.grant(covering: CastEligibility.need(for: video))
        XCTAssertEqual(server.created, [900, 7_500], "A grant too short for the video is not reused.")
        XCTAssertNotEqual(photo.id, long.id)
        XCTAssertGreaterThanOrEqual(long.expiresAt.timeIntervalSince(server.now()), 7_200 + 60)

        server.advance(by: 200)
        _ = try await store.grant(covering: 7_200)
        XCTAssertEqual(server.created.count, 2, "Still the video's length and a minute left: reused.")
        server.advance(by: 50)
        _ = try await store.grant(covering: 7_200)
        XCTAssertEqual(server.created, [900, 7_500, 7_500], "Less than a minute to spare: a new grant.")

        await store.revoke()
        XCTAssertEqual(Set(server.revoked), ["grant-1", "grant-2", "grant-3"], "Grants a longer one replaced are revoked too.")
    }

    @MainActor
    func testStopAndSessionEndRevokeGrant() async throws {
        let harness = CastHarness()
        harness.service.select(api: harness.api, asset: Asset(id: "photo-1"), start: true)
        try await until("The photo reached the TV.") { harness.link.loads.count == 1 }

        harness.service.disconnect()
        try await until("Stop revoked the grant.") { harness.server.revoked == ["grant-1"] }
        XCTAssertEqual(harness.link.endedSessions, 1)

        harness.link.isConnected = true
        harness.service.castLinkStarted()
        try await until("Casting started again with a new grant.") { harness.link.loads.count == 2 }
        harness.link.isConnected = false
        harness.service.castLinkEnded(withError: false)
        try await until("The Cast session's end revoked its grant.") { harness.server.revoked == ["grant-1", "grant-2"] }

        harness.link.isConnected = true
        harness.service.castLinkStarted()
        try await until("Casting started a third time.") { harness.link.loads.count == 3 }
        harness.service.attach(nil)
        try await until("Another account revoked the grant.") { harness.server.revoked == ["grant-1", "grant-2", "grant-3"] }
        XCTAssertNil(harness.service.currentAssetID)
    }

    /// Sign-out waits for the grants to be revoked, and the store makes none afterwards.
    @MainActor
    func testSignOutAwaitsTheRevokeAndClosesTheStore() async throws {
        let harness = CastHarness()
        harness.service.select(api: harness.api, asset: Asset(id: "photo-1"), start: true)
        try await until("The photo reached the TV.") { harness.link.loads.count == 1 }

        await harness.service.signOut()
        XCTAssertEqual(harness.server.revoked, ["grant-1"], "Revoked before sign-out goes on.")
        await harness.grants.close()
        do { _ = try await harness.grants.grant(covering: 0); XCTFail("A closed store made a grant.") }
        catch { XCTAssertEqual(error as? CastGrantError, .closed) }
    }

    /// A grant still being made when casting stops is revoked as soon as it arrives.
    func testAGrantArrivingAfterTheRevokeIsRevoked() async throws {
        let server = FakeCastServer(), gate = StubServer.Gate()
        server.hold(gate)
        let store = CastGrantStore(server: server, now: server.now)
        let asked = Task { try await store.grant(covering: 0) }
        try await until("The ask reached the server.") { server.created.count == 1 }
        let revoked = Task { await store.revoke() }
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        await revoked.value
        XCTAssertEqual(server.revoked, ["grant-1"])
        do { _ = try await asked.value; XCTFail("A revoked grant was handed out.") } catch is CancellationError {}
        let current = await store.currentGrant
        XCTAssertNil(current)
    }

    // MARK: - Server

    func testPreflightUsesChildToken() async throws {
        let server = makeStubServer()
        server.route("HEAD", "assets/photo-1/thumbnail", StubServer.Response(status: 200, headers: ["Content-Type": "image/jpeg"]))
        server.route("HEAD", "assets/video-1/video/playback", StubServer.Response(status: 200, headers: ["Content-Type": "video/mp4"]))
        let api = try client(server)
        let grant = CastGrant(id: "child-1", token: "child+token", expiresAt: .distantFuture)

        let photo = try await CastMediaResolver(api: api).media(for: Asset(id: "photo-1"), grant: grant)
        let video = try await CastMediaResolver(api: api).media(for: Asset(id: "video-1", type: .video), grant: grant)

        XCTAssertEqual(photo.contentType, "image/jpeg")
        XCTAssertEqual(video.contentType, "video/mp4")
        let heads = server.requests.filter { $0.method == "HEAD" }
        XCTAssertEqual(heads.map(\.path), ["assets/photo-1/thumbnail", "assets/video-1/video/playback"])
        for head in heads {
            XCTAssertEqual(head.query.first { $0.name == "sessionKey" }?.value, "child+token", "The preflight carries the grant's token.")
            XCTAssertFalse(head.headers.values.contains { $0.contains("app-token") }, "The preflight never carries the app's token: \(head.headers)")
        }
        XCTAssertTrue(photo.url.absoluteString.contains("sessionKey=child%2Btoken"), photo.url.absoluteString)
        XCTAssertFalse(photo.url.absoluteString.contains("app-token"))
    }

    /// Revoking a grant deletes only its child session: never the app's own session, never every
    /// other session, and it never logs out.
    func testRevokingAGrantDeletesOnlyItsChildSession() async throws {
        let server = makeStubServer()
        server.route("POST", "sessions", .json(#"{"id":"0b5e-child","token":"child","expiresAt":"2099-01-01T00:00:00.000Z","current":false}"#),
                     .json(#"{"id":"0b5e-app","token":"app","expiresAt":"2099-01-01T00:00:00.000Z","current":true}"#),
                     .json(#"{"id":"","token":"child","expiresAt":"2099-01-01T00:00:00.000Z"}"#))
        server.route("DELETE", "sessions/0b5e-child", .empty())
        let api = try client(server)
        let store = CastGrantStore(server: api)

        let grant = try await store.grant(covering: 0)
        XCTAssertEqual(grant.id, "0b5e-child")
        XCTAssertEqual(try XCTUnwrap(server.requests("POST", "sessions").first?.body).jsonObject["duration"] as? Int, 900)
        await store.revoke()
        for _ in 0..<2 {
            do { _ = try await store.grant(covering: 0); XCTFail("An unmanageable session was used as a grant.") }
            catch { XCTAssertEqual(error as? CastGrantError, .unusableGrant) }
        }
        await store.revoke()
        try await api.revokeCastGrant(id: "")
        try await api.revokeCastGrant(id: "../auth")

        XCTAssertEqual(server.requests.map { $0.method + " " + $0.path },
                       ["POST sessions", "DELETE sessions/0b5e-child", "POST sessions", "POST sessions"])
    }

    // MARK: - Session

    @MainActor
    func testStaleLoadFailureDoesNotOverwriteNewerLoad() async throws {
        let harness = CastHarness()
        let gate = StubServer.Gate()
        harness.resolver.hold("photo-a", until: gate, thenFail: true)
        harness.service.select(api: harness.api, asset: Asset(id: "photo-a"), start: true)
        try await until("Photo A is being resolved.") { harness.resolver.asked.contains("photo-a") }
        harness.service.select(api: harness.api, asset: Asset(id: "photo-b"), start: true)
        try await until("Photo B reached the TV.") { harness.link.loads.count == 1 }
        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(harness.service.error, "A's failure came after B's load.")
        XCTAssertEqual(harness.service.currentAssetID, "photo-b")
        XCTAssertEqual(harness.link.loads.map(\.media.url.lastPathComponent), ["photo-b"])

        harness.service.retry()
        try await until("B loaded again.") { harness.link.loads.count == 2 }
        harness.link.loads[0].finished(false)
        XCTAssertNil(harness.service.error, "The receiver's answer to an older load changes nothing.")
        XCTAssertTrue(harness.service.loading)
        harness.link.loads[1].finished(true)
        XCTAssertFalse(harness.service.loading)
        XCTAssertEqual(harness.service.currentAssetID, "photo-b")
    }

    @MainActor
    func testFollowingIntoLockedAssetKeepsCurrentMedia() async throws {
        let harness = CastHarness()
        harness.service.select(api: harness.api, asset: Asset(id: "photo-1"), start: true)
        try await until("The photo reached the TV.") { harness.link.loads.count == 1 }
        harness.link.loads[0].finished(true)

        var locked = Asset(id: "locked-1")
        locked.visibility = .locked
        harness.service.select(api: harness.api, asset: locked)
        harness.service.select(api: harness.api, asset: locked, start: true)
        harness.service.retry()
        try await until("Retry reloaded the photo.") { harness.link.loads.count == 2 }

        XCTAssertFalse(harness.resolver.asked.contains("locked-1"), "A locked photo never reaches the TV.")
        XCTAssertEqual(harness.link.loads.map(\.media.url.lastPathComponent), ["photo-1", "photo-1"])
        XCTAssertEqual(harness.service.currentAssetID, "photo-1")

        harness.service.select(api: harness.api, asset: Asset(id: "photo-2"))
        try await until("Following goes on past the locked photo.") { harness.link.loads.count == 3 }
        XCTAssertEqual(harness.link.loads.last?.media.url.lastPathComponent, "photo-2")
    }

    // MARK: - Support

    private func client(_ server: StubServer) throws -> APIClient {
        let api = try APIClient(baseURL: server.baseURL, accessToken: "app-token", userID: "alice", sessionConfiguration: server.configuration(),
                                networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        return api
    }

    private func until(_ message: String, timeout: Duration = .seconds(5), isolation: isolated (any Actor)? = #isolation,
                       _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private extension Data {
    var jsonObject: [String: Any] { ((try? JSONSerialization.jsonObject(with: self)) as? [String: Any]) ?? [:] }
}

/// A server that makes grants named grant-1, grant-2… expiring on its own clock.
private final class FakeCastServer: CastGrantServer {
    private let state = Mutex<(created: [Int], revoked: [String], clock: Date, gate: StubServer.Gate?)>(([], [], Date(timeIntervalSince1970: 1_800_000_000), nil))

    var created: [Int] { state.withLock { $0.created } }
    var revoked: [String] { state.withLock { $0.revoked } }
    var now: @Sendable () -> Date { { [self] in self.state.withLock { $0.clock } } }
    func advance(by seconds: TimeInterval) { state.withLock { $0.clock.addTimeInterval(seconds) } }
    /// Answers wait for `gate`.
    func hold(_ gate: StubServer.Gate) { state.withLock { $0.gate = gate } }

    func createCastGrant(seconds: Int) async throws -> CastGrant {
        let (number, gate) = state.withLock { state in state.created.append(seconds); return (state.created.count, state.gate) }
        await gate?.wait()
        let expiry = state.withLock { $0.clock }.addingTimeInterval(TimeInterval(seconds))
        return CastGrant(id: "grant-\(number)", token: "token-\(number)", expiresAt: expiry)
    }

    func revokeCastGrant(id: String) async throws { state.withLock { $0.revoked.append(id) } }
}

/// Media at https://tv.test/<asset id>. An asset can be held back and then fail.
private final class FakeCastResolver: CastMediaResolving {
    private let state = Mutex<(asked: [String], held: [String: (StubServer.Gate, Bool)])>(([], [:]))

    var asked: [String] { state.withLock { $0.asked } }
    func hold(_ assetID: String, until gate: StubServer.Gate, thenFail: Bool) { state.withLock { $0.held[assetID] = (gate, thenFail) } }

    func media(for asset: Asset, grant: CastGrant) async throws -> CastMedia {
        let held = state.withLock { state in state.asked.append(asset.id); return state.held[asset.id] }
        if let held {
            await held.0.wait()
            if held.1 { throw URLError(.timedOut) }
        }
        return CastMedia(url: URL(string: "https://tv.test/\(asset.id)")!, contentType: "image/jpeg")
    }
}

@MainActor
private final class FakeCastLink: CastReceiverLink {
    struct Load { let media: CastMedia; let finished: @MainActor (Bool) -> Void }
    weak var events: (any CastLinkEvents)?
    var isConnected = true
    var receiverName = "Living room"
    var loads: [Load] = []
    var endedSessions = 0

    func load(_ media: CastMedia, title: String, isVideo: Bool, finished: @escaping @MainActor (Bool) -> Void) {
        loads.append(Load(media: media, finished: finished))
    }
    func cancelLoad() {}
    func endSession() { endedSessions += 1; isConnected = false }
    func showControls() {}
}

/// A service on a connected fake receiver, attached to an account over the fakes.
@MainActor
private struct CastHarness {
    let server = FakeCastServer()
    let resolver = FakeCastResolver()
    let link = FakeCastLink()
    let api: APIClient
    let grants: CastGrantStore
    let service: CastSessionService

    init() {
        api = try! APIClient(baseURL: URL(string: "https://cast.test/api")!, accessToken: "app-token", userID: "alice",
                             networkConfiguration: NetworkConfiguration())
        grants = CastGrantStore(server: server, now: server.now)
        service = CastSessionService(link: link)
        service.attach(CastAccount(scope: api.cacheScope, grants: grants, resolver: resolver))
    }
}

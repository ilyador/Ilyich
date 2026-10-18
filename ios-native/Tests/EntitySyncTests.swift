import Foundation
import XCTest
@testable import Ilyich

@MainActor
final class EntitySyncTests: XCTestCase {
    private func makeStore(_ root: URL, scope: String = "server|alice") throws -> EntityStore {
        try EntityStore(scope: scope, userID: "alice", directory: root)
    }
    private func event(_ type: String, _ json: String, ack: String? = nil) throws -> EntitySyncEvent {
        .init(type: type, data: try JSONDecoder().decode([String: EntityJSON].self, from: Data(json.utf8)), ack: ack ?? type + "|1")
    }
    private func asset(_ id: String, owner: String = "alice", visibility: String = "timeline", deleted: Bool = false, favorite: Bool = false, stack: String? = nil) throws -> EntitySyncEvent {
        try event("AssetV2", """
        {"id":"\(id)","ownerId":"\(owner)","type":"IMAGE","originalFileName":"\(id).NEF","checksum":"AQIDBA==","width":6000,"height":4000,"fileCreatedAt":"2026-01-31T23:30:00Z","localDateTime":"2026-02-01T05:00:00Z","createdAt":"2026-03-01T00:00:00Z","visibility":"\(visibility)","isFavorite":\(favorite),"deletedAt":\(deleted ? "\"2026-03-04T00:00:00Z\"" : "null"),"stackId":\(stack.map { "\"\($0)\"" } ?? "null"),"isEdited":false,"isDeveloped":true,"mediaRevision":"xmp-7"}
        """, ack: "AssetV2|\(id)")
    }
    func testDurableCommitRetainsUnacknowledgedCursorAcrossReopenAndIsolatesAccounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        let needsReset = try await store.prepare(sessionFingerprint: "session-one")
        XCTAssertTrue(needsReset)
        _ = try await store.apply([asset("photo"), event("SyncCompleteV1", "{}", ack: "SyncCompleteV1|finished")], epoch: epoch)
        try await store.markResetRequested()
        let reopened = try makeStore(root)
        let cached = try await reopened.asset(id: "photo")
        XCTAssertEqual(cached?.cacheRevision, "xmp-7")
        let pending = try await reopened.pendingAcknowledgements()
        XCTAssertEqual(Set(pending), ["AssetV2|photo", "SyncCompleteV1|finished"])
        let sameSession = try await reopened.prepare(sessionFingerprint: "session-one")
        XCTAssertFalse(sameSession)
        try await reopened.acknowledged(["AssetV2|older"])
        let stillPending = try await reopened.pendingAcknowledgements()
        XCTAssertTrue(stillPending.contains("AssetV2|photo"))
        let other = try makeStore(root, scope: "server|bob")
        let otherAsset = try await other.asset(id: "photo")
        XCTAssertNil(otherAsset)
        let changedSession = try await reopened.prepare(sessionFingerprint: "session-two")
        XCTAssertTrue(changedSession)
        let removed = try await reopened.asset(id: "photo")
        XCTAssertNil(removed)
    }
    func testInvalidBatchRollsBackEntitiesAndCheckpointsTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        do {
            _ = try await store.apply([asset("photo"), event("UnsupportedV99", "{}")], epoch: epoch)
            XCTFail("Unknown events must not be silently acknowledged")
        } catch is APIError { }
        let removed = try await store.asset(id: "photo"), pending = try await store.pendingAcknowledgements()
        XCTAssertNil(removed); XCTAssertTrue(pending.isEmpty)
        _ = try await store.apply([asset("photo")], epoch: epoch)
        _ = try await store.apply([event("SyncAckV1", "{}", ack: "PartnerAssetBackfillV2|change|complete")], epoch: epoch)
        let backfillAck = try await store.pendingAcknowledgements()
        XCTAssertTrue(backfillAck.contains("PartnerAssetBackfillV2|change|complete"))
    }
    func testResetAndLogoutInvalidateStoredRecordsAndRejectLateWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        _ = try await store.apply([asset("photo"), event("SyncCompleteV1", "{}")], epoch: epoch)
        let reset = try await store.apply([event("SyncResetV1", "{}", ack: "SyncResetV1|reset")], epoch: epoch)
        XCTAssertTrue(reset.reset)
        let removed = try await store.asset(id: "photo"), complete = try await store.isComplete()
        XCTAssertNil(removed); XCTAssertFalse(complete)
        let pending = try await store.pendingAcknowledgements()
        XCTAssertEqual(pending, ["SyncResetV1|reset"])
        try await store.clear()
        do { _ = try await store.apply([asset("late")], epoch: epoch); XCTFail("Logout must fence late responses") }
        catch is CancellationError { }
    }
    func testRevocationRemovesSharedDataOnlyWhenNoRemainingGrantExists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        _ = try await store.apply([
            asset("mine"), asset("shared", owner: "bob"),
            event("PartnerV1", #"{"sharedById":"bob","sharedWithId":"alice","inTimeline":true}"#),
            event("AlbumV2", #"{"id":"album","name":"Trip","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":"shared","isActivityEnabled":true,"order":"desc"}"#),
            event("AlbumUserV1", #"{"albumId":"album","userId":"alice","role":"viewer"}"#),
            event("AlbumToAssetV1", #"{"albumId":"album","assetId":"shared"}"#)
        ], epoch: epoch)
        _ = try await store.apply([event("PartnerDeleteV1", #"{"sharedById":"bob","sharedWithId":"alice"}"#)], epoch: epoch)
        let stillShared = try await store.asset(id: "shared")
        XCTAssertNotNil(stillShared)
        _ = try await store.apply([event("AlbumUserDeleteV1", #"{"albumId":"album","userId":"alice"}"#)], epoch: epoch)
        let revoked = try await store.asset(id: "shared"), owned = try await store.asset(id: "mine")
        XCTAssertNil(revoked); XCTAssertNotNil(owned)
        let albums = try await store.albums()
        XCTAssertTrue(albums.isEmpty)
    }
    func testLockedTransitionPurgesMetadataAndCannotBeRepopulatedByLaterExif() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        _ = try await store.apply([asset("photo"), event("AssetExifV1", #"{"assetId":"photo","description":"private caption"}"#)], epoch: epoch)
        _ = try await store.apply([asset("photo", visibility: "locked"), event("AssetExifV1", #"{"assetId":"photo","description":"late private caption"}"#)], epoch: epoch)
        let locked = try await store.asset(id: "photo"), exif = try await store.entityData(kind: "exif", id: "photo")
        XCTAssertNil(locked); XCTAssertNil(exif)
        let accessInvalidated = try await store.takeAccessInvalidation(), consumed = try await store.takeAccessInvalidation()
        XCTAssertTrue(accessInvalidated); XCTAssertFalse(consumed)
    }
    func testOfflineTimelineUsesLocalMonthsFavoritesStacksAndBothCloudDateFormats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        _ = try await store.apply([
            asset("primary", favorite: true, stack: "stack"), asset("secondary", stack: "stack"), asset("trash", deleted: true), asset("hidden", visibility: "hidden"),
            event("StackV1", #"{"id":"stack","ownerId":"alice","primaryAssetId":"primary","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#),
            event("AssetMetadataV1", #"{"assetId":"primary","key":"mobile-app","value":{"iCloudId":"cloud-photo","createdAt":"2026-01-31T23:30:00Z","adjustmentTime":1700000000,"latitude":"38.7","longitude":-9.1}}"#)
        ], epoch: epoch)
        let buckets = try await store.timeBuckets()
        XCTAssertEqual(buckets.map(\.timeBucket), ["2026-02-01"])
        XCTAssertEqual(buckets.first?.count, 1)
        var filter = TimelineFilter(); filter.isFavorite = true
        let favorites = try await store.timeBucket("2026-02-01", filter: filter)
        XCTAssertEqual(favorites.map(\.id), ["primary"])
        filter.withStacked = false; filter.isFavorite = nil
        let all = try await store.timelineAssets(filter: filter)
        XCTAssertEqual(Set(all.map(\.id)), ["primary", "secondary"])
        filter.visibility = nil
        let defaultVisibility = try await store.timelineAssets(filter: filter)
        XCTAssertFalse(defaultVisibility.contains { $0.id == "hidden" })
        let matches = try await store.localAssetMatches()
        XCTAssertEqual(Set(matches.map(\.assetID)), ["primary", "secondary", "trash", "hidden"])
        let paired = try XCTUnwrap(matches.first { $0.assetID == "primary" })
        XCTAssertEqual(paired.cloudID, "cloud-photo")
        XCTAssertEqual(paired.createdAt, APIDate.parse("2026-01-31T23:30:00Z"))
        XCTAssertEqual(paired.adjustmentTime, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(paired.latitude, 38.7)
    }
    func testSocketProtocolHandlesHeartbeatEditsAndSessionErrorsWithoutCredentialsInMessages() throws {
        if case .ping(let payload) = try SocketEventPacket.parse("2probe") { XCTAssertEqual(payload, "probe") }
        else { XCTFail("Engine.IO ping requires pong") }
        if case .invalidation(let update) = try SocketEventPacket.parse(#"42["AssetEditReadyV2",{"asset":{"id":"photo","mediaRevision":"new"},"edit":[]}]"#) { XCTAssertEqual(update.assetIDs, ["photo"]) }
        else { XCTFail("Published edit must invalidate media") }
        XCTAssertThrowsError(try SocketEventPacket.parse(#"42["error","unauthorized"]"#))
        XCTAssertTrue(ReadOnlyPolicy.permits(method: "POST", path: "sync/ack"))
        XCTAssertTrue(ReadOnlyPolicy.permits(method: "POST", path: "sync/stream"))
        XCTAssertFalse(ReadOnlyPolicy.permits(method: "POST", path: "assets"))
    }
}

private final class SyncHTTPFixture: @unchecked Sendable {
    struct Response: Sendable { let status: Int; let body: Data }
    private let lock = NSLock()
    private var replies: [String: [Response]] = [:]
    private var requests: [URLRequest] = []
    func reset() { lock.lock(); defer { lock.unlock() }; replies.removeAll(); requests.removeAll() }
    func set(_ path: String, _ values: [Response]) { lock.lock(); defer { lock.unlock() }; replies[path] = values }
    func reply(_ request: URLRequest) -> Response {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let path = request.url?.path ?? ""
        guard var values = replies[path], !values.isEmpty else { return .init(status: 500, body: Data()) }
        let value = values.removeFirst(); replies[path] = values; return value
    }
    func bodies(_ path: String) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.path == path }.compactMap { request in
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096), data = Data()
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
            return data
        }
    }
}
private final class SyncTestURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = SyncHTTPFixture()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sync-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value = Self.fixture.reply(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: value.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/jsonlines+json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: value.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

extension EntitySyncTests {
    func testInterruptedInitialStreamResumesWithoutAnotherServerReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = try APIClient(baseURL: URL(string: "https://sync-test.invalid")!, accessToken: "test-session", userID: "alice", session: session, networkConfiguration: .init())
        let store = try EntityStore(scope: api.cacheScope, userID: "alice", directory: root)
        let sync = NativeSync(api: api, store: store)
        let partial = try JSONEncoder().encode(asset("photo")) + Data("\n".utf8)
        let complete = try JSONEncoder().encode(event("SyncCompleteV1", "{}", ack: "SyncCompleteV1|finished")) + Data("\n".utf8)
        SyncTestURLProtocol.fixture.reset()
        SyncTestURLProtocol.fixture.set("/api/sync/stream", [.init(status: 200, body: partial), .init(status: 200, body: complete)])
        SyncTestURLProtocol.fixture.set("/api/sync/ack", [.init(status: 204, body: Data()), .init(status: 204, body: Data())])
        do { _ = try await sync.synchronize(); XCTFail("A missing complete marker must fail") }
        catch is APIError { }
        let firstSaved = try await store.asset(id: "photo"), initiallyComplete = try await store.isComplete()
        XCTAssertNotNil(firstSaved); XCTAssertFalse(initiallyComplete)
        let resumed = try await sync.synchronize()
        XCTAssertTrue(resumed.completed)
        let requests = try SyncTestURLProtocol.fixture.bodies("/api/sync/stream").map { try JSONDecoder().decode([String: EntityJSON].self, from: $0) }
        XCTAssertEqual(requests.map { $0["reset"] }, [.bool(true), .bool(false)])
        let pending = try await store.pendingAcknowledgements()
        XCTAssertTrue(pending.isEmpty)
    }
}

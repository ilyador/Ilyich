import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// One sync pass: what its batches say they changed, when it acknowledges, and what keeps the
/// owner's library from syncing again after an update.
@MainActor final class SyncPassTests: XCTestCase {
    private let february = MonthKey(year: 2026, month: 2)
    private let march = MonthKey(year: 2026, month: 3)

    // MARK: - Typed changes

    /// Each batch names what it changed: the months an asset left and joined, a new media
    /// revision only for an asset the index already had, and the collections touched. Details
    /// such as EXIF or faces keep an asset in its month. The account's own user record and a
    /// record for an asset the index doesn't hold change nothing.
    func testBatchesNameWhatTheyChangedWithTheirMonths() async throws {
        let store = try makeStore()
        let epoch = await store.epoch()

        var change = try await store.apply([SyncEvents.asset("photo", taken: "2026-02-01T05:00:00Z", revision: "r1")], epoch: epoch)
        XCTAssertEqual(change.upserted, ["photo": .init(from: nil, to: february)], "A new photo joins its month.")
        XCTAssertTrue(change.mediaRevisions.isEmpty, "A new photo has no media to replace.")
        let first = change.revision

        change = try await store.apply([SyncEvents.asset("photo", taken: "2026-03-10T05:00:00.000Z", revision: "r2")], epoch: epoch)
        XCTAssertEqual(change.upserted, ["photo": .init(from: february, to: march)], "A new date moves it to March.")
        XCTAssertEqual(change.mediaRevisions, ["photo": "r2"])
        XCTAssertGreaterThan(change.revision, first)

        change = try await store.apply([SyncEvents.asset("motion", visibility: "hidden")], epoch: epoch)
        XCTAssertEqual(change.upserted, ["motion": .init(from: nil, to: nil)], "A hidden asset shows in no month.")

        change = try await store.apply([SyncEvents.event("AssetExifV1", #"{"assetId":"photo","city":"Lisbon"}"#)], epoch: epoch)
        XCTAssertEqual(change.upserted, ["photo": .init(from: march, to: march)], "Its EXIF changed and it stayed in March.")
        let revision = change.revision
        change = try await store.apply([SyncEvents.event("AssetExifV1", #"{"assetId":"elsewhere","city":"Porto"}"#)], epoch: epoch)
        XCTAssertTrue(change.isEmpty, "A record for an asset the index doesn't hold changes nothing.")
        XCTAssertEqual(change.revision, revision, "Nothing changed, so the revision stays.")

        _ = try await store.apply([SyncEvents.event("PersonV1", #"{"id":"maya","name":"Maya"}"#),
                                   SyncEvents.event("PersonV1", #"{"id":"leo","name":"Leo"}"#),
                                   SyncEvents.event("AssetFaceV3", #"{"id":"face","assetId":"photo","personId":"maya","isVisible":true,"deletedAt":null}"#)],
                                  epoch: epoch)
        change = try await store.apply([SyncEvents.event("AssetFaceV3", #"{"id":"face","assetId":"photo","personId":"leo","isVisible":true,"deletedAt":null}"#)],
                                       epoch: epoch)
        XCTAssertEqual(change.people, ["maya", "leo"], "A face that moves changes both people.")
        XCTAssertEqual(change.upserted, ["photo": .init(from: march, to: march)])
        change = try await store.apply([SyncEvents.event("AssetFaceDeleteV1", #"{"assetFaceId":"face"}"#)], epoch: epoch)
        XCTAssertEqual(change.people, ["leo"], "A face's deletion names only the face; what it belonged to is read first.")
        XCTAssertEqual(change.upserted, ["photo": .init(from: march, to: march)])

        change = try await store.apply([
            SyncEvents.event("AlbumV2", #"{"id":"trip","ownerId":"alice","albumName":"Trip"}"#),
            SyncEvents.event("StackV1", #"{"id":"stack","ownerId":"alice","primaryAssetId":"photo"}"#),
            SyncEvents.event("MemoryV2", #"{"id":"memory","ownerId":"alice"}"#),
        ], epoch: epoch)
        XCTAssertEqual(change.albums, ["trip"])
        XCTAssertEqual(change.stacks, ["stack"])
        XCTAssertTrue(change.memoriesChanged)
        XCTAssertFalse(change.partnersChanged)

        change = try await store.apply([SyncEvents.event("UserMetadataV1", #"{"userId":"alice","key":"preferences","value":{"memories":{"enabled":false}}}"#)], epoch: epoch)
        XCTAssertTrue(change.memoriesChanged, "The account's preferences decide whether memories show.")
        change = try await store.apply([SyncEvents.event("AuthUserV2", #"{"id":"alice","name":"Alice","email":"alice@example.com","pinCode":null,"quotaUsageInBytes":42}"#)],
                                       epoch: epoch)
        XCTAssertTrue(change.isEmpty, "The account's own record, as after every upload, is not part of the library.")
        change = try await store.apply([SyncEvents.event("UserV1", #"{"id":"bob","name":"Bob","email":"bob@example.com","deletedAt":null}"#),
                                        SyncEvents.event("PartnerV1", #"{"sharedById":"bob","sharedWithId":"alice","inTimeline":true}"#)], epoch: epoch)
        XCTAssertTrue(change.partnersChanged)

        change = try await store.apply([SyncEvents.asset("photo", visibility: "locked")], epoch: epoch)
        XCTAssertEqual(change.removed, ["photo"])
        XCTAssertEqual(change.accessLost, ["photo"], "A photo moved to the Locked Folder is lost to the library.")
        change = try await store.apply([SyncEvents.event("AssetDeleteV1", #"{"assetId":"motion"}"#)], epoch: epoch)
        XCTAssertEqual(change.removed, ["motion"])
        XCTAssertTrue(change.accessLost.isEmpty, "A deletion is not lost access.")
    }

    /// The completion marker alone changes nothing, unless it completes the index: then feeds move
    /// to it. A reset of a complete index moves them back.
    func testTheCompletionMarkerChangesNothingUnlessItCompletesTheIndex() async throws {
        let store = try makeStore()
        let epoch = await store.epoch()
        let completing = try await store.apply([SyncEvents.complete()], epoch: epoch)
        XCTAssertTrue(completing.completed)
        XCTAssertTrue(completing.routingChanged)
        let again = try await store.apply([SyncEvents.complete(id: "again")], epoch: epoch)
        XCTAssertTrue(again.completed)
        XCTAssertTrue(again.isEmpty, "\(again)")
        let reset = try await store.apply([SyncEvents.event("SyncResetV1", "{}", ack: "SyncResetV1|reset")], epoch: epoch)
        XCTAssertTrue(reset.serverReset)
        XCTAssertTrue(reset.routingChanged)
    }

    /// A change names at most 50,000 items. Past that it overflows: consumers reload, and only
    /// lost access, which is never forgotten, is kept.
    func testAChangeOverflowsPastFiftyThousandItems() {
        var change = IndexChange()
        change.accessLost = ["locked"]
        for id in 1..<LibraryChange.itemLimit { change.upserted["asset-\(id)"] = .init(from: nil, to: february) }
        change.limitItems()
        XCTAssertFalse(change.overflow, "Exactly at the limit, lost access included, nothing overflows.")
        var later = IndexChange()
        later.albums = ["trip"]
        change.merge(later)
        XCTAssertTrue(change.overflow)
        XCTAssertTrue(change.upserted.isEmpty)
        XCTAssertTrue(change.albums.isEmpty)
        XCTAssertEqual(change.accessLost, ["locked"])
        XCTAssertFalse(change.isEmpty)

        var library = LibraryChange(account: LegacyGoldens.account, authorization: AuthorizationEpoch(account: LegacyGoldens.account, value: 1),
                                    indexRevision: 1, origin: .sync)
        library.removed = Set((0...LibraryChange.itemLimit).map { "removed-\($0)" })
        library.accessLost = ["locked"]
        library.limitItems()
        XCTAssertTrue(library.overflow)
        XCTAssertTrue(library.removed.isEmpty)
        XCTAssertEqual(library.accessLost, ["locked"])
    }

    // MARK: - Acknowledgements

    /// A pass posts what it has committed once 2,000 events arrived since it last posted, and at
    /// the end of the stream, instead of after every batch of 200.
    func testAcknowledgementsGoEveryTwoThousandEventsAndAtTheEnd() async throws {
        let (sync, store, server) = try makePass(acks: AckPolicy(interval: .seconds(3_600), events: 2_000))
        server.route("POST", "sync/stream", SyncEvents.stream((0..<4_500).map { SyncEvents.asset("photo-\($0)") } + [SyncEvents.complete()]))

        _ = try await sync.pass()

        let posts = server.requests("POST", "sync/ack")
        XCTAssertEqual(posts.count, 3, "At 2,000 and 4,000 events, and at the end.")
        XCTAssertEqual(try acks(in: posts.last), ["AssetV2|photo-4499", "SyncCompleteV1|done"], "The last post carries the latest of each type.")
        let pending = try await store.pendingAcknowledgements()
        XCTAssertTrue(pending.isEmpty)
    }

    /// Between small batches a pass waits a second before posting again; with no interval to wait,
    /// every batch posts.
    func testAcknowledgementsWaitForTheirIntervalBetweenBatches() async throws {
        let events = (0..<450).map { SyncEvents.asset("photo-\($0)") } + [SyncEvents.complete()]
        let (patient, _, server) = try makePass(acks: AckPolicy(interval: .seconds(3_600), events: 2_000))
        server.route("POST", "sync/stream", SyncEvents.stream(events))
        _ = try await patient.pass()
        XCTAssertEqual(server.requests("POST", "sync/ack").count, 1, "Three batches, one post at the end.")

        let (eager, _, eagerServer) = try makePass(acks: AckPolicy(interval: .zero, events: 2_000))
        eagerServer.route("POST", "sync/stream", SyncEvents.stream(events))
        _ = try await eager.pass()
        XCTAssertEqual(eagerServer.requests("POST", "sync/ack").count, 3, "One post a batch.")
    }

    /// Pinned: acknowledgements committed with their data but never posted, because the app ended
    /// in between or the post failed, are posted first by the next pass, before its stream. The
    /// server takes the same acknowledgement twice without harm, so nothing is ever skipped.
    func testUnpostedAcknowledgementsAreReplayedBeforeTheNextStream() async throws {
        let (sync, store, server) = try makePass()
        let fingerprint = try await sync.api.syncSessionFingerprint()
        _ = try await store.prepare(sessionFingerprint: fingerprint)
        try await store.markResetRequested()
        // Committed, and the app ended before the post.
        _ = try await store.apply([SyncEvents.asset("kept"), SyncEvents.complete(id: "crashed")], epoch: store.epoch())
        server.route("POST", "sync/ack", responses: [.immichError(500, message: "Internal server error"), .empty(204)])
        server.route("POST", "sync/stream", SyncEvents.stream([SyncEvents.complete(id: "next")]))

        do {
            _ = try await sync.pass()
            XCTFail("A replay the server refused fails the pass before its stream.")
        } catch {}
        XCTAssertTrue(server.requests("POST", "sync/stream").isEmpty, "No stream starts before the replay goes.")
        let stillPending = try await store.pendingAcknowledgements()
        XCTAssertEqual(Set(stillPending), ["AssetV2|kept", "SyncCompleteV1|crashed"], "A failed post keeps them for the next pass.")

        _ = try await sync.pass()

        let order = server.requests.map { $0.method + " " + $0.path }
        XCTAssertEqual(order, ["POST sync/ack", "POST sync/ack", "POST sync/stream", "POST sync/ack"])
        let posts = server.requests("POST", "sync/ack")
        XCTAssertEqual(Set(try acks(in: posts[1])), ["AssetV2|kept", "SyncCompleteV1|crashed"], "The replay carries what was committed.")
        XCTAssertEqual(try acks(in: posts[2]), ["SyncCompleteV1|next"])
        let stream = try XCTUnwrap(server.requests("POST", "sync/stream").first?.body)
        XCTAssertEqual(try JSONDecoder().decode([String: EntityJSON].self, from: stream)["reset"], .bool(false))
        let kept = try await store.asset(id: "kept")
        XCTAssertNotNil(kept)
    }

    /// Pinned: the offline library belongs to the login session through a fingerprint of its
    /// token, SHA-256 in lowercase hex, which no update may change. The same session keeps every
    /// entity and the server's checkpoints and asks for no reset, so an update never re-syncs the
    /// library; only another session empties the index and asks the server for everything again.
    func testOnlyAnotherSessionWipesTheIndex() async throws {
        let server = makeStubServer()
        server.route("POST", "sync/stream", SyncHarness.completeStream)
        server.route("POST", "sync/ack", .empty(204))
        let api = try client(server, token: "golden-session")
        let fingerprint = try await api.syncSessionFingerprint()
        XCTAssertEqual(fingerprint, "1e591f4cbe50d9d30081aea051bd034c41979b37bf2ac3f58a2dc611807ab76a")
        let store = try makeStore(scope: api.cacheScope)
        // The index as an earlier build left it for this session: synced, complete, acknowledged.
        _ = try await store.prepare(sessionFingerprint: "1e591f4cbe50d9d30081aea051bd034c41979b37bf2ac3f58a2dc611807ab76a")
        try await store.markResetRequested()
        _ = try await store.apply([SyncEvents.asset("kept"), SyncEvents.complete()], epoch: store.epoch())
        try await store.acknowledged(store.pendingAcknowledgements())

        let same = try await NativeSync(api: api, store: store).pass()

        XCTAssertFalse(same.localReset)
        XCTAssertTrue(same.isEmpty)
        XCTAssertEqual(try resets(server), [false], "The same session asks for no reset.")
        let kept = try await store.asset(id: "kept")
        XCTAssertNotNil(kept)
        let complete = try await store.isComplete()
        XCTAssertTrue(complete)

        let other = try client(server, token: "another-session")
        let wiped = try await NativeSync(api: other, store: store).pass()

        XCTAssertTrue(wiped.localReset)
        XCTAssertEqual(try resets(server), [false, true], "Another session asks the server for everything again.")
        let gone = try await store.asset(id: "kept")
        XCTAssertNil(gone, "Another session's library starts empty.")
    }

    // MARK: - The live connection's hints

    /// The namespace's connect ack asks for a pass, since hints sent while the connection was
    /// down are lost, but is no configuration change. A stack update's spread arguments are all
    /// read, and hints that carry an asset carry its media revision.
    func testHintsSayWhatTheyKnowAndNothingMore() throws {
        guard case .invalidation(let connected) = try SocketEventPacket.parse(#"40{"sid":"abc"}"#) else { return XCTFail("The connect ack asks for a pass.") }
        XCTAssertEqual(connected, ServerInvalidation(), "The connect ack is no configuration change.")
        guard case .invalidation(let stacked) = try SocketEventPacket.parse(#"42["on_asset_stack_update","a","b"]"#) else { return XCTFail() }
        XCTAssertEqual(stacked.assetIDs, ["a", "b"])
        guard case .invalidation(let trashed) = try SocketEventPacket.parse(#"42["on_asset_trash",["c","d"]]"#) else { return XCTFail() }
        XCTAssertEqual(trashed.assetIDs, ["c", "d"])
        guard case .invalidation(let uploaded) = try SocketEventPacket.parse(#"42["AssetUploadReadyV2",{"asset":{"id":"new","mediaRevision":"m1"},"exif":{}}]"#) else { return XCTFail() }
        XCTAssertEqual(uploaded.mediaRevisions, ["new": "m1"])
        guard case .invalidation(let updated) = try SocketEventPacket.parse(#"42["on_asset_update",{"id":"old","mediaRevision":"m2"}]"#) else { return XCTFail() }
        XCTAssertEqual(updated.mediaRevisions, ["old": "m2"])
        guard case .invalidation(let configured) = try SocketEventPacket.parse(#"42["on_config_update"]"#) else { return XCTFail() }
        XCTAssertTrue(configured.configurationChanged)
    }

    /// Hints that arrive while nobody reads wait merged into one: every asset, the latest
    /// revision of each, and either's flag. The connection's end comes after them.
    func testHintsWaitMergedUntilRead() async throws {
        let mailbox = ServerHintMailbox()
        mailbox.post(ServerInvalidation(assetIDs: ["a"], mediaRevisions: ["a": "1"]))
        mailbox.post(ServerInvalidation(assetIDs: ["b"], mediaRevisions: ["a": "2"], configurationChanged: true))
        mailbox.finish(throwing: URLError(.networkConnectionLost))

        let merged = try await mailbox.next()
        XCTAssertEqual(merged, ServerInvalidation(assetIDs: ["a", "b"], mediaRevisions: ["a": "2"], configurationChanged: true))
        do {
            _ = try await mailbox.next()
            XCTFail("The connection's failure follows the hints.")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }

        let waiting = ServerHintMailbox()
        let reader = Task { try await waiting.next() }
        try await Task.sleep(for: .milliseconds(50))
        waiting.post(ServerInvalidation(assetIDs: ["c"]))
        let read = try await reader.value
        XCTAssertEqual(read?.assetIDs, ["c"], "A reader that waits gets the next hint.")
        let cancelled = Task { try await waiting.next() }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled read ends.")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    // MARK: - Support

    private func makeStore(scope: String = "server|alice") throws -> EntityStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncPassTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try EntityStore(scope: scope, userID: "alice", directory: root)
    }

    private func client(_ server: StubServer, token: String) throws -> APIClient {
        let api = try APIClient(baseURL: server.baseURL, accessToken: token, userID: "alice", sessionConfiguration: server.configuration(),
                                networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        return api
    }

    /// A pass over a stub server and a fresh index.
    private func makePass(acks: AckPolicy = AckPolicy()) throws -> (sync: PassUnderTest, store: EntityStore, server: StubServer) {
        let server = makeStubServer()
        server.route("POST", "sync/ack", .empty(204))
        let api = try client(server, token: "pass-session")
        let store = try makeStore(scope: api.cacheScope)
        return (PassUnderTest(api: api, native: NativeSync(api: api, store: store, acks: acks)), store, server)
    }

    /// The acknowledgements one sync/ack request posted, in order.
    private func acks(in request: StubServer.Request?) throws -> [String] {
        let body = try XCTUnwrap(request?.body)
        return try JSONDecoder().decode([String: [String]].self, from: body)["acks"] ?? []
    }

    /// Whether each sync/stream request asked for a reset.
    private func resets(_ server: StubServer) throws -> [Bool] {
        try server.requests("POST", "sync/stream").map { request in
            let body = try XCTUnwrap(request.body)
            return try JSONDecoder().decode([String: EntityJSON].self, from: body)["reset"] == .bool(true)
        }
    }
}

/// A pass and the client it runs with.
private struct PassUnderTest {
    let api: APIClient
    let native: NativeSync

    func pass() async throws -> IndexChange { try await native.pass() }
}

import IlyichPlatform
import UIKit
import XCTest
@testable import Ilyich

/// N2: the library's changes on the server go through one service. It refuses what read-only
/// mode or ownership forbids before anything is sent, makes one call, invalidates exactly the
/// media the change makes stale, publishes the result to every screen, and merges the sync pass
/// that follows, whether or not the screen that asked is still there.
@MainActor final class LibraryMutationServiceTests: XCTestCase {
    private let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
        UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    private static let features = #"{"passwordLogin":true,"oauth":false,"smartSearch":true,"ocr":true,"facialRecognition":true,"map":true,"trash":true,"sidecar":true,"realtimeTranscoding":true}"#

    /// A service over a stub server, with its own media pipeline and no sync unless `refresh`.
    private func makeService(server: StubServer, userID: String = "me", readOnly: Bool = false,
                             refresh: (@Sendable () async throws -> LibraryChange?)? = nil,
                             polling: LibraryMutationService.EditPolling = .init(interval: .milliseconds(10), attempts: 5))
        throws -> (service: LibraryMutationService, api: APIClient, pipeline: MediaPipeline) {
        // A user of its own, so the thumbnail store is this test's alone.
        let account = AccountID(server: server.baseURL, userID: userID + "-" + UUID().uuidString)
        let authorization = AuthorizationState(account: account, token: "mutations", readOnly: readOnly, requiresPasswordChange: false, mirror: nil)
        let api = try APIClient(baseURL: server.baseURL, accessToken: "mutations", userID: userID, sessionConfiguration: server.configuration(),
                                networkConfiguration: NetworkConfiguration())
        let pipeline = MediaPipeline(client: api, protocolClasses: [StubURLProtocol.self], earlierURLCacheEntries: false)
        let service = LibraryMutationService(client: api, pipeline: pipeline, authorization: authorization, refresh: refresh, polling: polling)
        addTeardownBlock { await service.shutdown(); await pipeline.removeAll(); await api.shutdown() }
        return (service, api, pipeline)
    }

    private func photo(_ id: String, owner: String? = "me", revision: String = "r1", trashed: Bool = false) -> Asset {
        var asset = Asset(id: id, originalFileName: id + ".jpg", ownerId: owner, mediaRevision: revision)
        asset.isTrashed = trashed
        return asset
    }

    /// Stores each photo's thumbnail and decodes it at two cell sizes.
    private func cache(_ assets: [Asset], in pipeline: MediaPipeline, scope: String) async {
        let disk = ThumbnailDiskStore.shared(scope: scope)
        for asset in assets { await disk.store(png, assetID: asset.id, revision: asset.cacheRevision) }
        for asset in assets {
            for size in [8, 6] { _ = await pipeline.storedThumbnail(for: asset, pixelSize: size) }
        }
    }

    private func isCached(_ asset: Asset, in pipeline: MediaPipeline) -> Bool {
        pipeline.hasStoredThumbnail(asset) || pipeline.cachedImage(for: asset, pixelSize: 8) != nil
            || pipeline.cachedImage(for: asset, pixelSize: 6) != nil || pipeline.latestImage(assetID: asset.id, size: .thumbnail) != nil
    }

    private func isFullyCached(_ asset: Asset, in pipeline: MediaPipeline) -> Bool {
        pipeline.hasStoredThumbnail(asset) && pipeline.cachedImage(for: asset, pixelSize: 8) != nil
            && pipeline.cachedImage(for: asset, pixelSize: 6) != nil
    }

    private func body(_ request: StubServer.Request?) throws -> [String: EntityJSON] {
        try JSONDecoder().decode([String: EntityJSON].self, from: XCTUnwrap(request?.body))
    }

    private func json(_ asset: Asset) -> StubServer.Response { .json(asset) }

    /// The events a stream holds, up to and including the first follow-up.
    private func eventsUntilFollowUp(_ events: AsyncStream<MutationEvent>) async -> [MutationEvent] {
        var received: [MutationEvent] = []
        for await event in events {
            received.append(event)
            if case .followedUp = event { break }
        }
        return received
    }

    // MARK: - Media

    /// Locking one photo forgets only that photo's media, at once and everywhere; every other
    /// photo keeps its thumbnail, so the offline library stays whole.
    func testLockingOnePhotoForgetsOnlyThatPhoto() async throws {
        let server = makeStubServer()
        server.route("PUT", "assets", .empty(204))
        let (service, api, pipeline) = try makeService(server: server)
        let locked = photo("locked"), kept = photo("kept")
        await cache([locked, kept], in: pipeline, scope: api.cacheScope)
        XCTAssertTrue(isFullyCached(locked, in: pipeline))

        let result = try await service.start(.visibility(["locked"], .locked), on: [locked]).result

        XCTAssertEqual(result.succeeded, ["locked"])
        XCTAssertEqual(result.fresh["locked"]?.visibility, .locked, "Its record as the change left it.")
        XCTAssertFalse(isCached(locked, in: pipeline), "Nothing of the locked photo stays, on disk or in memory.")
        XCTAssertTrue(isFullyCached(kept, in: pipeline), "Every other photo keeps its thumbnail, at every size.")
        let request = try XCTUnwrap(server.requests("PUT", "assets").first)
        XCTAssertEqual(try body(request), ["ids": .array([.string("locked")]), "visibility": .string("locked")],
                       "One bulk call, as Immich's apps lock, which also takes the photo out of its albums.")
        XCTAssertEqual(server.requests.count, 1, "One HTTP call.")
    }

    /// A photo put in Trash and restored, and the photos a duplicate group puts in Trash, keep
    /// their thumbnails: nothing needs downloading again when they come back.
    func testTrashRestoreAndDuplicateResolveKeepOfflineThumbnails() async throws {
        let server = makeStubServer()
        server.route("DELETE", "assets", .empty(204))
        server.route("POST", "trash/restore/assets", .json(#"{"count":1}"#))
        server.route("GET", "server/features", .json(Self.features))
        server.route("POST", "duplicates/resolve", .json(#"[{"id":"group","success":true}]"#))
        let (service, api, pipeline) = try makeService(server: server)
        let trashed = photo("trashed"), keeper = photo("keeper"), duplicate = photo("duplicate")
        await cache([trashed, keeper, duplicate], in: pipeline, scope: api.cacheScope)

        let trash = try await service.start(.trash(["trashed"]), on: [trashed]).result
        XCTAssertEqual(trash.fresh["trashed"]?.isTrashed, true)
        XCTAssertTrue(isFullyCached(trashed, in: pipeline), "A photo in Trash keeps its thumbnail.")
        XCTAssertEqual(try body(server.requests("DELETE", "assets").first), ["ids": .array([.string("trashed")]), "force": .bool(false)])

        let restore = try await service.start(.restore(["trashed"]), on: [photo("trashed", trashed: true)]).result
        XCTAssertEqual(restore.affected, 1)
        XCTAssertEqual(restore.fresh["trashed"]?.isTrashed, false)
        XCTAssertTrue(isFullyCached(trashed, in: pipeline), "A restored photo shows its thumbnail at once.")

        let resolve = try await service.start(.resolveDuplicate(group: "group", keep: ["keeper"], trash: ["duplicate"]),
                                              on: [keeper, duplicate]).result
        XCTAssertEqual(resolve.succeeded, ["duplicate"], "The photo put in Trash is the one the group changed.")
        XCTAssertEqual(resolve.fresh["duplicate"]?.isTrashed, true)
        for asset in [keeper, duplicate] { XCTAssertTrue(isFullyCached(asset, in: pipeline), asset.id) }
        let sent = try body(server.requests("POST", "duplicates/resolve").first)
        XCTAssertEqual(sent["groups"], .array([.object(["duplicateId": .string("group"), "keepAssetIds": .array([.string("keeper")]),
                                                        "trashAssetIds": .array([.string("duplicate")])])]))
    }

    /// A photo deleted for good loses its media, and only it.
    func testDeletingForGoodForgetsOnlyThosePhotos() async throws {
        let server = makeStubServer()
        server.route("DELETE", "assets", .empty(204))
        let (service, api, pipeline) = try makeService(server: server)
        let gone = photo("gone", trashed: true), kept = photo("kept", trashed: true)
        await cache([gone, kept], in: pipeline, scope: api.cacheScope)

        let result = try await service.start(.deletePermanently(["gone"]), on: [gone]).result

        XCTAssertNil(result.fresh["gone"], "A photo deleted for good has no record.")
        XCTAssertFalse(isCached(gone, in: pipeline))
        XCTAssertTrue(isFullyCached(kept, in: pipeline))
        XCTAssertEqual(try body(server.requests("DELETE", "assets").first)["force"], .bool(true))
    }

    /// An edit's new preview is waited for: the photo's record is read until its media revision
    /// moves. The new record is the result's, and only that photo's old images leave.
    func testAnEditWaitsForItsNewPreviewAndRefreshesOnlyThatPhoto() async throws {
        let server = makeStubServer()
        server.route("PUT", "assets/edited/edits", .json(#"{"assetId":"edited","edits":[{"action":"rotate","parameters":{"angle":90}}]}"#))
        let (service, api, pipeline) = try makeService(server: server)
        let edited = photo("edited"), other = photo("other")
        server.route("GET", "assets/edited", json(edited), json(edited), json(photo("edited", revision: "r2")))
        await cache([edited, other], in: pipeline, scope: api.cacheScope)

        let result = try await service.start(.edits(asset: "edited", [.rotate(90)]), on: [edited]).result

        XCTAssertEqual(result.fresh["edited"]?.mediaRevision, "r2", "The record once the new preview exists.")
        XCTAssertEqual(server.requests("GET", "assets/edited").count, 3, "Read until its revision moved.")
        XCTAssertFalse(isCached(edited, in: pipeline), "The old revision is neither shown nor kept.")
        XCTAssertTrue(isFullyCached(other, in: pipeline), "No other photo is touched.")
    }

    /// An edit whose preview the server hasn't made yet is still saved: the result keeps the
    /// record it has, and the caller says the preview is on its way.
    func testAnEditWhosePreviewIsLateIsStillSaved() async throws {
        let server = makeStubServer()
        server.route("DELETE", "assets/edited/edits", .empty(204))
        let (service, _, _) = try makeService(server: server, polling: .init(interval: .milliseconds(5), attempts: 3))
        let edited = photo("edited")
        server.route("GET", "assets/edited", json(edited))

        let result = try await service.start(.edits(asset: "edited", []), on: [edited]).result

        XCTAssertEqual(result.succeeded, ["edited"])
        XCTAssertEqual(result.fresh["edited"]?.mediaRevision, "r1")
        XCTAssertEqual(server.requests("GET", "assets/edited").count, 3)
        XCTAssertEqual(server.requests("DELETE", "assets/edited/edits").count, 1, "No edits left removes them.")
    }

    // MARK: - Publishing

    /// Every subscriber hears the server's answer at once, then the same result again with the
    /// change of the sync pass that followed it merged in.
    func testFollowUpSyncSummaryReachesSubscribers() async throws {
        let harness = try makeSyncHarness()
        try await harness.primeIndex([SyncEvents.asset("photo")])
        var favorite = photo("photo", owner: "alice")
        favorite.isFavorite = true
        harness.server.route("PUT", "assets/photo", json(favorite))
        harness.server.route("POST", "sync/stream", SyncEvents.stream([SyncEvents.asset("photo", revision: "r2"), SyncEvents.complete()]))
        let engine = harness.engine
        let service = LibraryMutationService(client: harness.api, pipeline: harness.pipeline, authorization: harness.authorization,
                                             refresh: { try await engine.refresh() })
        addTeardownBlock { await service.shutdown() }
        XCTAssertTrue(service.followsUp)
        let first = service.events(), second = service.events()

        let answer = try await service.start(.favorite(["photo"], true), on: [photo("photo", owner: "alice")]).result

        XCTAssertNil(answer.followUp, "The server's answer comes back before the sync has run.")
        XCTAssertEqual(answer.fresh["photo"]?.isFavorite, true)
        for events in [first, second] {
            let received = await eventsUntilFollowUp(events)
            guard received.count == 2, case .applied(let applied) = received[0], case .followedUp(let followed) = received[1] else {
                return XCTFail("Each subscriber hears the answer, then the follow-up: \(received)")
            }
            XCTAssertEqual(applied.operation, followed.operation)
            XCTAssertEqual(applied.succeeded, ["photo"])
            let followUp = try XCTUnwrap(followed.followUp, "The sync pass's change is merged in.")
            XCTAssertNotNil(followUp.upserted["photo"], "It names the photo the sync read again.")
            XCTAssertNotNil(followUp.syncedThrough, "A full pass, which confirms what the feeds took out.")
        }
        XCTAssertEqual(harness.streamRequests.count, 1, "One pass follows.")
        XCTAssertFalse(harness.notifications.all.isEmpty, "The pass published its change to the screens as every pass does.")
        let settled = await becomesTrue { service.runningCount == 0 }
        XCTAssertTrue(settled, "The mutation ends with its follow-up.")
    }

    /// The screen that asked can be gone before the server answers: the change is still made,
    /// once, and its result reaches every screen still showing photos.
    func testAResultIsPublishedAfterThePresentingScreenIsGone() async throws {
        let server = makeStubServer()
        let gate = StubServer.Gate()
        server.route("DELETE", "assets", StubServer.Response.empty(204).waiting(for: gate))
        let (service, _, _) = try makeService(server: server)
        let events = service.events()
        var screen: Task<MutationResult, any Error>? = Task { try await service.start(.trash(["gone"]), on: [self.photo("gone")]).result }
        let sent = await becomesTrue { server.requests("DELETE", "assets").count == 1 }
        XCTAssertTrue(sent, "The change was sent.")

        // The viewer closes, and with it the task that waited for the answer.
        screen?.cancel()
        screen = nil
        gate.open()

        let received = await eventsUntilFollowUp(events)
        guard case .applied(let result)? = received.first else { return XCTFail("The result was published: \(received)") }
        XCTAssertEqual(result.succeeded, ["gone"])
        XCTAssertEqual(result.fresh["gone"]?.isTrashed, true)
        guard case .followedUp(let followed)? = received.last else { return XCTFail("The follow-up was published.") }
        XCTAssertNil(followed.followUp, "Without an offline library no sync follows.")
        XCTAssertEqual(server.requests("DELETE", "assets").count, 1, "Made once, never cancelled or sent again.")
    }

    // MARK: - What may be sent

    /// Read-only mode refuses every change before it is sent.
    func testReadOnlyModeRefusesAChangeBeforeItIsSent() async throws {
        let server = makeStubServer()
        server.route("PUT", "assets/mine", json(photo("mine")))
        let (service, _, _) = try makeService(server: server, readOnly: true)
        let events = service.events()

        do {
            _ = try await service.start(.favorite(["mine"], true), on: [photo("mine")]).result
            XCTFail("Read-only mode refuses the change.")
        } catch {
            XCTAssertTrue(error is ReadOnlyPolicy.ReadOnlyError, "\(error)")
        }
        XCTAssertTrue(server.requests.isEmpty, "Nothing is sent.")
        await service.shutdown()
        var published: [MutationEvent] = []
        for await event in events { published.append(event) }
        XCTAssertTrue(published.isEmpty, "A change not made is not published.")
    }

    /// Only the owner changes a photo: a bulk change sends the photos that are the account's own,
    /// and says why each other one failed; a change to one photo of someone else's sends nothing.
    func testOnlyTheOwnersPhotosAreSent() async throws {
        let server = makeStubServer()
        var favorited = photo("mine")
        favorited.isFavorite = true
        server.route("PUT", "assets/mine", json(favorited))
        let (service, _, _) = try makeService(server: server)

        let result = try await service.start(.favorite(["mine", "theirs"], true), on: [photo("mine"), photo("theirs", owner: "partner")]).result

        XCTAssertEqual(result.succeeded, ["mine"])
        XCTAssertEqual(result.failed, ["theirs": MutationPlan.ownersOnly])
        XCTAssertEqual(server.requests.map { "\($0.method) \($0.path)" }, ["PUT assets/mine"], "Only the account's own photo is sent.")

        do {
            _ = try await service.start(.trash(["theirs"]), on: [photo("theirs", owner: "partner")]).result
            XCTFail("Someone else's photo can't be put in Trash.")
        } catch {
            XCTAssertEqual(error as? MutationError, .notAllowed(MutationPlan.ownersOnly))
        }
        XCTAssertEqual(server.requests.count, 1, "Nothing more is sent.")
    }

    /// A bulk answer says which photos changed: those already in the album count as added, and a
    /// photo the server refused fails with its reason. A locked photo never goes in an album.
    func testABulkAnswerSaysWhichPhotosChanged() async throws {
        let server = makeStubServer()
        server.route("PUT", "albums/album/assets", .json(#"[{"id":"a","success":true},{"id":"b","success":false,"error":"duplicate"},{"id":"c","success":false,"error":"no_permission"}]"#))
        let (service, _, _) = try makeService(server: server)
        var locked = photo("locked")
        locked.visibility = .locked

        let result = try await service.start(.addToAlbum(album: "album", assets: ["a", "b", "c", "locked"]),
                                             on: [photo("a"), photo("b"), photo("c"), locked]).result

        XCTAssertEqual(result.succeeded, ["a", "b"])
        XCTAssertEqual(result.failed, ["c": "no_permission", "locked": MutationPlan.notInLockedFolder])
        XCTAssertEqual(try body(server.requests("PUT", "albums/album/assets").first), ["ids": .array([.string("a"), .string("b"), .string("c")])])
    }

    /// A UI test that changes the library signs in to the fixture with a token of its own, new
    /// each launch, so the shared fixture keeps its changes from every other test and launch.
    func testAMutableFixtureSessionHasATokenOfItsOwnEachLaunch() {
        let arguments = ["--ui-testing", "--ui-testing-library", "--ui-testing-mutable-library"]
        let first = AccountEnvironment.uiTest(arguments: arguments)?.fixtureCredential?.token
        let second = AccountEnvironment.uiTest(arguments: arguments)?.fixtureCredential?.token
        XCTAssertEqual(first?.hasPrefix("ui-test-mutable-"), true)
        XCTAssertNotEqual(first, second, "Each launch's changes are its own.")
        XCTAssertEqual(AccountEnvironment.uiTest(arguments: ["--ui-testing", "--ui-testing-library"])?.fixtureCredential?.token,
                       "ui-test-session", "Every other session keeps the shared token.")
    }

    /// Sign-out ends the service: a mutation waiting for its answer is cancelled, the subscribers'
    /// streams end, and nothing new is started.
    func testShutdownCancelsMutationsAndEndsEveryStream() async throws {
        let server = makeStubServer()
        let gate = StubServer.Gate()
        addTeardownBlock { gate.open() }
        server.route("PUT", "assets", StubServer.Response.empty(204).waiting(for: gate))
        let (service, _, _) = try makeService(server: server)
        let events = service.events()
        let handle = service.start(.favorite(["a", "b"], true), on: [photo("a"), photo("b")])
        let sent = await becomesTrue { server.requests("PUT", "assets").count == 1 }
        XCTAssertTrue(sent)

        await service.shutdown()

        do { _ = try await handle.result; XCTFail("The mutation was cancelled.") } catch {}
        var published = 0
        for await _ in events { published += 1 }
        XCTAssertEqual(published, 0, "The stream ended without a result.")
        XCTAssertEqual(service.runningCount, 0)
        do {
            _ = try await service.start(.trash(["a"]), on: [photo("a")]).result
            XCTFail("A closed service starts nothing.")
        } catch {
            XCTAssertEqual(error as? MutationError, .closed)
        }
        XCTAssertEqual(server.requests.count, 1)
    }
}

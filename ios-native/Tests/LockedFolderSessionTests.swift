import IlyichPlatform
import SwiftUI
import UIKit
import XCTest
@testable import Ilyich

/// N5: the Locked Folder's session. It unlocks by PIN or password, relocks synchronously on the
/// way to the background, purging locked media, and drops whatever answer comes after a relock.
/// Locked photos never reach a library cache, and moving one to the timeline reaches the feed.
@MainActor final class LockedFolderSessionTests: XCTestCase {
    private let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
        UIColor.systemPurple.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    private struct Folder {
        let session: LockedFolderSession
        let api: APIClient
        let pipeline: MediaPipeline
        let authorization: AuthorizationState
        let mutations: LibraryMutationService
    }

    /// A Locked Folder over `server`, whose session the test ends. The account owns the folder's
    /// photos; the server's host, new for each test, keeps its caches the test's own.
    private func makeFolder(_ server: StubServer) throws -> Folder {
        let userID = "me"
        let authorization = AuthorizationState(account: AccountID(server: server.baseURL, userID: userID), token: "locked",
                                               readOnly: false, requiresPasswordChange: false, mirror: nil)
        let api = try APIClient(baseURL: server.baseURL, accessToken: "locked", userID: userID, sessionConfiguration: server.configuration(),
                                networkConfiguration: NetworkConfiguration(), authorization: authorization)
        let pipeline = MediaPipeline(client: api, protocolClasses: [StubURLProtocol.self], earlierURLCacheEntries: false)
        let mutations = LibraryMutationService(client: api, pipeline: pipeline, authorization: authorization, refresh: nil)
        let session = LockedFolderSession(api: api, pipeline: pipeline, authorization: authorization, mutations: mutations)
        addTeardownBlock { @MainActor in
            session.end()
            await mutations.shutdown(); await pipeline.removeAll(); await api.shutdown()
        }
        return Folder(session: session, api: api, pipeline: pipeline, authorization: authorization, mutations: mutations)
    }

    /// A server whose Locked Folder has a PIN and holds `months`, newest first, each with its
    /// photos. It unlocks with any PIN; the status says it is elevated from the second read on.
    private func lockedServer(_ months: [(date: String, ids: [String])]) -> StubServer {
        let server = makeStubServer()
        server.route("GET", "auth/status", Self.status(elevated: false), Self.status(elevated: true))
        server.route("POST", "auth/session/unlock", .empty(204))
        server.route("POST", "auth/session/lock", .empty(204))
        server.route("GET", "timeline/buckets", Self.buckets(months))
        server.route("GET", "timeline/bucket", responses: months.map { Self.month($0.date, $0.ids) })
        return server
    }

    private static func status(pinCode: Bool = true, elevated: Bool, expires: Date? = nil) -> StubServer.Response {
        var object: [String: Any] = ["pinCode": pinCode, "password": true, "isElevated": elevated]
        if let expires { object["pinExpiresAt"] = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(expires) }
        return .json(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    private static func buckets(_ months: [(date: String, ids: [String])]) -> StubServer.Response {
        let object = months.map { ["timeBucket": $0.date + "T00:00:00.000Z", "count": $0.ids.count] as [String: Any] }
        return .json(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    /// One month of the Locked Folder as the server's timeline answers it: every row locked.
    private static func month(_ date: String, _ ids: [String]) -> StubServer.Response {
        func column(_ value: Any) -> [Any] { Array(repeating: value, count: ids.count) }
        let object: [String: Any] = [
            "id": ids, "ownerId": column("me"), "ratio": column(1.5), "isFavorite": column(false), "isTrashed": column(false),
            "isImage": column(true), "visibility": column("locked"), "fileCreatedAt": column(date + "T12:00:00Z"),
            "createdAt": column(date + "T12:00:00Z"), "localOffsetHours": column(0), "duration": column(NSNull()),
            "thumbhash": column(NSNull()), "mediaRevision": column("r1"), "livePhotoVideoId": column(NSNull()),
        ]
        return .json(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    private func image() -> StubServer.Response { StubServer.Response(status: 200, headers: ["Content-Type": "image/png"], body: png) }

    private func body(_ request: StubServer.Request?) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request?.body)) as? [String: String])
    }

    private static func ids(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { prefix + String(format: "%02d", $0) } }

    /// Opens the folder with PIN 123456 and waits for its first months.
    private func unlock(_ session: LockedFolderSession) async {
        await session.appear()
        session.entry.pin = "123456"
        XCTAssertTrue(session.canUnlock)
        session.unlock()
        await session.unlocking?.value
    }

    private func until(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Relocking

    /// Going to the background relocks before the call returns: the folder shows nothing, its
    /// viewer closes, the private epoch moves and every locked image leaves memory, with nothing
    /// awaited. Library reads and writes carry on, and the server hears afterwards. Nothing of the
    /// folder ever reached a shared cache.
    func testBackgroundRelocksSynchronouslyAndPurgesPrivateMedia() async throws {
        let server = lockedServer([("2026-03-01", ["a", "b"])])
        server.route("GET", "assets/a/thumbnail", image())
        let folder = try makeFolder(server)
        let session = folder.session

        await unlock(session)
        XCTAssertEqual(session.phase, .unlocked)
        XCTAssertEqual(Set(session.photos.assets.map(\.id)), ["a", "b"])
        XCTAssertEqual(try body(server.requests("POST", "auth/session/unlock").first), ["pinCode": "123456"])
        XCTAssertEqual(session.entry, LockedFolderSession.Entry(), "What was typed goes once the folder opens.")
        let open = folder.authorization.snapshot
        XCTAssertTrue(open.lockedFolderUnlocked)
        let photo = try XCTUnwrap(session.photos.assets.first { $0.id == "a" })
        XCTAssertEqual(photo.visibility, .locked)
        _ = try await folder.pipeline.image(for: photo, size: .thumbnail, pixelSize: 64)
        _ = try await folder.pipeline.image(for: photo, size: .preview, pixelSize: 256)
        XCTAssertTrue(folder.pipeline.holdsPrivateMedia, "The folder's images are kept while it is open.")
        XCTAssertFalse(folder.pipeline.hasStoredThumbnail(photo), "Never on disk.")
        XCTAssertNil(folder.pipeline.latestImage(assetID: photo.id, size: .thumbnail), "Never in the grid's thumbnail cache.")
        XCTAssertNil(folder.pipeline.latestImage(assetID: photo.id, size: .preview), "Never among the previews.")
        XCTAssertNil(folder.pipeline.cachedImage(for: photo, size: .preview, pixelSize: 256))
        session.viewing = ViewerRoute(asset: photo, source: .locked, albumContext: nil)

        session.sceneChanged(.background)

        // All of it before anything is awaited.
        XCTAssertEqual(session.phase, .locked)
        XCTAssertNil(session.viewing, "The viewer closes.")
        XCTAssertTrue(session.photos.assets.isEmpty)
        XCTAssertFalse(session.hasMore)
        XCTAssertFalse(folder.pipeline.holdsPrivateMedia, "Locked media leaves memory at once.")
        let relocked = folder.authorization.snapshot
        XCTAssertFalse(relocked.lockedFolderUnlocked)
        XCTAssertGreaterThan(relocked.privateEpoch, open.privateEpoch, "Relocking moves the private epoch.")
        XCTAssertEqual(relocked.epoch, open.epoch, "No library read is discarded.")
        XCTAssertEqual(relocked.writeGeneration, open.writeGeneration, "No write is fenced.")

        do {
            _ = try await folder.pipeline.image(for: photo, size: .thumbnail, pixelSize: 64)
            XCTFail("A locked photo's image is refused while the folder is locked.")
        } catch is CancellationError {}
        XCTAssertEqual(server.requests("GET", "assets/a/thumbnail").count, 2, "Nothing more was asked of the server.")
        await session.serverLock?.value
        XCTAssertEqual(server.requests("POST", "auth/session/lock").count, 1, "The server locks too.")

        // Another background, with the folder already locked, changes nothing.
        session.sceneChanged(.background)
        XCTAssertEqual(folder.authorization.snapshot, relocked)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requests("POST", "auth/session/lock").count, 1)
    }

    /// An answer that comes after a relock is dropped: an unlock doesn't open the folder (and the
    /// server is told to lock again after it), a month adds no photos, and an image isn't kept.
    func testLateResultAfterRelockDropped() async throws {
        let first = Self.ids("a", LockedFolderSession.firstPage), second = Self.ids("b", 3)
        let server = lockedServer([("2026-03-01", first), ("2026-02-01", second)])
        let monthGate = StubServer.Gate(), imageGate = StubServer.Gate(), unlockGate = StubServer.Gate()
        server.route("GET", "timeline/bucket", Self.month("2026-03-01", first), Self.month("2026-02-01", second).waiting(for: monthGate))
        server.route("GET", "assets/a00/thumbnail", image().waiting(for: imageGate))
        let folder = try makeFolder(server)
        let session = folder.session
        await unlock(session)
        XCTAssertEqual(session.photos.assets.count, first.count)
        XCTAssertTrue(session.hasMore)

        // A month on its way.
        session.photoAppeared(try XCTUnwrap(session.photos.assets.last).id)
        try await until("The next month was not asked for.") { server.requests("GET", "timeline/bucket").count == 2 }
        // An image on its way.
        let photo = try XCTUnwrap(session.photos.assets.first { $0.id == "a00" })
        let pipeline = folder.pipeline
        let download = Task { try await pipeline.image(for: photo, size: .preview, pixelSize: 64) }
        try await until("The image was not asked for.") { server.requests("GET", "assets/a00/thumbnail").count == 1 }

        session.lock()
        monthGate.open(); imageGate.open()
        do {
            _ = try await download.value
            XCTFail("An image that lands after the relock is not handed over.")
        } catch {}
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.phase, .locked)
        XCTAssertTrue(session.photos.assets.isEmpty, "The late month adds nothing.")
        XCTAssertFalse(session.isLoading)
        XCTAssertFalse(folder.pipeline.holdsPrivateMedia, "The late image isn't kept.")

        // An unlock on its way when the app goes to the background.
        server.route("POST", "auth/session/unlock", StubServer.Response.empty(204).waiting(for: unlockGate))
        let reads = server.requests("GET", "timeline/buckets").count
        let locks = server.requests("POST", "auth/session/lock").count
        session.entry.pin = "123456"
        session.unlock()
        XCTAssertEqual(session.phase, .unlocking)
        try await until("The unlock was not sent.") { server.requests("POST", "auth/session/unlock").count == 2 }
        session.sceneChanged(.background)
        XCTAssertEqual(session.phase, .locked)
        unlockGate.open()
        await session.unlocking?.value
        XCTAssertEqual(session.phase, .locked, "The late unlock doesn't open the folder.")
        XCTAssertFalse(folder.authorization.snapshot.lockedFolderUnlocked)
        XCTAssertTrue(session.photos.assets.isEmpty)
        XCTAssertEqual(server.requests("GET", "timeline/buckets").count, reads, "Nothing of the folder is read.")
        await session.serverLock?.value
        XCTAssertEqual(server.requests("POST", "auth/session/lock").count, locks + 2,
                       "The relock's lock, then another after the late unlock, in case it unlocked the server.")
    }

    /// The server's elevation running out relocks the folder.
    func testTheElevationRunningOutRelocks() async throws {
        let server = lockedServer([("2026-03-01", ["a"])])
        server.route("GET", "auth/status", Self.status(elevated: false), Self.status(elevated: true, expires: Date.now.addingTimeInterval(0.4)))
        let folder = try makeFolder(server)
        await unlock(folder.session)
        XCTAssertEqual(folder.session.phase, .unlocked)
        try await until("The folder did not relock when the elevation ran out.") { folder.session.phase == .locked }
        XCTAssertTrue(folder.session.photos.assets.isEmpty)
        XCTAssertFalse(folder.authorization.snapshot.lockedFolderUnlocked)
        await folder.session.serverLock?.value
        XCTAssertEqual(server.requests("POST", "auth/session/lock").count, 1)
    }

    // MARK: - Unlocking

    /// A first PIN is set, then unlocks; the password unlocks too; a wrong PIN shows the server's
    /// words and leaves the folder locked.
    func testPINSetUpPasswordAndAWrongPIN() async throws {
        let server = lockedServer([("2026-03-01", ["a"])])
        server.route("GET", "auth/status", Self.status(pinCode: false, elevated: false), Self.status(elevated: true))
        server.route("POST", "auth/pin-code", .empty(201))
        let folder = try makeFolder(server)
        let session = folder.session
        await session.appear()
        XCTAssertTrue(session.settingUp)
        session.entry.pin = "123456"
        session.entry.confirmation = "123450"
        XCTAssertFalse(session.canUnlock, "The two PINs must match.")
        session.entry.confirmation = "123456"
        XCTAssertTrue(session.canUnlock)
        session.unlock()
        await session.unlocking?.value
        XCTAssertEqual(session.phase, .unlocked)
        XCTAssertEqual(try body(server.requests("POST", "auth/pin-code").first), ["pinCode": "123456"])
        XCTAssertEqual(try body(server.requests("POST", "auth/session/unlock").first), ["pinCode": "123456"])
        XCTAssertEqual(Array(server.requests.map(\.path).filter { $0.hasPrefix("auth/") }.prefix(3)),
                       ["auth/status", "auth/pin-code", "auth/session/unlock"], "The PIN is set before it unlocks.")

        session.lock()
        server.route("GET", "auth/status", Self.status(elevated: false), Self.status(elevated: true))
        await session.appear()
        XCTAssertFalse(session.settingUp)
        session.entry.usePassword = true
        XCTAssertFalse(session.canUnlock)
        session.entry.password = "secret"
        session.unlock()
        await session.unlocking?.value
        XCTAssertEqual(session.phase, .unlocked)
        XCTAssertEqual(try body(server.requests("POST", "auth/session/unlock").last), ["password": "secret"])

        session.lock()
        server.route("GET", "auth/status", Self.status(elevated: false))
        server.route("POST", "auth/session/unlock", .immichError(400, message: "Wrong PIN code"))
        await session.appear()
        session.entry.pin = "000000"
        session.unlock()
        await session.unlocking?.value
        XCTAssertEqual(session.phase, .locked)
        XCTAssertEqual(session.failure?.message, "Wrong PIN code")
        XCTAssertEqual(session.entry, LockedFolderSession.Entry(), "What was typed goes.")
        XCTAssertFalse(folder.authorization.snapshot.lockedFolderUnlocked)
        session.entry.pin = "12345"
        XCTAssertFalse(session.canUnlock, "A PIN has six digits.")
    }

    /// The folder pages as its grid scrolls, with no Load more button: months are read until the
    /// grid has photos to scroll through, then one at a time as its last photos come on screen.
    func testTheFolderPagesAsItsGridScrolls() async throws {
        let first = Self.ids("a", LockedFolderSession.firstPage), second = Self.ids("b", 3), third = Self.ids("c", 2)
        let server = lockedServer([("2026-03-01", first), ("2026-02-01", second), ("2026-01-01", third)])
        let folder = try makeFolder(server)
        let session = folder.session
        await unlock(session)
        XCTAssertEqual(session.photos.assets.count, first.count, "One month fills the grid.")
        XCTAssertTrue(session.hasMore)
        XCTAssertEqual(server.requests("GET", "timeline/bucket").count, 1)
        XCTAssertEqual(server.requests("GET", "timeline/buckets").first?.query.first { $0.name == "visibility" }?.value, "locked",
                       "Only the Locked Folder's own timeline is asked for.")

        session.photoAppeared(session.photos.assets[0].id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requests("GET", "timeline/bucket").count, 1, "A photo far from the end reads nothing.")

        session.photoAppeared(session.photos.assets[first.count - 1].id)
        try await until("The next month was not read.") { session.photos.assets.count == first.count + second.count }
        XCTAssertTrue(session.hasMore)
        session.photoAppeared(try XCTUnwrap(session.photos.assets.last).id)
        try await until("The last month was not read.") { session.photos.assets.count == first.count + second.count + third.count }
        XCTAssertFalse(session.hasMore)
        XCTAssertFalse(session.isLoading)
        session.photoAppeared(try XCTUnwrap(session.photos.assets.last).id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requests("GET", "timeline/bucket").count, 3, "Nothing is left to read.")
        XCTAssertTrue(session.photos.assets.allSatisfy { $0.visibility == .locked })
    }

    /// A photo moved to the timeline or put in Trash leaves the folder in place, whichever screen
    /// moved it; a favorite stays, with its new record.
    func testAPhotoMovedOutLeavesTheFolderInPlace() async throws {
        let server = lockedServer([("2026-03-01", ["a", "b", "c"])])
        server.route("PUT", "assets", .empty(204))
        server.route("DELETE", "assets", .empty(204))
        let folder = try makeFolder(server)
        let session = folder.session
        await unlock(session)
        let photos = session.photos.assets
        let moved = try XCTUnwrap(photos.first { $0.id == "a" }), trashed = try XCTUnwrap(photos.first { $0.id == "b" })

        _ = try await folder.mutations.start(.visibility(["a"], .timeline), on: [moved]).result
        try await until("The photo moved to the timeline stayed.") { !session.photos.assets.contains { $0.id == "a" } }
        _ = try await folder.mutations.start(.trash(["b"]), on: [trashed]).result
        try await until("The photo put in Trash stayed.") { session.photos.assets.map(\.id) == ["c"] }
        XCTAssertEqual(server.requests("GET", "timeline/bucket").count, 1, "Nothing is read again.")
    }

    // MARK: - The account

    /// The account's session makes the folder, hands it every scene change before anything else,
    /// and ends it with the account: the app going to the background relocks it, whatever screen
    /// is up.
    func testTheAccountSessionRelocksTheFolderWhenTheAppGoesToTheBackground() async throws {
        let server = lockedServer([("2026-03-01", ["a"])])
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        let credential = StoredCredential(server: server.baseURL, token: "locked-folder", userID: "me-" + UUID().uuidString, name: "Me")
        var environment = AccountEnvironment()
        environment.usesDeviceStorage = false
        environment.syncsLibrary = false
        environment.usesDevicePhotos = false
        environment.importsBackupState = false
        environment.validatesSession = false
        let clients = AccountClients { address, credential, purpose in
            let authorization: AuthorizationState? = if case .session(let state) = purpose { state } else { nil }
            return try APIClient(baseURL: address, accessToken: credential?.token, userID: credential?.userID, sessionConfiguration: server.configuration(),
                                 networkConfiguration: NetworkConfiguration(), wifiName: NoWiFi(), authorization: authorization)
        }
        let dependencies = AccountDependencies(credentials: EphemeralCredentialStore(credential), mirror: nil,
                                               device: FakeAccountDevice(log: AccountEventLog()), clients: clients,
                                               unlockEvents: { AsyncStream { $0.finish() } })
        let account = AccountSession(environment: environment, dependencies: dependencies, presence: AppPresence(isForeground: true))
        await account.restore()
        XCTAssertEqual(account.phase, .active)
        let session = try XCTUnwrap(account.lockedFolder)
        let runtime = try XCTUnwrap(account.runtime)

        await unlock(session)
        XCTAssertEqual(session.phase, .unlocked)
        try await until("The account's snapshot did not say the folder is unlocked.") { account.authorization?.lockedFolderUnlocked == true }

        account.sceneChanged(.inactive)
        XCTAssertEqual(session.phase, .unlocked, "Only leaving the foreground relocks; the screen hides while inactive.")
        account.sceneChanged(.background)
        XCTAssertEqual(session.phase, .locked, "Relocked synchronously, through the account's scene changes.")
        XCTAssertTrue(session.photos.assets.isEmpty)
        XCTAssertFalse(runtime.authorization.snapshot.lockedFolderUnlocked)
        XCTAssertFalse(runtime.pipeline.holdsPrivateMedia)
        await session.serverLock?.value
        XCTAssertEqual(server.requests("POST", "auth/session/lock").count, 1)

        await account.signOut()
        XCTAssertNil(account.lockedFolder, "The folder ends with the account.")
        session.entry.pin = "123456"
        XCTAssertFalse(session.canUnlock, "An ended folder never unlocks again.")
    }

    /// The PIN kept for biometric unlock stays where it always was: the same Keychain service, and
    /// the account the storage paths name.
    func testTheLockedPINKeychainItemIsUnchanged() {
        XCTAssertEqual(LockedPINStore.service, "Ilyich.LockedFolder.PIN")
        let account = AccountID(server: URL(string: "https://photos.example.test/api")!, userID: "user-1")
        XCTAssertEqual(LockedPINStore.account(account.cacheScope), AccountStoragePaths(account).lockedPINAccount,
                       "The PIN's account is the account's digest, which AccountStoragePathsTests pins.")
    }

    // MARK: - The feed

    /// Moving a photo out of the Locked Folder reaches the library. Without an offline library the
    /// feed reads its months again itself; with one, the sync that follows names the photo and the
    /// feed reads its month again.
    func testMovingAPhotoToTheTimelineReconcilesTheFeed() async throws {
        let march = "2026-03-01T00:00:00Z"
        let taken = try XCTUnwrap(APIDate.parse("2026-03-10T12:00:00Z"))
        let kept = Asset(id: "kept", originalFileName: "kept.jpg", ownerId: "me", localDateTime: taken)
        let unlocked = Asset(id: "private", originalFileName: "private.jpg", ownerId: "me", localDateTime: taken)
        let moved = MutationResult(operation: OperationID(), request: .visibility(["private"], .timeline), succeeded: ["private"],
                                   failed: [:], fresh: ["private": unlocked], followUp: nil)

        for followsUp in [false, true] {
            let source = MovingLibrary(month: march, photos: [kept])
            let store = LibraryFeedStore(source: source)
            defer { store.stop() }
            await store.reload()
            let loaded = await becomesTrue { store.loaded[march]?.map(\.id) == ["kept"] }
            XCTAssertTrue(loaded, "The library loaded.")
            await source.add(unlocked)

            await FeedMutationApplier.apply(.applied(moved), to: store, refreshes: !followsUp)
            if followsUp {
                let account = AccountID(server: URL(string: "https://photos.example.test/api")!, userID: "me")
                var change = LibraryChange(account: account, authorization: AuthorizationEpoch(account: account, value: 1), indexRevision: 2, origin: .sync)
                change.upserted = ["private": .init(from: nil, to: MonthKey(bucketID: march))]
                await store.apply(change)
            }
            let reconciled = await becomesTrue { Set(store.loaded[march]?.map(\.id) ?? []) == ["kept", "private"] }
            XCTAssertTrue(reconciled, followsUp ? "The follow-up sync's change brings the photo in." : "The feed reads again and finds the photo.")
            XCTAssertFalse(store.loaded[march]?.contains { $0.visibility == .locked } ?? true, "No locked record is in the feed.")
        }
    }
}

/// One month of photos, to which a photo moved out of the Locked Folder is added.
private actor MovingLibrary: FakeFeedSource {
    nonisolated let cacheScope = "test-locked-folder-" + UUID().uuidString
    nonisolated var userID: String? { "me" }
    private let bucket: String
    private var photos: [Asset]

    init(month: String, photos: [Asset]) { bucket = month; self.photos = photos }

    func add(_ asset: Asset) { photos.append(asset) }

    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] { [TimeBucket(timeBucket: bucket, count: photos.count)] }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] { bucket == self.bucket ? photos : [] }
    func search(_ body: SearchQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
    func metadataSearch(_ body: MetadataQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
}

import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// Plan line 78, "Collections handle deletion, restoration, locking and membership changes
/// correctly" (G1): the Trash's own screen, the memories and the grids a photo opens follow what
/// changes elsewhere while they are up, through the account's bus. A mutation's result applies in
/// place, whichever screen made it; a sync's change takes out at once what the offline library let
/// go, and has the rest read again quietly, never undoing a change made here meanwhile. The Locked
/// Folder's are in LockedFolderSessionTests, the feeds' in FeedSessionTests and SearchFeedTests.
@MainActor final class CollectionFollowingTests: XCTestCase {
    // MARK: - The Trash

    /// A photo restored on the web leaves the Trash and the selection; one deleted for good there
    /// leaves at once, with nothing read; one put in Trash there, in a newer month, joins, and the
    /// months already shown stay shown.
    func testTheTrashFollowsPhotosRestoredDeletedAndTrashedElsewhere() async throws {
        let server = makeStubServer()
        server.route("GET", "server/features", Self.features)
        server.route("GET", "timeline/buckets", Self.buckets([("2026-03-01", 2), ("2026-02-01", 1)]))
        server.route("GET", "timeline/bucket", Self.trashed("2026-03-01", ["t1", "t2"]), Self.trashed("2026-02-01", ["t3"]))
        let bus = LibraryBus()
        let trash = TrashModel(api: try makeAPI(server))
        trash.follow(mutations: nil, bus: bus)
        await trash.reload()
        XCTAssertEqual(trash.assets.map(\.id), ["t1", "t2"])
        await trash.loadNext()
        XCTAssertEqual(trash.assets.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(trash.nextBucket, 2)
        trash.selection = ["t2", "t3"]

        // t2 is restored on the web: the sync's change names it, and the months shown are read again.
        server.route("GET", "timeline/buckets", Self.buckets([("2026-03-01", 1), ("2026-02-01", 1)]))
        server.route("GET", "timeline/bucket", Self.trashed("2026-03-01", ["t1"]), Self.trashed("2026-02-01", ["t3"]))
        bus.post(.changed(Self.change(upserted: ["t2"]), accessChanged: false))
        try await until("The photo restored elsewhere stayed in the Trash.") { trash.assets.map(\.id) == ["t1", "t3"] }
        XCTAssertEqual(trash.selection, ["t3"], "The selection keeps what is still there.")
        XCTAssertEqual(trash.nextBucket, 2, "Both months stay shown.")

        // t3 is deleted for good on the web: it leaves at once, and nothing is read.
        let reads = server.requests("GET", "timeline/bucket").count
        bus.post(.changed(Self.change(removed: ["t3"]), accessChanged: false))
        try await until("The photo deleted elsewhere stayed in the Trash.") { trash.assets.map(\.id) == ["t1"] }
        XCTAssertTrue(trash.selection.isEmpty)
        XCTAssertEqual(server.requests("GET", "timeline/bucket").count, reads, "Nothing is read for a photo gone.")

        // t4, taken in April, is put in Trash on the web: it joins, and March stays shown.
        server.route("GET", "timeline/buckets", Self.buckets([("2026-04-01", 1), ("2026-03-01", 1)]))
        server.route("GET", "timeline/bucket", Self.trashed("2026-04-01", ["t4"]), Self.trashed("2026-03-01", ["t1"]))
        bus.post(.changed(Self.change(upserted: ["t4"]), accessChanged: false))
        try await until("The photo put in Trash elsewhere did not join.") { trash.assets.map(\.id) == ["t4", "t1"] }
        XCTAssertEqual(trash.nextBucket, 2)
        XCTAssertEqual(trash.buckets.count, 2, "Load more has nothing left to read.")
    }

    /// A quiet read that began before a photo was restored here would show it still in the Trash:
    /// it is read again instead, and the photo stays out.
    func testAQuietReadOfTheTrashNeverBringsBackAPhotoRestoredMeanwhile() async throws {
        let server = makeStubServer()
        server.route("GET", "server/features", Self.features)
        server.route("GET", "timeline/buckets", Self.buckets([("2026-03-01", 2)]))
        server.route("GET", "timeline/bucket", Self.trashed("2026-03-01", ["t1", "t2"]))
        let bus = LibraryBus()
        let trash = TrashModel(api: try makeAPI(server))
        trash.follow(mutations: nil, bus: bus)
        await trash.reload()
        XCTAssertEqual(trash.assets.map(\.id), ["t1", "t2"])

        // A change starts a quiet read, which the server answers as it was before the restore.
        let gate = StubServer.Gate()
        server.route("GET", "timeline/buckets", Self.buckets([("2026-03-01", 2)]).waiting(for: gate), Self.buckets([("2026-03-01", 1)]))
        server.route("GET", "timeline/bucket", Self.trashed("2026-03-01", ["t1", "t2"]), Self.trashed("2026-03-01", ["t1"]))
        let summaries = server.requests("GET", "timeline/buckets").count
        bus.post(.changed(Self.change(upserted: ["elsewhere"]), accessChanged: false))
        try await until("The quiet read did not start.") { server.requests("GET", "timeline/buckets").count > summaries }

        // Meanwhile t2 is restored here.
        bus.post(.mutation(.applied(MutationResult(operation: OperationID(), request: .restore(["t2"]), succeeded: ["t2"], failed: [:],
                                                   fresh: [:], followUp: nil))))
        try await until("The restored photo stayed in the Trash.") { trash.assets.map(\.id) == ["t1"] }
        gate.open()
        try await until("The read overtaken was not read again.") { server.requests("GET", "timeline/buckets").count == summaries + 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(trash.assets.map(\.id), ["t1"], "The read that began before the restore never shows the photo again.")
    }

    /// Restoring here goes through the account's mutations: the photos leave the Trash in place
    /// from the result, and the screen says how many the server restored.
    func testRestoringFromTheTrashLeavesItAndSaysHowMany() async throws {
        let server = makeStubServer()
        server.route("GET", "server/features", Self.features)
        server.route("GET", "timeline/buckets", Self.buckets([("2026-03-01", 2)]))
        server.route("GET", "timeline/bucket", Self.trashed("2026-03-01", ["t1", "t2"]))
        server.route("POST", "trash/restore/assets", .json(#"{"count":1}"#))
        let api = try makeAPI(server)
        let mutations = LibraryMutationService(client: api, pipeline: nil, authorization: nil, refresh: nil)
        addTeardownBlock { await mutations.shutdown() }
        let trash = TrashModel(api: api)
        trash.follow(mutations: mutations, bus: nil)
        await trash.reload()
        trash.selection = ["t1"]
        await trash.restoreSelected()
        try await until("The restored photo stayed in the Trash.") { trash.assets.map(\.id) == ["t2"] }
        XCTAssertEqual(trash.resultMessage, "Restored 1 items.")
        XCTAssertTrue(trash.selection.isEmpty)
        let body = try XCTUnwrap(server.requests("POST", "trash/restore/assets").first?.body)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: [String]])?["ids"], ["t1"])
    }

    // MARK: - Memories

    /// A memory shows only timeline photos out of the Trash. A photo deleted elsewhere leaves its
    /// memory at once, with nothing read; one archived from a viewer leaves from the result; one
    /// put in Trash on the web, which the sync names, has the memories read again, as does a change
    /// to the memories themselves; a change naming no photo of theirs reads nothing; and a memory
    /// saved elsewhere shows it.
    func testMemoriesFollowPhotosChangedElsewhere() async throws {
        let server = makeStubServer()
        server.route("GET", "users/me/preferences", .json(#"{"memories":{"enabled":true}}"#))
        server.route("GET", "memories", Self.memories([("m1", ["p1", "p2", "p3"]), ("m2", ["p4"])]))
        let api = try makeAPI(server)
        let bus = LibraryBus()
        let collections = CollectionsService(client: api, authorization: nil, bus: bus)
        addTeardownBlock { await collections.shutdown() }
        let model = MemoriesModel()
        model.follow(collections: collections, bus: bus)
        await model.load(.today)
        func photos() -> [[String]] { model.memories.map { $0.assets.map(\.id) } }
        XCTAssertEqual(photos(), [["p1", "p2", "p3"], ["p4"]])

        bus.post(.changed(Self.change(removed: ["p1"]), accessChanged: false))
        try await until("The photo deleted elsewhere stayed in its memory.") { photos() == [["p2", "p3"], ["p4"]] }
        XCTAssertEqual(server.requests("GET", "memories").count, 1, "Nothing is read for a photo gone.")

        var archived = Asset(id: "p2")
        archived.visibility = .archive
        bus.post(.mutation(.applied(MutationResult(operation: OperationID(), request: .visibility(["p2"], .archive), succeeded: ["p2"],
                                                   failed: [:], fresh: ["p2": archived], followUp: nil))))
        try await until("The photo archived from a viewer stayed in its memory.") { photos() == [["p3"], ["p4"]] }

        server.route("GET", "memories", Self.memories([("m1", []), ("m2", ["p4"])]))
        bus.post(.changed(Self.change(upserted: ["p3"]), accessChanged: false))
        try await until("The memories were not read again for a photo they show.") { photos() == [[], ["p4"]] }
        XCTAssertEqual(server.requests("GET", "memories").count, 2)

        bus.post(.changed(Self.change(upserted: ["elsewhere"]), accessChanged: false))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(server.requests("GET", "memories").count, 2, "A change naming no photo of theirs reads nothing.")

        server.route("GET", "memories", Self.memories([("m2", ["p4"])]))
        var memories = Self.change()
        memories.memoriesChanged = true
        bus.post(.changed(memories, accessChanged: false))
        try await until("A change to the memories did not read them again.") { model.memories.map(\.id) == ["m2"] }

        bus.post(.collection(.memorySaved("m2", saved: true)))
        try await until("A memory saved elsewhere did not show it.") { model.memories.first?.isSaved == true }
    }

    /// Among the saved memories, one unsaved elsewhere leaves.
    func testAMemoryUnsavedElsewhereLeavesTheSavedMemories() async throws {
        let server = makeStubServer()
        server.route("GET", "memories", Self.memories([("m1", ["p1"]), ("m2", ["p2"])], saved: true))
        let api = try makeAPI(server)
        let bus = LibraryBus()
        let collections = CollectionsService(client: api, authorization: nil, bus: bus)
        addTeardownBlock { await collections.shutdown() }
        let model = MemoriesModel()
        model.follow(collections: collections, bus: bus)
        await model.load(.saved)
        XCTAssertEqual(model.memories.map(\.id), ["m1", "m2"])
        XCTAssertEqual(server.requests("GET", "memories").first?.query, [URLQueryItem(name: "isSaved", value: "true")])
        bus.post(.collection(.memorySaved("m1", saved: false)))
        try await until("The memory unsaved elsewhere stayed among the saved.") { model.memories.map(\.id) == ["m2"] }
    }

    // MARK: - Grids opened from a photo

    /// The grids a photo's Info opens (its person, album, place or text) and Find similar drop at
    /// once what a sync's change took out of the offline library: a photo deleted, locked or out of
    /// reach elsewhere. A photo the change names otherwise stays.
    func testAGridOpenedFromAPhotoDropsPhotosGoneElsewhere() {
        let list = AssetList([Asset(id: "a"), Asset(id: "b"), Asset(id: "c")], keeps: CollectionMembership.searched)
        var change = Self.change(upserted: ["a"], removed: ["b"])
        change.accessLost = ["c"]
        list.drop(change)
        XCTAssertEqual(list.assets.map(\.id), ["a"])
        XCTAssertEqual(list.losses, 0, "Nothing has the screen read its photos again.")
    }

    // MARK: - Support

    private func makeAPI(_ server: StubServer) throws -> APIClient {
        let api = try APIClient(baseURL: server.baseURL, accessToken: "collections", userID: "me", sessionConfiguration: server.configuration(),
                                networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        return api
    }

    private static let features = StubServer.Response.json(
        #"{"passwordLogin":true,"oauth":false,"smartSearch":true,"ocr":false,"facialRecognition":true,"map":true,"trash":true,"sidecar":true,"realtimeTranscoding":false}"#)

    private static func buckets(_ months: [(date: String, count: Int)]) -> StubServer.Response {
        let object = months.map { ["timeBucket": $0.date + "T00:00:00.000Z", "count": $0.count] as [String: Any] }
        return .json(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    /// One month of the Trash as the server's timeline answers it.
    private static func trashed(_ date: String, _ ids: [String]) -> StubServer.Response {
        func column(_ value: Any) -> [Any] { Array(repeating: value, count: ids.count) }
        let object: [String: Any] = [
            "id": ids, "ownerId": column("me"), "ratio": column(1.5), "isFavorite": column(false), "isTrashed": column(true),
            "isImage": column(true), "visibility": column("timeline"), "fileCreatedAt": column(date + "T12:00:00Z"),
            "createdAt": column(date + "T12:00:00Z"), "localOffsetHours": column(0), "duration": column(NSNull()),
            "thumbhash": column(NSNull()), "mediaRevision": column("r1"), "livePhotoVideoId": column(NSNull()),
        ]
        return .json(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    private static func memories(_ memories: [(id: String, photos: [String])], saved: Bool = false) -> StubServer.Response {
        let object = memories.map { memory -> [String: Any] in
            ["id": memory.id, "type": "on_this_day", "memoryAt": "2024-06-01T00:00:00.000Z", "isSaved": saved,
             "data": ["year": 2024], "assets": memory.photos.map { ["id": $0, "type": "IMAGE", "visibility": "timeline"] }]
        }
        return .json(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    private static func change(upserted: Set<String> = [], removed: Set<String> = []) -> LibraryChange {
        var change = LibraryChange(account: LegacyGoldens.account, authorization: AuthorizationEpoch(account: LegacyGoldens.account, value: 1),
                                   indexRevision: 2, origin: .sync)
        change.upserted = Dictionary(uniqueKeysWithValues: upserted.map { ($0, LibraryChange.MonthMove()) })
        change.removed = removed
        return change
    }

    private func until(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail(message); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

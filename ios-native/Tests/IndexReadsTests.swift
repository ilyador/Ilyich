import CryptoKit
import Foundation
import IlyichPlatform
import Synchronization
import XCTest
@testable import Ilyich

/// Q3: feeds read the derived tables in the library's order, the access purge forgets only the
/// photos that left the account, and dependents that came early or were dropped come back.
final class IndexReadsTests: XCTestCase {
    // MARK: - Order

    /// A month is ordered as the library always was, not as the server orders it (day, file
    /// creation time, file name): by the time taken, newest first, then by ID, ascending either
    /// way. In created-at order the time added takes the place of the time taken.
    func testMonthOrderIsTheTimeTakenThenID() async throws {
        let index = try makeIndex()
        _ = try await index.apply([
            Self.asset("late-day", taken: "2026-02-28T09:00:00Z"),
            // Same day: the time taken decides, not the file's creation time.
            Self.asset("taken-earlier", taken: "2026-02-10T08:00:00Z", fileCreated: "2026-02-10T08:00:00Z", name: "IMG_0001.jpg"),
            Self.asset("taken-later", taken: "2026-02-10T23:00:00Z", fileCreated: "2026-02-10T07:00:00Z", name: "IMG_0002.jpg"),
            // Same time taken: the ID decides, not the file name or creation time.
            Self.asset("name-a", taken: "2026-02-03T12:00:00Z", fileCreated: "2026-02-03T12:00:00Z", name: "IMG_0005.jpg"),
            Self.asset("name-b", taken: "2026-02-03T12:00:00Z", fileCreated: "2026-02-03T11:00:00Z", name: "IMG_0004.jpg"),
            Self.asset("tie-2", taken: "2026-02-03T09:00:00Z", fileCreated: "2026-02-03T09:00:00Z", name: "DSC.jpg"),
            Self.asset("tie-1", taken: "2026-02-03T09:00:00Z", fileCreated: "2026-02-03T09:00:00Z", name: "DSC.jpg"),
            SyncEvents.complete(),
        ], epoch: index.epoch())
        let newest = ["late-day", "taken-later", "taken-earlier", "name-a", "name-b", "tie-1", "tie-2"]
        let month = try await index.timeBucket("2026-02-01T00:00:00Z").map(\.id)
        XCTAssertEqual(month, newest)
        var oldest = LibraryQuery.library; oldest.ranking = .chronological(.takenAt, ascending: true)
        let ascending = try await index.timeBucket("2026-02-01T00:00:00Z", of: oldest).map(\.id)
        XCTAssertEqual(ascending, ["tie-1", "tie-2", "name-a", "name-b", "taken-earlier", "taken-later", "late-day"],
                       "Oldest first, photos taken at one time still in ID order.")
        let across = try await index.timelineAssets().map(\.id)
        XCTAssertEqual(across, newest, "Across months the order is the same.")

        // Added in two months: the time added first, then the ID.
        _ = try await index.apply([
            Self.asset("added-first", taken: "2026-02-03T12:00:00Z", created: "2026-03-01T00:00:00Z", fileCreated: "2026-02-03T12:00:00Z", name: "Z.jpg"),
            Self.asset("added-last", taken: "2025-05-01T12:00:00Z", created: "2026-03-20T00:00:00Z"),
            Self.asset("added-late", taken: "2026-02-01T12:00:00Z", created: "2026-03-10T00:00:00Z"),
        ], epoch: index.epoch())
        var added = LibraryQuery.library; added.ranking = .chronological(.createdAt, ascending: false)
        let addedMonths = try await index.timeBuckets(added)
        XCTAssertEqual(addedMonths.map(\.timeBucket), ["2026-03-01"])
        let addedOrder = try await index.timeBucket("2026-03-01T00:00:00Z", of: added).map(\.id)
        XCTAssertEqual(addedOrder, ["added-last", "added-late", "added-first", "late-day", "name-a", "name-b", "taken-earlier", "taken-later", "tie-1", "tie-2"],
                       "Photos added at one time are in ID order.")
    }

    /// Before the index is readable months come from the server, which orders them by day, file
    /// creation time and file name; they are shown in the library's order all the same.
    func testServerMonthsAreShownInTheLibrarysOrder() throws {
        let day = try XCTUnwrap(APIDate.parse("2026-02-10T00:00:00Z"))
        let morning = Asset(id: "b-morning", fileCreatedAt: day.addingTimeInterval(9 * 3_600), localDateTime: day.addingTimeInterval(9 * 3_600))
        let night = Asset(id: "c-night", fileCreatedAt: day.addingTimeInterval(1 * 3_600), localDateTime: day.addingTimeInterval(23 * 3_600))
        let tie = Asset(id: "a-tie", fileCreatedAt: day.addingTimeInterval(9 * 3_600), localDateTime: day.addingTimeInterval(9 * 3_600))
        let earlier = Asset(id: "d-earlier", fileCreatedAt: day.addingTimeInterval(-86_400), localDateTime: day.addingTimeInterval(-86_400))
        let server = [morning, tie, night, earlier]
        XCTAssertEqual(try ServerTimelineRequest(.library, userID: "alice").libraryOrder(server).map(\.id), ["c-night", "a-tie", "b-morning", "d-earlier"])
        var oldest = LibraryQuery.library; oldest.ranking = .chronological(.takenAt, ascending: true)
        XCTAssertEqual(try ServerTimelineRequest(oldest, userID: "alice").libraryOrder(server).map(\.id), ["d-earlier", "a-tie", "b-morning", "c-night"])
    }

    // MARK: - Equivalence

    /// Every feed the app shows, laid out by month from the index, against the server's rules
    /// applied to the same records: the same months, counts and photos, in the library's order.
    /// Place, Lightroom and person by month are among them.
    func testIndexAndServerAgreeForEveryPreset() async throws {
        let index = try makeIndex()
        let library = Self.makeLibrary()
        _ = try await index.apply(library.events + [SyncEvents.complete()], epoch: index.epoch())
        let readable = try await index.isReadable()
        XCTAssertTrue(readable)

        var trash = LibraryQuery.trash; trash.stacks = .all
        var oldest = LibraryQuery.library; oldest.ranking = .chronological(.takenAt, ascending: true)
        let presets: [(String, LibraryQuery, partners: Bool)] = [
            ("Library", .library, false),
            ("Library with partners", .library, true),
            ("Favorites", .favorites, false),
            ("Archive", .archive, false),
            ("Trash", trash, false),
            ("Lightroom", .lightroom, false),
            ("Album", .album("shared"), false),
            ("My album", .album("mine"), false),
            ("Person", .person("maya"), false),
            ("Place", .place(PlaceMembership(placeID: "Lisbon", assetIDs: library.place, markerQuery: "")), false),
            ("Partner", .partner("bob"), false),
            ("Recently added", .recentlyAdded, false),
            ("Library, oldest first", oldest, false),
        ]

        for (name, query, partners) in presets {
            let expected = library.server(try IndexFeedRequest(query, userID: "alice", includesPartners: partners))
            let months = try await index.timeBuckets(query, includesPartners: partners)
            XCTAssertEqual(months.map(\.timeBucket), expected.map(\.month), "\(name): months")
            XCTAssertEqual(months.map(\.count), expected.map(\.ids.count), "\(name): counts")
            XCTAssertFalse(expected.isEmpty, "\(name) shows photos.")
            for month in expected {
                let photos = try await index.timeBucket(month.month + "T00:00:00Z", of: query, includesPartners: partners)
                XCTAssertEqual(photos.map(\.id), month.ids, "\(name): \(month.month)")
            }
        }

        // A stack counts its photos as the server does: those in the timeline, not in the trash.
        let stacked = try await index.timelineAssets(limit: 2_000).compactMap(\.stack)
        XCTAssertFalse(stacked.isEmpty)
        for stack in stacked { XCTAssertEqual(stack.assetCount, library.stackCount(stack.id), stack.id) }
    }

    // MARK: - Dependents

    /// A face can arrive before the shared photo it is on. Only a marker of it waits, since the
    /// face does not say whose photo it is on; when the photo arrives a repair fetches its faces,
    /// and the face counts for its person, once.
    func testFaceArrivingBeforeItsSharedAssetCountsOnceTheAssetArrives() async throws {
        let index = try makeIndex()
        let person = LibraryQuery.person("maya")
        _ = try await index.apply([
            SyncEvents.event("PersonV1", #"{"id":"maya","name":"Maya","isHidden":false}"#, ack: "PersonV1|maya"),
            SyncEvents.event("AlbumV2", #"{"id":"trip","ownerId":"bob","name":"Trip","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":null,"isActivityEnabled":true,"order":"desc"}"#, ack: "AlbumV2|trip"),
            SyncEvents.event("AlbumUserV1", #"{"albumId":"trip","userId":"alice","role":"viewer"}"#, ack: "AlbumUserV1|trip"),
            Self.face("face-1", asset: "shared"),
            SyncEvents.complete(),
        ], epoch: index.epoch())
        let early = try await index.timeBuckets(person)
        let stored = try await index.entityData(kind: "face", id: "face-1")
        XCTAssertEqual(early, [], "No photo yet.")
        XCTAssertNil(stored, "The face waits aside, not as a face of a photo the library lacks.")
        let waiting = try await index.writer.orphanPayloads(of: "shared")
        XCTAssertEqual(waiting, [""], "Only a marker waits: no person, no bounding box.")

        _ = try await index.apply([
            Self.asset("shared", owner: "bob", taken: "2026-02-01T05:00:00Z", type: "AlbumAssetCreateV2"),
            SyncEvents.event("AlbumToAssetV1", #"{"albumId":"trip","assetId":"shared"}"#, ack: "AlbumToAssetV1|shared"),
        ], epoch: index.epoch())
        let queued = try await index.dueRepairs(limit: 10)
        XCTAssertEqual(queued, ["shared"], "The faces that waited are fetched.")
        let arrival = await DependentRepairer(index: index, fetcher: StaticFetcher(["shared": [Self.face("face-1", asset: "shared")]])).run()
        XCTAssertTrue(arrival.people.contains("maya"), "Maya's photos changed.")
        let months = try await index.timeBuckets(person)
        XCTAssertEqual(months.map(\.count), [1])
        let photo = try await index.asset(id: "shared")
        XCTAssertEqual(photo?.people?.map(\.id), ["maya"])

        // The face again, and another of Maya on the same photo: still one photo.
        _ = try await index.apply([Self.face("face-1", asset: "shared"), Self.face("face-2", asset: "shared")], epoch: index.epoch())
        let again = try await index.timeBuckets(person)
        XCTAssertEqual(again.map(\.count), [1])

        // A face of a photo in the Locked Folder is never kept, waiting or not.
        _ = try await index.apply([Self.asset("secret", taken: "2026-02-02T05:00:00Z", visibility: "locked"),
                                   Self.face("face-3", asset: "secret")], epoch: index.epoch())
        _ = try await index.apply([Self.asset("secret", taken: "2026-02-02T05:00:00Z")], epoch: index.epoch())
        let unlocked = try await index.entityData(kind: "face", id: "face-3")
        XCTAssertNil(unlocked, "Nothing private comes back from the queue; the repair fetches it again.")

        // Nor one of a photo locked before the index knew, which locked_asset lacks: only its
        // marker waits.
        _ = try await index.apply([Self.face("face-4", asset: "locked-before-q2", person: "maya")], epoch: index.epoch())
        let held = try await index.writer.orphanPayloads(of: "locked-before-q2")
        XCTAssertEqual(held, [""])

        // The account's own EXIF follows its photo; without it, the photo is in the Locked Folder
        // or deleted, even one locked before the index knew, and its EXIF is never kept.
        _ = try await index.apply([SyncEvents.event("AssetExifV1", #"{"assetId":"locked-long-ago","city":"Lisbon"}"#, ack: "AssetExifV1|x")], epoch: index.epoch())
        _ = try await index.apply([Self.asset("locked-long-ago", taken: "2026-02-02T05:00:00Z")], epoch: index.epoch())
        let exif = try await index.entityData(kind: "exif", id: "locked-long-ago")
        XCTAssertNil(exif)
    }

    /// Locking a photo drops its EXIF, faces and OCR, and the server sends them again only when
    /// they change. Unlocking queues a repair, which fetches them and writes them as the sync
    /// stream would.
    func testUnlockedPhotoRegainsItsMetadata() async throws {
        let index = try makeIndex()
        let server = makeStubServer()
        let api = try APIClient(baseURL: server.baseURL, accessToken: "repair-session", userID: "alice",
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        _ = try await index.apply([
            SyncEvents.event("PersonV1", #"{"id":"maya","name":"Maya","isHidden":false}"#, ack: "PersonV1|maya"),
            Self.asset("photo", taken: "2026-02-01T05:00:00Z"),
            SyncEvents.event("AssetExifV1", #"{"assetId":"photo","city":"Lisbon","country":"Portugal","make":"Apple"}"#, ack: "AssetExifV1|photo"),
            Self.face("face-1", asset: "photo"),
            SyncEvents.event("AssetOcrV1", #"{"id":"ocr-1","assetId":"photo","text":"EXIT","isVisible":true}"#, ack: "AssetOcrV1|ocr-1"),
            SyncEvents.complete(),
        ], epoch: index.epoch())
        _ = try await index.apply([Self.asset("photo", taken: "2026-02-01T05:00:00Z", visibility: "locked")], epoch: index.epoch())
        let whileLocked = try await index.dueRepairs(limit: 10)
        XCTAssertEqual(whileLocked, [])

        _ = try await index.apply([Self.asset("photo", taken: "2026-02-01T05:00:00Z")], epoch: index.epoch())
        let bare = try await index.asset(id: "photo")
        XCTAssertNil(bare?.exifInfo, "The stream brought the photo back without its EXIF.")
        let queued = try await index.dueRepairs(limit: 10)
        XCTAssertEqual(queued, ["photo"])

        server.route("GET", "assets/photo", .json(#"{"id":"photo","visibility":"timeline","exifInfo":{"city":"Lisbon","country":"Portugal","make":"Apple","model":"iPhone 15 Pro","latitude":38.7,"longitude":-9.1}}"#))
        server.route("GET", "faces", .json(#"[{"id":"face-1","imageWidth":4032,"imageHeight":3024,"boundingBoxX1":10,"boundingBoxY1":20,"boundingBoxX2":110,"boundingBoxY2":140,"sourceType":"machine-learning","person":{"id":"maya","name":"Maya"}}]"#))
        server.route("GET", "assets/photo/ocr", .json(#"[{"id":"ocr-1","assetId":"photo","x1":0.1,"y1":0.1,"x2":0.4,"y2":0.1,"x3":0.4,"y3":0.2,"x4":0.1,"y4":0.2,"boxScore":0.9,"textScore":0.8,"text":"EXIT"}]"#))
        let change = await DependentRepairer(index: index, fetcher: ServerDependentFetcher(client: api)).run()

        let repaired = try await index.asset(id: "photo")
        XCTAssertEqual(repaired?.exifInfo?.city, "Lisbon")
        XCTAssertEqual(repaired?.people?.map(\.id), ["maya"])
        let text = try await index.assetOCR(id: "photo").map(\.text)
        XCTAssertEqual(text, ["EXIT"])
        let person = try await index.timeBuckets(.person("maya"))
        XCTAssertEqual(person.map(\.count), [1])
        XCTAssertTrue(change.people.contains("maya"))
        XCTAssertNotNil(change.upserted["photo"], "The photo's details changed.")
        let left = try await index.dueRepairs(limit: 10)
        XCTAssertEqual(left, [])
        XCTAssertEqual(server.requests("GET", "faces").first?.query, [URLQueryItem(name: "id", value: "photo")])

        // Written in the sync stream's shapes, every field present.
        let exifData = try await index.entityData(kind: "exif", id: "photo")
        let exif = try JSONDecoder().decode([String: EntityJSON].self, from: XCTUnwrap(exifData))
        XCTAssertEqual(Set(exif.keys), Set(ServerDependentFetcher.exifFields + ["assetId"]))
        let faceData = try await index.entityData(kind: "face", id: "face-1")
        let face = try JSONDecoder().decode([String: EntityJSON].self, from: XCTUnwrap(faceData))
        XCTAssertEqual(Set(face.keys), Set(ServerDependentFetcher.faceFields + ["id", "assetId", "personId", "sourceType", "deletedAt", "isVisible"]))
        XCTAssertEqual(face["personId"], .string("maya"))
    }

    /// A photo locked before the index kept locked_asset comes back from the Locked Folder as a
    /// photo of the account's own the index never held, though the server had it at the last
    /// sync: its dependents are fetched. New uploads, partners' photos and a first sync are not.
    func testPhotoLockedBeforeTheIndexKnewIsRepairedWhenUnlocked() async throws {
        let index = try makeIndex()
        _ = try await index.apply([
            SyncEvents.event("PartnerV1", #"{"sharedById":"bob","sharedWithId":"alice","inTimeline":true}"#, ack: "PartnerV1|bob"),
            Self.asset("first-sync", taken: "2026-02-01T05:00:00Z", created: "2020-01-01T00:00:00Z"),
            SyncEvents.complete(),
        ], epoch: index.epoch())
        let afterFirst = try await index.dueRepairs(limit: 10)
        XCTAssertEqual(afterFirst, [], "A first sync sends the dependents itself.")

        let future = Date().addingTimeInterval(3_600).ISO8601Format()
        _ = try await index.apply([
            Self.asset("locked-long-ago", taken: "2025-02-01T05:00:00Z", created: "2020-01-01T00:00:00Z"),
            Self.asset("new-upload", taken: "2026-02-01T06:00:00Z", created: future),
            Self.asset("partners", owner: "bob", taken: "2026-02-01T07:00:00Z", created: "2020-01-01T00:00:00Z", type: "PartnerAssetBackfillV2"),
            // Seen before: an update is not a return from the Locked Folder.
            Self.asset("first-sync", taken: "2026-02-01T05:00:00Z", created: "2020-01-01T00:00:00Z"),
        ], epoch: index.epoch())
        let queued = try await index.dueRepairs(limit: 10)
        XCTAssertEqual(queued, ["locked-long-ago"])
    }

    /// A repair fetched while the sync stream changed the photo's dependents would put older
    /// records over newer ones: it writes nothing, stays queued and is fetched again.
    func testRepairOverlappingTheStreamIsFetchedAgain() async throws {
        let index = try makeIndex()
        _ = try await index.apply([
            SyncEvents.event("PersonV1", #"{"id":"maya","name":"Maya","isHidden":false}"#, ack: "PersonV1|maya"),
            SyncEvents.event("PersonV1", #"{"id":"leo","name":"Leo","isHidden":false}"#, ack: "PersonV1|leo"),
            Self.asset("photo", taken: "2026-02-01T05:00:00Z", visibility: "locked"),
            SyncEvents.complete(),
        ], epoch: index.epoch())
        _ = try await index.apply([Self.asset("photo", taken: "2026-02-01T05:00:00Z")], epoch: index.epoch())
        let fetcher = StaticFetcher(["photo": [Self.face("face-1", asset: "photo", person: "maya")]]) {
            // The face moves to Leo on the web while the repair is fetching.
            _ = try? await index.apply([Self.face("face-1", asset: "photo", person: "leo")], epoch: index.epoch())
        }
        _ = await DependentRepairer(index: index, fetcher: fetcher).run()
        let face = try await index.entityData(kind: "face", id: "face-1")
        let stored = try JSONDecoder().decode([String: EntityJSON].self, from: XCTUnwrap(face))
        XCTAssertEqual(stored["personId"], .string("leo"), "The stream's newer face stays.")
        let queued = try await index.dueRepairs(limit: 10)
        XCTAssertEqual(queued, ["photo"], "Fetched again on the next run.")

        let quiet = StaticFetcher(["photo": [Self.face("face-1", asset: "photo", person: "leo")]])
        _ = await DependentRepairer(index: index, fetcher: quiet).run()
        let left = try await index.dueRepairs(limit: 10)
        XCTAssertEqual(left, [])
    }

    /// Immich answers a photo the account cannot read with 400: faces or OCR it won't give are
    /// none, and a photo gone or locked again drops the repair at once.
    func testRepairTreatsNoAccessAsPermanent() async throws {
        let index = try makeIndex()
        let server = makeStubServer()
        let api = try APIClient(baseURL: server.baseURL, accessToken: "repair-session", userID: "alice",
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        _ = try await index.apply([Self.asset("photo", taken: "2026-02-01T05:00:00Z", visibility: "locked"),
                                   Self.asset("gone", taken: "2026-02-01T05:00:00Z", visibility: "locked"),
                                   SyncEvents.complete()], epoch: index.epoch())
        _ = try await index.apply([Self.asset("photo", taken: "2026-02-01T05:00:00Z"), Self.asset("gone", taken: "2026-02-01T05:00:00Z")], epoch: index.epoch())
        let denied = StubServer.Response.immichError(400, message: "Not found or no asset.read access")
        server.route("GET", "assets/photo", .json(#"{"id":"photo","visibility":"timeline","exifInfo":{"city":"Lisbon"}}"#))
        server.route("GET", "faces", denied)
        server.route("GET", "assets/photo/ocr", denied)
        server.route("GET", "assets/gone", denied)
        let start = Date()
        _ = await DependentRepairer(index: index, fetcher: ServerDependentFetcher(client: api)).run(now: start)
        let repaired = try await index.asset(id: "photo")
        XCTAssertEqual(repaired?.exifInfo?.city, "Lisbon")
        let left = try await index.dueRepairs(limit: 10, now: start.addingTimeInterval(86_400))
        XCTAssertEqual(left, [])
        XCTAssertEqual(server.requests("GET", "assets/gone").count, 1)
    }

    /// A repair that fails waits and is tried again; one for a photo the server no longer has is
    /// dropped, and one that keeps failing is dropped after its attempts.
    func testFailedRepairsWaitAndGiveUp() async throws {
        let index = try makeIndex()
        _ = try await index.apply([Self.asset("gone", taken: "2026-02-01T05:00:00Z", visibility: "locked"),
                                   Self.asset("flaky", taken: "2026-02-01T05:00:00Z", visibility: "locked")], epoch: index.epoch())
        _ = try await index.apply([Self.asset("gone", taken: "2026-02-01T05:00:00Z"), Self.asset("flaky", taken: "2026-02-01T05:00:00Z")], epoch: index.epoch())
        let fetcher = FailingFetcher(failures: ["gone": ServerFailure.http(400, "Not found or no asset.read access"), "flaky": ServerFailure.http(502, nil)])
        let repairer = DependentRepairer(index: index, fetcher: fetcher, attempts: 2)
        let start = Date()
        _ = await repairer.run(now: start)
        let waiting = try await index.dueRepairs(limit: 10, now: start)
        let later = try await index.dueRepairs(limit: 10, now: start.addingTimeInterval(61))
        XCTAssertEqual(waiting, [], "The missing photo is dropped; the other waits.")
        XCTAssertEqual(later, ["flaky"])
        _ = await repairer.run(now: start.addingTimeInterval(61))
        let given = try await index.dueRepairs(limit: 10, now: start.addingTimeInterval(86_400))
        XCTAssertEqual(given, [], "Dropped after its second failure.")
        XCTAssertEqual(fetcher.calls, ["flaky": 2, "gone": 1])
    }

    // MARK: - Access

    /// Only photos that left the account are forgotten. A partner's photo in an album I own stays
    /// when the partner stops sharing; it goes once it leaves that album too. Someone else
    /// leaving a shared album changes nothing I see.
    func testAccessPurgeKeepsWhatTheAccountStillSees() async throws {
        let index = try makeIndex()
        _ = try await index.apply([
            SyncEvents.event("PartnerV1", #"{"sharedById":"bob","sharedWithId":"alice","inTimeline":true}"#, ack: "PartnerV1|bob"),
            Self.asset("bob-in-mine", owner: "bob", taken: "2026-02-01T05:00:00Z", type: "PartnerAssetV2"),
            Self.asset("bob-only", owner: "bob", taken: "2026-02-01T06:00:00Z", type: "PartnerAssetV2"),
            Self.asset("carol-shared", owner: "carol", taken: "2026-02-01T07:00:00Z", type: "AlbumAssetCreateV2"),
            SyncEvents.event("AlbumV2", #"{"id":"mine","ownerId":"alice","name":"Mine","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":null,"isActivityEnabled":true,"order":"desc"}"#, ack: "AlbumV2|mine"),
            SyncEvents.event("AlbumToAssetV1", #"{"albumId":"mine","assetId":"bob-in-mine"}"#, ack: "AlbumToAssetV1|1"),
            SyncEvents.event("AlbumV2", #"{"id":"carols","ownerId":"carol","name":"Carol's","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":null,"isActivityEnabled":true,"order":"desc"}"#, ack: "AlbumV2|carols"),
            SyncEvents.event("AlbumUserV1", #"{"albumId":"carols","userId":"alice","role":"viewer"}"#, ack: "AlbumUserV1|1"),
            SyncEvents.event("AlbumUserV1", #"{"albumId":"carols","userId":"dave","role":"viewer"}"#, ack: "AlbumUserV1|2"),
            SyncEvents.event("AlbumToAssetV1", #"{"albumId":"carols","assetId":"carol-shared"}"#, ack: "AlbumToAssetV1|2"),
            SyncEvents.complete(),
        ], epoch: index.epoch())

        let unshared = try await index.apply([SyncEvents.event("PartnerDeleteV1", #"{"sharedById":"bob","sharedWithId":"alice"}"#, ack: "PartnerDeleteV1|bob")], epoch: index.epoch())
        XCTAssertEqual(unshared.accessLost, ["bob-only"])
        let kept = try await index.asset(id: "bob-in-mine")
        XCTAssertNotNil(kept, "It is still in my own album.")

        let daveLeft = try await index.apply([SyncEvents.event("AlbumUserDeleteV1", #"{"albumId":"carols","userId":"dave"}"#, ack: "AlbumUserDeleteV1|dave")], epoch: index.epoch())
        XCTAssertTrue(daveLeft.accessLost.isEmpty)
        XCTAssertTrue(daveLeft.removed.isEmpty)

        let removed = try await index.apply([SyncEvents.event("AlbumToAssetDeleteV1", #"{"albumId":"mine","assetId":"bob-in-mine"}"#, ack: "AlbumToAssetDeleteV1|1")], epoch: index.epoch())
        XCTAssertEqual(removed.accessLost, ["bob-in-mine"])
        let purges = try await index.pendingMediaPurges()
        XCTAssertEqual(Set(purges.filter(\.revoked).map(\.assetID)), ["bob-only", "bob-in-mine"])
        let invalidated = try await index.takeAccessInvalidation()
        XCTAssertFalse(invalidated, "None of it empties every cache.")
    }

    /// Feeds read the index only once its derived tables hold everything; until then they come
    /// from the server.
    func testFeedsReadTheIndexOnlyOnceItIsQueryable() async throws {
        let index = try makeIndex()
        _ = try await index.apply([Self.asset("photo", taken: "2026-02-01T05:00:00Z")], epoch: index.epoch())
        let incomplete = try await index.isReadable()
        XCTAssertFalse(incomplete, "The first sync isn't done.")
        _ = try await index.apply([SyncEvents.complete()], epoch: index.epoch())
        let complete = try await index.isReadable()
        XCTAssertTrue(complete)
        try await index.writer.restartBackfill()
        let backfilling = try await index.isReadable()
        XCTAssertFalse(backfilling, "The backfill is redoing the derived tables.")
    }

    // MARK: - Budget

    /// Build 3040019: a person's timeline on a 60,000-photo library was slow. Its months and its
    /// newest month come from the derived tables within budget.
    func testPersonTimelineOnALargeLibraryStaysWithinBudget() async throws {
        let index = try Self.makeLargeLibrary(in: temporaryDirectory(), photos: 60_000)
        while try await index.writer.backfillStep() {}
        let readable = try await index.isReadable()
        XCTAssertTrue(readable)
        let clock = ContinuousClock()
        let person = LibraryQuery.person("maya")
        var months: [TimeBucket] = []
        let listing = try await clock.measure { months = try await index.timeBuckets(person) }
        var newest: [Asset] = []
        let loading = try await clock.measure { newest = try await index.timeBucket(months[0].timeBucket + "T00:00:00Z", of: person) }
        let library = try await clock.measure { _ = try await index.timeBuckets() }
        XCTAssertEqual(months.reduce(0) { $0 + $1.count }, 15_000)
        XCTAssertEqual(newest.count, months[0].count)
        print("PERSON TIMELINE 60,000 photos: months \(listing.formatted(.units(allowed: [.milliseconds]))), newest month \(loading.formatted(.units(allowed: [.milliseconds]))), library months \(library.formatted(.units(allowed: [.milliseconds])))")
        XCTAssertLessThan(listing + loading, .milliseconds(500), "A person's months and newest month load within budget.")
    }

    // MARK: - Support

    private func makeIndex() throws -> LibraryIndex {
        try LibraryIndex(scope: "server|alice", userID: "alice", directory: temporaryDirectory())
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IndexReadsTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    static func asset(_ id: String, owner: String = "alice", taken: String, created: String = "2026-03-01T00:00:00Z", fileCreated: String? = nil,
                      name: String? = nil, visibility: String = "timeline", trashed: Bool = false, favorite: Bool = false,
                      developed: Bool = false, stack: String? = nil, type: String = "AssetV2") -> EntitySyncEvent {
        SyncEvents.event(type, """
        {"id":"\(id)","ownerId":"\(owner)","type":"IMAGE","originalFileName":"\(name ?? id + ".jpg")","checksum":"AQIDBA==","fileCreatedAt":"\(fileCreated ?? taken)","localDateTime":"\(taken)","createdAt":"\(created)","visibility":"\(visibility)","isFavorite":\(favorite),"deletedAt":\(trashed ? "\"2026-03-04T00:00:00Z\"" : "null"),"stackId":\(stack.map { "\"\($0)\"" } ?? "null"),"isEdited":false,"isDeveloped":\(developed),"mediaRevision":"r1"}
        """, ack: "\(type)|\(id)")
    }

    static func face(_ id: String, asset: String, person: String = "maya", visible: Bool = true, deleted: Bool = false) -> EntitySyncEvent {
        SyncEvents.event("AssetFaceV3", """
        {"id":"\(id)","assetId":"\(asset)","personId":"\(person)","imageWidth":100,"imageHeight":100,"boundingBoxX1":0,"boundingBoxY1":0,"boundingBoxX2":10,"boundingBoxY2":10,"sourceType":"machine-learning","deletedAt":\(deleted ? "\"2026-03-04T00:00:00Z\"" : "null"),"isVisible":\(visible)}
        """, ack: "AssetFaceV3|\(id)")
    }

    /// A library of 400 photos over four months, with many ties in day, creation time and file
    /// name, of three owners (Alice, her partner Bob, and Carol, who shares an album), in every
    /// visibility, some trashed, favorite, developed or stacked, with faces of Maya.
    private static func makeLibrary() -> ReferenceLibrary {
        var random = SeededRandom(seed: 7)
        var library = ReferenceLibrary()
        var events: [EntitySyncEvent] = [
            SyncEvents.event("PartnerV1", #"{"sharedById":"bob","sharedWithId":"alice","inTimeline":true}"#, ack: "PartnerV1|bob"),
            SyncEvents.event("PersonV1", #"{"id":"maya","name":"Maya","isHidden":false}"#, ack: "PersonV1|maya"),
            SyncEvents.event("AlbumV2", #"{"id":"shared","ownerId":"carol","name":"Shared","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":null,"isActivityEnabled":true,"order":"desc"}"#, ack: "AlbumV2|shared"),
            SyncEvents.event("AlbumUserV1", #"{"albumId":"shared","userId":"alice","role":"viewer"}"#, ack: "AlbumUserV1|shared"),
            SyncEvents.event("AlbumV2", #"{"id":"mine","ownerId":"alice","name":"Mine","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":null,"isActivityEnabled":true,"order":"desc"}"#, ack: "AlbumV2|mine"),
        ]
        for number in 0..<400 {
            let id = String(format: "p%03d", number)
            let roll = random.next(100)
            let owner = roll < 70 ? "alice" : roll < 85 ? "bob" : "carol"
            let month = 1 + random.next(4), day = 1 + random.next(5), hour = 10 + random.next(3)
            let taken = String(format: "2025-%02d-%02dT%02d:00:00Z", month, day, hour)
            let fileCreated = random.next(2) == 0 ? taken : String(format: "2025-%02d-%02dT%02d:00:00Z", month, day, random.next(3))
            let name = "IMG_\(random.next(6)).jpg"
            let created = String(format: "2025-%02d-15T%02d:00:00Z", 1 + random.next(4), random.next(2))
            let visibilityRoll = random.next(100)
            let visibility = visibilityRoll < 80 ? "timeline" : visibilityRoll < 90 ? "archive" : visibilityRoll < 95 ? "hidden" : "locked"
            let trashed = random.next(20) == 0, favorite = random.next(5) == 0, developed = random.next(4) == 0
            var stack: String?
            if number % 37 == 0 { stack = "s\(number)" } else if number % 37 == 1, number > 1 { stack = "s\(number - 1)" }
            let type = owner == "alice" ? "AssetV2" : owner == "bob" ? "PartnerAssetV2" : "AlbumAssetCreateV2"
            events.append(asset(id, owner: owner, taken: taken, created: created, fileCreated: fileCreated, name: name, visibility: visibility,
                                trashed: trashed, favorite: favorite, developed: developed, stack: stack, type: type))
            // The server never sends what Alice can't see, and the index keeps nothing locked.
            guard visibility != "locked" else { continue }
            library.assets[id] = .init(id: id, owner: owner, taken: taken, fileCreated: fileCreated, name: name, created: created,
                                       visibility: visibility, trashed: trashed, favorite: favorite, developed: developed, stack: stack)
            if owner == "carol" || (owner == "alice" && number % 9 == 0) {
                events.append(SyncEvents.event("AlbumToAssetV1", #"{"albumId":"shared","assetId":"\#(id)"}"#, ack: "AlbumToAssetV1|s\(id)"))
                library.albums["shared", default: []].insert(id)
            }
            if owner == "bob", number % 3 == 0 {
                events.append(SyncEvents.event("AlbumToAssetV1", #"{"albumId":"mine","assetId":"\#(id)"}"#, ack: "AlbumToAssetV1|m\(id)"))
                library.albums["mine", default: []].insert(id)
            }
            if number % 5 == 0 {
                let visible = number % 15 != 0, deleted = number % 25 == 0
                events.append(face("face-\(id)", asset: id, visible: visible, deleted: deleted))
                if visible && !deleted { library.maya.insert(id) }
            }
            if number % 7 == 0 { library.place.append(id) }
        }
        for number in stride(from: 0, to: 400, by: 37) where library.assets[String(format: "p%03d", number)] != nil {
            let primary = String(format: "p%03d", number)
            events.append(SyncEvents.event("StackV1", #"{"id":"s\#(number)","ownerId":"alice","primaryAssetId":"\#(primary)","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#, ack: "StackV1|s\(number)"))
            library.stacks["s\(number)"] = primary
        }
        library.events = events
        return library
    }

    /// A library of `photos` photos, every fourth one with a face of Maya, written as a build
    /// before Q2 left it and then filled by the backfill, as on the owner's phone.
    private static func makeLargeLibrary(in root: URL, photos: Int) throws -> LibraryIndex {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scope = "server|large"
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let connection = try SQLiteConnection(path: root.appendingPathComponent(name + ".sqlite").path, readOnly: false, busyTimeout: 5_000)
        try connection.execute("PRAGMA journal_mode=WAL")
        for statement in LibraryIndexSchema.base { try connection.execute(statement) }
        try connection.transaction {
            let photo = "printf('photo-%05d',i)"
            let taken = "strftime('%Y-%m-%dT%H:%M:%SZ','2016-01-01',printf('+%d minutes',i*90))"
            try connection.execute("""
            WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<\(photos - 1))
            INSERT INTO entities(kind,id,payload) SELECT 'asset',\(photo),json_object('id',\(photo),'ownerId','alice','type','IMAGE',
              'originalFileName',printf('IMG_%05d.HEIC',i),'checksum','AQIDBA==','width',4032,'height',3024,'fileCreatedAt',\(taken),
              'localDateTime',\(taken),'createdAt',\(taken),'visibility','timeline','isFavorite',json('false'),'deletedAt',NULL,'stackId',NULL,
              'isEdited',json('false'),'isDeveloped',json('false'),'mediaRevision','r1','thumbhash','HIcNXIyGh4d/eHh5eIWHcEf3dQ==') FROM n
            """)
            try connection.execute("""
            WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<\(photos - 1))
            INSERT INTO entities(kind,id,payload) SELECT 'exif',\(photo),json_object('assetId',\(photo),'city','Lisbon','country','Portugal','make','Apple') FROM n
            """)
            try connection.execute("""
            WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+4 FROM n WHERE i+4<\(photos))
            INSERT INTO entities(kind,id,payload) SELECT 'face',printf('face-%05d',i),json_object('id',printf('face-%05d',i),'assetId',\(photo),
              'personId','maya','isVisible',json('true'),'deletedAt',NULL) FROM n
            """)
            try connection.execute("INSERT INTO entities(kind,id,payload) VALUES('person','maya','{\"id\":\"maya\",\"name\":\"Maya\"}')")
            try connection.execute("INSERT INTO metadata(key,value) VALUES('session','session'),('needsReset','0'),('complete','1'),('completedAt','2026-10-20T10:00:00Z')")
        }
        connection.close()
        let index = try LibraryIndex(scope: scope, userID: "alice", directory: root, backfillBatchSize: 20_000)
        return index
    }
}

/// The server's rules for a timeline (AssetRepository.getTimeBuckets and getTimeBucket, with the
/// app's owner and partner scope), applied to the records a library was synced from, with each
/// month in the library's order: the time, then the ID.
private struct ReferenceLibrary {
    struct Photo {
        let id, owner, taken, fileCreated, name, created, visibility: String
        let trashed, favorite, developed: Bool
        let stack: String?
    }
    var events: [EntitySyncEvent] = []
    var assets: [String: Photo] = [:]
    var albums: [String: Set<String>] = [:]
    var maya = Set<String>()
    var place: [String] = []
    /// Stack to its primary photo.
    var stacks: [String: String] = [:]
    let me = "alice"

    func server(_ filter: IndexFeedRequest) -> [(month: String, ids: [String])] {
        let createdOrder = filter.byCreated
        let shown = assets.values.filter { included($0, filter) }
        let byMonth = Dictionary(grouping: shown) { String((createdOrder ? $0.created : $0.taken).prefix(7)) + "-01" }
        let descending = !filter.ascending
        return byMonth.keys.sorted(by: descending ? (>) : (<)).map { month in
            // Within a month the library's order, not the server's: the time, then the ID, ascending.
            let ids = byMonth[month]!.sorted { a, b in
                let left = createdOrder ? a.created : a.taken, right = createdOrder ? b.created : b.taken
                if left == right { return a.id < b.id }
                return descending ? left > right : left < right
            }.map(\.id)
            return (month, ids)
        }
    }

    func stackCount(_ id: String) -> Int {
        assets.values.count { $0.stack == id && !$0.trashed && $0.visibility == "timeline" }
    }

    private func included(_ photo: Photo, _ filter: IndexFeedRequest) -> Bool {
        if let visibility = filter.visibility { guard photo.visibility == visibility else { return false } }
        else { guard ["timeline", "archive"].contains(photo.visibility) else { return false } }
        guard photo.trashed == filter.trashed else { return false }
        if let favorite = filter.favorite, photo.favorite != favorite { return false }
        if let developed = filter.developed, photo.developed != developed { return false }
        if let album = filter.albumID, albums[album]?.contains(photo.id) != true { return false }
        if let person = filter.personID, person != "maya" || !maya.contains(photo.id) { return false }
        if let place = filter.placeAssetIDs, !place.contains(photo.id) { return false }
        if (filter.albumID == nil && filter.placeAssetIDs == nil) || filter.ownerID != nil {
            let owner = photo.owner == (filter.ownerID ?? me)
            // Bob shares with Alice and shows in her timeline; Carol only shares an album.
            let partner = filter.withPartners && photo.owner == "bob"
            let sharedAlbum = filter.personID != nil && albums["shared"]?.contains(photo.id) == true
            guard owner || partner || sharedAlbum else { return false }
        }
        if filter.primaryOnly, let stack = photo.stack, let primary = stacks[stack], primary != photo.id { return false }
        return true
    }
}

/// The same numbers every run.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

/// Fails each asset's repair as told, counting the calls.
private final class StaticFetcher: DependentFetching {
    private let events: [String: [EntitySyncEvent]]
    private let during: (@Sendable () async -> Void)?
    init(_ events: [String: [EntitySyncEvent]], during: (@Sendable () async -> Void)? = nil) { self.events = events; self.during = during }
    func dependents(of assetID: String) async throws -> [EntitySyncEvent] {
        await during?()
        return events[assetID] ?? []
    }
}

private final class FailingFetcher: DependentFetching {
    private let state: Mutex<[String: Int]> = Mutex([:])
    private let failures: [String: ServerFailure]
    init(failures: [String: ServerFailure]) { self.failures = failures }
    var calls: [String: Int] { state.withLock { $0 } }
    func dependents(of assetID: String) async throws -> [EntitySyncEvent] {
        state.withLock { $0[assetID, default: 0] += 1 }
        if let failure = failures[assetID] { throw failure }
        return []
    }
}

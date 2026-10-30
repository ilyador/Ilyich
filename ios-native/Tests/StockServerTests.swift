import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// A2: the app on a stock server, whose answers lack what the owner's fork adds (media revisions,
/// developed photos, search verification and cursors, face images and the editor's base size).
/// The payloads are stock 3.3.5's own, trimmed.
@MainActor final class StockServerTests: XCTestCase {
    /// GET server/features from stock 3.3.5, which never names searchVerification.
    static let stockFeatures = #"{"smartSearch":true,"facialRecognition":true,"duplicateDetection":true,"map":true,"reverseGeocoding":true,"importFaces":false,"sidecar":true,"search":true,"trash":true,"oauth":false,"oauthAutoLaunch":false,"ocr":true,"passwordLogin":true,"configFile":false,"email":false,"realtimeTranscoding":false}"#
    /// The fork's, with search verification set up.
    static let forkFeatures = stockFeatures.replacingOccurrences(of: #""smartSearch":true"#, with: #""smartSearch":true,"searchVerification":true"#)
    /// GET assets/<id> from stock 3.3.5.
    static let stockAsset = #"{"id":"5a7c8ef6-891e-474a-9dff-89aaf6a02307","createdAt":"2026-10-30T19:03:23.897Z","ownerId":"64bb4c5b-6553-46a2-93fc-5ab979c4d345","libraryId":null,"type":"IMAGE","originalFileName":"obama-1.jpg","originalMimeType":"image/jpeg","thumbhash":"1igOFYB4d1V/dYh5eFiHiXifvKf0","fileCreatedAt":"2011-07-22T05:16:50.850Z","fileModifiedAt":"2011-07-22T17:16:50.000Z","localDateTime":"2011-07-22T17:16:50.850Z","updatedAt":"2026-10-30T19:03:24.581Z","isFavorite":false,"isArchived":false,"isTrashed":false,"visibility":"timeline","duration":null,"livePhotoVideoId":null,"tags":[],"checksum":"b+YbyhIMxgKtDBjWVKJXh1btVfs=","stack":null,"isOffline":false,"hasMetadata":true,"duplicateId":null,"resized":true,"width":1920,"height":1273,"isEdited":false,"exifInfo":{"exifImageWidth":1920,"exifImageHeight":1273,"orientation":"1"}}"#

    private func features(_ json: String) throws -> ServerFeatures { try APIJSON.decoder().decode(ServerFeatures.self, from: Data(json.utf8)) }

    /// The fork is told by what it has and stock lacks: its features name searchVerification,
    /// even when verification isn't set up.
    func testFeaturesTellTheForkFromAStockRelease() throws {
        let stock = try features(Self.stockFeatures)
        XCTAssertFalse(stock.isFork)
        XCTAssertNil(stock.searchVerification)
        XCTAssertTrue(try features(Self.forkFeatures).isFork)
        let unconfigured = try features(Self.stockFeatures.replacingOccurrences(of: #""ocr":true"#, with: #""ocr":true,"searchVerification":false"#))
        XCTAssertTrue(unconfigured.isFork, "A fork without verification set up is still the fork.")
    }

    /// A stock record carries isEdited alone: it knows its edit state, since stock develops
    /// nothing, so it can be edited and its original can stand in offline. Its media are versioned
    /// by thumbhash. A fork record from before isDeveloped, with a media revision, still doesn't.
    func testAStockAssetKnowsItsEditStateAndIsVersionedByThumbhash() throws {
        let asset = try APIJSON.decoder().decode(Asset.self, from: Data(Self.stockAsset.utf8))
        XCTAssertTrue(asset.hasKnownEditState)
        XCTAssertFalse(asset.isDeveloped)
        XCTAssertNil(asset.mediaRevision)
        XCTAssertEqual(asset.cacheRevision, "1igOFYB4d1V/dYh5eFiHiXifvKf0")
        var owned = asset
        owned.ownerId = "me"
        let context = CapabilityContext(viewerID: "me", writable: true, features: try features(Self.stockFeatures), album: nil)
        XCTAssertEqual(AssetCapabilityPolicy.evaluate(owned, context: context)[.edit], .offered, "Stock photos can be edited.")
        XCTAssertEqual(AssetCapabilityPolicy.evaluate(owned, context: context)[.findSimilar], .offered)

        let forkBeforeDevelopment = #"{"id":"photo","type":"IMAGE","isEdited":false,"mediaRevision":"r1"}"#
        XCTAssertFalse(try APIJSON.decoder().decode(Asset.self, from: Data(forkBeforeDevelopment.utf8)).hasKnownEditState)
        let timelineRow = #"{"id":"photo","type":"IMAGE","thumbhash":"abc"}"#
        XCTAssertFalse(try APIJSON.decoder().decode(Asset.self, from: Data(timelineRow.utf8)).hasKnownEditState,
                       "A record without isEdited still says nothing.")
    }

    /// Stock's timeline columns have no media revisions: each row is versioned by its thumbhash.
    func testAStockTimelineMonthIsVersionedByThumbhash() throws {
        let month = #"{"duration":[null],"id":["5a7c8ef6-891e-474a-9dff-89aaf6a02307"],"visibility":["timeline"],"isFavorite":[false],"isImage":[true],"isTrashed":[false],"livePhotoVideoId":[null],"fileCreatedAt":["2011-07-22T05:16:50.85"],"localOffsetHours":[12],"createdAt":["2026-10-30T19:03:23.897026"],"ownerId":["64bb4c5b-6553-46a2-93fc-5ab979c4d345"],"projectionType":[null],"ratio":[1.508],"status":["active"],"thumbhash":["1igOFYB4d1V/dYh5eFiHiXifvKf0"],"city":["Wellington"],"country":["New Zealand"],"stack":[null]}"#
        let assets = try APIJSON.decoder().decode(TimeBucketPayload.self, from: Data(month.utf8)).assets()
        XCTAssertEqual(assets.map(\.cacheRevision), ["1igOFYB4d1V/dYh5eFiHiXifvKf0"])
        XCTAssertEqual(assets.first?.localDateTime, APIDate.parse("2011-07-22T17:16:50.850Z"))
    }

    /// Stock's sync records version media by thumbhash, which an edit's new previews change: the
    /// index names the new revision, as it does a fork's media revision, so the photo's old
    /// thumbnails go. A change that leaves the thumbhash names none.
    func testAStockThumbhashChangeIsAMediaRevisionChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StockServerTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let index = try LibraryIndex(scope: "server|alice", userID: "alice", directory: root)
        let epoch = await index.epoch()
        func record(thumbhash: String, favorite: Bool = false) -> EntitySyncEvent {
            SyncEvents.event("AssetV2", """
            {"id":"photo","ownerId":"alice","originalFileName":"obama-1.jpg","fileCreatedAt":"2011-07-22T05:16:50.850Z","fileModifiedAt":"2011-07-22T17:16:50.000Z","createdAt":"2026-10-30T19:03:23.897Z","localDateTime":"2011-07-22T17:16:50.850Z","type":"IMAGE","deletedAt":null,"isFavorite":\(favorite),"visibility":"timeline","duration":null,"livePhotoVideoId":null,"stackId":null,"libraryId":null,"width":1920,"height":1273,"isEdited":false,"checksum":"b+YbyhIMxgKtDBjWVKJXh1btVfs=","thumbhash":"\(thumbhash)"}
            """, ack: "AssetV2|photo-\(thumbhash)-\(favorite)")
        }
        _ = try await index.apply([record(thumbhash: "before")], epoch: epoch)
        var change = try await index.apply([record(thumbhash: "before", favorite: true)], epoch: epoch)
        XCTAssertTrue(change.mediaRevisions.isEmpty, "A favorite leaves the photo's media.")
        change = try await index.apply([record(thumbhash: "after", favorite: true)], epoch: epoch)
        XCTAssertEqual(change.mediaRevisions, ["photo": "after"])
        let held = try await index.asset(id: "photo")
        XCTAssertEqual(held?.cacheRevision, "after")
        XCTAssertEqual(held?.hasKnownEditState, true)
    }

    /// Stock's smart search pages none (it answers `size` results and no cursor) and checks
    /// nothing: the library asks it once for 100, without a cursor or verify. The fork's smart
    /// search pages 10 at a time with the AI check's answer. Features that can't be read leave the
    /// fork's request.
    func testAStockServerIsAskedForOneLongerSmartSearchPage() async throws {
        let empty = #"{"albums":{"total":0,"count":0,"items":[],"facets":[]},"assets":{"total":0,"count":0,"items":[],"facets":[],"nextPage":null,"nextCursor":null}}"#
        for (name, featuresAnswer, size, verify) in [("stock", StubServer.Response.json(Self.stockFeatures), 100, nil as Bool?),
                                                       ("fork", .json(Self.forkFeatures), 10, false),
                                                       ("unknown", .immichError(500, message: "Down"), 10, false)] {
            let server = makeStubServer()
            server.route("GET", "server/features", featuresAnswer)
            server.route("POST", "search/smart", .json(empty))
            let api = try APIClient(baseURL: server.baseURL, accessToken: "stock-session", userID: "alice", sessionConfiguration: server.configuration(),
                                    networkConfiguration: NetworkConfiguration())
            addTeardownBlock { await api.shutdown() }
            let repository = LibraryRepository(client: api, index: nil, sync: nil)
            let request = try ServerSearchRequest(LibraryFeedStore.librarySearch.refined(text: "beach", mode: .context), userID: "alice", checksContent: false)
            let response = try await repository.smart(request, cursor: name == "stock" ? nil : "page-2")
            XCTAssertFalse(response.assets.hasMore, name)
            XCTAssertNil(response.verification, name)
            let body = try XCTUnwrap(server.requests("POST", "search/smart").first?.body, name)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any], name)
            XCTAssertEqual(json["size"] as? Int, size, name)
            XCTAssertEqual(json["verify"] as? Bool, verify, name)
            XCTAssertEqual(json["cursor"] as? String, name == "stock" ? nil : "page-2", name)
            XCTAssertEqual(json["query"] as? String, "beach", name)
        }
    }

    /// The shelves and Browse more offer Lightroom only on the fork: stock develops nothing, and
    /// it would drop the timeline's isDeveloped and show every photo. Unknown features hide it too.
    func testLightroomIsOfferedOnlyOnTheFork() throws {
        var catalog = ShelfCatalog()
        XCTAssertFalse(catalog.rows(.more).contains { $0.id == "lightroom" }, "Until the server is known, Lightroom waits.")
        catalog.features = try features(Self.stockFeatures)
        XCTAssertFalse(catalog.rows(.more).contains { $0.id == "lightroom" })
        XCTAssertTrue(catalog.rows(.more).contains { $0.id == "trash" })
        catalog.features = try features(Self.forkFeatures)
        XCTAssertTrue(catalog.rows(.more).contains { $0.id == "lightroom" })
    }

    /// Stock publishes no base size for edits: the editor measures the original as stock checks a
    /// crop, by its EXIF size turned by its orientation. The fork's published size wins, and a
    /// developed photo without one can't be edited yet.
    func testTheEditorMeasuresAStockOriginalAsStockDoes() throws {
        let stockEdits = try APIJSON.decoder().decode(AssetEdits.self, from: Data(#"{"assetId":"photo","edits":[]}"#.utf8))
        var asset = try APIJSON.decoder().decode(Asset.self, from: Data(Self.stockAsset.utf8))
        XCTAssertEqual(try stockEdits.base(of: asset), PixelDimensions(width: 1920, height: 1273))
        asset.exifInfo = try APIJSON.decoder().decode(ExifInfo.self, from: Data(#"{"exifImageWidth":4032,"exifImageHeight":3024,"orientation":"6"}"#.utf8))
        asset.width = 2000; asset.height = 1000
        XCTAssertEqual(try stockEdits.base(of: asset), PixelDimensions(width: 3024, height: 4032),
                       "Turned a quarter, from the EXIF size; a crop already saved has changed the record's own size.")
        let published = try APIJSON.decoder().decode(AssetEdits.self, from: Data(#"{"assetId":"photo","edits":[],"baseDimensions":{"width":10,"height":20}}"#.utf8))
        XCTAssertEqual(try published.base(of: asset), PixelDimensions(width: 10, height: 20))
        asset.isDeveloped = true
        XCTAssertThrowsError(try stockEdits.base(of: asset))
    }

    // MARK: Minimum version

    /// 3.3.0 is the oldest release with every sync type the app asks for; its release candidates
    /// lacked the memories. A release comes after its candidates, and a server too old to name a
    /// prerelease is read as a release.
    func testTheOldestSupportedReleaseIs330() throws {
        XCTAssertEqual(ServerVersion.minimum, ServerVersion(major: 3, minor: 3, patch: 0))
        let stock = try APIJSON.decoder().decode(ServerVersion.self, from: Data(#"{"major":3,"minor":3,"patch":5,"prerelease":null}"#.utf8))
        XCTAssertTrue(stock.isSupported)
        XCTAssertTrue(try APIJSON.decoder().decode(ServerVersion.self, from: Data(#"{"major":3,"minor":3,"patch":0}"#.utf8)).isSupported)
        XCTAssertTrue(ServerVersion(major: 4, minor: 0, patch: 0).isSupported)
        XCTAssertTrue(ServerVersion(major: 3, minor: 3, patch: 1, prerelease: 0).isSupported)
        for older in [ServerVersion(major: 3, minor: 2, patch: 4), ServerVersion(major: 3, minor: 3, patch: 0, prerelease: 2),
                      ServerVersion(major: 2, minor: 9, patch: 9), ServerVersion(major: 1, minor: 140, patch: 0)] {
            XCTAssertFalse(older.isSupported, older.name)
        }
        XCTAssertLessThan(ServerVersion(major: 3, minor: 3, patch: 0, prerelease: 1), ServerVersion(major: 3, minor: 3, patch: 0, prerelease: 2))
        XCTAssertLessThan(ServerVersion(major: 3, minor: 3, patch: 0, prerelease: 2), ServerVersion(major: 3, minor: 3, patch: 0))
    }

    /// The refusal is plain, names the release needed and what the server runs, and never names
    /// Immich, which only the App Store description does.
    func testTheRefusalNamesTheReleaseNeeded() {
        let messages = [UnsupportedServer(version: ServerVersion(major: 3, minor: 2, patch: 4)),
                        UnsupportedServer(version: ServerVersion(major: 3, minor: 3, patch: 0, prerelease: 1)),
                        UnsupportedServer(version: nil)].map(\.localizedDescription)
        XCTAssertEqual(messages, ["This server runs version 3.2.4. Ilyich needs version 3.3.0 or later.",
                                  "This server runs a prerelease of version 3.3.0. Ilyich needs version 3.3.0 or later.",
                                  "This server is too old for Ilyich, which needs version 3.3.0 or later."])
        XCTAssertFalse(messages.contains { $0.localizedCaseInsensitiveContains("immich") })
    }

    /// A stock search page has no verification and, for smart search, no continuation.
    func testAStockSearchPageHasNoVerificationOrMore() throws {
        let page = #"{"albums":{"total":0,"count":0,"items":[],"facets":[]},"assets":{"total":1,"count":1,"items":[\#(Self.stockAsset)],"facets":[],"nextPage":null,"nextCursor":null}}"#
        let response = try APIJSON.decoder().decode(SearchResponse.self, from: Data(page.utf8))
        XCTAssertNil(response.verification)
        XCTAssertFalse(response.assets.hasMore)
        XCTAssertEqual(response.assets.items.first?.hasKnownEditState, true)
    }
}

import Foundation
import XCTest
@testable import Ilyich

@MainActor
final class CoreTests: XCTestCase {
    func testStructuredSearchPreservesNaturalLanguageAndUsesCursorContract() throws {
        var query = SearchQuery(query: "me wearing a red hat in Amsterdam")
        query.cursor = "server-owned-next-token"
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: APIJSON.encoder().encode(query)) as? [String: Any])
        XCTAssertEqual(object["query"] as? String, "me wearing a red hat in Amsterdam")
        XCTAssertEqual(object["cursor"] as? String, "server-owned-next-token")
        XCTAssertNotNil(object["filter"] as? [String: Any])
        XCTAssertNil(object["page"])
        XCTAssertNil(object["verify"], "Automatic verification belongs to the server; do not opt out implicitly.")
    }

    func testOCRUsesStructuredPredicateAndShortVerifiedPageRetainsNextCursor() throws {
        var query = MetadataQuery()
        query.filter.ocr = OCRFilter(matches: "binance")
        query.filter.isFavorite = BoolFilter(eq: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: APIJSON.encoder().encode(query)) as? [String: Any])
        let filter = try XCTUnwrap(object["filter"] as? [String: Any])
        XCTAssertEqual((filter["ocr"] as? [String: String])?["matches"], "binance")
        XCTAssertEqual((filter["isFavorite"] as? [String: Bool])?["eq"], true)
        let data = Data(#"{"assets":{"items":[],"count":0,"total":0,"nextCursor":"still-more","nextPage":null},"verification":{"status":"partial","checked":8,"rejected":8}}"#.utf8)
        let response = try APIJSON.decoder().decode(SearchResponse.self, from: data)
        XCTAssertTrue(response.assets.hasMore)
        XCTAssertEqual(response.assets.nextCursor, "still-more")
        XCTAssertTrue(try XCTUnwrap(response.verification).canRetry)
    }

    func testTimelineColumnRowsKeepCaptureZoneAndRevisionAndRejectMismatches() throws {
        let valid = #"{"id":["photo"],"ownerId":["owner"],"ratio":[1.5],"isFavorite":[true],"isTrashed":[false],"isImage":[true],"visibility":["timeline"],"fileCreatedAt":["2026-01-31T23:30:00"],"createdAt":["2026-02-03T10:00:00.000"],"localOffsetHours":[5.5],"duration":[null],"thumbhash":[null],"mediaRevision":["edited-2"],"livePhotoVideoId":[null]}"#
        let assets = try APIJSON.decoder().decode(TimeBucketPayload.self, from: Data(valid.utf8)).assets()
        let asset = try XCTUnwrap(assets.first)
        XCTAssertEqual(asset.fileCreatedAt, APIDate.parse("2026-01-31T23:30:00Z"))
        XCTAssertEqual(asset.localDateTime, APIDate.parse("2026-02-01T05:00:00Z"))
        XCTAssertEqual(asset.cacheRevision, "edited-2")
        XCTAssertEqual(asset.aspectRatio, 1.5)
        let malformed = valid.replacingOccurrences(of: #""ratio":[1.5]"#, with: #""ratio":[]"#)
        XCTAssertThrowsError(try APIJSON.decoder().decode(TimeBucketPayload.self, from: Data(malformed.utf8)).assets())
    }

    func testMediaCacheDoesNotCrossAccountRevisionOrDecodeSize() {
        var asset = Asset(id: "photo", isDeveloped: true, mediaRevision: "one")
        let base = MediaCacheIdentity(scope: "server|alice", asset: asset, size: .preview, pixelSize: 1200)
        XCTAssertNotEqual(base, MediaCacheIdentity(scope: "server|bob", asset: asset, size: .preview, pixelSize: 1200))
        XCTAssertNotEqual(base, MediaCacheIdentity(scope: "other-server|alice", asset: asset, size: .preview, pixelSize: 1200))
        XCTAssertNotEqual(base, MediaCacheIdentity(scope: "server|alice", asset: asset, size: .fullsize, pixelSize: 1200))
        XCTAssertNotEqual(base, MediaCacheIdentity(scope: "server|alice", asset: asset, size: .preview, pixelSize: 300))
        asset.mediaRevision = "two"
        XCTAssertNotEqual(base, MediaCacheIdentity(scope: "server|alice", asset: asset, size: .preview, pixelSize: 1200))
    }

    func testBaseURLNormalizationPreservesProxyPrefixWithoutDoubleAPI() throws {
        XCTAssertEqual(try APIClient.normalizedBaseURL(URL(string: "https://photos.example/prefix/")!).absoluteString, "https://photos.example/prefix/api")
        XCTAssertEqual(try APIClient.normalizedBaseURL(URL(string: "https://photos.example/prefix/api/")!).absoluteString, "https://photos.example/prefix/api")
        for value in ["file:///photos", "https://user:secret@photos.example", "https://photos.example?token=secret", "https://photos.example/#photos"] {
            XCTAssertThrowsError(try APIClient.normalizedBaseURL(URL(string: value)!))
        }
        XCTAssertFalse(SameOriginRedirectDelegate.sameOrigin(URL(string: "https://photos.example")!, URL(string: "http://photos.example")!))
        XCTAssertFalse(SameOriginRedirectDelegate.sameOrigin(URL(string: "https://photos.example")!, URL(string: "https://other.example")!))
        XCTAssertTrue(SameOriginRedirectDelegate.sameOrigin(URL(string: "https://photos.example")!, URL(string: "https://photos.example:443/api")!))
    }

    func testOpaqueSessionTokenStaysInAuthorizationHeaderAndErrorsStayDistinct() async throws {
        let client = try APIClient(baseURL: URL(string: "https://photos.example")!, accessToken: "opaque.not-a-jwt", userID: "alice")
        let request = try await client.authorizedRequest(path: "assets/photo/thumbnail", query: [.init(name: "c", value: "revision+with/slash")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer opaque.not-a-jwt")
        XCTAssertFalse(try XCTUnwrap(request.url).absoluteString.contains("opaque.not-a-jwt"))
        XCTAssertTrue(try XCTUnwrap(request.url).absoluteString.contains("revision%2Bwith"))
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try APIClient.validate(response)) { error in
            guard case APIError.forbidden = error else { return XCTFail("Permission failures must not be converted into logout.") }
        }
    }

    func testAssetDecodeKeepsLightcraftDistinctFromImmichEdits() throws {
        let data = Data(#"{"id":"photo","type":"IMAGE","isEdited":false,"isDeveloped":true,"mediaRevision":"xmp-7","duration":null,"width":6000,"height":4000,"originalFileName":"DSC_0632.NEF","fileCreatedAt":"2024-10-19T13:48:55.000Z"}"#.utf8)
        let asset = try APIJSON.decoder().decode(Asset.self, from: data)
        XCTAssertTrue(asset.isDeveloped)
        XCTAssertFalse(asset.isEdited)
        XCTAssertEqual(asset.aspectRatio, 1.5)
        XCTAssertEqual(asset.cacheRevision, "xmp-7")
    }
}

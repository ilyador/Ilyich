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
        XCTAssertFalse(asset.hasKnownEditState)
        let restored = try APIJSON.decoder().decode(Asset.self, from: APIJSON.encoder().encode(asset))
        XCTAssertFalse(restored.hasKnownEditState, "Caching a timeline summary must not invent edit metadata.")
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
        asset.visibility = .locked
        XCTAssertNotEqual(base, MediaCacheIdentity(scope: "server|alice", asset: asset, size: .preview, pixelSize: 1200))
        asset.visibility = .timeline
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
        let client = try APIClient(baseURL: URL(string: "https://photos.example")!, accessToken: "opaque.not-a-jwt", userID: "alice", networkConfiguration: .init())
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
        XCTAssertTrue(asset.hasKnownEditState)
        XCTAssertFalse(asset.isEdited)
        XCTAssertEqual(asset.aspectRatio, 1.5)
        XCTAssertEqual(asset.cacheRevision, "xmp-7")
    }

    func testEditorUsesPublishedDevelopedDimensionsAndClampsRoundedEdges() throws {
        let edits = try APIJSON.decoder().decode(AssetEdits.self, from: Data(#"{"assetId":"photo","edits":[],"baseDimensions":{"width":4103,"height":2701}}"#.utf8))
        let base = try XCTUnwrap(edits.baseDimensions)
        let crop = try PixelCrop.normalized(x: 0.3333333, y: 0.2, width: 0.6666667, height: 0.8, in: base)
        XCTAssertEqual(crop.x + crop.width, base.width)
        XCTAssertEqual(crop.y + crop.height, base.height)
        XCTAssertEqual(crop.x, 1367)
        XCTAssertThrowsError(try PixelCrop.normalized(x: .nan, y: 0, width: 1, height: 1, in: base))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: APIJSON.encoder().encode(EditSubmission(edits: [.crop(crop), .rotate(90)]))) as? [String: Any])
        let items = try XCTUnwrap(encoded["edits"] as? [[String: Any]])
        XCTAssertEqual(items.first?["action"] as? String, "crop")
        XCTAssertEqual((items.first?["parameters"] as? [String: Int])?["width"], 2736)
    }

    func testEditTransformPreservesExistingOrderAndHasNoDuplicateActions() throws {
        for angle in [0, 90, 180, 270] {
            for axis in [MirrorAxis.horizontal, .vertical] {
                for edits: [PhotoEdit] in [[.mirror(axis), .rotate(angle)], [.rotate(angle), .mirror(axis)]] {
                    let transform = PhotoTransform(edits: edits)
                    XCTAssertEqual(PhotoTransform(edits: transform.edits), transform)
                    let decoded = try APIJSON.decoder().decode([PhotoEdit].self, from: APIJSON.encoder().encode(transform.edits))
                    XCTAssertEqual(PhotoTransform(edits: decoded), transform)
                    XCTAssertTrue(decoded.count <= 2)
                }
            }
        }
        XCTAssertEqual(PhotoTransform(edits: [.mirror(.vertical), .rotate(90)]), PhotoTransform(a: 0, b: -1, c: -1, d: 0))
        XCTAssertEqual(PhotoTransform(edits: [.rotate(90), .rotate(90), .rotate(90), .rotate(90)]), PhotoTransform())
    }

    func testVideoContentRangeRejectsMalformedOrUnsatisfiedRanges() throws {
        let range = try XCTUnwrap(HTTPContentRange("bytes 4096-8191/200000"))
        XCTAssertEqual(range.start, 4096)
        XCTAssertEqual(range.end, 8191)
        XCTAssertEqual(range.total, 200000)
        for header in ["bytes */200000", "bytes 0-10/10", "bytes 10-0/20", "bytes -1-2/20", "items 0-1/2", "bytes 0-1/*", "bytes 0-1/2/3"] {
            XCTAssertNil(HTTPContentRange(header))
        }
    }
    func testClearingRatingSendsNullRatherThanOmittingTheUpdate() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: APIJSON.encoder().encode(RatingUpdate(rating: nil))) as? [String: Any])
        XCTAssertTrue(object["rating"] is NSNull)
    }

    func testNetworkHeadersAndOrderedEndpointsPreserveProxyAuthentication() async throws {
        let primary = URL(string: "https://photos.example/prefix/api")!
        var settings = NetworkConfiguration(customHeaders: ["CF-Access-Client-Id": "opaque-value"],
                                            alternateEndpoints: [URL(string: "http://192.168.1.2:2283")!, primary],
                                            automaticallySwitchEndpoints: true)
        settings = try settings.validated()
        XCTAssertEqual(settings.candidates(primary: primary).map(\.absoluteString), ["http://192.168.1.2:2283/api", primary.absoluteString])
        settings.automaticallySwitchEndpoints = false
        let client = try APIClient(baseURL: primary, accessToken: "session", networkConfiguration: settings)
        let request = try await client.authorizedRequest(path: "assets/photo/thumbnail")
        XCTAssertEqual(request.url?.absoluteString, "https://photos.example/prefix/api/assets/photo/thumbnail")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "opaque-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session")
        let proxyClient = try APIClient(baseURL: primary, accessToken: "session", networkConfiguration: .init(customHeaders: ["Authorization": "Basic proxy-value"]))
        let proxyRequest = try await proxyClient.authorizedRequest(path: "assets/photo/thumbnail")
        XCTAssertEqual(proxyRequest.value(forHTTPHeaderField: "Authorization"), "Basic proxy-value")
        XCTAssertEqual(proxyRequest.value(forHTTPHeaderField: "x-immich-user-token"), "session")
        for headers in [["X-Key": "line\r\nbreak"], ["X-Key": "one", "x-key": "two"], ["Host": "elsewhere"], ["x-immich-user-token": "override"]] {
            XCTAssertThrowsError(try NetworkConfiguration(customHeaders: headers).validated())
        }
    }

    func testReadOnlyKeepsSearchAndAuthenticationWhileBlockingLibraryMutations() {
        for route in ["search/smart", "search/metadata", "auth/session/unlock", "auth/logout"] {
            XCTAssertTrue(ReadOnlyPolicy.permits(method: "POST", path: route))
        }
        XCTAssertTrue(ReadOnlyPolicy.permits(method: "GET", path: "assets/photo/thumbnail"))
        for (method, route) in [("POST", "assets"), ("PUT", "assets/photo"), ("DELETE", "assets"), ("PATCH", "albums/album"), ("POST", "users/profile-image")] {
            XCTAssertFalse(ReadOnlyPolicy.permits(method: method, path: route))
        }
    }

}

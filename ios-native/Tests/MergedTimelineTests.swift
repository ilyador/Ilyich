import Foundation
import XCTest
@testable import Ilyich

final class MergedTimelineTests: XCTestCase {
    func testMatchingCloudAndPhoneCopiesKeepOneServerRecordAndItsEditedRevision() throws {
        let date = try XCTUnwrap(APIDate.parse("2026-01-15T12:00:00Z"))
        let first = LocalPhoto(id: "phone-a", date: date)
        let duplicate = LocalPhoto(id: "phone-copy", date: date)
        let onlyLocal = LocalPhoto(id: "phone-b", date: date.addingTimeInterval(60))
        let archived = LocalPhoto(id: "archived-copy", date: date)
        let merge = MergedTimeline(photos: [first, duplicate, onlyLocal, archived],
                                   associations: [first.id: "remote", duplicate.id: "remote", archived.id: "archived"])
        let buckets = merge.buckets(remote: [.init(timeBucket: "2026-01-01T00:00:00Z", count: 1)])
        XCTAssertEqual(buckets.map(\.count), [2])
        let developed = Asset(id: "remote", fileCreatedAt: date, localDateTime: date, isDeveloped: true, mediaRevision: "xmp-7")
        let entries = merge.entries(remote: [developed], bucket: buckets[0].id)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.compactMap(\.remote), [developed])
        XCTAssertEqual(entries.compactMap(\.remote).first?.cacheRevision, "xmp-7")
        XCTAssertEqual(entries.filter { $0.remote == nil }.map(\.id), ["local:phone-b"])
    }

    func testLocalMonthDoesNotNeedAServerBucketAndEqualDatesHaveStableOrdering() throws {
        let date = try XCTUnwrap(APIDate.parse("2026-02-15T12:00:00Z"))
        let merge = MergedTimeline(photos: [.init(id: "b", date: date), .init(id: "a", date: date)])
        let buckets = merge.buckets(remote: [.init(timeBucket: "2026-01-01", count: 8)])
        XCTAssertEqual(buckets.map(\.id), ["2026-02-01", "2026-01-01"])
        XCTAssertEqual(buckets.map(\.count), [2, 8])
        XCTAssertEqual(merge.entries(remote: [], bucket: "2026-02-01").map(\.id), ["local:a", "local:b"])
    }

    /// A merged month is ordered by the time taken, newest first, then by ID, the server's photos
    /// and the phone-only ones alike, whatever order the server's came in.
    func testMergedMonthIsOrderedByTimeTakenThenID() throws {
        let day = try XCTUnwrap(APIDate.parse("2026-02-15T00:00:00Z"))
        // The server orders by file creation time within a day: "noon" before "night".
        let night = Asset(id: "night", fileCreatedAt: day.addingTimeInterval(8 * 3_600), localDateTime: day.addingTimeInterval(23 * 3_600))
        let noon = Asset(id: "noon", fileCreatedAt: day.addingTimeInterval(9 * 3_600), localDateTime: day.addingTimeInterval(12 * 3_600))
        let tie = Asset(id: "a-noon", fileCreatedAt: day.addingTimeInterval(10 * 3_600), localDateTime: day.addingTimeInterval(12 * 3_600))
        let early = Asset(id: "early", fileCreatedAt: day.addingTimeInterval(-86_400), localDateTime: day.addingTimeInterval(-86_400 + 9 * 3_600))
        let merge = MergedTimeline(photos: [.init(id: "phone", date: day.addingTimeInterval(13 * 3_600 - Double(TimeZone.current.secondsFromGMT(for: day))))])
        let entries = merge.entries(remote: [noon, tie, night, early], bucket: "2026-02-01")
        XCTAssertEqual(entries.map(\.id), ["night", "local:phone", "a-noon", "noon", "early"])
        XCTAssertEqual(merge.entries(remote: [noon, night, tie], bucket: "2026-01-01").map(\.id), ["night", "a-noon", "noon"],
                       "Without phone photos, the same order.")
    }

    func testCloudIdentityRequiresUnchangedCreationLocationAndNoRemoteAdjustment() throws {
        let date = try XCTUnwrap(APIDate.parse("2026-02-15T12:00:00Z"))
        let photo = LocalPhoto(id: "phone", date: date, latitude: 38.7, longitude: -9.1)
        func remote(date: Date?, adjustment: Date? = nil, latitude: Double? = 38.7) -> LocalAssetMatch {
            .init(assetID: "remote", checksum: "hash", cloudID: "cloud", createdAt: date,
                  adjustmentTime: adjustment, latitude: latitude, longitude: -9.1)
        }
        XCTAssertTrue(LocalIdentityMatch.matches(photo, remote: remote(date: date)))
        XCTAssertFalse(LocalIdentityMatch.matches(photo, remote: remote(date: date.addingTimeInterval(1))))
        XCTAssertFalse(LocalIdentityMatch.matches(photo, remote: remote(date: date, adjustment: date)))
        XCTAssertFalse(LocalIdentityMatch.matches(photo, remote: remote(date: date, latitude: 38.8)))
        XCTAssertFalse(LocalIdentityMatch.matches(photo, remote: remote(date: nil)))
    }
}

import XCTest
@testable import Ilyich

final class CleanupPolicyTests: XCTestCase {
    private let cutoff = Date(timeIntervalSince1970: 1_000)
    func testKeepsUnknownRecentAndBoundaryDates() {
        let policy = CleanupPolicy(cutoff: cutoff, keepFavorites: false, keepMediaType: "none")
        for date in [nil, cutoff, cutoff.addingTimeInterval(1)] {
            XCTAssertFalse(policy.allows(date: date, favorite: false, video: false, inKeptAlbum: false))
        }
        XCTAssertTrue(policy.allows(date: cutoff.addingTimeInterval(-1), favorite: false, video: false, inKeptAlbum: false))
    }
    func testFavoritesAndAlbumsRemainProtected() {
        let policy = CleanupPolicy(cutoff: cutoff, keepFavorites: true, keepMediaType: "none")
        XCTAssertFalse(policy.allows(date: .distantPast, favorite: true, video: false, inKeptAlbum: false))
        XCTAssertFalse(policy.allows(date: .distantPast, favorite: false, video: true, inKeptAlbum: true))
    }
    func testMediaTypeAndUnknownPreferenceFailClosed() {
        let photos = CleanupPolicy(cutoff: cutoff, keepFavorites: false, keepMediaType: "photos")
        XCTAssertFalse(photos.allows(date: .distantPast, favorite: false, video: false, inKeptAlbum: false))
        XCTAssertTrue(photos.allows(date: .distantPast, favorite: false, video: true, inKeptAlbum: false))
        let videos = CleanupPolicy(cutoff: cutoff, keepFavorites: false, keepMediaType: "videos")
        XCTAssertFalse(videos.allows(date: .distantPast, favorite: false, video: true, inKeptAlbum: false))
        XCTAssertTrue(videos.allows(date: .distantPast, favorite: false, video: false, inKeptAlbum: false))
        let unknown = CleanupPolicy(cutoff: cutoff, keepFavorites: false, keepMediaType: "unknown")
        XCTAssertFalse(unknown.allows(date: .distantPast, favorite: false, video: false, inKeptAlbum: false))
    }
    /// The critic's correction for P1: every build goes onto the owner's phone, so Free up space's
    /// Remove stays off until P4's cleanup service lands. P4 turns it on and deletes this test.
    func testFreeUpSpaceRemoveStaysOffUntilP4() {
        XCTAssertFalse(CleanupRemoval.isEnabled, "Free up space must not remove photos from the phone before P4.")
    }
}

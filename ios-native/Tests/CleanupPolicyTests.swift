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
    /// P4's cleanup service is built, but the owner's device test with disposable photos hasn't
    /// run, and every build goes onto the owner's phone. Until it has, Free up space's Remove stays
    /// unavailable. Opening CleanupRemovalGate after that test deletes this test.
    func testFreeUpSpaceRemoveStaysClosedUntilTheDeviceGate() {
        XCTAssertFalse(CleanupRemovalGate.isOpen, "Free up space must not remove photos from the phone before the owner's device test.")
    }
}

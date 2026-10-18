import XCTest
@testable import Ilyich

final class BackupReceiptTests: XCTestCase {
    func testDeletionProofRequiresSameFileOwnerAndLiveAsset() throws {
        let receipt = BackupRemoteFile(id: "asset", checksum: "original-sha1")
        func asset(id: String = "asset", owner: String = "user", checksum: String = "original-sha1", trashed: Bool = false) -> BackupRemoteAsset {
            BackupRemoteAsset(id: id, ownerId: owner, checksum: checksum, isTrashed: trashed, livePhotoVideoId: nil)
        }
        XCTAssertTrue(receipt.matches(asset(), ownerID: "user"))
        XCTAssertFalse(receipt.matches(asset(id: "replacement"), ownerID: "user"))
        XCTAssertFalse(receipt.matches(asset(owner: "other"), ownerID: "user"))
        XCTAssertFalse(receipt.matches(asset(checksum: "changed-sha1"), ownerID: "user"))
        XCTAssertFalse(receipt.matches(asset(trashed: true), ownerID: "user"))
    }

    func testSavedPreferencesKeepAutomaticAndCellularOffWhenMissing() throws {
        let preferences = try JSONDecoder().decode(BackupPreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(preferences.automatic)
        XCTAssertFalse(preferences.cellularPhotos)
        XCTAssertFalse(preferences.cellularVideos)
        XCTAssertEqual(preferences.triggerDelay, 30)
        let restored = try JSONDecoder().decode(BackupPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(preferences, restored)
    }
}

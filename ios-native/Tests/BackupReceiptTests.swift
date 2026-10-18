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

    func testOldReceiptsDecodeAndMalformedSizeDoesNotAffectVerification() throws {
        let old = #"{"modificationDate":0,"original":{"id":"asset","checksum":"sha1"}}"#
        let receipt = try JSONDecoder().decode(BackupReceipt.self, from: Data(old.utf8))
        XCTAssertNil(receipt.original.byteCount)

        let remote = #"{"id":"asset","ownerId":"user","checksum":"sha1","isTrashed":false,"exifInfo":{"fileSizeInByte":"oops"}}"#
        let asset = try JSONDecoder().decode(BackupRemoteAsset.self, from: Data(remote.utf8))
        XCTAssertTrue(receipt.original.matches(asset, ownerID: "user"))
        XCTAssertNil(asset.knownByteCount)
    }

    func testOptionalSizeDecodesOnlyWhenValidAndRequiredFieldsStayStrict() throws {
        func decode(_ exif: String) throws -> BackupRemoteAsset {
            let json = #"{"id":"a","ownerId":"u","checksum":"c","isTrashed":false"# + exif + "}"
            return try JSONDecoder().decode(BackupRemoteAsset.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#","exifInfo":{"fileSizeInByte":1234,"make":"x"}"#).knownByteCount, 1234)
        XCTAssertNil(try decode("").knownByteCount)
        XCTAssertNil(try decode(#","exifInfo":null"#).knownByteCount)
        XCTAssertNil(try decode(#","exifInfo":"bad""#).knownByteCount)
        XCTAssertNil(try decode(#","exifInfo":{}"#).knownByteCount)
        XCTAssertNil(try decode(#","exifInfo":{"fileSizeInByte":null}"#).knownByteCount)
        XCTAssertNil(try decode(#","exifInfo":{"fileSizeInByte":-1}"#).knownByteCount)
        XCTAssertNil(try decode(#","exifInfo":{"fileSizeInByte":99999999999999999999}"#).knownByteCount)

        let missingChecksum = #"{"id":"a","ownerId":"u","isTrashed":false,"exifInfo":{"fileSizeInByte":1}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(BackupRemoteAsset.self, from: Data(missingChecksum.utf8)))
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

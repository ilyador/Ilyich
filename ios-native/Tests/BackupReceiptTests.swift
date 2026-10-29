import XCTest
@testable import Ilyich

final class BackupReceiptTests: XCTestCase {
    /// A size the server reports in a shape it shouldn't is ignored, never failing the decode.
    func testMalformedSizeDoesNotAffectVerification() throws {
        let remote = #"{"id":"asset","ownerId":"user","checksum":"sha1","isTrashed":false,"exifInfo":{"fileSizeInByte":"oops"}}"#
        let asset = try JSONDecoder().decode(BackupRemoteAsset.self, from: Data(remote.utf8))
        XCTAssertEqual(asset.checksum, "sha1")
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

    /// Backup's defaults, which a new account's database starts from: automatic backup and
    /// cellular off, a 30-second delay.
    func testPreferencesDefaultToAutomaticAndCellularOff() throws {
        let preferences = TransferPreferences()
        XCTAssertFalse(preferences.automatic)
        XCTAssertFalse(preferences.cellularPhotos)
        XCTAssertFalse(preferences.cellularVideos)
        XCTAssertEqual(preferences.triggerDelay, 30)
        XCTAssertEqual(TransferJSON.encode(preferences),
                       #"{"automatic":false,"cellularPhotos":false,"cellularVideos":false,"downloadCloudOriginals":false,"excludedAlbums":[],"includedAlbums":[],"requireCharging":false,"syncAlbums":false,"triggerDelay":30}"#)
        let restored = try JSONDecoder().decode(TransferPreferences.self, from: Data(TransferJSON.encode(preferences).utf8))
        XCTAssertEqual(preferences, restored)
    }
}

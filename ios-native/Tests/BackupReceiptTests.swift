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
                       #"{"automatic":false,"cellularPhotos":false,"cellularVideos":false,"downloadCloudOriginals":false,"excludedAlbums":[],"includedAlbums":[],"requireCharging":false,"scope":"selectedAlbums","syncAlbums":false,"triggerDelay":30}"#)
        let restored = try JSONDecoder().decode(TransferPreferences.self, from: Data(TransferJSON.encode(preferences).utf8))
        XCTAssertEqual(preferences, restored)
    }

    func testLegacyPreferencesKeepTheirSelectionAndAutomaticSetting() throws {
        let legacy = #"{"automatic":false,"cellularPhotos":true,"cellularVideos":false,"downloadCloudOriginals":true,"excludedAlbums":["private"],"includedAlbums":["trips"],"requireCharging":true,"syncAlbums":true,"triggerDelay":60}"#
        let preferences = try JSONDecoder().decode(TransferPreferences.self, from: Data(legacy.utf8))
        XCTAssertEqual(preferences.scope, .selectedAlbums)
        XCTAssertEqual(preferences.includedAlbums, ["trips"])
        XCTAssertEqual(preferences.excludedAlbums, ["private"])
        XCTAssertTrue(preferences.hasSelection)
        XCTAssertFalse(preferences.automatic)
        XCTAssertTrue(preferences.cellularPhotos)
        XCTAssertTrue(preferences.downloadCloudOriginals)
        XCTAssertTrue(preferences.requireCharging)
        XCTAssertTrue(preferences.syncAlbums)
        XCTAssertEqual(preferences.triggerDelay, 60)
        let emptyLegacy = legacy.replacingOccurrences(of: #""includedAlbums":["trips"]"#, with: #""includedAlbums":[]"#)
        let empty = try JSONDecoder().decode(TransferPreferences.self, from: Data(emptyLegacy.utf8))
        XCTAssertEqual(empty.scope, .selectedAlbums)
        XCTAssertFalse(empty.hasSelection)
        XCTAssertFalse(empty.automatic)
    }

    func testEntireLibraryRoundTripsWithoutAlbumsOrEnablingAutomaticBackup() throws {
        var preferences = TransferPreferences()
        XCTAssertFalse(preferences.hasSelection)
        preferences.scope = .entireLibrary
        preferences.excludedAlbums = ["private"]
        let restored = try JSONDecoder().decode(TransferPreferences.self, from: Data(TransferJSON.encode(preferences).utf8))
        XCTAssertEqual(restored, preferences)
        XCTAssertTrue(restored.hasSelection)
        XCTAssertTrue(restored.includedAlbums.isEmpty)
        XCTAssertFalse(restored.automatic)
        preferences.scope = .selectedAlbums
        XCTAssertFalse(preferences.hasSelection)
    }

}

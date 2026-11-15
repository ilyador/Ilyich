import XCTest
@testable import Ilyich

final class BackupReceiptTests: XCTestCase {
    func testPathIdentityIsNeverAcceptedAsContentProof() throws {
        func remote(_ fields: String) throws -> BackupRemoteAsset {
            try JSONDecoder().decode(BackupRemoteAsset.self, from: Data((#"{"id":"a","ownerId":"u","checksum":"path-hash","isTrashed":false,"isExternal":true"# + fields + "}").utf8))
        }
        XCTAssertNil(try remote(#","checksumAlgorithm":"sha1-path""#).fileChecksum)
        XCTAssertNil(try remote("").fileChecksum)
        XCTAssertEqual(try remote(#","checksumAlgorithm":"sha1-path","contentChecksum":"actual-file-sha1""#).fileChecksum, "actual-file-sha1")
        XCTAssertEqual(try remote(#","checksumAlgorithm":"sha1""#).fileChecksum, "path-hash")
        XCTAssertNil(ContentFingerprint.checksum(primary: "c", algorithm: nil, content: nil, isExternal: nil))
        XCTAssertEqual(ContentFingerprint.checksum(primary: "c", algorithm: nil, content: nil, isExternal: false), "c")
    }

    func testLegacyLibraryIDDistinguishesUploadedContentFromExternalPathIdentity() throws {
        func remote(_ field: String) throws -> BackupRemoteAsset {
            try JSONDecoder().decode(BackupRemoteAsset.self, from: Data((#"{"id":"a","ownerId":"u","checksum":"c","isTrashed":false"# + field + "}").utf8))
        }
        XCTAssertEqual(try remote(#","libraryId":null"#).fileChecksum, "c")
        XCTAssertNil(try remote(#","libraryId":"external-library""#).fileChecksum)
        XCTAssertNil(try remote("").fileChecksum)
        XCTAssertNil(try remote(#","libraryId":null,"checksumAlgorithm":"future-algorithm""#).fileChecksum)
    }

    func testCleanupRequiresCurrentContentProofForExternalArchive() async throws {
        let receipt = CleanupReceipt(localID: "local", revision: AssetRevision(Date()), original: .init(id: "a", checksum: "file-sha1"), motion: nil)
        for content in [nil, "wrong", "file-sha1"] as [String?] {
            let remote = BackupRemoteAsset(id: "a", ownerId: "u", checksum: "path-sha1", isTrashed: false, livePhotoVideoId: nil,
                                           visibility: "archive", checksumAlgorithm: "sha1-path", contentChecksum: content, isExternal: true)
            let verifier = RemoteCopyVerifier(ownerID: "u", fetch: { _ in remote })
            let result = try await verifier.verify(receipt)
            if content == "file-sha1" {
                guard case .verified = result else { return XCTFail("Current content proof should permit cleanup verification.") }
            } else { XCTAssertEqual(result, .excluded(.checksumMismatch)) }
        }
    }

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

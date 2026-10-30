import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

final class AccountStoragePathsTests: XCTestCase {
    func testPathsMatchLegacyLocations() throws {
        let account = AccountID(server: URL(string: "https://photos.example/api")!, userID: "alice")
        // SHA-256 of "https://photos.example/api|alice", computed outside Swift.
        let digest = "cb73830dc48b80dcb5bfbf7950f74cb2efcdefb3be8cb10ec10c37faf0721712"
        XCTAssertEqual(account.cacheScope, "https://photos.example/api|alice")
        XCTAssertEqual(account.digest, digest)

        let paths = AccountStoragePaths(account)
        XCTAssertEqual(paths.entitiesDatabase, "IlyichEntities/\(digest).sqlite")
        XCTAssertEqual(paths.thumbnails, "IlyichThumbnails/cb73830dc48b80dcb5bfbf7950f74cb2")
        XCTAssertEqual(paths.mediaCache, "IlyichMedia/\(digest)")
        XCTAssertEqual(paths.backup, "Backup/\(digest)")
        XCTAssertEqual(paths.transfersDatabase, "IlyichTransfers/\(digest).sqlite")
        XCTAssertTrue(TransferStore.url(for: account).path.hasSuffix("/Library/Application Support/" + paths.transfersDatabase))
        XCTAssertEqual(paths.readOnlyKey, "readOnly.\(digest)")
        XCTAssertEqual(paths.lockedPINAccount, digest)
        XCTAssertEqual(paths.shelfOrderKey("people"), "shelfOrder.people.https://photos.example/api|alice")

        // The code that stores the data today derives the same names.
        let client = try APIClient(baseURL: URL(string: "https://photos.example")!, accessToken: "token", userID: "alice", networkConfiguration: .init())
        XCTAssertEqual(client.cacheScope, account.cacheScope)
        XCTAssertEqual(StoredCredential(server: client.baseURL, token: "token", userID: "alice", name: "Alice").scope, digest)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AccountStoragePathsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(ThumbnailDiskStore.shared(scope: client.cacheScope, root: root).directory.path, root.appendingPathComponent(paths.thumbnails).path)
        // Since T8 the app keeps the folder in Application Support; builds before kept it in Caches.
        XCTAssertTrue(ThumbnailDiskStore.directory(scope: client.cacheScope, root: nil).path.hasSuffix("/Library/Application Support/" + paths.thumbnails))
        XCTAssertTrue(ThumbnailDiskStore.cachesRoot.path.hasSuffix("/Library/Caches"))
        _ = try LibraryIndex(scope: client.cacheScope, userID: "alice", directory: root.appendingPathComponent("IlyichEntities", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(paths.entitiesDatabase).path))

        let shelves = try XCTUnwrap(UserDefaults(suiteName: "AccountStoragePathsTests"))
        defer { shelves.removePersistentDomain(forName: "AccountStoragePathsTests") }
        ShelfOrder(scope: client.cacheScope, defaults: shelves).save(["maya"], for: .people)
        XCTAssertEqual(shelves.stringArray(forKey: paths.shelfOrderKey("people")), ["maya"])

        let readOnly = AppGroup.defaults ?? .standard
        defer { readOnly.removeObject(forKey: paths.readOnlyKey) }
        readOnly.set(true, forKey: paths.readOnlyKey)
        XCTAssertTrue(ReadOnlyPolicy.isEnabled(server: URL(string: "https://photos.example")!, userID: "alice"),
                      "Read-only mode is found under the normalized address.")
    }
}

import XCTest
@testable import Ilyich

final class ThumbnailStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbnailStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testThumbnailsSurviveByAssetAndRevisionNotByAddress() async {
        let store = ThumbnailStore(scope: "https://photos.example|user", root: root)
        let id = "6f1c2a40-0000-4000-8000-000000000001"
        XCTAssertNil(store.data(assetID: id, revision: "r1"))
        await store.store(Data("first".utf8), assetID: id, revision: "r1")
        XCTAssertEqual(store.data(assetID: id, revision: "r1"), Data("first".utf8))
        XCTAssertTrue(store.contains(assetID: id, revision: "r1"))
        await store.store(Data("edited".utf8), assetID: id, revision: "r2")
        XCTAssertNil(store.data(assetID: id, revision: "r1"), "A new revision replaces the photo's older thumbnail.")
        XCTAssertEqual(store.data(assetID: id, revision: "r2"), Data("edited".utf8))
        let other = ThumbnailStore(scope: "https://photos.example|someone-else", root: root)
        XCTAssertNil(other.data(assetID: id, revision: "r2"), "Accounts never share thumbnails.")
    }

    func testDeletedPhotosAndClearingLeaveNothingBehind() async {
        let store = ThumbnailStore(scope: "scope", root: root)
        await store.store(Data("a".utf8), assetID: "asset-a", revision: "1")
        await store.store(Data("b".utf8), assetID: "asset-b", revision: "1")
        await store.forget(assetIDs: ["asset-a"])
        XCTAssertNil(store.data(assetID: "asset-a", revision: "1"))
        XCTAssertNotNil(store.data(assetID: "asset-b", revision: "1"))
        let usage = await store.currentUsage()
        XCTAssertGreaterThan(usage, 0)
        await store.removeAll()
        XCTAssertNil(store.data(assetID: "asset-b", revision: "1"))
        let cleared = await store.currentUsage()
        XCTAssertEqual(cleared, 0)
    }

    func testTheOldestThumbnailsGoFirstPastTheCap() async {
        let store = ThumbnailStore(scope: "scope", limit: 5 * 4_096, root: root)
        for index in 0..<8 {
            await store.store(Data(repeating: UInt8(index), count: 3_000), assetID: "asset-\(index)", revision: "1")
            try? await Task.sleep(for: .milliseconds(15))
        }
        let usage = await store.currentUsage()
        XCTAssertLessThanOrEqual(usage, 5 * 4_096)
        XCTAssertNil(store.data(assetID: "asset-0", revision: "1"), "The oldest thumbnail is trimmed first.")
        XCTAssertNotNil(store.data(assetID: "asset-7", revision: "1"), "The newest thumbnail stays.")
    }
}

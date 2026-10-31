import IlyichPlatform
import UIKit
import XCTest
@testable import Ilyich

private typealias G = LegacyGoldens

final class ThumbnailDiskStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbnailDiskStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func directory(_ scope: String = "scope") -> URL { ThumbnailDiskStore.directory(scope: scope, root: root) }

    /// Every regular file under the store's folders except the index, measured from the disk.
    private func measuredUsage(_ scope: String = "scope") -> Int {
        let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .isRegularFileKey]
        var total = 0
        for case let file as URL in FileManager.default.enumerator(at: directory(scope), includingPropertiesForKeys: Array(keys)) ?? .init() {
            guard !file.lastPathComponent.hasPrefix(ThumbnailDiskStore.indexName),
                  let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += values.fileAllocatedSize ?? 0
        }
        return total
    }

    func testThumbnailsSurviveByAssetAndRevisionNotByAddress() async {
        let store = ThumbnailDiskStore.shared(scope: "https://photos.example|user", root: root)
        let id = "6f1c2a40-0000-4000-8000-000000000001"
        XCTAssertNil(store.data(assetID: id, revision: "r1"))
        await store.store(Data("first".utf8), assetID: id, revision: "r1")
        XCTAssertEqual(store.data(assetID: id, revision: "r1"), Data("first".utf8))
        XCTAssertTrue(store.contains(assetID: id, revision: "r1"))
        await store.store(Data("edited".utf8), assetID: id, revision: "r2")
        XCTAssertNil(store.data(assetID: id, revision: "r1"), "A new revision replaces the photo's older thumbnail.")
        XCTAssertEqual(store.data(assetID: id, revision: "r2"), Data("edited".utf8))
        let other = ThumbnailDiskStore.shared(scope: "https://photos.example|someone-else", root: root)
        XCTAssertNil(other.data(assetID: id, revision: "r2"), "Accounts never share thumbnails.")
        XCTAssertTrue(ThumbnailDiskStore.shared(scope: "https://photos.example|user", root: root) === store, "One store per folder.")
    }

    /// A write is readable at once, before it reaches the disk.
    func testAQueuedWriteIsReadableAtOnce() async {
        let store = ThumbnailDiskStore.shared(scope: "scope", root: root)
        store.enqueueWrite(Data("now".utf8), assetID: "asset", revision: "1", token: store.fence.token())
        XCTAssertEqual(store.data(assetID: "asset", revision: "1"), Data("now".utf8))
        XCTAssertTrue(store.contains(assetID: "asset", revision: "1"))
        await store.waitUntilIndexed()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(assetID: "asset", revision: "1").path))
    }

    func testDeletedPhotosAndClearingLeaveNothingBehind() async {
        let store = ThumbnailDiskStore.shared(scope: "scope", root: root)
        await store.store(Data("a".utf8), assetID: "asset-a", revision: "1")
        await store.store(Data("b".utf8), assetID: "asset-b", revision: "1")
        await store.forget(assetIDs: ["asset-a"])
        XCTAssertNil(store.data(assetID: "asset-a", revision: "1"))
        XCTAssertNotNil(store.data(assetID: "asset-b", revision: "1"))
        let usage = await store.currentUsage()
        XCTAssertGreaterThan(usage, 0)
        await store.removeAll()
        XCTAssertNil(store.data(assetID: "asset-b", revision: "1"))
        XCTAssertFalse(store.contains(assetID: "asset-b", revision: "1"))
        let cleared = await store.currentUsage()
        XCTAssertEqual(cleared, 0)
        await store.store(Data("c".utf8), assetID: "asset-c", revision: "1")
        XCTAssertTrue(store.contains(assetID: "asset-c", revision: "1"), "The store works again after clearing.")
    }

    func testForgettingManyPhotosKeepsTheRest() async {
        let store = ThumbnailDiskStore.shared(scope: "scope", root: root)
        let ids = (0..<40).map { "asset-\($0)" } + ["an.odd/id"]
        for id in ids { await store.store(Data(id.utf8), assetID: id, revision: "1") }
        let gone = Set(ids.prefix(20)).union(["an.odd/id"])
        await store.forget(assetIDs: gone)
        for id in ids { XCTAssertEqual(store.contains(assetID: id, revision: "1"), !gone.contains(id), id) }
        let tracked = await store.currentUsage()
        XCTAssertEqual(tracked, measuredUsage(), "Usage drops by exactly what was forgotten.")
        let relaunched = ThumbnailDiskStore(directory: directory(), indexDelay: nil)
        let reloaded = await relaunched.currentUsage()
        XCTAssertEqual(reloaded, tracked, "The index remembers it across launches.")
    }

    /// Once the index lists the store, replacing a photo's revision deletes the old file through
    /// the index: no folder is listed, however large the store.
    func testFirstWriteAfterLaunchDoesNotEnumerateTheStore() async {
        let first = ThumbnailDiskStore(directory: directory(), indexDelay: nil)
        for index in 0..<30 { await first.store(Data("v1-\(index)".utf8), assetID: "asset-\(index)", revision: "1") }
        await first.waitUntilIndexed()

        let launched = ThumbnailDiskStore(directory: directory(), indexDelay: nil)
        _ = await launched.currentUsage()
        XCTAssertTrue(launched.isIndexComplete, "The index from the last launch is trusted.")
        XCTAssertTrue(launched.contains(assetID: "asset-7", revision: "1"))
        await launched.store(Data("v2".utf8), assetID: "asset-7", revision: "2")

        XCTAssertEqual(launched.listings.load(ordering: .relaxed), 0, "Nothing was listed.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: launched.url(assetID: "asset-7", revision: "1").path), "The old revision is gone.")
        XCTAssertEqual(launched.data(assetID: "asset-7", revision: "2"), Data("v2".utf8))
        XCTAssertNotNil(launched.data(assetID: "asset-8", revision: "1"), "Other photos stay.")
    }

    /// A download that began before the account's thumbnails were cleared never reaches the new store.
    func testWriteAfterAccountResetIsDiscarded() async {
        let store = ThumbnailDiskStore.shared(scope: "scope", root: root)
        let token = store.fence.token()
        store.enqueueWrite(Data("early".utf8), assetID: "queued", revision: "1", token: token)
        await store.removeAll()
        store.enqueueWrite(Data("late".utf8), assetID: "late", revision: "1", token: token)
        await store.waitUntilIndexed()
        for id in ["queued", "late"] {
            XCTAssertFalse(store.contains(assetID: id, revision: "1"), id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(assetID: id, revision: "1").path), id)
        }
        await store.store(Data("new".utf8), assetID: "new", revision: "1")
        XCTAssertTrue(store.contains(assetID: "new", revision: "1"), "A download begun after the reset is kept.")
    }

    /// Past the cap, trimming removes the thumbnails looked at longest ago, not the oldest files,
    /// and only when maintenance runs, never on the write itself.
    func testTrimEvictsLeastRecentlyViewedNotOldestWritten() async throws {
        let store = ThumbnailDiskStore(directory: directory(), limit: 5 * 4_096, indexDelay: nil, idleDelay: 60, touchInterval: 0)
        for index in 0..<5 {
            await store.store(Data(repeating: UInt8(index), count: 3_000), assetID: "asset-\(index)", revision: "1")
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(store.data(assetID: "asset-0", revision: "1"), "The oldest file is looked at again.")
        try await Task.sleep(for: .milliseconds(5))
        for index in 5..<7 {
            await store.store(Data(repeating: UInt8(index), count: 3_000), assetID: "asset-\(index)", revision: "1")
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(store.contains(assetID: "asset-1", revision: "1"), "Writing never trims.")

        await store.maintain()

        let usage = await store.currentUsage()
        XCTAssertLessThanOrEqual(usage, 5 * 4_096 / 10 * 9)
        XCTAssertNotNil(store.data(assetID: "asset-0", revision: "1"), "The thumbnail viewed recently stays, though written first.")
        XCTAssertNil(store.data(assetID: "asset-1", revision: "1"), "The least recently viewed goes.")
        XCTAssertNotNil(store.data(assetID: "asset-6", revision: "1"), "The newest stays.")
        XCTAssertEqual(usage, measuredUsage())
    }

    /// A lower cap, picked under Diagnostics, trims at once instead of waiting until the store is
    /// idle, least recently viewed first.
    func testALowerLimitTrimsAtOnce() async throws {
        let store = ThumbnailDiskStore(directory: directory(), limit: 5 * 4_096, indexDelay: nil, idleDelay: 60, touchInterval: 0)
        for index in 0..<4 {
            await store.store(Data(repeating: UInt8(index), count: 3_000), assetID: "asset-\(index)", revision: "1")
            try await Task.sleep(for: .milliseconds(5))
        }

        store.setLimit(2 * 4_096)

        let usage = await store.currentUsage()
        XCTAssertEqual(store.limit, 2 * 4_096)
        XCTAssertLessThanOrEqual(usage, 2 * 4_096 / 10 * 9)
        XCTAssertNil(store.data(assetID: "asset-0", revision: "1"), "The least recently viewed goes.")
        XCTAssertNotNil(store.data(assetID: "asset-3", revision: "1"), "The newest stays.")
        XCTAssertEqual(usage, measuredUsage())
    }

    /// The cap is one of the sizes Diagnostics offers, 1.5 GB until one is picked.
    func testTheLimitSettingKeepsAChoiceAndOtherwiseReads1Point5GB() throws {
        let name = "ThumbnailLimitSetting-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        XCTAssertTrue(ThumbnailLimitSetting.choices.contains(ThumbnailDiskStore.defaultLimit))
        XCTAssertEqual(ThumbnailLimitSetting.load(from: defaults), ThumbnailDiskStore.defaultLimit)

        ThumbnailLimitSetting.save(5_120 * 1_024 * 1_024, to: defaults)
        XCTAssertEqual(ThumbnailLimitSetting.load(from: defaults), 5_120 * 1_024 * 1_024)

        defaults.set(12_345, forKey: ThumbnailLimitSetting.defaultsKey)
        XCTAssertEqual(ThumbnailLimitSetting.load(from: defaults), ThumbnailDiskStore.defaultLimit, "A size that isn't offered reads as the default.")
    }

    /// Files a build without the index wrote are listed by the index, kept in place and read
    /// without a download. Until the index is complete, the store asks the disk.
    func testV1FilesAreAdoptedWithoutDownloading() async throws {
        let server = makeStubServer()
        let api = try APIClient(baseURL: server.baseURL, accessToken: "media-session", userID: "adopt-" + UUID().uuidString,
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        let store = ThumbnailDiskStore(directory: ThumbnailDiskStore.directory(scope: api.cacheScope, root: root), indexDelay: nil)
        var assets: [Asset] = []
        for (assetID, revision) in G.thumbnails where !assetID.hasPrefix("local:") {
            let bytes = try FixtureLoader.data("caches/" + Legacy.thumbnailPath(scope: G.account.cacheScope, assetID: assetID, revision: revision))
            let url = store.url(assetID: assetID, revision: revision)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            assets.append(Asset(id: assetID, mediaRevision: revision))
        }
        let before = measuredUsage(api.cacheScope)
        for asset in assets { XCTAssertTrue(store.contains(assetID: asset.id, revision: asset.cacheRevision), "Before the index, the disk answers.") }

        await store.waitUntilIndexed()

        XCTAssertTrue(store.isIndexComplete)
        let usage = await store.currentUsage()
        XCTAssertEqual(usage, before, "Every file is listed.")
        XCTAssertEqual(measuredUsage(api.cacheScope), before, "Nothing was removed or rewritten.")
        let scheduler = ThumbnailScheduler(store: store, memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { _, _, _ in throw URLError(.notConnectedToInternet) }))
        for asset in assets {
            XCTAssertTrue(store.contains(assetID: asset.id, revision: asset.cacheRevision), asset.id)
            let image = try await scheduler.image(assetID: asset.id, revision: asset.cacheRevision, shortSide: 64, network: false,
                                                  token: store.fence.token())
            XCTAssertNotNil(image, asset.id)
        }
        XCTAssertTrue(server.requests.isEmpty, "Nothing was downloaded.")
        await api.shutdown()
    }

    /// A file the index lists but iOS or an older build removed is a miss, and leaves the index;
    /// a file an older build added is adopted at the next launch's comparison.
    func testVanishedAndForeignFilesAreReconciled() async throws {
        let store = ThumbnailDiskStore(directory: directory(), indexDelay: nil)
        for id in ["kept", "purged"] { await store.store(Data(id.utf8), assetID: id, revision: "1") }
        await store.waitUntilIndexed()
        try FileManager.default.removeItem(at: store.url(assetID: "purged", revision: "1"))
        XCTAssertTrue(store.contains(assetID: "purged", revision: "1"), "The index still lists it.")
        XCTAssertNil(store.data(assetID: "purged", revision: "1"))
        _ = await store.currentUsage()
        XCTAssertFalse(store.contains(assetID: "purged", revision: "1"), "A failed read removes the row.")

        let foreign = store.url(assetID: "foreign", revision: "1")
        try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old build".utf8).write(to: foreign)
        let relaunched = ThumbnailDiskStore(directory: directory(), indexDelay: 0)
        try await waitUntil { relaunched.contains(assetID: "foreign", revision: "1") }
        let usage = await relaunched.currentUsage()
        XCTAssertEqual(usage, measuredUsage())
    }

    /// A sync reset's sweep removes files a complete index doesn't list, such as ones whose rows a
    /// crash kept from being saved, before the launch comparison has adopted them.
    func testSweepAfterResetRemovesFilesTheCompleteIndexDoesNotList() async throws {
        let store = ThumbnailDiskStore(directory: directory(), indexDelay: nil)
        for id in ["kept", "gone"] { await store.store(Data(id.utf8), assetID: id, revision: "1") }
        await store.waitUntilIndexed()
        let unlisted = store.url(assetID: "unlisted", revision: "1")
        try FileManager.default.createDirectory(at: unlisted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unsaved row".utf8).write(to: unlisted)

        let relaunched = ThumbnailDiskStore(directory: directory(), indexDelay: nil)
        try await waitUntil { relaunched.isIndexComplete }
        let removed = await relaunched.sweep(keeping: ["kept": "1"])
        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unlisted.path), "A file the index didn't list survived the sweep.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: relaunched.url(assetID: "gone", revision: "1").path))
        XCTAssertNotNil(relaunched.data(assetID: "kept", revision: "1"))
        let usage = await relaunched.currentUsage()
        XCTAssertEqual(usage, measuredUsage())
    }

    /// Without its index, the store rebuilds it from the folders and keeps every file.
    func testAMissingIndexIsRebuilt() async throws {
        let store = ThumbnailDiskStore(directory: directory(), indexDelay: nil)
        for index in 0..<5 { await store.store(Data("\(index)".utf8), assetID: "asset-\(index)", revision: "1") }
        await store.waitUntilIndexed()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: directory().appendingPathComponent(ThumbnailDiskStore.indexName + suffix))
        }
        let relaunched = ThumbnailDiskStore(directory: directory(), indexDelay: 0)
        try await waitUntil { relaunched.isIndexComplete }
        for index in 0..<5 { XCTAssertNotNil(relaunched.data(assetID: "asset-\(index)", revision: "1")) }
        let usage = await relaunched.currentUsage()
        XCTAssertEqual(usage, measuredUsage())
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

import UIKit
import XCTest
@testable import Ilyich

/// Grid thumbnails move out of Caches into Application Support (REBUILD_ROADMAP.md T8): by renaming,
/// with their index, never downloaded again, a move a kill stopped finished at the next launch, and
/// the new folder kept out of backups.
final class ThumbnailStoreMoveTests: XCTestCase {
    private struct Photo {
        let id: String
        let revision: String
        let bytes: Data
    }

    private var base: URL!
    /// Where builds before T8 kept the store, and where it is now.
    private var caches: URL { base.appendingPathComponent("Caches", isDirectory: true) }
    private var support: URL { base.appendingPathComponent("Application Support", isDirectory: true) }
    private let scope = "https://photos.example/api|user"

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbnailStoreMoveTests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    /// The first launch after the update finds an earlier build's thumbnails in Caches and moves
    /// them, with their index and coverage's position, by renaming: the same files, not copies.
    /// Until the move has run, reads find them in Caches. None is downloaded again, Caches keeps
    /// nothing, and the new folder is kept out of backups.
    func testAnEarlierBuildsThumbnailsMoveToApplicationSupportWithTheirIndex() async throws {
        let photos = (0..<12).map { photo($0) }
        let coverage = CoverageState(cursor: #"{"id":"b2-4"}"#, mark: 42, passMark: 42, policyHash: "policy", total: 60_000, stored: 12)
        let usage = await writeAsAnEarlierBuild(photos, in: caches, coverage: coverage)
        let earlierTree = caches.appendingPathComponent(ThumbnailDiskStore.folderName, isDirectory: true)
        let tree = support.appendingPathComponent(ThumbnailDiskStore.folderName, isDirectory: true)
        // The build before T8 never marked Caches.
        try setExcludedFromBackup(false, earlierTree)
        let numbers = try fileNumbers(under: earlierTree)
        XCTAssertEqual(numbers.count, photos.count + 1, "Every photo and the index.")

        // The store opens while its move waits, as behind another account's: Caches answers.
        let store = ThumbnailDiskStore.moveLock.withLock { _ in
            let store = ThumbnailDiskStore(directory: directory(in: support), indexDelay: nil, earlierRoot: caches)
            for photo in photos {
                XCTAssertTrue(store.contains(assetID: photo.id, revision: photo.revision), "Before the move, Caches answers.")
                XCTAssertEqual(store.data(assetID: photo.id, revision: photo.revision), photo.bytes, photo.id)
            }
            return store
        }

        let moved = await store.currentUsage()
        XCTAssertEqual(moved, usage, "The index came along.")
        XCTAssertTrue(store.isIndexComplete, "It still lists every file.")
        XCTAssertEqual(store.listings.load(ordering: .relaxed), 0, "Nothing was listed.")
        let position = await store.coverageState()
        XCTAssertEqual(position, coverage, "Coverage carries on where it was.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: earlierTree.path), "Caches keeps nothing.")
        XCTAssertEqual(try fileNumbers(under: tree), numbers, "Each file was renamed into Application Support, not copied.")
        XCTAssertTrue(isExcludedFromBackup(tree), "The folder is kept out of backups.")

        let fetches = Recorded<String>()
        let scheduler = ThumbnailScheduler(store: store, memory: DecodedThumbnailCache(), fetcher: ThumbnailFetcher(load: { id, _, _ in
            fetches.append(id)
            throw URLError(.notConnectedToInternet)
        }))
        for photo in photos {
            XCTAssertTrue(store.contains(assetID: photo.id, revision: photo.revision), photo.id)
            let image = try await scheduler.image(assetID: photo.id, revision: photo.revision, shortSide: 4, network: true,
                                                  token: store.fence.token())
            XCTAssertNotNil(image, photo.id)
        }
        XCTAssertEqual(fetches.all, [], "Nothing was downloaded again.")

        // A folder named as both places is left alone.
        XCTAssertEqual(ThumbnailDiskStore.moveEarlierFolders(from: tree, to: tree), 0)
        XCTAssertEqual(try fileNumbers(under: tree), numbers)
    }

    /// A move a kill stops anywhere loses nothing, and the next launch finishes it. Here an older
    /// build ran after this one, so both places hold the account's folder: a two-letter folder
    /// Application Support lacks moves whole, one it has a file at a time, a file in both stays as
    /// Application Support has it, and nothing there is replaced. The launch comparison adopts
    /// what arrived, and until it has, the store asks the disk, so no file is a miss.
    func testAMoveStoppedAnywhereFinishesAtTheNextLaunch() async throws {
        let earlier = (0..<8).map { photo($0) }
        // a1-0 is in both places; Application Support's copy, which differs here, must stay.
        let later = [photo(0, bytes: 40), photo(9, prefix: "a1"), photo(10, prefix: "e5")]
        let template = base.appendingPathComponent("template", isDirectory: true)
        _ = await writeAsAnEarlierBuild(earlier, in: template.appendingPathComponent("Caches", isDirectory: true))
        _ = await writeAsAnEarlierBuild(later, in: template.appendingPathComponent("Application Support", isDirectory: true))
        var expected: [String: Data] = [:], revisions: [String: String] = [:]
        for photo in earlier + later { expected[photo.id] = photo.bytes; revisions[photo.id] = photo.revision }

        let whole = try copy(template)
        let changes = ThumbnailDiskStore.moveEarlierFolders(from: tree(whole, "Caches"), to: tree(whole, "Application Support"))
        XCTAssertGreaterThan(changes, 10, "Folders moved whole and a file at a time.")

        for stop in 0..<changes {
            let run = try copy(template)
            ThumbnailDiskStore.moveEarlierFolders(from: tree(run, "Caches"), to: tree(run, "Application Support"), moves: stop)
            let earlierFolder = ThumbnailDiskStore.directory(scope: scope, root: run.appendingPathComponent("Caches", isDirectory: true))
            let folder = ThumbnailDiskStore.directory(scope: scope, root: run.appendingPathComponent("Application Support", isDirectory: true))
            for (id, bytes) in expected {
                let here = try? Data(contentsOf: file(id, revisions[id]!, in: folder))
                let there = try? Data(contentsOf: file(id, revisions[id]!, in: earlierFolder))
                XCTAssertTrue(here != nil || there != nil, "Stopped after \(stop): \(id) was lost.")
                if later.contains(where: { $0.id == id }) { XCTAssertEqual(here, bytes, "Stopped after \(stop): \(id) was replaced.") }
            }

            let store = ThumbnailDiskStore(directory: folder, indexDelay: 0, earlierRoot: run.appendingPathComponent("Caches", isDirectory: true))
            for (id, bytes) in expected {
                XCTAssertTrue(store.contains(assetID: id, revision: revisions[id]!), "Stopped after \(stop): \(id) is a miss.")
                XCTAssertEqual(store.data(assetID: id, revision: revisions[id]!), bytes, "Stopped after \(stop): \(id)")
            }
            let indexed = await becomesTrue { store.isIndexComplete }
            XCTAssertTrue(indexed, "Stopped after \(stop): the launch comparison did not finish.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: tree(run, "Caches").path), "Stopped after \(stop): Caches keeps something.")
            for (id, bytes) in expected {
                XCTAssertTrue(store.contains(assetID: id, revision: revisions[id]!), "Stopped after \(stop): \(id) is not listed.")
                XCTAssertEqual(try? Data(contentsOf: file(id, revisions[id]!, in: folder)), bytes, "Stopped after \(stop): \(id)")
            }
            let usage = await store.currentUsage()
            XCTAssertEqual(usage, measuredUsage(folder), "Stopped after \(stop)")
        }
    }

    /// The thumbnail folder stays out of backups: marked when the index opens, and marked again
    /// whenever the mark is found missing, at the next launch or once the store was cleared.
    func testTheThumbnailFolderStaysOutOfBackups() async throws {
        let tree = support.appendingPathComponent(ThumbnailDiskStore.folderName, isDirectory: true)
        do {
            let store = ThumbnailDiskStore(directory: directory(in: support), indexDelay: nil, earlierRoot: caches)
            await store.store(photo(0).bytes, assetID: photo(0).id, revision: photo(0).revision)
            await store.waitUntilIndexed()
            XCTAssertTrue(isExcludedFromBackup(tree))
        }

        try setExcludedFromBackup(false, tree)
        XCTAssertFalse(isExcludedFromBackup(tree))
        let relaunched = ThumbnailDiskStore(directory: directory(in: support), indexDelay: nil, earlierRoot: caches)
        _ = await relaunched.currentUsage()
        XCTAssertTrue(isExcludedFromBackup(tree), "The next launch marks it again.")

        try setExcludedFromBackup(false, tree)
        await relaunched.removeAll()
        await relaunched.store(photo(1).bytes, assetID: photo(1).id, revision: photo(1).revision)
        await relaunched.waitUntilIndexed()
        XCTAssertTrue(isExcludedFromBackup(tree), "So does the store, once cleared.")
    }

    /// Sign-out empties the account's folder in Application Support, and removes anything of it a
    /// move left in Caches. Clear browsing cache keeps it (G2).
    func testClearingEmptiesTheFolderInBothPlaces() async throws {
        let store = ThumbnailDiskStore(directory: directory(in: support), indexDelay: nil, earlierRoot: caches)
        await store.store(photo(0).bytes, assetID: photo(0).id, revision: photo(0).revision)
        let stored = store.url(assetID: photo(0).id, revision: photo(0).revision)
        XCTAssertTrue(stored.path.hasPrefix(support.path), stored.path)
        let left = file(photo(1).id, photo(1).revision, in: directory(in: caches))
        try FileManager.default.createDirectory(at: left.deletingLastPathComponent(), withIntermediateDirectories: true)
        try photo(1).bytes.write(to: left)

        await store.removeAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path), "The folder in Application Support is gone.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(in: caches).path), "What stayed in Caches is gone.")
        XCTAssertFalse(store.contains(assetID: photo(1).id, revision: photo(1).revision))
        let usage = await store.currentUsage()
        XCTAssertEqual(usage, 0)
    }

    // MARK: - Support

    /// A photo in the two-letter folder `prefix`, by default one of four; `bytes` picks its image.
    private func photo(_ index: Int, prefix: String? = nil, bytes: Int? = nil) -> Photo {
        let folder = prefix ?? ["a1", "b2", "c3", "d4"][index % 4]
        let hue = CGFloat(bytes ?? index) / 50
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return Photo(id: "\(folder)-\(index)", revision: "r\(index)", bytes: png)
    }

    private func directory(in root: URL) -> URL { ThumbnailDiskStore.directory(scope: scope, root: root) }

    private func tree(_ run: URL, _ root: String) -> URL {
        run.appendingPathComponent(root, isDirectory: true).appendingPathComponent(ThumbnailDiskStore.folderName, isDirectory: true)
    }

    /// Where the store keeps a photo's file under `folder`.
    private func file(_ id: String, _ revision: String, in folder: URL) -> URL {
        let path = Legacy.thumbnailPath(scope: scope, assetID: id, revision: revision)
        return folder.appendingPathComponent(path.split(separator: "/").suffix(2).joined(separator: "/"))
    }

    /// Writes `photos` as a build before T8 did, under `root`, with a complete index, and returns
    /// the usage it counted. The store is gone when this returns, and its index closed.
    private func writeAsAnEarlierBuild(_ photos: [Photo], in root: URL, coverage: CoverageState? = nil) async -> Int {
        let earlier = ThumbnailDiskStore(directory: directory(in: root), indexDelay: nil)
        for photo in photos { await earlier.store(photo.bytes, assetID: photo.id, revision: photo.revision) }
        await earlier.waitUntilIndexed()
        if let coverage { _ = await earlier.saveCoverageState(coverage, token: earlier.fence.token()) }
        return await earlier.currentUsage()
    }

    private func copy(_ template: URL) throws -> URL {
        let run = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: template, to: run)
        return run
    }

    /// The thumbnails and the index under `tree`, by path below it, each with its file number on
    /// the volume, which a rename keeps and a copy changes.
    private func fileNumbers(under tree: URL) throws -> [String: Int] {
        var numbers: [String: Int] = [:]
        for case let relative as String in FileManager.default.enumerator(atPath: tree.path) ?? .init() {
            guard !relative.hasSuffix("-wal"), !relative.hasSuffix("-shm") else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: tree.appendingPathComponent(relative).path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            numbers[relative] = try XCTUnwrap(attributes[.systemFileNumber] as? Int, relative)
        }
        return numbers
    }

    /// Every thumbnail's allocated size in `folder`, measured from the disk.
    private func measuredUsage(_ folder: URL) -> Int {
        let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .isRegularFileKey]
        var total = 0
        for case let file as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) ?? .init() {
            guard !file.lastPathComponent.hasPrefix(ThumbnailDiskStore.indexName),
                  let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += values.fileAllocatedSize ?? 0
        }
        return total
    }

    private func isExcludedFromBackup(_ folder: URL) -> Bool {
        (try? URL(fileURLWithPath: folder.path, isDirectory: true).resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    private func setExcludedFromBackup(_ excluded: Bool, _ folder: URL) throws {
        var url = URL(fileURLWithPath: folder.path, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try url.setResourceValues(values)
    }
}

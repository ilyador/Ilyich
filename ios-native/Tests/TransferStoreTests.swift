import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// The transfers database: where it lives, dates kept bit for bit, a completion that costs the
/// same few statements however many receipts there are, all of it off the main thread, and the
/// receipt queries cleanup and the phone's timeline will use.
@MainActor final class TransferStoreTests: XCTestCase {
    private typealias G = LegacyGoldens

    /// The database is the account's, in Application Support (never the App Group), and opens
    /// with the schema of architecture section 3, owned by nobody until the engine claims it.
    func testDatabaseLivesInApplicationSupportPerAccount() async throws {
        let account = AccountID(server: URL(string: "https://photos.example/api")!, userID: "alice")
        let standard = TransferStore.url(for: account)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(standard.path, support.appendingPathComponent("IlyichTransfers/\(account.digest).sqlite").path)
        XCTAssertFalse(standard.path.contains("/Shared/AppGroup/"), "Never the App Group, where a lock held at suspension kills the app.")

        let folder = temporaryDirectory()
        let store = TransferStore(url: TransferStore.url(for: account, in: folder))
        let meta = try await store.meta()
        XCTAssertEqual(meta, TransferMeta(schema: 1, engine: .legacy))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(account.digest).sqlite").path))
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, "Kept out of iCloud backup.")
        let tables = try await store.dump().keys.sorted()
        XCTAssertEqual(tables, ["album_destinations", "attempts", "confirmations", "engine_state", "jobs", "linked_albums", "meta",
                                "notification_batches", "preferences", "receipts", "share_consumed", "stack_tasks", "stages"])
        await store.close()
        do {
            _ = try await store.meta()
            XCTFail("A closed store refuses work.")
        } catch { XCTAssertEqual(error as? TransferStoreError, .closed) }
    }

    /// BM2: every date comes back with the bits it went in with, through each table and query:
    /// fractions PhotoKit reports, a whole number of seconds, the smallest double, a negative
    /// zero, which a REAL column would turn into 0, and the largest double. The rows are those
    /// B9's import wrote on the phone, and the engine's own writes after them.
    func testDatesRoundTripByBitPattern() async throws {
        let values: [Double] = [782_481_234.567_891, 781_234_567.123_456_7, 700_000_000, 0.1, -0.0, 5e-324, -1.5, 1.797_693_134_862_315_7e308]
        var seed = TransferSeed()
        for (index, value) in values.enumerated() {
            let id = "photo-\(index)"
            let date = Date(timeIntervalSinceReferenceDate: value)
            seed.confirmations.append((id, date))
            seed.receipts.append(.init(localID: id, modified: date, originalID: "asset-\(index)", originalChecksum: "sum-\(index)", confirmedAt: date))
            seed.jobs.append(.init(localID: "failed-\(index)", state: .failed, failure: .init(message: "Refused", date: date, filename: "IMG_\(index).HEIC")))
        }
        seed.jobs.append(.init(localID: "staged", state: .staged))
        seed.stages.append(Self.stage(localID: "staged", modified: Date(timeIntervalSinceReferenceDate: -0.0)))

        let store = TransferStore(url: temporaryDirectory().appendingPathComponent("transfers.sqlite"))
        try await store.seedForTest(seed)
        let contents = try await store.contents()
        for (index, value) in values.enumerated() {
            let receipt = try XCTUnwrap(contents.receipts.first { $0.localID == "photo-\(index)" })
            XCTAssertEqual(receipt.modificationDate?.bitPattern, value.bitPattern, "\(value)")
            XCTAssertEqual(receipt.confirmedAt?.bitPattern, value.bitPattern, "\(value)")
            XCTAssertEqual(contents.confirmations.first { $0.localID == "photo-\(index)" }?.modificationDate?.bitPattern, value.bitPattern, "\(value)")
            XCTAssertEqual(contents.jobs.first { $0.sourceKey == "failed-\(index)" }?.errorAt?.bitPattern, value.bitPattern, "\(value)")
            let read = try await store.receipts(for: ["photo-\(index)"])
            XCTAssertEqual(read["photo-\(index)"]?.revision, AssetRevision(referenceSeconds: value), "\(value)")
            let failures = try await store.failures(lane: .library, limit: 100)
            XCTAssertEqual(failures.first { $0.source == .photo(DeviceAssetID(rawValue: "failed-\(index)")) }?.failedAt?.timeIntervalSinceReferenceDate.bitPattern,
                           value.bitPattern, "\(value)")
        }
        XCTAssertEqual(contents.stages.first?.modificationDate?.bitPattern, (-0.0).bitPattern, "A negative zero stays negative.")
        let staged = try await store.recoveryJobs().first { $0.job.source.key == "staged" }?.stage
        XCTAssertEqual(staged?.revision.referenceSeconds.bitPattern, (-0.0).bitPattern, "The stage the engine reads keeps it too.")

        // And through a completion and a verification.
        let job = try XCTUnwrap(contents.jobs.first { $0.sourceKey == "staged" })
        let revision = AssetRevision(referenceSeconds: 782_481_234.567_891)
        let confirmedAt = Date(timeIntervalSinceReferenceDate: 0.1)
        let receipt = TransferReceipt(localID: "staged", revision: revision, original: RemoteCopy(id: "new", checksum: "new-sum"),
                                      motion: nil, confirmedAt: confirmedAt)
        let committed = try await store.complete(TransferCompletion(job: job.id, lease: nil, localID: "staged", revision: revision, assetID: "new",
                                                                    receipt: receipt, confirmedAt: confirmedAt))
        XCTAssertTrue(committed)
        let stored = try await store.receipts(for: ["staged"])["staged"]
        XCTAssertEqual(stored?.revision, revision)
        XCTAssertEqual(stored?.confirmedAt?.timeIntervalSinceReferenceDate.bitPattern, confirmedAt.timeIntervalSinceReferenceDate.bitPattern)
        let verified = try await store.updateVerifiedSizes(ifUnchanged: [VerifiedSizes(localID: "staged", revision: revision, originalID: "new", motionID: nil,
                                                                                       originalBytes: 1, motionBytes: nil)],
                                                           at: Date(timeIntervalSinceReferenceDate: -0.0))
        XCTAssertEqual(verified, 1)
        let after = try await store.receipts(for: ["staged"])["staged"]
        XCTAssertEqual(after?.verifiedAt?.timeIntervalSinceReferenceDate.bitPattern, (-0.0).bitPattern)
        let removed = Date(timeIntervalSinceReferenceDate: 5e-324)
        let marked = try await store.markLocallyDeleted([LocalDeletion(localID: "staged", revision: revision, date: removed)])
        XCTAssertEqual(marked, 1)
        let deleted = try await store.receipts(for: ["staged"])["staged"]
        XCTAssertEqual(deleted?.localDeletedAt?.timeIntervalSinceReferenceDate.bitPattern, (5e-324).bitPattern)
    }

    /// Confirming one more upload with 60,000 receipts on the phone writes only that photo's rows:
    /// the same statements as with ten, where the old engine's state.json rewrote every receipt for
    /// each photo.
    /// None of it runs on the main thread, though every call here comes from it.
    func testCompletionIsIncrementalAndOffMainWith60kReceipts() async throws {
        func statementsToComplete(receipts count: Int) async throws -> (completion: Int, verification: Int, store: TransferStore) {
            let store = TransferStore(url: temporaryDirectory().appendingPathComponent("transfers.sqlite"))
            var seed = TransferSeed()
            for index in 0..<count {
                let id = String(format: "%08X-0000-4000-8000-000000000000/L0/001", index)
                let date = Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(index) * 0.001)
                seed.confirmations.append((id, date))
                seed.receipts.append(.init(localID: id, modified: date, originalID: "asset-\(index)", originalChecksum: "sum-\(index)", confirmedAt: date))
            }
            seed.jobs = [.init(localID: "next", batch: G.notificationID), .init(localID: "after", batch: G.notificationID)]
            seed.destinations = [("next", "album", nil)]
            seed.batch = (G.notificationID, 2, 0, nil)
            try await store.seedForTest(seed)
            let job = try unwrapped(try await store.contents().jobs.first { $0.sourceKey == "next" })

            let before = await store.statistics().statements
            let revision = AssetRevision(referenceSeconds: 782_000_000.5)
            let committed = try await store.complete(TransferCompletion(
                job: job.id, lease: nil, localID: "next", revision: revision, assetID: "next-asset",
                receipt: TransferReceipt(localID: "next", revision: revision, original: RemoteCopy(id: "next-asset", checksum: "next-sum"), motion: nil,
                                         confirmedAt: Date()),
                confirmedAt: Date()))
            XCTAssertTrue(committed)
            let completion = await store.statistics().statements - before

            let measured = await store.statistics().statements
            let first = String(format: "%08X-0000-4000-8000-000000000000/L0/001", 0)
            let updated = try await store.updateVerifiedSizes(ifUnchanged: [VerifiedSizes(
                localID: first, revision: AssetRevision(referenceSeconds: 700_000_000), originalID: "asset-0", motionID: nil, originalBytes: 42, motionBytes: nil)],
                                                              at: Date())
            XCTAssertEqual(updated, 1)
            return (completion, await store.statistics().statements - measured, store)
        }

        let small = try await statementsToComplete(receipts: 10)
        let started = ContinuousClock.now
        let large = try await statementsToComplete(receipts: 60_000)
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(large.completion, small.completion, "A completion's statements don't grow with the receipts.")
        XCTAssertLessThanOrEqual(large.completion, 14)
        XCTAssertEqual(large.verification, small.verification, "Nor do a verification's.")
        XCTAssertEqual(large.verification, 3, "Begin, one update, commit.")
        XCTAssertLessThan(elapsed, .seconds(60), "Seeding and completing 60,000 receipts stays fast.")
        let statistics = await large.store.statistics()
        XCTAssertGreaterThan(statistics.statements, 120_000, "Seeding wrote a row per statement.")
        XCTAssertEqual(statistics.onMainThread, 0, "Nothing ran on the main thread.")

        // The completion did what a commit does.
        let contents = try await large.store.contents()
        XCTAssertEqual(contents.jobs.map(\.sourceKey), ["after"])
        XCTAssertEqual(contents.receipts.count, 60_001)
        XCTAssertEqual(contents.confirmations.count, 60_001)
        XCTAssertEqual(contents.albumDestinations.map(\.remoteID), ["next-asset"], "The album the photo waited for learns its server ID.")
        XCTAssertEqual(contents.notificationBatches.first?.completed, 1, "The running batch counts it.")
    }

    /// A completion applies only to the job it names while its lease holds; a re-upload of a photo
    /// backed up before stacks the new copy with the old one, as the old backup did.
    func testCompletionNeedsItsLeaseAndStacksAReupload() async throws {
        let store = TransferStore(url: temporaryDirectory().appendingPathComponent("transfers.sqlite"))
        var seed = TransferSeed()
        let old = Date(timeIntervalSinceReferenceDate: 700_000_000.25)
        seed.receipts = [.init(localID: "edited", modified: old, originalID: "old-asset", originalChecksum: "old")]
        seed.confirmations = [("edited", old)]
        seed.jobs = [.init(localID: "edited")]
        try await store.seedForTest(seed)
        let job = try unwrapped(try await store.contents().jobs.first)
        let revision = AssetRevision(referenceSeconds: 790_000_000.75)
        func completion(lease: UUID?, job id: Int64) -> TransferCompletion {
            TransferCompletion(job: id, lease: lease, localID: "edited", revision: revision, assetID: "new-asset",
                               receipt: TransferReceipt(localID: "edited", revision: revision, original: RemoteCopy(id: "new-asset", checksum: "new"),
                                                        motion: nil, confirmedAt: Date()),
                               confirmedAt: Date())
        }
        let stale = try await store.complete(completion(lease: UUID(), job: job.id))
        XCTAssertFalse(stale, "A lease that doesn't hold the job never commits.")
        let unknown = try await store.complete(completion(lease: nil, job: job.id + 99))
        XCTAssertFalse(unknown)
        let unchanged = try await store.contents()
        XCTAssertEqual(unchanged.jobs.count, 1)
        XCTAssertEqual(unchanged.receipts.first?.originalID, "old-asset")

        let committed = try await store.complete(completion(lease: nil, job: job.id))
        XCTAssertTrue(committed)
        let contents = try await store.contents()
        XCTAssertTrue(contents.jobs.isEmpty)
        XCTAssertEqual(contents.receipts.first?.originalID, "new-asset")
        XCTAssertEqual(contents.confirmations.first?.modificationDate?.bitPattern, revision.referenceSeconds.bitPattern)
        XCTAssertEqual(contents.stackTasks, 1, "The new copy is stacked with the one backed up before.")
    }

    /// The receipt queries: lookups by local ID in any number, pages in local ID order, and sizes
    /// recorded only for receipts that are still the ones checked.
    func testReceiptQueries() async throws {
        let store = TransferStore(url: temporaryDirectory().appendingPathComponent("transfers.sqlite"))
        var seed = TransferSeed()
        let ids = (0..<2_500).map { String(format: "local-%05d", $0) }
        for (index, id) in ids.enumerated() {
            let video = index.isMultiple(of: 10)
            seed.receipts.append(.init(localID: id, modified: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(index)), originalID: "asset-\(index)",
                                       originalChecksum: "sum-\(index)", originalBytes: index == 1 ? 77 : nil,
                                       motionID: video ? "motion-\(index)" : nil, motionChecksum: video ? "motion-sum-\(index)" : nil))
        }
        try await store.seedForTest(seed)

        let found = try await store.receipts(for: ids + ["missing"])
        XCTAssertEqual(found.count, 2_500, "Every ID is looked up, past the 2,000 a statement takes.")
        XCTAssertEqual(found["local-00001"]?.original, RemoteCopy(id: "asset-1", checksum: "sum-1", byteCount: 77))
        XCTAssertEqual(found["local-00010"]?.motion, RemoteCopy(id: "motion-10", checksum: "motion-sum-10"))
        XCTAssertNil(found["missing"])

        var pages: [[ReceiptAssociation]] = []
        var cursor: String?
        repeat {
            let page = try await store.associations(after: cursor, limit: 1_000)
            if !page.isEmpty { pages.append(page) }
            cursor = page.last?.localID
            if page.count < 1_000 { break }
        } while true
        XCTAssertEqual(pages.map(\.count), [1_000, 1_000, 500])
        XCTAssertEqual(pages.flatMap { $0 }.map(\.localID), ids)
        XCTAssertEqual(pages.first?.first, ReceiptAssociation(localID: "local-00000", assetID: "asset-0"))

        let verification = try await store.receiptsForVerification(after: "local-02497", limit: 10)
        XCTAssertEqual(verification.map(\.localID), ["local-02498", "local-02499"])

        // Only an unchanged receipt takes the sizes: same revision, same server copies.
        let checkedAt = Date(timeIntervalSinceReferenceDate: 800_000_000.5)
        let updated = try await store.updateVerifiedSizes(ifUnchanged: [
            VerifiedSizes(localID: "local-00002", revision: AssetRevision(referenceSeconds: 700_000_002), originalID: "asset-2", motionID: nil,
                          originalBytes: 2_000, motionBytes: nil),
            VerifiedSizes(localID: "local-00003", revision: AssetRevision(referenceSeconds: 700_000_003.5), originalID: "asset-3", motionID: nil,
                          originalBytes: 3_000, motionBytes: nil),
            VerifiedSizes(localID: "local-00004", revision: AssetRevision(referenceSeconds: 700_000_004), originalID: "replaced", motionID: nil,
                          originalBytes: 4_000, motionBytes: nil),
            VerifiedSizes(localID: "local-00010", revision: AssetRevision(referenceSeconds: 700_000_010), originalID: "asset-10", motionID: "motion-10",
                          originalBytes: 10_000, motionBytes: 1_000),
            VerifiedSizes(localID: "local-00020", revision: AssetRevision(referenceSeconds: 700_000_020), originalID: "asset-20", motionID: nil,
                          originalBytes: 20_000, motionBytes: nil),
        ], at: checkedAt)
        XCTAssertEqual(updated, 2, "A changed revision, a replaced copy and a missing video each keep the receipt as it was.")
        let after = try await store.receipts(for: ["local-00002", "local-00003", "local-00004", "local-00010", "local-00020"])
        XCTAssertEqual(after["local-00002"]?.original.byteCount, 2_000)
        XCTAssertEqual(after["local-00002"]?.verifiedAt, checkedAt)
        XCTAssertNil(after["local-00003"]?.original.byteCount)
        XCTAssertNil(after["local-00004"]?.original.byteCount)
        XCTAssertEqual(after["local-00010"]?.original.byteCount, 10_000)
        XCTAssertEqual(after["local-00010"]?.motion?.byteCount, 1_000)
        XCTAssertNil(after["local-00020"]?.verifiedAt)
    }

    // MARK: - Support

    /// XCTUnwrap for a value that takes an await, which XCTUnwrap's autoclosure can't hold.
    private func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    /// A stage as B9's import wrote one: files relative to the App Group, no checksum of the still.
    static func stage(localID: String, modified: Date, folder: String = "F0F0F0F0-0000-4000-8000-000000000000",
                      stage: String = "A0A0A0A0-0000-4000-8000-000000000000") -> TransferSeed.Stage {
        let path = "Backup/\(G.digest)/\(folder)"
        return TransferSeed.Stage(localID: localID, stageID: stage, folder: path, modified: modified,
                                  original: StagedFile(path: path + "/original", filename: "IMG_9000.HEIC", contentType: "image/heic"),
                                  fields: ["fileCreatedAt": "2025-10-18T09:41:12Z", "isFavorite": "false"], bodyPath: path + "/\(stage).multipart")
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TransferStoreTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// The Photos journal in device.sqlite: an entry written before Photos is asked and finished after,
/// kept when the screen that asked is gone, reconciled at the next launch and never applied again,
/// and stored in a form a later importer reads exactly.
@MainActor final class MutationJournalTests: XCTestCase {
    private let a = DeviceAssetID(rawValue: "A/L0/001")
    private let b = DeviceAssetID(rawValue: "B/L0/001")
    private let c = DeviceAssetID(rawValue: "C/L0/001")
    private let revision = AssetRevision(referenceSeconds: FakePhotoKit.revision)
    private let digest = AccountID(server: URL(string: "https://photos.example.com/api")!, userID: "alice").digest

    /// The person confirms iOS's prompt after the screen that asked has gone. Photos still removes
    /// the photo, and the journal and the results say committed.
    func testCommittedAfterTheScreenIsGone() async throws {
        let photos = FakePhotoKit()
        photos.add(a.rawValue)
        let prompt = StubServer.Gate()
        addTeardownBlock { prompt.open() }
        photos.holdAtPrompt(prompt)
        let journal = DeviceDatabase(url: deviceDatabaseURL())
        let adapter = PhotoKitAdapter(library: photos, assets: photos, journal: journal)
        let heard = listen(to: adapter.mutations())
        let removal = DeviceMutation.delete([a], expected: [a: revision], origin: .cleanup(scan: UUID(), account: digest))

        // The screen asks, iOS's prompt shows, and the screen goes, cancelling its work.
        let screen = Task { await adapter.perform(removal) }
        try await waitFor { prompt.waiting == 1 }
        screen.cancel()
        let pending = try await journal.records()
        XCTAssertEqual(pending.map(\.entry.mutation), [removal], "Written before Photos was asked.")
        XCTAssertEqual(pending.map(\.finishedAt), [nil], "Not finished while the prompt is up.")

        prompt.open()
        try await waitFor { heard.value.count == 1 }
        let committed = DeviceMutationResult.Outcome.committed(affected: [a], created: [])
        XCTAssertEqual(heard.value.map(\.outcome), [committed])
        let records = try await journal.records()
        XCTAssertEqual(records.map(\.outcome), [committed])
        XCTAssertNotNil(records.first?.finishedAt)
        XCTAssertNil(photos.asset(a.rawValue))
        let answer = await screen.value
        XCTAssertEqual(answer.outcome, committed, "The cancelled screen's own answer says the same.")
    }

    /// At the next launch, a removal the app ended during is reconciled from what Photos holds: done
    /// if its photos are gone, interrupted if they are still there. A favorite is done only if it
    /// shows, and a save can't be told. Photos is never asked again, at that launch or any later.
    func testInterruptedDeleteIsReconciledNotReplayed() async throws {
        let url = deviceDatabaseURL()
        let earlier = DeviceDatabase(url: url)
        let applied = entry(.delete([a, b], expected: [a: revision, b: revision], origin: .cleanup(scan: UUID(), account: digest)), at: 1_000)
        let unanswered = entry(.delete([c], expected: [c: revision], origin: .user), at: 2_000)
        let favorited = entry(.setFavorite([c], true, expected: [:]), at: 3_000)
        let saved = entry(.create(still: nil, video: nil, pairedVideo: nil, origin: .saveFromServer(asset: "server-1", account: digest)), at: 4_000)
        for begun in [applied, unanswered, favorited, saved] { try await earlier.begin(begun) }

        // At launch A and B are gone; C is still there, and not a favorite.
        let photos = FakePhotoKit()
        photos.add(c.rawValue)
        let adapter = PhotoKitAdapter(library: photos, assets: photos, journal: DeviceDatabase(url: url))
        let heard = listen(to: adapter.mutations())
        await adapter.start()

        let records = try await DeviceDatabase(url: url).records()
        XCTAssertEqual(records.map(\.entry.id), [applied.id, unanswered.id, favorited.id, saved.id])
        XCTAssertEqual(records.map(\.outcome), [.committed(affected: [a, b], created: []), .interrupted, .interrupted, .interrupted])
        XCTAssertFalse(records.contains { $0.finishedAt == nil })
        try await waitFor { heard.value.count == 4 }
        XCTAssertEqual(photos.performed, 0, "Nothing is applied again.")
        XCTAssertNotNil(photos.asset(c.rawValue))

        // Reconciled once: later launches find nothing left to reconcile.
        await adapter.start()
        let later = PhotoKitAdapter(library: photos, assets: photos, journal: DeviceDatabase(url: url))
        await later.start()
        let after = try await DeviceDatabase(url: url).records()
        XCTAssertEqual(after, records)
        XCTAssertEqual(photos.performed, 0)
    }

    /// Limited access hides photos outside the selection, so a removal whose photos can't be seen
    /// can't be told as done. It waits for read access at all.
    func testInterruptedDeleteNeedsFullAccessToCountAsDone() async throws {
        let url = deviceDatabaseURL()
        let removal = entry(.delete([a], expected: [a: revision], origin: .user), at: 1_000)
        try await DeviceDatabase(url: url).begin(removal)

        let photos = FakePhotoKit(status: .denied)
        let adapter = PhotoKitAdapter(library: photos, assets: photos, journal: DeviceDatabase(url: url))
        await adapter.start()
        let waiting = try await DeviceDatabase(url: url).records()
        XCTAssertEqual(waiting.map(\.finishedAt), [nil], "Without read access nothing is reconciled.")

        photos.setStatus(.limited)
        await adapter.refreshAccess()
        try await waitFor { (try? self.finishedCount(url)) == 1 }
        let reconciled = try await DeviceDatabase(url: url).records()
        XCTAssertEqual(reconciled.map(\.outcome), [.interrupted])
        XCTAssertEqual(photos.performed, 0)
    }

    /// DS9: the entry is written before Photos is asked, and a journal that can't be written
    /// changes nothing.
    func testEntryIsWrittenBeforePhotosIsAsked() async throws {
        let photos = FakePhotoKit()
        photos.add(a.rawValue)
        let journal = DeviceDatabase(url: deviceDatabaseURL())
        let adapter = PhotoKitAdapter(library: photos, assets: photos, journal: journal)
        let open = Locked<[UUID]>([])
        photos.beforeBlock {
            let entries = (try? await journal.unfinished()) ?? []
            open.mutate { $0 = entries.map(\.id) }
        }
        let favorited = await adapter.perform(.setFavorite([a], true, expected: [:]))
        XCTAssertEqual(open.value, [favorited.id])
        let unfinished = try await journal.unfinished()
        XCTAssertEqual(unfinished, [], "Finished once Photos answered.")

        let blocked = PhotoKitAdapter(library: photos, assets: photos,
                                      journal: DeviceDatabase(url: URL(fileURLWithPath: "/dev/null/IlyichDevice/device.sqlite")))
        let refused = await blocked.perform(.delete([a], expected: [a: revision], origin: .user))
        guard case .failed = refused.outcome else { return XCTFail("Nothing is removed without a journal entry, not \(refused.outcome).") }
        XCTAssertEqual(photos.performed, 1, "Photos was asked only for the journaled change.")
        XCTAssertNotNil(photos.asset(a.rawValue))
    }

    /// A later importer reads these rows: B9 marks a receipt locally deleted from a committed
    /// cleanup removal whose expected revision equals the receipt's. Revisions are kept bit for bit
    /// and dates as REAL seconds since 2001, with the account, the scan and the order asked.
    func testEntriesKeepRevisionsBitExactAndTheirOrigin() async throws {
        let url = deviceDatabaseURL()
        let journal = DeviceDatabase(url: url)
        let receipt = AssetRevision(referenceSeconds: Double(bitPattern: LegacyGoldens.Bits.current))
        let expected = [a: receipt, b: AssetRevision(referenceSeconds: -0.0), c: AssetRevision(referenceSeconds: 0.1 + 0.2)]
        let scan = try XCTUnwrap(UUID(uuidString: "6F1C3B1E-2D43-4C59-9A8B-0D7E1F2A3B4C"))
        let removal = DeviceJournalEntry(id: try XCTUnwrap(UUID(uuidString: "0E9A1F3C-5B7D-4E2F-8A6C-1B3D5F7A9C2E")),
                                         mutation: .delete([c, a, b], expected: expected, origin: .cleanup(scan: scan, account: digest)),
                                         createdAt: Date(timeIntervalSinceReferenceDate: 782_481_300.25))
        try await journal.begin(removal)
        try await journal.finish(removal.id, outcome: .committed(affected: [c, a, b], created: []), at: Date(timeIntervalSinceReferenceDate: 782_481_301.5))
        try await journal.finish(removal.id, outcome: .failed("A second finish changes nothing."), at: Date())

        let first = try await journal.records().first
        let record = try XCTUnwrap(first)
        XCTAssertEqual(record.entry, removal, "Read back bit for bit.")
        XCTAssertEqual(record.outcome, .committed(affected: [c, a, b], created: []))
        XCTAssertEqual(record.finishedAt, Date(timeIntervalSinceReferenceDate: 782_481_301.5))
        guard case .delete(_, let kept, _) = record.entry.mutation else { return XCTFail("A removal.") }
        XCTAssertEqual(kept[b]?.referenceSeconds.bitPattern, (-0.0).bitPattern)

        let database = try DeviceSQLite(url: url)
        let columns = try database.query("PRAGMA table_info(device_mutation)").compactMap { $0[1].text }
        XCTAssertEqual(columns, ["id", "account_digest", "kind", "origin", "asset_ids", "expected_revisions", "created_at", "finished_at", "outcome", "detail"])
        XCTAssertEqual(try database.query("PRAGMA user_version").first?.first, .real(1))
        let row = try XCTUnwrap(try database.query("""
            SELECT id,account_digest,kind,origin,asset_ids,expected_revisions,typeof(created_at),created_at,typeof(finished_at),outcome,detail
            FROM device_mutation
            """).first)
        XCTAssertEqual(row, [.text("0E9A1F3C-5B7D-4E2F-8A6C-1B3D5F7A9C2E"), .text(digest), .text("delete"),
                             .text(#"{"kind":"cleanup","scan":"6F1C3B1E-2D43-4C59-9A8B-0D7E1F2A3B4C"}"#),
                             .text(#"["C/L0/001","A/L0/001","B/L0/001"]"#),
                             .text(#"{"A/L0/001":"41c751dba948b0a7","B/L0/001":"8000000000000000","C/L0/001":"3fd3333333333334"}"#),
                             .text("real"), .real(782_481_300.25), .text("real"), .text("committed"), .null])

        // The other kinds and origins, as stored.
        let favorite = entry(.setFavorite([a], false, expected: [:]), at: 1)
        let save = entry(.create(still: URL(fileURLWithPath: "/tmp/IMG_0001.HEIC"), video: nil, pairedVideo: nil,
                                 origin: .saveFromServer(asset: "server-1", account: digest)), at: 2)
        try await journal.begin(favorite)
        try await journal.begin(save)
        try await journal.finish(save.id, outcome: .committed(affected: [], created: [DeviceAssetID(rawValue: "D/L0/001")]), at: Date())
        let stored = try database.query("SELECT kind,account_digest,origin,asset_ids,expected_revisions FROM device_mutation WHERE id IN (?,?) ORDER BY created_at",
                                        [.text(favorite.id.uuidString), .text(save.id.uuidString)])
        XCTAssertEqual(stored, [[.text("unfavorite"), .null, .text(#"{"kind":"user"}"#), .text(#"["A/L0/001"]"#), .text("{}")],
                                [.text("create"), .text(digest), .text(#"{"asset":"server-1","kind":"saveFromServer"}"#), .text(#"["D/L0/001"]"#), .text("{}")]])
        let saved = try await journal.records().first { $0.entry.id == save.id }
        XCTAssertEqual(saved?.entry.mutation, .create(still: nil, video: nil, pairedVideo: nil, origin: .saveFromServer(asset: "server-1", account: digest)),
                       "A save keeps no file names.")
        XCTAssertEqual(saved?.outcome, .committed(affected: [], created: [DeviceAssetID(rawValue: "D/L0/001")]))
    }

    // MARK: - Support

    private func entry(_ mutation: DeviceMutation, at seconds: TimeInterval) -> DeviceJournalEntry {
        DeviceJournalEntry(id: UUID(), mutation: mutation, createdAt: Date(timeIntervalSinceReferenceDate: seconds))
    }

    private func finishedCount(_ url: URL) throws -> Int {
        try DeviceSQLite(url: url).query("SELECT count(*) FROM device_mutation WHERE finished_at IS NOT NULL").first?.first?.real.map { Int($0) } ?? 0
    }
}

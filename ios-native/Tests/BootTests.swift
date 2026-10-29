import CryptoKit
import Foundation
import IlyichPlatform
import IlyichShareInbox
import Synchronization
import XCTest
@testable import Ilyich

/// The account's transfer runtime as the app boots it (architecture section 4) over a database
/// B9's import handed to the engine, with a fake OS: nothing already backed up is queued, hashed or
/// sent again, and an answer iOS already wrote is committed without a request. Since B10 the
/// state.json B9 left in place goes once nothing can need it, and only then: an upload an older
/// build started that iOS still holds, or a file an older build changed after the import, keeps
/// it, saying why. An account no import read yet has its file imported first, and comes back as
/// that build left it.
@MainActor final class BootTests: XCTestCase {
    private typealias G = LegacyGoldens
    private static let current = "Backup/\(G.digest)/\(G.currentFolder)"
    private static let state = "Backup/\(G.digest)/state.json"

    // MARK: Nothing backed up goes again

    /// The owner's phone holds tens of thousands of receipts, which B9 imported. A database at that
    /// scale starts with every receipt, confirmation, failure, album add and preference as the
    /// screens read them, and discovery over the same library queues only the photos never backed
    /// up and the ones edited since: no confirmed photo gets a job, and nothing is hashed, checked
    /// or sent.
    func testADatabaseAtScaleQueuesNothingAlreadyBackedUp() async throws {
        let golden = ScaleGolden()
        let h = try await BootHarness()
        addTeardownBlock { await h.tearDown() }
        try await h.store.seedForTest(golden.seed(), importedDigest: "state")
        let counts = try await h.store.albumUploadCounts()
        XCTAssertEqual(counts, [ScaleGolden.album: AlbumUploadCount(pending: 4, failed: 1)], "Four photos wait for the album; one's upload failed.")

        try await h.start()
        let engine = h.runtime.backend
        let failures = try await engine.failures(limit: 100)
        XCTAssertEqual(Set(failures.map(\.source)), Set(golden.failures.map { .photo(DeviceAssetID(rawValue: $0)) }))
        XCTAssertEqual(Set(failures.compactMap(\.displayName)), ["IMG_0.HEIC", "IMG_1.HEIC", "IMG_2.HEIC"])
        let preferences = try await engine.preferences()
        XCTAssertEqual(preferences, golden.seed().preferences)
        let queue = try await engine.queuePage(lane: .library, after: nil, limit: 100).map(\.source)
        XCTAssertEqual(queue, golden.queue.map { .photo(DeviceAssetID(rawValue: $0)) }, "The queue keeps its order.")
        let snapshot = await Self.first(await engine.snapshots())
        XCTAssertEqual(snapshot?.confirmed, golden.confirmed.count)
        XCTAssertEqual(snapshot?.remaining, golden.queue.count)
        XCTAssertEqual(snapshot?.failed, golden.failures.count)
        let history = try await engine.historyPage(offset: 0, limit: 3).map(\.localID.rawValue)
        XCTAssertEqual(history, [5_999, 5_998, 5_997].map(ScaleGolden.localID), "Confirmed uploads keep their order.")

        // The library as Photos has it now: everything backed up, the queue, two photos edited
        // since their backup and seven new ones.
        for (id, date) in golden.confirmed { h.staging.add(id, FakeStaging.Photo(modified: date)) }
        for id in golden.queue { h.staging.add(id, FakeStaging.Photo(modified: ScaleGolden.base)) }
        for id in golden.edited { h.staging.add(id, FakeStaging.Photo(modified: ScaleGolden.base.addingTimeInterval(86_400))) }
        let new = (0..<7).map { ScaleGolden.localID(900_000 + $0) }
        for id in new { h.staging.add(id, FakeStaging.Photo(modified: ScaleGolden.base)) }
        let merge = try await h.runtime.engine.discover(h.runtime.discovery)
        XCTAssertEqual(merge?.queued, new.count + golden.edited.count)

        let keys = Set(try await h.store.libraryJobKeys())
        XCTAssertEqual(keys, Set(golden.queue + new + golden.edited))
        let confirmedUnchanged = Set(golden.confirmed.keys).subtracting(golden.edited)
        XCTAssertTrue(keys.isDisjoint(with: confirmedUnchanged), "No photo already backed up gets a job.")
        XCTAssertTrue(h.server.checks.isEmpty, "Nothing is checked with the server.")
        XCTAssertTrue(h.staging.staged.isEmpty, "Nothing is staged or hashed.")
        XCTAssertTrue(h.backupSession.uploads.isEmpty, "Nothing is sent.")
        let receipts = try await h.store.cleanupReceipts()
        XCTAssertEqual(receipts.count, golden.receipts, "Cleanup and the device index read every receipt.")
    }

    /// BM5: an answer the delegate wrote while the app was gone finalizes the photo with no
    /// request at all.
    func testSuccessOutcomeFinalizesWithoutPost() async throws {
        let h = try await BootHarness()
        addTeardownBlock { await h.tearDown() }
        try await h.seedImportedGolden()
        try OutcomeRecord.encoded(OutcomeRecord(receipt: .init(id: G.originalAsset, status: "created"), httpStatus: 201, v: 2))
            .write(to: h.group.url(Self.current + "/\(G.currentStage).receipt"))

        try await h.start()
        let receipt = try await h.store.receipts(for: [G.l1])[G.l1]
        XCTAssertEqual(receipt?.original.id, G.originalAsset)
        XCTAssertTrue(h.backupSession.uploads.isEmpty)
        XCTAssertTrue(h.server.checks.isEmpty)
        XCTAssertFalse(h.group.exists(Self.current), "The committed stage goes.")
    }

    // MARK: Retiring state.json (B10)

    /// The state.json B9 imported and left in place goes at the first start once iOS holds no
    /// upload an older build started: the database holds everything it says (its digest is the
    /// one the import recorded). The database is untouched, the stages it refers to stay, and an
    /// older build's stage folder nothing refers to is swept. The next start finds nothing left.
    func testStateJSONGoesOnceTheEngineHoldsEverythingItSays() async throws {
        let h = try await BootHarness()
        addTeardownBlock { await h.tearDown() }
        let file = try h.writeState(FixtureLoader.data("backup/state-current.json"))
        try await h.seedImportedGolden(digest: file)
        let orphan = try h.writeOldStageFolder()
        let before = try await h.store.dump()

        try await h.start()
        XCTAssertEqual(h.runtime.legacyRetirement, .removed)
        XCTAssertFalse(h.group.exists(Self.state), "state.json is gone.")
        XCTAssertFalse(h.group.exists(orphan), "An older build's stage folder nothing refers to is swept.")
        XCTAssertTrue(h.group.exists(Self.current + "/original"), "A stage the database refers to stays.")
        let after = try await h.store.dump()
        XCTAssertEqual(after["receipts"], before["receipts"])
        XCTAssertEqual(after["confirmations"], before["confirmations"])
        XCTAssertEqual(after["meta"], before["meta"], "The import's record stays; nothing reads state.json again.")

        try await h.restart()
        XCTAssertEqual(h.runtime.legacyRetirement, .nothingLeft)
    }

    /// While iOS holds an upload an older build started, state.json stays and nothing is swept:
    /// recovery cancels the task, logged, and never sends its photo again by itself. Once iOS has
    /// let go of it, the next start removes the file.
    func testStateJSONStaysWhileIOSHoldsAnOlderBuildsUpload() async throws {
        let older = String(decoding: try FixtureLoader.data("backup/descriptor-backup.json"), as: UTF8.self)
        let h = try await BootHarness(backupTasks: [SessionTask(id: 7, description: older, state: .running, sent: 100, expected: 900)])
        addTeardownBlock { await h.tearDown() }
        let file = try h.writeState(FixtureLoader.data("backup/state-current.json"))
        try await h.seedImportedGolden(digest: file)
        let orphan = try h.writeOldStageFolder()

        try await h.start()
        XCTAssertEqual(h.backupSession.cancelled, [7], "The older build's upload is cancelled.")
        XCTAssertEqual(h.runtime.legacyRetirement, .kept(.olderUploads(1)))
        XCTAssertTrue(h.group.exists(Self.state))
        XCTAssertTrue(h.group.exists(orphan), "Nothing is swept while it is with iOS.")
        XCTAssertTrue(h.backupSession.uploads.isEmpty, "Its photo isn't sent again by recovery.")
        XCTAssertTrue(LegacyRetirement.Reason.olderUploads(1).text.hasPrefix("1 upload an older version started was still with iOS"))

        h.backupSession.forget(7)
        try await h.restart()
        XCTAssertEqual(h.runtime.legacyRetirement, .removed)
        XCTAssertFalse(h.group.exists(Self.state))
    }

    /// A state.json whose digest isn't the one the import recorded was written after it, which
    /// only an older build does: what it says isn't all in the database, so it stays, unread.
    func testAStateJSONAnOlderBuildChangedStays() async throws {
        let h = try await BootHarness()
        addTeardownBlock { await h.tearDown() }
        let imported = try FixtureLoader.data("backup/state-current.json")
        try await h.seedImportedGolden(digest: G.digest(of: imported))
        try h.writeState(FixtureLoader.data("backup/state-9780e9625.json"))

        try await h.start()
        XCTAssertEqual(h.runtime.legacyRetirement, .kept(.changedSinceImport))
        XCTAssertEqual(try Data(contentsOf: h.group.url(Self.state)), try FixtureLoader.data("backup/state-9780e9625.json"), "Never read or written.")
    }

    /// An account no import handed over (one a build before B9 signed out) has the state.json that
    /// build left imported before its engine starts (AccountRuntime.handOver), over the copy B1
    /// made while it backed up, as B9 did. It comes back as signing out left it: automatic backup
    /// off and paused, with the file's records, never uploading by itself as the copy's automatic
    /// backup and run would have it. The file then goes like any other, and that build's stage
    /// folders nothing refers to are swept.
    func testAnAccountNoImportReadComesBackAsSigningOutLeftIt() async throws {
        let h = try await BootHarness()
        addTeardownBlock { await h.tearDown() }
        var state = try FixtureLoader.decode(Legacy.BackupState.self, from: "backup/state-current.json")
        state.preferences?.automatic = false
        state.paused = true
        let file = try h.writeState(JSONEncoder().encode(state))
        // The copy is older: automatic backup on, a run under way, and the last photo not yet confirmed.
        var copy = G.importedSeed()
        copy.intent = .automatic
        copy.confirmations.removeLast()
        try await h.seedGolden(copy, digest: "older", mode: .shadow, engine: .legacy)
        let orphan = try h.writeOldStageFolder()

        let handed = await AccountRuntime.handOver(h.store, importing: LegacyBackupImporter(store: h.store, folder: h.backupFolder))
        XCTAssertEqual(handed, .engine)
        let meta = try await h.store.meta()
        XCTAssertEqual(meta.legacyImportMode, .authoritative)
        XCTAssertEqual(meta.legacyImportDigest, file)
        let preferences = try await h.store.preferences()
        XCTAssertEqual(preferences?.automatic, false, "As signing out left it, not as the copy had it.")
        let engineState = try await h.store.engineState()
        XCTAssertEqual(engineState?.intent, .paused)

        try await h.start()
        let snapshot = await Self.first(await h.runtime.backend.snapshots())
        XCTAssertEqual(snapshot?.intent, .paused, "Nothing uploads until the user starts it.")
        XCTAssertEqual(snapshot?.confirmed, 3, "The file's records.")
        XCTAssertEqual(h.runtime.legacyRetirement, .removed, "Imported, the file goes like any other.")
        XCTAssertFalse(h.group.exists(Self.state))
        XCTAssertFalse(h.group.exists(orphan), "That build's stage folders nothing refers to are swept.")
        XCTAssertTrue(h.group.exists(Self.current + "/original"), "A stage the file refers to stays.")
        XCTAssertTrue(h.backupSession.uploads.isEmpty)
    }

    /// Cleanup removals Photos committed before the cutover were kept only in the device journal:
    /// each marks its receipt when the receipt is still of the revision removed.
    func testCleanupRemovalsBeforeTheCutoverMarkTheirReceipts() async throws {
        let h = try await BootHarness()
        addTeardownBlock { await h.tearDown() }
        try await h.seedImportedGolden()
        let removed = Date(timeIntervalSinceReferenceDate: 790_000_000)
        func record(_ ids: [String], expected: [String: Date], account: String, outcome: DeviceMutationResult.Outcome?) -> DeviceJournalRecord {
            let assets = ids.map(DeviceAssetID.init(rawValue:))
            let revisions = Dictionary(uniqueKeysWithValues: expected.map { (DeviceAssetID(rawValue: $0.key), AssetRevision($0.value)) })
            return DeviceJournalRecord(entry: DeviceJournalEntry(id: UUID(), mutation: .delete(assets, expected: revisions, origin: .cleanup(scan: UUID(), account: account)),
                                                                 createdAt: removed),
                                       finishedAt: removed, outcome: outcome)
        }
        let records = [
            record([G.l2, G.l4], expected: [G.l2: G.Dates.l2, G.l4: Date(timeIntervalSinceReferenceDate: 1)], account: G.digest,
                   outcome: .committed(affected: [DeviceAssetID(rawValue: G.l2), DeviceAssetID(rawValue: G.l4)], created: [])),
            record([G.l5], expected: [:], account: "another-account", outcome: .committed(affected: [DeviceAssetID(rawValue: G.l5)], created: [])),
            record([G.l5], expected: [:], account: G.digest, outcome: .declined),
        ]
        let deletions = AccountRuntime.localDeletions(records, account: G.digest)
        XCTAssertEqual(deletions.map(\.localID), [G.l2, G.l4])
        let marked = try await h.store.markLocallyDeleted(deletions)
        XCTAssertEqual(marked, 1, "Only the receipt still of the revision removed.")
        let receipts = try await h.store.cleanupReceipts()
        XCTAssertEqual(receipts[G.l2]?.locallyDeleted, true)
        XCTAssertEqual(receipts[G.l4]?.locallyDeleted, false)
        let remarked = try await h.store.markLocallyDeleted(deletions)
        XCTAssertEqual(remarked, 0, "Idempotent.")
    }

    // MARK: Runs and sign-out

    /// Back up now asks for background windows even with automatic backup off (the owner's
    /// decision) while it runs, and ends once nothing is left, as today's run ends.
    func testManualRunAsksForWindowsAndEnds() async throws {
        let scheduler = RecordingWindowScheduler()
        let h = try await TransferEngineHarness(scheduler: scheduler)
        try await h.store.savePreferences(TransferPreferences())
        try await h.engine.start()
        await untilTransfers("The first plan.") { scheduler.plans == [.none] }
        let gate = TransferGate()
        h.executor.script("a", .hold(gate))
        _ = try await h.engine.enqueue([h.photo("a")])
        let run = Task { try await h.engine.runManually(nil) }
        await untilTransfers("The run asks for windows.") { scheduler.plans.count == 2 }
        XCTAssertEqual(scheduler.plans.last, .automatic(requireCharging: false, triggerDelay: 30))
        gate.open()
        _ = try await run.value
        await untilTransfers("The run ends with nothing left.") { await h.engine.currentSnapshot.intent == .paused }
        await untilTransfers("Its windows go.") { scheduler.plans.last == SchedulePlan.none }
        await h.tearDown()
    }

    /// A manual run whose last photo iOS finished while the app was gone ends once recovery
    /// commits it after the relaunch, as one this process ran does: with automatic backup off it
    /// pauses, and its windows go.
    func testAManualRunEndsWhenRecoveryCommitsItsLastPhoto() async throws {
        let scheduler = RecordingWindowScheduler()
        let h = try await TransferEngineHarness(scheduler: scheduler)
        try await h.store.savePreferences(TransferPreferences())
        _ = try await h.store.enqueue([h.photo("a")])
        // The photo's upload is with iOS, from the process before.
        let job = try await h.requireJob("a")
        let token = UUID()
        _ = try await h.store.lease(job: job.id, token: token)
        _ = try await h.store.advance(job: job.id, token: token, to: .submitted, phase: "original")
        try await h.store.release(job: job.id, token: token)
        try await h.store.saveEngineState(intent: .manual, blocker: nil, lastMessage: nil)
        try await h.engine.start()
        await untilTransfers("The run asks for windows while it waits.") { scheduler.plans.last == .automatic(requireCharging: false, triggerDelay: 30) }
        let waiting = await h.engine.currentSnapshot.intent
        XCTAssertEqual(waiting, .manual, "The run waits for its last photo.")

        // Recovery applies the outcome iOS kept, then tells the engine.
        let revision = AssetRevision(referenceSeconds: 700_000_000.25)
        let committed = try await h.store.complete(TransferCompletion(job: job.id, lease: nil, localID: "a", revision: revision, assetID: "asset-a",
                                                                      receipt: nil, confirmedAt: Date()))
        XCTAssertTrue(committed)
        await h.engine.refresh()
        await untilTransfers("The run ends with nothing left.") { await h.engine.currentSnapshot.intent == .paused }
        let saved = try await h.store.engineState()
        XCTAssertEqual(saved?.intent, .paused)
        await untilTransfers("Its windows go.") { scheduler.plans.last == SchedulePlan.none }
        await h.tearDown()
    }

    /// Back up selected and a share's Upload, for a file whose upload failed, retry it, as they
    /// always did; a discovery pass leaves a failed photo for the user.
    func testAskingAgainForAFailedFileRetriesIt() async throws {
        let h = try await TransferEngineHarness()
        h.executor.script("a", .fail { TransferItemFailure.rejected("Unsupported file type") })
        let selected = TransferRequest(source: .photo(DeviceAssetID(rawValue: "a")), origin: .selection)
        _ = try await h.engine.enqueue([selected])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("The photo fails.") { try await h.job("a")?.state == .failed }
        let found = try await h.store.enqueue([h.photo("a")])
        XCTAssertEqual(found.queued, 0, "Discovery leaves a failed photo for the user.")
        let failed = try await h.requireJob("a")
        XCTAssertEqual(failed.state, .failed)
        let again = try await h.engine.enqueue([selected])
        XCTAssertEqual(again, .queued(1))
        try await untilTransfers("Back up selected retries it.") { try await h.confirmed("a") }

        // The same for a shared file, with the engine stopped so that only the store acts.
        await h.engine.stop()
        let share = TransferRequest(source: .shared(batch: UUID(), attachment: "IMG_0001.JPG"), origin: .shareApproval)
        _ = try await h.store.enqueue([share])
        let shared = try await h.store.job(lane: .share, sourceKey: share.source.key)
        let shareJob = try XCTUnwrap(shared)
        let token = UUID()
        _ = try await h.store.lease(job: shareJob.id, token: token)
        _ = try await h.store.markFailed(job: shareJob.id, token: token, message: "The server rejected it.", at: Date())
        let retried = try await h.store.enqueue([share])
        XCTAssertEqual(retried.queued, 1, "Upload in Shared files retries a file that failed.")
        let requeued = try await h.store.job(lane: .share, sourceKey: share.source.key)
        XCTAssertEqual(requeued?.state, .queued)
        XCTAssertNil(requeued?.errorMessage)
        await h.tearDown()
    }

    /// The backup screen lists the phone's failed photos only, as it always did, beside its
    /// Remaining count; a shared file's failure shows in Shared files, from the share lane's queue.
    func testTheScreensListEachLanesFailuresWhereTheyAlwaysDid() async throws {
        let h = try await BootHarness()
        addTeardownBlock { await h.tearDown() }
        try await h.seedImportedGolden()
        let share = TransferRequest(source: .shared(batch: UUID(), attachment: "IMG_0002.JPG"), origin: .shareApproval)
        _ = try await h.store.enqueue([share])
        let shared = try await h.store.job(lane: .share, sourceKey: share.source.key)
        let shareJob = try XCTUnwrap(shared)
        let token = UUID()
        _ = try await h.store.lease(job: shareJob.id, token: token)
        _ = try await h.store.markFailed(job: shareJob.id, token: token, message: "The server rejected it.", at: Date())
        try await h.start()

        let failures = try await h.runtime.backend.failures(limit: 100)
        XCTAssertEqual(failures.map(\.source), [.photo(DeviceAssetID(rawValue: G.l3))], "The backup screen lists failed photos only.")
        let sharePage = try await h.runtime.backend.queuePage(lane: .share, after: nil, limit: 10)
        XCTAssertEqual(sharePage.map(\.state), [.failed])
        XCTAssertEqual(sharePage.first?.message, "The server rejected it.", "Shared files shows the file's error.")
    }

    /// Signing out switches automatic backup off and pauses (as every build did), cancels the
    /// account's tasks with iOS, and keeps the database and the staged copies (the owner's
    /// decision). Kept, as the sign-out policy may one day say, automatic backup stays on.
    func testSignOutKeepsStagedCopiesAndTheDatabase() async throws {
        XCTAssertFalse(SignOutPolicy(reason: .user).keepsAutomaticBackup, "Owner question: until it is answered, sign-out switches it off.")
        XCTAssertFalse(SignOutPolicy(reason: .sessionExpired).keepsAutomaticBackup)
        for keeping in [false, true] {
            let key = AttemptKey(attempt: AttemptID(legacy: G.currentStage), scope: G.digest, folder: Self.current)
            let h = try await BootHarness(backupTasks: [SessionTask(id: 7, description: key.descriptor.taskDescription, state: .running,
                                                                    sent: 100, expected: 900)])
            try await h.seedImportedGolden(automaticBackup: true)
            try await h.start()

            await h.runtime.signOut(keepingAutomaticBackup: keeping)
            await h.runtime.stop()
            XCTAssertEqual(h.backupSession.cancelled, [7], "The account's upload stops with its session.")
            let preferences = try await h.store.preferences()
            XCTAssertEqual(preferences?.automatic, keeping, "keeping: \(keeping): signing in again carries on as sign-out left it.")
            let state = try await h.store.engineState()
            XCTAssertEqual(state?.intent, .paused, "keeping: \(keeping)")
            XCTAssertTrue(h.group.exists(Self.current + "/original"), "The staged copy stays.")
            let kept = try await h.store.receipts(for: [G.l2])
            XCTAssertNotNil(kept[G.l2], "The records stay.")
            await h.tearDown()
        }
    }

    /// The backup screen counts failed photos in Remaining and words the status line as it
    /// always has, whichever engine runs.
    func testTheBackupScreenReadsTheEngineAsBefore() {
        var preferences = TransferPreferences()
        func shown(_ phase: TransferPhase, intent: RunIntent = .automatic, remaining: Int = 0, failed: Int = 0) -> TransferSnapshot {
            EngineBackend.presented(TransferSnapshot(intent: intent, phase: phase, remaining: remaining, confirmed: 5, failed: failed, fileProgress: nil,
                                                     bytesSent: 0, bytesExpected: 0, bytesPerSecond: nil, lastMessage: nil), preferences: preferences)
        }
        XCTAssertEqual(shown(.idle).activity, "Choose albums to back up")
        preferences.includedAlbums = ["album"]
        XCTAssertEqual(shown(.idle).activity, "Selected photos backed up")
        XCTAssertEqual(shown(.idle, failed: 2).activity, "2 uploads need retry")
        XCTAssertEqual(shown(.idle, failed: 2).remaining, 2, "Failed photos stay in the queue the screen lists.")
        XCTAssertEqual(shown(.idle, intent: .paused, remaining: 3).activity, "Backup paused")
        XCTAssertEqual(shown(.discovering).activity, "Finding new photos")
        XCTAssertEqual(shown(.blocked(.readOnly)).activity, "Backup paused")
        XCTAssertEqual(shown(.waiting(.deviceConditions)).activity, "Waiting for the device to cool down")
        preferences.requireCharging = true
        XCTAssertEqual(shown(.waiting(.deviceConditions)).activity, "Waiting for charging and a cool device")
    }

    // MARK: Support

    private static func first(_ stream: AsyncStream<TransferSnapshot>) async -> TransferSnapshot? {
        for await value in stream { return value }
        return nil
    }
}
// MARK: - A database at the owner's scale

/// What B9's import wrote for a state.json at the owner's scale: thousands of photos backed up,
/// some Live Photos, some confirmed without a receipt (Live Photos sent before their video's
/// checksum was kept), a queue with failures, album adds and linked albums.
struct ScaleGolden {
    static let count = 6_000
    static let base = Date(timeIntervalSinceReferenceDate: 650_000_000.125)
    static let album = "d4c3b2a1-0f9e-4d8c-b7a6-958473625141"

    let confirmed: [String: Date]
    let queue: [String]
    let failures: [String]
    let edited: [String]
    let receipts: Int

    init() {
        var confirmed: [String: Date] = [:]
        for index in 0..<Self.count {
            confirmed[Self.localID(index)] = Self.base.addingTimeInterval(Double(index) * 1_234.567_891)
        }
        self.confirmed = confirmed
        queue = (0..<20).map { Self.localID(500_000 + $0) }
        failures = [queue[3], queue[11], queue[17]]
        edited = [Self.localID(42), Self.localID(4_242)]
        receipts = (0..<Self.count).filter { $0 % 50 != 7 }.count
    }

    static func localID(_ index: Int) -> String { String(format: "%08X-1D2C-4B3A-8F9E-%012X/L0/001", index, index &* 7_919) }
    static func assetID(_ index: Int) -> String { String(format: "%08x-5a6b-4c7d-8e9f-%012x", index, index &* 104_729) }

    func seed() -> TransferSeed {
        var preferences = TransferPreferences()
        preferences.includedAlbums = [FakeStaging.album]
        preferences.cellularPhotos = true
        preferences.triggerDelay = 60
        preferences.syncAlbums = true
        var seed = TransferSeed()
        seed.preferences = preferences
        seed.intent = .paused
        seed.confirmations = confirmed.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        for index in 0..<Self.count where index % 50 != 7 {
            let id = Self.localID(index)
            let video = index % 10 == 3
            seed.receipts.append(.init(localID: id, modified: confirmed[id]!, originalID: Self.assetID(index), originalChecksum: "c\(index)=",
                                       originalBytes: index % 3 == 0 ? Int64(index) * 1_000 : nil,
                                       motionID: video ? Self.assetID(1_000_000 + index) : nil, motionChecksum: video ? "m\(index)=" : nil,
                                       confirmedAt: Self.base.addingTimeInterval(86_400 + Double(index) * 61.25)))
        }
        seed.jobs = queue.map { id in
            guard let offset = failures.firstIndex(of: id) else { return TransferSeed.Job(localID: id) }
            return TransferSeed.Job(localID: id, state: .failed, failure: .init(
                message: "The server rejected IMG_\(offset).HEIC. Check its supported file formats.",
                date: Self.base.addingTimeInterval(Double(offset) * 3_600.5), filename: "IMG_\(offset).HEIC"))
        }
        // Album adds of photos backed up already take their receipt's server ID; queued ones wait.
        seed.destinations = [(Self.localID(10), Self.album, Self.assetID(10)), (Self.localID(11), Self.album, Self.assetID(11)),
                             (queue[0], Self.album, nil), (queue[3], Self.album, nil)]
        seed.linkedAlbums = [(FakeStaging.album, Self.album)]
        return seed
    }
}

// MARK: - Harness

/// One account's transfers database, its Backup folder in a throwaway App Group, fake background
/// sessions, and the TransferRuntime the app would start over them.
@MainActor final class BootHarness {
    let group: TemporaryAppGroup
    let folder: URL
    let store: TransferStore
    let backupSession: FakeTransportSession
    let shareSession: FakeTransportSession
    let registry: TransportRegistry
    let staging = FakeStaging()
    let server = FakeTransferServer()
    let authorization = FakeTransferAuthorization()
    let acknowledged = Locked<[String]>([])
    let poster = FakeNotificationPoster()
    private(set) var runtime: TransferRuntime!
    private var forwarding: Task<Void, Never>?

    var backupFolder: URL { group.url(AccountStoragePaths(LegacyGoldens.account).backup) }

    init(backupTasks: [SessionTask] = []) async throws {
        group = try TemporaryAppGroup()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Boot-" + UUID().uuidString, isDirectory: true)
        store = TransferStore(url: folder.appendingPathComponent("transfers.sqlite"))
        try FileManager.default.createDirectory(at: group.url(AccountStoragePaths(LegacyGoldens.account).backup), withIntermediateDirectories: true)
        let backupSession = FakeTransportSession(tasks: backupTasks), shareSession = FakeTransportSession()
        self.backupSession = backupSession
        self.shareSession = shareSession
        let journal = group.journal
        registry = TransportRegistry { session, emit in
            BackgroundTransport(session: session, journal: journal, emit: emit, uptime: { .zero }) {
                (session == .backup ? backupSession : shareSession).attach($0)
            }
        }
    }

    /// The database as B9's import of the golden state.json left it, with the stages' files where
    /// it says they are, and backup paused, so that only recovery acts. `digest` is the
    /// state.json's the import recorded; `automaticBackup` keeps the preference on.
    func seedImportedGolden(digest: String = "state", mode: TransferStore.ImportMode = .authoritative,
                            engine: TransferStore.Engine = .transfer, automaticBackup: Bool = false) async throws {
        var seed = LegacyGoldens.importedSeed()
        seed.preferences.automatic = automaticBackup
        seed.intent = .paused
        try await seedGolden(seed, digest: digest, mode: mode, engine: engine)
    }

    /// `seed`, a variation of the golden rows, written as is, with the golden stages' files where
    /// it says they are.
    func seedGolden(_ seed: TransferSeed, digest: String, mode: TransferStore.ImportMode, engine: TransferStore.Engine) async throws {
        try await store.seedForTest(seed, importedDigest: digest, mode: mode, engine: engine)
        let current = "Backup/\(LegacyGoldens.digest)/\(LegacyGoldens.currentFolder)"
        try group.write("still of IMG_0001", to: current + "/original")
        try group.write("video of IMG_0001", to: current + "/motion")
        try group.write("<xmp/>", to: current + "/sidecar")
        try group.write("video IMG_0006", to: "Backup/\(LegacyGoldens.digest)/\(LegacyGoldens.suspendedFolder)/original")
    }

    /// Writes the account's state.json as an older build left it, and returns its digest.
    @discardableResult
    func writeState(_ data: Data) throws -> String {
        try data.write(to: backupFolder.appendingPathComponent("state.json"), options: .atomic)
        return LegacyGoldens.digest(of: data)
    }

    /// A stage folder an older build left that nothing refers to, changed an hour ago: past the
    /// sweep's grace. Returns its path in the App Group.
    func writeOldStageFolder() throws -> String {
        let path = "Backup/\(LegacyGoldens.digest)/\(UUID().uuidString)"
        try group.write("an older build's copy", to: path + "/original")
        let earlier = Date().addingTimeInterval(-3_600)
        for item in [path + "/original", path] {
            try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: group.url(item).path)
        }
        return path
    }

    /// Starts the runtime as TransferHost does, routing the sessions' events to it.
    func start() async throws {
        let acknowledged = self.acknowledged
        let parts = TransferRuntime.Parts(
            account: LegacyGoldens.account, store: store, authorization: authorization, server: server, registry: registry,
            layout: group.layout, inbox: ShareInboxRepository(root: group.url("ShareInbox")), staging: staging,
            scheduler: RecordingWindowScheduler(), time: FakeBackgroundTime(), appActive: true, preSync: nil,
            acknowledge: { session, drain in acknowledged.mutate { $0.append("\(session.rawValue):\(drain)") } },
            conditionsPermit: { _ in true }, poster: poster)
        let runtime = TransferRuntime(parts)
        self.runtime = runtime
        if forwarding == nil {
            // One stream for the registry's life: each event goes to the runtime running then.
            let events = registry.events
            forwarding = Task { [weak self] in for await event in events { self?.runtime?.receive(event) } }
        }
        registry.connect()
        try await runtime.start()
    }

    /// The app's next start: the runtime ends, and a new one starts over the same database and sessions.
    func restart() async throws {
        await runtime?.stop()
        try await start()
    }

    func tearDown() async {
        await runtime?.stop()
        forwarding?.cancel()
        await store.close()
        group.remove()
        try? FileManager.default.removeItem(at: folder)
    }
}

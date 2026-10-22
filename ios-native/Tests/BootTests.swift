import CryptoKit
import Foundation
import IlyichPlatform
import IlyichShareInbox
import Synchronization
import XCTest
@testable import Ilyich

/// The cutover to the transfer engine (rebuild milestone B9), with a fake OS: the account's
/// state.json imported authoritatively, then the account's TransferRuntime started over fake
/// background sessions, as the app boots it (architecture section 4). Nothing already backed up is
/// queued, hashed or sent again; an upload iOS still holds from the earlier build is adopted, and
/// an answer it already wrote is committed without a request.
@MainActor final class BootTests: XCTestCase {
    private typealias G = LegacyGoldens
    private static let current = "Backup/\(G.digest)/\(G.currentFolder)"

    // MARK: Nothing backed up goes again

    /// The owner's phone holds tens of thousands of receipts. A state.json at that scale, built the
    /// way BackupCoordinator writes it and pinned by its digest, imports with every receipt,
    /// confirmation, failure, album add and preference, and the backup screens read what they read
    /// from today's backup. Discovery over the same library then queues only the photos never
    /// backed up and the ones edited since: no confirmed photo gets a job, and nothing is hashed,
    /// checked or sent.
    func testGoldenStateAtScaleQueuesNothingAlreadyBackedUp() async throws {
        let golden = ScaleGolden()
        let data = try golden.encoded()
        XCTAssertEqual(LegacyBackupImporter.digest(data), ScaleGolden.digest, "The golden state.json is the one pinned.")
        let h = try await BootHarness(state: data)
        addTeardownBlock { await h.tearDown() }

        let report = try await h.imported()
        XCTAssertEqual(report.outcome, .imported)
        XCTAssertEqual(report.comparison?.total, 0, report.summary)
        XCTAssertEqual(report.comparison?.compared[.receipts], golden.receipts)
        XCTAssertEqual(report.comparison?.compared[.confirmations], golden.confirmed.count)
        let meta = try await h.store.meta()
        XCTAssertEqual(meta.engine, .transfer)
        XCTAssertTrue(h.group.exists("Backup/\(G.digest)/state.json"), "state.json stays where it is, for the way back.")

        try await h.start()
        // The backup screens read the same as from today's backup.
        let legacy = try h.legacyBackend()
        let engine = h.runtime.backend
        let legacyFailures = try await legacy.failures(limit: 100).map(Self.shown)
        let engineFailures = try await engine.failures(limit: 100).map(Self.shown)
        XCTAssertEqual(engineFailures, legacyFailures)
        let legacyCounts = try await legacy.albumUploadCounts()
        let engineCounts = try await engine.albumUploadCounts()
        XCTAssertEqual(engineCounts, legacyCounts)
        let legacyPreferences = try await legacy.preferences()
        let enginePreferences = try await engine.preferences()
        XCTAssertEqual(enginePreferences, legacyPreferences)
        let legacyQueue = try await legacy.queuePage(lane: .library, after: nil, limit: 100).map(\.source)
        let engineQueue = try await engine.queuePage(lane: .library, after: nil, limit: 100).map(\.source)
        XCTAssertEqual(engineQueue, legacyQueue)
        let snapshot = await Self.first(await engine.snapshots())
        XCTAssertEqual(snapshot?.confirmed, golden.confirmed.count)
        XCTAssertEqual(snapshot?.remaining, golden.queue.count)
        XCTAssertEqual(snapshot?.failed, golden.failures.count)
        let history = try await engine.historyPage(offset: 0, limit: 3).map(\.localID.rawValue)
        let legacyHistory = try await legacy.historyPage(offset: 0, limit: 3).map(\.localID.rawValue)
        XCTAssertEqual(history, legacyHistory, "Confirmed uploads keep their order.")

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

    /// Today's backup marks itself paused at the end of every run and starts again whenever
    /// automatic backup is on, so automatic backup on is the automatic intent, run or not; with it
    /// off a run under way is manual, and anything else paused.
    func testRunIntentFollowsTodaysBackup() {
        func intent(automatic: Bool, paused: Bool?) -> RunIntent {
            var state = Legacy.BackupState()
            var preferences = Legacy.BackupPreferences()
            preferences.automatic = automatic
            state.preferences = preferences
            state.paused = paused
            return LegacyBackupPlan.intent(state)
        }
        XCTAssertEqual(intent(automatic: true, paused: true), .automatic, "Idle automatic backup keeps running.")
        XCTAssertEqual(intent(automatic: true, paused: false), .automatic)
        XCTAssertEqual(intent(automatic: false, paused: false), .manual)
        XCTAssertEqual(intent(automatic: false, paused: true), .paused)
        XCTAssertEqual(intent(automatic: false, paused: nil), .paused)
    }

    // MARK: Uploads in flight at the update

    /// The earlier build's upload of the current photo is still with iOS: the runtime binds it by
    /// its stage ID and waits, never sending it again. When iOS finishes it, the answer the new
    /// delegate writes commits the photo, and only then is iOS told its events are handled.
    func testInFlightLegacyTaskIsAdoptedAndItsDrainAcknowledgedAfterCommit() async throws {
        let descriptor = String(decoding: try FixtureLoader.data("backup/descriptor-backup.json"), as: UTF8.self)
        let h = try await BootHarness(state: try JSONEncoder().encode(Self.pausedGolden()),
                                      backupTasks: [SessionTask(id: 7, description: descriptor, state: .running, sent: 100, expected: 900)])
        addTeardownBlock { await h.tearDown() }
        try h.writeGoldenStages()
        let imported = try await h.imported()
        XCTAssertEqual(imported.outcome, .imported)

        try await h.start()
        let bound = try await h.store.job(lane: .library, sourceKey: G.l1)
        XCTAssertEqual(bound?.state, .submitted, "The photo waits for the task iOS holds.")
        XCTAssertTrue(h.backupSession.uploads.isEmpty)
        XCTAssertTrue(h.backupSession.cancelled.isEmpty)

        _ = h.backupSession.handler.task(7, didReceive: Data(#"{"id":"\#(G.originalAsset)","status":"created"}"#.utf8))
        h.backupSession.handler.taskDidComplete(CompletedTask(id: 7, description: descriptor, httpStatus: 201, failure: nil))
        h.backupSession.forget(7)
        h.backupSession.handler.sessionDidFinishEvents()

        try await untilTransfers("The answer commits the photo.") { try await h.store.receipts(for: [G.l1])[G.l1] != nil }
        await untilTransfers("iOS hears back once it is committed.") { h.acknowledged.value == ["backup:1"] }
        let receipt = try await h.store.receipts(for: [G.l1])[G.l1]
        XCTAssertEqual(receipt?.original.id, G.originalAsset)
        XCTAssertTrue(h.backupSession.uploads.isEmpty, "The photo went once.")
        XCTAssertTrue(h.server.checks.filter { $0.id == G.l1 }.isEmpty, "Its answer needed no check.")
    }

    /// BM5: an answer the earlier build's delegate wrote before the update finalizes the photo
    /// with no request at all.
    func testSuccessOutcomeFinalizesWithoutPost() async throws {
        let h = try await BootHarness(state: try JSONEncoder().encode(Self.pausedGolden()))
        addTeardownBlock { await h.tearDown() }
        try h.writeGoldenStages()
        try FixtureLoader.data("backup/outcome-created.json").write(to: h.group.url(Self.current + "/\(G.currentStage).receipt"))
        let imported = try await h.imported()
        XCTAssertEqual(imported.outcome, .imported)

        try await h.start()
        let receipt = try await h.store.receipts(for: [G.l1])[G.l1]
        XCTAssertEqual(receipt?.original.id, G.originalAsset)
        XCTAssertTrue(h.backupSession.uploads.isEmpty)
        XCTAssertTrue(h.server.checks.isEmpty)
        XCTAssertFalse(h.group.exists(Self.current), "The committed stage goes.")
    }

    // MARK: Import

    /// BM1: importing twice changes nothing, and so does an app that ended right after the
    /// import committed. state.json is never renamed or removed: an earlier build reinstalled
    /// finds it (the critic's correction for B9).
    func testImportingTwiceIsANoOpAndAnEndAfterCommitLeavesTheFile() async throws {
        let h = try await BootHarness(state: try JSONEncoder().encode(Self.pausedGolden()))
        addTeardownBlock { await h.tearDown() }
        let crashed = await LegacyBackupImporter(mode: .authoritative, store: h.store, folder: h.backupFolder, crashingAt: .afterCommit).run()
        XCTAssertNil(crashed, "The app ended right after the commit.")
        let first = try await h.store.dump()
        let again = try await h.imported()
        XCTAssertEqual(again.outcome, .unchanged)
        XCTAssertEqual(again.comparison?.total, 0)
        let third = try await h.imported()
        XCTAssertEqual(third.outcome, .unchanged)
        let after = try await h.store.dump()
        XCTAssertEqual(after.filter { $0.key != "meta" }, first.filter { $0.key != "meta" }, "No row is added twice.")
        XCTAssertEqual(try h.backupFolderContents(), ["state.json"])
    }

    /// BM8: an earlier build reinstalled over this one backs up from the state.json left in place;
    /// back on this build, what it did is merged and what the engine did is kept.
    func testAReinstalledOldBuildsStateMerges() async throws {
        let h = try await BootHarness(state: try JSONEncoder().encode(Self.pausedGolden()))
        addTeardownBlock { await h.tearDown() }
        let imported = try await h.imported()
        XCTAssertEqual(imported.outcome, .imported)
        // The engine backed up a photo after the cutover.
        _ = try await h.store.enqueue([TransferRequest(source: .photo(DeviceAssetID(rawValue: "engine-photo")), origin: .discovery, revision: nil)])
        let stored = try await h.store.job(lane: .library, sourceKey: "engine-photo")
        let job = try XCTUnwrap(stored)
        let revision = AssetRevision(referenceSeconds: 790_000_000.5)
        let completed = try await h.store.complete(TransferCompletion(
            job: job.id, lease: nil, localID: "engine-photo", revision: revision, assetID: "engine-asset",
            receipt: TransferReceipt(localID: "engine-photo", revision: revision, original: RemoteCopy(id: "engine-asset", checksum: "e="), motion: nil,
                                     confirmedAt: nil), confirmedAt: Date(timeIntervalSinceReferenceDate: 790_000_100)))
        XCTAssertTrue(completed)

        // The older build backed up l3 and found another photo to queue.
        var older = Self.pausedGolden()
        let l3Date = Date(timeIntervalSinceReferenceDate: 783_000_000.75)
        older.confirmed[G.l3] = l3Date
        older.receipts?[G.l3] = BackupReceipt(modificationDate: l3Date, original: BackupRemoteFile(id: "old-build-asset", checksum: "o="),
                                              confirmedAt: Date(timeIntervalSinceReferenceDate: 783_000_100))
        older.queue = [G.l1, G.l6, "older-new-photo"]
        try h.writeState(JSONEncoder().encode(older))

        let merge = try await h.imported()
        XCTAssertEqual(merge.outcome, .merged)
        let receipts = try await h.store.receipts(for: [G.l3, "engine-photo", G.l2])
        XCTAssertEqual(receipts[G.l3]?.original.id, "old-build-asset", "What the older build backed up is kept.")
        XCTAssertEqual(receipts["engine-photo"]?.original.id, "engine-asset", "What the engine backed up is kept.")
        XCTAssertNotNil(receipts[G.l2])
        let l3Job = try await h.store.job(lane: .library, sourceKey: G.l3)
        XCTAssertNil(l3Job, "A photo the older build backed up leaves the queue.")
        let queued = try await h.store.job(lane: .library, sourceKey: "older-new-photo")
        XCTAssertEqual(queued?.state, .queued)
        let again = try await h.imported()
        XCTAssertEqual(again.outcome, .unchanged, "It merges once.")
    }

    /// BM8, after a rollback and re-upgrade: the older build's state.json lists every photo
    /// backed up before the cutover too. A photo the engine queued again since (an edit, Back up
    /// selected) keeps its job, since that build confirmed nothing newer of it; an album add for a
    /// photo with a job waits for that upload's copy rather than the one its receipt names.
    func testAMergeKeepsWhatTheEngineQueuedSinceTheCutover() async throws {
        let h = try await BootHarness(state: try JSONEncoder().encode(Self.pausedGolden()))
        addTeardownBlock { await h.tearDown() }
        let imported = try await h.imported()
        XCTAssertEqual(imported.outcome, .imported)
        // l2 was backed up before the cutover; edited since, it is queued again.
        _ = try await h.store.enqueue([TransferRequest(source: .photo(DeviceAssetID(rawValue: G.l2)), origin: .selection)])

        // The older build didn't upload l2; it added it to an album.
        var older = Self.pausedGolden()
        older.pendingAlbumAdds?[G.l2] = [G.otherServerAlbum]
        try h.writeState(JSONEncoder().encode(older))
        let merge = try await h.imported()
        XCTAssertEqual(merge.outcome, .merged)
        let job = try await h.store.job(lane: .library, sourceKey: G.l2)
        XCTAssertEqual(job?.state, .queued, "The edit queued since the cutover is still backed up.")
        let destinations = try await h.store.albumDestinations()
        let add = destinations.first { $0.localID == G.l2 && $0.albumID == G.otherServerAlbum }
        XCTAssertNotNil(add)
        XCTAssertNil(add?.remoteID, "The album gets the copy l2's upload makes, not the one from before the edit.")
    }

    /// Cleanup removals Photos committed before the cutover were kept only in the device journal:
    /// each marks its receipt when the receipt is still of the revision removed.
    func testCleanupRemovalsBeforeTheCutoverMarkTheirReceipts() async throws {
        let h = try await BootHarness(state: try JSONEncoder().encode(Self.pausedGolden()))
        addTeardownBlock { await h.tearDown() }
        let imported = try await h.imported()
        XCTAssertEqual(imported.outcome, .imported)
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
        try await h.store.savePreferences(TransferPreferences(Legacy.BackupPreferences()))
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
        try await h.store.savePreferences(TransferPreferences(Legacy.BackupPreferences()))
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
        let h = try await BootHarness(state: try JSONEncoder().encode(Self.pausedGolden()))
        addTeardownBlock { await h.tearDown() }
        _ = try await h.imported()
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
    /// decision).
    func testSignOutKeepsStagedCopiesAndTheDatabase() async throws {
        let descriptor = String(decoding: try FixtureLoader.data("backup/descriptor-backup.json"), as: UTF8.self)
        let h = try await BootHarness(state: try JSONEncoder().encode(Self.pausedGolden()),
                                      backupTasks: [SessionTask(id: 7, description: descriptor, state: .running, sent: 100, expected: 900)])
        addTeardownBlock { await h.tearDown() }
        try h.writeGoldenStages()
        let imported = try await h.imported()
        XCTAssertEqual(imported.outcome, .imported)
        try await h.start()

        await h.runtime.signOut(keepingAutomaticBackup: false)
        await h.runtime.stop()
        XCTAssertEqual(h.backupSession.cancelled, [7], "The account's upload stops with its session.")
        let preferences = try await h.store.preferences()
        XCTAssertEqual(preferences?.automatic, false)
        let state = try await h.store.engineState()
        XCTAssertEqual(state?.intent, .paused)
        XCTAssertTrue(h.group.exists(Self.current + "/original"), "The staged copy stays.")
        let kept = try await h.store.receipts(for: [G.l2])
        XCTAssertNotNil(kept[G.l2], "The records stay.")
    }

    /// The backup screen counts failed photos in Remaining and words the status line as it
    /// always has, whichever engine runs.
    func testTheBackupScreenReadsTheEngineAsBefore() {
        var preferences = TransferPreferences(Legacy.BackupPreferences())
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

    /// The golden state with backup idle and automatic backup off, so the engine's loop leaves
    /// the queue alone and only recovery acts.
    private static func pausedGolden() -> BackupState {
        var state = G.backupState()
        state.preferences.automatic = false
        state.paused = true
        return state
    }

    private static func shown(_ item: TransferQueueItem) -> [String?] {
        [item.displayName, item.message, item.failedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) }, "\(item.source)"]
    }

    private static func first(_ stream: AsyncStream<TransferSnapshot>) async -> TransferSnapshot? {
        for await value in stream { return value }
        return nil
    }
}

// MARK: - The golden state at scale

/// A state.json at the owner's scale: thousands of photos backed up, some Live Photos, some
/// confirmed without a receipt (Live Photos sent before their video's checksum was kept), a queue
/// with failures, album adds and linked albums. Encoded with sorted keys, so its bytes, pinned by
/// their digest, never change; BackupCoordinator writes the same keys in its own order.
struct ScaleGolden {
    static let count = 6_000
    static let base = Date(timeIntervalSinceReferenceDate: 650_000_000.125)
    static let digest = "89881d5ba4cc38e6fe202d00d8dc84f47ee204a7545e40216054e663c7d26a23"
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

    func state() -> BackupState {
        var preferences = BackupPreferences()
        preferences.includedAlbums = [FakeStaging.album]
        preferences.cellularPhotos = true
        preferences.triggerDelay = 60
        preferences.syncAlbums = true
        var state = BackupState()
        state.preferences = preferences
        state.confirmed = confirmed
        var receipts: [String: BackupReceipt] = [:]
        for index in 0..<Self.count where index % 50 != 7 {
            let id = Self.localID(index)
            let motion = index % 10 == 3 ? BackupRemoteFile(id: Self.assetID(1_000_000 + index), checksum: "m\(index)=") : nil
            receipts[id] = BackupReceipt(modificationDate: confirmed[id]!, original: BackupRemoteFile(id: Self.assetID(index), checksum: "c\(index)=",
                                                                                                        byteCount: index % 3 == 0 ? Int64(index) * 1_000 : nil),
                                         motion: motion, confirmedAt: Self.base.addingTimeInterval(86_400 + Double(index) * 61.25))
        }
        state.receipts = receipts
        state.queue = queue
        var failures: [String: BackupFailure] = [:]
        for (offset, id) in self.failures.enumerated() {
            failures[id] = BackupFailure(id: id, filename: "IMG_\(offset).HEIC", message: "The server rejected IMG_\(offset).HEIC. Check its supported file formats.",
                                         date: Self.base.addingTimeInterval(Double(offset) * 3_600.5))
        }
        state.failures = failures
        state.pendingAlbumAdds = [Self.localID(10): [Self.album], Self.localID(11): [Self.album], queue[0]: [Self.album], queue[3]: [Self.album]]
        state.linkedAlbums = [FakeStaging.album: Self.album]
        state.paused = true
        return state
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(state())
    }
}

// MARK: - Harness

/// One account's transfers database, state.json in a throwaway App Group, fake background
/// sessions, and the TransferRuntime the app would start over them.
@MainActor final class BootHarness {
    let group: TemporaryAppGroup
    let folder: URL
    let store: TransferStore
    let importer: LegacyBackupImporter
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

    init(state: Data?, backupTasks: [SessionTask] = []) async throws {
        group = try TemporaryAppGroup()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Boot-" + UUID().uuidString, isDirectory: true)
        store = TransferStore(url: folder.appendingPathComponent("transfers.sqlite"))
        let backup = group.url(AccountStoragePaths(LegacyGoldens.account).backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        if let state { try state.write(to: backup.appendingPathComponent("state.json"), options: .atomic) }
        importer = LegacyBackupImporter(mode: .authoritative, store: store, folder: backup)
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

    /// Runs the import, as the account's runtime does when backup starts.
    func imported(file: StaticString = #filePath, line: UInt = #line) async throws -> LegacyImportReport {
        let report = await importer.run()
        return try XCTUnwrap(report, file: file, line: line)
    }

    func writeState(_ data: Data) throws {
        try data.write(to: backupFolder.appendingPathComponent("state.json"), options: .atomic)
    }

    func backupFolderContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: backupFolder.path).sorted()
    }

    /// The golden state's staged files, where state.json says they are.
    func writeGoldenStages() throws {
        let current = "Backup/\(LegacyGoldens.digest)/\(LegacyGoldens.currentFolder)"
        try group.write("still of IMG_0001", to: current + "/original")
        try group.write("video of IMG_0001", to: current + "/motion")
        try group.write("<xmp/>", to: current + "/sidecar")
        try group.write("video IMG_0006", to: "Backup/\(LegacyGoldens.digest)/\(LegacyGoldens.suspendedFolder)/original")
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
        let events = registry.events
        forwarding = Task { for await event in events { runtime.receive(event) } }
        registry.connect()
        try await runtime.start()
    }

    /// Today's backup over the same state.json, for comparing what the screens read.
    func legacyBackend() throws -> LegacyCoordinatorBackend {
        let coordinator = BackupCoordinator()
        try coordinator.load(LegacyGoldens.credential, folder: backupFolder)
        return LegacyCoordinatorBackend(coordinator: coordinator, inbox: ShareInboxStore())
    }

    func tearDown() async {
        await runtime?.stop()
        forwarding?.cancel()
        await store.close()
        group.remove()
        try? FileManager.default.removeItem(at: folder)
    }
}

import Foundation
import IlyichPlatform
import Synchronization
import XCTest
@testable import Ilyich

/// The library job executor, discovery and the pipeline (B3), on the transfer engine with fake
/// Photos, a fake server and a fake transport.
final class LibraryJobTests: XCTestCase {
    // MARK: Parts

    /// A Live Photo's video goes first, hidden and without the mobile-app metadata; the still
    /// follows with livePhotoVideoId, and the receipt keeps both. Every check names the photo's
    /// local identifier, every body its attempt, and a retry of the still sends the video no more.
    func testMotionHiddenThenStillPaired() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("live", FakeStaging.Photo(modified: FakeStaging.date, isLive: true))
        // The still fails once on the server; the retry must pair it with the same video.
        h.uploads.answer("live.HEIC", .status(503))
        try await h.run("live")
        try await untilTransfers("The still waits for its retry.") { try await h.job("live")?.state == .retryScheduled }
        h.clock.advance(by: .seconds(31))
        try await untilTransfers("The Live Photo is backed up.") { try await h.receipt("live") != nil }

        let motion = h.uploads.uploads(of: "live-live.MOV")
        let stills = h.uploads.uploads(of: "live.HEIC")
        XCTAssertEqual(motion.count, 1, "The video is sent once, even though the still was sent twice.")
        XCTAssertEqual(stills.count, 2)
        XCTAssertEqual(h.uploads.uploads.first?.filename, "live-live.MOV", "The video goes first.")
        XCTAssertEqual(motion.first?.fields["visibility"], "hidden")
        XCTAssertNil(motion.first?.fields["metadata"], "The video carries no mobile-app metadata.")
        XCTAssertNil(motion.first?.fields["livePhotoVideoId"])
        let receipt = try await h.receipt("live")
        let motionID = try XCTUnwrap(receipt?.motion?.id)
        XCTAssertEqual(stills.map { $0.fields["livePhotoVideoId"] }, [motionID, motionID], "Both tries pair the still with the one video.")
        XCTAssertNotNil(stills.first?.fields["metadata"], "The still keeps its metadata.")
        XCTAssertNil(stills.first?.fields["visibility"])
        for upload in h.uploads.uploads { XCTAssertEqual(upload.boundary, "Ilyich-" + upload.key.attempt.rawValue) }
        XCTAssertNotEqual(stills[0].key.attempt, stills[1].key.attempt, "A failed attempt is not sent again; the retry makes a new one.")
        XCTAssertEqual(Set(h.server.checks.map(\.id)), ["live"], "Every check names the local identifier.")
        let checksums = Set(h.server.checks.map(\.checksum))
        XCTAssertEqual(checksums.count, 2, "One checksum for the video, one for the still.")
        XCTAssertEqual(Set([receipt?.original.checksum, receipt?.motion?.checksum].compactMap { $0 }), checksums)
        XCTAssertEqual(receipt?.revision, AssetRevision(FakeStaging.date))
        XCTAssertEqual(h.staging.stagings("live"), 1, "The retry resumes from its stage.")
        let stages = try await h.dump("stages")
        XCTAssertTrue(stages.isEmpty, "The commit removes the stage.")
        await untilTransfers("The stage's files go after the commit.") {
            (try? FileManager.default.contentsOfDirectory(atPath: h.group.url(AccountStoragePaths(LibraryJobHarness.account).backup).path))?.isEmpty ?? true
        }
        await h.tearDown()
    }

    /// The video's server ID, once known, is kept with the stage: a job resumed after it, from a
    /// crash or an earlier build, pairs the still with it and never sends the video again.
    func testMotionIDIsReusedAcrossACrash() async throws {
        let h = try await LibraryJobHarness()
        try await h.seed("live") { folder in
            LibraryStage(stageID: UUID().uuidString, folder: folder, revision: AssetRevision(FakeStaging.date),
                         original: try! h.stagedFile(folder, "original", filename: "live.HEIC", contents: "still"),
                         motion: try! h.stagedFile(folder, "motion", filename: "live.MOV", contents: "video"), sidecar: nil,
                         fields: ["isFavorite": "false"], isVideo: false, motionRemoteID: "motion-1", motionChecksum: "motion-sum")
        }
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("The still is backed up.") { try await h.receipt("live") != nil }
        XCTAssertEqual(h.uploads.uploads.map(\.filename), ["live.HEIC"])
        XCTAssertEqual(h.uploads.uploads.first?.fields["livePhotoVideoId"], "motion-1")
        let receipt = try await h.receipt("live")
        XCTAssertEqual(receipt?.motion, RemoteCopy(id: "motion-1", checksum: "motion-sum"))
        XCTAssertEqual(h.staging.staged.count, 0, "Nothing is staged again.")
        await h.tearDown()
    }

    /// A duplicate with an XMP sidecar counts only when this job's own attempt was answered
    /// created with that ID; anyone else's copy, or an answer of duplicate, fails the photo.
    func testXMPDuplicateOnlyForOwnAttempt() async throws {
        let h = try await LibraryJobHarness()
        func stage(_ name: String) -> (String) -> LibraryStage {
            { folder in
                LibraryStage(stageID: UUID().uuidString, folder: folder, revision: AssetRevision(FakeStaging.date),
                             original: try! h.stagedFile(folder, "original", filename: name + ".DNG", contents: "raw " + name),
                             motion: nil, sidecar: try! h.stagedFile(folder, "sidecar", filename: name + ".xmp", contents: "<xmp/>"),
                             fields: [:], isVideo: false, originalChecksum: "sum-" + name)
            }
        }
        // Its own upload was answered created, then the app ended before the commit.
        try await h.seed("own", stage: stage("own"), attempts: [
            LibraryAttempt(id: AttemptID(), part: .original, state: .completed, remoteID: "server-own", remoteStatus: "created"),
        ])
        h.server.hold(checksum: "sum-own", as: .duplicate("server-own", trashed: false))
        // Someone else's copy.
        try await h.seed("other", stage: stage("other"))
        h.server.hold(checksum: "sum-other", as: .duplicate("server-other", trashed: false))
        // Its own attempt was answered duplicate: the sidecar never went.
        try await h.seed("answered", stage: stage("answered"), attempts: [
            LibraryAttempt(id: AttemptID(), part: .original, state: .completed, remoteID: "server-answered", remoteStatus: "duplicate"),
        ])
        h.server.hold(checksum: "sum-answered", as: .duplicate("server-answered", trashed: false))
        // Accepted, and then the upload's answer is duplicate.
        try await h.seed("late", stage: stage("late"))
        h.uploads.answer("late.DNG", .duplicate("server-late"))

        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("Every job ends.") {
            let own = try await h.receipt("own")
            let failed = try await h.states("other", "answered", "late")
            return own != nil && failed == [.failed, .failed, .failed]
        }
        let own = try await h.receipt("own")
        XCTAssertEqual(own?.original.id, "server-own")
        let message = TransferItemFailure.sidecarDuplicate.localizedDescription
        for id in ["other", "answered", "late"] {
            let job = try await h.job(id)
            XCTAssertEqual(job?.errorClass, "item", id)
            XCTAssertEqual(job?.errorMessage, message, id)
        }
        XCTAssertEqual(h.uploads.uploads.map(\.filename), ["late.DNG"], "A duplicate is never sent.")
        XCTAssertEqual(h.uploads.uploads.first?.hasSidecar, true)
        await h.tearDown()
    }

    /// A duplicate in the server's trash fails the photo; the queue goes on.
    func testTrashedDuplicateIsItem() async throws {
        let h = try await LibraryJobHarness()
        try await h.seed("trashed") { folder in
            LibraryStage(stageID: UUID().uuidString, folder: folder, revision: AssetRevision(FakeStaging.date),
                         original: try! h.stagedFile(folder, "original", filename: "trashed.HEIC", contents: "t"), motion: nil, sidecar: nil,
                         fields: [:], isVideo: false, originalChecksum: "sum-trashed")
        }
        h.server.hold(checksum: "sum-trashed", as: .duplicate("server-trashed", trashed: true))
        h.staging.add("next")
        try await h.run("next")
        try await untilTransfers("The next photo is backed up and the trashed one failed.") {
            let next = try await h.receipt("next")
            let trashed = try await h.job("trashed")?.state
            return next != nil && trashed == .failed
        }
        let job = try await h.job("trashed")
        XCTAssertEqual(job?.errorClass, "item")
        XCTAssertEqual(job?.errorMessage, TransferItemFailure.trashedDuplicate.localizedDescription)
        XCTAssertFalse(h.uploads.uploads.contains { $0.filename == "trashed.HEIC" })
        let trashedReceipt = try await h.receipt("trashed")
        XCTAssertNil(trashedReceipt)
        await h.tearDown()
    }

    /// An edited photo's new date queues it again; its new upload stacks over the old one.
    func testChangedDateRequeuesAndStacks() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("photo")
        h.staging.add("same")
        let first = try await h.discover()
        XCTAssertEqual(first?.queued, 2)
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("Both photos are backed up.") { try await h.backedUp("photo", "same") }
        let before = try await h.receipt("photo")

        let edited = FakeStaging.date.addingTimeInterval(86_400.5)
        h.staging.edit("photo", modified: edited)
        let second = try await h.discover()
        XCTAssertEqual(second?.queued, 1, "Only the edited photo is queued again.")
        try await untilTransfers("The edited photo is backed up again.") { try await h.receipt("photo")?.revision == AssetRevision(edited) }
        let after = try await h.receipt("photo")
        XCTAssertNotEqual(after?.original.id, before?.original.id)
        XCTAssertNotEqual(after?.original.checksum, before?.original.checksum)
        let stacks = try await h.dump("stack_tasks")
        XCTAssertEqual(stacks.count, 1)
        XCTAssertEqual(stacks.first?[1], .text("photo"))
        XCTAssertEqual(stacks.first?[2], .text(after?.original.id ?? ""), "The new upload goes on top.")
        XCTAssertEqual(stacks.first?[3], .text(before?.original.id ?? ""))
        let third = try await h.discover()
        XCTAssertEqual(third?.queued, 0)
        await h.tearDown()
    }

    /// Photos follow cellularPhotos; videos and Live Photo videos cellularVideos, both for the
    /// upload and for staging, as the preferences were when the lease was taken.
    func testCellularPerMediaType() async throws {
        let h = try await LibraryJobHarness(preferences: LibraryJobHarness.preferences(cellularPhotos: true, cellularVideos: false))
        h.staging.add("a-photo")
        h.staging.add("b-video", FakeStaging.Photo(modified: FakeStaging.date, isVideo: true))
        h.staging.add("c-live", FakeStaging.Photo(modified: FakeStaging.date, isLive: true))
        let gate = TransferGate()
        h.staging.hold("a-photo", at: gate)
        try await h.run("a-photo", "b-video", "c-live")
        try await untilTransfers("The photo is staging.") { h.staging.stagings("a-photo") == 1 }
        // A change after the lease is taken waits for the next job.
        var changed = LibraryJobHarness.preferences(cellularPhotos: false, cellularVideos: true)
        changed.includedAlbums = [FakeStaging.album]
        try await h.engine.setPreferences(changed)
        gate.open()
        try await untilTransfers("All three are backed up.") {
            try await h.backedUp("a-photo", "b-video", "c-live")
        }
        let cellular = Dictionary(h.uploads.uploads.map { ($0.filename, $0.allowsCellular) }, uniquingKeysWith: { $1 })
        XCTAssertEqual(cellular["a-photo.HEIC"], true, "The photo's lease was taken while photos could use cellular.")
        let staged = Dictionary(h.staging.staged.map { ($0.localID, $0.policy) }, uniquingKeysWith: { $1 })
        XCTAssertEqual(staged["a-photo"], StagingPolicy(allowCloud: false, cellularPhotos: true, cellularVideos: false))
        // The others leased after the change, unless they ran beside the photo.
        for (name, id) in [("b-video.MOV", "b-video"), ("c-live-live.MOV", "c-live"), ("c-live.HEIC", "c-live")] {
            let policy = try XCTUnwrap(staged[id])
            let video = name.hasSuffix(".MOV")
            XCTAssertEqual(cellular[name], video ? policy.cellularVideos : policy.cellularPhotos, name)
        }
        await h.tearDown()
    }

    /// A Live Photo an earlier build sent part way, without its video's checksum, is confirmed
    /// without a receipt: backed up, but never a cleanup candidate.
    func testLegacyLiveWithoutReceipt() async throws {
        let h = try await LibraryJobHarness()
        try await h.seed("legacy") { folder in
            LibraryStage(stageID: UUID().uuidString, folder: folder, revision: AssetRevision(FakeStaging.date),
                         original: try! h.stagedFile(folder, "original", filename: "legacy.HEIC", contents: "still"),
                         motion: try! h.stagedFile(folder, "motion", filename: "legacy.MOV", contents: "video"), sidecar: nil,
                         fields: [:], isVideo: false, motionRemoteID: "legacy-motion", motionChecksum: nil)
        }
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("The photo is confirmed.") { try await h.confirmed("legacy") }
        let receipt = try await h.receipt("legacy")
        XCTAssertNil(receipt)
        XCTAssertEqual(h.uploads.uploads.map(\.filename), ["legacy.HEIC"])
        XCTAssertEqual(h.uploads.uploads.first?.fields["livePhotoVideoId"], "legacy-motion")
        let job = try await h.job("legacy")
        XCTAssertNil(job)
        await h.tearDown()
    }

    /// An answer on disk that nobody applied, from an attempt the app ended during, is applied
    /// without asking the server or sending the photo again.
    func testRecordedOutcomeIsAppliedWithoutUploadingAgain() async throws {
        let h = try await LibraryJobHarness()
        let attempt = AttemptID()
        try await h.seed("ended", stage: { folder in
            LibraryStage(stageID: attempt.rawValue, folder: folder, revision: AssetRevision(FakeStaging.date),
                         original: try! h.stagedFile(folder, "original", filename: "ended.HEIC", contents: "e"), motion: nil, sidecar: nil,
                         fields: [:], isVideo: false)
        }, attempts: [LibraryAttempt(id: attempt, part: .original, state: .interrupted)])
        h.uploads.record(OutcomeRecord(receipt: .init(id: "server-ended", status: "created")), for: attempt)
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("The photo is backed up.") { try await h.receipt("ended") != nil }
        let receipt = try await h.receipt("ended")
        XCTAssertEqual(receipt?.original.id, "server-ended")
        XCTAssertTrue(h.uploads.uploads.isEmpty)
        XCTAssertTrue(h.server.checks.isEmpty)
        XCTAssertEqual(h.uploads.acknowledged, [attempt])
        await h.tearDown()
    }

    /// A still the server already held is paired with the job's video only by the server's own
    /// answer; one paired with another video fails the photo.
    func testDuplicateStillIsPairedStrictly() async throws {
        let h = try await LibraryJobHarness()
        func stage(_ name: String) -> (String) -> LibraryStage {
            { folder in
                LibraryStage(stageID: UUID().uuidString, folder: folder, revision: AssetRevision(FakeStaging.date),
                             original: try! h.stagedFile(folder, "original", filename: name + ".HEIC", contents: name),
                             motion: try! h.stagedFile(folder, "motion", filename: name + ".MOV", contents: "v"), sidecar: nil, fields: [:],
                             isVideo: false, motionRemoteID: "motion-" + name, motionChecksum: "msum", originalChecksum: "sum-" + name)
            }
        }
        try await h.seed("free", stage: stage("free"))
        h.server.hold(checksum: "sum-free", as: .duplicate("still-free", trashed: false))
        try await h.seed("taken", stage: stage("taken"))
        h.server.hold(checksum: "sum-taken", as: .duplicate("still-taken", trashed: false))
        h.server.pair("still-taken", with: "someone-elses-video")
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("Both end.") {
            let free = try await h.receipt("free")
            let taken = try await h.job("taken")?.state
            return free != nil && taken == .failed
        }
        XCTAssertEqual(h.server.paired, ["still-free": "motion-free"])
        let taken = try await h.job("taken")
        XCTAssertEqual(taken?.errorMessage, TransferItemFailure.livePairConflict.localizedDescription)
        await h.tearDown()
    }

    /// Transfers make no client of their own: the runtime's one client serves them.
    func testOneServerClientPerRuntime() async throws {
        let server = makeStubServer()
        server.route("POST", "assets/bulk-upload-check", .json(#"{"results":[{"id":"photo","action":"accept"}]}"#))
        let made = Mutex(0)
        let clients = AccountClients { address, credential, purpose in
            made.withLock { $0 += 1 }
            let authorization: AuthorizationState? = if case .session(let state) = purpose { state } else { nil }
            return try APIClient(baseURL: address, accessToken: credential?.token, userID: credential?.userID, sessionConfiguration: server.configuration(),
                                 networkConfiguration: NetworkConfiguration(), wifiName: NoWiFi(), authorization: authorization)
        }
        let credential = StoredCredential(server: server.baseURL, token: "session-token", userID: "alice", name: "Alice")
        let log = AccountEventLog()
        var environment = AccountEnvironment()
        environment.usesDeviceStorage = false
        environment.usesDevicePhotos = false
        environment.syncsLibrary = false
        environment.validatesSession = false
        environment.importsBackupState = false
        let dependencies = AccountDependencies(credentials: TestCredentialStore(credential, log: log), mirror: nil, device: FakeAccountDevice(log: log),
                                               clients: clients, unlockEvents: { AsyncStream { $0.finish() } })
        let runtime = try await AccountRuntime.open(credential, environment: environment, dependencies: dependencies,
                                                    presence: AppPresence(isForeground: false)) { _, _ in false }
        let first = runtime.transferServer, second = runtime.transferServer
        XCTAssertTrue(first.client === runtime.api)
        XCTAssertTrue(second.client === runtime.api)
        let results = try await first.bulkUploadCheck([UploadCheck.Item(id: "photo", checksum: "c2hh")])
        XCTAssertEqual(results.map(\.action), ["accept"])
        let request = try await second.uploadRequest(boundary: "Ilyich-attempt", allowsCellular: false)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=Ilyich-attempt")
        XCTAssertFalse(request.allowsCellularAccess)
        XCTAssertFalse(request.allowsExpensiveNetworkAccess)
        XCTAssertEqual(made.withLock { $0 }, 1, "One client for the account, whatever transfers ask.")
        let checks = server.requests("POST", "assets/bulk-upload-check")
        XCTAssertEqual(checks.count, 1)
        let token = checks.first.flatMap { $0.headers["Authorization"] ?? $0.headers["x-immich-user-token"] }
        XCTAssertTrue(token?.hasSuffix("session-token") == true, "The account's own session sends it.")
        runtime.authorization.end()
        await runtime.api.shutdown()
    }

    // MARK: Discovery

    /// The merge runs against the tables as they are at its commit: a photo confirmed while
    /// discovery read Photos is not queued again.
    func testDiscoveryDoesNotRequeueItemConfirmedDuringDiscovery() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("a")
        h.staging.add("b")
        h.staging.add("c")
        let gate = TransferGate()
        h.staging.holdDiscovery(at: gate)
        let discovery = Task { try await h.discover() }
        await untilTransfers("Discovery is reading Photos.") { h.staging.discoveryWaits }
        let snapshot = await h.engine.currentSnapshot
        XCTAssertEqual(snapshot.phase, .discovering)

        // Meanwhile a selection backs up b.
        try await h.run("b")
        try await untilTransfers("b is confirmed.") { try await h.confirmed("b") }
        try await h.engine.setIntent(.paused)
        gate.open()
        let merge = try await discovery.value
        XCTAssertEqual(merge?.found, 3)
        XCTAssertEqual(merge?.queued, 2)
        let jobs = try await h.store.queuePage(lane: .library, after: nil, limit: 10).map(\.source)
        XCTAssertEqual(jobs, [.photo(DeviceAssetID(rawValue: "a")), .photo(DeviceAssetID(rawValue: "c"))])
        await h.tearDown()
    }

    /// A job whose photo has left Photos is dropped, with full access; limited access can't tell.
    func testDeletedAssetDropsItsJob() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("kept")
        h.staging.add("deleted")
        let merge = try await h.discover()
        XCTAssertEqual(merge?.queued, 2)
        h.staging.delete("deleted")

        h.staging.setAccess(.limited)
        let limited = try await h.discover()
        XCTAssertEqual(limited?.dropped, 0)
        let stillThere = try await h.job("deleted")
        XCTAssertNotNil(stillThere)

        h.staging.setAccess(.authorized)
        let full = try await h.discover()
        XCTAssertEqual(full?.dropped, 1)
        let gone = try await h.job("deleted")
        XCTAssertNil(gone)
        let kept = try await h.job("kept")
        XCTAssertNotNil(kept)
        await h.tearDown()
    }

    /// An iCloud original that may download only on Wi-Fi defers its own job; the rest go on, and
    /// it runs once conditions change.
    func testWiFiRequiredOriginalDefersOnlyThatJob() async throws {
        let h = try await LibraryJobHarness()
        h.staging.add("cloud")
        h.staging.add("local")
        h.staging.fail("cloud") { BackupDeferral.waitingForWiFi }
        try await h.run("cloud", "local")
        try await untilTransfers("The local photo is backed up and the iCloud one waits.") {
            let local = try await h.receipt("local")
            let cloud = try await h.job("cloud")?.state
            return local != nil && cloud == .waiting
        }
        let snapshot = await h.engine.currentSnapshot
        XCTAssertEqual(snapshot.phase, .idle, "Only that job waits; the engine doesn't.")
        let job = try await h.job("cloud")
        XCTAssertEqual(job?.retryCount, 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: h.group.url(AccountStoragePaths(LibraryJobHarness.account).backup).path)
        XCTAssertTrue(leftovers.isEmpty, "A stage that failed leaves no files.")
        await h.engine.conditionsChanged()
        try await untilTransfers("It runs once conditions change.") { try await h.receipt("cloud") != nil }
        await h.tearDown()
    }

    // MARK: Pipeline

    /// A new stage starts only while the staged files not yet with the transport are under the
    /// budget, at most two of them; at most three parts wait for their answers.
    func testPipelineRespectsStagingBudget() async throws {
        let h = try await LibraryJobHarness(limits: TransferPipeline.Limits(staged: 2, submitted: 3, stagingBytes: 500))
        let ids = (1...6).map { "p\($0)" }
        for id in ids { h.staging.add(id, FakeStaging.Photo(modified: FakeStaging.date, bytes: 600)) }
        let answers = TransferGate()
        h.uploads.hold(at: answers)
        _ = try await h.engine.enqueue(ids.map { TransferRequest(source: .photo(DeviceAssetID(rawValue: $0)), origin: .selection) })
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("Three uploads wait for their answers and a fourth photo is staged.") {
            h.uploads.waiting == 3 && h.staging.staged.count == 4
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(h.uploads.waiting, 3, "No more than three parts with the transport.")
        XCTAssertEqual(h.staging.staged.count, 4, "The fourth stage is over the budget: the fifth waits.")
        XCTAssertEqual(h.pipeline.stagedCount, 1)
        XCTAssertEqual(h.pipeline.peaks.staged, 1, "Over the budget, one stage at a time.")
        XCTAssertEqual(h.pipeline.peaks.submitted, 3)
        answers.open()
        try await untilTransfers("Every photo is backed up.") { try await h.store.receipts(for: ids).count == ids.count }
        XCTAssertLessThanOrEqual(h.pipeline.peaks.submitted, 3)
        await h.tearDown()

        // Under the budget, two stages wait together.
        let roomy = try await LibraryJobHarness(limits: TransferPipeline.Limits(staged: 2, submitted: 1, stagingBytes: 10_000))
        for id in ids { roomy.staging.add(id, FakeStaging.Photo(modified: FakeStaging.date, bytes: 600)) }
        let held = TransferGate()
        roomy.uploads.hold(at: held)
        _ = try await roomy.engine.enqueue(ids.map { TransferRequest(source: .photo(DeviceAssetID(rawValue: $0)), origin: .selection) })
        try await roomy.engine.setIntent(.automatic)
        try await roomy.engine.start()
        await untilTransfers("One upload waits and two photos stand staged.") { roomy.uploads.waiting == 1 && roomy.pipeline.stagedCount == 2 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(roomy.staging.staged.count, 3)
        XCTAssertEqual(roomy.pipeline.peaks.staged, 2)
        held.open()
        try await untilTransfers("Every photo is backed up.") { try await roomy.store.receipts(for: ids).count == ids.count }
        await roomy.tearDown()
    }
}

import IlyichPlatform
import Synchronization
import UIKit
import XCTest
@testable import Ilyich

/// T5: the coverage worker keeps the account's own timeline on disk by paging the index and
/// checking the presence map; it resumes from its saved position, checks only what a change
/// named once the library was verified, downloads only when the policy allows, and belongs to
/// one session.
@MainActor final class CoverageWorkerTests: XCTestCase {
    private nonisolated static let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
        UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    /// Downloads by photo, in order; the photos in `blocked` wait until the test releases them.
    private final class FakeServer: Sendable {
        let calls = Mutex<[String]>([])
        let blocked = Mutex<Set<String>>([])
        let fails = Atomic<Bool>(false)

        func load(_ id: String) async throws -> Data {
            calls.withLock { $0.append(id) }
            while blocked.withLock({ $0.contains(id) }) { try await Task.sleep(for: .milliseconds(5)) }
            if fails.load(ordering: .relaxed) { throw URLError(.badServerResponse) }
            return CoverageWorkerTests.png
        }

        var requested: [String] { calls.withLock { $0 } }
        func block(_ ids: Set<String>) { blocked.withLock { $0 = ids } }
    }

    /// The account's library changes, as SyncEngine.changes hands them out: one stream per subscriber.
    private final class ChangeFeed: Sendable {
        private let continuations = Mutex<[AsyncStream<LibraryChange>.Continuation]>([])

        func stream() -> AsyncStream<LibraryChange> {
            let (stream, continuation) = AsyncStream.makeStream(of: LibraryChange.self)
            continuations.withLock { $0.append(continuation) }
            return stream
        }

        func send(_ change: LibraryChange) {
            for continuation in continuations.withLock({ $0 }) { continuation.yield(change) }
        }
    }

    private struct Harness {
        let index: LibraryIndex
        let store: ThumbnailDiskStore
        let scheduler: ThumbnailScheduler
        let server: FakeServer
        let conditions: CoverageConditions
        let authorization: AuthorizationState
        let account: AccountID
        let feed: ChangeFeed
        let root: URL
    }

    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CoverageWorkerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    // MARK: - Resuming and rechecking

    /// A pass checks every covered photo against the store and downloads only the missing ones:
    /// not a present file, not a partner's, archived, trashed or locked photo. Stopped between two
    /// pages, the next worker resumes after the last page saved. Once the library has been walked
    /// the index's revision is the mark, so a relaunch makes no request; after that a change
    /// names the photos to check again, and only those are read and fetched.
    func testCoverageResumesAndRechecksOnlyChangedAssets() async throws {
        let h = try await makeHarness(photos: Self.six)
        // One photo is already on disk, as after an earlier launch.
        await h.store.store(Self.png, assetID: "p2", revision: "r1")
        // The server holds p3, so the first worker is stopped while page two is under way.
        h.server.block(["p3"])
        let first = makeWorker(h)
        first.start()
        try await until("Page two did not start.") { h.server.requested.contains("p3") }
        try await until("The second photo of the page was not asked for.") { h.server.requested.contains("p4") }
        await first.stop()
        XCTAssertEqual(first.statistics.pagesRead, 2)
        var saved = await h.store.coverageState()
        let began = try await h.index.derivedRevision()
        XCTAssertNotNil(saved.cursor, "The position after page one is saved.")
        XCTAssertNil(saved.mark, "The library isn't verified yet.")
        XCTAssertEqual(saved.passMark, began, "The pass carries the revision it began at.")
        XCTAssertEqual(saved.total, 6)
        XCTAssertEqual(saved.stored, 2, "Page one: p1 fetched, p2 present.")
        // A download that has started finishes into the store, as every download does.
        h.server.block([])
        try await until("The held downloads did not finish.") {
            h.store.contains(assetID: "p3", revision: "r1") && h.store.contains(assetID: "p4", revision: "r1")
        }

        let second = makeWorker(h)
        second.start()
        try await until("The second worker did not finish the pass.") { second.statistics.completedPasses == 1 }
        await second.stop()
        XCTAssertEqual(second.statistics.pagesRead, 3, "Two pages after the saved position, then the empty page: nothing before it is read again.")
        XCTAssertEqual(Set(h.server.requested), ["p1", "p3", "p4", "p5", "p6"], "Only missing photos of the owner's timeline are fetched.")
        XCTAssertEqual(h.server.requested.count, 5, "None twice.")
        saved = await h.store.coverageState()
        let revision = try await h.index.derivedRevision()
        XCTAssertNil(saved.cursor)
        XCTAssertEqual(saved.mark, revision, "Verified through the index's revision.")
        XCTAssertNil(saved.passMark, "Nothing is under way.")
        XCTAssertEqual(saved.total, 6)
        XCTAssertEqual(saved.stored, 6)
        let relaunched = ThumbnailDiskStore(directory: h.store.directory, indexDelay: nil)
        let reread = await relaunched.coverageState()
        XCTAssertEqual(reread, saved, "The position and the mark are in the index on disk.")

        // A relaunch with nothing changed: no pass, no request, the counts from the index.
        let third = makeWorker(h)
        third.start()
        try await until("The relaunched worker did not settle.") { third.progress.total == 6 && !third.isRunning }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(third.statistics.passes, 0, "A verified library is not walked again.")
        XCTAssertEqual(h.server.requested.count, 5, "Zero coverage requests after a relaunch.")
        XCTAssertEqual(third.progress.stored, 6)

        // p3's previews were made again: only p3 is checked, and fetched at its new revision.
        _ = try await h.index.apply([Self.photo("p3", taken: Self.six[2].taken, revision: "r2")], epoch: h.index.epoch())
        var change = await makeChange(h)
        change.mediaRevisions = ["p3": "r2"]
        h.feed.send(change)
        try await until("The changed photo was not fetched again.") { h.server.requested.count == 6 }
        XCTAssertEqual(h.server.requested.last, "p3")
        try await until("The recheck did not finish.") { third.statistics.rechecked == 1 && !third.isRunning }
        XCTAssertEqual(third.statistics.pagesRead, 0, "A change never starts a pass.")
        try await until("The thumbnail was not stored.") { h.store.contains(assetID: "p3", revision: "r2") }
        saved = await h.store.coverageState()
        let changed = try await h.index.derivedRevision()
        XCTAssertEqual(saved.mark, changed, "Verified through the changed index.")
        XCTAssertEqual(saved.stored, 6)

        // A change that names a removed photo, or one outside the covered set, fetches nothing.
        var removal = await makeChange(h)
        removal.removed = ["p6"]
        removal.upserted = ["archived": .init(from: nil, to: nil)]
        h.feed.send(removal)
        try await until("The second recheck did not finish.") { third.statistics.rechecked == 2 && !third.isRunning }
        XCTAssertEqual(h.server.requested.count, 6)

        // An album changing moves the index's revision without naming a photo: the mark follows,
        // so the next launch walks nothing.
        _ = try await h.index.apply([Self.photo("archived", taken: "2026-06-21T12:00:00Z", visibility: "archive", revision: "r2")], epoch: h.index.epoch())
        let moved = try await h.index.derivedRevision()
        XCTAssertNotEqual(moved, changed, "The index's revision moved.")
        var album = await makeChange(h)
        album.albums = ["album"]
        h.feed.send(album)
        try await until("The album change did not move the mark.") { await h.store.coverageState().mark == moved }
        XCTAssertEqual(third.statistics.pagesRead, 0)
        XCTAssertEqual(h.server.requested.count, 6)
        await third.stop()

        let fourth = makeWorker(h)
        fourth.start()
        try await until("The relaunched worker did not settle.") { fourth.progress.total == 6 && !fourth.isRunning }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fourth.statistics.passes, 0, "Nothing is walked after the album change either.")
        await fourth.stop()
    }

    /// A photo that synced in while an earlier launch's pass had already walked its month is not
    /// lost with the change that named it when that process was killed: the resumed pass ends
    /// with the revision it began at, which the next launch finds behind the index, and verifies
    /// the library once more without fetching a present file.
    func testAChangeLostWithAnEarlierLaunchIsFoundByTheMark() async throws {
        let h = try await makeHarness(photos: Self.six)
        h.server.block(["p3"])
        let first = makeWorker(h)
        first.start()
        try await until("Page two did not start.") { h.server.requested.contains("p4") }
        await first.stop()
        h.server.block([])
        try await until("The held downloads did not finish.") {
            h.store.contains(assetID: "p3", revision: "r1") && h.store.contains(assetID: "p4", revision: "r1")
        }
        let began = try await h.index.derivedRevision()
        var saved = await h.store.coverageState()
        XCTAssertNotNil(saved.cursor)
        XCTAssertEqual(saved.passMark, began)
        // While no worker runs, a photo newer than any walked lands in the newest month; the
        // change naming it died with the earlier process.
        _ = try await h.index.apply([Self.photo("p0", taken: "2026-06-20T12:00:00Z")], epoch: h.index.epoch())
        let moved = try await h.index.derivedRevision()
        XCTAssertNotEqual(moved, began)

        let second = makeWorker(h)
        second.start()
        try await until("The new photo was not fetched.") { h.server.requested.contains("p0") }
        try await until("The verification pass did not finish.") { second.statistics.completedPasses == 2 && !second.isRunning }
        XCTAssertEqual(second.statistics.passes, 2, "The resumed pass, then one from the newest photo.")
        XCTAssertEqual(h.server.requested.count, 7, "p1 to p6 once, then p0: no present file was fetched again.")
        saved = await h.store.coverageState()
        XCTAssertEqual(saved.mark, moved, "Verified through the index as it is now.")
        XCTAssertNil(saved.passMark)
        XCTAssertEqual(saved.total, 7)
        XCTAssertEqual(saved.stored, 7)
        await second.stop()
    }

    /// A reset, or a change that overflowed, walks the library again instead of checking photos one by one.
    func testAResetWalksTheLibraryAgain() async throws {
        let h = try await makeHarness(photos: Array(Self.six.prefix(2)))
        let worker = makeWorker(h)
        worker.start()
        try await until("The first pass did not finish.") { worker.statistics.completedPasses == 1 }
        var change = await makeChange(h)
        change.reset = true
        h.feed.send(change)
        try await until("The reset did not start another pass.") { worker.statistics.completedPasses == 2 }
        XCTAssertEqual(h.server.requested.count, 2, "Present files are never fetched again.")
        await worker.stop()
    }

    // MARK: - Holds

    /// Nothing downloads while a photo is open, while the grid scrolls or the rail scrubs, or for
    /// the hold after the grid stops.
    func testCoverageHoldsWhileScrubbingOrViewing() async throws {
        let h = try await makeHarness(photos: Array(Self.six.prefix(4)))
        var policy = CoveragePolicy.today
        policy.motionHold = 1.0
        h.conditions.setViewing(true)
        let worker = makeWorker(h, policy: policy)
        worker.start()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(h.server.requested, [], "Nothing downloads while a photo is open.")
        XCTAssertEqual(worker.progress.hold, .viewing)
        XCTAssertTrue(worker.isRunning, "The pass has work; it waits.")

        // The grid starts moving as the viewer closes.
        h.conditions.setMoving(true)
        h.conditions.setViewing(false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(h.server.requested, [], "Nothing downloads while the grid moves.")
        XCTAssertEqual(worker.progress.hold, .moving)

        h.conditions.setMoving(false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(h.server.requested, [], "Nor for a moment after it stops.")
        guard case .settling(_)? = worker.progress.hold else { return XCTFail("The hold after motion is not shown: \(String(describing: worker.progress.hold)).") }

        try await until("Coverage did not resume once the grid rested.") { h.server.requested.count == 4 }
        try await until("The pass did not finish.") { worker.statistics.completedPasses == 1 }
        XCTAssertNil(worker.progress.hold)
        await worker.stop()
    }

    /// Cellular, a hotspot and Low Data Mode all pause coverage; an unmetered path resumes it.
    func testMeteredPathPausesCoverage() async throws {
        let h = try await makeHarness(photos: Array(Self.six.prefix(2)))
        h.conditions.update { $0.network = .expensive }
        let worker = makeWorker(h)
        worker.start()
        try await until("The metered hold was not shown.") { worker.progress.hold == .metered }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(h.server.requested, [], "Nothing downloads on cellular.")
        h.conditions.update { $0.network = .constrained }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(h.server.requested, [], "Nothing downloads in Low Data Mode.")
        XCTAssertEqual(worker.progress.hold, .metered)
        h.conditions.update { $0.network = .none }
        try await until("The offline hold was not shown.") { worker.progress.hold == .offline }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(h.server.requested, [], "Nothing is tried without a network.")
        h.conditions.update { $0.network = .unmetered }
        try await until("Coverage did not resume on Wi-Fi.") { h.server.requested.count == 2 }
        await worker.stop()
    }

    /// Low Power Mode, a hot phone and the app leaving the front pause coverage too.
    func testLowPowerHeatAndBackgroundPauseCoverage() async throws {
        let h = try await makeHarness(photos: Array(Self.six.prefix(2)))
        h.conditions.update { $0.lowPower = true }
        let worker = makeWorker(h)
        worker.start()
        try await until("The Low Power hold was not shown.") { worker.progress.hold == .lowPower }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(h.server.requested, [])
        h.conditions.update { $0.lowPower = false; $0.thermal = .serious }
        try await until("The thermal hold was not shown.") { worker.progress.hold == .thermal }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(h.server.requested, [])
        h.conditions.update { $0.thermal = .fair; $0.appActive = false }
        try await until("The background hold was not shown.") { worker.progress.hold == .background }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(h.server.requested, [])
        h.conditions.setAppActive(true)
        try await until("Coverage did not resume.") { h.server.requested.count == 2 }
        await worker.stop()
    }

    /// At the store's cap coverage waits for the trim rather than filling what it would evict.
    func testCoverageWaitsAtTheDiskBudget() async throws {
        let h = try await makeHarness(photos: Array(Self.six.prefix(2)), storeLimit: 4_096)
        await h.store.store(Self.png, assetID: "elsewhere", revision: "r1")
        let worker = makeWorker(h)
        worker.start()
        try await until("The budget hold was not shown.") { worker.progress.hold == .diskBudget }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(h.server.requested, [], "Nothing downloads into a full store.")
        await worker.stop()
    }

    /// A failing server gets a pause after three failures in a row instead of a stream of
    /// requests, and a change of conditions meanwhile does not cut the pause short.
    func testAFailingServerGetsAPause() async throws {
        let h = try await makeHarness(photos: Self.six)
        h.server.fails.store(true, ordering: .relaxed)
        let worker = makeWorker(h, pageSize: 6, failurePause: .seconds(1))
        worker.start()
        try await until("The server was not left alone after three failures.") { worker.progress.hold == .serverFailing }
        XCTAssertEqual(h.server.requested.count, 4, "The download in flight at the third failure finished; nothing more was asked.")
        // Opening and closing a photo wakes the worker, but the pause goes on.
        h.conditions.setViewing(true)
        h.conditions.setViewing(false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(worker.progress.hold, .serverFailing)
        XCTAssertEqual(h.server.requested.count, 4)
        h.server.fails.store(false, ordering: .relaxed)
        try await until("Coverage did not carry on after the pause.") { worker.statistics.completedPasses == 1 }
        XCTAssertEqual(h.server.requested.count, 6, "Each photo was asked for once in the pass.")
        XCTAssertEqual(worker.progress.stored, 2, "The counts stay honest.")
        var saved = await h.store.coverageState()
        XCTAssertNil(saved.mark, "A pass in which a download failed leaves the library unverified.")
        // The server is left alone once more, then only the photos that failed are asked for.
        try await until("The pause before the next pass was not shown.") { worker.progress.hold == .serverFailing }
        try await until("The failed photos were not fetched by the next pass.") { worker.statistics.completedPasses == 2 }
        XCTAssertEqual(h.server.requested.count, 10)
        XCTAssertEqual(Set(h.server.requested.suffix(4)), ["p1", "p2", "p3", "p4"], "Present files are never fetched again.")
        XCTAssertEqual(worker.progress.stored, 6)
        saved = await h.store.coverageState()
        let revision = try await h.index.derivedRevision()
        XCTAssertEqual(saved.mark, revision, "Verified once every photo is on disk.")
        await worker.stop()
    }

    /// A photo whose download fails in a recheck is checked again after a pause, and the mark
    /// waits for it, so a kill meanwhile finds the index past the mark at the next launch.
    func testARecheckThatFailsKeepsTheMarkAndTriesAgain() async throws {
        let h = try await makeHarness(photos: Array(Self.six.prefix(2)))
        let worker = makeWorker(h)
        worker.start()
        try await until("The first pass did not finish.") { worker.statistics.completedPasses == 1 }
        let verified = try await h.index.derivedRevision()
        h.server.fails.store(true, ordering: .relaxed)
        _ = try await h.index.apply([Self.photo("p1", taken: Self.six[0].taken, revision: "r2")], epoch: h.index.epoch())
        var change = await makeChange(h)
        change.mediaRevisions = ["p1": "r2"]
        h.feed.send(change)
        try await until("The changed photo was not asked for.") { h.server.requested.count == 3 }
        try await until("The server was not left alone after the failure.") { worker.progress.hold == .serverFailing }
        var saved = await h.store.coverageState()
        XCTAssertEqual(saved.mark, verified, "The mark waits for the photo that failed.")
        h.server.fails.store(false, ordering: .relaxed)
        try await until("The failed photo was not asked for again.") { h.server.requested.count == 4 }
        XCTAssertEqual(h.server.requested.last, "p1")
        let moved = try await h.index.derivedRevision()
        try await until("The mark did not follow the recheck.") { await h.store.coverageState().mark == moved }
        saved = await h.store.coverageState()
        XCTAssertEqual(saved.stored, 2)
        XCTAssertEqual(worker.statistics.passes, 1, "No pass is walked for a recheck that failed.")
        await worker.stop()
    }

    /// Clear browsing cache in the middle of a pass: the page under way is not saved into the
    /// emptied store, and the next pass starts from the newest photo with fresh counts, so every
    /// file is there in the end and the counts say so.
    func testClearingTheStoreDuringAPassStartsItOver() async throws {
        let h = try await makeHarness(photos: Self.six)
        h.server.block(["p3"])
        let worker = makeWorker(h)
        worker.start()
        try await until("Page two did not start.") { h.server.requested.contains("p4") }
        let underWay = await h.store.coverageState()
        XCTAssertNotNil(underWay.cursor, "Page one is saved.")
        // The user clears the cache while page two downloads.
        await h.store.removeAll()
        XCTAssertFalse(h.store.contains(assetID: "p1", revision: "r1"))
        h.server.block([])
        try await until("The pass from the newest photo did not finish.") { worker.statistics.completedPasses == 1 && !worker.isRunning }
        for photo in Self.six {
            XCTAssertTrue(h.store.contains(assetID: photo.id, revision: "r1"), "\(photo.id) is on disk.")
        }
        XCTAssertEqual(worker.statistics.passes, 2, "The pass under way ended; one from the newest photo followed.")
        let saved = await h.store.coverageState()
        let revision = try await h.index.derivedRevision()
        XCTAssertEqual(saved.stored, 6)
        XCTAssertEqual(saved.total, 6)
        XCTAssertEqual(saved.mark, revision)
        XCTAssertEqual(worker.progress.stored, 6)
        await worker.stop()
    }

    // MARK: - Session and library

    /// Coverage belongs to its session: once it ended, nothing starts, and a worker under way stops.
    func testCoverageNeverRunsForAnEndedSession() async throws {
        let h = try await makeHarness(photos: Array(Self.six.prefix(2)))
        h.authorization.end()
        let worker = makeWorker(h)
        worker.start()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(h.server.requested, [], "A worker of an ended session never starts.")
        XCTAssertFalse(worker.isRunning)
        XCTAssertEqual(worker.statistics.passes, 0)
        await worker.stop()
    }

    /// Until the first sync is complete nothing is covered; the change that completes it starts the pass.
    func testCoverageWaitsForACompleteLibrary() async throws {
        let h = try await makeHarness(photos: Array(Self.six.prefix(2)), complete: false)
        let worker = makeWorker(h)
        worker.start()
        try await until("The incomplete library was not noticed.") { worker.progress.hold == .libraryNotReady }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.server.requested, [], "An incomplete library is not covered.")
        _ = try await h.index.apply([SyncEvents.complete()], epoch: h.index.epoch())
        var change = await makeChange(h)
        change.routingChanged = true
        h.feed.send(change)
        try await until("The complete library was not covered.") { worker.statistics.completedPasses == 1 }
        XCTAssertEqual(Set(h.server.requested), ["p1", "p2"])
        await worker.stop()
    }

    // MARK: - Policy

    /// The policy defaults to today's behavior, round-trips through UserDefaults, and ignores what it doesn't know.
    func testPolicyDefaultsToTodayAndRoundTrips() throws {
        let suite = "CoverageWorkerTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CoveragePolicy.load(from: defaults), .today)
        XCTAssertEqual(CoveragePolicy.today.scope, .ownerTimeline)
        XCTAssertTrue(CoveragePolicy.today.unmeteredOnly)
        XCTAssertEqual(CoveragePolicy.today.motionHold, 1.5)

        var policy = CoveragePolicy.today
        policy.unmeteredOnly = false
        policy.motionHold = 3
        policy.save(to: defaults)
        XCTAssertEqual(CoveragePolicy.load(from: defaults), policy)

        defaults.set(Data(#"{"scope":"ownerTimeline","later":true}"#.utf8), forKey: CoveragePolicy.defaultsKey)
        XCTAssertEqual(CoveragePolicy.load(from: defaults), .today, "Keys a later build adds read as today's values.")
        defaults.set(Data("not json".utf8), forKey: CoveragePolicy.defaultsKey)
        XCTAssertEqual(CoveragePolicy.load(from: defaults), .today, "An unreadable value is today's behavior.")
    }

    /// The hold a policy gives for each condition, in the order they are checked.
    func testPolicyHolds() {
        let policy = CoveragePolicy.today
        var conditions = CoverageConditions.Snapshot()
        XCTAssertNil(policy.hold(conditions, now: 100))
        conditions.motionEndedAt = 99
        XCTAssertEqual(policy.hold(conditions, now: 100), .settling(until: 100.5))
        XCTAssertNil(policy.hold(conditions, now: 100.6), "The hold ends.")
        conditions.moving = true
        XCTAssertEqual(policy.hold(conditions, now: 100), .moving)
        conditions.viewing = true
        XCTAssertEqual(policy.hold(conditions, now: 100), .viewing)
        conditions.thermal = .critical
        XCTAssertEqual(policy.hold(conditions, now: 100), .thermal)
        conditions.lowPower = true
        XCTAssertEqual(policy.hold(conditions, now: 100), .lowPower)
        conditions.network = .expensive
        XCTAssertEqual(policy.hold(conditions, now: 100), .metered)
        conditions.network = .none
        XCTAssertEqual(policy.hold(conditions, now: 100), .offline)
        conditions.appActive = false
        XCTAssertEqual(policy.hold(conditions, now: 100), .background)

        var lenient = policy
        lenient.unmeteredOnly = false; lenient.pausesInLowPowerMode = false; lenient.pausesWhenHot = false; lenient.pausesWhileViewing = false
        conditions = CoverageConditions.Snapshot(network: .constrained, lowPower: true, thermal: .critical, viewing: true)
        XCTAssertNil(lenient.hold(conditions, now: 100), "A policy may allow each of them.")
    }

    // MARK: - Support

    private struct Photo {
        let id: String
        let taken: String
    }

    /// Six photos of the owner's timeline, newest first.
    private static let six = (1...6).map { Photo(id: "p\($0)", taken: "2026-0\(7 - $0)-15T12:00:00Z") }

    private static func photo(_ id: String, taken: String, owner: String = "alice", visibility: String = "timeline", trashed: Bool = false,
                              revision: String = "r1", type: String = "AssetV2") -> EntitySyncEvent {
        SyncEvents.event(type, """
        {"id":"\(id)","ownerId":"\(owner)","type":"IMAGE","originalFileName":"\(id).jpg","checksum":"AQIDBA==","fileCreatedAt":"\(taken)","localDateTime":"\(taken)","createdAt":"2026-03-01T00:00:00Z","visibility":"\(visibility)","isFavorite":false,"deletedAt":\(trashed ? "\"2026-03-04T00:00:00Z\"" : "null"),"stackId":null,"isEdited":false,"isDeveloped":false,"mediaRevision":"\(revision)"}
        """, ack: "\(type)|\(id)")
    }

    /// An index holding `photos` and, beside them, a partner's photo, an archived, a trashed and
    /// a locked one, none of which coverage keeps; a store of its own; a scheduler over a fake
    /// server; and conditions that allow downloading.
    private func makeHarness(photos: [Photo], complete: Bool = true, storeLimit: Int = ThumbnailDiskStore.defaultLimit) async throws -> Harness {
        let server = FakeServer()
        let index = try LibraryIndex(scope: "server|alice", userID: "alice", directory: root.appendingPathComponent("index", isDirectory: true))
        var events = photos.map { Self.photo($0.id, taken: $0.taken) }
        events += [
            SyncEvents.event("PartnerV1", #"{"sharedById":"bob","sharedWithId":"alice","inTimeline":true}"#, ack: "PartnerV1|bob"),
            Self.photo("partner", taken: "2026-06-20T12:00:00Z", owner: "bob", type: "PartnerAssetV2"),
            Self.photo("archived", taken: "2026-06-21T12:00:00Z", visibility: "archive"),
            Self.photo("trashed", taken: "2026-06-22T12:00:00Z", trashed: true),
            Self.photo("locked", taken: "2026-06-23T12:00:00Z", visibility: "locked"),
        ]
        if complete { events.append(SyncEvents.complete()) }
        _ = try await index.apply(events, epoch: index.epoch())
        let store = ThumbnailDiskStore(directory: root.appendingPathComponent("thumbnails", isDirectory: true), limit: storeLimit, indexDelay: nil)
        let scheduler = ThumbnailScheduler(store: store, memory: DecodedThumbnailCache(),
                                           fetcher: ThumbnailFetcher(load: { id, _, _ in try await server.load(id) }, baseDelay: 0.05))
        let account = AccountID(server: try XCTUnwrap(URL(string: "https://coverage.example/api")), userID: "alice")
        let authorization = AuthorizationState(account: account, token: "coverage-session", readOnly: false, requiresPasswordChange: false, mirror: nil)
        addTeardownBlock { server.block([]) }
        return Harness(index: index, store: store, scheduler: scheduler, server: server, conditions: CoverageConditions(),
                       authorization: authorization, account: account, feed: ChangeFeed(), root: root)
    }

    private func makeWorker(_ h: Harness, policy: CoveragePolicy = .today, pageSize: Int = 2,
                            failurePause: Duration = .milliseconds(300)) -> CoverageWorker {
        let feed = h.feed
        return CoverageWorker(index: h.index, store: h.store, scheduler: h.scheduler, conditions: h.conditions, board: CoverageBoard(),
                              changes: { feed.stream() }, authorization: h.authorization, policy: policy, pageSize: pageSize,
                              startDelay: .zero, failurePause: failurePause)
    }

    private func makeChange(_ h: Harness) async -> LibraryChange {
        LibraryChange(account: h.account, authorization: h.authorization.snapshot.epoch, indexRevision: await h.index.revision, origin: .sync)
    }

    private func until(_ message: String, within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

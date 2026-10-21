import Foundation
import Synchronization
import XCTest
@testable import Ilyich

/// Lifecycle events and background windows (B7), dormant: LifecycleEventSource and
/// TransferLifecycle over fake tasks, fake background time and fake window work, and the transfer
/// engine's plan and hand-off.
@MainActor final class LifecycleTests: XCTestCase {
    @MainActor private struct Rig {
        let scheduler = FakeTaskScheduler()
        let time = FakeBackgroundTime()
        let clock = TestClock()
        let source: LifecycleEventSource
        let lifecycle: TransferLifecycle<TestClock>

        init(active: Bool, work: any BackgroundWindowWork) async {
            source = LifecycleEventSource(initial: .launch(active: active), scheduler: scheduler)
            lifecycle = TransferLifecycle(work: work, time: time, clock: clock, appActive: active)
            XCTAssertTrue(source.register())
            await lifecycle.start(source.events)
        }

        func handled(_ count: Int) async {
            await untilTransfers("\(count) events handled") { await lifecycle.handled >= count }
        }

        func stop() async {
            source.finish()
            await lifecycle.stop()
        }
    }

    // MARK: Windows

    func testExpirationCompletesTaskSynchronously() async throws {
        let work = FakeWindowWork()
        let gate = TransferGate()
        work.hold("reconcile", at: gate)
        let rig = await Rig(active: false, work: work)
        let task = rig.scheduler.launch(.processing)
        await untilTransfers("The window reconciles.") { gate.waiting == 1 }

        let expire = try XCTUnwrap(task.expirationHandler, "The lease takes the task's expiration.")
        expire()
        XCTAssertEqual(task.completions, [false], "The task is completed before the expiration handler returns.")

        gate.open()
        await untilTransfers("The window ends.") { await !rig.lifecycle.hasWindow }
        XCTAssertEqual(task.completions, [false], "Finishing afterwards completes nothing a second time.")
        XCTAssertEqual(work.calls, ["reconcile", "reconcile cancelled"], "The window's work stops with its time.")
        await rig.stop()
    }

    func testBackgroundLaunchStartsNoForegroundWork() async throws {
        let work = FakeWindowWork()
        let rig = await Rig(active: false, work: work)
        // The network monitor's first callback, then a Photos change, while iOS has the app in the background.
        rig.source.networkChanged(.unmetered)
        rig.source.photoLibraryChanged()
        let task = rig.scheduler.launch(.refresh)
        await untilTransfers("The refresh window completes.") { task.completions == [true] }
        await rig.handled(2)
        try await Task.sleep(for: .milliseconds(50))

        let handled = await rig.lifecycle.handled
        XCTAssertEqual(handled, 2, "The first network reading is no event.")
        XCTAssertEqual(work.calls, ["reconcile", "applyOutcomes", "submitStaged"], "A refresh window reconciles and submits only.")
        XCTAssertEqual(rig.clock.sleeperCount, 0, "No trigger delay runs towards a search.")
        XCTAssertTrue(rig.time.begun.isEmpty)
        XCTAssertTrue(rig.scheduler.submitted.isEmpty, "Nothing reschedules on its own.")

        // Coming forward is what starts the foreground's search.
        rig.source.applicationBecameActive()
        await untilTransfers("Coming forward looks for new photos.") { work.count("discover") == 1 }
        await rig.stop()
    }

    func testPathFlapDoesNotCancelDiscovery() async throws {
        let work = FakeWindowWork()
        let search = TransferGate()
        work.hold("discover", at: search)
        let rig = await Rig(active: false, work: work)
        rig.source.networkChanged(.unmetered)
        rig.source.applicationBecameActive()
        await untilTransfers("The foreground search starts.") { search.waiting == 1 }

        rig.source.networkChanged(.none)
        rig.source.networkChanged(.unmetered)
        await rig.handled(3)
        XCTAssertEqual(work.count("conditionsChanged"), 2, "Each change ends the engine's waits.")
        search.open()
        await untilTransfers("The search finishes.") { await !rig.lifecycle.isSearching }
        XCTAssertEqual(work.count("discover"), 1)
        XCTAssertFalse(work.calls.contains("discover cancelled"), "The flap never reaches the search.")

        // And in a processing window, in the background.
        rig.source.applicationEnteredBackground()
        let windowSearch = TransferGate()
        work.hold("discover", at: windowSearch)
        let task = rig.scheduler.launch(.processing)
        await untilTransfers("The window searches.") { windowSearch.waiting == 1 }
        rig.source.networkChanged(.none)
        rig.source.networkChanged(.expensive)
        await rig.handled(7)
        windowSearch.open()
        await untilTransfers("The window completes.") { task.completions == [true] }
        XCTAssertFalse(work.calls.contains("discover cancelled"))
        await rig.stop()
    }

    func testQueuedJobsRunWhenMetadataPreSyncFails() async throws {
        let work = FakeWindowWork()
        work.fail("preSync")
        // Nothing to run at first; discovery queues a photo, which then goes to the daemon.
        work.handoffs(.nothingRunnable, .handedToDaemon)
        let rig = await Rig(active: false, work: work)
        let task = rig.scheduler.launch(.processing)
        await untilTransfers("The window completes.") { !task.completions.isEmpty }
        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(work.calls, ["reconcile", "applyOutcomes", "submitStaged", "daemonOwnsWork", "runUntilHandedOff", "preSync",
                                    "discover", "runUntilHandedOff"])
        await rig.stop()
    }

    func testMetadataPreSyncIsAbandonedAtItsLimit() async throws {
        XCTAssertEqual(TransferLifecycle<TestClock>.preSyncLimit(budget: .seconds(120)), .seconds(20))
        XCTAssertEqual(TransferLifecycle<TestClock>.preSyncLimit(budget: .seconds(30)), .seconds(9), "30 % of a short budget.")
        let work = FakeWindowWork()
        let sync = TransferGate()
        work.hold("preSync", at: sync)
        let rig = await Rig(active: false, work: work)
        let task = rig.scheduler.launch(.processing)
        await untilTransfers("The pre-sync runs.") { sync.waiting == 1 }
        try await rig.clock.waitForSleepers(1)
        rig.clock.advance(by: .seconds(19))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(work.count("discover"), 0, "The pre-sync has its 20 seconds.")
        rig.clock.advance(by: .seconds(1))
        await untilTransfers("The window goes on without it.") { task.completions == [true] }
        XCTAssertEqual(work.count("discover"), 1)
        sync.open()
        await rig.stop()
    }

    func testWindowReturnsWhenWorkHandedToDaemonWithoutPolling() async throws {
        let h = try await TransferEngineHarness()
        let staging = TransferGate()
        let answer = TransferGate()
        h.executor.script("a", .handOff(staging: staging, answer: answer))
        _ = try await h.engine.enqueue([h.photo("a")])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        await untilTransfers("The job stages.") { staging.waiting == 1 }

        let work = EngineWindowWork(engine: h.engine)
        let rig = await Rig(active: false, work: work)
        let task = rig.scheduler.launch(.processing)
        await untilTransfers("The window waits for the engine.") { work.recorder.count("runUntilHandedOff") == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(task.completions.isEmpty, "Staging is not yet the daemon's.")

        staging.open()
        await untilTransfers("The window completes once the part is with the session.") { task.completions == [true] }
        XCTAssertEqual(answer.waiting, 1, "The upload is still the daemon's.")
        XCTAssertEqual(work.recorder.count("daemonOwnsWork"), 1, "Nothing polls.")
        XCTAssertEqual(work.recorder.count("runUntilHandedOff"), 1)
        let handedOff = await h.engine.handoff()
        XCTAssertEqual(handedOff, .handedToDaemon, "A part with the session hands off at once.")
        let owns = await h.engine.daemonOwnsWork()
        XCTAssertTrue(owns)

        answer.open()
        try await untilTransfers("The upload commits.") { try await h.confirmed("a") }
        let idle = await h.engine.handoff()
        XCTAssertEqual(idle, .nothingRunnable, "With nothing left, a window returns at once.")
        await rig.stop()
        await h.tearDown()
    }

    func testLibraryChurnDoesNotPostponeWindows() async throws {
        let work = FakeWindowWork()
        work.setTriggerDelay(.seconds(30))
        let rig = await Rig(active: false, work: work)
        let plan = SchedulePlan.automatic(requireCharging: true, triggerDelay: 30)
        await rig.source.schedule(plan)
        let first = rig.scheduler.submitted
        XCTAssertEqual(first.map(\.kind), [.processing, .refresh])
        XCTAssertEqual(first.first?.shape, WindowRequest.Shape(requiresExternalPower: true, requiresNetworkConnectivity: true))

        for _ in 0..<50 { rig.source.photoLibraryChanged() }
        await rig.source.schedule(plan)
        rig.source.applicationBecameActive()
        for _ in 0..<50 { rig.source.photoLibraryChanged() }
        await rig.handled(101)
        XCTAssertEqual(rig.scheduler.submitted, first, "No change to Photos asks for a later window.")
        XCTAssertTrue(rig.scheduler.cancelled.isEmpty)

        // A window iOS used up is asked for again; a changed plan replaces the requests.
        rig.source.applicationEnteredBackground()
        rig.scheduler.launch(.refresh)
        XCTAssertEqual(rig.scheduler.submitted.map(\.kind), [.processing, .refresh, .refresh])
        await rig.source.schedule(.none)
        XCTAssertEqual(rig.scheduler.cancelled, BackgroundWindowKind.allCases.map(\.identifier))
        await rig.stop()
    }

    func testRequestsHeldFromAnEarlierLaunchAreKept() async {
        let scheduler = FakeTaskScheduler()
        scheduler.pendingAtLaunch = [
            WindowRequest(kind: .processing, shape: WindowRequest.Shape(requiresExternalPower: false, requiresNetworkConnectivity: true),
                          earliestBeginDate: nil),
            WindowRequest(kind: .refresh, shape: WindowRequest.Shape(), earliestBeginDate: nil),
        ]
        let source = LifecycleEventSource(initial: .launch(active: false), scheduler: scheduler)
        await source.schedule(.automatic(requireCharging: false, triggerDelay: 30))
        XCTAssertTrue(scheduler.submitted.isEmpty, "A relaunch keeps the windows iOS already holds.")
        await source.schedule(.automatic(requireCharging: true, triggerDelay: 30))
        XCTAssertEqual(scheduler.submitted.map(\.kind), [.processing], "Only the request whose shape changed is replaced.")
    }

    func testIdentifiersAreTodays() {
        XCTAssertEqual(BackgroundWindowKind.processing.identifier, BackupLifecycle.identifier)
        XCTAssertEqual(BackgroundWindowKind.refresh.identifier, BackupLifecycle.refreshIdentifier)
        let lease = BGTaskLease(identifier: BackupLifecycle.refreshIdentifier) { _ in }
        XCTAssertEqual(lease.kind, .refresh)
    }

    // MARK: Source

    func testConditionsFoldIntoOneSnapshotAndYieldOnlyOnChange() async {
        let source = LifecycleEventSource(initial: .launch(active: false), scheduler: FakeTaskScheduler())
        source.networkChanged(.unmetered)
        source.chargingChanged(false)
        source.chargingChanged(true)
        source.chargingChanged(true)
        source.thermalChanged(.serious)
        source.lowPowerChanged(false)
        source.applicationBecameActive()
        source.applicationBecameActive()
        source.finish()
        var events: [String] = []
        for await event in source.events {
            switch event {
            case .environment(let snapshot): events.append("environment charging=\(snapshot.charging) thermal=\(snapshot.thermal.rawValue)")
            case .becameActive: events.append("becameActive")
            default: events.append("other")
            }
        }
        XCTAssertEqual(events, ["environment charging=true thermal=0", "environment charging=true thermal=2", "becameActive"])
        XCTAssertEqual(source.snapshot, EnvironmentSnapshot(appActive: true, network: .unmetered, charging: true, thermal: .serious, lowPower: false))
    }

    // MARK: Assertions

    func testBackgroundAssertionEndsOnceAndExpiryCancelsTheStep() async {
        let time = FakeBackgroundTime()
        let gate = TransferGate()
        let run = Task { await BackgroundAssertion.run("step", granting: time) { await gate.wait(); return Task.isCancelled } }
        await untilTransfers("The step holds time.") { time.held == 1 && gate.waiting == 1 }
        time.expireAll()
        XCTAssertEqual(time.ended, [1], "Expiry ends the assertion before its handler returns.")
        gate.open()
        let cancelled = await run.value
        XCTAssertTrue(cancelled, "Expiry cancels the step.")
        XCTAssertEqual(time.ended, [1], "It ends once.")
    }

    func testGoingToTheBackgroundHoldsTimeUntilTheHandOff() async {
        let work = FakeWindowWork()
        let handoff = TransferGate()
        work.hold("runUntilHandedOff", at: handoff)
        work.setTriggerDelay(nil)
        let rig = await Rig(active: true, work: work)
        rig.source.applicationEnteredBackground()
        await untilTransfers("Time is held.") { rig.time.held == 1 }
        XCTAssertEqual(work.count("discover"), 0)
        handoff.open()
        await untilTransfers("The time goes back once the job is the daemon's.") { rig.time.held == 0 }
        XCTAssertEqual(rig.time.ended.count, 1)
        await rig.stop()
    }

    // MARK: Engine

    func testEngineHandsOverAPlanOnlyWhenItChanges() async throws {
        let scheduler = RecordingWindowScheduler()
        let h = try await TransferEngineHarness(scheduler: scheduler)
        try await h.engine.start()
        await untilTransfers("The first plan.") { scheduler.plans.count == 1 }
        try await h.engine.setIntent(.automatic)
        var preferences = TransferPreferences(Legacy.BackupPreferences())
        preferences.automatic = true
        try await h.engine.setPreferences(preferences)
        await untilTransfers("Automatic backup's plan.") { scheduler.plans.count == 2 }
        _ = try await h.engine.enqueue([h.photo("a"), h.photo("b")])
        try await untilTransfers("Both commit.") { try await h.allConfirmed("a", "b") }
        await h.engine.conditionsChanged()
        // Back up now, with automatic backup on: today's windows stay.
        try await h.engine.setIntent(.manual)
        try await h.engine.setPreferences(preferences)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scheduler.plans, [.none, .automatic(requireCharging: false, triggerDelay: 30)],
                       "A manual run, work and commands that change nothing schedule nothing.")

        preferences.requireCharging = true
        try await h.engine.setPreferences(preferences)
        preferences.automatic = false
        try await h.engine.setPreferences(preferences)
        preferences.automatic = true
        try await h.engine.setPreferences(preferences)
        try await h.engine.setIntent(.paused)
        try await h.engine.setIntent(.automatic)
        h.authorization.setReadOnly(true)
        await untilTransfers("Read-only blocks the engine and its windows.") { scheduler.plans.count == 8 }
        let charging = SchedulePlan.automatic(requireCharging: true, triggerDelay: 30)
        XCTAssertEqual(scheduler.plans.suffix(6), [charging, .none, charging, .none, charging, .none],
                       "The preference decides the windows; a pause and a block drop them.")
        await h.tearDown()
    }

    func testARefusedRequestIsAskedForAgainAndReported() async {
        let scheduler = FakeTaskScheduler()
        let source = LifecycleEventSource(initial: .launch(active: false), scheduler: scheduler)
        XCTAssertTrue(source.register())
        await source.schedule(.automatic(requireCharging: false, triggerDelay: 30))
        XCTAssertEqual(scheduler.submitted.map(\.kind), [.processing, .refresh])
        scheduler.answer(.processing, nil)
        scheduler.answer(.refresh, "Background App Refresh is off")
        XCTAssertEqual(source.schedulingError,
                       "iOS could not schedule automatic backup: Background App Refresh is off. You can still use Back up now.")

        source.photoLibraryChanged()
        XCTAssertEqual(scheduler.submitted.map(\.kind), [.processing, .refresh, .refresh], "Only the refused request is asked for again.")
        source.photoLibraryChanged()
        source.applicationBecameActive()
        XCTAssertEqual(scheduler.submitted.count, 3, "A request iOS has not answered is not replaced.")
        scheduler.answer(.refresh, nil)
        XCTAssertNil(source.schedulingError, "iOS took the request.")
        source.applicationEnteredBackground()
        source.photoLibraryChanged()
        XCTAssertEqual(scheduler.submitted.count, 3, "Nothing more is asked for.")
        source.finish()
    }
}

/// The engine's hand-off behind the window's other steps, which only record.
private struct EngineWindowWork: BackgroundWindowWork {
    let engine: TransferEngine<TestClock>
    let recorder = FakeWindowWork()

    func reconcile() async throws { try await recorder.reconcile() }
    func applyOutcomes() async throws { try await recorder.applyOutcomes() }
    func submitStaged() async throws { try await recorder.submitStaged() }
    func preSyncMetadata() async throws { try await recorder.preSyncMetadata() }
    func discover() async throws { try await recorder.discover() }
    func conditionsChanged() async { await recorder.conditionsChanged() }
    func automaticTriggerDelay() async -> Duration? { nil }

    func daemonOwnsWork() async -> Bool {
        _ = await recorder.daemonOwnsWork()
        return await engine.daemonOwnsWork()
    }

    func runUntilHandedOff() async -> WindowHandoff {
        _ = await recorder.runUntilHandedOff()
        return await engine.handoff()
    }
}

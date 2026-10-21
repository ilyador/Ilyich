import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// The account's sync engine: when passes run, what they publish, and what stops them.
@MainActor final class SyncEngineTests: XCTestCase {
    private let february = MonthKey(year: 2026, month: 2)

    /// Pull to refresh, and the refresh after a change the app made, run as passes of the engine:
    /// the change comes back to the caller and is published like any other pass's.
    func testUserRefreshPublishesItsChanges() async throws {
        let harness = try makeSyncHarness()
        try await harness.primeIndex()
        harness.server.route("POST", "sync/stream", SyncEvents.stream([SyncEvents.asset("fresh"), SyncEvents.complete()]))
        let published = await harness.engine.changes()
        let library = NativeLibraryAPI(client: harness.api, entities: harness.entities, sync: harness.engine)

        let refreshed = try await library.refresh()

        let returned = try XCTUnwrap(refreshed, "NativeLibraryAPI.refresh returns the change.")
        XCTAssertEqual(returned.upserted, ["fresh": .init(from: nil, to: february)], "The refresh says what it changed.")
        XCTAssertEqual(returned.account, harness.authorization.account)
        XCTAssertEqual(returned.origin, .sync)
        var changes = published.makeAsyncIterator()
        let first = await changes.next()
        XCTAssertEqual(first?.upserted, returned.upserted, "The same change was published.")
        XCTAssertEqual(harness.notifications.all, [["collections": false, "accessChanged": false]],
                       "The screens heard of it once, as a change to photos alone.")
        let settled = await becomesTrue { !harness.status.status.isSyncing && harness.status.status.lastSyncDate != nil }
        XCTAssertTrue(settled, "The status shows the pass finished: \(harness.status.status)")
    }

    /// A pass whose stream holds only its completion marker changed nothing: the caller gets an
    /// empty change, nothing is published and the screens reload nothing, though the marker is
    /// still acknowledged. The marker that completes the index is another matter: feeds move to it.
    func testCompleteMarkerAloneIsNotALibraryChange() async throws {
        let harness = try makeSyncHarness()
        try await harness.primeIndex()
        let published = Recorded<LibraryChange>()
        let stream = await harness.engine.changes()
        let listener = Task { for await change in stream { published.append(change) } }
        defer { listener.cancel() }

        let change = try await harness.engine.refresh()

        XCTAssertTrue(change.isEmpty, "\(change)")
        XCTAssertEqual(harness.server.requests("POST", "sync/ack").count, 1, "The marker is acknowledged at the end of the stream.")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(published.count, 0, "Nothing was published.")
        XCTAssertTrue(harness.notifications.all.isEmpty, "Neither the feed nor the shelves reload.")

        let first = try makeSyncHarness()
        _ = try await first.entities.prepare(sessionFingerprint: first.api.syncSessionFingerprint())
        try await first.entities.markResetRequested()
        let completing = try await first.engine.refresh()
        XCTAssertTrue(completing.routingChanged, "The first completion moves the feeds to the offline library.")
        XCTAssertFalse(completing.reset)
        XCTAssertEqual(first.notifications.count, 1)
    }

    /// A pass can end in a cancellation nobody asked for: here the index refuses the pass's write
    /// because it was emptied meanwhile. That pass fails quietly, sync isn't left running, and
    /// the next request gets a pass of its own.
    func testFencedCancellationDoesNotStrandSync() async throws {
        let harness = try makeSyncHarness()
        try await harness.primeIndex()
        let held = StubServer.Gate()
        harness.server.route("POST", "sync/stream", responses: [
            SyncEvents.stream([SyncEvents.asset("fenced"), SyncEvents.complete()]).waiting(for: held),
            SyncEvents.stream([SyncEvents.asset("after"), SyncEvents.complete()]),
        ])
        let first = Task { try await harness.engine.refresh() }
        let streaming = await becomesTrue { held.waiting == 1 }
        XCTAssertTrue(streaming, "The first pass did not start its stream.")

        try await harness.entities.clear()
        held.open()

        do {
            _ = try await first.value
            XCTFail("A pass whose writes the index refused does not succeed.")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let idle = await becomesTrue { !harness.status.status.isSyncing }
        XCTAssertTrue(idle, "Sync is not left running.")
        XCTAssertNil(harness.status.status.error, "A fenced pass fails quietly.")
        let fenced = try await harness.entities.asset(id: "fenced")
        XCTAssertNil(fenced, "Nothing the fenced pass streamed was kept.")

        let next = try await harness.engine.refresh()
        let after = try await harness.entities.asset(id: "after")
        XCTAssertNotNil(after, "The next request ran a pass of its own.")
        XCTAssertNotNil(next.upserted["after"])
        XCTAssertTrue(next.reset, "The emptied index was filled again from scratch.")
        XCTAssertEqual(harness.streamRequests.count, 2)
    }

    /// The live connection opens only after a pass, while the app is in front. A pass that ends
    /// after the app left never opens it, and once stopped, it never connects again.
    func testEventsCannotStartAfterStop() async throws {
        let harness = try makeSyncHarness(foreground: true)
        try await harness.primeIndex()
        let held = StubServer.Gate()
        harness.server.route("POST", "sync/stream", responses: [SyncHarness.completeStream.waiting(for: held), SyncHarness.completeStream])
        await harness.engine.start()
        let streaming = await becomesTrue { held.waiting == 1 }
        XCTAssertTrue(streaming, "Coming to the front did not sync.")

        harness.presence.isForeground = false
        await harness.engine.presenceChanged()
        held.open()
        let idle = await becomesTrue { !harness.status.status.isSyncing }
        XCTAssertTrue(idle)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.live.connects, 0, "The pass the app left behind never opened the live connection.")

        harness.presence.isForeground = true
        await harness.engine.presenceChanged()
        let connected = await becomesTrue { harness.live.isOpen }
        XCTAssertTrue(connected, "Back in front, the live connection opens after the pass.")

        await harness.engine.shutdown()
        let closed = await becomesTrue { !harness.live.isOpen }
        XCTAssertTrue(closed, "Sign-out closed it.")
        try await Task.sleep(for: .milliseconds(1_300))
        XCTAssertEqual(harness.live.connects, 1, "A stopped connection never connects again, not even after the first retry delay.")
        harness.live.send(ServerInvalidation(configurationChanged: true))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(harness.streamRequests.count, 2, "Nothing asks for a pass after sign-out.")
    }

    /// A background backup window holds a lease on the pass it asks for. When the window runs
    /// out while the app is in front, the pass goes on and foreground sync carries on as usual:
    /// the pass is published and the live connection opens. In the background nobody else needs
    /// the pass, so it stops.
    func testBackgroundLeaseExpiryKeepsForegroundSync() async throws {
        let harness = try makeSyncHarness(foreground: true)
        try await harness.primeIndex()
        let held = StubServer.Gate()
        harness.server.route("POST", "sync/stream", responses: [
            SyncEvents.stream([SyncEvents.asset("seen"), SyncEvents.complete()]).waiting(for: held), SyncHarness.completeStream,
        ])
        await harness.engine.start()
        let streaming = await becomesTrue { held.waiting == 1 }
        XCTAssertTrue(streaming)
        let window = Task { await harness.engine.prepareForBackgroundBackup() }
        let leased = await becomesTrue { await harness.engine.waiting == 1 }
        XCTAssertTrue(leased, "The window did not ask for a pass.")

        window.cancel()
        let ready = await window.value
        XCTAssertFalse(ready, "A window that ran out is not ready.")
        held.open()

        let kept = await becomesTrue { (try? await harness.entities.asset(id: "seen")) != nil }
        XCTAssertTrue(kept, "The foreground's pass went on.")
        let connected = await becomesTrue { harness.live.isOpen }
        XCTAssertTrue(connected, "The live connection opened after it.")
        let idle = await becomesTrue { !harness.status.status.isSyncing }
        XCTAssertTrue(idle)
        XCTAssertNil(harness.status.status.error)
        XCTAssertEqual(harness.notifications.count, 1, "The pass was published.")

        let background = try makeSyncHarness(foreground: false)
        try await background.primeIndex()
        let backgroundHeld = StubServer.Gate()
        background.server.route("POST", "sync/stream", SyncEvents.stream([SyncEvents.asset("unseen"), SyncEvents.complete()]).waiting(for: backgroundHeld))
        await background.engine.start()
        let backgroundWindow = Task { await background.engine.prepareForBackgroundBackup() }
        let backgroundStreaming = await becomesTrue { backgroundHeld.waiting == 1 }
        XCTAssertTrue(backgroundStreaming)
        backgroundWindow.cancel()
        let backgroundReady = await backgroundWindow.value
        XCTAssertFalse(backgroundReady)
        backgroundHeld.open()
        let stopped = await becomesTrue { !background.status.status.isSyncing }
        XCTAssertTrue(stopped)
        try await Task.sleep(for: .milliseconds(100))
        let unseen = try await background.entities.asset(id: "unseen")
        XCTAssertNil(unseen, "In the background the pass stopped with the window.")
        XCTAssertEqual(background.live.connects, 0)
    }

    /// A background window that isn't cut short gets its pass, published like any other, and
    /// finds the library ready. A window whose session ends first finds it not ready.
    func testABackgroundWindowSyncsOnceAndIsReady() async throws {
        let harness = try makeSyncHarness()
        try await harness.primeIndex()
        harness.server.route("POST", "sync/stream", SyncEvents.stream([SyncEvents.asset("queued"), SyncEvents.complete()]))
        let ready = await harness.engine.prepareForBackgroundBackup()
        XCTAssertTrue(ready)
        XCTAssertEqual(harness.streamRequests.count, 1)
        XCTAssertEqual(harness.notifications.count, 1)
        XCTAssertEqual(harness.live.connects, 0, "No live connection in the background.")

        let ended = try makeSyncHarness()
        try await ended.primeIndex()
        let held = StubServer.Gate()
        ended.server.route("POST", "sync/stream", SyncHarness.completeStream.waiting(for: held))
        let window = Task { await ended.engine.prepareForBackgroundBackup() }
        let streaming = await becomesTrue { held.waiting == 1 }
        XCTAssertTrue(streaming)
        ended.authorization.end()
        held.open()
        let endedReady = await window.value
        XCTAssertFalse(endedReady, "The lease ended with the session.")
    }

    /// Coming to the front syncs, and so does the live connection's connect, but when the server
    /// has nothing new the screens hear nothing, so the feed doesn't reload. Returning from
    /// Control Center, which never left the front, syncs once too, and reloads nothing either.
    func testForegroundingWithNoServerChangeReloadsNothing() async throws {
        let harness = try makeSyncHarness(foreground: true)
        try await harness.primeIndex()
        await harness.engine.start()
        let connected = await becomesTrue { harness.live.isOpen }
        XCTAssertTrue(connected)
        guard case .invalidation(let connectAck) = try SocketEventPacket.parse(#"40{"sid":"connected"}"#) else {
            return XCTFail("The namespace's connect ack asks for a pass.")
        }
        harness.live.send(connectAck)
        let synced = await becomesTrue { harness.streamRequests.count == 2 }
        XCTAssertTrue(synced, "The connect ack asked for a pass.")

        harness.presence.isForeground = false
        await harness.engine.presenceChanged()
        harness.presence.isForeground = true
        await harness.engine.presenceChanged()
        let returned = await becomesTrue { harness.streamRequests.count == 3 }
        XCTAssertTrue(returned, "Coming back to the front synced.")
        // Becoming active again without leaving the front, after Control Center, syncs once.
        await harness.engine.presenceChanged()
        let reactivated = await becomesTrue { harness.streamRequests.count == 4 }
        XCTAssertTrue(reactivated, "Becoming active without leaving the front synced.")
        let idle = await becomesTrue { !harness.status.status.isSyncing }
        XCTAssertTrue(idle)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(harness.streamRequests.count, 4)
        XCTAssertTrue(harness.notifications.all.isEmpty, "Nothing reloaded: \(harness.notifications.all)")
        XCTAssertNil(harness.status.status.error)
    }

    /// A photo edited on the web arrives as AssetEditReadyV2, carrying the photo's new media
    /// revision. When the stream that follows doesn't carry the photo, because only its previews
    /// were made again, the hint's revision still reaches the published change, so the photo is
    /// shown anew. A revision the index already holds changes nothing.
    func testAnEditHintedOnTheLiveConnectionReachesTheChange() async throws {
        let harness = try makeSyncHarness(foreground: true)
        try await harness.primeIndex([SyncEvents.asset("photo", revision: "r1")])
        let published = Recorded<LibraryChange>()
        let stream = await harness.engine.changes()
        let listener = Task { for await change in stream { published.append(change) } }
        defer { listener.cancel() }
        await harness.engine.start()
        let connected = await becomesTrue { harness.live.isOpen }
        XCTAssertTrue(connected)

        guard case .invalidation(let edit) = try SocketEventPacket.parse(#"42["AssetEditReadyV2",{"asset":{"id":"photo","mediaRevision":"r2"},"edit":[]}]"#),
              case .invalidation(let same) = try SocketEventPacket.parse(#"42["on_asset_update",{"id":"photo","mediaRevision":"r1"}]"#) else {
            return XCTFail("Both hints ask for a pass.")
        }
        harness.live.send(edit)
        let arrived = await becomesTrue { published.count == 1 }
        XCTAssertTrue(arrived, "The edit was published.")
        XCTAssertEqual(published.all.first?.mediaRevisions, ["photo": "r2"])
        XCTAssertEqual(harness.notifications.count, 1, "The feed and an open viewer reload.")

        harness.live.send(same)
        let passes = await becomesTrue { harness.streamRequests.count == 3 }
        XCTAssertTrue(passes)
        let idle = await becomesTrue { !harness.status.status.isSyncing }
        XCTAssertTrue(idle)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(published.count, 1, "A revision the index holds changes nothing.")
    }

    /// A pass that fails after some of its batches were committed still publishes what they
    /// changed, since no later pass would see it again, and the status says why it failed until
    /// a pass succeeds.
    func testAFailedPassPublishesWhatItCommitted() async throws {
        let harness = try makeSyncHarness()
        try await harness.primeIndex()
        // The stream breaks off before its completion marker.
        harness.server.route("POST", "sync/stream", responses: [SyncEvents.stream([SyncEvents.asset("committed")]), SyncHarness.completeStream])

        do {
            _ = try await harness.engine.refresh()
            XCTFail("A stream without its completion marker fails the pass.")
        } catch {}

        XCTAssertEqual(harness.notifications.count, 1, "What the pass committed was published.")
        let explained = await becomesTrue { harness.status.status.error != nil && !harness.status.status.isSyncing }
        XCTAssertTrue(explained, "\(harness.status.status)")
        await harness.engine.syncNow()
        let cleared = await becomesTrue { harness.status.status.error == nil && !harness.status.status.isSyncing }
        XCTAssertTrue(cleared, "A pass that succeeds clears the error.")
    }
}

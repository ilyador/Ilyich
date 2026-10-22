import Foundation
import XCTest
@testable import Ilyich

/// Notifications as a test sees them. Each kind of post can wait at a gate first.
@MainActor final class FakeNotificationPoster: TransferNotificationPosting {
    enum Post: Equatable {
        case started(UUID, kind: String, total: Int)
        case finished(UUID, kind: String, total: Int, completed: Int, failed: Int)
    }

    private(set) var posts: [Post] = []
    private(set) var withdrawn: [UUID] = []
    var startGate: TransferGate?
    /// Posts begun and not yet returned.
    private(set) var inFlight = 0

    func started(id: UUID, kind: String, total: Int) async {
        inFlight += 1
        if let startGate { await startGate.wait() }
        inFlight -= 1
        posts.append(.started(id, kind: kind, total: total))
    }

    func finished(id: UUID, kind: String, total: Int, completed: Int, failed: Int) async {
        posts.append(.finished(id, kind: kind, total: total, completed: completed, failed: failed))
    }

    func withdraw(id: UUID) { withdrawn.append(id) }
}

/// B4: notification_batches become notifications, started once and finished once across
/// relaunches, and never hold up the engine.
@MainActor final class TransferNotifierTests: XCTestCase {
    private func request(_ id: String, batch: UUID) -> TransferRequest {
        TransferRequest(source: .photo(DeviceAssetID(rawValue: id)), origin: .selection, batch: batch)
    }

    func testTerminalPostedOnceAcrossRelaunch() async throws {
        let h = try await TransferEngineHarness()
        let batch = UUID()
        _ = try await h.store.enqueue(["p1", "p2"].map { request($0, batch: batch) })
        let poster = FakeNotificationPoster()
        let notifier = TransferNotifier(store: h.store, poster: poster, authorization: h.authorization)

        await notifier.refresh()
        XCTAssertEqual(poster.posts, [.started(batch, kind: "Backup", total: 2)])
        await notifier.refresh()
        XCTAssertEqual(poster.posts.count, 1, "started goes out once")

        // One photo backs up, the other fails.
        try await h.engine.setIntent(.automatic)
        h.executor.script("p2", .fail { TransferItemFailure.unreadableFile })
        try await h.engine.start()
        try await untilTransfers("both jobs ran") {
            let counts = try await h.store.counts()
            return counts.failed == 1 && counts.remaining == 0
        }
        await notifier.refresh()
        XCTAssertEqual(poster.posts.last, .finished(batch, kind: "Backup", total: 2, completed: 1, failed: 1))

        // A relaunch: a new notifier on the same database posts nothing again.
        notifier.stop()
        let relaunched = FakeNotificationPoster()
        let again = TransferNotifier(store: h.store, poster: relaunched, authorization: h.authorization)
        await again.refresh()
        XCTAssertTrue(relaunched.posts.isEmpty)
        XCTAssertEqual(poster.posts.count, 2)
        await h.tearDown()
    }

    func testABatchThatFinishedBeforeItsNotificationGetsOnlyTheLastOne() async throws {
        let h = try await TransferEngineHarness()
        let batch = UUID()
        _ = try await h.store.enqueue([request("p1", batch: batch)])
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("backed up") { try await h.confirmed("p1") }

        let poster = FakeNotificationPoster()
        let notifier = TransferNotifier(store: h.store, poster: poster, authorization: h.authorization)
        await notifier.refresh()
        XCTAssertEqual(poster.posts, [.finished(batch, kind: "Backup", total: 1, completed: 1, failed: 0)])
        let left = try await h.store.notificationBatches()
        XCTAssertTrue(left.isEmpty, "a batch fully posted with no job left is pruned")
        await h.tearDown()
    }

    func testEngineProgressesWhileNotificationsHang() async throws {
        let h = try await TransferEngineHarness()
        let batch = UUID()
        let poster = FakeNotificationPoster()
        let gate = TransferGate()
        poster.startGate = gate
        let notifier = TransferNotifier(store: h.store, poster: poster, authorization: h.authorization)
        notifier.start()
        let following = notifier.follow(await h.engine.snapshots())

        _ = try await h.engine.enqueue(["p1", "p2", "p3"].map { request($0, batch: batch) })
        notifier.changed()
        try await untilTransfers("the started notification hangs") { poster.inFlight == 1 }
        try await h.engine.setIntent(.automatic)
        try await h.engine.start()
        try await untilTransfers("every photo backed up while the notification hangs") { try await h.allConfirmed("p1", "p2", "p3") }
        XCTAssertEqual(poster.inFlight, 1)
        XCTAssertTrue(poster.posts.isEmpty)

        gate.open()
        notifier.changed()
        try await untilTransfers("the last notification once the first returns") {
            poster.posts.contains(.finished(batch, kind: "Backup", total: 3, completed: 3, failed: 0))
        }
        XCTAssertEqual(poster.posts.first, .started(batch, kind: "Backup", total: 3))
        notifier.stop()
        following.cancel()
        await h.tearDown()
    }

    func testAPostThatCompletesAfterStopIsWithdrawnAndNotRecorded() async throws {
        let h = try await TransferEngineHarness()
        let batch = UUID()
        _ = try await h.store.enqueue([request("p1", batch: batch)])
        let poster = FakeNotificationPoster()
        let gate = TransferGate()
        poster.startGate = gate
        let notifier = TransferNotifier(store: h.store, poster: poster, authorization: h.authorization)
        let refresh = Task { await notifier.refresh() }
        try await untilTransfers("posting") { poster.inFlight == 1 }
        notifier.stop()
        gate.open()
        await refresh.value
        XCTAssertEqual(poster.withdrawn, [batch])
        let batches = try await h.store.notificationBatches()
        XCTAssertEqual(batches.first?.startedPosted, false)

        // Signed out: nothing is posted at all.
        h.authorization.end()
        let later = FakeNotificationPoster()
        await TransferNotifier(store: h.store, poster: later, authorization: h.authorization).refresh()
        XCTAssertTrue(later.posts.isEmpty)
        await h.tearDown()
    }

    func testACancelledBatchIsWithdrawnQuietly() async throws {
        let h = try await TransferEngineHarness()
        let batch = UUID()
        _ = try await h.engine.enqueue([request("p1", batch: batch)])
        let poster = FakeNotificationPoster()
        let notifier = TransferNotifier(store: h.store, poster: poster, authorization: h.authorization)
        await notifier.refresh()
        try await h.engine.cancel([.photo(DeviceAssetID(rawValue: "p1"))])
        await notifier.refresh()
        XCTAssertEqual(poster.posts, [.started(batch, kind: "Backup", total: 1)])
        XCTAssertEqual(poster.withdrawn, [batch])
        let batches = try await h.store.notificationBatches()
        XCTAssertTrue(batches.isEmpty)
        await h.tearDown()
    }

    func testShareBatchesUseTodaysWords() async throws {
        let h = try await TransferEngineHarness()
        let batch = UUID()
        _ = try await h.store.enqueue([TransferRequest(source: .shared(batch: UUID(), attachment: "a"), origin: .shareApproval, batch: batch)])
        let poster = FakeNotificationPoster()
        await TransferNotifier(store: h.store, poster: poster, authorization: h.authorization).refresh()
        XCTAssertEqual(poster.posts, [.started(batch, kind: "Shared upload", total: 1)])
        await h.tearDown()
    }
}

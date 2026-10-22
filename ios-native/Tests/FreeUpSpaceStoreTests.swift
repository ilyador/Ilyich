import Foundation
import IlyichPlatform
import Photos
import XCTest
@testable import Ilyich

/// Free up space's per-account store against the cleanup fakes (REBUILD_ROADMAP.md P4).
@MainActor final class FreeUpSpaceStoreTests: XCTestCase {

    /// The saved cutoff is a number of days before today: checking a week later, with the store
    /// alive all along, keeps it at the same number of days.
    func testTheSavedCutoffStaysTheSameNumberOfDaysAsDaysPass() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a")
        h.settings.setCutoffDaysAgo(30)
        let today = Locked(Date())
        let store = FreeUpSpaceStore(service: h.service, settings: h.settings, adapter: h.adapter, now: { today.value })

        await store.appear()
        await store.check()?.value
        XCTAssertTrue(store.checked)
        XCTAssertEqual(h.settings.load().cutoffDaysAgo, 30)
        XCTAssertEqual(store.cutoff, h.settings.load().cutoff(now: today.value))

        store.disappear()
        today.mutate { $0 = $0.addingTimeInterval(7 * 86_400) }
        await store.appear()
        await store.check()?.value
        XCTAssertTrue(store.checked)
        XCTAssertEqual(h.settings.load().cutoffDaysAgo, 30, "A week later the saved cutoff is still 30 days, not 37.")
        XCTAssertEqual(store.cutoff, h.settings.load().cutoff(now: today.value))
        store.disappear()
    }

    /// A check dropped as a whole while the screen wasn't following (another screen pushed on top)
    /// asks to be made again when the screen comes back, rather than showing stale groups.
    func testACheckDroppedWhileAwayAsksToCheckAgainOnReturn() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a")
        h.addBackedUp("favorite", favorite: true)
        let store = FreeUpSpaceStore(service: h.service, settings: h.settings, adapter: h.adapter)

        await store.appear()
        await store.check()?.value
        XCTAssertTrue(store.checked)
        XCTAssertEqual(store.exclusions.map(\.exclusion), [.favorite])

        store.disappear()
        h.photos.emit(PhotoLibraryChangeDetails(requiresFullReload: true))
        let service = h.service
        let deadline = ContinuousClock.now + .seconds(5)
        while await service.currentScanID != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let dropped = await service.currentScanID
        XCTAssertNil(dropped)

        await store.appear()
        XCTAssertFalse(store.checked)
        XCTAssertTrue(store.candidates.isEmpty)
        XCTAssertTrue(store.exclusions.isEmpty, "No groups from a check that no longer holds.")
        XCTAssertNotNil(store.message)
        store.disappear()
    }

    /// Coming back to a check that still holds keeps it.
    func testReturningToACheckThatStillHoldsKeepsIt() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a"); h.addBackedUp("favorite", favorite: true)
        let store = FreeUpSpaceStore(service: h.service, settings: h.settings, adapter: h.adapter)

        await store.appear()
        await store.check()?.value
        XCTAssertTrue(store.checked)
        store.disappear()
        await store.appear()

        XCTAssertTrue(store.checked)
        XCTAssertEqual(store.exclusions.map(\.exclusion), [.favorite])
        XCTAssertNil(store.message)
        store.disappear()
    }
}

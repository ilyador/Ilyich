import Foundation
import XCTest
@testable import Ilyich

/// F4: feed sessions, the saved library and typed changes. A change from the viewer or the sync
/// updates the feed in place and keeps its place; the library a filter clears back to comes back
/// at once, patched, and is then checked against the source; a pending feed replaces the frozen
/// one once its first months are ready, never on a failure.
@MainActor final class FeedSessionTests: XCTestCase {
    private static let march = "2026-03-01T00:00:00Z", february = "2026-02-01T00:00:00Z", april = "2026-04-01T00:00:00Z"

    func testArchivingFromTheViewerRemovesThePhotoFromTheTimeline() async throws {
        let api = try ChangingLibrary([photo("m1", "2026-03-20"), photo("m2", "2026-03-10"), photo("f1", "2026-02-10")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("The months did not load.") { store.loaded[Self.march] != nil && store.loaded[Self.february] != nil }
        await store.settleProjections()
        let position = GridPosition(section: Self.march, item: 0, offset: 12, assetID: "m1")
        store.position = position
        let reset = store.resetID, summaries = await api.summaryCalls

        // The viewer archives m2 and shows the record the server answered with.
        var archived = try XCTUnwrap(store.loaded[Self.march]?.first { $0.id == "m2" })
        archived.visibility = .archive
        await api.set(archived)
        store.update(archived)
        XCTAssertEqual(store.sections.map(\.count), [1, 1], "The photo leaves its month at once.")
        await store.settleProjections()
        XCTAssertEqual(store.entry(section: 0, item: 0)?.id, "m1")
        XCTAssertEqual(store.dayGroups(section: 0).map(\.count), [1])
        XCTAssertEqual(store.resetID, reset, "In place: the grid keeps where it is.")
        XCTAssertEqual(store.position, position)
        let afterUpdate = await api.summaryCalls
        XCTAssertEqual(afterUpdate, summaries, "Nothing is read again for it.")

        // The sync's change follows: only the photo's month is read again, and it stays out.
        let reads = await api.monthReads.count
        await store.apply(change(upserted: ["m2": move(Self.march, Self.march)]))
        try await until("March was not read again.") { await api.monthReads.count > reads && store.loaded[Self.march] != nil }
        let reread = await api.monthReads.dropFirst(reads)
        XCTAssertEqual(Array(reread), [Self.march], "Only the month the change touched is read again.")
        await store.settleProjections()
        XCTAssertEqual(store.loaded[Self.march]?.map(\.id), ["m1"])
        XCTAssertEqual(store.resetID, reset)
    }

    func testUnfavoritingInFavoritesRemovesThePhoto() async throws {
        let api = try ChangingLibrary([photo("a", "2026-03-20", favorite: true), photo("b", "2026-03-10", favorite: true),
                                       photo("c", "2026-03-05")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("The library did not load.") { store.loaded[Self.march]?.count == 3 }
        store.setFeed(.favorites, title: "Favorites")
        try await until("Favorites did not replace the library.") { !store.isReplacingFeed && store.loaded[Self.march]?.count == 2 }

        var unfavorited = try XCTUnwrap(store.loaded[Self.march]?.first { $0.id == "b" })
        unfavorited.isFavorite = false
        store.update(unfavorited)
        XCTAssertEqual(store.sections.map(\.count), [1], "The photo leaves Favorites at once.")
        XCTAssertEqual(store.asset(section: 0, item: 0)?.id, "a")
        // A read of the month before the offline library has the change can't bring it back.
        let reads = await api.monthReads.count
        await store.reload(preservingPosition: true)
        try await until("March was not read again.") { await api.monthReads.count > reads }
        try await Task.sleep(for: .milliseconds(100))
        await store.settleProjections()
        XCTAssertEqual(store.loaded[Self.march]?.map(\.id), ["a"])
        XCTAssertEqual(store.sections.map(\.count), [1])

        await api.set(unfavorited)
        store.clearFilters()
        XCTAssertEqual(store.sections.map(\.count), [3], "The library keeps it, with its new record.")
        XCTAssertEqual(store.loaded[Self.march]?.first { $0.id == "b" }?.isFavorite, false)
    }

    func testLockedUpdateKeepsTheTimelinePosition() async throws {
        let api = try ChangingLibrary([photo("m1", "2026-03-20"), photo("m2", "2026-03-10"), photo("f1", "2026-02-12"),
                                       photo("f2", "2026-02-10")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("The months did not load.") { store.loaded[Self.march] != nil && store.loaded[Self.february] != nil }
        let position = GridPosition(section: Self.february, item: 1, offset: 40, assetID: "f2")
        store.position = position
        let reset = store.resetID, summaries = await api.summaryCalls

        var locked = try XCTUnwrap(store.loaded[Self.march]?.first { $0.id == "m2" })
        locked.visibility = .locked
        store.update(locked)
        XCTAssertEqual(store.sections.map(\.count), [1, 2], "The locked photo leaves at once.")
        XCTAssertNil(store.loaded[Self.march]?.first { $0.id == "m2" })
        try await Task.sleep(for: .milliseconds(100))
        let after = await api.summaryCalls
        XCTAssertEqual(after, summaries, "The library is not read again from its top.")
        XCTAssertEqual(store.resetID, reset)
        XCTAssertEqual(store.position, position, "The grid stays on the photo it shows.")
        XCTAssertEqual(store.restoredIndex(for: position).map { [$0.section, $0.item] }, [1, 1])
    }

    func testClearingRevalidatesTheRestoredLibrarySummary() async throws {
        let api = try ChangingLibrary([photo("m1", "2026-03-20"), photo("m2", "2026-03-10", favorite: true)])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("The library did not load.") { store.loaded[Self.march]?.count == 2 }
        let position = GridPosition(section: Self.march, item: 1, offset: 8, assetID: "m2")
        store.position = position
        store.setFeed(.favorites, title: "Favorites")
        try await until("Favorites did not replace the library.") { !store.isReplacingFeed && store.loaded[Self.march]?.count == 1 }

        // While Favorites shows, a photo arrives in a new month and another in March, and no
        // change reaches the store.
        await api.set(try photo("new", "2026-04-02"))
        await api.set(try photo("m3", "2026-03-05"))
        let summaries = await api.summaryCalls
        store.clearFilters()
        XCTAssertEqual(store.sections.map(\.id), [Self.march], "The saved library comes back at once.")
        XCTAssertEqual(store.restorePosition, position)
        try await until("The restored library was not counted again.") { await api.summaryCalls > summaries }
        try await until("The new month did not show.") { store.sections.map(\.id) == [Self.april, Self.march] }
        try await until("March, counted otherwise than its rows, was not read again.") { store.loaded[Self.march]?.count == 3 }
        XCTAssertEqual(store.sections.map(\.count), [1, 3])
        XCTAssertFalse(store.isReplacingFeed)
    }

    func testDeviceSnapshotDuringReplacementIsShownAfterCommit() async throws {
        let api = try ChangingLibrary([photo("server", "2026-01-15", favorite: true)])
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        defer { store.stop() }
        // The app opened on a filter, so there is no saved library: clearing loads it, frozen.
        store.setFeed(.favorites, title: "Favorites")
        try await until("Favorites did not load.") { !store.isReplacingFeed && store.totalCount == 1 }
        await api.holdSummaries()
        let summaries = await api.summaryCalls
        store.clearFilters()
        try await until("The library was never asked for.") { await api.summaryCalls > summaries }
        XCTAssertTrue(store.isReplacingFeed)

        // The phone publishes a photo newer than the server's while the library is on its way.
        let taken = try XCTUnwrap(APIDate.parse("2026-02-10T12:00:00Z"))
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "phone", date: taken)]))
        await store.settleProjections()
        XCTAssertEqual(store.sections.map(\.id), ["2026-01-01T00:00:00Z"], "The frozen feed stays as it was.")
        await api.releaseSummaries()
        try await until("The library did not replace the frozen feed.") { !store.isReplacingFeed }
        await store.settleProjections()
        XCTAssertEqual(store.sections.map(\.id), ["2026-02-01", "2026-01-01T00:00:00Z"], "The phone's photo leads the library.")
        XCTAssertEqual(store.entry(section: 0, item: 0)?.local?.id, "phone")
    }

    /// FEED-2 on the path itself: a library loading behind a frozen feed, led by a month only the
    /// phone has, commits once the server's first month is in.
    func testAPendingLibraryLedByAMonthOnlyThePhoneHasCommits() async throws {
        let api = try ChangingLibrary([photo("server", "2026-01-15", favorite: true)])
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        defer { store.stop() }
        let taken = try XCTUnwrap(APIDate.parse("2026-02-10T12:00:00Z"))
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "phone", date: taken)]))
        await store.settleProjections()
        // Opened on a filter, so there is no saved library: clearing loads it behind the filter.
        store.setFeed(.favorites, title: "Favorites")
        try await until("Favorites did not load.") { !store.isReplacingFeed && store.totalCount == 1 }
        store.clearFilters()
        let committed = await eventually { !store.isReplacingFeed }
        XCTAssertTrue(committed, "The library replaces the frozen feed.")
        await store.settleProjections()
        XCTAssertEqual(store.sections.map(\.id), ["2026-02-01", "2026-01-01T00:00:00Z"])
        XCTAssertEqual(store.entry(section: 0, item: 0)?.local?.id, "phone")
    }

    /// The owner saw a photo deleted inside a filter linger. The photo leaves the filter at once,
    /// and neither a read of its month from before the server's change, nor the library the
    /// filter clears back to, brings it back; the library keeps its place.
    func testADeletedPhotoStaysOutOfTheFilterAndTheLibraryItClearsBackTo() async throws {
        let api = try ChangingLibrary([photo("m1", "2026-03-20"), photo("m2", "2026-03-10"), photo("f1", "2026-02-10")],
                                      people: ["maya": ["m1", "m2"]])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("The months did not load.") { store.loaded[Self.march]?.count == 2 && store.loaded[Self.february] != nil }
        let position = GridPosition(section: Self.february, item: 0, offset: 20, assetID: "f1")
        store.position = position
        store.setPerson(Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: nil, isFavorite: nil))
        try await until("Maya's photos did not replace the library.") { !store.isReplacingFeed && store.title != "Library" && store.totalCount == 2 }

        // The viewer moves m2 to Trash. The server has it, but the offline library hasn't synced yet,
        // and a reload for another reason reads Maya's month from it meanwhile.
        store.removeLocally(["m2"])
        XCTAssertEqual(store.sections.map(\.count), [1])
        var reads = await api.monthReads.count
        await store.reload(preservingPosition: true)
        try await until("Maya's month was not read again.") { await api.monthReads.count > reads }
        try await Task.sleep(for: .milliseconds(100))
        await store.settleProjections()
        XCTAssertEqual(store.loaded[Self.march]?.map(\.id), ["m1"], "A read from before the sync leaves it out.")
        XCTAssertEqual(store.sections.map(\.count), [1])

        reads = await api.monthReads.count
        store.clearFilters()
        XCTAssertEqual(store.sections.map(\.count), [1, 1], "The library comes back without it.")
        XCTAssertEqual(store.restorePosition, position, "The library keeps its place.")
        // Counted again, March has a photo more than its rows, so it is read again.
        try await until("The library's March was not read again.") { await api.monthReads.count > reads }
        try await Task.sleep(for: .milliseconds(100))
        await store.settleProjections()
        XCTAssertEqual(store.loaded[Self.march]?.map(\.id), ["m1"], "Its month read again still leaves it out.")
        XCTAssertEqual(store.sections.map(\.count), [1, 1])

        // The sync runs: the offline library has it in Trash, and the months read after are trusted.
        var trashed = try photo("m2", "2026-03-10")
        trashed.isTrashed = true
        await api.set(trashed)
        reads = await api.monthReads.count
        await store.refreshAfterMutation()
        try await until("March was not read again after the sync.") { await api.monthReads.count > reads }
        try await Task.sleep(for: .milliseconds(100))
        await store.settleProjections()
        XCTAssertEqual(store.loaded[Self.march]?.map(\.id), ["m1"])
        XCTAssertEqual(store.sections.map(\.count), [1, 1])
        XCTAssertEqual(store.restoredIndex(for: position).map { [$0.section, $0.item] }, [1, 0])
    }

    /// A photo taken out that is still there, as a stack's cover is after a stack change, which
    /// reaches the feed the way a deletion does, comes back once the sync that follows has run.
    func testAPhotoTakenOutThatIsStillThereComesBackAfterTheSync() async throws {
        let api = try ChangingLibrary([photo("m1", "2026-03-20"), photo("m2", "2026-03-10")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("March did not load.") { store.loaded[Self.march]?.count == 2 }
        store.removeLocally(["m1"])
        XCTAssertEqual(store.loaded[Self.march]?.map(\.id), ["m2"])
        await store.refreshAfterMutation()
        try await until("The photo did not come back.") { store.loaded[Self.march]?.map(\.id) == ["m1", "m2"] }
        await store.settleProjections()
        XCTAssertEqual(store.sections.map(\.count), [2])
    }

    /// A sync's change reads again only the months it names, removes what it took out at once,
    /// and a change that touches no photo reads nothing.
    func testASyncChangeReadsAgainOnlyTheMonthsItTouches() async throws {
        let api = try ChangingLibrary([photo("a1", "2026-04-20"), photo("m1", "2026-03-20"), photo("m2", "2026-03-10"),
                                       photo("f1", "2026-02-10")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        store.visibleSections([0, 1, 2])
        try await until("The months did not load.") { [Self.april, Self.march, Self.february].allSatisfy { store.loaded[$0] != nil } }
        await store.settleProjections()

        var edited = try photo("f1", "2026-02-10")
        edited.originalFileName = "renamed.jpg"
        await api.set(edited)
        var reads = await api.monthReads.count
        await store.apply(change(upserted: ["f1": move(Self.february, Self.february)]))
        try await until("February was not read again.") { store.loaded[Self.february]?.first?.originalFileName == "renamed.jpg" }
        var reread = await api.monthReads.dropFirst(reads)
        XCTAssertEqual(Array(reread), [Self.february])

        // Deleted elsewhere: it leaves at once.
        await api.delete("m2")
        reads = await api.monthReads.count
        await store.apply(change(removed: ["m2"]))
        XCTAssertEqual(store.loaded[Self.march]?.map(\.id), ["m1"])
        XCTAssertEqual(store.sections.map(\.count), [1, 1, 1])
        try await Task.sleep(for: .milliseconds(100))
        reread = await api.monthReads.dropFirst(reads)
        XCTAssertEqual(Array(reread), [], "The counts agree with the rows, so no month is read again.")

        let summaries = await api.summaryCalls
        var memories = change()
        memories.memoriesChanged = true
        await store.apply(memories)
        let after = await api.summaryCalls
        XCTAssertEqual(after, summaries, "A change that touches no photo reads nothing.")
    }

    /// A pending feed whose first month comes back empty (its photos went between the summary and
    /// the month) has another month first: that one is waited for too, and the feed replaces the
    /// frozen one instead of the grid staying frozen.
    func testAPendingFeedWhoseFirstMonthEmptiesStillReplacesTheFrozenFeed() async throws {
        let api = try ChangingLibrary([photo("a", "2026-04-10", favorite: true), photo("m", "2026-03-10", favorite: true),
                                       photo("f", "2026-02-10", favorite: true), photo("plain", "2026-01-10")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("The library did not load.") { store.loaded[Self.april] != nil }
        await api.empty(Self.april)
        store.setFeed(.favorites, title: "Favorites")
        let committed = await eventually(within: .seconds(3)) { !store.isReplacingFeed }
        XCTAssertTrue(committed, "The feed replaces the frozen one.")
        XCTAssertEqual(store.sections.map(\.id), [Self.march, Self.february])
        XCTAssertNil(store.error)
    }

    /// A sync that lands while a new feed is pending reloads that feed, which then opens at its top
    /// rather than at the place the frozen feed had.
    func testASyncDuringAReplacementOpensTheNewFeedAtItsTop() async throws {
        let api = try ChangingLibrary([photo("m1", "2026-03-20", favorite: true), photo("f1", "2026-02-10")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("The library did not load.") { store.loaded[Self.february] != nil }
        store.position = GridPosition(section: Self.february, item: 0, offset: 30, assetID: "f1")
        await api.holdSummaries()
        let summaries = await api.summaryCalls
        store.setFeed(.favorites, title: "Favorites")
        try await until("Favorites were never asked for.") { await api.summaryCalls > summaries }
        let sync = Task { await store.reload(preservingPosition: true) }
        try await until("The sync's reload never asked for the feed.") { await api.summaryCalls > summaries + 1 }
        await api.releaseSummaries()
        await sync.value
        try await until("Favorites did not replace the library.") { !store.isReplacingFeed }
        XCTAssertNil(store.restorePosition, "The new feed opens at its top.")
        XCTAssertEqual(store.sections.map(\.id), [Self.march])
    }

    /// Archiving inside a filter takes the photo out of the filter and of the library the filter
    /// clears back to. The library's month, counted again after the clear and read from an offline
    /// library that hasn't synced the change yet, still leaves it out.
    func testArchivingInsideAFilterKeepsThePhotoOutOfTheLibraryItClearsBackTo() async throws {
        let api = try ChangingLibrary([photo("m1", "2026-03-20"), photo("m2", "2026-03-10"), photo("f1", "2026-02-10")],
                                      people: ["maya": ["m1", "m2"]])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("The months did not load.") { store.loaded[Self.march]?.count == 2 && store.loaded[Self.february] != nil }
        store.setPerson(Self.maya)
        try await until("Maya's photos did not replace the library.") { !store.isReplacingFeed && store.title != "Library" && store.totalCount == 2 }

        // The viewer archives m2 and shows the server's record; the offline library is yet to sync it.
        var archived = try XCTUnwrap(store.loaded[Self.march]?.first { $0.id == "m2" })
        archived.visibility = .archive
        store.update(archived)
        XCTAssertEqual(store.sections.map(\.count), [1], "The photo leaves Maya's photos at once.")

        let reads = await api.monthReads.count
        store.clearFilters()
        XCTAssertEqual(store.sections.map(\.count), [1, 1], "The library comes back without it.")
        // Counted again, March has a photo more than its rows, so it is read again.
        try await until("The library's March was not read again.") { await api.monthReads.count > reads }
        try await Task.sleep(for: .milliseconds(100))
        await store.settleProjections()
        XCTAssertEqual(store.loaded[Self.march]?.map(\.id), ["m1"], "A read from before the sync leaves it out of the library too.")
        XCTAssertEqual(store.sections.map(\.count), [1, 1])
    }

    /// A sync's reload names the months its change touched. When another change's reload takes
    /// over before the first has its plan, the months the first named are still read again once
    /// the grid comes to them.
    func testAReloadThatTakesOverStillReadsTheMonthsTheOneBeforeNamed() async throws {
        let api = try ChangingLibrary([photo("a1", "2026-04-20"), photo("m1", "2026-03-20"), photo("f1", "2026-02-10")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        store.visibleSections([0, 1, 2])
        try await until("The months did not load.") { [Self.april, Self.march, Self.february].allSatisfy { store.loaded[$0] != nil } }
        store.visibleSections([0])
        await store.settleProjections()

        // f1 is renamed on the web while February is off screen; before its change's reload has a
        // plan, a change to m1 starts a reload of its own.
        var renamed = try photo("f1", "2026-02-10")
        renamed.originalFileName = "renamed.jpg"
        await api.set(renamed)
        await api.holdPlans()
        let plans = await api.planCalls
        let first = Task { await store.apply(change(upserted: ["f1": move(Self.february, Self.february)])) }
        try await until("The first reload never asked for its plan.") { await api.planCalls > plans }
        let second = Task { await store.apply(change(upserted: ["m1": move(Self.march, Self.march)])) }
        try await until("The second reload never asked for its plan.") { await api.planCalls > plans + 1 }
        await api.releasePlans()
        await first.value
        await second.value

        store.visibleSections([2])
        try await until("February was not read again.") { store.loaded[Self.february]?.first?.originalFileName == "renamed.jpg" }
    }

    /// A photo deleted here stays out until a sync that began reading the server after the
    /// deletion has run. A pass already on its way, whose change names the photo (favorited a
    /// moment before), and a refresh asked for before the deletion, read the server before it had
    /// the deletion: neither brings the photo back.
    func testASyncBegunBeforeADeletionDoesNotBringThePhotoBack() async throws {
        let api = try ChangingLibrary([photo("m1", "2026-03-20"), photo("m2", "2026-03-10")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("March did not load.") { store.loaded[Self.march]?.count == 2 }

        // A refresh asked for after another change, and a pass reading the server, are on their way.
        await api.holdRefreshes()
        let refreshes = await api.refreshCalls
        let refresh = Task { await store.refreshAfterMutation() }
        try await until("The refresh was never asked for.") { await api.refreshCalls > refreshes }
        let passBegan = ContinuousClock.now - .milliseconds(10)
        // The viewer deletes m2; the offline library those syncs leave still has it.
        store.removeLocally(["m2"])
        XCTAssertEqual(store.loaded[Self.march]?.map(\.id), ["m1"])

        // The pass publishes m2, favorited before the deletion, and March is read again.
        var reads = await api.monthReads.count
        await store.apply(change(upserted: ["m2": move(Self.march, Self.march)], syncedThrough: passBegan))
        try await until("March was not read again.") { await api.monthReads.count > reads }
        try await Task.sleep(for: .milliseconds(100))
        await store.settleProjections()
        XCTAssertEqual(store.loaded[Self.march]?.map(\.id), ["m1"], "A pass begun before the deletion doesn't bring it back.")

        // The refresh asked for before the deletion ends, and the feed is read again.
        reads = await api.monthReads.count
        await api.releaseRefreshes()
        await refresh.value
        try await until("March was not read again after the refresh.") { await api.monthReads.count > reads }
        try await Task.sleep(for: .milliseconds(100))
        await store.settleProjections()
        XCTAssertEqual(store.loaded[Self.march]?.map(\.id), ["m1"], "Nor does a refresh asked for before it.")
        XCTAssertEqual(store.sections.map(\.count), [1])
    }

    /// A photo taken out only as a precaution, whose access couldn't be checked, comes back with
    /// the next change a sync publishes when the refresh after it failed, though that change names
    /// other photos.
    func testAPhotoTakenOutWhoseRefreshFailedComesBackWithTheNextSync() async throws {
        let api = try ChangingLibrary([photo("m1", "2026-03-20"), photo("m2", "2026-03-10"), photo("f1", "2026-02-10")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("The months did not load.") { store.loaded[Self.march]?.count == 2 && store.loaded[Self.february] != nil }

        await api.failRefreshes()
        store.removeLocally(["m1"])
        await store.refreshAfterMutation()
        XCTAssertNotNil(store.error, "The refresh failed.")
        XCTAssertEqual(store.loaded[Self.march]?.map(\.id), ["m2"])

        // The network is back, and a sync publishes a change to another photo.
        var renamed = try photo("f1", "2026-02-10")
        renamed.originalFileName = "renamed.jpg"
        await api.set(renamed)
        await store.apply(change(upserted: ["f1": move(Self.february, Self.february)], syncedThrough: .now))
        try await until("The photo did not come back.") { store.loaded[Self.march]?.map(\.id) == ["m1", "m2"] }
        await store.settleProjections()
        XCTAssertEqual(store.sections.map(\.count), [2, 1])
    }

    /// A new feed whose first month fails leaves the feed shown frozen with the error, and the
    /// failed month's banner shows too. Its Retry loads the new feed again, which then replaces
    /// the frozen one.
    func testRetryingAPendingFeedsFailedMonthReplacesTheFrozenFeed() async throws {
        let api = try ChangingLibrary([photo("m1", "2026-03-20", favorite: true), photo("f1", "2026-02-10")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("The library did not load.") { store.loaded[Self.march] != nil && store.loaded[Self.february] != nil }
        await api.fail(Self.march)
        store.setFeed(.favorites, title: "Favorites")
        try await until("The failure was not shown.") { store.error != nil }
        XCTAssertTrue(store.isReplacingFeed, "The library stays, frozen, with the error.")
        XCTAssertFalse(store.bucketErrors.isEmpty)

        await api.heal(Self.march)
        store.retryFailedBuckets()
        let committed = await eventually { !store.isReplacingFeed }
        XCTAssertTrue(committed, "Favorites replace the frozen library once their month is in.")
        XCTAssertEqual(store.sections.map(\.id), [Self.march])
        XCTAssertNil(store.error)
    }

    /// A change read again only the months the grid wanted, leaving one off screen to be read when
    /// the grid comes to it. A filter opened meanwhile keeps that: once it clears, the month is
    /// read again when the grid comes to it, not shown as it was left.
    func testAMonthLeftStaleWhenAFilterOpensIsReadAgainOnceItClears() async throws {
        let api = try ChangingLibrary([photo("a1", "2026-04-20"), photo("m1", "2026-03-20"), photo("f1", "2026-02-10")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        store.visibleSections([0, 1, 2])
        try await until("The months did not load.") { [Self.april, Self.march, Self.february].allSatisfy { store.loaded[$0] != nil } }
        store.visibleSections([0])
        await store.settleProjections()

        // f1 is favorited on the web while February is off screen.
        await api.set(try photo("f1", "2026-02-10", favorite: true))
        let reads = await api.monthReads.count
        await store.apply(change(upserted: ["f1": move(Self.february, Self.february)]))
        try await Task.sleep(for: .milliseconds(100))
        let reread = await api.monthReads.dropFirst(reads)
        XCTAssertFalse(reread.contains(Self.february), "February waits for the grid.")

        store.setFeed(.favorites, title: "Favorites")
        try await until("Favorites did not replace the library.") { !store.isReplacingFeed && store.filterTitle == "Favorites" }
        let summaries = await api.summaryCalls
        store.clearFilters()
        XCTAssertEqual(store.loaded[Self.february]?.first?.isFavorite, false, "The library comes back as it was left.")
        try await until("The restored library was not counted again.") { await api.summaryCalls > summaries }
        store.visibleSections([2])
        try await until("February was not read again.") { store.loaded[Self.february]?.first?.isFavorite == true }
    }

    // MARK: - Support

    private func photo(_ id: String, _ day: String, favorite: Bool = false) throws -> Asset {
        Asset(id: id, originalFileName: id + ".jpg", ownerId: "alice", localDateTime: try XCTUnwrap(APIDate.parse(day + "T12:00:00Z")),
              isFavorite: favorite)
    }

    private func move(_ from: String, _ to: String) -> LibraryChange.MonthMove {
        LibraryChange.MonthMove(from: MonthKey(bucketID: from), to: MonthKey(bucketID: to))
    }

    /// `syncedThrough` is when the pass behind it began reading the server; nil for a change that
    /// doesn't say.
    private func change(upserted: [String: LibraryChange.MonthMove] = [:], removed: Set<String> = [],
                        syncedThrough: ContinuousClock.Instant? = nil) -> LibraryChange {
        var change = LibraryChange(account: LegacyGoldens.account, authorization: AuthorizationEpoch(account: LegacyGoldens.account, value: 1),
                                   indexRevision: 2, origin: .sync)
        change.upserted = upserted; change.removed = removed; change.syncedThrough = syncedThrough
        return change
    }

    private static let maya = Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: nil, isFavorite: nil)

    /// Polls until the condition holds or the time runs out, and says whether it held.
    private func eventually(within timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if await condition() { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func until(_ message: String, within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        if await eventually(within: timeout, condition) { return }
        XCTFail(message)
        throw CancellationError()
    }
}

/// A library whose photos change under the store, as the server's do. Every feed reads from the
/// one list: the photos that belong to its query, by month, newest first and then by ID. A
/// summary, a plan or a refresh can be held while a test arranges a race, a refresh can fail as
/// with no network, and a month can fail, or come back empty while the summary still counts it,
/// as when its photos go between the two reads.
private actor ChangingLibrary: FakeFeedSource {
    nonisolated let cacheScope = "test-feed-session-" + UUID().uuidString
    nonisolated var userID: String? { "alice" }
    private var photos: [String: Asset] = [:]
    private let people: [String: Set<String>]
    private var emptied: Set<String> = []
    private var failing: Set<String> = []
    private var summaryGate: StubServer.Gate?
    private var planGate: StubServer.Gate?
    private var refreshGate: StubServer.Gate?
    private var refreshesFail = false
    private(set) var summaryCalls = 0
    private(set) var planCalls = 0
    private(set) var refreshCalls = 0
    private(set) var monthReads: [String] = []

    init(_ photos: [Asset], people: [String: Set<String>] = [:]) throws {
        for photo in photos { self.photos[photo.id] = photo }
        self.people = people
    }

    func set(_ asset: Asset) { photos[asset.id] = asset }
    func delete(_ id: String) { photos[id] = nil }
    func empty(_ bucket: String) { emptied.insert(bucket) }
    /// The month fails as a busy server does, until healed.
    func fail(_ bucket: String) { failing.insert(bucket) }
    func heal(_ bucket: String) { failing.remove(bucket) }
    /// Summaries asked for from now on wait until releaseSummaries.
    func holdSummaries() { summaryGate = StubServer.Gate() }
    func releaseSummaries() { summaryGate?.open(); summaryGate = nil }
    /// Plans asked for from now on wait until releasePlans.
    func holdPlans() { planGate = StubServer.Gate() }
    func releasePlans() { planGate?.open(); planGate = nil }
    /// Refreshes asked for from now on wait until releaseRefreshes.
    func holdRefreshes() { refreshGate = StubServer.Gate() }
    func releaseRefreshes() { refreshGate?.open(); refreshGate = nil }
    /// Refreshes from now on fail, as with no network.
    func failRefreshes() { refreshesFail = true }

    func plan(_ query: LibraryQuery) async throws -> QueryPlan {
        planCalls += 1
        if let planGate { await planGate.wait() }
        return try QueryPlanner.plan(query, context: PlannerContext(indexReadable: false))
    }

    func refresh() async throws -> LibraryChange? {
        refreshCalls += 1
        if let refreshGate { await refreshGate.wait() }
        if refreshesFail { throw URLError(.notConnectedToInternet) }
        return nil
    }

    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] {
        summaryCalls += 1
        if let summaryGate { await summaryGate.wait() }
        var counts: [String: Int] = [:]
        for asset in photos.values where belongs(asset, to: query) { counts[Self.bucket(of: asset), default: 0] += 1 }
        return counts.keys.sorted(by: >).map { TimeBucket(timeBucket: $0, count: counts[$0] ?? 0) }
    }

    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] {
        monthReads.append(bucket)
        if failing.contains(bucket) { throw ServerFailure.http(500, nil) }
        guard !emptied.contains(bucket) else { return [] }
        return photos.values.filter { belongs($0, to: query) && Self.bucket(of: $0) == bucket }.sorted { a, b in
            let left = a.localDateTime ?? .distantPast, right = b.localDateTime ?? .distantPast
            return left == right ? a.id < b.id : left > right
        }
    }

    func search(_ query: SearchQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }

    /// What the server keeps in a feed: its visibility and trash, favorite, and a person's photos.
    private func belongs(_ asset: Asset, to query: LibraryQuery) -> Bool {
        switch asset.visibility {
        case .timeline: guard query.visibility.contains(.timeline) else { return false }
        case .archive: guard query.visibility.contains(.archive) else { return false }
        case .hidden, .locked: return false
        }
        guard asset.isTrashed == (query.trash == .trashed) else { return false }
        if let favorite = query.predicates.favorite, asset.isFavorite != favorite { return false }
        if let person = query.predicates.people.first, people[person]?.contains(asset.id) != true { return false }
        return true
    }

    private static func bucket(of asset: Asset) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month], from: asset.localDateTime ?? .distantPast)
        return String(format: "%04d-%02d-01T00:00:00Z", parts.year ?? 1970, parts.month ?? 1)
    }
}

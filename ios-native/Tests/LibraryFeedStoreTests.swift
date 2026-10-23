import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

@MainActor final class LibraryFeedStoreTests: XCTestCase {
    func testPartialPageStopsAndRetriesItsOwnCursorWithoutLosingEarlierMatches() async throws {
        let api = LibraryAPIFixture([
            .page(["first"], next: "second"),
            .page([], next: "third", status: .partial),
            .page(["second"], next: "third"),
        ])
        let store = LibraryFeedStore(source: api)
        // A checked search: the AI check starts off.
        store.setChecksContent(true)
        store.search("me wearing a red hat in Amsterdam")
        try await settle(store, calls: 1, api: api)
        store.loadMore()
        try await settle(store, calls: 2, api: api)
        XCTAssertEqual(store.results.map(\.id), ["first"])
        XCTAssertTrue(store.verification?.canRetry == true)
        XCTAssertFalse(store.hasMore, "Resolve the unchecked batch before advancing beyond it.")
        store.retrySearch()
        try await settle(store, calls: 3, api: api)
        let calls = await api.cursors
        XCTAssertEqual(calls, [nil, "second", "second"])
        XCTAssertEqual(store.results.map(\.id), ["first", "second"])
        XCTAssertTrue(store.hasMore)
        store.stop()
    }

    func testEmptyVerifiedPageFollowsCursorButUnavailablePageDoesNot() async throws {
        let api = LibraryAPIFixture([
            .page([], next: "next"),
            .page([], next: "later", status: .unavailable),
            .page(["found"]),
        ])
        let store = LibraryFeedStore(source: api)
        store.setChecksContent(true)
        store.search("Maya in Amsterdam")
        try await settle(store, calls: 2, api: api)
        XCTAssertTrue(store.verification?.canRetry == true)
        XCTAssertTrue(store.results.isEmpty)
        store.retrySearch()
        try await settle(store, calls: 3, api: api)
        let calls = await api.cursors
        XCTAssertEqual(calls, [nil, "next", "next"])
        XCTAssertEqual(store.results.map(\.id), ["found"])
        store.stop()
    }

    func testMediaShelfFilterLoadsIntoTheLibraryResultsFeed() async throws {
        let api = LibraryAPIFixture([], metadataPages: [.page(["video-1"])])
        let store = LibraryFeedStore(source: api)
        store.setMetadataFilter(SearchFilter(type: StringFilter(eq: "VIDEO")), title: "Videos")
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await api.metadataCalls >= 1, !store.isSearching { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.sections.first?.title, "Videos")
        XCTAssertEqual(store.results.map(\.id), ["video-1"])
        XCTAssertTrue(store.isFiltered)
        store.stop()
    }

    func testMetadataResultsTitleTracksVisiblePhotoAndClearRestoresTimelineTitle() async throws {
        let april = try XCTUnwrap(APIDate.parse("2018-04-12T12:00:00Z"))
        let june = try XCTUnwrap(APIDate.parse("2026-06-03T12:00:00Z"))
        let august = try XCTUnwrap(APIDate.parse("2026-08-17T12:00:00Z"))
        let api = LibraryAPIFixture([], bucketAssets: [
            "2018-04-01T00:00:00Z": [Asset(id: "timeline-photo", localDateTime: april)]
        ], metadataPages: [.page(assets: [
            Asset(id: "june-photo", localDateTime: june), Asset(id: "august-photo", fileCreatedAt: august)
        ])])
        let store = LibraryFeedStore(source: api)
        await store.reload()
        store.visibleSection(0)
        store.position = GridPosition(section: "2018-04-01T00:00:00Z", item: 0, offset: 0, assetID: "timeline-photo")
        XCTAssertEqual(store.title, "April 2018")

        store.setMetadataFilter(SearchFilter(type: StringFilter(eq: "PHOTO")), title: "Photos")
        try await until("The metadata results did not commit.") { await api.metadataCalls == 1 && !store.isSearching }
        XCTAssertEqual(store.title, "June 2026")

        store.position = GridPosition(section: "results", item: 1, offset: 0, assetID: "august-photo")
        XCTAssertEqual(store.title, "August 2026")
        store.clearFilters()
        XCTAssertEqual(store.title, "April 2018", "Clearing results restores the saved timeline heading.")
        store.stop()
    }

    func testDevelopedShelfFilterContinuesPastZeroMatchesAndClearRestoresTimelinePosition() async throws {
        let api = LibraryAPIFixture([], metadataPages: [
            .page(assets: [Asset(id: "not-developed", isDeveloped: false)], next: "developed-page"),
            .page(assets: [Asset(id: "developed", isDeveloped: true)]),
        ])
        let store = LibraryFeedStore(source: api)
        await store.reload()
        let bucket = try XCTUnwrap(store.buckets.first?.id)
        let position = GridPosition(section: bucket, item: 0, offset: 19, assetID: "timeline-photo")
        store.position = position

        store.setMetadataFilter(SearchFilter(visibility: StringFilter(eq: "timeline")), title: "Lightroom", developedOnly: true)
        try await until("The developed result was not found after the empty candidate page.") {
            await api.metadataCalls == 2 && !store.isSearching
        }
        XCTAssertEqual(store.results.map(\.id), ["developed"])

        store.clearFilters()
        XCTAssertEqual(store.restorePosition, position)
        XCTAssertFalse(store.isFiltered)
        store.stop()
    }

    func testClearingAFilterReopensTheLibraryOnTheBackendRoutingMovedItTo() async throws {
        let api = RoutingAPIFixture()
        let store = LibraryFeedStore(source: api, placesDelay: .zero)
        await store.reload()
        XCTAssertEqual(store.feedPlan?.backend, .serverTimeline)
        let position = GridPosition(section: "2024-10-01T00:00:00Z", item: 0, offset: 7, assetID: "photo")
        store.position = position

        store.setFeed(.favorites, title: "Favorites")
        try await until("Favorites never planned.") { store.feedPlan != nil && !store.isLoading }
        // The first sync finishes while Favorites is open: only the feed shown hears of it.
        await api.setIndexReadable(true)
        store.clearFilters()
        XCTAssertEqual(store.restorePosition, position, "The library comes back at once where it was left.")
        try await until("The library kept the plan it was left with.") {
            let readsIndex = await api.libraryReads.last == .index
            return store.feedPlan?.backend == .index && readsIndex
        }
        XCTAssertEqual(store.restorePosition, position, "Reopening on the index keeps the place in the library.")
        store.stop()
    }

    func testLibrarySearchesNeverReachTheLockedFolder() async throws {
        let library = try XCTUnwrap(SearchFilter.library.visibility?.in)
        XCTAssertEqual(Set(library), ["timeline", "archive"])
        let api = PlacesAPIFixture(places: [:])
        let store = LibraryFeedStore(source: api, placesDelay: .zero)
        XCTAssertEqual(store.searchFilter.visibility, SearchFilter.library.visibility, "Searching the library leaves the Locked Folder out.")
        store.setPerson(Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: nil, isFavorite: nil))
        XCTAssertEqual(store.searchFilter.visibility, SearchFilter.library.visibility, "So does searching a person's photos.")
        store.setFeed(.trash, title: "Trash")
        XCTAssertEqual(store.searchFilter.visibility, SearchFilter.library.visibility, "And the trash.")
        store.setFeed(.archive, title: "Archive")
        XCTAssertEqual(store.searchFilter.visibility, StringFilter(in: ["archive"]))
        store.clearFilters()
        XCTAssertEqual(store.searchFilter.visibility, SearchFilter.library.visibility)
        store.stop()
    }

    func testLightroomIsATimelineOfEveryDevelopedPhoto() async throws {
        let api = PlacesAPIFixture(places: [:])
        let store = LibraryFeedStore(source: api, placesDelay: .zero)
        await store.reload()
        store.setDeveloped(title: "Lightroom")
        XCTAssertEqual(store.feedQuery, .lightroom)
        XCTAssertTrue(try ServerTimelineRequest(store.feedQuery, userID: nil).queryItems.contains(URLQueryItem(name: "isDeveloped", value: "true")),
                      "The server lays out the developed photos too, when the offline library cannot.")
        try await until("Lightroom's months did not load.") { store.canScrubTimeline }
        XCTAssertNotEqual(store.sections.first?.id, "results", "Lightroom is a timeline by month, with its rail.")
        XCTAssertEqual(store.filterTitle, "Lightroom")
        store.stop()
    }

    func testTheDevelopedShelfLooksPastHundredsOfRecentUndevelopedPhotos() async throws {
        // Twelve pages of recent phone photos without development come before the first developed one.
        let recent: [SearchResponse] = (0..<12).map { page in
            .page(assets: (0..<5).map { Asset(id: "phone-\(page)-\($0)", isDeveloped: false) }, next: "page-\(page + 1)")
        }
        let api = LibraryAPIFixture([], metadataPages: recent + [.page(assets: [Asset(id: "developed", isDeveloped: true)])])
        let store = LibraryFeedStore(source: api)
        await store.reload()
        store.setMetadataFilter(SearchFilter(visibility: StringFilter(eq: "timeline")), title: "Lightroom", developedOnly: true)
        try await until("The developed photo behind the recent ones was not found.") { await api.metadataCalls == 13 && !store.isSearching }
        XCTAssertEqual(store.results.map(\.id), ["developed"])
        let sizes = await api.metadataSizes
        XCTAssertEqual(Set(sizes), [500], "The developed shelf reads big pages.")
        store.stop()
    }

    func testChoosingAPlaceKeepsTheTimelineAndItsRailAsAPersonDoes() async throws {
        let api = PlacesAPIFixture(places: [:], byMonth: true)
        let store = LibraryFeedStore(source: api, placesDelay: .zero)
        await store.reload()
        store.setPlace(id: "lisbon", assetIDs: ["lisbon-1", "lisbon-2"], title: "Lisbon")
        try await until("The place's months did not load.") { store.canScrubTimeline && store.buckets.first?.id == "2023-05-01T00:00:00Z" }
        XCTAssertNotEqual(store.sections.first?.id, "results", "A place is a timeline by month, as a person is, not a list of results.")
        XCTAssertEqual(store.buckets.first?.count, 2)
        XCTAssertEqual(store.filterTitle, "Lisbon")
        store.clearFilters()
        XCTAssertEqual(store.feedQuery, .library, "Clearing the place brings the library back.")
        store.stop()
    }

    func testAPlaceIsFoundBySearchWhenTheOfflineLibraryCannotLayItOut() async throws {
        let api = PlacesAPIFixture(places: [:], byMonth: true, placeFails: true)
        let store = LibraryFeedStore(source: api, placesDelay: .zero)
        await store.reload()
        store.setPlace(id: "lisbon", assetIDs: ["lisbon-1", "lisbon-2"], title: "Lisbon")
        try await until("The place did not fall back to search.") { store.sections.first?.id == "results" }
        XCTAssertEqual(store.feedPlan?.backend, .serverSearch, "The planner serves the place by search, as one list.")
        XCTAssertTrue(store.feedPlan?.limitations.contains(.noMonths) == true)
        XCTAssertEqual(store.results.map(\.id), ["lisbon-1", "lisbon-2"])
        store.stop()
    }

    func testAPlaceKeepsItsOwnCachesAndTheServerNeverSeesIt() throws {
        let library = LibraryQuery.library
        let lisbon = LibraryQuery.place(PlaceMembership(placeID: "Lisbon", assetIDs: ["a", "b"], markerQuery: ""))
        XCTAssertNotEqual(lisbon.stableKey, library.stableKey, "A place's feed is cached apart from the library's.")
        XCTAssertEqual(library.stableKey, try ServerTimelineRequest(library, userID: nil).queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&"),
                       "The library's caches keep their names.")
        XCTAssertThrowsError(try ServerTimelineRequest(lisbon, userID: nil), "The server never sees a place.") {
            XCTAssertEqual($0 as? Unsupported, .placeNeedsIndex)
        }
        XCTAssertNotEqual(lisbon, .place(PlaceMembership(placeID: "Lisbon", assetIDs: ["a", "b", "c"], markerQuery: "")),
                          "A place that gained photos is a new feed.")
    }

    func testClearingAPersonBringsTheLibrarysPlacesStraightBack() async throws {
        let api = PlacesAPIFixture(places: [
            nil: [MonthPlaceCount(bucket: "2024-10-01", city: "Kyoto", country: "Japan", count: 40)],
            "maya": [MonthPlaceCount(bucket: "2024-08-01", city: "Oslo", country: "Norway", count: 20)],
        ])
        let store = LibraryFeedStore(source: api, placesDelay: .zero)
        await store.reload()
        try await until("The library's places were not counted.") { store.monthPlaces["2024-10-01"] != nil }
        store.setPerson(Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: nil, isFavorite: nil))
        try await until("The person's places were not counted.") { store.monthPlaces["2024-08-01"] != nil }
        XCTAssertNil(store.monthPlaces["2024-10-01"], "A person's feed names months by that person's places only.")
        store.clearFilters()
        XCTAssertEqual(store.monthPlaces["2024-10-01"]?.first?.name, "Kyoto", "Clearing the person brings the library's places straight back.")
        XCTAssertNil(store.monthPlaces["2024-08-01"], "The person's places do not stay on the library.")
        store.stop()
    }

    func testPlacesArriveWhileTheLibraryKeepsChanging() async throws {
        let api = PlacesAPIFixture(places: [nil: [MonthPlaceCount(bucket: "2024-10-01", city: "Kyoto", country: "Japan", count: 40)]],
                                   delay: .milliseconds(300))
        let store = LibraryFeedStore(source: api, placesDelay: .zero)
        await store.reload()
        // Syncs reload the feed more often than its places take to count.
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(100))
            await store.reload(preservingPosition: true)
        }
        try await until("The places never arrived while the library kept changing.") { store.monthPlaces["2024-10-01"] != nil }
        store.stop()
    }

    func testALaunchShowsTheKeptPlacesWhileTheyAreCountedAgain() async throws {
        let scope = "test-places-" + UUID().uuidString
        let kept = MemoryPlacesStore()
        let counted = PlacesAPIFixture(scope: scope, places: [nil: [MonthPlaceCount(bucket: "2024-10-01", city: "Kyoto", country: "Japan", count: 40)]])
        let first = LibraryFeedStore(source: counted, placesDelay: .zero, places: MonthPlacesService(source: counted, store: kept, delay: .zero))
        await first.reload()
        try await until("The places were not counted.") { first.monthPlaces["2024-10-01"] != nil }
        try await until("The places were not kept on the phone.") { await kept.rows[LibraryQuery.library.stableKey] != nil }
        first.stop()
        // The next launch is slow to count; the kept places show meanwhile.
        let slow = PlacesAPIFixture(scope: scope, places: [:], delay: .seconds(10))
        let next = LibraryFeedStore(source: slow, placesDelay: .zero, places: MonthPlacesService(source: slow, store: kept, delay: .zero))
        await next.reload()
        try await until("The kept places did not show at launch.") { next.monthPlaces["2024-10-01"]?.first?.name == "Kyoto" }
        next.stop()
    }

    func testADeletedPhotoLeavesTheFeedBeforeTheServerConfirms() async throws {
        let bucket = "2026-01-01T00:00:00Z"
        let api = LibraryAPIFixture([], timelineAssets: [Asset(id: "a"), Asset(id: "b"), Asset(id: "c")])
        let store = LibraryFeedStore(source: api)
        await store.reload()
        try await until("The timeline did not load.") { store.loaded[bucket]?.count == 3 }

        store.removeLocally(["b"])
        XCTAssertEqual(store.sections.first?.count, 2)
        XCTAssertEqual([0, 1].compactMap { store.asset(section: 0, item: $0)?.id }, ["a", "c"])
        store.removeLocally(["a", "c"])
        XCTAssertTrue(store.sections.isEmpty, "A month with nothing left goes.")
        store.stop()
    }

    func testFilterKeepsLoadedFeedUntilReplacementBucketCommits() async throws {
        let bucket = "2026-01-01T00:00:00Z"
        let api = LibraryAPIFixture([], timelineAssets: [Asset(id: "old-a"), Asset(id: "old-b")],
                                    scopedTimelineAssets: ["favorites": [Asset(id: "favorite-a")]])
        let store = LibraryFeedStore(source: api)
        await store.reload()
        try await until("Initial timeline assets did not load.") { store.loaded[bucket]?.count == 2 }
        store.position = GridPosition(section: bucket, item: 1, offset: 17, assetID: "old-b")
        let initialResetID = store.resetID
        await api.setTimelineBehavior(scope: "favorites", delayed: true)

        store.setFeed(.favorites, title: "Favorites")
        try await until("The favorite bucket request did not start.") { await api.bucketCalls.count > 1 && store.isReplacingFeed }
        XCTAssertEqual(store.sections.first?.id, bucket)
        XCTAssertEqual(store.sections.first?.count, 2)
        XCTAssertEqual(store.asset(section: 0, item: 0)?.id, "old-a")
        XCTAssertEqual(store.resetID, initialResetID, "The old grid identity must remain stable during replacement.")

        try await until("The replacement feed did not commit.") { !store.isReplacingFeed && store.asset(section: 0, item: 0)?.id == "favorite-a" }
        XCTAssertEqual(store.sections.first?.count, 1)
        XCTAssertNotEqual(store.resetID, initialResetID)
        store.stop()
    }

    func testFailedReplacementRetainsOldFeedAndClearRestoresIt() async throws {
        let bucket = "2026-01-01T00:00:00Z"
        let api = LibraryAPIFixture([], timelineAssets: [Asset(id: "old-photo")],
                                    scopedTimelineAssets: ["favorites": [Asset(id: "favorite-photo")]],
                                    failingTimelineScopes: ["favorites"])
        let store = LibraryFeedStore(source: api)
        await store.reload()
        try await until("Initial timeline asset did not load.") { store.loaded[bucket]?.first?.id == "old-photo" }
        let initialResetID = store.resetID

        store.setFeed(.favorites, title: "Favorites")
        try await until("The failed replacement did not report its error.") { store.error != nil && store.isReplacingFeed }
        XCTAssertEqual(store.sections.first?.count, 1)
        XCTAssertEqual(store.asset(section: 0, item: 0)?.id, "old-photo")
        XCTAssertEqual(store.resetID, initialResetID)

        store.clearFilters()
        XCTAssertFalse(store.isReplacingFeed)
        XCTAssertEqual(store.asset(section: 0, item: 0)?.id, "old-photo")
        store.stop()
    }

    /// F7 review: More's filtered view, opened with no text, keeps the feed shown on screen until it
    /// is ready, and on an error for Retry and Clear, even after a search whose results are gone.
    /// Over a feed with nothing on screen, no older search's results show while it loads.
    func testFilteredViewKeepsTheFeedShownUntilReadyAndOnAnError() async throws {
        let bucket = "2026-01-01T00:00:00Z"
        // No metadata pages: the filtered view's search fails.
        let api = LibraryAPIFixture([.page(["beach-1", "beach-2"])], timelineAssets: [Asset(id: "timeline-photo")],
                                    scopedTimelineAssets: ["favorites": []])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("The timeline did not load.") { store.loaded[bucket]?.first?.id == "timeline-photo" }
        store.search("beach")
        try await settle(store, calls: 1, api: api)
        XCTAssertEqual(store.results.map(\.id), ["beach-1", "beach-2"])
        // The bar's clear button.
        store.search("")
        XCTAssertEqual(store.asset(section: 0, item: 0)?.id, "timeline-photo")

        store.applySearchOptions(mode: .context, filter: SearchFilter(type: StringFilter(eq: "VIDEO")))
        XCTAssertTrue(store.isBrowsingChoices)
        XCTAssertEqual(store.sections.map(\.id), [bucket], "The library stays while the filtered view loads.")
        XCTAssertEqual(store.asset(section: 0, item: 0)?.id, "timeline-photo")
        try await until("The filtered view did not fail.") { await api.metadataCalls == 1 && store.error != nil }
        XCTAssertTrue(store.isReplacingFeed)
        XCTAssertEqual(store.sections.map(\.id), [bucket], "An error keeps the library for Retry and Clear.")
        XCTAssertEqual(store.asset(section: 0, item: 0)?.id, "timeline-photo")
        store.clearFilters()
        XCTAssertFalse(store.isReplacingFeed)
        XCTAssertEqual(store.asset(section: 0, item: 0)?.id, "timeline-photo")

        // Favorites has nothing to freeze: the filtered view starts empty, not with the beach search.
        store.setFeed(.favorites, title: "Favorites")
        try await until("Favorites did not replace the library.") { !store.isReplacingFeed && !store.isLoading && store.totalCount == 0 }
        store.applySearchOptions(mode: .context, filter: SearchFilter(type: StringFilter(eq: "VIDEO")))
        XCTAssertTrue(store.isBrowsingChoices)
        XCTAssertNil(store.asset(section: 0, item: 0), "No older search's results show under the filtered view.")
        XCTAssertEqual(store.totalCount, 0)
        try await until("The filtered view did not fail.") { await api.metadataCalls == 2 && store.error != nil }
        XCTAssertNil(store.asset(section: 0, item: 0))
    }

    func testRapidScopeReplacementAndClearCannotCommitStaleFeed() async throws {
        let bucket = "2026-01-01T00:00:00Z"
        let api = LibraryAPIFixture([], timelineAssets: [Asset(id: "old-photo")],
                                    scopedTimelineAssets: ["favorites": [Asset(id: "stale-favorite")], "archive": [Asset(id: "archive-photo")]])
        let store = LibraryFeedStore(source: api)
        await store.reload()
        try await until("Initial timeline asset did not load.") { store.loaded[bucket]?.first?.id == "old-photo" }
        await api.setTimelineBehavior(scope: "favorites", delayed: true)

        store.setFeed(.favorites, title: "Favorites")
        try await until("The first replacement request did not start.") { await api.bucketCalls.count > 1 && store.isReplacingFeed }
        store.setFeed(.archive, title: "Archive")
        try await until("The latest replacement did not commit.") { !store.isReplacingFeed && store.asset(section: 0, item: 0)?.id == "archive-photo" }
        XCTAssertNotEqual(store.asset(section: 0, item: 0)?.id, "stale-favorite")

        store.clearFilters()
        XCTAssertEqual(store.asset(section: 0, item: 0)?.id, "old-photo")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(store.isReplacingFeed)
        XCTAssertEqual(store.asset(section: 0, item: 0)?.id, "old-photo")
        store.stop()
    }

    func testSwitchingScopeClearsSelectionAndInvalidatesPendingSearch() async throws {
        let api = LibraryAPIFixture([.page(["old-query"])], delayed: true)
        let store = LibraryFeedStore(source: api)
        store.search("old query")
        for _ in 0..<100 where await api.cursors.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        store.selected = ["invisible-photo"]; store.isSelecting = true
        store.setFeed(.favorites, title: "Favorites")
        XCTAssertTrue(store.selected.isEmpty)
        XCTAssertFalse(store.isSelecting)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(store.isSearching)
        XCTAssertTrue(store.query.isEmpty)
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertEqual(store.sections.first?.id, "2026-01-01T00:00:00Z")
        store.stop()
    }

    func testClearingFilterRestoresScrollPositionAndTimelineRetryStaysTimeline() async throws {
        let api = LibraryAPIFixture([])
        let store = LibraryFeedStore(source: api)
        await store.reload()
        let position = GridPosition(section: "2026-01-01T00:00:00Z", item: 0, offset: 17)
        store.position = position
        store.setFeed(.favorites, title: "Favorites")
        store.clearFilters()
        XCTAssertEqual(store.restorePosition, position)
        store.retryCurrent()
        try await Task.sleep(for: .milliseconds(60))
        let calls = await api.cursors
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(store.sections.first?.id, position.section)
        store.stop()
    }

    private func settle(_ store: LibraryFeedStore, calls: Int, api: LibraryAPIFixture) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await api.cursors.count >= calls, !store.isSearching { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The library did not settle its search request.")
    }

    /// A refresh whose pass published a change leaves the feed's reload to LibraryView, which
    /// reloads on that change, so the months load once. A pass that changed nothing, or a
    /// library that can't say what changed, still reloads here.
    func testRefreshAfterMutationLeavesAPublishedChangeToTheViewsReload() async throws {
        let api = LibraryAPIFixture([])
        let store = LibraryFeedStore(source: api)
        await store.reload()
        let initial = await api.summaryCalls
        XCTAssertGreaterThan(initial, 0)

        var change = LibraryChange(account: LegacyGoldens.account,
                                   authorization: AuthorizationEpoch(account: LegacyGoldens.account, value: 1),
                                   indexRevision: 2, origin: .sync)
        change.removed = ["timeline-photo"]
        await api.setRefreshChange(change)
        await store.refreshAfterMutation()
        let afterPublished = await api.summaryCalls
        XCTAssertEqual(afterPublished, initial, "The published change's own reload loads the feed.")

        await api.setRefreshChange(nil)
        await store.refreshAfterMutation()
        let afterUnknown = await api.summaryCalls
        XCTAssertEqual(afterUnknown, initial + 1, "Without a change to go on, the refresh reloads.")
        let refreshes = await api.refreshes
        XCTAssertEqual(refreshes, 2)
        store.stop()
    }

    func testMonthSelectionResolvesEvictedAssetsAndKeepsRemoteAndLocalIdentitiesSeparate() async throws {
        let assets = (0..<650).map { Asset(id: "remote-\($0)") }
        let api = LibraryAPIFixture([], timelineAssets: assets)
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        await store.reload()
        let date = try XCTUnwrap(APIDate.parse("2026-01-15T12:00:00Z"))
        store.updateDeviceTimeline(MergedTimeline(photos: [.init(id: "phone-only", date: date), .init(id: "backed-up", date: date)],
                                                  associations: ["backed-up": "remote-0"]))
        store.loaded = [:] // The summary survives eviction of its asset records.
        store.isSelecting = true
        store.selectMonth(true)
        try await settleSelection(store)
        XCTAssertEqual(store.selected.count, 651)
        XCTAssertEqual(Set(store.selectedAssets.map(\.id)), Set(assets.map(\.id)))
        XCTAssertEqual(store.selectedLocalPhotos.map(\.id), ["phone-only"])
        XCTAssertEqual(Set(store.selectedDevicePhotos.map(\.id)), ["phone-only", "backed-up"])
        XCTAssertFalse(store.selected.contains("local:backed-up"))
        store.selectMonth(false)
        try await settleSelection(store)
        XCTAssertTrue(store.selected.isEmpty)
        XCTAssertTrue(store.selectedLocalPhotos.isEmpty)
        store.stop()
    }

    func testPhoneOnlyPhotoSwipesThroughEverythingOnThePhone() async throws {
        let api = LibraryAPIFixture([], timelineAssets: [Asset(id: "remote-0"), Asset(id: "remote-1")])
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        await store.reload()
        let date = try XCTUnwrap(APIDate.parse("2026-01-15T12:00:00Z"))
        let phoneOnly = LocalPhoto(id: "phone-only", date: date)
        store.updateDeviceTimeline(MergedTimeline(photos: [phoneOnly, .init(id: "backed-up", date: date.addingTimeInterval(-60))],
                                                  associations: ["backed-up": "remote-0"]))
        try await until("The phone-only photo never reached the grid.") {
            store.sections.indices.contains { section in
                (0..<store.sections[section].count).contains { store.entry(section: section, item: $0)?.local?.id == "phone-only" }
            }
        }
        XCTAssertEqual(Set(store.availableLocalPhotos(around: phoneOnly).map(\.id)), ["phone-only", "backed-up"],
                       "A phone-only photo should swipe to the other photos on this phone, not open alone.")
        XCTAssertEqual(store.availableLocalPhotos(around: LocalPhoto(id: "elsewhere", date: date)).map(\.id), ["elsewhere"])
        store.stop()
    }

    func testPendingGroupSelectionCannotReappearAfterLeavingSelection() async throws {
        let api = LibraryAPIFixture([], delayedTimeline: true)
        let store = LibraryFeedStore(source: api)
        await store.reload()
        store.isSelecting = true; store.selectMonth(true)
        await Task.yield()
        store.isSelecting = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.selected.isEmpty)
        XCTAssertFalse(store.isSelectingGroup)
        store.stop()
    }

    func testDeduplicationKeepsTheVisiblePhotoAnchoredWhenEarlierRowsDisappear() async throws {
        let bucket = "2026-01-01T00:00:00Z"
        let api = LibraryAPIFixture([])
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        await store.reload()
        try await until("The timeline did not load.") { store.loaded[bucket] != nil }
        let date = try XCTUnwrap(APIDate.parse("2026-01-15T12:00:00Z"))
        let photos = [LocalPhoto(id: "a", date: date), LocalPhoto(id: "b", date: date.addingTimeInterval(-60))]
        store.updateDeviceTimeline(MergedTimeline(photos: photos))
        await store.settleProjections()
        store.loaded = [bucket: [Asset(id: "timeline-photo")]]
        store.updateDeviceTimeline(MergedTimeline(photos: photos))
        await store.settleProjections()
        store.position = GridPosition(section: bucket, item: 1, offset: 17, assetID: "local:b")
        store.updateDeviceTimeline(MergedTimeline(photos: photos, associations: ["a": "timeline-photo"]))
        await store.settleProjections()
        let position = try XCTUnwrap(store.restorePosition)
        XCTAssertEqual(store.restoredIndex(for: position)?.item, 0)
        XCTAssertEqual(position.offset, 17)
        store.updateDeviceTimeline(MergedTimeline(photos: photos, associations: ["a": "timeline-photo", "b": "timeline-photo"]))
        await store.settleProjections()
        XCTAssertEqual(store.restorePosition?.assetID, "timeline-photo")
        store.stop()
    }

    func testRepeatedDeviceSnapshotKeepsGridIdentityAndLocalEditStillInvalidatesMedia() async throws {
        let api = LibraryAPIFixture([])
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        let date = try XCTUnwrap(APIDate.parse("2026-01-15T12:00:00Z"))
        let photo = LocalPhoto(id: "phone", date: date, modified: date)
        let snapshot = MergedTimeline(photos: [photo])
        store.updateDeviceTimeline(snapshot)
        await store.settleProjections()
        let reset = store.resetID, revision = store.revision
        store.position = GridPosition(section: "2026-01-01", item: 0, offset: 17, assetID: "local:phone")
        store.isSelecting = true; store.select(.local(photo))

        store.updateDeviceTimeline(snapshot) // Discovery and fingerprint completion can be identical.
        await store.settleProjections()
        XCTAssertEqual(store.resetID, reset)
        XCTAssertEqual(store.revision, revision)
        XCTAssertNil(store.restorePosition)
        XCTAssertEqual(store.selected, ["local:phone"])

        let edited = LocalPhoto(id: "phone", date: date, modified: date.addingTimeInterval(60))
        store.updateDeviceTimeline(MergedTimeline(photos: [edited]))
        await store.settleProjections()
        XCTAssertEqual(store.resetID, reset, "A media revision change should reconfigure the same row.")
        XCTAssertGreaterThan(store.revision, revision)
        XCTAssertEqual(store.entry(section: 0, item: 0)?.local?.modified, edited.modified)
        store.stop()
    }

    /// F3: a snapshot from the phone projects only the months its photos changed in, and the
    /// other months keep their rows; an identical snapshot projects nothing.
    func testDevicePublishUpdatesOnlyItsMonth() async throws {
        let march = "2026-03-01T00:00:00Z", february = "2026-02-01T00:00:00Z"
        let api = try datedFixture()
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        await store.reload()
        try await until("The first months did not load.") { store.loaded[march] != nil && store.loaded[february] != nil }
        await store.settleProjections()
        let marchRow = try XCTUnwrap(store.entry(section: 0, item: 0))
        let date = try XCTUnwrap(APIDate.parse("2026-02-10T12:00:00Z"))
        MonthProjector.Probe.start()
        defer { MonthProjector.Probe.stop() }
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "phone", date: date)]))
        await store.settleProjections()
        XCTAssertEqual(MonthProjector.Probe.runs.flatMap(\.buckets), [february], "Only February is projected again.")
        XCTAssertEqual(store.sections.map(\.count), [1, 2, 2])
        XCTAssertEqual(store.entry(section: 0, item: 0), marchRow, "March keeps its rows.")
        XCTAssertEqual(store.entry(section: 1, item: 0)?.local?.id, "phone")

        // A month only the phone has is new to the grid: it alone is projected.
        let older = try XCTUnwrap(APIDate.parse("2024-01-10T12:00:00Z"))
        let photos = [LocalPhoto(id: "phone", date: date), LocalPhoto(id: "older", date: older)]
        store.updateDeviceTimeline(MergedTimeline(photos: photos))
        await store.settleProjections()
        XCTAssertEqual(MonthProjector.Probe.runs.last?.buckets, ["2024-01-01"])
        XCTAssertEqual(store.sections.map(\.id), [march, february, Self.june, "2024-01-01"])
        XCTAssertEqual(store.entry(section: 3, item: 0)?.local?.id, "older")

        let runs = MonthProjector.Probe.runs.count, revision = store.revision, reset = store.resetID
        store.updateDeviceTimeline(MergedTimeline(photos: photos))
        await store.settleProjections()
        XCTAssertEqual(MonthProjector.Probe.runs.count, runs, "An identical snapshot projects nothing.")
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.resetID, reset)
        store.stop()
    }

    /// F3: months are projected off the main actor, from the feed's deliveries, the phone's
    /// snapshots and an edited record alike.
    func testProjectionsNeverRunOnMain() async throws {
        let march = "2026-03-01T00:00:00Z", february = "2026-02-01T00:00:00Z"
        let api = try datedFixture()
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        MonthProjector.Probe.start()
        defer { MonthProjector.Probe.stop() }
        await store.reload()
        try await until("The first months did not load.") { store.loaded[march] != nil && store.loaded[february] != nil }
        let date = try XCTUnwrap(APIDate.parse("2026-02-10T12:00:00Z"))
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "phone", date: date)]))
        await store.settleProjections()
        store.update(Asset(id: "march", originalFileName: "march.jpg"))
        await store.settleProjections()
        let runs = MonthProjector.Probe.runs
        XCTAssertGreaterThanOrEqual(runs.filter { !$0.buckets.isEmpty }.count, 3, "The loads, the snapshot and the edit each project.")
        XCTAssertTrue(runs.allSatisfy { !$0.onMain }, "No projection ran on the main thread.")
        XCTAssertEqual(store.entry(section: 0, item: 0)?.remote?.originalFileName, "march.jpg")
        XCTAssertEqual(store.entry(section: 1, item: 0)?.local?.id, "phone")
        store.stop()
    }

    /// F3: a month the feed lets go while a run that projects it is on its way stays gone. The run
    /// used to bring its rows back, past the twelve resident months and out of reach of removals,
    /// edits and later evictions.
    func testAMonthLetGoDuringAProjectionRunStaysGone() async throws {
        let march = "2026-03-01T00:00:00Z", february = "2026-02-01T00:00:00Z"
        let api = try datedFixture()
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        await store.reload()
        try await until("The first months did not load.") { store.loaded[march] != nil && store.loaded[february] != nil }
        await store.settleProjections()
        let ticket = try XCTUnwrap(store.feedTicket)
        let juneMonth = try XCTUnwrap(MonthKey(bucketID: Self.june)), februaryMonth = try XCTUnwrap(MonthKey(bucketID: february))
        MonthProjector.Probe.start()
        defer { MonthProjector.Probe.stop() }
        // A photo is matched, as fingerprinting publishes: every loaded month is projected again.
        let taken = try XCTUnwrap(APIDate.parse("2026-02-10T12:00:00Z"))
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "copy", date: taken)], associations: ["copy": "february"]))
        // While that run is on its way, the feed delivers June and lets February go to make room.
        store.monthLoaded(ticket, month: juneMonth, assets: [Asset(id: "early"), Asset(id: "late")], fresh: true, evicting: [februaryMonth])
        await store.settleProjections()
        XCTAssertTrue(MonthProjector.Probe.runs.contains { Set($0.buckets) == [march, february] }, "The run took February.")
        XCTAssertNil(store.loaded[february])
        XCTAssertNil(store.entry(section: 1, item: 0), "February shows no rows until it is read again.")
        XCTAssertEqual(store.dayGroups(section: 1), [])
        XCTAssertEqual(store.entry(section: 0, item: 0)?.remote?.id, "march")
        XCTAssertEqual(store.loaded[Self.june]?.map(\.id), ["early", "late"])
        store.stop()
    }

    /// F3: when the feed delivers a month again while the phone's photos are being merged into it,
    /// the run that lands both keeps the grid on the photo it shows, as the phone's change alone does.
    func testAMonthDeliveredAgainDuringAPhoneRunKeepsTheAnchor() async throws {
        let february = "2026-02-01T00:00:00Z"
        let late = try XCTUnwrap(APIDate.parse("2026-02-20T12:00:00Z")), early = try XCTUnwrap(APIDate.parse("2026-02-05T12:00:00Z"))
        let server = [Asset(id: "late", localDateTime: late), Asset(id: "early", localDateTime: early)]
        let api = LibraryAPIFixture([], bucketAssets: [february: server])
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        await store.reload()
        try await until("February did not load.") { store.loaded[february] != nil }
        let before = try XCTUnwrap(APIDate.parse("2026-02-03T12:00:00Z")), after = try XCTUnwrap(APIDate.parse("2026-02-25T12:00:00Z"))
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "phone", date: before, modified: before)]))
        await store.settleProjections()
        XCTAssertEqual((0..<3).compactMap { store.entry(section: 0, item: $0)?.id }, ["late", "early", "local:phone"])
        let anchor = GridPosition(section: february, item: 1, offset: 17, assetID: "early")
        store.position = anchor
        XCTAssertNil(store.restorePosition)
        let reset = store.resetID, ticket = try XCTUnwrap(store.feedTicket), month = try XCTUnwrap(MonthKey(bucketID: february))

        // The phone's photo now dates after both server photos, above the one shown. While that is
        // merged in, a sync's read delivers February again.
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "phone", date: after, modified: after)]))
        store.monthLoaded(ticket, month: month, assets: server, fresh: true, evicting: [])
        await store.settleProjections()
        XCTAssertEqual((0..<3).compactMap { store.entry(section: 0, item: $0)?.id }, ["local:phone", "late", "early"])
        XCTAssertEqual(store.restorePosition, anchor, "The grid stays on the photo it shows.")
        XCTAssertNotEqual(store.resetID, reset)
        XCTAssertEqual(store.restoredIndex(for: anchor)?.item, 2)
        store.stop()
    }

    /// F3: the library a filter clears back to has the phone's photos as they are now: a photo
    /// taken while the filter showed leads it, and one deleted meanwhile is gone.
    func testClearingAFilterMergesThePhonesPhotosThatChangedMeanwhile() async throws {
        let march = "2026-03-01T00:00:00Z", february = "2026-02-01T00:00:00Z"
        let api = try datedFixture()
        let store = LibraryFeedStore(source: api, includesDevicePhotos: true)
        await store.reload()
        try await until("The first months did not load.") { store.loaded[march] != nil && store.loaded[february] != nil }
        let deleted = try XCTUnwrap(APIDate.parse("2026-02-10T12:00:00Z"))
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "deleted", date: deleted)]))
        await store.settleProjections()
        XCTAssertEqual(store.sections.map(\.count), [1, 2, 2])

        store.setFeed(.favorites, title: "Favorites")
        try await until("Favorites did not replace the library.") { !store.isReplacingFeed }
        let taken = try XCTUnwrap(APIDate.parse("2026-04-02T12:00:00Z"))
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "taken", date: taken)]))
        await store.settleProjections()

        store.clearFilters()
        await store.settleProjections()
        XCTAssertEqual(store.sections.map(\.id), ["2026-04-01", march, february, Self.june])
        XCTAssertEqual(store.sections.map(\.count), [1, 1, 1, 2], "The phone photo deleted meanwhile is gone.")
        XCTAssertEqual(store.entry(section: 0, item: 0)?.local?.id, "taken")
        store.stop()
    }

    /// A sync's reload keeps the rows shown until their months are read again (F2: the
    /// whole-snapshot cache is gone, so nothing older can be replayed over them either).
    func testBackgroundRefreshKeepsLiveRowsUntilTheirMonthsAreReadAgain() async throws {
        let api = LibraryAPIFixture([], delayedTimeline: true)
        let store = LibraryFeedStore(source: api)
        await store.reload()
        let bucket = "2026-01-01T00:00:00Z"
        store.loaded = [bucket: [Asset(id: "live-photo")]]
        let reset = store.resetID
        store.position = GridPosition(section: bucket, item: 0, offset: 17, assetID: "live-photo")

        await store.reload(preservingPosition: true)
        XCTAssertEqual(store.resetID, reset, "An unchanged sync summary must not recycle visible image cells.")
        XCTAssertEqual(store.asset(section: 0, item: 0)?.id, "live-photo")
        XCTAssertEqual(store.restorePosition, store.position)
        store.stop()
    }

    private static let june = "2025-06-01T00:00:00Z"
    private func datedFixture(slow: Set<String> = []) throws -> LibraryAPIFixture {
        let early = try XCTUnwrap(APIDate.parse("2025-06-02T12:00:00Z"))
        let late = try XCTUnwrap(APIDate.parse("2025-06-20T12:00:00Z"))
        return LibraryAPIFixture([], bucketAssets: [
            "2026-03-01T00:00:00Z": [Asset(id: "march")],
            "2026-02-01T00:00:00Z": [Asset(id: "february")],
            Self.june: [Asset(id: "early", fileCreatedAt: early, localDateTime: early), Asset(id: "late", fileCreatedAt: late, localDateTime: late)],
        ], slowBuckets: slow)
    }

    private func until(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }

    func testBackgroundRefreshPreservesTheVisibleOlderMonthHeading() async throws {
        let api = try datedFixture()
        let store = LibraryFeedStore(source: api)
        await store.reload()
        store.visibleSection(2)
        store.navigation.section = 2
        store.position = GridPosition(section: Self.june, item: 0, offset: 17, assetID: "early")
        let heading = store.title
        let reset = store.resetID

        await store.reload(preservingPosition: true)
        XCTAssertEqual(store.title, heading, "Sync must keep the heading for the month under the viewport.")
        XCTAssertEqual(store.navigation.section, 2)
        XCTAssertEqual(store.resetID, reset)
        XCTAssertEqual(store.restorePosition, store.position)
        store.stop()
    }

    func testPlaceRefreshKeepsUnchangedRowsAndRestoresAssetAfterReordering() async throws {
        let api = LibraryAPIFixture([], metadataPages: [
            .page(["place-a"], next: "page-2"),
            .page(["place-b", "place-c"]),
            .page(["place-a"], next: "page-2"),
            .page(["place-b", "place-c"]),
            .page(["place-c"], next: "page-2"),
            .page(["place-b", "place-a"]),
        ])
        let store = LibraryFeedStore(source: api)
        store.setFeed(.person("stale-person"), title: "Someone")
        store.setPlace(id: "nearby", assetIDs: ["place-a", "place-b", "place-c"], title: "Nearby")
        XCTAssertEqual(store.feedQuery, .place(PlaceMembership(placeID: "nearby", assetIDs: ["place-a", "place-b", "place-c"], markerQuery: "")),
                       "A place filter must discard stale person/album routing state.")
        try await until("The place results did not load.") { await api.metadataCalls == 1 && !store.isSearching }
        XCTAssertTrue(store.hasMore)
        store.loadMore()
        try await until("The second place result page did not load.") { await api.metadataCalls == 2 && !store.isSearching }
        XCTAssertEqual(store.results.map(\.id), ["place-a", "place-b", "place-c"])

        let anchor = GridPosition(section: "results", item: 1, offset: 23, assetID: "place-b")
        store.position = anchor
        let initialResetID = store.resetID
        await store.reload(preservingPosition: true)
        try await until("Both loaded place result pages did not refresh.") { await api.metadataCalls == 4 && !store.isSearching }
        XCTAssertEqual(store.results.map(\.id), ["place-a", "place-b", "place-c"], "A background refresh must replay the loaded page window.")
        XCTAssertEqual(store.resetID, initialResetID, "Unchanged result identities and order should keep visible grid cells.")
        XCTAssertEqual(store.restorePosition, anchor)

        await store.reload(preservingPosition: true)
        try await until("Both reordered place result pages did not refresh.") { await api.metadataCalls == 6 && !store.isSearching }
        XCTAssertNotEqual(store.resetID, initialResetID, "Changed result order should rebuild rows and restore the visible asset.")
        XCTAssertEqual(store.results.map(\.id), ["place-c", "place-b", "place-a"])
        XCTAssertEqual(store.restorePosition, anchor)
        XCTAssertEqual(store.restoredIndex(for: anchor)?.item, 1)
        store.stop()
    }

    func testRepeatedDateNavigationToLoadedBucketPublishesWithoutAnotherFetch() async throws {
        let bucket = "2026-01-01T00:00:00Z"
        let date = try XCTUnwrap(APIDate.parse("2026-01-15T12:00:00Z"))
        let asset = Asset(id: "loaded-photo", localDateTime: date)
        let api = LibraryAPIFixture([], bucketAssets: [bucket: [asset]])
        let store = LibraryFeedStore(source: api)
        await store.reload()
        try await until("Initial bucket did not load.") { store.loaded[bucket] != nil }
        let callsBefore = await api.bucketCalls.count
        // A loaded rail target must not remain in the pending queue either.
        store.scrollToBucket(0)
        store.showInTimeline(asset)
        try await until("Loaded date navigation stalled on a phantom pending request.") { store.scrollRequest != nil }
        XCTAssertEqual(store.scrollRequest?.position.assetID, asset.id)
        let firstRequest = store.scrollRequest?.id
        store.showInTimeline(asset)
        try await until("Repeated loaded date navigation did not finish.") { store.scrollRequest != nil }
        XCTAssertNotEqual(store.scrollRequest?.id, firstRequest)
        XCTAssertEqual(store.scrollRequest?.position.assetID, asset.id)
        let callsAfter = await api.bucketCalls.count
        XCTAssertEqual(callsAfter, callsBefore)
        store.stop()
    }

    func testColdRailScrubBoundsRequestsAndLoadsLatestIntent() async throws {
        let assets = Dictionary(uniqueKeysWithValues: (0..<60).map { index in
            (String(format: "%04d-%02d-01T00:00:00Z", 2000 + index / 12, index % 12 + 1), [Asset(id: "photo-\(index)")])
        })
        let api = LibraryAPIFixture([], bucketAssets: assets, bucketDelay: .milliseconds(40))
        let store = LibraryFeedStore(source: api)
        await store.reload()
        let reset = store.resetID
        for section in store.buckets.indices { store.scrollToBucket(section) }
        let target = try XCTUnwrap(store.buckets.last?.id)
        try await until("The final cold scrub target never loaded.") { store.loaded[target] != nil }
        let maximum = await api.maximumConcurrentBuckets
        let calls = await api.bucketCalls
        XCTAssertLessThanOrEqual(maximum, 3)
        XCTAssertLessThanOrEqual(calls.count, 10, "Intermediate drag positions must be coalesced, not queued indefinitely.")
        XCTAssertEqual(store.resetID, reset, "Scrubbing must not reload the entire collection.")
        XCTAssertEqual(store.loaded[target]?.first?.id, assets[target]?.first?.id)
        store.stop()
    }

    func testCancelledScrubRequestsDoNotBlockTheNextFeedGeneration() async throws {
        let assets = Dictionary(uniqueKeysWithValues: (0..<20).map { index in
            (String(format: "%04d-%02d-01T00:00:00Z", 2000 + index / 12, index % 12 + 1), [Asset(id: "photo-\(index)")])
        })
        let api = LibraryAPIFixture([], bucketAssets: assets, bucketDelay: .milliseconds(100))
        let store = LibraryFeedStore(source: api)
        await store.reload()
        for section in store.buckets.indices { store.scrollToBucket(section) }
        await Task.yield()
        store.stop()
        await store.reload()
        let finalIndex = store.buckets.count - 1
        store.scrollToBucket(finalIndex)
        let target = store.buckets[finalIndex].id
        try await until("Cancelled requests poisoned the new generation's target.") { store.loaded[target] != nil }
        XCTAssertEqual(store.loaded[target]?.first?.id, assets[target]?.first?.id)
        XCTAssertNil(store.bucketErrors[target])
        store.stop()
    }

    func testBackgroundBucketCompletionsCannotEvictVisiblePhotos() async throws {
        let assets = Dictionary(uniqueKeysWithValues: (0..<18).map { index in
            (String(format: "%04d-%02d-01T00:00:00Z", 2000 + index / 12, index % 12 + 1), [Asset(id: "photo-\(index)")])
        })
        let api = LibraryAPIFixture([], bucketAssets: assets)
        // Months of one photo each: the photo budget is set aside so the month bound applies.
        let store = LibraryFeedStore(source: api, residentPhotoBudget: 0)
        await store.reload()
        let first = try XCTUnwrap(store.buckets.first?.id)
        try await until("Initial bucket did not load.") { store.loaded[first] != nil }
        store.visibleSection(0)
        let original = store.loaded[first]?.map(\.id)
        for index in 2..<store.buckets.count {
            let id = store.buckets[index].id
            store.requestBucket(index)
            try await until("Background bucket did not load.") { store.loaded[id] != nil }
            XCTAssertEqual(store.loaded[first]?.map(\.id), original)
        }
        XCTAssertLessThanOrEqual(store.loaded.count, 12)
        store.stop()
    }

    func testRepeatedRailJumpsToTheSameMonthAreDistinctRequests() async throws {
        let api = try datedFixture()
        let store = LibraryFeedStore(source: api)
        await store.reload()
        store.scrollToBucket(1)
        let first = try XCTUnwrap(store.scrollRequest)
        store.scrollToBucket(1)
        let second = try XCTUnwrap(store.scrollRequest)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.position, second.position)
        XCTAssertEqual(first.position.section, "2026-02-01T00:00:00Z")
        XCTAssertEqual(first.position.item, 0)
        store.stop()
    }

    func testRailJumpPreservesAndClampsTheRequestedItemWithinItsMonth() async throws {
        let bucket = "2026-01-01T00:00:00Z"
        let api = LibraryAPIFixture([], bucketAssets: [bucket: (0..<3).map { Asset(id: "photo-\($0)") }])
        let store = LibraryFeedStore(source: api)
        await store.reload()

        store.scrollToBucket(0, item: 1)
        XCTAssertEqual(store.scrollRequest?.position.section, bucket)
        XCTAssertEqual(store.scrollRequest?.position.item, 1)

        store.scrollToBucket(0, item: -1)
        XCTAssertEqual(store.scrollRequest?.position.item, 0)
        store.scrollToBucket(0, item: 99)
        XCTAssertEqual(store.scrollRequest?.position.item, 2)
        store.stop()
    }

    func testShowInTimelineLoadsTheUnloadedMonthAndFindsTheAsset() async throws {
        let api = try datedFixture()
        let store = LibraryFeedStore(source: api)
        store.setFeed(.favorites, title: "Favorites")
        store.selected = ["other"]; store.isSelecting = true
        let date = try XCTUnwrap(APIDate.parse("2025-06-20T12:00:00Z"))
        store.showInTimeline(Asset(id: "late", fileCreatedAt: date, localDateTime: date))
        XCTAssertNil(store.filterTitle)
        XCTAssertTrue(store.selected.isEmpty)
        XCTAssertFalse(store.isSelecting)
        try await until("The date navigation never published a scroll request.") { store.scrollRequest != nil }
        let request = try XCTUnwrap(store.scrollRequest)
        XCTAssertEqual(request.position.section, Self.june)
        XCTAssertEqual(request.position.assetID, "late")
        XCTAssertEqual(store.loaded[Self.june]?.map(\.id), ["early", "late"])
        XCTAssertEqual(store.restoredIndex(for: request.position)?.section, 2)
        XCTAssertEqual(store.restoredIndex(for: request.position)?.item, 1)
        XCTAssertNil(store.error)

        // A missing asset falls back to the nearest capture date in the same month.
        let near = try XCTUnwrap(APIDate.parse("2025-06-19T00:00:00Z"))
        store.showInTimeline(Asset(id: "elsewhere", fileCreatedAt: near))
        try await until("The fallback navigation never published.") { store.scrollRequest != nil }
        XCTAssertEqual(store.scrollRequest?.position.assetID, "late")
        XCTAssertNotEqual(store.scrollRequest?.id, request.id)
        store.stop()
    }

    /// From the library itself (a memory's Show in timeline), the feed shown stays, and the
    /// photo's month still loads with the plan the library was opened with.
    func testShowInTimelineFromTheLibraryLoadsAnUnloadedMonth() async throws {
        let api = try datedFixture()
        let store = LibraryFeedStore(source: api)
        await store.reload()
        try await until("The library did not load.") { store.loaded["2026-03-01T00:00:00Z"] != nil }
        XCTAssertNil(store.loaded[Self.june])
        let date = try XCTUnwrap(APIDate.parse("2025-06-20T12:00:00Z"))
        store.showInTimeline(Asset(id: "late", fileCreatedAt: date, localDateTime: date))
        try await until("The photo's month never loaded.") { store.scrollRequest != nil }
        XCTAssertEqual(store.scrollRequest?.position.assetID, "late")
        XCTAssertNotNil(store.feedPlan)
        XCTAssertNil(store.error)
        store.stop()
    }

    func testScopeChangeOrStopPreventsAnOldDateNavigationFromPublishing() async throws {
        let api = try datedFixture(slow: [Self.june])
        let store = LibraryFeedStore(source: api)
        let date = try XCTUnwrap(APIDate.parse("2025-06-20T12:00:00Z"))
        let asset = Asset(id: "late", fileCreatedAt: date, localDateTime: date)
        store.showInTimeline(asset)
        try await until("The target month was never requested.") { await api.bucketCalls.contains(Self.june) }
        store.setFeed(.favorites, title: "Favorites")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.scrollRequest)

        store.showInTimeline(asset)
        try await until("The target month was never requested again.") { await api.bucketCalls.filter { $0 == Self.june }.count >= 2 }
        store.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.scrollRequest)
    }

    func testRailJumpSupersedesPendingDateNavigation() async throws {
        let api = try datedFixture(slow: [Self.june])
        let store = LibraryFeedStore(source: api)
        let date = try XCTUnwrap(APIDate.parse("2025-06-20T12:00:00Z"))
        store.showInTimeline(Asset(id: "late", localDateTime: date))
        try await until("The target month was never requested.") { await api.bucketCalls.contains(Self.june) }
        store.scrollToBucket(0)
        let request = try XCTUnwrap(store.scrollRequest)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.scrollRequest, request)
        XCTAssertEqual(request.position.section, "2026-03-01T00:00:00Z")
        store.stop()
    }

    /// N4: a feed showing an album that is deleted or left, here or anywhere else the account's
    /// collections hear of it, clears back to the library, and through the account's bus the
    /// search text goes with it. A change to another album leaves the filter; a rename of the
    /// album shown names the filter anew, and a rename of a person shown names theirs.
    func testDeletingOrLeavingTheFilteredAlbumClearsTheFilter() async throws {
        let api = LibraryAPIFixture([], timelineAssets: [Asset(id: "a")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        let coast = Album(id: "coast", albumName: "Coast", assetCount: 1, shared: false, albumUsers: nil, startDate: nil, endDate: nil,
                          updatedAt: nil, order: "desc")
        var renamed = coast
        renamed.albumName = "Coast at dusk"

        for removal in [CollectionChange.albumDeleted("coast"), .albumLeft("coast")] {
            store.setAlbum(coast)
            XCTAssertEqual(store.filterTitle, "Coast")
            XCTAssertFalse(store.apply(.albumDeleted("harbor")), "Another album's deletion leaves the filter.")
            XCTAssertFalse(store.apply(.albumLeft("harbor")))
            XCTAssertEqual(store.feedQuery.predicates.albums, ["coast"])
            XCTAssertFalse(store.apply(.albumUpdated(renamed)))
            XCTAssertEqual(store.filterTitle, "Coast at dusk", "A rename names the filter anew.")
            XCTAssertTrue(store.apply(removal), "\(removal) clears the filter.")
            XCTAssertFalse(store.isFiltered)
            XCTAssertNil(store.filterTitle)
            XCTAssertEqual(store.feedQuery, .library)
        }

        // On the bus, as the library follows it: the search text goes with the filter.
        store.setAlbum(coast)
        let cleared = await FeedEventApplier.apply(.collection(.albumLeft("coast")), to: store, refreshes: false)
        XCTAssertTrue(cleared, "The search text goes with the filter.")
        XCTAssertFalse(store.isFiltered)
        let kept = await FeedEventApplier.apply(.collection(.albumDeleted("coast")), to: store, refreshes: false)
        XCTAssertFalse(kept, "With no filter there is nothing to clear.")

        let maya = Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: false, isFavorite: nil)
        store.setPerson(maya)
        var renamedMaya = maya
        renamedMaya.name = "Maya R."
        store.apply(.personUpdated(renamedMaya))
        XCTAssertEqual(store.filterTitle, "Maya R.")
        XCTAssertFalse(store.apply(.albumDeleted("coast")), "An album's deletion leaves a person's filter.")
        XCTAssertTrue(store.isFiltered)
    }

    /// N4: a partner shown in the timeline, added or removed reads the feed again, as a sync's
    /// partner change does.
    func testAPartnerChangeReadsTheFeedAgain() async throws {
        let api = LibraryAPIFixture([], timelineAssets: [Asset(id: "a")])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        let before = await api.summaryCalls
        XCTAssertFalse(store.apply(.partnersChanged))
        try await until("The feed was not read again.") { await api.summaryCalls == before + 1 }
        store.apply(.memorySaved("memory", saved: true))
        store.apply(.albumCreated(Album(id: "reef", albumName: "Reef", assetCount: 1, shared: false, albumUsers: nil, startDate: nil,
                                        endDate: nil, updatedAt: nil, order: nil)))
        try await Task.sleep(for: .milliseconds(100))
        let after = await api.summaryCalls
        XCTAssertEqual(after, before + 1, "A memory saved or an album made reads nothing again.")
    }

    private func settleSelection(_ store: LibraryFeedStore) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while store.isSelectingGroup && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isSelectingGroup)
        XCTAssertNil(store.error)
    }
}

/// A library of one month whose places depend on the person chosen. With `byMonth`, a chosen
/// place is laid out by month in May 2023, as the offline library would; with `placeFails`, the
/// offline library turns out not to be ready.
private actor PlacesAPIFixture: FakeFeedSource {
    nonisolated let cacheScope: String
    private let places: [String?: [MonthPlaceCount]]
    private let delay: Duration
    private let byMonth: Bool
    private let placeFails: Bool
    init(scope: String = "test-places-" + UUID().uuidString, places: [String?: [MonthPlaceCount]], delay: Duration = .zero,
         byMonth: Bool = false, placeFails: Bool = false) {
        cacheScope = scope; self.places = places; self.delay = delay; self.byMonth = byMonth; self.placeFails = placeFails
    }
    /// The offline library lays a place out by month only when it is readable.
    func plan(_ query: LibraryQuery) async throws -> QueryPlan {
        try QueryPlanner.plan(query, context: PlannerContext(indexReadable: byMonth && !placeFails))
    }
    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] {
        guard let place = query.predicates.place else { return [.init(timeBucket: "2024-10-01T00:00:00Z", count: 1)] }
        return [.init(timeBucket: "2023-05-01T00:00:00Z", count: place.assetIDs.count)]
    }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] {
        if let place = query.predicates.place { return place.assetIDs.map { Asset(id: $0) } }
        return [Asset(id: "photo-\(query.predicates.people.first ?? "library")")]
    }
    /// A place found by search, as without the offline library.
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { .page(["lisbon-1", "lisbon-2"]) }
    func search(_ query: SearchQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
    func placeCounts(_ query: LibraryQuery) async throws -> [MonthPlaceCount] {
        if delay > .zero { try await Task.sleep(for: delay) }
        return places[query.predicates.people.first] ?? []
    }
}

/// A one-month library whose routing moves to the index when told, recording the backend each
/// library month was read from.
private actor RoutingAPIFixture: FakeFeedSource {
    nonisolated let cacheScope = "test-routing-" + UUID().uuidString
    private var indexReadable = false
    var libraryReads: [QueryPlan.Backend] = []
    func setIndexReadable(_ readable: Bool) { indexReadable = readable }
    func plan(_ query: LibraryQuery) async throws -> QueryPlan {
        try QueryPlanner.plan(query, context: PlannerContext(indexReadable: indexReadable))
    }
    func summary(_ query: LibraryQuery, plan: QueryPlan) async throws -> [TimeBucket] {
        if query == .library { libraryReads.append(plan.backend) }
        return [.init(timeBucket: "2024-10-01T00:00:00Z", count: 1)]
    }
    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] { [.init(timeBucket: "2024-10-01T00:00:00Z", count: 1)] }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] { [Asset(id: "photo")] }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { .page([]) }
    func search(_ query: SearchQuery) async throws -> SearchResponse { .page([]) }
}

private actor LibraryAPIFixture: FakeFeedSource {
    nonisolated let cacheScope = "test-library-" + UUID().uuidString
    var cursors: [String?] = []
    var metadataCalls = 0
    private var pages: [SearchResponse]
    private var metadataPages: [SearchResponse]
    private let delayed: Bool
    private let timelineAssets: [Asset]
    private let scopedTimelineAssets: [String: [Asset]]
    private let delayedTimeline: Bool
    private let delayedSummary: Bool
    private var delayedTimelineScopes: Set<String> = []
    private var failingTimelineScopes: Set<String>
    private let bucketAssets: [String: [Asset]]
    private let slowBuckets: Set<String>
    var bucketCalls: [String] = []
    var maximumConcurrentBuckets = 0
    private var activeBuckets = 0
    private let bucketDelay: Duration
    init(_ pages: [SearchResponse], delayed: Bool = false, timelineAssets: [Asset] = [Asset(id: "timeline-photo")], delayedTimeline: Bool = false,
         bucketAssets: [String: [Asset]] = [:], slowBuckets: Set<String> = [], metadataPages: [SearchResponse] = [],
         scopedTimelineAssets: [String: [Asset]] = [:], failingTimelineScopes: Set<String> = [], bucketDelay: Duration = .zero,
         delayedSummary: Bool = false) {
        self.delayedSummary = delayedSummary
        self.bucketDelay = bucketDelay
        self.pages = pages; self.delayed = delayed; self.timelineAssets = timelineAssets; self.delayedTimeline = delayedTimeline
        self.bucketAssets = bucketAssets; self.slowBuckets = slowBuckets; self.metadataPages = metadataPages
        self.scopedTimelineAssets = scopedTimelineAssets; self.failingTimelineScopes = failingTimelineScopes
    }
    var summaryCalls = 0
    var refreshes = 0
    private var refreshChange: LibraryChange?
    func setRefreshChange(_ change: LibraryChange?) { refreshChange = change }
    func refresh() async throws -> LibraryChange? { refreshes += 1; return refreshChange }
    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] {
        summaryCalls += 1
        if delayedSummary { try await Task.sleep(for: .seconds(3)) }
        if !bucketAssets.isEmpty { return bucketAssets.keys.sorted(by: >).map { .init(timeBucket: $0, count: bucketAssets[$0]?.count ?? 0) } }
        return [.init(timeBucket: "2026-01-01T00:00:00Z", count: assets(for: query).count)]
    }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] {
        bucketCalls.append(bucket)
        activeBuckets += 1; maximumConcurrentBuckets = max(maximumConcurrentBuckets, activeBuckets)
        defer { activeBuckets -= 1 }
        if bucketDelay > .zero { try await Task.sleep(for: bucketDelay) }
        let scope = scopeKey(query)
        if delayedTimeline || delayedTimelineScopes.contains(scope) || slowBuckets.contains(bucket) { try await Task.sleep(for: .seconds(3)) }
        if failingTimelineScopes.contains(scope) { throw ServerFailure.http(500, nil) }
        if let assets = bucketAssets[bucket] { return assets }
        return assets(for: query)
    }
    func setTimelineBehavior(scope: String, delayed: Bool = false, failing: Bool = false) {
        if delayed { delayedTimelineScopes.insert(scope) } else { delayedTimelineScopes.remove(scope) }
        if failing { failingTimelineScopes.insert(scope) } else { failingTimelineScopes.remove(scope) }
    }
    private func scopeKey(_ query: LibraryQuery) -> String {
        if query.predicates.favorite == true { return "favorites" }
        if query.visibility == .archive { return "archive" }
        return "default"
    }
    private func assets(for query: LibraryQuery) -> [Asset] {
        scopedTimelineAssets[scopeKey(query)] ?? timelineAssets
    }
    func search(_ query: SearchQuery) async throws -> SearchResponse {
        cursors.append(query.cursor)
        if delayed { try await Task.sleep(for: .seconds(3)) }
        guard !pages.isEmpty else { throw ServerFailure.http(500, nil) }
        return pages.removeFirst()
    }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse {
        metadataCalls += 1; metadataSizes.append(query.size)
        guard !metadataPages.isEmpty else { throw ServerFailure.http(500, nil) }
        return metadataPages.removeFirst()
    }
    var metadataSizes: [Int] = []
}

private extension SearchResponse {
    static func page(_ ids: [String], next: String? = nil, status: Verification.Status = .complete) -> Self {
        page(assets: ids.map { Asset(id: $0) }, next: next, status: status)
    }
    static func page(assets: [Asset], next: String? = nil, status: Verification.Status = .complete) -> Self {
        .init(assets: .init(items: assets, count: assets.count, nextCursor: next, nextPage: nil),
              verification: .init(status: status, checked: 10, rejected: 10 - assets.count))
    }
}

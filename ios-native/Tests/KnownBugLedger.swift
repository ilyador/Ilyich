import Foundation
import IlyichPlatform
import Network
import Synchronization
import XCTest
@testable import Ilyich

/// Known bugs, each pinned by a test that runs today's code and shows the bug. The checks that
/// fail are wrapped in a strict XCTExpectFailure naming the bug and the milestone that fixes it.
/// When that milestone lands the checks pass, the strict wrapper then fails the test, and whoever
/// fixed the bug removes the wrapper. A part already fixed has a plain test instead, and the bugs
/// these tests cannot reach are listed at the end with the reason.
@MainActor final class KnownBugLedgerTests: XCTestCase {
    // MARK: - Feed

    /// FEED-1. Opening a photo calls update(_:) with its detailed record, as
    /// AssetViewer.refreshCurrentAsset does on every open, and update drops the saved library
    /// timeline. Clearing the filter then reloads the library from its top instead of returning to
    /// the photo it was showing.
    func testOpeningAPhotoInAFilterKeepsTheLibraryPositionForClear() async throws {
        let june = "2025-06-01T00:00:00Z"
        let early = try XCTUnwrap(APIDate.parse("2025-06-02T12:00:00Z"))
        let late = try XCTUnwrap(APIDate.parse("2025-06-20T12:00:00Z"))
        let api = LedgerLibrary(months: [
            "2026-03-01T00:00:00Z": [Asset(id: "march")],
            "2026-02-01T00:00:00Z": [Asset(id: "february")],
            june: [Asset(id: "early", localDateTime: early), Asset(id: "late", localDateTime: late)],
        ])
        removeCachesAfterwards(api.cacheScope)
        let store = LibraryStore(api: api)
        defer { store.stop() }
        await store.reload()
        store.visibleSection(2)
        try await until("June did not load.") { store.loaded[june] != nil }
        let position = GridPosition(section: june, item: 1, offset: 17, assetID: "late")
        store.position = position

        store.setPerson(Self.maya)
        try await until("The person's feed did not replace the library.") { !store.isReplacingFeed }
        store.update(Asset(id: "late", originalFileName: "late.jpg", localDateTime: late))
        store.clearFilters()
        let restored = await eventually { store.restorePosition == position }

        XCTExpectFailure("FEED-1: opening a photo in a filter loses the library position. F4 removes this wrapper.", strict: true) {
            XCTAssertTrue(restored, "Clearing the filter returns to the photo the library was showing.")
        }
    }

    /// FEED-2. With the phone's photos merged in, a month only the phone has is a section of its
    /// own. A reload that replaces a frozen feed commits only once its first two months have
    /// loaded from the server, which a phone-only month never does, so the old feed stays frozen:
    /// no scrolling, no taps and no rail. Clearing a filter takes that path whenever its saved
    /// timeline is gone, here after a refresh that follows a mutation.
    func testClearingCommitsWhenTheNewestMonthIsOnlyOnThePhone() async throws {
        let january = "2026-01-01T00:00:00Z"
        let day = try XCTUnwrap(APIDate.parse("2026-01-15T12:00:00Z"))
        let api = LedgerLibrary(months: [january: [Asset(id: "server-photo", localDateTime: day)]])
        removeCachesAfterwards(api.cacheScope)
        let store = LibraryStore(api: api, includesDevicePhotos: true)
        defer { store.stop() }
        await store.reload()
        try await until("The server's month did not load.") { store.loaded[january] != nil }
        let taken = try XCTUnwrap(APIDate.parse("2026-02-10T12:00:00Z"))
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "phone-only", date: taken)]))
        XCTAssertEqual(store.sections.first?.id, "2026-02-01", "The phone's newer month leads the library.")

        store.setTimeline(TimelineFilter(isFavorite: true), title: "Favorites")
        try await until("Favorites did not replace the library.") { !store.isReplacingFeed }
        await store.refreshAfterMutation()
        store.clearFilters()
        let committed = await eventually(within: .seconds(3)) { !store.isReplacingFeed }
        let newest = store.sections.first?.id

        XCTExpectFailure("FEED-2: a phone-only newest month freezes Clear. F4 removes this wrapper.", strict: true) {
            XCTAssertTrue(committed, "Clearing replaces the frozen feed with the library.")
            XCTAssertEqual(newest, "2026-02-01", "The library leads with the phone's month again.")
        }
    }

    /// FEED-3. A sync that lands while a new scope's feed is loading reloads it keeping the
    /// position, as LibraryView does on every sync. That reload asks first for the month under the
    /// old position and the one after it, then for the first two months, so the second month waits
    /// for a free slot. The reload awaits only requests already running, finds the second month
    /// missing and gives up, and nothing else commits the frozen feed.
    func testReplacementCommitsWhenASyncReloadRacesTheScopeChange() async throws {
        let months = Dictionary(uniqueKeysWithValues: (1...6).map { month in
            (String(format: "2026-%02d-01T00:00:00Z", month), [Asset(id: "photo-\(month)")])
        })
        // The second month is slow, so it is still loading when the reload checks for it.
        let api = LedgerLibrary(months: months, delay: .milliseconds(50), slow: ["2026-05-01T00:00:00Z": .seconds(1)])
        removeCachesAfterwards(api.cacheScope)
        let store = LibraryStore(api: api)
        defer { store.stop() }
        await store.reload()
        try await until("The newest month did not load.") { store.loaded["2026-06-01T00:00:00Z"] != nil }
        store.position = GridPosition(section: store.buckets[4].id, item: 0, offset: 0)

        await api.holdSummaries()
        store.setTimeline(TimelineFilter(isFavorite: true), title: "Favorites")
        try await until("The new scope never asked for its months.") { await api.summaryCalls == 2 }
        let sync = Task { await store.reload(preservingPosition: true) }
        try await until("The sync's reload never asked for its months.") { await api.summaryCalls == 3 }
        await api.releaseSummaries()
        await sync.value
        let committed = await eventually(within: .seconds(3)) { !store.isReplacingFeed }

        XCTExpectFailure("FEED-3: a sync reload racing a scope change leaves the feed frozen. F4 removes this wrapper.", strict: true) {
            XCTAssertTrue(committed, "The new scope's feed replaces the frozen one.")
        }
    }

    /// FEED-4. Months waiting for a request slot are queued by section index. When the phone adds
    /// a month newer than every other, each index moves down by one, so the queue names the months
    /// before the ones asked for: one already in flight is skipped, and the last month asked for
    /// is never loaded.
    func testQueuedMonthStillLoadsAfterThePhoneAddsANewerMonth() async throws {
        let months = Dictionary(uniqueKeysWithValues: (3...12).map { month in
            (String(format: "2025-%02d-01T00:00:00Z", month), [Asset(id: "photo-\(month)")])
        })
        let api = LedgerLibrary(months: months, delay: .milliseconds(200))
        removeCachesAfterwards(api.cacheScope)
        let store = LibraryStore(api: api, includesDevicePhotos: true)
        defer { store.stop() }
        await store.reload()
        let asked = store.buckets[8].id
        // The first two months are loading; month 5 takes the last slot, and 6, 7 and 8 wait.
        for section in 5...8 { store.requestBucket(section) }
        let taken = try XCTUnwrap(APIDate.parse("2026-01-10T12:00:00Z"))
        store.updateDeviceTimeline(MergedTimeline(photos: [LocalPhoto(id: "phone-only", date: taken)]))
        XCTAssertEqual(store.sections.first?.id, "2026-01-01", "The phone's month is now the first section.")
        let loaded = await eventually(within: .seconds(3)) { store.loaded[asked] != nil }

        XCTExpectFailure("FEED-4: queued months shift when a section is inserted. F2 removes this wrapper.", strict: true) {
            XCTAssertTrue(loaded, "A month asked for loads once a slot frees.")
        }
    }

    /// FEED-5. A month's size comes only from the summary and is never reconciled with the photos
    /// the month returns. A month holding fewer photos than its count keeps "Loading photo" cells
    /// for good, because a loaded month is never asked for again.
    func testMonthSmallerThanItsSummaryLeavesNoPermanentPlaceholder() async throws {
        let month = "2026-01-01T00:00:00Z"
        let api = LedgerLibrary(months: [month: [Asset(id: "first"), Asset(id: "second")]], counts: [month: 3])
        removeCachesAfterwards(api.cacheScope)
        let store = LibraryStore(api: api)
        defer { store.stop() }
        await store.reload()
        try await until("The month did not load.") { store.loaded[month] != nil }
        // The grid shows the month and asks for it again.
        store.visibleSections([0])
        let complete = await eventually {
            let count = store.sections.first?.count ?? 0
            return count > 0 && (0..<count).allSatisfy { store.asset(section: 0, item: $0) != nil }
        }

        XCTExpectFailure("FEED-5: a month smaller than its summary keeps placeholders. F2 removes this wrapper.", strict: true) {
            XCTAssertTrue(complete, "Every cell of a loaded month shows a photo.")
        }
    }

    /// FEED-6. A feed's month places are saved on the phone from an unowned task, with no fence.
    /// When access changes while they are being counted (a revoked album or partner, a library
    /// reset, sign-out), SessionStore deletes the saved places, and the late count writes them
    /// back, so places the account may no longer see show at the next launch.
    func testPlacesCountedBeforeAnAccessChangeAreNotKept() async throws {
        let month = "2026-02-01T00:00:00Z"
        let api = LedgerLibrary(months: [month: [Asset(id: "photo")]], holdPlaces: true,
                                places: [MonthPlaceCount(bucket: "2026-02-01", city: "Kyoto", country: "Japan", count: 4)])
        removeCachesAfterwards(api.cacheScope)
        let store = LibraryStore(api: api, placesDelay: .zero)
        defer { store.stop() }
        await store.reload()
        try await until("The places were never counted.") { await api.placesCalls == 1 }

        // Access changes, and SessionStore drops what the phone kept for this account.
        await TimelinePlacesCache.shared.removeAll(scope: api.cacheScope)
        await TimelineCache.shared.removeAll(scope: api.cacheScope)
        await api.releasePlaces()
        try await until("The count never finished.") { await api.placesAnswered == 1 }
        let saved = await eventually(within: .seconds(1)) {
            await TimelinePlacesCache.shared.load(scope: api.cacheScope, filter: TimelineFilter()) != nil
        }

        XCTExpectFailure("FEED-6: places counted before an access change are saved after it. C6 removes this wrapper.", strict: true) {
            XCTAssertFalse(saved, "A count from before the access change is not kept on the phone.")
        }
    }

    // MARK: - Account

    /// AUTH-1. auth/login answers a wrong password with 401 and the reason in an Immich body.
    /// APIClient turns every 401 into "Your session has expired", and SignInView shows the error's
    /// description, so a mistyped password reads as an expired session.
    func testWrongPasswordShowsTheServerMessage() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/login", .immichError(401, message: "Incorrect email or password"))
        let api = try stubClient(server)
        var shown: String?
        do { _ = try await api.login(email: "maya@example.test", password: "not-it") }
        catch { shown = error.localizedDescription }
        let message = try XCTUnwrap(shown, "A wrong password must not sign in.")

        XCTExpectFailure("AUTH-1: a wrong password shows the expired-session text. C5 removes this wrapper.", strict: true) {
            XCTAssertEqual(message, "Incorrect email or password", "Sign-in shows the server's reason.")
        }
    }

    /// AUTH-2. With automatic endpoint switching on, requests wait for one shared resolution of
    /// the server's address. A request elsewhere that loses its route invalidates the connection,
    /// which cancels that resolution, and every request waiting on it throws CancellationError.
    /// Callers take it for their own cancellation and swallow it; SessionStore.startSync then
    /// returns without clearing its sync state, so sync stays off.
    func testInvalidationDuringResolutionDoesNotCancelWaiters() async throws {
        let wifi = HeldWiFiName()
        let configuration = NetworkConfiguration(alternateEndpoints: [URL(string: "http://127.0.0.1:9")!],
                                                 automaticallySwitchEndpoints: true, preferredWifiName: "Home",
                                                 localEndpoint: URL(string: "http://127.0.0.1:7")!)
        let connection = try ServerConnection(server: URL(string: "http://127.0.0.1:1")!, configuration: configuration, wifiName: wifi)
        let waiting = Task { try await connection.request(path: "timeline/buckets") }
        try await until("The address was never being resolved.") { wifi.gate.waiting == 1 }
        // Another request's lost route, as APIClient.perform reports it.
        await connection.invalidate()
        wifi.gate.open()
        var cancelled = false
        do { _ = try await waiting.value }
        catch is CancellationError { cancelled = true }
        catch { /* No configured address answers here, which is an honest failure. */ }

        XCTExpectFailure("AUTH-2: endpoint invalidation surfaces CancellationError. C5 removes this wrapper.", strict: true) {
            XCTAssertFalse(cancelled, "A request nobody cancelled does not end with CancellationError.")
        }
    }

    // MARK: - Sync

    /// SYNC-2. The live event stream keeps only the newest invalidation, so hints that arrive while
    /// a sync pass runs overwrite each other: a configuration change and the asset IDs of earlier
    /// events are lost. on_asset_stack_update also spreads its IDs as separate arguments, while the
    /// parser looks for one array, so those IDs are dropped too.
    func testSocketBurstKeepsEveryHint() async throws {
        let server = try SocketBurstServer(packets: [
            #"42["on_config_update"]"#,
            #"42["on_asset_update",{"id":"x"}]"#,
            #"42["on_asset_stack_update","a","b"]"#,
        ])
        let port = try await server.start()
        defer { server.stop() }
        let api = try APIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), accessToken: "ledger-session",
                                userID: "alice", networkConfiguration: NetworkConfiguration())
        let events = try await api.serverEvents()
        try await until("The client never answered the ping that follows the burst.") { server.ponged }
        // Nothing has read the stream yet, as while NativeSync waits for a sync pass.
        let reader = Task {
            var hints: [ServerInvalidation] = []
            do { for try await hint in events.events { hints.append(hint) } } catch {}
            return hints
        }
        try await Task.sleep(for: .milliseconds(300))
        events.close()
        let hints = await reader.value
        let ids = hints.reduce(into: Set<String>()) { $0.formUnion($1.assetIDs) }
        let configurationChanged = hints.contains { $0.configurationChanged }

        XCTExpectFailure("SYNC-2: socket hints in a burst are dropped. Q1 removes this wrapper.", strict: true) {
            XCTAssertTrue(configurationChanged, "The configuration change survives the burst.")
            XCTAssertEqual(ids, ["x", "a", "b"], "Every asset ID in the burst survives it.")
        }
    }

    // MARK: - Media

    /// MEDIA-1. A photo deleted on the server reaches the offline index as AssetDeleteV1, and the
    /// index reports it as an access change as well as a deletion. SessionStore.didSync empties the
    /// whole thumbnail store, the URL cache and every decoded image whenever an access change is
    /// reported, so its branch that forgets only the deleted photos never runs for a deletion.
    func testSyncedDeletionIsNotAnAccessChange() async throws {
        let (sync, index, server) = try makeSyncedIndex()
        _ = try await pass([asset("kept"), asset("deleted"), complete()], through: sync, server: server)
        _ = try await index.takeAccessInvalidation()
        let summary = try await pass([event("AssetDeleteV1", #"{"assetId":"deleted"}"#, ack: "AssetDeleteV1|deleted"), complete()],
                                     through: sync, server: server)
        let invalidated = try await index.takeAccessInvalidation()
        XCTAssertEqual(summary.deletedAssetIDs, ["deleted"], "The deletion itself is reported.")

        XCTExpectFailure("MEDIA-1: a synced deletion wipes the thumbnail store. Q6 removes this wrapper.", strict: true) {
            XCTAssertFalse(summary.accessChanged, "A deletion is not a change in what the account may see.")
            XCTAssertFalse(invalidated, "Nor is it kept as one for a later sync.")
        }
    }

    /// MEDIA-2. Removing one of my photos from my own album on the web reaches the index as
    /// AlbumToAssetDeleteV1. The index treats every album, partner and user removal as an access
    /// change, though the photo stays in my library, and SessionStore.didSync then empties the
    /// whole thumbnail store, so the offline library is downloaded again.
    func testRemovingAPhotoFromAnAlbumIsNotAnAccessChange() async throws {
        let (sync, index, server) = try makeSyncedIndex()
        _ = try await pass([
            asset("trip-photo"), asset("other"),
            event("AlbumV2", #"{"id":"trip","ownerId":"alice","name":"Trip","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":null,"isActivityEnabled":true,"order":"desc"}"#, ack: "AlbumV2|trip"),
            event("AlbumToAssetV1", #"{"albumId":"trip","assetId":"trip-photo"}"#, ack: "AlbumToAssetV1|trip-photo"),
            complete(),
        ], through: sync, server: server)
        _ = try await index.takeAccessInvalidation()
        let summary = try await pass([event("AlbumToAssetDeleteV1", #"{"albumId":"trip","assetId":"trip-photo"}"#, ack: "AlbumToAssetDeleteV1|trip-photo"),
                                      complete()], through: sync, server: server)
        let invalidated = try await index.takeAccessInvalidation()
        let kept = try await index.asset(id: "trip-photo")
        XCTAssertNotNil(kept, "The photo is still in my library.")

        XCTExpectFailure("MEDIA-2: removing a photo from an album sets accessChanged. Q3 removes this wrapper.", strict: true) {
            XCTAssertFalse(summary.accessChanged, "Removing my photo from my album changes nothing I may see.")
            XCTAssertFalse(invalidated, "Nor is it kept as an access change for a later sync.")
        }
    }

    // MARK: - Queries

    /// SEARCH-1. Searches never say whether trashed photos count, and the server's search includes
    /// them unless asked not to: a library search shows trashed photos, and a search inside Trash
    /// searches everything. Search options after Reset also drop the visibility, which brings
    /// Locked Folder photos into results while the folder is unlocked.
    func testSearchesStateTrashAndVisibility() async throws {
        let server = makeStubServer()
        server.route("POST", "search/smart", .json(Self.emptySearchPage))
        server.route("POST", "search/metadata", .json(Self.emptySearchPage))
        server.route("GET", "timeline/buckets", .json("[]"))
        let api = try stubClient(server, token: "ledger-session", userID: "alice")
        removeCachesAfterwards(api.cacheScope)
        let store = LibraryStore(api: api)
        defer { store.stop() }

        store.search("beach")
        let library = try await searchFilter(server, "search/smart", request: 1, store: store)
        store.setTimeline(TimelineFilter(visibility: nil, isTrashed: true), title: "Trash")
        store.search("beach")
        let trash = try await searchFilter(server, "search/smart", request: 2, store: store)
        // Search options after Reset, which clears every filter.
        store.applySearchOptions(mode: .filename, filter: SearchFilter())
        let options = try await searchFilter(server, "search/metadata", request: 1, store: store)

        XCTExpectFailure("SEARCH-1: searches omit trash and visibility. Q4 removes this wrapper.", strict: true) {
            XCTAssertEqual(library["trashedAt"], .object(["eq": .null]), "A library search leaves trashed photos out.")
            XCTAssertEqual(trash["trashedAt"], .object(["ne": .null]), "A search inside Trash keeps to the trash.")
            XCTAssertNotNil(options["visibility"], "Search options always say which photos they search.")
            XCTAssertEqual(options["trashedAt"], .object(["eq": .null]), "Search options leave trashed photos out.")
        }
    }

    /// The privacy half of SEARCH-1, fixed in S0 (build 3040055). While the Locked Folder is
    /// unlocked the server includes it in any search that does not say otherwise, so library,
    /// person, album, place, Trash and similar-photo searches ask for the timeline and archive only.
    func testLibraryPersonAlbumPlaceTrashAndSimilarSearchesAskForTimelineAndArchive() async throws {
        let server = makeStubServer()
        server.route("POST", "search/smart", .json(Self.emptySearchPage))
        server.route("POST", "search/metadata", .json(Self.emptySearchPage))
        server.route("GET", "timeline/buckets", .json("[]"))
        let api = try stubClient(server, token: "ledger-session", userID: "alice")
        removeCachesAfterwards(api.cacheScope)
        let store = LibraryStore(api: api)
        defer { store.stop() }

        store.search("beach")
        let library = try await searchFilter(server, "search/smart", request: 1, store: store)
        store.setPerson(Self.maya); store.search("beach")
        let person = try await searchFilter(server, "search/smart", request: 2, store: store)
        store.setAlbum(Album(id: "coast", albumName: "Coast", assetCount: 1, shared: false, albumUsers: nil,
                             startDate: nil, endDate: nil, updatedAt: nil, order: "desc"))
        store.search("beach")
        let album = try await searchFilter(server, "search/smart", request: 3, store: store)
        store.setTimeline(TimelineFilter(visibility: nil, isTrashed: true), title: "Trash"); store.search("beach")
        let trash = try await searchFilter(server, "search/smart", request: 4, store: store)
        store.findSimilar(to: Asset(id: "reference"))
        let similar = try await searchFilter(server, "search/smart", request: 5, store: store)
        // Without the offline library, a place's photos are found by search.
        store.setPlace(id: "lisbon", assetIDs: ["lisbon-1", "lisbon-2"], title: "Lisbon")
        let place = try await searchFilter(server, "search/metadata", request: 1, store: store)

        let timelineAndArchive = EntityJSON.object(["in": .array([.string("timeline"), .string("archive")])])
        for (name, filter) in [("library", library), ("person", person), ("album", album), ("trash", trash),
                               ("similar", similar), ("place", place)] {
            XCTAssertEqual(filter["visibility"], timelineAndArchive, "A \(name) search asks for the timeline and archive only.")
        }
    }

    /// QUERY-1. The library leaves out the partners whose photos are shown in the timeline:
    /// TimelineFilter.withPartners is false by default and nothing sets it, so the "Show in your
    /// timeline" switch has no effect on the native library, offline or from the server.
    func testLibraryIncludesPartnersShownInTimeline() async throws {
        let server = makeStubServer()
        let api = try stubClient(server, token: "ledger-session", userID: "alice")
        removeCachesAfterwards(api.cacheScope)
        let entities = try EntityStore(scope: api.cacheScope, userID: "alice", directory: temporaryDirectory())
        let epoch = await entities.epoch()
        _ = try await entities.apply([
            event("PartnerV1", #"{"sharedById":"bob","sharedWithId":"alice","inTimeline":true}"#, ack: "PartnerV1|bob"),
            event("PartnerV1", #"{"sharedById":"carol","sharedWithId":"alice","inTimeline":false}"#, ack: "PartnerV1|carol"),
            asset("mine"), asset("bob-photo", owner: "bob", type: "PartnerAssetV2"), asset("carol-photo", owner: "carol", type: "PartnerAssetV2"),
            complete(),
        ], epoch: epoch)
        let offline = LibraryStore(api: NativeLibraryAPI(client: api, entities: entities, sync: NativeSync(api: api, store: entities)))
        defer { offline.stop() }
        await offline.reload()
        try await until("The offline library's month did not load.") { offline.loaded["2026-02-01"] != nil }
        let shown = Set(offline.loaded.values.flatMap { $0 }.map(\.id))
        XCTAssertTrue(shown.contains("mine"))

        // Before the offline library is complete, the same feed comes from the server.
        let remote = makeStubServer()
        remote.route("GET", "timeline/buckets", .json("[]"))
        let remoteAPI = try stubClient(remote, token: "ledger-session", userID: "alice")
        removeCachesAfterwards(remoteAPI.cacheScope)
        let online = LibraryStore(api: remoteAPI)
        defer { online.stop() }
        await online.reload()
        let query = try XCTUnwrap(remote.requests("GET", "timeline/buckets").first?.query)

        XCTExpectFailure("QUERY-1: partners shown in the timeline are missing from the library. Q5 removes this wrapper.", strict: true) {
            XCTAssertTrue(shown.contains("bob-photo"), "A partner shown in the timeline is part of the offline library.")
            XCTAssertTrue(query.contains(URLQueryItem(name: "withPartners", value: "true")), "The server is asked for those partners too.")
        }
        XCTAssertFalse(shown.contains("carol-photo"), "A partner kept out of the timeline stays out.")
    }

    // MARK: - Not reproduced here
    //
    // SYNC-1 (lost tail pass, Q1). A trigger is lost only if it reaches the NativeSync actor
    // after run() has checked resyncRequested for the last time and before the first caller clears
    // the shared task. That window has no await in it, so no stub server or gate can hold a pass
    // inside it, and a test would be a timing race. Q1's requested and completed sequence numbers
    // make it testable with a gated transport.
    //
    // BACKUP-1 (a 5xx blocks automatic backup, B9) and BACKUP-2 (an album failure keeps a photo
    // queued, B9). BackupCoordinator uploads only with the signed-in account's Keychain credential,
    // a real PHAsset (DevicePhotos.prepare) and the background URLSession, which URLProtocol stubs
    // cannot serve. In this test host that means the simulator's own saved session and Photos
    // library. From B2 on, the transfer engine runs behind fakes, where B9 pins both.
    //
    // CLEAN-1 (one 404 aborts the cleanup check, P4). verifiedLocalDeletionCandidates needs the
    // same Keychain credential, and DevicePhotos.canRemove must find a real PHAsset before the GET
    // that fails, so it cannot run without a device's photos. P4's CleanupService takes its PhotoKit
    // adapter and its remote verifier as seams.

    // MARK: - Support

    private static let maya = Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: nil, isFavorite: nil)
    private static let emptySearchPage = #"{"assets":{"items":[],"count":0,"nextCursor":null,"nextPage":null},"verification":null}"#

    /// Polls until the condition holds or the time runs out, and says whether it held.
    private func eventually(within timeout: Duration = .seconds(2), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if await condition() { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A step a test needs before it can show its bug. Missing it is a real failure, never an expected one.
    private func until(_ message: String, within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        if await eventually(within: timeout, condition) { return }
        XCTFail(message)
    }

    private func removeCachesAfterwards(_ scope: String) {
        addTeardownBlock {
            await TimelineCache.shared.removeAll(scope: scope)
            await TimelinePlacesCache.shared.removeAll(scope: scope)
        }
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnownBugLedger-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// An APIClient whose requests reach only the stub server.
    private func stubClient(_ server: StubServer, token: String? = nil, userID: String? = nil) throws -> APIClient {
        let session = URLSession(configuration: server.configuration())
        addTeardownBlock { session.invalidateAndCancel() }
        return try APIClient(baseURL: server.baseURL, accessToken: token, userID: userID, session: session,
                             networkConfiguration: NetworkConfiguration())
    }

    /// The filter of a search request, once the store has sent that many to the path and settled.
    private func searchFilter(_ server: StubServer, _ path: String, request number: Int, store: LibraryStore) async throws -> [String: EntityJSON] {
        try await until("Search request \(number) to \(path) was never sent.") {
            server.requests("POST", path).count >= number && !store.isSearching
        }
        let requests = server.requests("POST", path)
        guard requests.count >= number, let body = requests[number - 1].body else { return [:] }
        return try JSONDecoder().decode([String: EntityJSON].self, from: body)["filter"]?.object ?? [:]
    }

    /// A NativeSync over a stub server and a fresh offline index.
    private func makeSyncedIndex() throws -> (sync: NativeSync, index: EntityStore, server: StubServer) {
        let server = makeStubServer()
        server.route("POST", "sync/ack", .empty(204))
        let api = try stubClient(server, token: "ledger-session", userID: "alice")
        let index = try EntityStore(scope: api.cacheScope, userID: "alice", directory: temporaryDirectory())
        return (NativeSync(api: api, store: index), index, server)
    }

    /// One sync pass whose stream holds the given events.
    private func pass(_ events: [EntitySyncEvent], through sync: NativeSync, server: StubServer) async throws -> SyncChangeSummary {
        var body = Data()
        for event in events { body += try JSONEncoder().encode(event) + Data("\n".utf8) }
        server.route("POST", "sync/stream", StubServer.Response(status: 200, headers: ["Content-Type": "application/jsonlines+json"], body: body))
        return try await sync.synchronize()
    }

    private func event(_ type: String, _ json: String, ack: String) throws -> EntitySyncEvent {
        EntitySyncEvent(type: type, data: try JSONDecoder().decode([String: EntityJSON].self, from: Data(json.utf8)), ack: ack)
    }

    private func asset(_ id: String, owner: String = "alice", type: String = "AssetV2") throws -> EntitySyncEvent {
        try event(type, """
        {"id":"\(id)","ownerId":"\(owner)","type":"IMAGE","originalFileName":"\(id).jpg","checksum":"AQIDBA==","fileCreatedAt":"2026-01-31T23:30:00Z","localDateTime":"2026-02-01T05:00:00Z","createdAt":"2026-03-01T00:00:00Z","visibility":"timeline","isFavorite":false,"deletedAt":null,"stackId":null,"isEdited":false,"isDeveloped":false,"mediaRevision":"r1"}
        """, ack: "\(type)|\(id)")
    }

    private func complete() throws -> EntitySyncEvent { try event("SyncCompleteV1", "{}", ack: "SyncCompleteV1|done") }
}

/// A library of months for the feed tests. Months load after a delay, the summary can be held
/// while a test arranges a race, and month places can be held until the test lets them finish.
private actor LedgerLibrary: LibraryAPI {
    nonisolated let cacheScope = "test-ledger-" + UUID().uuidString
    private let months: [String: [Asset]]
    private let counts: [String: Int]
    private let delay: Duration
    private let slow: [String: Duration]
    private let places: [MonthPlaceCount]
    private var summaryGate: StubServer.Gate?
    private let placesGate: StubServer.Gate?
    private(set) var summaryCalls = 0
    private(set) var placesCalls = 0
    private(set) var placesAnswered = 0

    /// `counts` overrides a month's size in the summary; `slow` overrides the delay of some months.
    init(months: [String: [Asset]], counts: [String: Int] = [:], delay: Duration = .zero, slow: [String: Duration] = [:],
         holdPlaces: Bool = false, places: [MonthPlaceCount] = []) {
        self.months = months; self.counts = counts; self.delay = delay; self.slow = slow; self.places = places
        placesGate = holdPlaces ? StubServer.Gate() : nil
    }

    /// Summaries asked for from now on wait until releaseSummaries.
    func holdSummaries() { summaryGate = StubServer.Gate() }
    func releaseSummaries() { summaryGate?.open() }
    func releasePlaces() { placesGate?.open() }

    func timeBuckets(filter: TimelineFilter) async throws -> [TimeBucket] {
        summaryCalls += 1
        if let summaryGate { await summaryGate.wait() }
        return months.keys.sorted(by: >).map { TimeBucket(timeBucket: $0, count: counts[$0] ?? months[$0]?.count ?? 0) }
    }
    func timeBucket(_ bucket: String, filter: TimelineFilter) async throws -> [Asset] {
        let wait = slow[bucket] ?? delay
        if wait > .zero { try await Task.sleep(for: wait) }
        return months[bucket] ?? []
    }
    func search(_ query: SearchQuery) async throws -> SearchResponse { throw APIError.http(500) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { throw APIError.http(500) }
    func monthPlaces(filter: TimelineFilter) async throws -> [MonthPlaceCount] {
        placesCalls += 1
        if let placesGate { await placesGate.wait() }
        placesAnswered += 1
        return places
    }
}

/// Holds the Wi-Fi name lookup, and with it the address resolution, until the test opens the gate.
private struct HeldWiFiName: WiFiNameProviding {
    let gate = StubServer.Gate()
    func currentName() async -> String? {
        await gate.wait()
        return nil
    }
}

/// One WebSocket connection on the loopback interface, playing an Engine.IO server. It opens the
/// session, sends its packets, then pings. The client answers a ping only after it has handled
/// every packet sent before it, so the pong shows they all reached the client's event stream.
private final class SocketBurstServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.ilyich.tests.socket-burst")
    private let packets: [String]
    private let state = Mutex<(start: CheckedContinuation<UInt16, any Error>?, connection: NWConnection?, ponged: Bool)>((nil, nil, false))

    init(packets: [String]) throws {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.packets = packets
    }

    /// Whether the client has answered the ping that follows the packets.
    var ponged: Bool { state.withLock { $0.ponged } }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.start = continuation }
            listener.stateUpdateHandler = { [weak self] update in self?.listenerChanged(update) }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        state.withLock { $0.connection }?.cancel()
        listener.cancel()
    }

    private func listenerChanged(_ update: NWListener.State) {
        let result: Result<UInt16, any Error>
        switch update {
        case .ready: result = .success(listener.port?.rawValue ?? 0)
        case .failed(let error): result = .failure(error)
        default: return
        }
        let start = state.withLock { state -> CheckedContinuation<UInt16, any Error>? in
            defer { state.start = nil }
            return state.start
        }
        start?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        state.withLock { $0.connection = connection }
        connection.stateUpdateHandler = { [weak self, weak connection] update in
            guard case .ready = update, let self, let connection else { return }
            let open = #"0{"sid":"ledger","upgrades":[],"pingInterval":25000,"pingTimeout":20000}"#
            for packet in [open] + self.packets + ["2"] { self.send(packet, on: connection) }
            self.receive(on: connection)
        }
        connection.start(queue: queue)
    }

    private func send(_ text: String, on connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "packet", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, String(decoding: data, as: UTF8.self) == "3" { self.state.withLock { $0.ponged = true } }
            self.receive(on: connection)
        }
    }
}

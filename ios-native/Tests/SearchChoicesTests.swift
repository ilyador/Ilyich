import Foundation
import XCTest
@testable import Ilyich

/// F7: the AI check, the search modes and More's filters, as requests and as the store keeps them.
@MainActor final class SearchChoicesTests: XCTestCase {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: APIJSON.encoder().encode(value)) as? [String: Any])
    }

    /// Photo content is smart search, with verify: false unless the AI check is on; on leaves
    /// verification to the server, as before. The other modes are metadata searches on their field.
    func testEachModeBuildsTheRightRequest() throws {
        let library = LibraryStore.librarySearch
        let plain = try ServerSearchRequest(library.refined(text: "red hat", mode: .context), userID: "alice", checksContent: false)
        XCTAssertEqual(plain.endpoint, .smart)
        var body = try json(plain.smartBody(cursor: nil))
        XCTAssertEqual(body["query"] as? String, "red hat")
        XCTAssertEqual(body["verify"] as? Bool, false, "With the AI check off, the server is told not to verify.")

        let checked = try ServerSearchRequest(library.refined(text: "red hat", mode: .context), userID: "alice", checksContent: true)
        body = try json(checked.smartBody(cursor: nil))
        XCTAssertEqual(body["query"] as? String, "red hat")
        XCTAssertNil(body["verify"], "With it on, the server verifies as it always did when configured.")

        let similar = try ServerSearchRequest(library.similar(to: "reference"), userID: "alice", checksContent: false)
        XCTAssertNil(try json(similar.smartBody(cursor: nil))["verify"], "Similar photos have no text to check.")

        for (mode, key) in [(SearchMode.filename, "originalFileName"), (.description, "description"), (.ocr, "ocr")] {
            let request = try ServerSearchRequest(library.refined(text: "beach", mode: mode), userID: "alice", checksContent: false)
            XCTAssertEqual(request.endpoint, .metadata, "\(mode) is a metadata search.")
            let filter = try XCTUnwrap(try json(request.metadataBody(cursor: nil, size: 100))["filter"] as? [String: Any])
            XCTAssertNotNil(filter[key], "\(mode) searches \(key).")
        }
        let ocr = try ServerSearchRequest(library.refined(text: "binance", mode: .ocr), userID: "alice")
        XCTAssertEqual(ocr.filter.ocr, OCRFilter(matches: "binance"))
        XCTAssertEqual(try ServerSearchRequest(library.refined(text: "beach", mode: .filename), userID: nil).filter.originalFileName, .containing("beach"))
        XCTAssertEqual(try ServerSearchRequest(library.refined(text: "beach", mode: .description), userID: nil).filter.description, .containing("beach"))
    }

    /// Every filter More sets reaches the request in every mode, beside the mode's own field.
    func testFiltersCombineWithEachMode() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000), end = Date(timeIntervalSince1970: 1_700_864_000)
        let chosen = SearchFilter(type: StringFilter(eq: "VIDEO"), personIds: IDsFilter(all: ["maya"]), city: StringFilter(eq: "Lisbon"),
                                  takenAt: DateFilter(gte: start, lt: end), visibility: StringFilter(eq: "archive"),
                                  isFavorite: BoolFilter(eq: true), make: StringFilter(eq: "Apple"), hasAlbums: BoolFilter(eq: false))
        for mode in SearchMode.allCases {
            let query = LibraryStore.librarySearch.narrowed(by: chosen).refined(text: "beach", mode: mode)
            let request = try ServerSearchRequest(query, userID: "alice")
            let filter = request.filter
            XCTAssertEqual(filter.type, StringFilter(eq: "VIDEO"), "\(mode)")
            XCTAssertEqual(filter.personIds, IDsFilter(all: ["maya"]), "\(mode)")
            XCTAssertEqual(filter.city, StringFilter(eq: "Lisbon"), "\(mode)")
            XCTAssertEqual(filter.takenAt, DateFilter(gte: start, lt: end), "\(mode)")
            XCTAssertEqual(filter.visibility, StringFilter(in: ["archive"]), "\(mode): archived only keeps to the archive.")
            XCTAssertEqual(filter.isFavorite, BoolFilter(eq: true), "\(mode)")
            XCTAssertEqual(filter.make, StringFilter(eq: "Apple"), "\(mode)")
            XCTAssertEqual(filter.hasAlbums, BoolFilter(eq: false), "\(mode)")
            XCTAssertEqual(filter.trashedAt, .unset, "\(mode)")
            switch mode {
            case .context: XCTAssertEqual(request.endpoint, .smart)
            case .filename: XCTAssertEqual(filter.originalFileName, .containing("beach"))
            case .description: XCTAssertEqual(filter.description, .containing("beach"))
            case .ocr: XCTAssertEqual(filter.ocr, OCRFilter(matches: "beach"))
            }
        }
        // Inside a person's feed, the people chosen join the person.
        var person = LibraryQuery.person("ali"); person.visibility = [.timeline, .archive]
        let both = try ServerSearchRequest(person.narrowed(by: SearchFilter(personIds: IDsFilter(all: ["maya"]))), userID: nil)
        XCTAssertEqual(both.filter.personIds, IDsFilter(all: ["ali", "maya"]))
    }

    /// The mode stays through clearing, a new search, and a change of feed.
    func testTheModeSurvivesClearingAndANewSearch() async throws {
        let api = SearchRecorder(userID: "alice", items: [Asset(id: "shown")])
        let store = LibraryStore(source: api, placesDelay: .zero)
        defer { store.stop() }
        removeCachesAfterwards(api.cacheScope)

        store.applySearchOptions(mode: .description, filter: SearchFilter())
        XCTAssertFalse(store.isBrowsingChoices, "A mode alone opens nothing.")
        store.search("beach")
        try await until("The first search was not sent.") { await api.metadata.count == 1 && !store.isSearching }
        store.search("")
        store.clearFilters()
        XCTAssertEqual(store.searchMode, .description)
        store.search("dog")
        try await until("The second search was not sent.") { await api.metadata.count == 2 && !store.isSearching }
        store.setFeed(.favorites, title: "Favorites")
        store.search("cat")
        try await until("The third search was not sent.") { await api.metadata.count == 3 && !store.isSearching }
        let filters = await api.metadata.map(\.filter.description)
        XCTAssertEqual(filters, [.containing("beach"), .containing("dog"), .containing("cat")])
        let smart = await api.smart.count
        XCTAssertEqual(smart, 0)
    }

    /// The switch starts off: a Photo content search sends verify: false. Turning it on runs the
    /// search again with the server's check.
    func testTheSwitchTogglesVerificationInTheRequest() async throws {
        let api = SearchRecorder(userID: "alice", items: [Asset(id: "shown")])
        let store = LibraryStore(source: api, placesDelay: .zero)
        defer { store.stop() }
        removeCachesAfterwards(api.cacheScope)

        XCTAssertFalse(store.searchChoices.checksContent)
        store.search("red hat")
        try await until("The search was not sent.") { await api.smart.count == 1 && !store.isSearching }
        XCTAssertFalse(store.checksPhotoContent)
        store.setChecksContent(true)
        XCTAssertTrue(store.checksPhotoContent)
        try await until("The search did not run again.") { await api.smart.count == 2 && !store.isSearching }
        store.setChecksContent(false)
        try await until("The search did not run again.") { await api.smart.count == 3 && !store.isSearching }
        let verify = await api.smart.map(\.verify)
        XCTAssertEqual(verify, [false, nil, false])
        XCTAssertEqual(store.results.map(\.id), ["shown"])
    }

    /// Filters chosen with no text show the feed narrowed as one list, with a chip each; removing
    /// the chips one by one narrows less, and the last one brings the library back.
    func testChipsShowAndClearOneByOne() async throws {
        let api = SearchRecorder(userID: "alice", items: [Asset(id: "shown")])
        let store = LibraryStore(source: api, placesDelay: .zero)
        defer { store.stop() }
        removeCachesAfterwards(api.cacheScope)

        store.applySearchOptions(mode: .filename, filter: SearchFilter(type: StringFilter(eq: "VIDEO"), isFavorite: BoolFilter(eq: true)))
        XCTAssertEqual(store.searchChoices.chips().map(\.kind), [.mode, .type, .favorites])
        XCTAssertEqual(store.searchChoices.chips().map(\.title), ["Filename", "Videos", "Favorites"])
        XCTAssertTrue(store.isBrowsingChoices)
        XCTAssertTrue(store.choicesApply)
        try await until("The filtered view was not loaded.") { await api.metadata.count == 1 && !store.isSearching }
        XCTAssertEqual(store.results.map(\.id), ["shown"])
        var last = await api.metadata.last
        XCTAssertEqual(last?.filter.isFavorite, BoolFilter(eq: true))
        XCTAssertEqual(last?.filter.type, StringFilter(eq: "VIDEO"))

        store.removeChoice(.favorites)
        try await until("The view was not narrowed again.") { await api.metadata.count == 2 && !store.isSearching }
        last = await api.metadata.last
        XCTAssertNil(last?.filter.isFavorite)
        XCTAssertEqual(last?.filter.type, StringFilter(eq: "VIDEO"))
        XCTAssertTrue(store.isBrowsingChoices)

        store.removeChoice(.type)
        XCTAssertFalse(store.isBrowsingChoices, "The last filter gone, the library comes back.")
        XCTAssertNil(store.filterTitle)
        XCTAssertFalse(store.choicesApply)
        XCTAssertEqual(store.searchChoices.chips().map(\.kind), [.mode], "The mode stays until its own chip goes.")
        store.removeChoice(.mode)
        XCTAssertEqual(store.searchMode, .context)
        XCTAssertTrue(store.searchChoices.chips().isEmpty)

        // Filters chosen over a feed narrow it, and their removal returns to it.
        store.setFeed(.favorites, title: "Favorites")
        store.applySearchOptions(mode: .context, filter: SearchFilter(personIds: IDsFilter(all: ["maya"])))
        XCTAssertEqual(store.searchPlaceTitle, "Favorites")
        try await until("The feed was not narrowed.") { await api.metadata.count == 3 && !store.isSearching }
        last = await api.metadata.last
        XCTAssertEqual(last?.filter.personIds, IDsFilter(all: ["maya"]))
        XCTAssertEqual(last?.filter.isFavorite, BoolFilter(eq: true))
        store.removeChoice(.people)
        XCTAssertEqual(store.filterTitle, "Favorites")
        XCTAssertFalse(store.isBrowsingChoices)
    }

    /// The choices persist per server and account, and the mode is stored by a fixed name.
    func testChoicesPersistUntilChanged() throws {
        let suite = "search-choices-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = SearchChoicesStorage(scope: "server|alice", defaults: defaults)
        XCTAssertEqual(storage.load(), SearchChoices(), "Nothing chosen yet: Photo content, no AI check, no filters.")

        let api = SearchRecorder(userID: "alice", items: [])
        removeCachesAfterwards(api.cacheScope)
        let store = LibraryStore(source: api, placesDelay: .zero, choices: storage)
        store.setChecksContent(true)
        store.applySearchOptions(mode: .ocr, filter: SearchFilter(personIds: IDsFilter(all: ["maya"]), isFavorite: BoolFilter(eq: true),
                                                                 trashedAt: .set))
        store.stop()

        let reopened = LibraryStore(source: api, placesDelay: .zero, choices: storage)
        defer { reopened.stop() }
        XCTAssertTrue(reopened.searchChoices.checksContent)
        XCTAssertEqual(reopened.searchMode, .ocr)
        XCTAssertEqual(reopened.searchChoices.filter, SearchFilter(personIds: IDsFilter(all: ["maya"]), isFavorite: BoolFilter(eq: true)),
                       "Only More's own filters are kept.")
        XCTAssertFalse(reopened.isBrowsingChoices, "A launch opens the library, not the filtered view.")
        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "searchChoices.server|alice"))) as? [String: Any])
        XCTAssertEqual(saved["mode"] as? String, "ocr")
        XCTAssertEqual(SearchChoicesStorage(scope: "server|bob", defaults: defaults).load(), SearchChoices(), "Another account has its own.")
    }

    private func until(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }

    private func removeCachesAfterwards(_ scope: String) {
        addTeardownBlock {
            await TimelineCache.shared.removeAll(scope: scope)
            await TimelinePlacesCache.shared.removeAll(scope: scope)
        }
    }
}

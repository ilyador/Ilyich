import Foundation

/// People a page at a time, by name, for the People screen and the search filter's picker
/// (REBUILD_ROADMAP.md F5). Pages are numbered from one; a new query starts over, and a page a
/// newer query overtook is dropped. A query's first page replaces the people shown, which the
/// People screen keeps until then. When the first page gets no answer at all and the offline
/// library is complete, the index answers the whole query as one page, and there is no more; a
/// later page's failure is shown and the page asked for again on retry. Loads run in the caller's
/// task, so a screen's `.task(id:)` cancels them as it would its own.
@MainActor @Observable final class PeoplePager {
    private(set) var people: [Person] = []
    private(set) var hasMore = true
    private(set) var isLoading = false
    /// Why the last page failed; nil once a page loads or a new query starts.
    private(set) var failure: String?
    private(set) var query = ""
    /// The page the next load asks for, from one; a failed page is asked for again.
    private(set) var nextPage = 1
    @ObservationIgnored private let source: any PeopleSource
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var generation = UUID()

    init(source: any PeopleSource, pageSize: Int = 100) {
        self.source = source; self.pageSize = max(1, pageSize)
    }

    /// Starts over with `query` and loads its first page, after `debounce` while typing. The people
    /// shown go at once, as the search filter's picker has them go. `keepingPeople` keeps them
    /// instead, as the People screen does while it filters them itself: nothing changes until the
    /// debounce has passed, and the people and whether there are more stay until the first page
    /// replaces them, or stay when it fails.
    func start(query: String, debounce: Duration = .zero, keepingPeople: Bool = false) async {
        let token = UUID()
        if !keepingPeople { begin(token, query: query); people = []; hasMore = true }
        if debounce > .zero {
            do { try await Task.sleep(for: debounce) } catch { if generation == token { isLoading = false }; return }
        }
        if keepingPeople { begin(token, query: query) }
        await load(token)
    }

    /// Asks for the next page, or again for the one that failed.
    func loadMore() async {
        guard !isLoading else { return }
        await load(generation)
    }

    /// Drops whatever is on its way, as when the screen goes.
    func cancel() { generation = UUID(); isLoading = false }

    func dismissFailure() { failure = nil }

    /// A person edited elsewhere shows as edited here.
    func replace(_ person: Person) {
        if let index = people.firstIndex(where: { $0.id == person.id }) { people[index] = person }
    }

    /// `query` becomes the query in force: its pages are asked for from the first, and a page an
    /// older query asked for is dropped when it lands.
    private func begin(_ token: UUID, query: String) {
        generation = token
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        nextPage = 1; failure = nil; isLoading = true
    }

    private func load(_ token: UUID) async {
        guard token == generation else { return }
        isLoading = true; failure = nil
        defer { if token == generation { isLoading = false } }
        let page = nextPage, name = query.isEmpty ? nil : query
        do {
            let response: PeopleResponse
            do { response = try await source.peoplePage(page, size: pageSize, name: name) }
            catch {
                guard page == 1, let offline = try await source.offlinePeople(after: error) else { throw error }
                try Task.checkCancellation()
                guard token == generation else { return }
                // The offline library answers the whole query as one page.
                people = offline.filter { person in
                    person.isHidden != true && (name.map { person.name.localizedStandardContains($0) } ?? true)
                }
                hasMore = false; nextPage = page + 1
                return
            }
            try Task.checkCancellation()
            guard token == generation else { return }
            // The first page replaces the people shown, which the screen may have kept till now.
            if page == 1 { people = [] }
            let known = Set(people.map(\.id))
            people += response.people.filter { !known.contains($0.id) }
            hasMore = response.hasNextPage ?? (response.people.count == pageSize)
            nextPage = page + 1
        } catch is CancellationError {
        } catch { if token == generation { failure = error.localizedDescription } }
    }
}

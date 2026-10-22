import Foundation

/// People a page at a time, by name, for the People screen and the search filter's picker
/// (REBUILD_ROADMAP.md F5). Pages are numbered from one; a new query starts over, and a page a
/// newer query overtook is dropped. When the first page gets no answer at all and the offline
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

    /// Starts over with `query` and loads its first page, after `debounce` while typing.
    func start(query: String, debounce: Duration = .zero) async {
        let token = UUID()
        generation = token
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        people = []; nextPage = 1; hasMore = true; failure = nil; isLoading = true
        if debounce > .zero {
            do { try await Task.sleep(for: debounce) } catch { if generation == token { isLoading = false }; return }
        }
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
            let known = Set(people.map(\.id))
            people += response.people.filter { !known.contains($0.id) }
            hasMore = response.hasNextPage ?? (response.people.count == pageSize)
            nextPage = page + 1
        } catch is CancellationError {
        } catch { if token == generation { failure = error.localizedDescription } }
    }
}

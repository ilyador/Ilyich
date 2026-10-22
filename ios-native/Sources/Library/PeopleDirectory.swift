import Foundation
import Synchronization

/// Where people come from: the server's pages, numbered from one, and the offline library when the
/// server gives no answer at all.
protocol PeopleSource: Sendable {
    /// One page from the server. Nothing stands in for a failure.
    func peoplePage(_ page: Int, size: Int, name: String?) async throws -> PeopleResponse
    /// Every person the offline library holds, hidden ones included, when it may answer for
    /// `error`: a definite transport failure, and a complete first sync. Nil otherwise.
    func offlinePeople(after error: any Error) async throws -> [Person]?
}

extension APIClient: PeopleSource {}

/// Every visible person, for the People shelf and the links the shelves resolve (REBUILD_ROADMAP.md
/// F5). One flight: callers that ask while a run is on join it, so the shelves opening, a sync
/// change and the app coming forward together cost one run. One source per run: the server's
/// pages, or, when the first page gets no answer at all and the offline library is complete, the
/// index; a run never mixes them, so nobody is missed or counted twice when a page fails midway.
/// A page cap bounds a server that keeps saying there is more.
final class PeopleDirectory: Sendable {
    private let source: any PeopleSource
    private let pageSize: Int
    let pageCap: Int
    private let flight = Mutex<Task<[Person], any Error>?>(nil)

    init(source: any PeopleSource, pageSize: Int = 100, pageCap: Int = 50) {
        self.source = source; self.pageSize = max(1, pageSize); self.pageCap = max(1, pageCap)
    }

    /// Every visible person, in the server's order.
    func allVisible() async throws -> [Person] {
        let task = flight.withLock { slot -> Task<[Person], any Error> in
            if let slot { return slot }
            let task = Task { try await self.run() }
            slot = task
            return task
        }
        defer { flight.withLock { if $0 == task { $0 = nil } } }
        return try await task.value
    }

    private func run() async throws -> [Person] {
        var all: [Person] = [], known = Set<String>(), page = 1
        while true {
            try Task.checkCancellation()
            let response: PeopleResponse
            do { response = try await source.peoplePage(page, size: pageSize, name: nil) }
            catch {
                // Only the first page may turn to the offline library, for the whole run; a later
                // page's failure fails the run rather than finishing it from another source.
                guard page == 1, let offline = try await source.offlinePeople(after: error) else { throw error }
                return offline.filter { $0.isHidden != true }
            }
            try Task.checkCancellation()
            let fresh = response.people.filter { known.insert($0.id).inserted }
            guard !fresh.isEmpty else { break }
            all.append(contentsOf: fresh)
            let visibleTotal = max(0, response.total - response.hidden)
            if response.hasNextPage == false || all.count >= visibleTotal { break }
            if response.hasNextPage == nil && response.people.count < pageSize { break }
            guard page < pageCap else { break }
            page += 1
        }
        return all
    }
}

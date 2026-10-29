import Foundation
import Observation

/// The Trash's own screen (TrashView): the server's trashed photos a month at a time, with Load
/// more, the selection, and restoring or deleting for good through the account's mutations.
///
/// It follows what changes elsewhere while it is up (plan line 78, G1). A mutation's result applies
/// in place, whichever screen made it, and one that puts photos in Trash has the months shown read
/// again. A sync's change takes out at once the photos the offline library let go (deleted for
/// good, locked, out of reach); a change that names any photo, which is how a photo restored or put
/// in Trash elsewhere arrives, has the months shown read again quietly, so the photo leaves or
/// joins and the selection keeps what is still there. A quiet read that something shown here
/// overtook, a change applied or a month loaded, is read again rather than shown, so it never
/// brings back a photo restored or deleted meanwhile.
@MainActor @Observable final class TrashModel {
    private(set) var assets: [Asset] = []
    /// The Trash's months, newest first, as last read.
    private(set) var buckets: [TimeBucket] = []
    /// How many of `buckets` are shown; Load more reads the next.
    private(set) var nextBucket = 0
    private(set) var loading = false
    private(set) var initialized = false
    /// Whether the server keeps a Trash; nil until it says.
    private(set) var trashEnabled: Bool?
    var selection = Set<String>()
    var failure: FeatureFailure?
    var resultMessage: String?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private var mutations: LibraryMutationService?
    @ObservationIgnored private let follower = LibraryFollower()
    /// The quiet read under way; another is owed when a change came in while it ran.
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var refreshOwed = false
    /// Moves whenever what is shown changes here, so a read begun before is not shown.
    @ObservationIgnored private var version = 0

    init(api: APIClient) { self.api = api }

    isolated deinit { refreshing?.cancel() }

    /// The account's mutations, and its bus, which carries their results and the sync's changes.
    /// Following the same bus again changes nothing.
    func follow(mutations: LibraryMutationService?, bus: LibraryBus?) {
        self.mutations = mutations
        follower.follow(bus ?? mutations?.bus) { [weak self] event in self?.handle(event) }
    }

    /// The Trash with every stacked photo on its own, from the server timeline.
    private var timeline: ServerTimelineRequest {
        get throws { var query = LibraryQuery.trash; query.stacks = .all; return try ServerTimelineRequest(query, userID: api.userID) }
    }

    // MARK: Reading

    /// Reads the Trash from its newest month, as on opening and on a pull to refresh.
    func reload() async {
        guard !loading else { return }
        loading = true
        do {
            trashEnabled = try await api.serverFeatures().trash
            guard trashEnabled == true else {
                assets = []; buckets = []; selection = []; initialized = true; version += 1
                return endLoading()
            }
            buckets = try await api.timeBuckets(try timeline); assets = []; nextBucket = 0; selection = []; initialized = true
            version += 1
        } catch is CancellationError { } catch { failure = .init(error) }
        endLoading()
        if !buckets.isEmpty { await loadNext() }
    }

    /// Reads the next month and adds its photos. One that a quiet read overtook is read again.
    func loadNext() async {
        guard !loading, nextBucket < buckets.count else { return }
        loading = true; defer { endLoading() }
        let started = version
        do {
            let page = try await api.timeBucket(buckets[nextBucket].timeBucket, of: try timeline)
            guard version == started else { return }
            assets += page; nextBucket += 1
            version += 1
        } catch { failure = .init(error) }
    }

    // MARK: Commands

    /// Restored photos keep their thumbnails; the account's mutations forget only those deleted
    /// for good.
    func restoreSelected() async {
        let ids = Array(selection)
        if let result = await change(.restore(ids), on: assets.filter { selection.contains($0.id) }) {
            resultMessage = "Restored \((result.affected ?? result.succeeded.count).formatted()) items."
        }
    }

    func deleteSelected() async {
        await change(.deletePermanently(Array(selection)), on: assets.filter { selection.contains($0.id) })
    }

    func changeAll(permanently: Bool) async {
        guard !loading else { return }
        do {
            guard try await api.serverFeatures().trash else { throw APIError.invalidResponse("Trash is turned off on this server.") }
        } catch { failure = .init(error); return }
        // Photos not loaded here are named by the sync, which forgets an emptied Trash's as their
        // deletions arrive.
        guard let result = await change(permanently ? .emptyTrash : .restoreAllTrash, on: assets) else { return }
        let count = (result.affected ?? result.succeeded.count).formatted()
        resultMessage = permanently ? "Permanently removed \(count) items." : "Restored \(count) items."
    }

    /// Has the account's mutations make the change, and says what it did. The photos leave the
    /// grid from the result, in place, as they leave the feed.
    @discardableResult private func change(_ request: MutationRequest, on records: [Asset]) async -> MutationResult? {
        guard let mutations else { failure = .init(APIError.signedOut); return nil }
        loading = true; defer { endLoading() }
        do {
            let result = try await mutations.start(request, on: records).result
            if !result.failed.isEmpty { failure = .init(APIError.invalidResponse("\(result.failed.count.formatted()) items couldn’t be changed. Refresh and try again.")) }
            return result
        } catch { failure = .init(error); return nil }
    }

    // MARK: Following

    private func handle(_ event: LibraryEvent) {
        switch event {
        case .mutation(.applied(let result)): apply(result)
        case .changed(let change, _): apply(change)
        default: break
        }
    }

    /// What a mutation leaves of the Trash shown: everything goes when it was emptied or restored
    /// whole, and otherwise each photo restored or deleted. Photos put in Trash join it once the
    /// months shown are read again.
    func apply(_ result: MutationResult) {
        guard result.changedPhotos else { return }
        version += 1
        switch result.request {
        case .emptyTrash, .restoreAllTrash:
            assets = []; buckets = []; nextBucket = 0; selection = []
        case .trash, .resolveDuplicate:
            guard initialized, trashEnabled == true else { return }
            refresh()
        default:
            assets = result.applied(to: assets, keeping: CollectionMembership.trash)
            selection.formIntersection(assets.map(\.id))
        }
    }

    /// A sync's change: the photos the offline library let go leave at once, and a change that
    /// names any photo has the months shown read again.
    func apply(_ change: LibraryChange) {
        guard initialized, trashEnabled == true else { return }
        let gone = change.removed.union(change.accessLost)
        if !gone.isEmpty, assets.contains(where: { gone.contains($0.id) }) {
            assets.removeAll { gone.contains($0.id) }
            selection.subtract(gone)
            version += 1
        }
        if !change.upserted.isEmpty || change.reset || change.overflow { refresh() }
    }

    /// Reads again, quietly, the months shown and any newer month: their photos replace those
    /// shown in one go, the selection keeps what is still there, and Load more goes on after them.
    /// One read at a time; a change that comes in meanwhile has it read once more when it ends.
    private func refresh() {
        guard refreshing == nil else { refreshOwed = true; return }
        refreshing = Task { [weak self] in await self?.refreshShown() }
    }

    /// A read or a change of the screen's own ended: a quiet read owed meanwhile runs now.
    private func endLoading() {
        loading = false
        if refreshOwed, refreshing == nil { refresh() }
    }

    private func refreshShown() async {
        defer { refreshing = nil }
        repeat {
            refreshOwed = false
            let started = version
            // The oldest month shown; the months are newest first.
            let reach = nextBucket > 0 && buckets.indices.contains(nextBucket - 1) ? buckets[nextBucket - 1].timeBucket : nil
            do {
                let months = try await api.timeBuckets(try timeline)
                let shown = reach.map { reach in Array(months.prefix { $0.timeBucket >= reach }) } ?? Array(months.prefix(1))
                var read: [Asset] = []
                for month in shown { read += try await api.timeBucket(month.timeBucket, of: try timeline) }
                try Task.checkCancellation()
                // A read or a change of the screen's own is under way: it reads again once that ends.
                guard !loading else { refreshOwed = true; return }
                // Something shown changed while this read ran: it reads again rather than undo it.
                guard version == started else { refreshOwed = true; continue }
                buckets = months; assets = read; nextBucket = shown.count
                selection.formIntersection(read.map(\.id))
                version += 1
            } catch {
                // A quiet read that fails changes nothing; the next change, or a pull, reads again.
                return
            }
        } while refreshOwed && !Task.isCancelled
    }
}

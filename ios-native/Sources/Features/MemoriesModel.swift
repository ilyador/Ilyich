import Foundation
import Observation

/// The memories On this day shows (MemoriesView): today's, every saved one, or the one memory a
/// link opened, read through the account's collections.
///
/// They follow what changes elsewhere while the screen is up (plan line 78, G1). A memory shows only
/// timeline photos out of the Trash, as the server's do: a photo deleted, locked or out of reach
/// leaves its memory at once, and so does one a change made anywhere put in Trash, archived or
/// locked. A memory saved or unsaved elsewhere shows it, and an unsaved one leaves the saved
/// memories. A sync that changed memories, or changed a photo they show, has them read again
/// quietly; a quiet read that a change applied here overtook is read again rather than shown.
@MainActor @Observable final class MemoriesModel {
    /// What the screen shows.
    enum Shown: Equatable, Sendable {
        case one(String), today, saved
    }

    private(set) var memories: [Memory] = []
    private(set) var loading = true
    var failure: FeatureFailure?

    @ObservationIgnored private var collections: CollectionsService?
    @ObservationIgnored private let follower = LibraryFollower()
    /// What was asked for last.
    @ObservationIgnored private var shown: Shown?
    /// The quiet read under way; another is owed when a change came in while it ran.
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var refreshOwed = false
    /// Moves whenever what is shown changes here, so a read begun before is read again.
    @ObservationIgnored private var version = 0

    init() {}

    isolated deinit { refreshing?.cancel() }

    /// The account's collections, and its bus, which carries the mutations' results, the sync's
    /// changes and the memories saved. Following the same bus again changes nothing.
    func follow(collections: CollectionsService?, bus: LibraryBus?) {
        self.collections = collections
        follower.follow(bus ?? collections?.bus) { [weak self] event in self?.handle(event) }
    }

    /// Reads `what` and shows it. The memories read, or nil when the read failed or was cancelled.
    @discardableResult func load(_ what: Shown) async -> [Memory]? {
        shown = what
        loading = true
        defer {
            loading = false
            if refreshOwed, refreshing == nil { refresh() }
        }
        guard let collections else { failure = .init(APIError.signedOut); return nil }
        let started = version
        do {
            let read = try await Self.read(what, from: collections)
            try Task.checkCancellation()
            guard shown == what else { return nil }
            memories = read
            // A change applied while this read ran may not be in it.
            if version != started { refreshOwed = true }
            version += 1
            return read
        } catch is CancellationError {
            return nil
        } catch {
            failure = .init(error)
            return nil
        }
    }

    /// Saves or unsaves a memory through the account's collections, which tell every screen.
    func toggleSaved(_ memory: Memory) async -> Bool {
        guard let collections else { failure = .init(APIError.signedOut); return false }
        do { try await collections.setMemorySaved(memory.id, !memory.isSaved); return true }
        catch { failure = .init(error); return false }
    }

    private static func read(_ what: Shown, from collections: CollectionsService) async throws -> [Memory] {
        switch what {
        case .one(let id): [try await collections.memory(id)]
        case .today: try await collections.memories(savedOnly: false)
        case .saved: try await collections.memories(savedOnly: true)
        }
    }

    // MARK: Following

    private func handle(_ event: LibraryEvent) {
        switch event {
        case .mutation(.applied(let result)): apply(result)
        case .changed(let change, _): apply(change)
        case .collection(.memorySaved(let id, let saved)): setSaved(id, saved)
        default: break
        }
    }

    /// A mutation's result: each memory keeps what is still a timeline photo out of the Trash, and
    /// a photo changed otherwise shows its new record.
    func apply(_ result: MutationResult) {
        guard result.changedPhotos else { return }
        changeEach { result.applied(to: $0, keeping: CollectionMembership.memory) }
    }

    /// A sync's change: the photos the offline library let go leave at once, and a change to the
    /// memories, or to a photo they show, has them read again.
    func apply(_ change: LibraryChange) {
        let gone = change.removed.union(change.accessLost)
        if !gone.isEmpty { changeEach { assets in assets.filter { !gone.contains($0.id) } } }
        let named = Set(change.upserted.keys)
        let touched = !named.isEmpty && memories.contains { memory in memory.assets.contains { named.contains($0.id) } }
        if change.memoriesChanged || change.reset || change.overflow || touched { refresh() }
    }

    private func setSaved(_ id: String, _ saved: Bool) {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        if shown == .saved && !saved { memories.remove(at: index) } else { memories[index].isSaved = saved }
        version += 1
    }

    /// Changes every memory's photos with `change`, and shows the memories only when one changed.
    private func changeEach(_ change: ([Asset]) -> [Asset]) {
        var changed = false
        let next = memories.map { memory in
            var memory = memory
            let assets = change(memory.assets)
            if assets != memory.assets { memory.assets = assets; changed = true }
            return memory
        }
        guard changed else { return }
        memories = next
        version += 1
    }

    /// Reads again, quietly, what the screen shows. One read at a time; a change that comes in
    /// meanwhile has it read once more when it ends. A read the screen asked for meanwhile wins.
    private func refresh() {
        guard shown != nil else { return }
        guard refreshing == nil else { refreshOwed = true; return }
        refreshing = Task { [weak self] in await self?.refreshShown() }
    }

    private func refreshShown() async {
        defer { refreshing = nil }
        repeat {
            refreshOwed = false
            guard let collections, let what = shown else { return }
            let started = version
            guard let read = try? await Self.read(what, from: collections), !Task.isCancelled, shown == what else { return }
            // The screen's own read is under way: it shows what is newer, and reads again after.
            guard !loading else { refreshOwed = true; return }
            guard version == started else { refreshOwed = true; continue }
            memories = read
            version += 1
        } while refreshOwed && !Task.isCancelled
    }
}

import SwiftUI

extension EnvironmentValues {
    /// The signed-in account's library mutations (REBUILD_ROADMAP.md N2). The app sets it at its
    /// root from AccountSession, and the viewer is handed it as it is handed the authorization.
    /// Nil while nobody is signed in.
    @Entry var mutations: LibraryMutationService? = nil
}

/// A screen's subscription to the account's mutations. It lives as long as the screen does,
/// covered or not: while a full-screen viewer covers a screen, SwiftUI takes the screen out of
/// the window and ends its tasks, and a result the viewer makes would be missed.
@MainActor final class MutationFollower {
    private var following: (service: ObjectIdentifier, task: Task<Void, Never>)?

    /// Hands every event `service` publishes from now on to `apply`, in order. Following the same
    /// service again changes nothing; another service replaces it. The subscription ends once the
    /// follower is let go, so `apply` must not hold the follower: a closure that reads a view's
    /// own properties holds the view, and with it the follower's storage, and a follower its own
    /// handler holds is never let go. It would run for a screen long gone until sign-out.
    func follow(_ service: LibraryMutationService?, _ apply: @escaping @MainActor (MutationEvent) async -> Void) {
        guard let service else { return stop() }
        let id = ObjectIdentifier(service)
        guard following?.service != id else { return }
        following?.task.cancel()
        let events = service.events()
        following = (id, Task { for await event in events { await apply(event) } })
    }

    /// Hands the server's answer to every mutation `service` makes from now on to `apply`.
    func follow(_ service: LibraryMutationService?, applying apply: @escaping @MainActor (MutationResult) -> Void) {
        follow(service) { event in if case .applied(let result) = event { apply(result) } }
    }

    func stop() {
        following?.task.cancel()
        following = nil
    }

    isolated deinit { following?.task.cancel() }
}

extension View {
    /// Applies the result of every mutation the account makes while this screen exists to what it
    /// shows, whichever screen made it (the critic's correction to N2).
    func onMutationApplied(_ apply: @escaping @MainActor (MutationResult) -> Void) -> some View {
        modifier(MutationFollowing(apply: apply))
    }
}

private struct MutationFollowing: ViewModifier {
    @Environment(\.mutations) private var mutations
    @State private var follower = MutationFollower()
    let apply: @MainActor (MutationResult) -> Void

    func body(content: Content) -> some View {
        // Only the handler goes to the follower. A closure made here that read `apply` would hold
        // this modifier, the follower's storage with it, and no screen's follower would be let go.
        content.onAppear { follower.follow(mutations, applying: apply) }
    }
}

/// A feed, as a mutation's result reaches it: through the commands F4 gave the store, which
/// LibraryFeedStore keeps (F6).
@MainActor protocol MutationFeed: AnyObject {
    /// Whether the feed shows the Trash.
    var showsTrash: Bool { get }
    func update(_ asset: Asset)
    func removeLocally(_ ids: Set<String>)
    func refreshAfterMutation() async
}

extension LibraryFeedStore: MutationFeed {
    var showsTrash: Bool { feedQuery.trash == .trashed }
}

/// Applies the account's mutations to a feed in place (REBUILD_ROADMAP.md N2): the photos a
/// result took out leave at once and those it changed show their new records, the grid keeping
/// its place. The sync pass that follows reaches the feed as every pass does; only where none
/// follows, as without an offline library, does the feed read its months again itself.
enum FeedMutationApplier {
    @MainActor static func apply(_ event: MutationEvent, to feed: some MutationFeed, refreshes: Bool) async {
        guard case .applied(let result) = event else { return }
        let effect = FeedMutationEffect.of(result, showingTrash: feed.showsTrash)
        if !effect.removed.isEmpty { feed.removeLocally(effect.removed) }
        for record in effect.records { feed.update(record) }
        if refreshes, result.changedPhotos { await feed.refreshAfterMutation() }
    }
}

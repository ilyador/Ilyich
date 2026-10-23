import SwiftUI

extension EnvironmentValues {
    /// The signed-in account's bus (REBUILD_ROADMAP.md N4): its sync's changes, its mutations'
    /// results, its collections' changes and a cleared cache, in one order. The app sets it at its
    /// root from AccountSession, and the viewer is handed it as it is handed the mutations. Nil
    /// while nobody is signed in.
    @Entry var libraryBus: LibraryBus? = nil
    /// The signed-in account's albums, people, partners, memories and album activity on the server
    /// (REBUILD_ROADMAP.md N4). Nil while nobody is signed in.
    @Entry var collectionsService: CollectionsService? = nil
    /// The signed-in account's name, password, Locked Folder PIN and profile photo on the server.
    /// Nil while nobody is signed in.
    @Entry var accountSettings: AccountSettingsService? = nil
}

/// A screen's or a store's subscription to the account's bus. It lives as long as its owner does,
/// covered or not: while a full-screen viewer covers a screen, SwiftUI takes the screen out of the
/// window and ends its tasks, and an event would be missed.
@MainActor final class LibraryFollower {
    private var following: (bus: ObjectIdentifier, task: Task<Void, Never>)?

    init() {}

    /// Hands every event `bus` carries from now on to `handle`, in order, each once the one before
    /// it has been handled. Following the same bus again changes nothing; another bus replaces
    /// it. The subscription ends once the follower is let go, so `handle` must not hold the
    /// follower or its owner strongly.
    func follow(_ bus: LibraryBus?, _ handle: @escaping @MainActor (LibraryEvent) async -> Void) {
        guard let bus else { return stop() }
        let id = ObjectIdentifier(bus)
        guard following?.bus != id else { return }
        following?.task.cancel()
        let events = bus.events()
        following = (id, Task { for await event in events { await handle(event) } })
    }

    /// Whether the follower follows `bus` now.
    func follows(_ bus: LibraryBus) -> Bool { following?.bus == ObjectIdentifier(bus) }

    func stop() {
        following?.task.cancel()
        following = nil
    }

    isolated deinit { following?.task.cancel() }
}

extension View {
    /// Applies every change to the account's collections made while this screen exists to what it
    /// shows, whichever screen made it (N4).
    func onCollectionChange(_ apply: @escaping @MainActor (CollectionChange) -> Void) -> some View {
        modifier(CollectionFollowing(apply: apply))
    }
}

private struct CollectionFollowing: ViewModifier {
    @Environment(\.libraryBus) private var bus
    @State private var follower = LibraryFollower()
    let apply: @MainActor (CollectionChange) -> Void

    func body(content: Content) -> some View {
        content.onAppear {
            // Only the handler goes to the follower. A closure that read `apply` through this
            // modifier would hold it, the follower's storage with it, and never be let go.
            let apply = apply
            follower.follow(bus) { event in if case .collection(let change) = event { apply(change) } }
        }
    }
}

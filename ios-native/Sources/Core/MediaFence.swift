import Foundation
import Synchronization

/// Keeps media of photos that were just forgotten from coming back. Work that may store or
/// remember a photo's media takes a token before it starts; once the photo is forgotten, a token
/// from before that is refused, while work that starts later is admitted again, so a photo that
/// returns (unlocked, or shared again) is cached as before.
final class MediaFence: Sendable {
    private struct State {
        var counter: UInt64 = 0
        /// Tokens below this are refused for every photo.
        var floor: UInt64 = 0
        var forgotten: [String: UInt64] = [:]
    }
    private let state = Mutex(State())
    /// Past this many photos the fence refuses every older token instead, so it stays small.
    private let limit: Int

    init(limit: Int = 20_000) { self.limit = limit }

    func token() -> UInt64 { state.withLock { $0.counter } }

    func forget(_ ids: some Sequence<String>) {
        state.withLock { state in
            state.counter &+= 1
            for id in ids { state.forgotten[id] = state.counter }
            if state.forgotten.count > limit { state.floor = state.counter; state.forgotten = [:] }
        }
    }

    func forgetAll() {
        state.withLock { state in
            state.counter &+= 1
            state.floor = state.counter
            state.forgotten = [:]
        }
    }

    func admits(_ id: String, since token: UInt64) -> Bool {
        state.withLock { state in token >= state.floor && (state.forgotten[id] ?? 0) <= token }
    }
}

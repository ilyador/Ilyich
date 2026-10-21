import CryptoKit
import Foundation
import IlyichPlatform
import Synchronization

/// What the signed-in account may do, as one snapshot behind a lock that any thread reads
/// without waiting, with a stream of its changes and the App Group mirror that the extensions
/// and upload delegates read. Its generations come from one counter, so two of them are never
/// equal by accident:
/// - the access epoch moves when access to some photos is lost or the library is reset. It fences
///   reads and what is kept of them;
/// - the write generation moves on every read-only toggle. It fences writes and uploads, and the
///   mirror carries it;
/// - both move when the session ends.
/// A read-only toggle never moves the access epoch, so it never discards a library read.
///
/// SessionStore owns it until AccountManager owns the account (C7).
final class AuthorizationState: Sendable {
    let account: AccountID
    /// Held only to read or update the snapshot, never while calling out.
    private let state: Mutex<State>
    /// Puts changes, and what they write to the mirror and tell the streams, in one order, so the
    /// mirror never goes back to an older value. Writing to the App Group can notify its
    /// observers at once, so this is not the snapshot's lock: an observer may read the snapshot.
    private let changes = Mutex(())
    private let mirror: AuthorizationMirror?

    private struct State {
        var snapshot: AuthorizationSnapshot
        /// The last generation given out, by any of the three.
        var counter: UInt64
        var ended = false
        var observers: [UUID: AsyncStream<AuthorizationSnapshot>.Continuation] = [:]
    }

    /// The state of a session opened with `token`, which `mirror` then names. The generations go
    /// on from the one the mirror holds, so none is reused on this phone: the same account keeps
    /// it, as a relaunch changes nothing, and any other account starts after it.
    init(account: AccountID, token: String, readOnly: Bool, requiresPasswordChange: Bool, mirror: AuthorizationMirror?) {
        let published = mirror?.read()
        let start: UInt64 = if let published { published.digest == account.digest ? max(published.epoch, 1) : published.epoch &+ 1 } else { 1 }
        let tokenDigest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let snapshot = AuthorizationSnapshot(epoch: AuthorizationEpoch(account: account, value: start), writeGeneration: start, privateEpoch: start,
                                             tokenDigest: tokenDigest, readOnly: readOnly, requiresPasswordChange: requiresPasswordChange,
                                             lockedFolderUnlocked: false)
        self.account = account
        self.mirror = mirror
        state = Mutex(State(snapshot: snapshot, counter: start))
        mirror?.publish(.init(digest: account.digest, epoch: start))
    }

    var snapshot: AuthorizationSnapshot { state.withLock { $0.snapshot } }

    /// Whether the session ended: signed out, or replaced by another.
    var hasEnded: Bool { state.withLock { $0.ended } }

    /// Whether a result made under `epoch` may still be kept.
    func isCurrent(_ epoch: AuthorizationEpoch) -> Bool {
        state.withLock { !$0.ended && $0.snapshot.epoch == epoch }
    }

    /// Read-only mode on or off. The write generation moves, so writes waiting to be sent are
    /// refused, and the mirror says so. Setting it to what it already is changes nothing.
    @discardableResult
    func setReadOnly(_ enabled: Bool) -> AuthorizationSnapshot {
        change(mirrored: true) { snapshot, next in
            guard snapshot.readOnly != enabled else { return false }
            snapshot.readOnly = enabled
            snapshot.writeGeneration = next
            return true
        }
    }

    /// Access to some photos was lost, or the library was reset: what was read or kept before
    /// may show what the account can no longer see. Writes are unaffected.
    @discardableResult
    func accessChanged() -> AuthorizationSnapshot {
        change(mirrored: false) { snapshot, next in
            snapshot.epoch = AuthorizationEpoch(account: account, value: next)
            return true
        }
    }

    /// Ends the session. Nothing made under it is current again, the mirror names no account,
    /// and the updates streams finish.
    func end() {
        changes.withLock { _ in
            let ended = state.withLock { state -> (generation: UInt64, observers: [AsyncStream<AuthorizationSnapshot>.Continuation])? in
                guard !state.ended else { return nil }
                state.ended = true
                state.counter &+= 1
                state.snapshot.epoch = AuthorizationEpoch(account: account, value: state.counter)
                state.snapshot.writeGeneration = state.counter
                defer { state.observers = [:] }
                return (state.counter, Array(state.observers.values))
            }
            guard let ended else { return }
            mirror?.publish(.init(digest: "", epoch: ended.generation))
            // Finishing runs each stream's termination handler, which takes the snapshot's lock.
            for observer in ended.observers { observer.finish() }
        }
    }

    /// The snapshot now, then each change, until the session ends. A slow reader gets the latest.
    func updates() -> AsyncStream<AuthorizationSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: AuthorizationSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let ended = state.withLock { state -> Bool in
            continuation.yield(state.snapshot)
            if !state.ended { state.observers[id] = continuation }
            return state.ended
        }
        if ended { continuation.finish() }
        else { continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.observers.removeValue(forKey: id) } } }
        return stream
    }

    /// Applies `update` with the next generation, if it changes anything, and tells the mirror
    /// when the write generation moved.
    private func change(mirrored: Bool, _ update: (inout AuthorizationSnapshot, UInt64) -> Bool) -> AuthorizationSnapshot {
        changes.withLock { _ in
            let (snapshot, observers, changed) = state.withLock { state -> (AuthorizationSnapshot, [AsyncStream<AuthorizationSnapshot>.Continuation], Bool) in
                let next = state.counter &+ 1
                guard !state.ended, update(&state.snapshot, next) else { return (state.snapshot, [], false) }
                state.counter = next
                return (state.snapshot, Array(state.observers.values), true)
            }
            guard changed else { return snapshot }
            if mirrored { mirror?.publish(.init(digest: account.digest, epoch: snapshot.writeGeneration)) }
            for observer in observers { observer.yield(snapshot) }
            return snapshot
        }
    }
}

/// The main client's requests ask the account's state: a write is refused while read-only mode
/// is on, and also when the write generation moved while it waited to be sent, whatever read-only
/// mode is by then. Reads and the requests read-only mode allows always go.
extension AuthorizationState: RequestAuthority {
    func admit(method: String, path: String) throws -> UInt64? {
        guard !ReadOnlyPolicy.permits(method: method, path: path) else { return nil }
        let snapshot = snapshot
        guard !snapshot.readOnly else { throw ReadOnlyPolicy.ReadOnlyError() }
        return snapshot.writeGeneration
    }

    func confirm(method: String, path: String, admittedUnder generation: UInt64?) throws {
        guard let generation else { return }
        let snapshot = snapshot
        guard !snapshot.readOnly else { throw ReadOnlyPolicy.ReadOnlyError() }
        guard snapshot.writeGeneration == generation else { throw WriteFenced() }
    }
}

/// A change that waited to be sent while read-only mode was turned on and off again. It is not
/// sent: it was asked for under the setting before.
struct WriteFenced: LocalizedError, Equatable {
    var errorDescription: String? { "Read-only mode changed before this change was sent. Try again." }
}

extension Error {
    /// Read-only mode refused this, or turned on and off while it waited: an upload loop pauses
    /// for it rather than counting a failure.
    var isReadOnlyRefusal: Bool { self is ReadOnlyPolicy.ReadOnlyError || self is WriteFenced }
}

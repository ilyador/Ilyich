import Foundation

/// A child session the server made for a Cast receiver: its own token, expiring on its own and
/// revocable without touching the app's session.
struct CastGrant: Sendable, Equatable {
    let id: String
    let token: String
    let expiresAt: Date

    /// Only an id that is one plain path segment is ever sent in `DELETE sessions/{id}`. An empty
    /// or odd id could otherwise reach `DELETE sessions`, which ends every other session.
    static func isRevocable(id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }
}

/// Makes and revokes Cast grants. APIClient in the app; fakes in tests.
protocol CastGrantServer: Sendable {
    /// A child session of the account's session that expires after `seconds`.
    func createCastGrant(seconds: Int) async throws -> CastGrant
    /// Revokes only the child session `id`.
    func revokeCastGrant(id: String) async throws
}

enum CastGrantError: LocalizedError, Equatable {
    /// The account is signing out; no new grant is made for it.
    case closed
    /// The server's answer can't be revoked safely, so it was not used.
    case unusableGrant

    var errorDescription: String? {
        switch self {
        case .closed: "You’re signed out. Sign in again to continue."
        case .unusableGrant: "The server returned a Cast session the app can’t manage. Try again."
        }
    }
}

/// What may be cast, and for how long the receiver needs its grant.
enum CastEligibility {
    /// A locked photo never reaches a TV (PF5).
    static func allows(_ asset: Asset) -> Bool { asset.visibility != .locked }

    /// How long, in seconds, the receiver reads `asset`: a video for its whole length, so playback
    /// and seeking keep working; a photo only while it loads. A video without a known length is
    /// treated as an hour long.
    static func need(for asset: Asset) -> TimeInterval {
        guard asset.isVideo else { return 0 }
        guard let milliseconds = asset.duration, milliseconds > 0 else { return 3_600 }
        return (Double(milliseconds) / 1_000).rounded(.up)
    }
}

/// The account's Cast grants (REBUILD_ROADMAP.md W2). One child session is made at a time and
/// reused while it still covers what is asked; each is revoked when casting stops, the Cast
/// session ends, the account changes and at sign-out. Revoking deletes only the grants this store
/// made, never the app's own session.
actor CastGrantStore {
    /// A grant is reused only while it has the need plus this long left.
    static let reuseMargin: TimeInterval = 60
    /// A new grant lasts the need plus this long, within `durationRange`.
    static let headroom: TimeInterval = 300
    static let durationRange = 900...21_600

    /// The grant's lifetime, in seconds, for a receiver that needs it `need` seconds.
    static func duration(covering need: TimeInterval) -> Int {
        let wanted = Int((max(0, need) + headroom).rounded(.up))
        return min(max(wanted, durationRange.lowerBound), durationRange.upperBound)
    }

    private let server: any CastGrantServer
    private let now: @Sendable () -> Date
    private var current: CastGrant?
    /// Grants a longer one replaced. A receiver may still be reading one, so they are revoked with
    /// the current grant rather than at once.
    private var superseded: [CastGrant] = []
    private var pending: (id: UUID, need: TimeInterval, task: Task<CastGrant, any Error>)?
    /// Bumped by every revoke: a grant asked for before it is revoked as soon as it arrives.
    private var generation: UInt64 = 0
    private var revoking: Task<Void, Never>?
    private var closed = false

    init(server: any CastGrantServer, now: @escaping @Sendable () -> Date = Date.init) {
        self.server = server
        self.now = now
    }

    /// A grant with at least `need` seconds and the margin left, made only when none has. Asks
    /// that arrive while one is being made share it when it covers them.
    func grant(covering need: TimeInterval) async throws -> CastGrant {
        guard !closed else { throw CastGrantError.closed }
        if let current, covers(current, need) { return current }
        if let pending, pending.need >= need { return try await pending.task.value }
        let id = UUID(), seconds = Self.duration(covering: need), generation = generation
        let task = Task { try await self.create(id: id, seconds: seconds, generation: generation) }
        pending = (id, need, task)
        return try await task.value
    }

    /// Revokes every grant made so far, and one still being made once it arrives. Returns when the
    /// server has been asked; a failure is ignored, since a grant expires on its own.
    func revoke() async {
        generation &+= 1
        let waiting = pending?.task
        pending = nil
        let grants = ([current].compactMap { $0 } + superseded).filter { $0.expiresAt > now() }
        current = nil
        superseded = []
        let previous = revoking, server = server
        let run = Task {
            await previous?.value
            for grant in grants { try? await server.revokeCastGrant(id: grant.id) }
        }
        revoking = run
        // A grant still being made sees the new generation and revokes itself.
        _ = try? await waiting?.value
        await run.value
    }

    /// Revokes everything and makes no grant again: the account is signing out.
    func close() async {
        closed = true
        await revoke()
    }

    /// The grant in use, for tests.
    var currentGrant: CastGrant? { current }

    private func covers(_ grant: CastGrant, _ need: TimeInterval) -> Bool {
        grant.expiresAt.timeIntervalSince(now()) >= max(0, need) + Self.reuseMargin
    }

    private func create(id: UUID, seconds: Int, generation: UInt64) async throws -> CastGrant {
        defer { if pending?.id == id { pending = nil } }
        let grant = try await server.createCastGrant(seconds: seconds)
        guard generation == self.generation, !closed else {
            // Revoked while it was being made: it never reaches a receiver.
            if CastGrant.isRevocable(id: grant.id) { try? await server.revokeCastGrant(id: grant.id) }
            throw CancellationError()
        }
        if let current {
            // A shorter grant that arrives after a longer one never replaces it.
            guard grant.expiresAt > current.expiresAt else { superseded.append(grant); return grant }
            superseded.append(current)
        }
        current = grant
        return grant
    }
}

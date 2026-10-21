import Foundation

/// When a failure ends the session. Signing in again re-syncs the whole library, so only Immich
/// itself saying the session is gone, twice, signs out. A proxy's refusal, a forbidden answer and
/// a network failure never do; Sign out stays in Settings for those.
///
/// Interim rule until AccountManager owns the session (C7).
enum SessionPolicy {
    /// Whether to sign out after `failure`. Only an expired session is checked again, with
    /// `recheck` (a second auth/validateToken) after `delay`, and only that check failing the
    /// same way confirms it.
    static func confirmsExpiry(after failure: any Error, delay: Duration = .seconds(2),
                               recheck: @Sendable () async throws -> Void) async -> Bool {
        guard case ServerFailure.sessionExpired = failure else { return false }
        do {
            try await Task.sleep(for: delay)
            try await recheck()
            return false
        } catch ServerFailure.sessionExpired {
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

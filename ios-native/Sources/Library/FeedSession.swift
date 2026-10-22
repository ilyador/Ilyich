import Foundation

/// One opening of a feed (F4): the ticket every delivery of its months carries, the query it
/// shows and the plan its months come from. While a new feed loads, the one on screen stays as
/// it was, frozen, as the displayed session, and the new one is pending until it is ready; a
/// sync's reload of the feed shown keeps its session and the months on their way.
struct FeedSession: Equatable {
    let ticket: TimelineFeed.Ticket
    let query: LibraryQuery
    let plan: QueryPlan

    init(_ query: LibraryQuery, plan: QueryPlan) {
        ticket = TimelineFeed.Ticket(); self.query = query; self.plan = plan
    }

    /// Where one of a pending feed's first months stands.
    enum Month: Equatable, Sendable {
        case loading
        case loaded
        /// Only the phone has it, so there is nothing to load (FEED-2).
        case phoneOnly
        case failed(String)
    }

    enum Readiness: Equatable, Sendable {
        case waiting
        /// The pending feed replaces the one shown.
        case ready
        /// The feed shown stays, with the error, for Retry and Clear (PARITY 3040020).
        case failed(String)
    }

    /// The months a pending feed waits for: its first two, or all it has when it has fewer.
    static let firstMonths = 2

    /// A pending feed is ready once its summary is in and each of its first months has loaded or
    /// is only on the phone; a feed with no month is ready at once. A month that failed keeps the
    /// feed shown, never the new one with placeholders. A slow month is waited for: committing
    /// after a timeout waits for the owner's answer (the critic's correction to F4).
    static func readiness(_ months: [Month]) -> Readiness {
        for month in months { if case .failed(let message) = month { return .failed(message) } }
        return months.allSatisfy { $0 == .loaded || $0 == .phoneOnly } ? .ready : .waiting
    }
}

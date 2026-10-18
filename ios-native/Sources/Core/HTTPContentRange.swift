import Foundation

/// A single successful HTTP byte-range response. Unsatisfied and unknown-length forms cannot initialize video metadata.
struct HTTPContentRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    let total: Int64

    init?(_ header: String) {
        let pieces = header.split(separator: " ", omittingEmptySubsequences: true)
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return nil }
        let extent = pieces[1].split(separator: "/", omittingEmptySubsequences: false)
        guard extent.count == 2, let total = Int64(extent[1]), total > 0 else { return nil }
        let interval = extent[0].split(separator: "-", omittingEmptySubsequences: false)
        guard interval.count == 2, let start = Int64(interval[0]), let end = Int64(interval[1]), start >= 0, end >= start, end < total else { return nil }
        self.start = start; self.end = end; self.total = total
    }
}

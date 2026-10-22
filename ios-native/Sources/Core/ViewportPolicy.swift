import Foundation

/// The viewport motion policy (REBUILD_ROADMAP.md T3): where a grid's thumbnails may come from,
/// decided by how the grid moves. Speeds are in screens per second.
///
/// - Scrubbing, or faster than `fastSpeed`: photos pass before a download could arrive, so the
///   screen is served from memory and the disk, and only where the grid will land (the fling's
///   target, or the month the rail's finger rests on) may download.
/// - Slower than `slowSpeed`, or at rest: the photos on screen download from the middle out, then
///   those about to scroll in and those just passed.
/// - Between the two the decision before stands, so a speed hovering near a threshold does not
///   start and stop downloads every frame.
/// - Coverage, which keeps the whole library on the phone, waits `coverageHold` after the grid
///   comes to rest (CoveragePolicy.motionHold carries the same default).
enum ViewportPolicy {
    static let fastSpeed = 2.5
    static let slowSpeed = 1.2
    static let coverageHold: TimeInterval = 1.5
    /// A grid whose offset has not changed for this long has come to rest.
    static let restAfter: TimeInterval = 0.1
    /// How far ahead the grid asks for photos: this many screens at least, and as many screens as
    /// it moves in a second up to `aheadScreens.upperBound`.
    static let aheadScreens: ClosedRange<Double> = 1...3
    /// How far behind: the photos just passed, for a reversal.
    static let behindScreens = 1.0

    /// Whether photos pass faster than they could arrive, given the decision before.
    static func isFast(_ motion: Motion, wasFast: Bool) -> Bool {
        switch motion {
        case .scrubbing: true
        case .idle: false
        case .tracking(let speed), .flinging(let speed):
            speed > fastSpeed ? true : speed < slowSpeed ? false : wasFast
        }
    }

    /// Whether a photo wanted on `band` may download now.
    static func allowsNetwork(_ band: DemandBand, fast: Bool) -> Bool { !fast || band == .target }

    /// How many screens ahead the grid asks for at `speed`.
    static func aheadScreens(at speed: Double) -> Double {
        min(aheadScreens.upperBound, max(aheadScreens.lowerBound, speed))
    }
}

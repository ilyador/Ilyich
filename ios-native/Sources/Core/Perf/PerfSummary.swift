import Foundation

/// What one perf scenario measured, as scripts/perf/summarize.py reads it. Durations are in
/// milliseconds and memory in megabytes (2^20 bytes); every percentile is already worked out,
/// so the script only formats.
struct PerfSummary: Codable, Equatable, Sendable {
    /// Nearest-rank percentiles of durations in milliseconds; only the count when there are none.
    struct Stats: Codable, Equatable, Sendable {
        var count: Int
        var p50: Double?
        var p95: Double?
        var p99: Double?
        var max: Double?
    }

    struct App: Codable, Equatable, Sendable {
        var version = ""
        var build = ""
        var configuration = ""
    }

    struct Device: Codable, Equatable, Sendable {
        var model = ""
        var system = ""
        var physicalMemoryMB = 0.0
        var maximumFramesPerSecond = 0
        var lowPowerMode = false
        var thermalStateAtStart = ""
        var thermalStateAtEnd = ""
    }

    struct Library: Codable, Equatable, Sendable {
        var months: Int
        var photos: Int
        var columns: Int
    }

    /// What was measured: from READY to the end, or for relaunch-check from the launch.
    struct Window: Codable, Equatable, Sendable {
        var seconds: Double
        var fromLaunch: Bool
    }

    struct Launch: Codable, Equatable, Sendable {
        /// From the process start to the first grid frame with at least 12 real thumbnails. From
        /// the app's init instead when iOS prewarmed the process.
        var firstContentMs: Double?
        /// From the process start to the app's init, where measuring starts.
        var armedMs: Double?
        var prewarmed = false
    }

    struct Thumbnails: Codable, Equatable, Sendable {
        struct Placeholders: Codable, Equatable, Sendable {
            /// The photo's thumbhash.
            var sketch: Int
            /// Nothing: the photo has no thumbhash.
            var empty: Int
            /// Nothing yet: the photo's month had not loaded. Counted once per cell and month.
            var awaitingMonth: Int
            /// The sketch's average colour, for the frame or two its sketch takes to decode.
            var color: Int
            var total: Int
        }
        /// Cells bound to a photo they did not show yet.
        var binds: Int
        /// Binds that drew a real thumbnail from memory in their own frame, of all binds.
        var sameFrameMemoryShare: Double
        /// Bind to first real thumbnail, by source: memory, memoryOther, disk, network.
        var display: [String: Stats]
        var placeholders: Placeholders
        /// Binds the cell let go of before a thumbnail came: scrolled away or reused.
        var abandoned: Int
        /// Binds whose thumbnail failed to load.
        var failed: Int
    }

    struct Hitches: Codable, Equatable, Sendable {
        /// Display link callbacks seen.
        var frames: Int
        var frameRate: Double
        var count: Int
        var totalMs: Double
        /// Hitch time per second of the window, as Instruments reports it.
        var ratioMsPerSecond: Double
        var longestMs: Double
    }

    struct Hangs: Codable, Equatable, Sendable {
        /// Main thread blocked for 250 ms or more.
        var count: Int
        var totalMs: Double
        var longestMs: Double
        /// The first 50, in order.
        var durationsMs: [Double]
    }

    struct Memory: Codable, Equatable, Sendable {
        struct Trim: Codable, Equatable, Sendable {
            /// When the memory warning was posted, from the window's start.
            var atSeconds: Double
            var beforeMB: Double?
            /// The first sample at least 2 s after the trim.
            var after2sMB: Double?
        }
        /// phys_footprint every 250 ms.
        var samples: Int
        var startMB: Double?
        var endMB: Double?
        var peakMB: Double?
        /// Since the launch, the window included.
        var processPeakMB: Double?
        var trims: [Trim]
    }

    struct Feed: Codable, Equatable, Sendable {
        /// Month load durations by backend: index or serverTimeline.
        var month: [String: Stats]
        var failed: Int
        /// Loaded months that reached the grid.
        var commits: Int
    }

    struct Sync: Codable, Equatable, Sendable {
        /// Passes that ended in the window.
        var passes: Stats
        var outcomes: [String: Int]
    }

    struct Scrub: Codable, Equatable, Sendable {
        var strokes: Int
        var seconds: Double
    }

    /// What ran beside the scenario, sampled before each jump of background-load.
    struct Background: Codable, Equatable, Sendable {
        var samples: Int
        var backupRunningAtStart: Bool
        var queuedAtStart: Int
        var backupRunningShare: Double
        var syncingShare: Double
        var warmerRunningShare: Double
    }

    /// Everything the recorder measured.
    struct Measurements: Codable, Equatable, Sendable {
        var window: Window
        var launch: Launch
        var thumbnails: Thumbnails
        var hitches: Hitches
        var hangs: Hangs
        var memory: Memory
        var feed: Feed
        var sync: Sync
        var scrub: Scrub
    }

    var schema = 1
    var scenario: String
    var seed: UInt64
    /// completed, noFirstContent, noGrid or cancelled.
    var status: String
    var startedAt: String
    var app: App
    var device: Device
    var library: Library?
    var measurements: Measurements
    var background: Background?

    /// Nearest-rank percentiles: the smallest value with at least p percent of all at or below it.
    static func stats(milliseconds values: [Double]) -> Stats {
        guard !values.isEmpty else { return Stats(count: 0) }
        let sorted = values.sorted()
        func rank(_ percent: Double) -> Double {
            sorted[min(sorted.count - 1, max(0, Int((percent / 100 * Double(sorted.count)).rounded(.up)) - 1))]
        }
        return Stats(count: sorted.count, p50: rounded(rank(50)), p95: rounded(rank(95)),
                     p99: rounded(rank(99)), max: rounded(sorted[sorted.count - 1]))
    }

    /// Microsecond precision is plenty, and keeps the file readable.
    static func rounded(_ value: Double) -> Double { (value * 1_000).rounded() / 1_000 }
}

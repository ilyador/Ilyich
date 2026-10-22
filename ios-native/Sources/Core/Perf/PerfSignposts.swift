import Foundation
import os

/// The signposts of the rebuild plan's instrumentation section. Scripts and Instruments parse
/// these names, so a shipped name never changes; new ones are only added. They are emitted
/// only while a perf scenario runs: otherwise every signposter is disabled and costs one check.
enum PerfSignpost {
    static let subsystem = "app.ilyich.native"

    /// Each area is a signpost category, as Instruments lists them.
    enum Category {
        static let thumbnails = "thumbnails"
        static let scrub = "scrub"
        static let feed = "feed"
        static let launch = "launch"
        static let sync = "sync"
        static let index = "index"
        static let transfer = "transfer"
        static let memory = "memory"
        static let perf = "perf"
        static let cleanup = "cleanup"
    }

    /// From a cell's bind to its first real thumbnail. The end carries the source.
    static let thumbDisplay: StaticString = "thumb.display"
    /// A bind that showed the sketch or nothing while its thumbnail was on its way.
    static let thumbPlaceholder: StaticString = "thumb.placeholder"
    /// A finger, or the perf driver, on the time rail.
    static let railScrub: StaticString = "rail.scrub"
    static let gridFling: StaticString = "grid.fling"
    /// One month's photos loading. The end carries the backend that answered.
    static let feedMonth: StaticString = "feed.month"
    /// A loaded month reaching the grid.
    static let feedCommit: StaticString = "feed.commit"
    /// From the app's start to the first grid frame with at least 12 real thumbnails.
    static let launchFirstContent: StaticString = "launch.firstContent"
    static let syncPass: StaticString = "sync.pass"
    static let indexBackfill: StaticString = "index.backfill"
    static let transferStage: StaticString = "transfer.stage"
    static let transferSubmit: StaticString = "transfer.submit"
    static let transferCommit: StaticString = "transfer.commit"
    /// The app's phys_footprint, sampled.
    static let memFootprint: StaticString = "mem.footprint"
    static let perfScenario: StaticString = "perf.scenario"
    /// One Free up space check, to its candidates. The end carries the receipts, the photos
    /// verified with the server, the most server checks in flight at once and the candidates.
    static let cleanupScan: StaticString = "cleanup.scan"

    /// Every name by category.
    static let catalog: [(category: String, names: [StaticString])] = [
        (Category.thumbnails, [thumbDisplay, thumbPlaceholder]),
        (Category.scrub, [railScrub, gridFling]),
        (Category.feed, [feedMonth, feedCommit]),
        (Category.launch, [launchFirstContent]),
        (Category.sync, [syncPass]),
        (Category.index, [indexBackfill]),
        (Category.transfer, [transferStage, transferSubmit, transferCommit]),
        (Category.memory, [memFootprint]),
        (Category.perf, [perfScenario]),
        (Category.cleanup, [cleanupScan]),
    ]

    static let thumbnails = signposter(Category.thumbnails)
    static let scrub = signposter(Category.scrub)
    static let feed = signposter(Category.feed)
    static let launch = signposter(Category.launch)
    static let sync = signposter(Category.sync)
    static let index = signposter(Category.index)
    static let transfer = signposter(Category.transfer)
    static let memory = signposter(Category.memory)
    static let perf = signposter(Category.perf)
    static let cleanup = signposter(Category.cleanup)

    private static func signposter(_ category: String) -> OSSignposter {
        PerfRecorder.shared == nil ? .disabled : OSSignposter(subsystem: subsystem, category: category)
    }
}

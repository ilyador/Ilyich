import XCTest
@testable import Ilyich

/// Scripts and Instruments parse these names, so renaming one would break every baseline
/// recorded before it.
final class SignpostNamesTests: XCTestCase {
    func testTheSubsystemAndEveryNameAreStable() {
        XCTAssertEqual(PerfSignpost.subsystem, "app.ilyich.native")
        let catalog = PerfSignpost.catalog.map { ($0.category, $0.names.map(\.description)) }
        XCTAssertEqual(catalog.map(\.0), ["thumbnails", "scrub", "feed", "launch", "sync", "index", "transfer", "memory", "perf", "cleanup"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: catalog), [
            "thumbnails": ["thumb.display", "thumb.placeholder"],
            "scrub": ["rail.scrub", "grid.fling"],
            "feed": ["feed.month", "feed.commit"],
            "launch": ["launch.firstContent"],
            "sync": ["sync.pass"],
            "index": ["index.backfill"],
            "transfer": ["transfer.stage", "transfer.submit", "transfer.commit"],
            "memory": ["mem.footprint"],
            "perf": ["perf.scenario"],
            "cleanup": ["cleanup.scan"],
        ])
    }

    func testEachConstantCarriesItsName() {
        let constants: [(StaticString, String)] = [
            (PerfSignpost.thumbDisplay, "thumb.display"), (PerfSignpost.thumbPlaceholder, "thumb.placeholder"),
            (PerfSignpost.railScrub, "rail.scrub"), (PerfSignpost.gridFling, "grid.fling"),
            (PerfSignpost.feedMonth, "feed.month"), (PerfSignpost.feedCommit, "feed.commit"),
            (PerfSignpost.launchFirstContent, "launch.firstContent"), (PerfSignpost.syncPass, "sync.pass"),
            (PerfSignpost.indexBackfill, "index.backfill"), (PerfSignpost.transferStage, "transfer.stage"),
            (PerfSignpost.transferSubmit, "transfer.submit"), (PerfSignpost.transferCommit, "transfer.commit"),
            (PerfSignpost.memFootprint, "mem.footprint"), (PerfSignpost.perfScenario, "perf.scenario"),
            (PerfSignpost.cleanupScan, "cleanup.scan"),
        ]
        for (constant, name) in constants { XCTAssertEqual(constant.description, name) }
        let all = PerfSignpost.catalog.flatMap(\.names).map(\.description)
        XCTAssertEqual(Set(all).count, all.count, "No name is used twice.")
        XCTAssertEqual(Set(all), Set(constants.map(\.1)), "Every constant is in the catalog.")
    }

    /// The summary and the signposts' metadata use these words too.
    func testSourcesPlaceholdersAndBackendsKeepTheirNames() {
        XCTAssertEqual(ThumbSource.allCases.map(\.name), ["memory", "memoryOther", "disk", "network", "device"])
        XCTAssertEqual(ThumbPlaceholder.allCases.map(\.name), ["sketch", "empty", "awaitingMonth", "color"])
        XCTAssertEqual([QueryPlan.Backend.index, .serverTimeline, .serverSearch].map(FeedMonthProbe.name),
                       ["index", "serverTimeline", "serverSearch"])
    }
}

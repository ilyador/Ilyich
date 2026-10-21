import XCTest
@testable import Ilyich

final class PerfScenarioDriverTests: XCTestCase {
    @MainActor func testWithoutTheArgumentNothingRuns() {
        XCTAssertNil(PerfScenarioConfiguration(arguments: ["Ilyich"]))
        XCTAssertNil(PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfSeed", "3"]), "A seed alone starts nothing.")
        XCTAssertNil(PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfScenario"]), "A scenario needs a name.")
        XCTAssertNil(PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfScenario", "warp-speed"]), "An unknown name starts nothing.")
        // The tests run in an app launched without a scenario: nothing is recorded or signposted.
        XCTAssertNil(PerfRecorder.shared)
        XCTAssertNil(PerfScenarioDriver.shared)
        XCTAssertFalse(PerfSignpost.thumbnails.isEnabled)
        XCTAssertFalse(PerfSignpost.feed.isEnabled)
        PerfScenarioDriver.arm()
        var probe = ThumbDisplayProbe()
        probe.bind(); probe.placeholder(.sketch); probe.displayed(.disk)
        XCTAssertNil(PerfRecorder.shared, "Arming and probing stay inert.")
    }

    func testScenarioAndSeedAreParsed() {
        XCTAssertEqual(PerfScenarioConfiguration.Scenario.allCases.map(\.rawValue),
                       ["rail-random", "rail-sweep", "fling", "reverse", "relaunch-check", "memory-warning", "background-load"])
        for scenario in PerfScenarioConfiguration.Scenario.allCases {
            let parsed = PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfScenario", scenario.rawValue])
            XCTAssertEqual(parsed, PerfScenarioConfiguration(scenario: scenario, seed: 7), "Without a seed it is 7.")
        }
        XCTAssertEqual(PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfScenario", "fling", "-IlyichPerfSeed", "42"])?.seed, 42)
        XCTAssertEqual(PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfSeed", "9", "-IlyichPerfScenario", "reverse"]),
                       PerfScenarioConfiguration(scenario: .reverse, seed: 9), "Order does not matter.")
        for unreadable in ["-3", "seven", "", "18446744073709551616"] {
            XCTAssertEqual(PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfScenario", "fling", "-IlyichPerfSeed", unreadable])?.seed, 7)
        }
        XCTAssertEqual(PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfScenario", "fling", "-IlyichPerfSeed"])?.seed, 7)
    }

    func testASeedAlwaysMakesTheSameJumps() {
        let jumps = PerfScenarioPlan.jumps(seed: 7)
        XCTAssertEqual(jumps.count, 20)
        XCTAssertEqual(jumps, PerfScenarioPlan.jumps(seed: 7))
        XCTAssertNotEqual(jumps, PerfScenarioPlan.jumps(seed: 8))
        XCTAssertTrue(jumps.allSatisfy { (0..<1).contains($0) })
        // Pinned, so a later build replays the jumps the baseline was recorded with.
        let pinned = [0.38983, 0.016788, 0.900761, 0.58293, 0.452442]
        for (jump, expected) in zip(jumps, pinned) { XCTAssertEqual(jump, expected, accuracy: 0.000_001) }
        XCTAssertEqual(PerfScenarioPlan.jumps(seed: 8).first ?? 0, 0.618505, accuracy: 0.000_001)
    }

    func testFlingSpeedsAreSeededAndInRange() {
        let speeds = PerfScenarioPlan.flingSpeeds(seed: 7, count: 10, in: 3...9)
        XCTAssertEqual(speeds, PerfScenarioPlan.flingSpeeds(seed: 7, count: 10, in: 3...9))
        XCTAssertTrue(speeds.allSatisfy { (3..<9).contains($0) })
        XCTAssertEqual(speeds.first ?? 0, 8.542201, accuracy: 0.000_001)
        XCTAssertNotEqual(speeds.map { ($0 - 3) / 6 }, Array(PerfScenarioPlan.jumps(seed: 7, count: 10)), "Flings draw from their own stream.")
    }

    func testTheSummaryFileNameSortsByTime() {
        let date = Date(timeIntervalSince1970: 1_792_527_300)
        XCTAssertEqual(PerfScenarioDriver.stamp(date), "20261020T201500Z")
        XCTAssertEqual(PerfScenarioDriver.folder, "Library/Caches/IlyichPerf")
    }
}

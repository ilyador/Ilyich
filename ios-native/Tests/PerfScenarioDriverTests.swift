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

    /// The grid is driven as C4's driver drove it unless the finger drive is asked for, so the
    /// numbers of a default run compare with the C4 baseline.
    func testTheDriveDefaultsToTheBaseline() {
        XCTAssertEqual(PerfScenarioConfiguration.Drive.allCases.map(\.rawValue), ["baseline", "finger"])
        XCTAssertEqual(PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfScenario", "rail-sweep"])?.drive, .baseline)
        XCTAssertEqual(PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfScenario", "rail-sweep", "-IlyichPerfDrive", "baseline"])?.drive,
                       .baseline)
        XCTAssertEqual(PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfDrive", "finger", "-IlyichPerfScenario", "rail-sweep"]),
                       PerfScenarioConfiguration(scenario: .railSweep, seed: 7, drive: .finger))
        for unknown in ["", "thumb", "Finger"] {
            XCTAssertEqual(PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfScenario", "fling", "-IlyichPerfDrive", unknown])?.drive,
                           .baseline)
        }
        XCTAssertNil(PerfScenarioConfiguration(arguments: ["Ilyich", "-IlyichPerfDrive", "finger"]), "A drive alone starts nothing.")
    }

    /// A default run writes the summary it always wrote; a finger-driven one says how it ran.
    func testOnlyTheFingerDriveIsNamedInTheSummary() throws {
        let measurements = PerfRecorder(processStart: 0, now: 0).measurements(at: 1_000_000_000)
        func written(drive: String?) throws -> [String: Any] {
            let summary = PerfSummary(scenario: "rail-sweep", seed: 7, drive: drive, status: "completed", startedAt: "",
                                      app: .init(), device: .init(), library: nil, measurements: measurements, background: nil)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        }
        XCTAssertNil(try written(drive: nil)["drive"])
        XCTAssertEqual(try written(drive: "finger")["drive"] as? String, "finger")
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

import XCTest

/// Runs a perf scenario on the UI-test fixture library the way scripts/perf/record.sh runs one on
/// the phone, and checks that a sane summary comes out.
final class PerfScenarioUITests: XCTestCase {
    @MainActor func testRailSweepWritesASummary() throws {
        // First content, 8 s of settling, a 20 s sweep and a dwell.
        let summary = try run("rail-sweep", timeout: 150)
        XCTAssertEqual(summary["status"] as? String, "completed")
        let measured = try XCTUnwrap(summary["measurements"] as? [String: Any])
        XCTAssertEqual(Self.number(measured, "window.seconds") ?? 0, 22, accuracy: 6, "The sweep and its dwell.")
        XCTAssertGreaterThan(Self.number(measured, "launch.firstContentMs") ?? 0, 0)
        XCTAssertGreaterThan(Self.number(measured, "thumbnails.binds") ?? 0, 100, "A sweep binds cells all the way down.")
        XCTAssertGreaterThan(Self.number(measured, "hitches.frames") ?? 0, 600, "The display link ran through the window.")
        XCTAssertLessThan(Self.number(measured, "hitches.ratioMsPerSecond") ?? .infinity, 500, "Hitches are a share of the window.")
        XCTAssertGreaterThan(Self.number(measured, "memory.samples") ?? 0, 40, "Four samples a second.")
        XCTAssertGreaterThan(Self.number(measured, "memory.peakMB") ?? 0, 10)
        XCTAssertEqual(Self.number(measured, "scrub.strokes"), 1, "One stroke from top to bottom.")
    }

    /// Launches the scenario, waits for its summary and returns it, attached to the test.
    @MainActor func run(_ scenario: String, seed: Int = 7, timeout: TimeInterval) throws -> [String: Any] {
        continueAfterFailure = false
        let launched = Date()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-library", "-IlyichPerfScenario", scenario, "-IlyichPerfSeed", String(seed)]
        app.launch()
        XCTAssertTrue(app.collectionViews["library.grid"].waitForExistence(timeout: 15))
        let file = try XCTUnwrap(summaryFile(prefix: "\(scenario)-\(seed)-", after: launched, timeout: timeout),
                                 "\(scenario) wrote no summary.")
        let data = try Data(contentsOf: file)
        // The attachment and the log keep it; the simulator does not need to.
        try? FileManager.default.removeItem(at: file)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = file.lastPathComponent
        attachment.lifetime = .keepAlways
        add(attachment)
        print("PERF SUMMARY \(file.lastPathComponent)\n\(String(decoding: data, as: UTF8.self))")
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(summary["scenario"] as? String, scenario)
        XCTAssertEqual(summary["seed"] as? Int, seed)
        return summary
    }

    /// A number at a dotted path, such as "memory.peakMB".
    static func number(_ object: [String: Any], _ path: String) -> Double? {
        var node: Any? = object
        for key in path.split(separator: ".") { node = (node as? [String: Any])?[String(key)] }
        return (node as? NSNumber)?.doubleValue
    }

    /// On the simulator the app's data container sits beside this runner's own.
    @MainActor private func summaryFile(prefix: String, after date: Date, timeout: TimeInterval) -> URL? {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let manager = FileManager.default
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for container in (try? manager.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)) ?? [] {
                let folder = container.appendingPathComponent("Library/Caches/IlyichPerf", isDirectory: true)
                let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                let fresh = files.filter { file in
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    return file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "json" && (modified ?? .distantPast) > date
                }
                if let newest = fresh.max(by: { $0.lastPathComponent < $1.lastPathComponent }) { return newest }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        } while Date() < deadline
        let listed = (try? manager.contentsOfDirectory(atPath: containers.path))?.count
        print("PERF SUMMARY missing; \(containers.path) lists \(listed.map(String.init) ?? "nothing")")
        return nil
    }
}

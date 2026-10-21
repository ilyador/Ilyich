import XCTest
@testable import Ilyich

final class PerfRecorderTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000
    private let frame = 1.0 / 120

    func testPercentilesUseTheNearestRank() {
        let stats = PerfSummary.stats(milliseconds: (1...100).map(Double.init).shuffled())
        XCTAssertEqual(stats, PerfSummary.Stats(count: 100, p50: 50, p95: 95, p99: 99, max: 100))
        XCTAssertEqual(PerfSummary.stats(milliseconds: [4, 1, 3, 2]), PerfSummary.Stats(count: 4, p50: 2, p95: 4, p99: 4, max: 4))
        XCTAssertEqual(PerfSummary.stats(milliseconds: [7.25]), PerfSummary.Stats(count: 1, p50: 7.25, p95: 7.25, p99: 7.25, max: 7.25))
        XCTAssertEqual(PerfSummary.stats(milliseconds: []), PerfSummary.Stats(count: 0), "No samples, no percentiles.")
    }

    func testDisplaysAreSplitBySourceAndOnlyMemoryDrawsInTheSameFrame() {
        let recorder = PerfRecorder(processStart: nil, now: 0)
        for _ in 0..<8 { recorder.countBind() }
        recorder.recordDisplay(.memory, nanoseconds: 4_000)
        recorder.recordDisplay(.memory, nanoseconds: 6_000)
        recorder.recordDisplay(.memoryOther, nanoseconds: 9_000)
        for milliseconds in [12, 30, 48] { recorder.recordDisplay(.disk, nanoseconds: UInt64(milliseconds) * 1_000_000) }
        recorder.recordDisplay(.network, nanoseconds: 420_000_000)
        recorder.countPlaceholder(.sketch); recorder.countPlaceholder(.sketch); recorder.countPlaceholder(.empty)
        recorder.countPlaceholder(.awaitingMonth); recorder.countPlaceholder(.color)
        recorder.countAbandoned()
        let thumbnails = recorder.measurements(at: 10 * second).thumbnails
        XCTAssertEqual(thumbnails.binds, 8)
        XCTAssertEqual(thumbnails.sameFrameMemoryShare, 0.375, "Three of eight binds drew from memory at once.")
        XCTAssertEqual(thumbnails.display["memory"], PerfSummary.Stats(count: 2, p50: 0.004, p95: 0.006, p99: 0.006, max: 0.006))
        XCTAssertEqual(thumbnails.display["memoryOther"]?.count, 1)
        XCTAssertEqual(thumbnails.display["disk"], PerfSummary.Stats(count: 3, p50: 30, p95: 48, p99: 48, max: 48))
        XCTAssertEqual(thumbnails.display["network"]?.p50, 420)
        XCTAssertEqual(thumbnails.placeholders, .init(sketch: 2, empty: 1, awaitingMonth: 1, color: 1, total: 5))
        XCTAssertEqual(thumbnails.abandoned, 1)
    }

    func testTheHitchRatioIsHitchTimePerSecondOfTheWindow() {
        let recorder = PerfRecorder(processStart: nil, now: 0)
        recorder.recordFrame(hitch: 10 * frame, frameDuration: frame)
        recorder.beginWindow(at: 5 * second)
        for _ in 0..<1_200 { recorder.recordFrame(hitch: 0, frameDuration: frame) }
        recorder.recordFrame(hitch: 2 * frame, frameDuration: frame)
        recorder.recordFrame(hitch: frame, frameDuration: frame)
        let hitches = recorder.measurements(at: 15 * second).hitches
        XCTAssertEqual(hitches.frames, 1_202, "The window drops what came before it.")
        XCTAssertEqual(hitches.frameRate, 120)
        XCTAssertEqual(hitches.count, 2)
        XCTAssertEqual(hitches.totalMs, 25, accuracy: 0.001)
        XCTAssertEqual(hitches.ratioMsPerSecond, 2.5, accuracy: 0.001, "25 ms of hitches over 10 s.")
        XCTAssertEqual(hitches.longestMs, 16.667, accuracy: 0.001)
    }

    /// A callback `frames` refreshes after the previous one's, run `callback` frames after it.
    private func next(after previous: PerfHitch.Frame, refreshes: Double, callback: Double, duration: Double? = nil) -> PerfHitch.Frame {
        let duration = duration ?? previous.duration
        let timestamp = previous.timestamp + refreshes * previous.duration
        return PerfHitch.Frame(timestamp: timestamp, target: timestamp + duration, callbackAt: previous.callbackAt + callback * previous.duration)
    }

    func testAFrameIsLateByTheRefreshesItMissed() {
        // The simulator runs callbacks some 33 ms after their refresh; only changes count.
        let start = PerfHitch.Frame(timestamp: 100, target: 100 + frame, callbackAt: 100.033)
        XCTAssertEqual(PerfHitch.hitch(next(after: start, refreshes: 1, callback: 1), after: start), 0, "On time.")
        XCTAssertEqual(PerfHitch.hitch(next(after: start, refreshes: 1, callback: 1.3), after: start), 0, "Scheduling noise.")
        XCTAssertEqual(PerfHitch.hitch(next(after: start, refreshes: 1, callback: 1.6), after: start), frame, accuracy: 1e-9,
                       "The main thread overran its frame without a refresh being skipped.")
        XCTAssertEqual(PerfHitch.hitch(next(after: start, refreshes: 3, callback: 3.1), after: start), 3 * frame, accuracy: 1e-9,
                       "Two refreshes skipped, and the callback came late after the second.")
        let late = PerfHitch.Frame(timestamp: 100, target: 100 + frame, callbackAt: 100.033 + 0.9 * frame)
        XCTAssertEqual(PerfHitch.hitch(next(after: late, refreshes: 2, callback: 1.1), after: late), frame, accuracy: 1e-9,
                       "After a late callback, a skipped refresh still counts.")
        let slow = PerfHitch.Frame(timestamp: 100, target: 100 + 1.0 / 60, callbackAt: 100.001)
        XCTAssertEqual(PerfHitch.hitch(next(after: slow, refreshes: 6, callback: 6.2), after: slow), 0.1, accuracy: 1e-9,
                       "A long stall at 60 Hz: six frames.")
        let broken = PerfHitch.Frame(timestamp: 100, target: 100, callbackAt: 100)
        XCTAssertEqual(PerfHitch.hitch(next(after: broken, refreshes: 1, callback: 1, duration: 0), after: broken), 0)
    }

    func testTheFootprintTwoSecondsAfterATrimIsReported() {
        let recorder = PerfRecorder(processStart: nil, now: 0)
        let megabyte: UInt64 = 1_048_576
        recorder.recordFootprint(500 * megabyte, at: 0)
        recorder.beginWindow(at: second)
        // 300 MB until the trim at 4 s, then 200 MB from 5.75 s.
        for quarter in 4..<40 {
            let time = UInt64(quarter) * second / 4
            recorder.recordFootprint(time < 23 * second / 4 ? 300 * megabyte : 200 * megabyte, at: time)
        }
        recorder.markTrim(at: 4 * second)
        let memory = recorder.measurements(at: 10 * second).memory
        XCTAssertEqual(memory.samples, 36)
        XCTAssertEqual(memory.peakMB, 300)
        XCTAssertEqual(memory.processPeakMB, 500, "The launch's peak stays.")
        XCTAssertEqual(memory.startMB, 300)
        XCTAssertEqual(memory.endMB, 200)
        XCTAssertEqual(memory.trims, [.init(atSeconds: 3, beforeMB: 300, after2sMB: 200)])
    }

    func testAHangAcrossTheBackgroundIsSuspensionNotAHang() {
        let recorder = PerfRecorder(processStart: nil, now: 0)
        let generation = recorder.foregroundGeneration() ?? -1
        recorder.recordHang(nanoseconds: 400_000_000, generation: generation)
        recorder.setForeground(false)
        XCTAssertNil(recorder.foregroundGeneration())
        recorder.setForeground(true)
        recorder.recordHang(nanoseconds: 9 * second, generation: generation)
        let hangs = recorder.measurements(at: 20 * second).hangs
        XCTAssertEqual(hangs.count, 1)
        XCTAssertEqual(hangs.longestMs, 400)
    }

    func testFirstContentCountsFromTheProcessStartAndOutlastsTheWindow() {
        let recorder = PerfRecorder(processStart: second, now: second + 150_000_000)
        XCTAssertTrue(recorder.markFirstContent(at: 2 * second))
        XCTAssertFalse(recorder.markFirstContent(at: 3 * second), "Only the first frame counts.")
        recorder.beginWindow(at: 10 * second)
        let measurements = recorder.measurements(at: 20 * second)
        XCTAssertEqual(measurements.launch, .init(firstContentMs: 1_000, armedMs: 150))
        XCTAssertEqual(measurements.window, .init(seconds: 10, fromLaunch: false))

        // iOS may start the process long before the launch; then the launch counts from init.
        let prewarmed = PerfRecorder(processStart: 0, prewarmed: true, now: 30 * second)
        prewarmed.markFirstContent(at: 30 * second + 800_000_000)
        XCTAssertEqual(prewarmed.measurements(at: 40 * second).launch, .init(firstContentMs: 800, armedMs: nil, prewarmed: true))
    }

    func testMonthsAndPassesAreGroupedByBackendAndOutcome() {
        let recorder = PerfRecorder(processStart: nil, now: 0)
        recorder.recordMonth(backend: "index", nanoseconds: 4_000_000, succeeded: true)
        recorder.recordMonth(backend: "index", nanoseconds: 6_000_000, succeeded: true)
        recorder.recordMonth(backend: "serverTimeline", nanoseconds: 180_000_000, succeeded: true)
        recorder.recordMonth(backend: "serverTimeline", nanoseconds: 30_000_000, succeeded: false)
        recorder.countCommit()
        recorder.recordSyncPass(nanoseconds: 1_200_000_000, outcome: "completed")
        recorder.recordSyncPass(nanoseconds: 10_000_000, outcome: "cancelled")
        let measurements = recorder.measurements(at: second)
        XCTAssertEqual(measurements.feed.month["index"], PerfSummary.Stats(count: 2, p50: 4, p95: 6, p99: 6, max: 6))
        XCTAssertEqual(measurements.feed.month["serverTimeline"]?.max, 180)
        XCTAssertEqual(measurements.feed.failed, 1)
        XCTAssertEqual(measurements.feed.commits, 1)
        XCTAssertEqual(measurements.sync.passes.count, 2)
        XCTAssertEqual(measurements.sync.outcomes, ["completed": 1, "cancelled": 1])
    }
}

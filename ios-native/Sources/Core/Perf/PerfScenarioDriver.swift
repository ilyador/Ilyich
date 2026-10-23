import Foundation
import os
import UIKit

/// The scenario named on the command line:
/// -IlyichPerfScenario <name> [-IlyichPerfSeed <n>] [-IlyichPerfDrive baseline|finger].
struct PerfScenarioConfiguration: Equatable, Sendable {
    enum Scenario: String, CaseIterable, Sendable {
        case railRandom = "rail-random"
        case railSweep = "rail-sweep"
        case fling
        case reverse
        case relaunchCheck = "relaunch-check"
        case memoryWarning = "memory-warning"
        case backgroundLoad = "background-load"
    }

    /// How the scenarios move the grid.
    enum Drive: String, CaseIterable, Sendable {
        /// As C4's driver did, so every build's numbers compare with the C4 baseline: a rail scrub
        /// moves the grid with nothing drawn over it, and a fling's landing is not known ahead.
        case baseline
        /// As a finger does: the rail opens its lens and column, follows the month with its haptics
        /// and shows the lens's photos, and a fling's landing is known as it lets go, as UIKit
        /// reports it. It measures more than C4's baseline did, so compare it only with itself.
        case finger
    }

    static let scenarioArgument = "-IlyichPerfScenario"
    static let seedArgument = "-IlyichPerfSeed"
    static let driveArgument = "-IlyichPerfDrive"
    static let defaultSeed: UInt64 = 7

    let scenario: Scenario
    let seed: UInt64
    let drive: Drive

    init(scenario: Scenario, seed: UInt64 = Self.defaultSeed, drive: Drive = .baseline) {
        self.scenario = scenario
        self.seed = seed
        self.drive = drive
    }

    /// Nil, which leaves the app inert, unless the arguments name a known scenario. A missing or
    /// unreadable seed or drive is the default.
    init?(arguments: [String]) {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard let name = value(after: Self.scenarioArgument), let scenario = Scenario(rawValue: name) else { return nil }
        self.init(scenario: scenario, seed: value(after: Self.seedArgument).flatMap { UInt64($0) } ?? Self.defaultSeed,
                  drive: value(after: Self.driveArgument).flatMap(Drive.init(rawValue:)) ?? .baseline)
    }
}

/// A scenario's moves come from its seed alone, so every build replays the same ones.
enum PerfScenarioPlan {
    static let jumpCount = 20

    /// Where each rail-random jump lands on the rail, from 0, the newest photos, to 1.
    static func jumps(seed: UInt64, count: Int = jumpCount) -> [Double] {
        var generator = SplitMix64(seed: seed)
        return (0..<count).map { _ in generator.nextUnit() }
    }

    /// Starting speeds of flings, in screens per second, from a stream of their own.
    static func flingSpeeds(seed: UInt64, count: Int, in range: ClosedRange<Double>) -> [Double] {
        var generator = SplitMix64(seed: seed ^ 0x9E37_79B9_7F4A_7C15)
        return (0..<count).map { _ in range.lowerBound + generator.nextUnit() * (range.upperBound - range.lowerBound) }
    }
}

/// SplitMix64, written out so a seed means the same moves on every OS and toolchain.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double { Double(next() >> 11) * 0x1.0p-53 }
}

/// Runs one perf scenario on the real grid and writes what the recorder measured to
/// Library/Caches/IlyichPerf, where scripts/perf/record.sh fetches it. It ships in every build
/// and does nothing unless the app was launched with -IlyichPerfScenario. It moves the grid only
/// as the time rail and a scroll do, through the grid's viewport (T4): by default as C4's driver
/// did, so the numbers compare with its baseline, and with -IlyichPerfDrive finger through the
/// rail's controller as a finger scrubs, the lens and the column following, and with each fling's
/// landing told as UIKit tells it. It never changes the library or the server: no backup, upload,
/// deletion or edit.
@MainActor final class PerfScenarioDriver {
    static let shared: PerfScenarioDriver? = PerfRecorder.shared.flatMap { recorder in
        PerfScenarioConfiguration(arguments: ProcessInfo.processInfo.arguments)
            .map { PerfScenarioDriver(configuration: $0, recorder: recorder) }
    }

    /// First content is the first grid frame with this many real thumbnails, or with every
    /// visible cell of a smaller library.
    static let firstContentThumbnails = 12
    static let firstContentTimeout: Duration = .seconds(120)
    /// Launch work settles before a scenario starts.
    static let settle: Duration = .seconds(8)
    /// How long each jump is looked at.
    static let dwell: Duration = .milliseconds(1_500)
    static let sweepSeconds = 20.0
    /// UIScrollView's normal deceleration: a fling keeps this share of its speed each millisecond.
    static let decelerationRate = 0.998
    /// A fling coasts until it is slower than this, in screens per second.
    static let stopSpeed = 0.05

    private enum Status: String { case completed, noFirstContent, noGrid }

    /// What ran beside background-load, sampled before each jump.
    private struct BackgroundTally {
        let backupAtStart: Bool
        let queuedAtStart: Int
        /// `warmer` counts samples with coverage at work; the summary keeps the field's old name.
        var samples = 0, backup = 0, syncing = 0, warmer = 0
    }

    let configuration: PerfScenarioConfiguration
    let recorder: PerfRecorder
    private let frames: PerfFrameClock
    private let memory: MemorySampler
    private let watchdog: HangWatchdog
    /// The library's grid: its feed, how it moves and its rail.
    private struct Grid {
        let store: LibraryStore
        let viewport: GridViewport
        let rail: TimeRailController
        var scroller: GridScrollController { viewport.scroller }
    }

    private weak var store: LibraryStore?
    private weak var session: AccountSession?
    private weak var viewport: GridViewport?
    private weak var rail: TimeRailController?
    private var task: Task<Void, Never>?
    private var launchInterval: OSSignpostIntervalState?
    private var launchedAt = Date()
    private var thermalAtStart = ProcessInfo.processInfo.thermalState
    private var background: BackgroundTally?
    private static let log = Logger(subsystem: PerfSignpost.subsystem, category: PerfSignpost.Category.perf)

    private init(configuration: PerfScenarioConfiguration, recorder: PerfRecorder) {
        self.configuration = configuration
        self.recorder = recorder
        frames = PerfFrameClock(recorder: recorder)
        memory = MemorySampler(recorder: recorder)
        watchdog = HangWatchdog(recorder: recorder)
    }

    /// Starts measuring before the app's first frame. Does nothing without -IlyichPerfScenario.
    static func arm() { shared?.start() }

    /// The library's store, session, grid motion and rail, once the library is on screen.
    func attach(store: LibraryStore, session: AccountSession, viewport: GridViewport, rail: TimeRailController) {
        self.store = store
        self.session = session
        self.viewport = viewport
        self.rail = rail
    }

    private func start() {
        guard task == nil else { return }
        launchedAt = Date()
        frames.onFrame = { [weak self] _ in self?.checkFirstContent() }
        frames.start(); memory.start(); watchdog.start()
        let signposter = PerfSignpost.launch
        if signposter.isEnabled { launchInterval = signposter.beginInterval(PerfSignpost.launchFirstContent) }
        say("PERF ARMED \(configuration.scenario.rawValue) seed \(configuration.seed) drive \(configuration.drive.rawValue)")
        task = Task { await run() }
    }

    private func run() async {
        guard await firstContent() else { return await finish(.noFirstContent) }
        try? await Task.sleep(for: Self.settle)
        guard let store, let viewport, let rail, viewport.scroller.collection != nil else { return await finish(.noGrid) }
        let grid = Grid(store: store, viewport: viewport, rail: rail)
        say("PERF READY \(configuration.scenario.rawValue)")
        // relaunch-check measures the launch itself; the others what follows READY.
        if configuration.scenario != .relaunchCheck { recorder.beginWindow() }
        thermalAtStart = ProcessInfo.processInfo.thermalState
        let signposter = PerfSignpost.perf
        let interval = signposter.isEnabled ? signposter.beginInterval(PerfSignpost.perfScenario, "\(self.configuration.scenario.rawValue, privacy: .public)") : nil
        await perform(grid)
        if let interval { signposter.endInterval(PerfSignpost.perfScenario, interval) }
        await finish(grid.scroller.collection == nil ? .noGrid : .completed)
    }

    // MARK: Launch

    private func firstContent() async -> Bool {
        let deadline = ContinuousClock.now + Self.firstContentTimeout
        while !recorder.hasFirstContent {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// Checked on every frame until it holds.
    private func checkFirstContent() {
        guard let collection = viewport?.scroller.collection else { return }
        let cells = collection.visibleCells
        guard !cells.isEmpty else { return }
        let real = cells.count { ($0 as? PhotoCell)?.showsThumbnail == true }
        guard real >= min(Self.firstContentThumbnails, cells.count), recorder.markFirstContent() else { return }
        frames.onFrame = nil
        if let launchInterval {
            PerfSignpost.launch.endInterval(PerfSignpost.launchFirstContent, launchInterval)
            self.launchInterval = nil
        }
    }

    // MARK: Scenarios

    private func perform(_ grid: Grid) async {
        switch configuration.scenario {
        case .railRandom: await railRandom(grid)
        case .railSweep: await railSweep(grid)
        case .fling: await flings(grid)
        case .reverse: await reversals(grid)
        case .relaunchCheck: break
        case .memoryWarning:
            await railSweep(grid)
            try? await Task.sleep(for: .seconds(1))
            trimMemory()
            // The footprint reported is the first sample 2 s after the trim.
            try? await Task.sleep(for: .milliseconds(2_500))
            await railRandom(grid)
        case .backgroundLoad:
            await railRandom(grid) { self.sampleBackground() }
        }
    }

    /// Seeded jumps along the rail, each looked at while its photos load.
    private func railRandom(_ grid: Grid, beforeEachJump: () -> Void = {}) async {
        for fraction in PerfScenarioPlan.jumps(seed: configuration.seed) {
            guard !Task.isCancelled else { return }
            beforeEachJump()
            await jump(grid, to: fraction)
            try? await Task.sleep(for: Self.dwell)
        }
    }

    /// The rail from the newest photos to the oldest at an even pace, a step every frame.
    private func railSweep(_ grid: Grid) async {
        beginScrub(grid, at: 0)
        let start = await frames.next()
        var progress = 0.0
        while progress < 1, !Task.isCancelled {
            let time = await frames.next()
            progress = min(1, (time - start) / Self.sweepSeconds)
            scrub(grid, to: CGFloat(progress))
        }
        endScrub(grid)
        try? await Task.sleep(for: Self.dwell)
    }

    /// Flings down the library at seeded speeds, each coasting to a stop.
    private func flings(_ grid: Grid) async {
        await jump(grid, to: 0.15)
        try? await Task.sleep(for: Self.dwell)
        for speed in PerfScenarioPlan.flingSpeeds(seed: configuration.seed, count: 10, in: 3...9) {
            guard !Task.isCancelled else { return }
            await fling(grid, screensPerSecond: speed)
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: Self.dwell)
    }

    /// Down, then straight back up through the photos just passed, again and again, each flick
    /// caught before it stops.
    private func reversals(_ grid: Grid) async {
        await jump(grid, to: 0.3)
        try? await Task.sleep(for: Self.dwell)
        var coasting = false
        for (index, speed) in PerfScenarioPlan.flingSpeeds(seed: configuration.seed, count: 24, in: 4...8).enumerated() {
            guard !Task.isCancelled else { break }
            coasting = await fling(grid, screensPerSecond: index.isMultiple(of: 2) ? speed : -speed, for: 0.7)
        }
        if coasting {
            // The last flick is caught too, and the finger lifts without moving.
            grid.viewport.willBeginDragging()
            grid.viewport.didEndDragging(decelerate: false)
        }
        try? await Task.sleep(for: Self.dwell)
    }

    /// What the rail does for a finger: it holds coverage, drops pending navigation and moves
    /// the grid.
    private func jump(_ grid: Grid, to fraction: Double) async {
        beginScrub(grid, at: CGFloat(fraction))
        _ = await frames.next()
        endScrub(grid)
    }

    /// A rail scrub starts at `fraction` of the way down the library. With the finger drive the
    /// rail's controller scrubs as a finger does once the rail is open, the lens following;
    /// otherwise the grid alone moves, as C4's driver moved it, with nothing drawn over it.
    private func beginScrub(_ grid: Grid, at fraction: CGFloat) {
        switch configuration.drive {
        case .finger:
            grid.rail.beginDrivenScrub(atFraction: fraction)
        case .baseline:
            RailScrubProbe.began()
            grid.viewport.beginScrub()
            grid.store.cancelPendingNavigation()
            grid.viewport.scrub(toFraction: fraction)
        }
    }

    private func scrub(_ grid: Grid, to fraction: CGFloat) {
        switch configuration.drive {
        case .finger: grid.rail.drive(toFraction: fraction)
        case .baseline: grid.viewport.scrub(toFraction: fraction)
        }
    }

    private func endScrub(_ grid: Grid) {
        switch configuration.drive {
        case .finger:
            grid.rail.endDrivenScrub()
        case .baseline:
            grid.viewport.endScrub()
            RailScrubProbe.ended()
        }
    }

    /// One fling, slowing as UIScrollView's normal deceleration does, moved through the same
    /// offset path the rail drives and told to the viewport as UIKit tells a fling: the drag
    /// begins, ends, and the coast ends. Only the finger drive tells its velocity and landing as
    /// the drag ends, as UIKit does; C4's driver never did, so by default the landing screen is not
    /// known ahead. A fling cut short by `limit` is caught by the next drag, as a flick is, and
    /// returns true: it is still coasting. Positive speeds go down the library, toward older photos.
    @discardableResult
    private func fling(_ grid: Grid, screensPerSecond speed: Double, for limit: Double = .infinity) async -> Bool {
        let scroller = grid.scroller
        guard let collection = scroller.collection, let height = scroller.scrollableHeight, height > 0,
              let current = scroller.fraction else { return false }
        let screen = Double(collection.bounds.height)
        var fraction = Double(current), velocity = speed * screen
        let signposter = PerfSignpost.scrub
        let interval = signposter.isEnabled ? signposter.beginInterval(PerfSignpost.gridFling) : nil
        // As a drag starting does.
        grid.store.cancelPendingNavigation()
        grid.viewport.willBeginDragging()
        if configuration.drive == .finger {
            // Where the coast would end, as UIKit says when the finger lets go: velocity in points
            // per millisecond times rate / (1 - rate).
            let landing = min(1, max(0, fraction + velocity / 1_000 * Self.decelerationRate / (1 - Self.decelerationRate) / Double(height)))
            grid.viewport.willEndDragging(velocity: CGPoint(x: 0, y: velocity / 1_000),
                                          target: CGPoint(x: 0, y: scroller.offset(atFraction: CGFloat(landing)) ?? collection.contentOffset.y))
        }
        grid.viewport.didEndDragging(decelerate: true)
        let start = await frames.next()
        var last = start
        var coasting = true
        while !Task.isCancelled {
            let now = await frames.next()
            let elapsed = now - last
            last = now
            fraction = min(1, max(0, fraction + velocity * elapsed / Double(height)))
            scroller.scroll(toFraction: CGFloat(fraction))
            velocity *= pow(Self.decelerationRate, elapsed * 1_000)
            if abs(velocity) < Self.stopSpeed * screen || fraction <= 0 || fraction >= 1 { coasting = false; break }
            if now - start >= limit { break }
        }
        if !coasting || Task.isCancelled { grid.viewport.didEndDecelerating() }
        if let interval { signposter.endInterval(PerfSignpost.gridFling, interval) }
        return coasting && !Task.isCancelled
    }

    /// The app's own memory-pressure path: the notification iOS posts with a memory warning.
    private func trimMemory() {
        recorder.markTrim()
        say("PERF TRIM")
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
    }

    /// Only reads what is running; starting a backup or anything else is never the driver's.
    private func sampleBackground() {
        let backup = BackupStore.shared
        var tally = background ?? BackgroundTally(backupAtStart: backup.isRunning, queuedAtStart: backup.remaining)
        tally.samples += 1
        if backup.isRunning { tally.backup += 1 }
        if session?.isSyncing == true { tally.syncing += 1 }
        if session?.coverage?.isRunning == true { tally.warmer += 1 }
        background = tally
    }

    // MARK: Summary

    private func finish(_ status: Status) async {
        let end = perfNow()
        frames.stop(); memory.stop(); watchdog.stop()
        if let launchInterval {
            PerfSignpost.launch.endInterval(PerfSignpost.launchFirstContent, launchInterval, "outcome=none")
            self.launchInterval = nil
        }
        let recorder = recorder
        let measurements = await Task.detached(priority: .utility) { recorder.measurements(at: end) }.value
        let summary = PerfSummary(
            scenario: configuration.scenario.rawValue, seed: configuration.seed,
            drive: configuration.drive == .baseline ? nil : configuration.drive.rawValue, status: status.rawValue,
            startedAt: launchedAt.formatted(.iso8601), app: Self.app(), device: device(), library: library(),
            measurements: measurements, background: background.map { tally in
                func share(_ count: Int) -> Double { tally.samples == 0 ? 0 : PerfSummary.rounded(Double(count) / Double(tally.samples)) }
                return PerfSummary.Background(samples: tally.samples, backupRunningAtStart: tally.backupAtStart, queuedAtStart: tally.queuedAtStart,
                                              backupRunningShare: share(tally.backup), syncingShare: share(tally.syncing),
                                              warmerRunningShare: share(tally.warmer))
            })
        let name = "\(configuration.scenario.rawValue)-\(configuration.seed)-\(Self.stamp(launchedAt)).json"
        do {
            try await Task.detached(priority: .utility) { try Self.write(summary, name: name) }.value
            say("PERF DONE \(Self.folder)/\(name)")
        } catch {
            say("PERF FAILED \(error.localizedDescription)")
        }
    }

    /// Where summaries go, relative to the app's data container.
    nonisolated static let folder = "Library/Caches/IlyichPerf"

    nonisolated static func write(_ summary: PerfSummary, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("IlyichPerf", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// A UTC time that sorts as text, such as 20261020T201500Z.
    nonisolated static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    private nonisolated static func app() -> PerfSummary.App {
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        return PerfSummary.App(version: info["CFBundleShortVersionString"] as? String ?? "",
                               build: info["CFBundleVersion"] as? String ?? "", configuration: configuration)
    }

    private func device() -> PerfSummary.Device {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let process = ProcessInfo.processInfo
        return PerfSummary.Device(
            model: process.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine,
            system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            physicalMemoryMB: PerfSummary.rounded(Double(process.physicalMemory) / 1_048_576),
            maximumFramesPerSecond: viewport?.scroller.collection?.window?.windowScene?.screen.maximumFramesPerSecond ?? 0,
            lowPowerMode: process.isLowPowerModeEnabled,
            thermalStateAtStart: Self.name(thermalAtStart), thermalStateAtEnd: Self.name(process.thermalState))
    }

    private func library() -> PerfSummary.Library? {
        guard let store else { return nil }
        let columns = (viewport?.scroller.collection?.collectionViewLayout as? VirtualPhotoLayout)?.columns ?? 0
        return PerfSummary.Library(months: store.buckets.count, photos: store.totalCount, columns: columns)
    }

    private static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// To the unified log, and to stdout for `devicectl device process launch --console`.
    private func say(_ line: String) {
        Self.log.notice("\(line, privacy: .public)")
        print(line)
    }
}

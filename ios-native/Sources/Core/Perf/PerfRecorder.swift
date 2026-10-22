import Darwin
import Foundation
import Synchronization

/// Nanoseconds on the uptime clock, the timebase of CACurrentMediaTime and the display link.
func perfNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// Where a cell's first real thumbnail came from.
enum ThumbSource: Int, CaseIterable, Sendable {
    /// Memory, at the cell's size, in the bind's own frame.
    case memory
    /// Memory, the photo's newest decode at another size, in the bind's own frame.
    case memoryOther
    case disk
    case network
    /// Photos, for a photo only on this phone.
    case device

    var name: String {
        switch self {
        case .memory: "memory"
        case .memoryOther: "memoryOther"
        case .disk: "disk"
        case .network: "network"
        case .device: "device"
        }
    }
}

/// What a cell showed instead of a real thumbnail.
enum ThumbPlaceholder: Int, CaseIterable, Sendable {
    /// Names only grow: color came after the others.
    case sketch, empty, awaitingMonth, color

    var name: String {
        switch self {
        case .sketch: "sketch"
        case .empty: "empty"
        case .awaitingMonth: "awaitingMonth"
        case .color: "color"
        }
    }
}

/// Collects what a perf scenario measures. It exists only when the app was launched with
/// -IlyichPerfScenario; otherwise `shared` is nil and every probe returns after that one check.
/// Callers on the main thread only take a timestamp and bump a counter or append a number under
/// a lock; sorting and percentiles wait for the summary, which is worked out off the main thread.
final class PerfRecorder: Sendable {
    static let shared: PerfRecorder? = {
        let process = ProcessInfo.processInfo
        guard PerfScenarioConfiguration(arguments: process.arguments) != nil else { return nil }
        // iOS sets ActivePrewarm when it started the process ahead of a launch.
        return PerfRecorder(processStart: PerfProcess.startUptime(), prewarmed: process.environment["ActivePrewarm"] == "1")
    }()

    private struct Sample { let time: UInt64; let bytes: UInt64 }
    private struct MonthLoad { let backend: String; let nanoseconds: UInt64; let succeeded: Bool }
    private struct SyncPass { let nanoseconds: UInt64; let outcome: String }

    private struct State {
        var windowStart: UInt64
        var fromLaunch = true
        /// The source in the top byte, nanoseconds below it.
        var displays: [UInt64] = []
        var binds = 0
        var placeholders = [Int](repeating: 0, count: ThumbPlaceholder.allCases.count)
        var abandoned = 0
        var failed = 0
        var frames = 0
        var frameDuration = 0.0
        /// Seconds.
        var hitches: [Double] = []
        /// Nanoseconds.
        var hangs: [UInt64] = []
        var memory: [Sample] = []
        var trims: [UInt64] = []
        var months: [MonthLoad] = []
        var commits = 0
        var syncPasses: [SyncPass] = []
        var scrubs = 0
        var scrubNanoseconds: UInt64 = 0
        // Kept when the window starts.
        var firstContent: UInt64?
        var processPeak: UInt64 = 0
        var foreground = true
        var foregroundGeneration = 0

        init(windowStart: UInt64) {
            self.windowStart = windowStart
            displays.reserveCapacity(1 << 15)
        }
    }

    /// The process start on the uptime clock, when the system says.
    let processStart: UInt64?
    /// iOS started the process ahead of the launch, so its start says nothing about the launch.
    let prewarmed: Bool
    let armed: UInt64
    private let state: Mutex<State>

    init(processStart: UInt64?, prewarmed: Bool = false, now: UInt64 = perfNow()) {
        self.processStart = processStart
        self.prewarmed = prewarmed
        armed = now
        state = Mutex(State(windowStart: now))
    }

    // MARK: Thumbnails, from the grid's cells

    func countBind() { state.withLock { $0.binds += 1 } }

    func recordDisplay(_ source: ThumbSource, nanoseconds: UInt64) {
        state.withLock { $0.displays.append(UInt64(source.rawValue) << 56 | min(nanoseconds, (1 << 56) - 1)) }
    }

    func countPlaceholder(_ kind: ThumbPlaceholder) { state.withLock { $0.placeholders[kind.rawValue] += 1 } }
    func countAbandoned() { state.withLock { $0.abandoned += 1 } }
    func countFailed() { state.withLock { $0.failed += 1 } }

    // MARK: Frames and hangs

    /// One display link callback, and how late it found the frame before it.
    func recordFrame(hitch: Double, frameDuration: Double) {
        state.withLock { state in
            state.frames += 1
            state.frameDuration = frameDuration
            if hitch > 0 { state.hitches.append(hitch) }
        }
    }

    /// The app moved between the foreground and the background. Suspension is not a hang.
    func setForeground(_ foreground: Bool) {
        state.withLock { state in
            guard state.foreground != foreground else { return }
            state.foreground = foreground; state.foregroundGeneration += 1
        }
    }

    /// Nil while the app is in the background; a hang counts only if it is the same afterwards.
    func foregroundGeneration() -> Int? {
        state.withLock { $0.foreground ? $0.foregroundGeneration : nil }
    }

    func recordHang(nanoseconds: UInt64, generation: Int) {
        state.withLock { state in
            guard state.foreground, state.foregroundGeneration == generation else { return }
            state.hangs.append(nanoseconds)
        }
    }

    // MARK: Memory

    func recordFootprint(_ bytes: UInt64, at time: UInt64 = perfNow()) {
        state.withLock { state in
            state.memory.append(Sample(time: time, bytes: bytes))
            state.processPeak = max(state.processPeak, bytes)
        }
    }

    /// The app's memory-pressure trim ran now.
    func markTrim(at time: UInt64 = perfNow()) { state.withLock { $0.trims.append(time) } }

    // MARK: Feed, sync and scrubbing

    func recordMonth(backend: String, nanoseconds: UInt64, succeeded: Bool) {
        state.withLock { $0.months.append(MonthLoad(backend: backend, nanoseconds: nanoseconds, succeeded: succeeded)) }
    }

    func countCommit() { state.withLock { $0.commits += 1 } }

    func recordSyncPass(nanoseconds: UInt64, outcome: String) {
        state.withLock { $0.syncPasses.append(SyncPass(nanoseconds: nanoseconds, outcome: outcome)) }
    }

    func recordScrub(nanoseconds: UInt64) {
        state.withLock { state in state.scrubs += 1; state.scrubNanoseconds += nanoseconds }
    }

    // MARK: Launch and window

    /// Returns false if first content was already marked.
    @discardableResult func markFirstContent(at time: UInt64 = perfNow()) -> Bool {
        state.withLock { state in
            guard state.firstContent == nil else { return false }
            state.firstContent = time
            return true
        }
    }

    var hasFirstContent: Bool { state.withLock { $0.firstContent != nil } }

    /// Starts the measured window here, dropping all but the launch from before it.
    func beginWindow(at time: UInt64 = perfNow()) {
        state.withLock { state in
            var fresh = State(windowStart: time)
            fresh.fromLaunch = false
            fresh.firstContent = state.firstContent
            fresh.processPeak = state.processPeak
            fresh.foreground = state.foreground
            fresh.foregroundGeneration = state.foregroundGeneration
            state = fresh
        }
    }

    // MARK: Summary

    /// Everything measured from the window's start to `end`.
    func measurements(at end: UInt64 = perfNow()) -> PerfSummary.Measurements {
        let state = self.state.withLock { $0 }
        let seconds = Double(end &- state.windowStart) / 1e9
        func milliseconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1e6 }
        func megabytes(_ bytes: UInt64) -> Double { PerfSummary.rounded(Double(bytes) / 1_048_576) }

        var bySource = [[Double]](repeating: [], count: ThumbSource.allCases.count)
        for display in state.displays {
            bySource[Int(display >> 56)].append(milliseconds(display & ((1 << 56) - 1)))
        }
        var display: [String: PerfSummary.Stats] = [:]
        for source in ThumbSource.allCases { display[source.name] = PerfSummary.stats(milliseconds: bySource[source.rawValue]) }
        let sameFrame = bySource[ThumbSource.memory.rawValue].count + bySource[ThumbSource.memoryOther.rawValue].count
        let placeholders = PerfSummary.Thumbnails.Placeholders(
            sketch: state.placeholders[ThumbPlaceholder.sketch.rawValue], empty: state.placeholders[ThumbPlaceholder.empty.rawValue],
            awaitingMonth: state.placeholders[ThumbPlaceholder.awaitingMonth.rawValue],
            color: state.placeholders[ThumbPlaceholder.color.rawValue], total: state.placeholders.reduce(0, +))
        let thumbnails = PerfSummary.Thumbnails(
            binds: state.binds, sameFrameMemoryShare: state.binds == 0 ? 0 : PerfSummary.rounded(Double(sameFrame) / Double(state.binds)),
            display: display, placeholders: placeholders, abandoned: state.abandoned, failed: state.failed)

        let hitchTotal = state.hitches.reduce(0, +) * 1_000
        let hitches = PerfSummary.Hitches(
            frames: state.frames, frameRate: state.frameDuration > 0 ? (1 / state.frameDuration).rounded() : 0,
            count: state.hitches.count, totalMs: PerfSummary.rounded(hitchTotal),
            ratioMsPerSecond: seconds > 0 ? PerfSummary.rounded(hitchTotal / seconds) : 0,
            longestMs: PerfSummary.rounded((state.hitches.max() ?? 0) * 1_000))

        let hangDurations = state.hangs.map(milliseconds)
        let hangs = PerfSummary.Hangs(count: hangDurations.count, totalMs: PerfSummary.rounded(hangDurations.reduce(0, +)),
                                      longestMs: PerfSummary.rounded(hangDurations.max() ?? 0),
                                      durationsMs: hangDurations.prefix(50).map(PerfSummary.rounded))

        let trims = state.trims.map { trim in
            PerfSummary.Memory.Trim(atSeconds: PerfSummary.rounded(Double(trim &- state.windowStart) / 1e9),
                                    beforeMB: state.memory.last { $0.time <= trim }.map { megabytes($0.bytes) },
                                    after2sMB: state.memory.first { $0.time >= trim + 2_000_000_000 }.map { megabytes($0.bytes) })
        }
        let memory = PerfSummary.Memory(
            samples: state.memory.count, startMB: state.memory.first.map { megabytes($0.bytes) },
            endMB: state.memory.last.map { megabytes($0.bytes) }, peakMB: state.memory.map(\.bytes).max().map(megabytes),
            processPeakMB: state.processPeak > 0 ? megabytes(state.processPeak) : nil, trims: trims)

        var months: [String: [Double]] = [:]
        for load in state.months where load.succeeded { months[load.backend, default: []].append(milliseconds(load.nanoseconds)) }
        let feed = PerfSummary.Feed(month: months.mapValues(PerfSummary.stats(milliseconds:)),
                                    failed: state.months.count { !$0.succeeded }, commits: state.commits)

        var outcomes: [String: Int] = [:]
        for pass in state.syncPasses { outcomes[pass.outcome, default: 0] += 1 }
        let sync = PerfSummary.Sync(passes: PerfSummary.stats(milliseconds: state.syncPasses.map { milliseconds($0.nanoseconds) }),
                                    outcomes: outcomes)

        // A prewarmed launch counts from the app's init, which runs once the launch is real.
        let origin = prewarmed ? armed : processStart
        let launch = PerfSummary.Launch(
            firstContentMs: origin.flatMap { start in state.firstContent.map { PerfSummary.rounded(milliseconds($0 &- start)) } },
            armedMs: prewarmed ? nil : processStart.map { PerfSummary.rounded(milliseconds(armed &- $0)) },
            prewarmed: prewarmed)
        return PerfSummary.Measurements(
            window: .init(seconds: PerfSummary.rounded(seconds), fromLaunch: state.fromLaunch), launch: launch,
            thumbnails: thumbnails, hitches: hitches, hangs: hangs, memory: memory, feed: feed, sync: sync,
            scrub: .init(strokes: state.scrubs, seconds: PerfSummary.rounded(Double(state.scrubNanoseconds) / 1e9)))
    }
}

/// How late the frame before a display link callback was shown, in whole frames. The link's own
/// timestamps show refreshes it skipped while the main thread was busy; the time between two
/// callbacks shows a main thread that overran a frame without a refresh being skipped. Each
/// alone misses some hitches, so the larger counts. Neither depends on how long after its
/// refresh a callback runs, which differs between the phone and the simulator.
enum PerfHitch {
    struct Frame: Equatable, Sendable {
        /// The refresh the callback belongs to.
        let timestamp: Double
        /// The refresh after it.
        let target: Double
        /// When the callback ran, on the same clock.
        let callbackAt: Double
        var duration: Double { target - timestamp }
    }

    static func hitch(_ frame: Frame, after previous: Frame) -> Double {
        let duration = previous.duration
        guard duration > 0 else { return 0 }
        let skipped = ((frame.timestamp - previous.target) / duration).rounded() * duration
        let late = frame.callbackAt - previous.callbackAt - duration
        // A callback under half a frame late is as likely scheduling noise as a missed frame.
        let overrun = late > duration / 2 ? (late / duration).rounded(.up) * duration : 0
        return max(0, skipped, overrun)
    }
}

/// The process's own numbers, from the kernel.
enum PerfProcess {
    /// When the process started, on the uptime clock. The kernel keeps it as wall time, so the
    /// wall clock's distance to it now is taken off the uptime clock.
    static func startUptime() -> UInt64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        var wall = timeval()
        gettimeofday(&wall, nil)
        let uptime = perfNow()
        let elapsed = (Int64(wall.tv_sec) - Int64(started.tv_sec)) * 1_000_000_000
            + (Int64(wall.tv_usec) - Int64(started.tv_usec)) * 1_000
        guard elapsed >= 0, UInt64(elapsed) < uptime else { return nil }
        return uptime - UInt64(elapsed)
    }

    /// phys_footprint: the memory iOS weighs against the app's limit.
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

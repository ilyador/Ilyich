import Foundation
import os
import QuartzCore
import Synchronization
import UIKit

/// A display link at the screen's top rate while a scenario runs. Each callback works out the
/// hitch of the frame before it, then wakes whatever waits for the next frame: the perf
/// driver's moves and its first-content check.
@MainActor final class PerfFrameClock: NSObject {
    private let recorder: PerfRecorder
    private var link: CADisplayLink?
    private var previous: PerfHitch.Frame?
    private var waiters: [CheckedContinuation<CFTimeInterval, Never>] = []
    /// Runs on every frame, before the waiters.
    var onFrame: ((CFTimeInterval) -> Void)?

    init(recorder: PerfRecorder) { self.recorder = recorder }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(enteredBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(enteringForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    func stop() {
        link?.invalidate(); link = nil
        NotificationCenter.default.removeObserver(self)
        onFrame = nil
        let waiting = waiters; waiters = []
        for waiter in waiting { waiter.resume(returning: CACurrentMediaTime()) }
    }

    /// When the next frame will be on screen; at once if the clock has stopped.
    func next() async -> CFTimeInterval {
        guard link != nil else { return CACurrentMediaTime() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let frame = PerfHitch.Frame(timestamp: link.timestamp, target: link.targetTimestamp, callbackAt: CACurrentMediaTime())
        if let previous { recorder.recordFrame(hitch: PerfHitch.hitch(frame, after: previous), frameDuration: previous.duration) }
        previous = frame
        onFrame?(link.targetTimestamp)
        let waiting = waiters; waiters = []
        for waiter in waiting { waiter.resume(returning: link.targetTimestamp) }
    }

    /// The display link pauses in the background; the first frame back is not late.
    @objc private func enteredBackground() { previous = nil; recorder.setForeground(false) }
    @objc private func enteringForeground() { previous = nil; recorder.setForeground(true) }
}

/// Reads the app's phys_footprint every 250 ms on a utility queue.
final class MemorySampler: Sendable {
    private let recorder: PerfRecorder
    private let running = Atomic<Bool>(false)
    private let queue = DispatchQueue(label: "ilyich.perf.memory", qos: .utility)

    init(recorder: PerfRecorder) { self.recorder = recorder }

    func start() {
        guard !running.exchange(true, ordering: .relaxed) else { return }
        queue.async { [self] in sample() }
    }

    func stop() { running.store(false, ordering: .relaxed) }

    private func sample() {
        guard running.load(ordering: .relaxed) else { return }
        if let bytes = PerfProcess.footprint() {
            recorder.recordFootprint(bytes)
            let signposter = PerfSignpost.memory
            if signposter.isEnabled { signposter.emitEvent(PerfSignpost.memFootprint, "bytes=\(bytes, privacy: .public)") }
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [self] in sample() }
    }
}

/// Pings the main thread from a thread of its own. A reply that takes 250 ms or longer means the
/// main thread was blocked at least that long: a hang, as Instruments counts them.
final class HangWatchdog: Sendable {
    static let threshold: DispatchTimeInterval = .milliseconds(250)
    private let recorder: PerfRecorder
    private let running = Atomic<Bool>(false)

    init(recorder: PerfRecorder) { self.recorder = recorder }

    func start() {
        guard !running.exchange(true, ordering: .relaxed) else { return }
        let thread = Thread { [self] in watch() }
        thread.name = "ilyich.perf.hang-watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { running.store(false, ordering: .relaxed) }

    private func watch() {
        while running.load(ordering: .relaxed) {
            guard let generation = recorder.foregroundGeneration() else {
                Thread.sleep(forTimeInterval: 0.25); continue
            }
            let replied = DispatchSemaphore(value: 0)
            let sent = perfNow()
            DispatchQueue.main.async { replied.signal() }
            if replied.wait(timeout: .now() + Self.threshold) == .timedOut {
                replied.wait()
                recorder.recordHang(nanoseconds: perfNow() &- sent, generation: generation)
            }
            // Often enough that a hang is measured from close to its start.
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

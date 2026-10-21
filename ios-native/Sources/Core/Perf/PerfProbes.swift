import Foundation
import os
import Synchronization

/// Times one grid cell from binding a photo to showing its first real thumbnail, and says where
/// that thumbnail came from. Without a perf scenario every call returns after one check.
struct ThumbDisplayProbe {
    /// When the open bind started; zero when none is open.
    private var start: UInt64 = 0
    private var interval: OSSignpostIntervalState?
    private var awaitingMonth = false

    /// The cell was bound to a photo, closing any bind still open.
    mutating func bind() {
        abandon()
        awaitingMonth = false
        guard let recorder = PerfRecorder.shared else { return }
        start = perfNow()
        recorder.countBind()
        let signposter = PerfSignpost.thumbnails
        if signposter.isEnabled { interval = signposter.beginInterval(PerfSignpost.thumbDisplay, id: signposter.makeSignpostID()) }
    }

    /// A real thumbnail is on screen. Only the bind's first counts: the exact size arriving after
    /// another size from memory does not.
    mutating func displayed(_ source: ThumbSource) {
        guard start != 0 else { return }
        PerfRecorder.shared?.recordDisplay(source, nanoseconds: perfNow() &- start)
        start = 0
        if let interval {
            PerfSignpost.thumbnails.endInterval(PerfSignpost.thumbDisplay, interval, "source=\(source.name, privacy: .public)")
            self.interval = nil
        }
    }

    /// The bind drew the photo's sketch, its average colour or nothing while the thumbnail is on its way.
    func placeholder(_ kind: ThumbPlaceholder) {
        guard start != 0 else { return }
        count(kind)
    }

    /// The cell waits for its photo's month to load. Counted once until the cell is bound or reused.
    mutating func awaitMonth() {
        abandon()
        guard !awaitingMonth, PerfRecorder.shared != nil else { return }
        awaitingMonth = true
        count(.awaitingMonth)
    }

    /// The cell let go of the photo before a real thumbnail came: it scrolled away or was reused.
    mutating func abandon() {
        guard start != 0 else { return }
        start = 0
        PerfRecorder.shared?.countAbandoned()
        if let interval {
            PerfSignpost.thumbnails.endInterval(PerfSignpost.thumbDisplay, interval, "source=none outcome=abandoned")
            self.interval = nil
        }
    }

    /// The thumbnail could not be loaded.
    mutating func failed() {
        guard start != 0 else { return }
        start = 0
        PerfRecorder.shared?.countFailed()
        if let interval {
            PerfSignpost.thumbnails.endInterval(PerfSignpost.thumbDisplay, interval, "source=none outcome=failed")
            self.interval = nil
        }
    }

    /// The cell is about to show another photo.
    mutating func reset() {
        abandon()
        awaitingMonth = false
    }

    private func count(_ kind: ThumbPlaceholder) {
        PerfRecorder.shared?.countPlaceholder(kind)
        let signposter = PerfSignpost.thumbnails
        if signposter.isEnabled { signposter.emitEvent(PerfSignpost.thumbPlaceholder, "kind=\(kind.name, privacy: .public)") }
    }
}

/// A finger, or the perf driver, on the time rail. Strokes never overlap.
@MainActor enum RailScrubProbe {
    private static var start: UInt64 = 0
    private static var interval: OSSignpostIntervalState?

    static func began() {
        guard PerfRecorder.shared != nil else { return }
        // A stroke whose end never came, as when the rail left the screen mid-scrub, ends here.
        ended()
        start = perfNow()
        let signposter = PerfSignpost.scrub
        if signposter.isEnabled { interval = signposter.beginInterval(PerfSignpost.railScrub) }
    }

    static func ended() {
        guard start != 0 else { return }
        PerfRecorder.shared?.recordScrub(nanoseconds: perfNow() &- start)
        start = 0
        if let interval {
            PerfSignpost.scrub.endInterval(PerfSignpost.railScrub, interval)
            self.interval = nil
        }
    }
}

/// Times a month of photos loading, tagged with the backend that answered it. The LibraryAPI
/// serving the month notes its backend on the load's task.
enum FeedMonthProbe {
    final class Note: Sendable {
        private let value = Mutex<QueryPlan.Backend?>(nil)
        func set(_ backend: QueryPlan.Backend) { value.withLock { $0 = backend } }
        var backend: QueryPlan.Backend? { value.withLock { $0 } }
    }

    /// The measured load running on this task, if any.
    @TaskLocal static var current: Note?

    /// Called by the LibraryAPI as it picks where a month comes from.
    static func note(_ backend: QueryPlan.Backend) {
        guard PerfRecorder.shared != nil else { return }
        current?.set(backend)
    }

    /// Runs one month load, measuring it while a scenario runs. A load nobody noted came from the
    /// server's timeline, which is the only backend that does not note itself.
    static func measure<T>(isolation: isolated (any Actor)? = #isolation, _ load: () async throws -> T) async throws -> T {
        guard let recorder = PerfRecorder.shared else { return try await load() }
        let note = Note(), start = perfNow()
        let signposter = PerfSignpost.feed
        let interval = signposter.isEnabled ? signposter.beginInterval(PerfSignpost.feedMonth, id: signposter.makeSignpostID()) : nil
        do {
            let value = try await $current.withValue(note) { try await load() }
            let backend = name(note.backend ?? .serverTimeline)
            recorder.recordMonth(backend: backend, nanoseconds: perfNow() &- start, succeeded: true)
            if let interval { signposter.endInterval(PerfSignpost.feedMonth, interval, "backend=\(backend, privacy: .public)") }
            return value
        } catch {
            let backend = name(note.backend ?? .serverTimeline)
            // A cancelled load is work given up, not a slow or failed month, however it ended.
            if !(error is CancellationError) && !Task.isCancelled {
                recorder.recordMonth(backend: backend, nanoseconds: perfNow() &- start, succeeded: false)
            }
            if let interval { signposter.endInterval(PerfSignpost.feedMonth, interval, "backend=\(backend, privacy: .public) outcome=failed") }
            throw error
        }
    }

    /// A loaded month reached the grid.
    static func committed() {
        guard let recorder = PerfRecorder.shared else { return }
        recorder.countCommit()
        let signposter = PerfSignpost.feed
        if signposter.isEnabled { signposter.emitEvent(PerfSignpost.feedCommit) }
    }

    static func name(_ backend: QueryPlan.Backend) -> String {
        switch backend {
        case .index: "index"
        case .serverTimeline: "serverTimeline"
        case .serverSearch: "serverSearch"
        }
    }
}

/// Times one sync pass, from its start until it has applied the server's last change or stopped.
enum SyncPassProbe {
    static func measure<T>(isolation: isolated (any Actor)? = #isolation, _ pass: () async throws -> T) async throws -> T {
        guard let recorder = PerfRecorder.shared else { return try await pass() }
        let start = perfNow()
        let signposter = PerfSignpost.sync
        let interval = signposter.isEnabled ? signposter.beginInterval(PerfSignpost.syncPass, id: signposter.makeSignpostID()) : nil
        do {
            let value = try await pass()
            recorder.recordSyncPass(nanoseconds: perfNow() &- start, outcome: "completed")
            if let interval { signposter.endInterval(PerfSignpost.syncPass, interval, "outcome=completed") }
            return value
        } catch {
            let outcome = error is CancellationError ? "cancelled" : "failed"
            recorder.recordSyncPass(nanoseconds: perfNow() &- start, outcome: outcome)
            if let interval { signposter.endInterval(PerfSignpost.syncPass, interval, "outcome=\(outcome, privacy: .public)") }
            throw error
        }
    }
}

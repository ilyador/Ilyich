import Foundation
import Synchronization

/// What Photos answered for one phone photo's thumbnail.
enum DeviceThumbnailResult: Sendable {
    case image(PreparedImage)
    /// Photos has no copy it can give: the photo is gone, or only in iCloud and the network may
    /// not be used.
    case unavailable(inCloud: Bool)
}

/// Photos' caching image manager, as the thumbnail source drives it. The app's one
/// PHCachingImageManager implements it (PhotoKitAdapter.thumbnails, Sources/Device); tests fake
/// it. Every method is called off the main thread: the caching calls on the source's own queue,
/// `thumbnail` on a decode lane, which it blocks while Photos renders.
protocol DeviceThumbnailImaging: Sendable {
    /// Photos decodes these photos ahead of their cells, aspect-filling `pixels` square, and keeps
    /// them until they are stopped.
    func startCaching(_ ids: [DeviceAssetID], pixels: Int)
    func stopCaching(_ ids: [DeviceAssetID], pixels: Int)
    func stopCachingAll()
    /// One photo's thumbnail aspect-filling `pixels` square, never from iCloud, as the grid draws
    /// it: upright, with no view to turn it.
    func thumbnail(_ id: DeviceAssetID, pixels: Int) -> DeviceThumbnailResult
}

/// Phone photos' thumbnails for the scheduler: Photos renders them, through the app's one caching
/// image manager, and this preheats the photos the grid is about to show.
protocol DeviceThumbnailProviding: Sendable {
    /// The photos the grids want now that memory lacks, at the cell's size in pixels, replacing
    /// the window before. Returns at once.
    func preheat(_ ids: Set<DeviceAssetID>, pixels: Int)
    /// Nothing is wanted any more, as at sign-out.
    func stop()
    /// Renders one photo's thumbnail at `pixels`. Blocks the calling lane while Photos works.
    func thumbnail(_ id: DeviceAssetID, pixels: Int) -> DeviceThumbnailResult
}

/// Keeps Photos' caching image manager one step ahead of the grid (REBUILD_ROADMAP.md T6). Each
/// window the scheduler sends is diffed against the one before: only the photos that came in are
/// started and only those that left are stopped, so a scroll costs Photos the new row, not the
/// screen. A new cell size, a memory warning or the app going to the background stop everything;
/// the next window after that starts again from nothing. The diff and the calls into Photos run
/// on a serial queue of the source's own, the latest window replacing one not yet worked in, and
/// a stop is a step of that same work, ahead of the window asked for after it.
final class DeviceThumbnailSource: DeviceThumbnailProviding, Sendable {
    private struct State {
        /// What Photos is caching now, and at what size.
        var window: Set<DeviceAssetID> = []
        var pixels = 0
        var next: (ids: Set<DeviceAssetID>, pixels: Int)?
        /// Photos is to stop caching everything, before the next window if there is one.
        var clearPending = false
        var scheduled = false
        var inBackground = false
    }

    /// One step of work: what Photos stops, then what it starts.
    private struct Plan {
        var stopAll = false
        var stop: [DeviceAssetID] = []
        var stopPixels = 0
        var start: [DeviceAssetID] = []
        var pixels = 0
    }

    private let imaging: any DeviceThumbnailImaging
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "ilyich.device-thumbnails", qos: .userInitiated)
    private let notifications: NotificationCenter
    /// Set once in init and read in deinit, so never shared.
    private nonisolated(unsafe) var observers: [any NSObjectProtocol] = []

    /// UIKit's notifications by name, so the source needs no UIKit.
    static let memoryWarning = Notification.Name("UIApplicationDidReceiveMemoryWarningNotification")
    static let didEnterBackground = Notification.Name("UIApplicationDidEnterBackgroundNotification")
    static let willEnterForeground = Notification.Name("UIApplicationWillEnterForegroundNotification")

    init(imaging: any DeviceThumbnailImaging, notifications: NotificationCenter = .default) {
        self.imaging = imaging
        self.notifications = notifications
        observers = [
            notifications.addObserver(forName: Self.memoryWarning, object: nil, queue: nil) { [weak self] _ in
                self?.clear(background: nil)
            },
            notifications.addObserver(forName: Self.didEnterBackground, object: nil, queue: nil) { [weak self] _ in
                self?.clear(background: true)
            },
            notifications.addObserver(forName: Self.willEnterForeground, object: nil, queue: nil) { [weak self] _ in
                self?.state.withLock { $0.inBackground = false }
            },
        ]
    }

    deinit {
        for token in observers { notifications.removeObserver(token) }
    }

    func preheat(_ ids: Set<DeviceAssetID>, pixels: Int) {
        schedule { $0.next = (ids, pixels) }
    }

    func stop() { clear(background: nil) }

    func thumbnail(_ id: DeviceAssetID, pixels: Int) -> DeviceThumbnailResult {
        imaging.thumbnail(id, pixels: pixels)
    }

    /// What Photos is caching, for tests.
    var cachedWindow: Set<DeviceAssetID> { state.withLock { $0.window } }

    /// Photos stops caching everything. While `background` holds, windows are not started until
    /// the app comes forward again. The stop is worked in on the queue like a window: a window
    /// already queued is started before it and stopped with the rest, and a window asked for after
    /// it is started after it, from nothing, instead of being wiped by it and lost until the grid
    /// scrolls again.
    private func clear(background: Bool?) {
        schedule { state in
            state.clearPending = true
            state.next = nil
            if let background { state.inBackground = background }
        }
    }

    /// Changes the state and queues the work once; work already queued picks the change up.
    private func schedule(_ change: (inout State) -> Void) {
        let schedule = state.withLock { state -> Bool in
            change(&state)
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if schedule { queue.async { [self] in work() } }
    }

    private func work() {
        let plan = state.withLock { state -> Plan in
            state.scheduled = false
            var plan = Plan()
            if state.clearPending {
                state.clearPending = false
                state.window = []
                state.pixels = 0
                plan.stopAll = true
            }
            guard let next = state.next else { return plan }
            state.next = nil
            guard !state.inBackground else { return plan }
            // An empty window stops what is left; its size means nothing.
            let pixels = next.ids.isEmpty ? state.pixels : next.pixels
            let sizeChanged = pixels != state.pixels && !state.window.isEmpty
            if sizeChanged { plan.stopAll = true }
            plan.start = (sizeChanged ? next.ids : next.ids.subtracting(state.window)).sorted { $0.rawValue < $1.rawValue }
            plan.stop = (sizeChanged ? [] : state.window.subtracting(next.ids)).sorted { $0.rawValue < $1.rawValue }
            plan.stopPixels = state.pixels
            plan.pixels = pixels
            state.window = next.ids
            state.pixels = pixels
            return plan
        }
        if plan.stopAll { imaging.stopCachingAll() }
        if !plan.stop.isEmpty { imaging.stopCaching(plan.stop, pixels: plan.stopPixels) }
        if !plan.start.isEmpty { imaging.startCaching(plan.start, pixels: plan.pixels) }
    }
}

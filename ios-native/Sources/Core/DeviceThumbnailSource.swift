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
/// on a serial queue of the source's own, the latest window replacing one not yet worked in.
final class DeviceThumbnailSource: DeviceThumbnailProviding, Sendable {
    private struct State {
        /// What Photos is caching now, and at what size.
        var window: Set<DeviceAssetID> = []
        var pixels = 0
        var next: (ids: Set<DeviceAssetID>, pixels: Int)?
        var scheduled = false
        var inBackground = false
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
        let schedule = state.withLock { state -> Bool in
            state.next = (ids, pixels)
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if schedule { queue.async { [self] in work() } }
    }

    func stop() { clear(background: nil) }

    func thumbnail(_ id: DeviceAssetID, pixels: Int) -> DeviceThumbnailResult {
        imaging.thumbnail(id, pixels: pixels)
    }

    /// What Photos is caching, for tests.
    var cachedWindow: Set<DeviceAssetID> { state.withLock { $0.window } }

    /// Photos stops caching everything. While `background` holds, windows are not started until
    /// the app comes forward again. The window is forgotten on the queue, in the same step that
    /// stops Photos: a window that work already queued starts in between is stopped with the rest,
    /// and the diff after knows it, so the next window starts from nothing.
    private func clear(background: Bool?) {
        state.withLock { state in
            state.next = nil
            if let background { state.inBackground = background }
        }
        queue.async { [self] in
            state.withLock { state in
                state.window = []
                state.pixels = 0
            }
            imaging.stopCachingAll()
        }
    }

    private func work() {
        let plan = state.withLock { state -> (start: [DeviceAssetID], stop: [DeviceAssetID], all: Bool, pixels: Int, before: Int)? in
            state.scheduled = false
            guard let next = state.next else { return nil }
            state.next = nil
            guard !state.inBackground else { return nil }
            let before = state.pixels
            // An empty window stops what is left; its size means nothing.
            let pixels = next.ids.isEmpty ? state.pixels : next.pixels
            let sizeChanged = pixels != state.pixels && !state.window.isEmpty
            let start = sizeChanged ? next.ids : next.ids.subtracting(state.window)
            let stop = sizeChanged ? [] : state.window.subtracting(next.ids)
            state.window = next.ids
            state.pixels = pixels
            return (start.sorted { $0.rawValue < $1.rawValue }, stop.sorted { $0.rawValue < $1.rawValue }, sizeChanged, pixels, before)
        }
        guard let plan else { return }
        if plan.all { imaging.stopCachingAll() }
        if !plan.stop.isEmpty { imaging.stopCaching(plan.stop, pixels: plan.before) }
        if !plan.start.isEmpty { imaging.startCaching(plan.start, pixels: plan.pixels) }
    }
}

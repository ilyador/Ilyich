import CryptoKit
import Foundation
import Network
@preconcurrency import Photos

/// Deterministic activity state for the export watchdog. PhotoKit progress only counts when its
/// value advances; repeated callbacks at the same value don't disguise a stalled transfer.
@_spi(Testing) public struct PhotoExportActivityWatchdog: Sendable {
    let timeout: Duration
    private(set) var lastActivity: ContinuousClock.Instant
    private(set) var latestProgress = 0.0

    public init(timeout: Duration, startedAt: ContinuousClock.Instant) {
        self.timeout = timeout
        lastActivity = startedAt
    }

    public mutating func receivedBytes(at now: ContinuousClock.Instant) {
        lastActivity = now
    }

    public mutating func reportProgress(_ progress: Double, at now: ContinuousClock.Instant) {
        guard progress.isFinite, progress > latestProgress else { return }
        latestProgress = progress
        lastActivity = now
    }

    public func isStalled(at now: ContinuousClock.Instant) -> Bool {
        lastActivity.duration(to: now) >= timeout
    }

    public func remaining(at now: ContinuousClock.Instant) -> Duration {
        let elapsed = lastActivity.duration(to: now)
        return elapsed >= timeout ? .zero : timeout - elapsed
    }
}

/// Streams one PhotoKit resource to a file, or hashes it. PhotoKit streams on its own serial
/// queue. A lock also covers cancellation, which can arrive before PhotoKit has returned the
/// request identifier: the partial file is deleted then, and the request cancelled once named.
/// Nothing here is bound to the main actor.
public final class PhotoResourceExport: @unchecked Sendable {
    /// Why an export waits rather than fails.
    public enum Deferral: LocalizedError, Sendable {
        /// The original is in iCloud and cellular downloads are off.
        case waitingForWiFi

        public var errorDescription: String? {
            switch self {
            case .waitingForWiFi: "Waiting for Wi-Fi to download the iCloud original"
            }
        }
    }

    private let lock = NSLock()
    private let destination: URL?
    private let computesChecksum: Bool
    private let noProgressTimeout: Duration?
    private let clock = ContinuousClock()
    private var hash = Insecure.SHA1()
    private var completedChecksum: String?
    private var activityWatchdog: PhotoExportActivityWatchdog?
    private var watchdogTask: Task<Void, Never>?
    private var cancelAfterRequestStarts = false
    private var output: FileHandle?
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelRequest: (@Sendable (PHAssetResourceDataRequestID) -> Void)?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var completed = false
    private var cancelled = false
    private var monitor: NWPathMonitor?
    private var started = false

    /// Hashing is opt-in for file exports so share staging doesn't pay for an unused digest.
    /// The destination-less checksum path always opts in explicitly.
    public init(destination: URL? = nil, computeChecksum: Bool = false, noProgressTimeout: Duration? = nil) {
        self.destination = destination
        computesChecksum = computeChecksum
        self.noProgressTimeout = noProgressTimeout
    }

    /// The base64 SHA-1 digest, available only after a successful write and close.
    public var checksum: String? {
        lock.withLock { completed && !cancelled ? completedChecksum : nil }
    }

    /// Hashes in bounded memory, trying local bytes first. Cloud access uses the same
    /// cellular gate as file exports; by default a cloud-only resource fails without downloading.
    public static func checksum(_ resource: PHAssetResource, allowCloud: Bool = false, allowCellular: Bool = false,
                                isolation: isolated (any Actor)? = #isolation) async throws -> String {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        do {
            let reader = PhotoResourceExport(computeChecksum: true)
            try await reader.write(resource, options: options)
            guard let checksum = reader.checksum else { throw CocoaError(.fileReadUnknown) }
            return checksum
        } catch {
            let details = error as NSError
            guard allowCloud, details.domain == PHPhotosErrorDomain,
                  details.code == PHPhotosError.networkAccessRequired.rawValue else { throw error }
            try Task.checkCancellation()
            // A failed local request may have delivered partial bytes. A fresh reader hashes
            // the cloud request from the beginning rather than retaining that partial digest.
            let reader = PhotoResourceExport(computeChecksum: true)
            options.isNetworkAccessAllowed = true
            try await reader.write(resource, options: options, allowCellular: allowCellular)
            guard let checksum = reader.checksum else { throw CocoaError(.fileReadUnknown) }
            return checksum
        }
    }

    /// Streams `resource`. The request starts on the caller's executor, the Photos adapter's own
    /// queue for backup, and PhotoKit streams bytes and hashes on its callback queue. With network
    /// access and `allowCellular` off, an iCloud download waits for Wi-Fi: the export throws
    /// `Deferral.waitingForWiFi` while the phone is on cellular or offline.
    public func write(_ resource: PHAssetResource, options: PHAssetResourceRequestOptions, allowCellular: Bool = true,
                      isolation: isolated (any Actor)? = #isolation) async throws {
        let previousProgress = options.progressHandler
        if noProgressTimeout != nil {
            options.progressHandler = { [weak self] progress in
                self?.reportPhotoProgress(progress)
                previousProgress?(progress)
            }
        }
        defer { options.progressHandler = previousProgress }
        try await write(.photoKit(resource, options: options), networkAccess: options.isNetworkAccessAllowed, allowCellular: allowCellular)
    }

    /// Streams what `request` delivers, as `write(_:options:allowCellular:)` does for a PhotoKit resource.
    public func write(_ request: ResourceDataRequest, networkAccess: Bool, allowCellular: Bool = true,
                      isolation: isolated (any Actor)? = #isolation) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(request, networkAccess: networkAccess, allowCellular: allowCellular, continuation: continuation)
            }
        } onCancel: { self.cancel() }
        try Task.checkCancellation()
    }

    private func begin(_ request: ResourceDataRequest, networkAccess: Bool, allowCellular: Bool,
                       continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        guard !cancelled, !completed, self.continuation == nil else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        do {
            if let destination {
                try Data().write(to: destination, options: .completeFileProtectionUntilFirstUserAuthentication)
                output = try FileHandle(forWritingTo: destination)
            }
        } catch { lock.unlock(); finish(error); return }
        if networkAccess, !allowCellular {
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = Self.pathHandler(self, request: request)
            lock.unlock()
            monitor.start(queue: DispatchQueue(label: "app.ilyich.photo-network"))
            return
        }
        lock.unlock()
        startRequest(request)
    }

    /// Built outside any actor, as NWPathMonitor calls it on its own queue.
    private nonisolated static func pathHandler(_ export: PhotoResourceExport, request: ResourceDataRequest) -> @Sendable (NWPath) -> Void {
        { path in
            if path.status != .satisfied || path.isExpensive || path.usesInterfaceType(.cellular) {
                export.finish(Deferral.waitingForWiFi, cancelRequest: true)
            } else { export.startRequest(request) }
        }
    }

    private func startRequest(_ request: ResourceDataRequest) {
        lock.lock()
        guard !started, !completed, !cancelled else { lock.unlock(); return }
        started = true
        if let noProgressTimeout {
            activityWatchdog = PhotoExportActivityWatchdog(timeout: noProgressTimeout, startedAt: clock.now)
            watchdogTask = Task { [weak self] in
                guard let self else { return }
                await self.watchForStall()
            }
        }
        lock.unlock()
        let id = request.start({ [self] in append($0) }, { [self] in finish($0) })
        lock.lock()
        requestID = id
        cancelRequest = request.cancel
        let shouldCancel = cancelAfterRequestStarts
        cancelAfterRequestStarts = false
        lock.unlock()
        // Cancelled before PhotoKit returned the identifier: the file is already gone, and the
        // request is cancelled now that it can be named.
        if shouldCancel { request.cancel(id) }
    }

    private func append(_ data: Data) {
        lock.lock()
        guard !completed, !cancelled else { lock.unlock(); return }
        do {
            if !data.isEmpty, activityWatchdog != nil {
                activityWatchdog?.receivedBytes(at: clock.now)
            }
            if destination != nil {
                guard let output else { throw CocoaError(.fileWriteUnknown) }
                try output.write(contentsOf: data)
                if computesChecksum { hash.update(data: data) }
            } else if computesChecksum {
                hash.update(data: data)
            }
            lock.unlock()
        }
        catch { lock.unlock(); finish(error, cancelRequest: true) }
    }

    private func reportPhotoProgress(_ progress: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, !cancelled else { return }
        activityWatchdog?.reportProgress(progress, at: clock.now)
    }

    private func watchForStall() async {
        while !Task.isCancelled {
            let remaining = lock.withLock { activityWatchdog?.remaining(at: clock.now) }
            guard let remaining else { return }
            do { try await Task.sleep(for: remaining) } catch { return }
            let error = URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "Photos stopped making progress on this download. Try again later."])
            if finish(error, cancelRequest: true, onlyIfStalled: true) { return }
        }
    }

    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(CancellationError(), cancelRequest: true)
    }

    @discardableResult
    private func finish(_ error: (any Error)?, cancelRequest: Bool = false, onlyIfStalled: Bool = false) -> Bool {
        lock.lock()
        guard !completed else { lock.unlock(); return false }
        if onlyIfStalled, !(activityWatchdog?.isStalled(at: clock.now) ?? false) {
            lock.unlock()
            return false
        }
        completed = true
        if cancelRequest, requestID == nil { cancelAfterRequestStarts = true }
        var result = error
        do { try output?.close() } catch { if result == nil { result = error } }
        output = nil
        if result == nil, !cancelled, computesChecksum {
            completedChecksum = Data(hash.finalize()).base64EncodedString()
        }
        if result != nil, let destination { try? FileManager.default.removeItem(at: destination) }
        let continuation = self.continuation
        self.continuation = nil
        let id = requestID
        let cancelling = self.cancelRequest
        let watchdogTask = self.watchdogTask
        self.watchdogTask = nil
        activityWatchdog = nil
        let monitor = self.monitor
        self.monitor = nil
        lock.unlock()
        watchdogTask?.cancel()
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        if cancelRequest, let id { cancelling?(id) }
        if let result { continuation?.resume(throwing: result) }
        else { continuation?.resume() }
        return true
    }
}

/// One data request: how to start it, which returns its identifier, and how to cancel it. Built
/// by nonisolated factories, so PhotoKit can call its handlers on its own queue.
public struct ResourceDataRequest: Sendable {
    public typealias Start = @Sendable (_ received: @escaping @Sendable (Data) -> Void,
                                        _ completed: @escaping @Sendable ((any Error)?) -> Void) -> PHAssetResourceDataRequestID
    public let start: Start
    public let cancel: @Sendable (PHAssetResourceDataRequestID) -> Void

    public init(start: @escaping Start, cancel: @escaping @Sendable (PHAssetResourceDataRequestID) -> Void) {
        self.start = start; self.cancel = cancel
    }

    /// A request to PHAssetResourceManager for `resource`.
    public nonisolated static func photoKit(_ resource: PHAssetResource, options: PHAssetResourceRequestOptions) -> ResourceDataRequest {
        nonisolated(unsafe) let resource = resource
        nonisolated(unsafe) let options = options
        return ResourceDataRequest(start: { received, completed in
            PHAssetResourceManager.default().requestData(for: resource, options: options,
                                                         dataReceivedHandler: { received($0) }, completionHandler: { completed($0) })
        }, cancel: { PHAssetResourceManager.default().cancelDataRequest($0) })
    }
}

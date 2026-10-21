import CryptoKit
import Foundation
import Network
@preconcurrency import Photos

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
    private var hash = Insecure.SHA1()
    private var output: FileHandle?
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelRequest: (@Sendable (PHAssetResourceDataRequestID) -> Void)?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var completed = false
    private var cancelled = false
    private var monitor: NWPathMonitor?
    private var started = false

    /// Without a destination, the resource is only hashed.
    public init(destination: URL? = nil) { self.destination = destination }

    /// The same streamed resource used by backup, with no temporary export or
    /// iCloud network request. A cloud-only resource fails for the caller to skip.
    public static func checksum(_ resource: PHAssetResource, isolation: isolated (any Actor)? = #isolation) async throws -> String {
        let reader = PhotoResourceExport()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        try await reader.write(resource, options: options)
        return reader.lock.withLock { Data(reader.hash.finalize()).base64EncodedString() }
    }

    /// Streams `resource`. The request starts on the caller's executor, the Photos adapter's own
    /// queue for backup, and PhotoKit streams bytes and hashes on its callback queue. With network
    /// access and `allowCellular` off, an iCloud download waits for Wi-Fi: the export throws
    /// `Deferral.waitingForWiFi` while the phone is on cellular or offline.
    public func write(_ resource: PHAssetResource, options: PHAssetResourceRequestOptions, allowCellular: Bool = true,
                      isolation: isolated (any Actor)? = #isolation) async throws {
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
        lock.unlock()
        let id = request.start({ [self] in append($0) }, { [self] in finish($0) })
        lock.lock()
        requestID = id
        cancelRequest = request.cancel
        let shouldCancel = completed || cancelled
        lock.unlock()
        // Cancelled before PhotoKit returned the identifier: the file is already gone, and the
        // request is cancelled now that it can be named.
        if shouldCancel { request.cancel(id) }
    }

    private func append(_ data: Data) {
        lock.lock()
        guard !completed, !cancelled else { lock.unlock(); return }
        do {
            if destination == nil { hash.update(data: data) }
            else { try output?.write(contentsOf: data) }
            lock.unlock()
        }
        catch { lock.unlock(); finish(error, cancelRequest: true) }
    }

    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(CancellationError(), cancelRequest: true)
    }

    private func finish(_ error: (any Error)?, cancelRequest: Bool = false) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        var result = error
        do { try output?.close() } catch { if result == nil { result = error } }
        output = nil
        if result != nil, let destination { try? FileManager.default.removeItem(at: destination) }
        let continuation = self.continuation
        self.continuation = nil
        let id = requestID
        let cancelling = self.cancelRequest
        let monitor = self.monitor
        self.monitor = nil
        lock.unlock()
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        if cancelRequest, let id { cancelling?(id) }
        if let result { continuation?.resume(throwing: result) }
        else { continuation?.resume() }
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

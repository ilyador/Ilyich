import Foundation
import CryptoKit
import Network
@preconcurrency import Photos

/// PhotoKit streams on its own serial queue. A lock also covers cancellation,
/// which can arrive before PhotoKit has returned the request identifier.
final class PhotoResourceExport: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL?
    private var hash = Insecure.SHA1()
    private var output: FileHandle?
    private var requestID: PHAssetResourceDataRequestID?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var completed = false
    private var cancelled = false
    private var monitor: NWPathMonitor?
    private var started = false

    init(destination: URL? = nil) { self.destination = destination }

    /// The same streamed resource used by backup, with no temporary export or
    /// iCloud network request. A cloud-only resource fails for the caller to skip.
    @MainActor static func checksum(_ resource: PHAssetResource) async throws -> String {
        let reader = PhotoResourceExport()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        try await reader.write(resource, options: options)
        return reader.lock.withLock { Data(reader.hash.finalize()).base64EncodedString() }
    }

    // Resource discovery is main-actor isolated. Keep PhotoKit request setup on
    // that actor; PhotoKit still streams bytes and hashes on its callback queue.
    @MainActor func write(_ resource: PHAssetResource, options: PHAssetResourceRequestOptions, allowCellular: Bool = true) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(resource, options: options, allowCellular: allowCellular, continuation: continuation)
            }
        } onCancel: { self.cancel() }
        try Task.checkCancellation()
    }

    private func begin(_ resource: PHAssetResource, options: PHAssetResourceRequestOptions, allowCellular: Bool,
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
        if options.isNetworkAccessAllowed, !allowCellular {
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { path in
                if path.status != .satisfied || path.isExpensive || path.usesInterfaceType(.cellular) {
                    self.finish(BackupDeferral.waitingForWiFi, cancelRequest: true)
                } else { self.startRequest(resource, options: options) }
            }
            lock.unlock()
            monitor.start(queue: DispatchQueue(label: "app.ilyich.photo-network"))
            return
        }
        lock.unlock()
        startRequest(resource, options: options)
    }

    private func startRequest(_ resource: PHAssetResource, options: PHAssetResourceRequestOptions) {
        lock.lock()
        guard !started, !completed, !cancelled else { lock.unlock(); return }
        started = true
        lock.unlock()
        let id = PHAssetResourceManager.default().requestData(for: resource, options: options,
            dataReceivedHandler: { self.append($0) }, completionHandler: { self.finish($0) })
        lock.lock()
        requestID = id
        let shouldCancel = completed || cancelled
        lock.unlock()
        if shouldCancel { PHAssetResourceManager.default().cancelDataRequest(id) }
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
        let monitor = self.monitor
        self.monitor = nil
        lock.unlock()
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        if cancelRequest, let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        if let result { continuation?.resume(throwing: result) }
        else { continuation?.resume() }
    }
}

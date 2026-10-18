import Foundation
@preconcurrency import Photos

/// PhotoKit streams on its own serial queue. A lock also covers cancellation,
/// which can arrive before PhotoKit has returned the request identifier.
final class PhotoResourceExport: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private var output: FileHandle?
    private var requestID: PHAssetResourceDataRequestID?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var completed = false
    private var cancelled = false

    init(destination: URL) { self.destination = destination }

    func write(_ resource: PHAssetResource, options: PHAssetResourceRequestOptions) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(resource, options: options, continuation: continuation)
            }
        } onCancel: { self.cancel() }
        try Task.checkCancellation()
    }

    private func begin(_ resource: PHAssetResource, options: PHAssetResourceRequestOptions,
                       continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        do {
            try Data().write(to: destination, options: .completeFileProtectionUntilFirstUserAuthentication)
            output = try FileHandle(forWritingTo: destination)
        } catch { lock.unlock(); finish(error); return }
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
        do { try output?.write(contentsOf: data); lock.unlock() }
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
        if result != nil { try? FileManager.default.removeItem(at: destination) }
        let continuation = self.continuation
        self.continuation = nil
        let id = requestID
        lock.unlock()
        if cancelRequest, let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        if let result { continuation?.resume(throwing: result) }
        else { continuation?.resume() }
    }
}

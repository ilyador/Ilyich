import Foundation
import Network
@preconcurrency import Photos

/// PhotoKit's public editing input identifies the current RAW/JPEG choice. Only the content type
/// crosses the callback; no image is decoded into memory. Nothing here is bound to the main actor:
/// a lock guards the state, and every callback is built by a nonisolated factory, so PhotoKit and
/// NWPathMonitor may call it on any queue. The request starts on the caller's executor, the Photos
/// adapter's own queue.
final class PhotoCurrentRepresentation: @unchecked Sendable {
    private let asset: PHAsset
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var requestID: PHContentEditingInputRequestID?
    private var monitor: NWPathMonitor?
    private var finished = false
    private var began = false
    private var failed = false

    init(asset: PHAsset) { self.asset = asset }

    func contentType(allowCloud: Bool, allowCellular: Bool, progress: @escaping @Sendable (Double) -> Void,
                     isolation: isolated (any Actor)? = #isolation) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !finished, self.continuation == nil else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                if allowCloud && !allowCellular {
                    let monitor = NWPathMonitor(); self.monitor = monitor
                    monitor.pathUpdateHandler = Self.pathHandler(self, allowCloud: allowCloud, progress: progress)
                    lock.unlock()
                    monitor.start(queue: DispatchQueue(label: "app.ilyich.current-photo-network"))
                } else {
                    lock.unlock()
                    begin(allowCloud: allowCloud, progress: progress)
                }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    private nonisolated static func pathHandler(_ request: PhotoCurrentRepresentation, allowCloud: Bool,
                                                progress: @escaping @Sendable (Double) -> Void) -> @Sendable (NWPath) -> Void {
        { [weak request] path in
            let allowed = path.status == .satisfied && !path.isExpensive && !path.usesInterfaceType(.cellular)
            guard let request else { return }
            if allowed { request.begin(allowCloud: allowCloud, progress: progress) }
            else { request.finish(.failure(BackupDeferral.waitingForWiFi)) }
        }
    }

    private nonisolated static func completion(_ request: PhotoCurrentRepresentation) -> @Sendable (PHContentEditingInput?, [AnyHashable: Any]) -> Void {
        { input, info in
            if let type = input?.contentType?.identifier { request.finish(.success(type)) }
            else {
                let failure = info[PHContentEditingInputErrorKey] as? Error
                request.finish(.failure(failure ?? BackupError.message("Photos could not provide its current RAW or JPEG version. Download it in Photos or enable iCloud downloads, then retry.")))
            }
        }
    }

    private nonisolated static func progressHandler(_ progress: @escaping @Sendable (Double) -> Void) -> @Sendable (Double, UnsafeMutablePointer<ObjCBool>) -> Void {
        { value, _ in progress(value) }
    }

    private func begin(allowCloud: Bool, progress: @escaping @Sendable (Double) -> Void) {
        lock.lock()
        guard !began, !finished else { lock.unlock(); return }
        began = true
        lock.unlock()
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = allowCloud
        options.canHandleAdjustmentData = { _ in false }
        options.progressHandler = Self.progressHandler(progress)
        let id = asset.requestContentEditingInput(with: options, completionHandler: Self.completion(self))
        lock.lock()
        requestID = id
        let cancel = finished && failed
        lock.unlock()
        // Failed or cancelled before PhotoKit returned the identifier.
        if cancel { asset.cancelContentEditingInputRequest(id) }
    }

    private func finish(_ result: Result<String, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        if case .failure = result { failed = true }
        let monitor = self.monitor; self.monitor = nil
        let continuation = self.continuation; self.continuation = nil
        let id = requestID
        lock.unlock()
        monitor?.pathUpdateHandler = nil; monitor?.cancel()
        if case .failure = result, let id { asset.cancelContentEditingInputRequest(id) }
        continuation?.resume(with: result)
    }
}

import Foundation
import Network
@preconcurrency import Photos

/// PhotoKit's public editing input identifies the current RAW/JPEG choice.
/// Only the content type crosses the callback; no image is decoded into memory.
@MainActor final class PhotoCurrentRepresentation {
    private let asset: PHAsset
    private var continuation: CheckedContinuation<String, any Error>?
    private var requestID: PHContentEditingInputRequestID?
    private var monitor: NWPathMonitor?
    private var finished = false

    init(asset: PHAsset) { self.asset = asset }

    func contentType(allowCloud: Bool, allowCellular: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try Task.checkCancellation()
        guard !finished, continuation == nil else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if allowCloud && !allowCellular {
                    let monitor = NWPathMonitor(); self.monitor = monitor
                    monitor.pathUpdateHandler = { [weak self] path in
                        let allowed = path.status == .satisfied && !path.isExpensive && !path.usesInterfaceType(.cellular)
                        Task { @MainActor in
                            guard let self, !self.finished else { return }
                            if allowed { self.begin(allowCloud: allowCloud, progress: progress) }
                            else { self.finish(.failure(BackupDeferral.waitingForWiFi)) }
                        }
                    }
                    monitor.start(queue: DispatchQueue(label: "app.ilyich.current-photo-network"))
                } else { begin(allowCloud: allowCloud, progress: progress) }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }

    private func begin(allowCloud: Bool, progress: @escaping @Sendable (Double) -> Void) {
        guard requestID == nil, !finished else { return }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = allowCloud
        options.canHandleAdjustmentData = { _ in false }
        options.progressHandler = { value, _ in progress(value) }
        requestID = asset.requestContentEditingInput(with: options) { input, info in
            let type = input?.contentType?.identifier
            let failure = info[PHContentEditingInputErrorKey] as? Error
            Task { @MainActor in
                if let type { self.finish(.success(type)) }
                else { self.finish(.failure(failure ?? BackupError.message("Photos could not provide its current RAW or JPEG version. Download it in Photos or enable iCloud downloads, then retry."))) }
            }
        }
    }

    private func finish(_ result: Result<String, any Error>) {
        guard !finished else { return }; finished = true
        monitor?.pathUpdateHandler = nil; monitor?.cancel(); monitor = nil
        if case .failure = result, let requestID { asset.cancelContentEditingInputRequest(requestID) }
        continuation?.resume(with: result); continuation = nil
    }
}

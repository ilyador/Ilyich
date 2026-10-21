import Foundation
@preconcurrency import Photos
import UniformTypeIdentifiers

/// A share the Share extension can't stage, in words for the person sharing.
public struct ShareStagingError: LocalizedError, Sendable {
    public let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// Copies what the Share extension received into a new share batch. Uploading happens later in
/// the signed-in app, after the user picks what to upload, so a cold launch or an expired session
/// never loses the share. Provider callbacks copy files on their own queues and PhotoKit streams
/// Live Photo parts on its own; only the orchestration runs on the main actor.
@MainActor public final class ShareStaging {
    public static let maximumItems = ShareManifest.maximumAttachments

    private let repository: ShareInboxRepository
    /// The batch being staged or last staged.
    public private(set) var batchID: UUID?
    private var saved = false

    public init(repository: ShareInboxRepository) { self.repository = repository }

    /// Copies every provider's file into a new batch folder, pairs XMP sidecars with their photos
    /// by file name and saves the manifest. A failed or cancelled staging leaves nothing behind.
    /// `progress` receives the index of the item being copied and the number of items.
    public func stage(_ providers: [NSItemProvider], progress: (_ index: Int, _ count: Int) -> Void) async throws -> SharedBatch {
        guard !providers.isEmpty, providers.count <= Self.maximumItems else {
            throw ShareStagingError("Share between 1 and \(Self.maximumItems) files at a time.")
        }
        let id = UUID()
        batchID = id
        saved = false
        do {
            let folder = try await repository.createFolder(for: id)
            var attachments: [SharedAttachment] = []
            for (index, provider) in providers.enumerated() {
                try Task.checkCancellation()
                progress(index, providers.count)
                if provider.canLoadObject(ofClass: PHLivePhoto.self) {
                    attachments.append(try await copyLivePhoto(provider, to: folder))
                } else {
                    attachments.append(SharedAttachment(original: try await copy(provider, to: folder)))
                }
            }
            attachments = try Self.pairSidecars(attachments)
            try Task.checkCancellation()
            let batch = SharedBatch(id: id, createdAt: Date(), attachments: attachments)
            try await repository.save(batch)
            saved = true
            return batch
        } catch {
            try? await repository.remove(id)
            throw error
        }
    }

    /// Deletes the batch being staged, unless it was saved.
    public func discard() async {
        guard !saved, let batchID else { return }
        try? await repository.remove(batchID)
    }

    /// Attaches each shared .xmp file to the photo whose file name it extends (IMG_1.CR3.xmp) or
    /// whose stem it shares (IMG_1.xmp), ignoring case. A sidecar without its photo, or a second
    /// sidecar for one photo, fails the share.
    public nonisolated static func pairSidecars(_ items: [SharedAttachment]) throws -> [SharedAttachment] {
        func isSidecar(_ item: SharedAttachment) -> Bool { item.original.filename.lowercased().hasSuffix(".xmp") }
        func stem(_ filename: String) -> String { URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent.lowercased() }
        var attachments = items.filter { !isSidecar($0) }
        for sidecar in items.filter(isSidecar) {
            let name = stem(sidecar.original.filename)
            guard let index = attachments.firstIndex(where: { name == $0.original.filename.lowercased() || name == stem($0.original.filename) }),
                  attachments[index].sidecar == nil else {
                throw ShareStagingError("Include the matching original photo for \(sidecar.original.filename).")
            }
            attachments[index].sidecar = sidecar.original
        }
        return attachments
    }

    private func copyLivePhoto(_ provider: NSItemProvider, to folder: URL) async throws -> SharedAttachment {
        let loading = ShareRepresentationRequest()
        let live: PHLivePhoto = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let progress = provider.loadObject(ofClass: PHLivePhoto.self) { object, error in
                    do {
                        try loading.checkCancellation()
                        if let error { throw error }
                        guard let live = object as? PHLivePhoto else { throw ShareStagingError("The source app did not provide this Live Photo.") }
                        continuation.resume(returning: live)
                    } catch { continuation.resume(throwing: error) }
                }
                loading.attach(progress)
            }
        } onCancel: { loading.cancel() }
        let resources = PHAssetResource.assetResources(for: live)
        guard let photo = resources.first(where: { $0.type == .photo }),
              let movie = resources.first(where: { $0.type == .pairedVideo }) else {
            throw ShareStagingError("The source app did not provide both parts of this Live Photo. Nothing was uploaded.")
        }
        func export(_ resource: PHAssetResource) async throws -> SharedFile {
            let name = UUID().uuidString
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await PhotoResourceExport(destination: folder.appendingPathComponent(name, isDirectory: false)).write(resource, options: options)
            return SharedFile(name: name, filename: resource.originalFilename,
                              contentType: UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream", folder: folder)
        }
        return SharedAttachment(original: try await export(photo), motion: try await export(movie))
    }

    private func copy(_ provider: NSItemProvider, to folder: URL) async throws -> SharedFile {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let file: SharedFile = try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    do {
                        if let error { throw error }
                        guard let url = item as? URL, url.isFileURL else { throw ShareStagingError("The source app did not provide a local file.") }
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let name = UUID().uuidString
                        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name, isDirectory: false))
                        continuation.resume(returning: SharedFile(name: name, filename: url.lastPathComponent,
                            contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", folder: folder))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return file
        }
        guard let type = provider.registeredTypeIdentifiers.first(where: { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }) ?? provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) else {
            throw ShareStagingError("This shared item does not contain an image, video, or original file.")
        }
        let loading = ShareRepresentationRequest()
        let file: SharedFile = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let progress = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    do {
                        try loading.checkCancellation()
                        if let error { throw error }
                        guard let url else { throw ShareStagingError("The source app did not provide this file. Try sharing it again.") }
                        let name = UUID().uuidString
                        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name, isDirectory: false))
                        continuation.resume(returning: SharedFile(name: name, filename: url.lastPathComponent,
                                                                  contentType: UTType(type)?.preferredMIMEType ?? "application/octet-stream", folder: folder))
                    } catch { continuation.resume(throwing: error) }
                }
                loading.attach(progress)
            }
        } onCancel: { loading.cancel() }
        try Task.checkCancellation()
        return file
    }
}

/// Cancels a provider's load, which can be cancelled before the provider returns its progress.
private final class ShareRepresentationRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var cancelled = false

    func attach(_ progress: Progress) {
        let shouldCancel = lock.withLock { self.progress = progress; return cancelled }
        if shouldCancel { progress.cancel() }
    }

    func cancel() {
        let progress = lock.withLock { cancelled = true; return self.progress }
        progress?.cancel()
    }

    func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

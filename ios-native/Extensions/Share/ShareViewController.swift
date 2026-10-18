import UIKit
import UniformTypeIdentifiers
@preconcurrency import Photos

@MainActor final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let continueButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var operation: Task<Void, Never>?
    private var stagedID: UUID?
    private var saved = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.numberOfLines = 0
        message.text = "Continue in Ilyich to choose files and upload. Your files stay available if you need to sign in first."
        continueButton.setTitle("Continue in Ilyich", for: .normal)
        continueButton.addTarget(self, action: #selector(start), for: .touchUpInside)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        let title = UILabel(); title.text = "Ilyich"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        title.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [title, message, continueButton, cancelButton])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            continueButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @objc private func close() {
        operation?.cancel()
        if !saved, let stagedID { try? SharedInbox.remove(stagedID) }
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func start() {
        if saved { openApp(); return }
        guard operation == nil else { return }
        continueButton.isEnabled = false
        operation = Task {
            do {
                try await stage()
                saved = true
                cancelButton.setTitle("Done", for: .normal)
                openApp()
            } catch is CancellationError { }
            catch {
                if let stagedID { try? SharedInbox.remove(stagedID) }
                message.text = error.localizedDescription
                continueButton.setTitle("Try again", for: .normal)
            }
            continueButton.isEnabled = true; operation = nil
        }
    }

    private func openApp() {
        guard let url = URL(string: "immich://share") else { return }
        extensionContext?.open(url) { opened in
            Task { @MainActor in
                if opened { self.extensionContext?.completeRequest(returningItems: nil) }
                else { self.message.text = "Your files are saved. Open Ilyich to review and upload them." }
            }
        }
    }

    private func stage() async throws {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty, providers.count <= 100 else { throw ShareError("Share between 1 and 100 files at a time.") }
        let id = UUID(); stagedID = id
        let folder = try SharedInbox.createDirectory(for: id)
        var attachments: [SharedAttachment] = []
        for (index, provider) in providers.enumerated() {
            try Task.checkCancellation()
            message.text = "Preparing \(index + 1) of \(providers.count)"
            if provider.canLoadObject(ofClass: PHLivePhoto.self) {
                attachments.append(try await copyLivePhoto(provider, to: folder))
            } else { attachments.append(SharedAttachment(original: try await copy(provider, to: folder))) }
        }
        let sidecars = attachments.filter { $0.original.filename.lowercased().hasSuffix(".xmp") }
        attachments.removeAll { $0.original.filename.lowercased().hasSuffix(".xmp") }
        for sidecar in sidecars {
            let stem = URL(fileURLWithPath: sidecar.original.filename).deletingPathExtension().lastPathComponent.lowercased()
            guard let index = attachments.firstIndex(where: {
                stem == $0.original.filename.lowercased() || stem == URL(fileURLWithPath: $0.original.filename).deletingPathExtension().lastPathComponent.lowercased()
            }), attachments[index].sidecar == nil else { throw ShareError("Include the matching original photo for \(sidecar.original.filename).") }
            attachments[index].sidecar = sidecar.original
        }
        try Task.checkCancellation()
        try SharedInbox.save(SharedBatch(id: id, createdAt: Date(), attachments: attachments))
    }

    private func copyLivePhoto(_ provider: NSItemProvider, to folder: URL) async throws -> SharedAttachment {
        let loading = ShareRepresentationRequest()
        let live: PHLivePhoto = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let progress = provider.loadObject(ofClass: PHLivePhoto.self) { object, error in
                    do {
                        try loading.checkCancellation()
                        if let error { throw error }
                        guard let live = object as? PHLivePhoto else { throw ShareError("The source app did not provide this Live Photo.") }
                        continuation.resume(returning: live)
                    } catch { continuation.resume(throwing: error) }
                }
                loading.attach(progress)
            }
        } onCancel: { loading.cancel() }
        let resources = PHAssetResource.assetResources(for: live)
        guard let photo = resources.first(where: { $0.type == .photo }),
              let movie = resources.first(where: { $0.type == .pairedVideo }) else {
            throw ShareError("The source app did not provide both parts of this Live Photo. Nothing was uploaded.")
        }
        func export(_ resource: PHAssetResource) async throws -> UploadFile {
            let url = folder.appendingPathComponent(UUID().uuidString)
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
            try await PhotoResourceExport(destination: url).write(resource, options: options)
            return UploadFile(url: url, filename: resource.originalFilename,
                              contentType: UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream")
        }
        return SharedAttachment(original: try await export(photo), motion: try await export(movie))
    }

    private func copy(_ provider: NSItemProvider, to directory: URL) async throws -> UploadFile {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let file: UploadFile = try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    do {
                        if let error { throw error }
                        guard let url = item as? URL, url.isFileURL else { throw ShareError("The source app did not provide a local file.") }
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let target = directory.appendingPathComponent(UUID().uuidString)
                        try FileManager.default.copyItem(at: url, to: target)
                        continuation.resume(returning: UploadFile(url: target, filename: url.lastPathComponent,
                            contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"))
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
            throw ShareError("This shared item does not contain an image, video, or original file.")
        }
        let loading = ShareRepresentationRequest()
        let file: UploadFile = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let progress = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    try loading.checkCancellation()
                    if let error { throw error }
                    guard let url else { throw ShareError("The source app did not provide this file. Try sharing it again.") }
                    let target = directory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: UploadFile(url: target, filename: url.lastPathComponent,
                                                              contentType: UTType(type)?.preferredMIMEType ?? "application/octet-stream"))
                } catch { continuation.resume(throwing: error) }
                }
                loading.attach(progress)
            }
        } onCancel: { loading.cancel() }
        try Task.checkCancellation()
        return file
    }
}

private struct ShareError: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } }

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

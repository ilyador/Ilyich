import UIKit
import UniformTypeIdentifiers

@MainActor final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let uploadButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let progress = UIProgressView(progressViewStyle: .default)
    private var operation: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.numberOfLines = 0
        message.text = "Upload the selected photos and videos to Ilyich."
        uploadButton.setTitle("Upload to Ilyich", for: .normal)
        uploadButton.addTarget(self, action: #selector(start), for: .touchUpInside)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        let title = UILabel()
        title.text = "Ilyich"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        title.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [title, message, progress, uploadButton, cancelButton])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            uploadButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        do {
            guard let saved = try SessionKeychain.read() else { throw ShareError("Open Ilyich and sign in before uploading.") }
            guard saved.requiresPasswordChange != true else { throw ShareError("Open Ilyich and change your account password before uploading.") }
            message.text = "Upload to \(saved.name) on \(saved.server.host() ?? "your server")."
        } catch { message.text = error.localizedDescription; uploadButton.isEnabled = false }
    }

    @objc private func close() {
        operation?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func start() {
        guard operation == nil else { return }
        uploadButton.isEnabled = false
        operation = Task {
            do {
                try await upload()
                cancelButton.setTitle("Done", for: .normal)
                uploadButton.isHidden = true
            } catch is CancellationError { }
            catch { message.text = error.localizedDescription; uploadButton.setTitle("Retry upload", for: .normal); uploadButton.isEnabled = true }
            operation = nil
        }
    }

    private func upload() async throws {
        guard let saved = try SessionKeychain.read() else { throw ShareError("Open Ilyich and sign in before uploading.") }
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard !attachments.isEmpty else { throw ShareError("No files were shared with Ilyich.") }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: try SessionKeychain.appGroup) else {
            throw ShareError("Shared storage is unavailable. Open Ilyich and try again.")
        }
        let folder = container.appendingPathComponent("ShareUploads").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var files: [UploadFile] = []
        for provider in attachments {
            try Task.checkCancellation()
            if provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier) {
                throw ShareError("Use Device backup in Ilyich for Live Photos so both the photo and its video are preserved.")
            }
            message.text = "Preparing \(files.count + 1) of \(attachments.count)"
            files.append(try await copy(provider, to: folder))
        }
        let images = files.filter { !$0.filename.lowercased().hasSuffix(".xmp") }
        guard !images.isEmpty else { throw ShareError("Share an original photo together with its XMP sidecar.") }
        for sidecar in files where sidecar.filename.lowercased().hasSuffix(".xmp") {
            guard images.contains(where: { matches(sidecar: sidecar, original: $0) }) else {
                throw ShareError("Include the original photo for \(sidecar.filename) so its edits are preserved.")
            }
        }
        let connection = try ServerConnection(server: saved.server)
        let network = URLSession(configuration: .ephemeral, delegate: ShareRedirectDelegate(server: saved.server), delegateQueue: nil)
        defer { network.invalidateAndCancel() }
        for (index, file) in images.enumerated() {
            try Task.checkCancellation()
            guard let current = try SessionKeychain.read(), current.scope == saved.scope, current.token == saved.token else {
                throw ShareError("Your sign-in changed. Reopen this share sheet before uploading.")
            }
            message.text = "Uploading \(index + 1) of \(images.count): \(file.filename)"
            let checksum = try await Task.detached(priority: .utility) { try UploadBody.checksum(file.url) }.value
            let checkBody = try JSONEncoder().encode(UploadCheck(assets: [.init(id: file.filename, checksum: checksum)]))
            let checkRequest = try await request(saved, connection: connection, path: "assets/bulk-upload-check", contentType: "application/json")
            let (checkData, checkResponse) = try await network.upload(for: checkRequest, from: checkBody)
            try validate(checkResponse)
            let checked = try JSONDecoder().decode(UploadCheckResponse.self, from: checkData).results.first { $0.id == file.filename }
            if checked?.action == "reject" {
                guard checked?.reason == "duplicate", checked?.assetId != nil, checked?.isTrashed != true else {
                    throw ShareError("\(index) of \(images.count) uploaded. The server rejected \(file.filename); check its format or server trash and retry.")
                }
            } else {
                guard checked?.action == "accept" else { throw ShareError("The server did not confirm its upload check. Retry.") }
                let sidecar = files.first { matches(sidecar: $0, original: file) }
                let body = folder.appendingPathComponent("body-\(index)")
                let boundary = "Ilyich-" + UUID().uuidString
                let dates = try file.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let fields = ["fileCreatedAt": (dates.creationDate ?? Date()).ISO8601Format(),
                              "fileModifiedAt": (dates.contentModificationDate ?? Date()).ISO8601Format()]
                try await Task.detached(priority: .utility) { try UploadBody.write(to: body, boundary: boundary, fields: fields, asset: file, sidecar: sidecar) }.value
                let uploadRequest = try await request(saved, connection: connection, path: "assets", contentType: "multipart/form-data; boundary=\(boundary)")
                let (data, response) = try await network.upload(for: uploadRequest, fromFile: body)
                try validate(response)
                let receipt = try JSONDecoder().decode(UploadReceipt.self, from: data)
                guard UUID(uuidString: receipt.id) != nil, ["created", "duplicate"].contains(receipt.status) else {
                    throw ShareError("The server did not confirm this upload. Retry to verify its checksum.")
                }
                try FileManager.default.removeItem(at: body)
            }
            progress.progress = Float(index + 1) / Float(images.count)
        }
        message.text = "\(images.count) \(images.count == 1 ? "file is" : "files are") backed up in Ilyich."
    }

    private func request(_ saved: SavedSession, connection: ServerConnection, path: String, contentType: String) async throws -> URLRequest {
        try Task.checkCancellation()
        guard let current = try SessionKeychain.read(), current.scope == saved.scope, current.token == saved.token,
              current.requiresPasswordChange != true else {
            throw ShareError("Your sign-in changed. Open Ilyich before uploading again.")
        }
        var request = try await connection.request(path: path, token: saved.token)
        guard let latest = try SessionKeychain.read(), latest.scope == saved.scope, latest.token == saved.token else {
            throw ShareError("Your sign-in changed. Open Ilyich before uploading again.")
        }
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    private func matches(sidecar: UploadFile, original: UploadFile) -> Bool {
        guard sidecar.filename.lowercased().hasSuffix(".xmp") else { return false }
        let stem = URL(fileURLWithPath: sidecar.filename).deletingPathExtension().lastPathComponent.lowercased()
        return stem == original.filename.lowercased() || stem == URL(fileURLWithPath: original.filename).deletingPathExtension().lastPathComponent.lowercased()
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw ShareError("The upload failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Keep this sheet open and retry, or use Device backup for long transfers.")
        }
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

private final class ShareRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let server: URL
    init(server: URL) { self.server = server }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        ClientCertificateStore.respond(to: challenge, server: server, requestURL: task.originalRequest?.url, completion: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

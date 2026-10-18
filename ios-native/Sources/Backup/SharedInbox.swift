import Foundation

struct SharedAttachment: Codable, Identifiable, Sendable {
    var id: String { original.url.lastPathComponent }
    let original: UploadFile
    var motion: UploadFile?
    var sidecar: UploadFile?
}

struct SharedBatch: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    var attachments: [SharedAttachment]
}

/// The extension only stages files. Upload happens after explicit selection in
/// the signed-in app, so a cold launch or expired session never loses the share.
enum SharedInbox {
    static func directory(for id: UUID) throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: try SessionKeychain.appGroup) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return container.appendingPathComponent("ShareInbox", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func createDirectory(for id: UUID) throws -> URL {
        var folder = try directory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder
    }

    static func save(_ batch: SharedBatch) throws {
        let folder = try directory(for: batch.id)
        try validate(batch, folder: folder)
        #if os(iOS)
        for item in batch.attachments {
            for file in [item.original, item.motion, item.sidecar].compactMap({ $0 }) {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.url.path)
            }
        }
        #endif
        try JSONEncoder().encode(batch).write(to: folder.appendingPathComponent("manifest.json"),
                                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func load() throws -> [SharedBatch] {
        let root = try directory(for: UUID()).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            let manifest = folder.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
            let data = try Data(contentsOf: manifest)
            guard data.count <= 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
            let batch = try JSONDecoder().decode(SharedBatch.self, from: data)
            guard batch.id == id else { throw CocoaError(.fileReadCorruptFile) }
            try validate(batch, folder: folder)
            return batch
        }.sorted { $0.createdAt < $1.createdAt }
    }

    static func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: directory(for: id)) }

    static func validate(_ batch: SharedBatch, folder: URL) throws {
        guard !batch.attachments.isEmpty, batch.attachments.count <= 100 else { throw CocoaError(.fileReadCorruptFile) }
        let expected = folder.resolvingSymlinksInPath().standardizedFileURL
        for item in batch.attachments {
            for file in [item.original, item.motion, item.sidecar].compactMap({ $0 }) {
                let resolved = file.url.resolvingSymlinksInPath().standardizedFileURL
                guard file.url.isFileURL, resolved.deletingLastPathComponent().path == expected.path,
                      try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
    }
}

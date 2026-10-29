import Foundation

/// A file staged in a share batch's folder. The Share extension names each one with a new UUID
/// and records the source's own file name beside it.
public struct SharedFile: Hashable, Sendable {
    /// The file's name in its batch folder: a single path component.
    public let name: String
    /// The name the source app gave the file, which the server receives.
    public let filename: String
    /// The file's MIME type.
    public let contentType: String
    /// The file in this container: its batch folder plus `name`. Upload identities hash its path.
    public let url: URL

    public init(name: String, filename: String, contentType: String, folder: URL) {
        self.name = name
        self.filename = filename
        self.contentType = contentType
        url = folder.appendingPathComponent(name, isDirectory: false)
    }
}

/// One shared item: a photo or video, with a Live Photo's video or an XMP sidecar when it has one.
public struct SharedAttachment: Identifiable, Hashable, Sendable {
    /// The original's name in the batch folder, which the extension makes a UUID.
    public var id: String { original.name }
    public let original: SharedFile
    public var motion: SharedFile?
    public var sidecar: SharedFile?

    public init(original: SharedFile, motion: SharedFile? = nil, sidecar: SharedFile? = nil) {
        self.original = original
        self.motion = motion
        self.sidecar = sidecar
    }

    /// The original, then the video and the sidecar when present.
    public var files: [SharedFile] { [original, motion, sidecar].compactMap { $0 } }
}

/// Files shared together, waiting in <AppGroup>/ShareInbox/<id>/ until the user uploads or
/// discards them.
public struct SharedBatch: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var attachments: [SharedAttachment]

    public init(id: UUID, createdAt: Date, attachments: [SharedAttachment]) {
        self.id = id
        self.createdAt = createdAt
        self.attachments = attachments
    }
}

/// Why a batch folder can't be used. The folder is left as it is: a manifest that can't be read
/// before the phone's first unlock, or one a newer build wrote, may read fine later.
public enum ShareBatchDamage: LocalizedError, Hashable, Sendable {
    /// The manifest couldn't be read.
    case unreadable
    /// The manifest is larger than any the Share extension writes.
    case tooLarge
    /// The manifest isn't a share manifest.
    case undecodable
    /// A newer build of the app wrote the manifest.
    case newerVersion(Int)
    /// The manifest names another batch.
    case wrongBatch
    /// The manifest lists no attachments or more than 100, or a file that isn't a regular file
    /// directly inside the batch folder.
    case invalid

    public var errorDescription: String? {
        switch self {
        case .unreadable: "These shared files couldn’t be read."
        case .newerVersion: "A newer version of Ilyich saved these shared files."
        case .tooLarge, .undecodable, .wrongBatch, .invalid: "These shared files are damaged."
        }
    }
}

/// <AppGroup>/ShareInbox/<batch>/manifest.json, version 2: `"v": 2`, the batch's ID and creation
/// date, and each file by its `name` in the batch folder, with the source's file name and the
/// MIME type. JSONEncoder's defaults, keys sorted: dates are seconds since 2001.
///
/// Builds from W3 to 3040093 also wrote each file's absolute URL, for builds before W3, which read
/// only URLs; readers since W3 use the names and skip it, so those manifests read as any other.
/// No build that reads URLs will be installed again, so the URLs are no longer written (C8). A
/// version 1 manifest (no version, URLs only) is no longer read: it is a damaged batch, kept on
/// disk and out of the list.
public enum ShareManifest {
    public static let version = 2
    public static let fileName = "manifest.json"
    /// A manifest larger than this is not read.
    public static let maximumSize = 1_048_576
    public static let maximumAttachments = 100

    /// Reads a manifest of the batch whose folder is `folder`. Every file resolves to `folder` plus
    /// its name, so a batch survives a moved container. Files are not looked at on disk here.
    public static func decode(_ data: Data, batch id: UUID, folder: URL) throws(ShareBatchDamage) -> SharedBatch {
        let stored: Stored
        do { stored = try JSONDecoder().decode(Stored.self, from: data) } catch { throw .undecodable }
        // Without a version it is a version 1 manifest, which no build since C8 reads.
        guard let version = stored.v else { throw .undecodable }
        guard version <= Self.version else { throw .newerVersion(version) }
        guard version == Self.version else { throw .undecodable }
        guard stored.id == id else { throw .wrongBatch }
        guard (1...maximumAttachments).contains(stored.attachments.count) else { throw .invalid }
        func file(_ file: StoredFile) throws(ShareBatchDamage) -> SharedFile {
            guard let name = file.name, isPlainName(name) else { throw .invalid }
            return SharedFile(name: name, filename: file.filename, contentType: file.contentType, folder: folder)
        }
        var attachments: [SharedAttachment] = []
        for item in stored.attachments {
            var attachment = SharedAttachment(original: try file(item.original))
            if let motion = item.motion { attachment.motion = try file(motion) }
            if let sidecar = item.sidecar { attachment.sidecar = try file(sidecar) }
            attachments.append(attachment)
        }
        return SharedBatch(id: id, createdAt: stored.createdAt, attachments: attachments)
    }

    /// The version 2 encoding, keys sorted: each file by its name, with no URL.
    public static func encode(_ batch: SharedBatch) throws -> Data {
        func file(_ file: SharedFile) -> StoredFile {
            StoredFile(filename: file.filename, contentType: file.contentType, name: file.name)
        }
        let stored = Stored(v: version, id: batch.id, createdAt: batch.createdAt, attachments: batch.attachments.map {
            StoredAttachment(original: file($0.original), motion: $0.motion.map(file), sidecar: $0.sidecar.map(file))
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(stored)
    }

    /// One path component that can't step out of the batch folder or stand for its manifest.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name != fileName && !name.contains("/") && !name.contains("\0")
    }

    // The keys on disk. A `url` key, which builds from W3 to 3040093 wrote beside each name, is
    // skipped.
    private struct Stored: Codable {
        var v: Int?
        let id: UUID
        let createdAt: Date
        let attachments: [StoredAttachment]
    }

    private struct StoredAttachment: Codable {
        let original: StoredFile
        let motion: StoredFile?
        let sidecar: StoredFile?
    }

    private struct StoredFile: Codable {
        let filename: String
        let contentType: String
        /// The file's name in the batch folder; a manifest without it is damaged.
        let name: String?
    }
}

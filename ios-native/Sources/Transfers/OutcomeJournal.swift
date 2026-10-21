import Foundation
import IlyichPlatform

/// Outcome files: the delegate records how each task ended in one before it reports the task
/// finished, so a result outlives the process and never needs the database. Paths are relative to
/// the App Group.
protocol OutcomeJournaling: Sendable {
    /// The file a path names, or nil when the App Group is unavailable.
    func url(for path: String) -> URL?
    func write(_ record: OutcomeRecord, to path: String) throws
    /// The outcome at a path, legacy or version 2, or nil when there is no file.
    func read(_ path: String) throws -> OutcomeRecord?
    func exists(_ path: String) -> Bool
    /// Deletes a file. A file that is already gone is not an error.
    func remove(_ path: String) throws
}

/// Outcome files in the App Group container.
struct FileOutcomeJournal: OutcomeJournaling {
    /// Nil when the App Group is unavailable: every write then fails, and no task reports success.
    let layout: AppGroupLayout?

    func url(for path: String) -> URL? { layout?.url(forRelativePath: path) }

    func write(_ record: OutcomeRecord, to path: String) throws {
        guard let url = url(for: path) else { throw AppGroupError.unavailable }
        // Atomic, so a reader never sees half a file, and readable after the first unlock like
        // every outcome before it. A missing folder is not recreated: it was swept or signed out.
        try OutcomeRecord.encoded(record).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func read(_ path: String) throws -> OutcomeRecord? {
        guard let url = url(for: path) else { throw AppGroupError.unavailable }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(OutcomeRecord.self, from: Data(contentsOf: url))
    }

    func exists(_ path: String) -> Bool {
        url(for: path).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func remove(_ path: String) throws {
        guard let url = url(for: path) else { throw AppGroupError.unavailable }
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
}

extension OutcomeRecord {
    static let version = 2

    /// Version 2 is written with sorted keys and plain slashes, the same bytes every time. Earlier
    /// builds still read it: they decode receipt, error and httpStatus and ignore the rest.
    static func encoded(_ record: OutcomeRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }
}

/// Failures the transport records itself, in outcome files' errorDomain app.ilyich.transport.
enum TransportOutcomeCode: Int, Sendable {
    /// The answer passed 64 KiB, so the task was cancelled unread.
    case responseTooLarge = 1
    /// A success status whose body is not a receipt for a created or duplicate asset.
    case invalidReceipt = 2
    /// The task ended with neither an error nor a response.
    case noResponse = 3
    /// The session followed a redirect to another origin, which a background session does without
    /// asking. The body may have gone there; what that server answered, its status included, is
    /// not recorded, since it says nothing about this upload.
    case redirected = 4

    static let domain = "app.ilyich.transport"
}

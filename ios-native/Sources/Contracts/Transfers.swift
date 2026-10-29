import Foundation
import IlyichPlatform

enum TransferLane: String, Hashable, Sendable {
    /// Backups of phone photos. The run intent gates only this lane.
    case library
    /// Files from the Share extension, uploaded once approved.
    case share
}

/// What a job uploads.
enum TransferSource: Hashable, Sendable {
    case photo(DeviceAssetID)
    /// An attachment of a share batch, named by its original's file name.
    case shared(batch: UUID, attachment: String)
}

enum JobOrigin: String, Hashable, Sendable {
    /// `legacy` is a job B9 imported from an earlier build's queue; the database still holds them.
    case discovery, selection, albumUpload, shareApproval, legacy
}

enum JobState: String, Hashable, Sendable {
    case queued, staging, staged, submitting, submitted, finalizing, retryScheduled, waiting, failed
}

/// Whether the library lane runs: not at all, whenever conditions allow, or because the user asked now.
enum RunIntent: String, Hashable, Sendable {
    case paused, automatic, manual
}

/// A claim on one job. A commit applies only while its lease token still matches.
struct Lease: Hashable, Sendable {
    let job: Int64
    let token: UUID
    let epoch: AuthorizationEpoch
}

/// One upload attempt. New attempts are UUIDs; a stage ID imported from an earlier build (B9) or a
/// share identity is kept verbatim, since it already names files.
struct AttemptID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init() { rawValue = UUID().uuidString }
    init(legacy value: String) { rawValue = value }
    var description: String { rawValue }
}

/// The two background URLSessions. Their identifiers derive from the bundle identifier, which the
/// sideloading tool rewrites (on the phone, app.alextran.immich.H4K2MSF2SG), and never change.
enum TransferSessionID: String, CaseIterable, Hashable, Sendable {
    case backup
    case shareUpload = "share-upload"

    var identifier: String { identifier(bundleIdentifier: Bundle.main.bundleIdentifier) }
    func identifier(bundleIdentifier: String?) -> String { (bundleIdentifier ?? "app.alextran.immich") + "." + rawValue }
}

/// What a background upload task's taskDescription says about it.
enum TaskDescriptor: Equatable, Sendable {
    /// Written from B9: the attempt, the account digest and the outcome file relative to the App Group.
    case v2(attempt: AttemptID, scope: String, outcome: String)
    /// Written by every build before B9: {id, receipt}, a stage ID or share identity and the
    /// outcome file's absolute URL. Nothing reads such a task's answer any more (B10): recovery
    /// cancels the task and logs it, and it is never adopted or sent again.
    case legacy
    /// Not written by this app, or unreadable.
    case foreign

    private struct Version2: Codable {
        let v: Int
        let attempt: String
        let scope: String
        let outcome: String
    }
    private struct Version: Decodable { let v: Int? }
    /// The keys every build before B9 wrote, read only to tell such a task from another app's.
    private struct Unversioned: Decodable {
        let id: String
        let receipt: String
    }

    init(taskDescription: String?) {
        guard let data = taskDescription?.data(using: .utf8), let version = try? JSONDecoder().decode(Version.self, from: data) else {
            self = .foreign; return
        }
        guard let v = version.v else {
            self = (try? JSONDecoder().decode(Unversioned.self, from: data)) == nil ? .foreign : .legacy
            return
        }
        guard v == 2, let value = try? JSONDecoder().decode(Version2.self, from: data), !value.attempt.isEmpty,
              Self.isRelative(value.outcome) else { self = .foreign; return }
        self = .v2(attempt: AttemptID(legacy: value.attempt), scope: value.scope, outcome: value.outcome)
    }

    /// The text to set as taskDescription: version 2, written with sorted keys and plain slashes.
    /// Nothing else is written.
    var taskDescription: String? {
        guard case .v2(let attempt, let scope, let outcome) = self else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(Version2(v: 2, attempt: attempt.rawValue, scope: scope, outcome: outcome))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The attempt the task belongs to, for a version 2 task.
    var attempt: AttemptID? {
        guard case .v2(let attempt, _, _) = self else { return nil }
        return attempt
    }

    /// The outcome file, relative to the App Group, for a version 2 task.
    var outcomePath: String? {
        guard case .v2(_, _, let outcome) = self else { return nil }
        return outcome
    }

    private static func isRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("://") && !path.split(separator: "/").contains("..")
    }
}

/// An outcome file: the keys every build wrote (receipt, error, httpStatus), plus what version 2
/// adds. Classify it only by its receipt, its status and a version 2 file's error domain and code.
struct OutcomeRecord: Codable, Equatable, Sendable {
    struct Receipt: Codable, Equatable, Sendable {
        let id: String
        /// created or duplicate.
        let status: String
    }

    var receipt: Receipt?
    /// A localized description. Never parse it.
    var error: String?
    var httpStatus: Int?
    var errorDomain: String?
    var errorCode: Int?
    /// NSURLErrorBackgroundTaskCancelledReasonKey when iOS cancelled the task.
    var cancelReason: Int?
    /// 2 from B9; absent in files builds before it wrote.
    var v: Int?
}

/// Where the transfer engine is, for the backup screen and notifications.
enum TransferPhase: Hashable, Sendable {
    case idle
    case discovering
    case running
    case waiting(WaitReason)
    case blocked(AccountRestriction)
}

struct TransferSnapshot: Hashable, Sendable {
    var intent: RunIntent
    var phase: TransferPhase
    var remaining: Int
    var confirmed: Int
    var failed: Int
    /// The current file's progress, from 0 to 1, when known.
    var fileProgress: Double?
    var bytesSent: Int64
    var bytesExpected: Int64
    var bytesPerSecond: Int64?
    /// The last error to show, until the next run clears it.
    var lastMessage: String?
    /// What backup is doing, in words, for the status line: EngineBackend words the engine's
    /// phase, and the screens' router its placeholders.
    var activity: String? = nil
}

enum EnqueueResult: Hashable, Sendable {
    case queued(Int)
    case alreadyBackedUp(Int)
    case refused(AccountRestriction)
}

/// A job to add: what to upload, why, and for a photo the revision it has now, which a
/// confirmation of the same revision already covers.
struct TransferRequest: Hashable, Sendable {
    var source: TransferSource
    var origin: JobOrigin
    var revision: AssetRevision?
    /// The file name shown with the job.
    var displayName: String?
    /// The notification batch the job counts in.
    var batch: UUID?
    /// The server album a photo joins once backed up (B4, Upload to album). Ignored for a shared file.
    var album: String? = nil
}

/// Photos still waiting to join a server album after their backup, and how many of them failed.
struct AlbumUploadCount: Hashable, Sendable {
    var pending: Int
    var failed: Int
}

/// A job as the queue and failure lists show it.
struct TransferQueueItem: Hashable, Sendable {
    let source: TransferSource
    let state: JobState
    /// Its place in its lane's order, which a queue page continues after.
    let seq: Int64
    let displayName: String?
    /// The last failure's message.
    let message: String?
    let failedAt: Date?
}

/// A photo the transfer engine confirmed.
struct TransferHistoryItem: Hashable, Sendable {
    let localID: DeviceAssetID
    /// Nil for a confirmation imported from an earlier build's records, which kept no time.
    let confirmedAt: Date?
}

/// The commands and reads the backup and share screens use (B8). Commands write rows and wake the
/// engine's loop; they never run transfers themselves.
protocol TransferControlling: Sendable {
    func setIntent(_ intent: RunIntent) async throws
    func enqueue(_ requests: [TransferRequest]) async throws -> EnqueueResult
    func cancel(_ sources: [TransferSource]) async throws
    func setPreferences(_ preferences: TransferPreferences) async throws
    /// The preferences in effect, nil before any were saved.
    func preferences() async throws -> TransferPreferences?
    /// Retries failed jobs: those named, or every one for nil. An explicit retry also lifts an
    /// account block whose cause has gone.
    func retry(_ sources: [TransferSource]?) async throws
    /// The engine's state now, then its changes at most four times a second.
    func snapshots() async -> AsyncStream<TransferSnapshot>
    func queuePage(lane: TransferLane, after seq: Int64?, limit: Int) async throws -> [TransferQueueItem]
    func historyPage(offset: Int, limit: Int) async throws -> [TransferHistoryItem]
    func failures(limit: Int) async throws -> [TransferQueueItem]
    /// Photos waiting for each server album, by album ID.
    func albumUploadCounts() async throws -> [String: AlbumUploadCount]
}

// MARK: Receipts

/// One part of a backed-up photo on the server: the still or video, or a Live Photo's video.
struct RemoteCopy: Hashable, Sendable {
    let id: String
    /// Base64 SHA-1, as the server reports it.
    let checksum: String
    /// The size the server reported at the last cleanup check; nil until one has run.
    var byteCount: Int64?
}

/// Proof that a photo was backed up: what it was when it was uploaded, and its server copies.
struct TransferReceipt: Hashable, Sendable {
    let localID: String
    /// PHAsset.modificationDate when it was uploaded, bit for bit.
    let revision: AssetRevision
    var original: RemoteCopy
    /// A Live Photo's video.
    var motion: RemoteCopy?
    let confirmedAt: Date?
    /// When a cleanup check last measured its sizes.
    var verifiedAt: Date?
    /// When cleanup removed the photo from the phone.
    var localDeletedAt: Date?
}

/// A phone photo and the server asset it was backed up as.
struct ReceiptAssociation: Hashable, Sendable {
    let localID: String
    let assetID: String
}

/// Sizes a cleanup check measured for one receipt, recorded only while the receipt is still the
/// one checked: the same revision and the same server copies.
struct VerifiedSizes: Hashable, Sendable {
    let localID: String
    let revision: AssetRevision
    let originalID: String
    let motionID: String?
    let originalBytes: Int64?
    let motionBytes: Int64?
}

/// Backup receipts for cleanup and the phone's timeline. Pages run in local ID order; `after` is
/// the last local ID of the page before, nil for the first.
protocol ReceiptQuery: Sendable {
    func receipts(for localIDs: [String]) async throws -> [String: TransferReceipt]
    func associations(after localID: String?, limit: Int) async throws -> [ReceiptAssociation]
    /// Receipts whose photo is still on the phone, for a cleanup check.
    func receiptsForVerification(after localID: String?, limit: Int) async throws -> [TransferReceipt]
    /// Records each measured size whose receipt is unchanged, and returns how many were.
    func updateVerifiedSizes(ifUnchanged sizes: [VerifiedSizes], at date: Date) async throws -> Int
}

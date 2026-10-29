import CryptoKit
import Foundation
import IlyichPlatform
import os

/// Retires the state.json an older build left in an account's Backup folder (B10). B9 imported it
/// into the transfers database and left it in place as the way back for an older build; the owner
/// ruled that way back out, so the file goes once nothing can need it:
/// - only from a database the engine owns through B9's import (mode authoritative) whose recorded
///   digest is the file's own: everything the file says is in the database;
/// - only while iOS holds no upload an older build described, in either session. Recovery cancels
///   such a task when it finds it, and the file waits for a start that finds none.
/// An account whose state.json no import read (one last signed in before B9) has it imported
/// before its engine starts (LegacyBackupImporter, AccountRuntime.prepareTransfers), so it goes
/// here like any other. A file beside a database the engine took over without importing it stays
/// unread (only an older build, reinstalled, could write one). Whatever stays is logged with its
/// reason and shown in Diagnostics. The stage folders older builds left, once nothing refers to
/// them, are recovery's sweep's (R5), which waits while iOS holds an older build's upload, and
/// leaves a Backup folder alone while a state.json no import read is in it.
enum LegacyRetirement {
    /// The file builds before B9 kept an account's backup in, in its Backup folder.
    static let fileName = "state.json"

    enum Outcome: Equatable, Sendable {
        /// There is no state.json: the account never backed up with an older build, or its file went earlier.
        case nothingLeft
        /// state.json went now.
        case removed
        /// state.json stays, for this reason.
        case kept(Reason)
    }

    enum Reason: Equatable, Sendable {
        /// No import read this account's state.json.
        case neverImported
        /// iOS still holds uploads an older build started, this many.
        case olderUploads(Int)
        /// state.json changed after the import read it, which only an older build does.
        case changedSinceImport
        /// state.json or the database couldn't be read, or the file removed, now.
        case unavailable

        /// For Diagnostics and the console.
        var text: String {
            switch self {
            case .neverImported: "they were never moved to the new backup engine and stay unread."
            case .olderUploads(let count):
                "\(count) upload\(count == 1 ? "" : "s") an older version started \(count == 1 ? "was" : "were") still with iOS; stopped now, and the records go at the next launch."
            case .changedSinceImport: "an older version changed them after they were moved; they stay unread."
            case .unavailable: "they couldn’t be read or removed now; Ilyich tries again at the next launch."
            }
        }
    }

    /// Retires the account's state.json, if it can go, as its TransferRuntime starts, after the
    /// first reconcile. The file is read and hashed on the database's queue.
    static func run(store: TransferStore, layout: AppGroupLayout, account: AccountID, transports: [any TransferTransport]) async -> Outcome {
        var olderUploads = 0
        for transport in transports { olderUploads += await transport.inventory().legacy.count }
        let folder = layout.url(forRelativePath: AccountStoragePaths(account).backup)
        let outcome = await store.retireLegacyState(in: folder, olderUploads: olderUploads)
        switch outcome {
        case .nothingLeft: break
        case .removed: logger.notice("The backup records an older version of Ilyich kept (state.json) are removed")
        case .kept(let reason): logger.notice("The backup records an older version of Ilyich kept (state.json) stay: \(reason.text, privacy: .public)")
        }
        return outcome
    }

    static let logger = Logger(subsystem: "app.ilyich.native", category: "Transfers")
}

extension TransferStore {
    /// LegacyRetirement's decision for the state.json in `folder`, given how many uploads an older
    /// build started iOS still holds. Removes the file when it can go.
    func retireLegacyState(in folder: URL, olderUploads: Int) -> LegacyRetirement.Outcome {
        let file = folder.appendingPathComponent(LegacyRetirement.fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: file.path) else { return .nothingLeft }
        guard let meta = try? meta() else { return .kept(.unavailable) }
        guard meta.engine == .transfer, meta.legacyImportMode == .authoritative, let imported = meta.legacyImportDigest else {
            return .kept(.neverImported)
        }
        guard olderUploads == 0 else { return .kept(.olderUploads(olderUploads)) }
        let data: Data
        do { data = try Data(contentsOf: file, options: .mappedIfSafe) } catch { return .kept(.unavailable) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == imported else { return .kept(.changedSinceImport) }
        do { try FileManager.default.removeItem(at: file) } catch { return .kept(.unavailable) }
        return .removed
    }
}

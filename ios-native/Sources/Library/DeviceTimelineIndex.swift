import CryptoKit
import Foundation
import Observation

/// Only backup-selected albums join the main timeline, matching the incumbent
/// client. Discovery and cloud-ID lookup run off the UI thread; hashing is serial,
/// cancellable, and never downloads originals from iCloud. It reads the phone again after each
/// burst of changes the Photos adapter reports.
@MainActor @Observable final class DeviceTimelineIndex {
    private(set) var snapshot = MergedTimeline()
    private(set) var revision = 0
    private(set) var isIndexing = false
    @ObservationIgnored private var source: Source?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var changes: Task<Void, Never>?

    private struct Source: Sendable {
        let scope: String
        let entities: LibraryIndex?
        let preferences: BackupPreferences
        let receipts: [String: BackupReceipt]
    }

    func configure(scope: String, entities: LibraryIndex?, preferences: BackupPreferences, receipts: [String: BackupReceipt]) {
        source = Source(scope: scope, entities: entities, preferences: preferences, receipts: receipts)
        if changes == nil {
            let stream = PhotoKitAdapter.shared.changes()
            changes = Task { [weak self] in
                for await _ in stream { self?.refresh() }
            }
        }
        refresh()
    }
    func stop() {
        generation = UUID(); worker?.cancel(); worker = nil; source = nil; isIndexing = false
        changes?.cancel(); changes = nil
    }

    private func refresh() {
        worker?.cancel(); generation = UUID()
        guard let source else { return }
        let current = generation
        guard PhotoKitAdapter.canRead(PhotoKitAdapter.shared.authorization), !source.preferences.includedAlbums.isEmpty else {
            snapshot = MergedTimeline(); revision += 1; isIndexing = false; return
        }
        isIndexing = true
        worker = Task.detached(priority: .utility) { [weak self] in
            do {
                let locals = try await PhotoKitAdapter.shared.timelineItems(included: source.preferences.includedAlbums,
                                                                            excluded: source.preferences.excludedAlbums)
                try Task.checkCancellation()
                var remotes: [LocalAssetMatch] = []
                if let entities = source.entities, try await entities.isComplete() {
                    var offset = 0
                    while true {
                        let page = try await entities.localAssetMatches(offset: offset, limit: 2_000)
                        remotes += page; offset += page.count
                        if page.count < 2_000 { break }
                        try Task.checkCancellation()
                    }
                }
                let byID = Dictionary(remotes.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first })
                let byHash = Dictionary(remotes.map { ($0.checksum, $0.assetID) }, uniquingKeysWith: { first, _ in first })
                let byCloud = Dictionary(grouping: remotes.compactMap { row in row.cloudID.map { ($0, row) } }, by: { $0.0 })
                let fingerprints = LocalFingerprintCache(scope: source.scope)
                var cached = await fingerprints.load()
                var associations: [String: String] = [:]
                for local in locals {
                    let photo = local.photo
                    if let receipt = source.receipts[photo.id], photo.modified == receipt.modificationDate,
                       byID[receipt.original.id]?.checksum == receipt.original.checksum {
                        associations[photo.id] = receipt.original.id
                    } else if let fingerprint = cached[photo.id], fingerprint.modified == photo.modified,
                              let remote = byHash[fingerprint.checksum] {
                        associations[photo.id] = remote
                    } else if local.unadjusted, let cloudID = local.cloudID,
                              let remote = byCloud[cloudID]?.first(where: { LocalIdentityMatch.matches(photo, remote: $0.1) })?.1 {
                        associations[photo.id] = remote.assetID
                    }
                }
                try Task.checkCancellation()
                await self?.publish(MergedTimeline(photos: locals.map(\.photo), associations: associations), generation: current)

                // An incomplete server index cannot prove that a local fingerprint
                // is absent. Wait for sync rather than hashing the whole device twice.
                guard !remotes.isEmpty else { await self?.finished(generation: current); return }
                var changes = 0, fingerprintsSinceSave = 0
                for local in locals where associations[local.photo.id] == nil {
                    try Task.checkCancellation()
                    guard !ProcessInfo.processInfo.isLowPowerModeEnabled,
                          ProcessInfo.processInfo.thermalState != .serious,
                          ProcessInfo.processInfo.thermalState != .critical else { break }
                    let photo = local.photo
                    if cached[photo.id]?.modified == photo.modified { continue }
                    do {
                        let checksum = try await PhotoKitAdapter.shared.fingerprint(of: photo.id)
                        try Task.checkCancellation()
                        guard await PhotoKitAdapter.shared.revision(of: photo.id) == photo.modified else { continue }
                        cached[photo.id] = .init(modified: photo.modified, checksum: checksum)
                        fingerprintsSinceSave += 1
                        if fingerprintsSinceSave >= 25 {
                            await fingerprints.save(cached); fingerprintsSinceSave = 0
                        }
                        if let id = byHash[checksum] { associations[photo.id] = id; changes += 1 }
                        if changes >= 20 {
                            await self?.publish(MergedTimeline(photos: locals.map(\.photo), associations: associations), generation: current)
                            changes = 0
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* Cloud-only and unavailable files keep their honest local-only state. */ }
                    try await Task.sleep(for: .milliseconds(30))
                }
                try Task.checkCancellation()
                let ids = Set(locals.map { $0.photo.id })
                await fingerprints.save(cached.filter { ids.contains($0.key) })
                await self?.publish(MergedTimeline(photos: locals.map(\.photo), associations: associations), generation: current)
            } catch is CancellationError { }
            catch { /* Keep the previous snapshot; a later activation/change retries discovery. */ }
            await self?.finished(generation: current)
        }
    }
    private func publish(_ value: MergedTimeline, generation current: UUID) {
        guard current == generation else { return }
        snapshot = value; revision += 1
    }
    private func finished(generation current: UUID) {
        guard current == generation else { return }
        isIndexing = false; worker = nil
    }
}

enum LocalIdentityMatch {
    static func matches(_ photo: LocalPhoto, remote: LocalAssetMatch) -> Bool {
        guard remote.adjustmentTime == nil, let localDate = photo.date, let remoteDate = remote.createdAt else { return false }
        return Int64(localDate.timeIntervalSince1970) == Int64(remoteDate.timeIntervalSince1970)
            && photo.latitude == remote.latitude && photo.longitude == remote.longitude
    }
}

actor LocalFingerprintCache {
    struct Fingerprint: Codable, Sendable { let modified: Date?; let checksum: String }
    private let url: URL
    init(scope: String) {
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IlyichFingerprints", isDirectory: true).appendingPathComponent(name + ".json")
    }
    func load() -> [String: Fingerprint] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Fingerprint].self, from: data)) ?? [:]
    }
    func save(_ values: [String: Fingerprint]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { /* The cache is disposable; never mark an upload or deletion from it. */ }
    }
}

import Foundation

/// What the device index reads of the Photos library (PhotoKitIndexReader over the app's one
/// adapter; tests fake it).
protocol DeviceIndexReading: Sendable {
    /// Photos access now.
    func access() async -> DeviceAccess
    /// The library's changes from now on.
    func changes() -> AsyncStream<DeviceLibraryChange>
    /// All readable photos and videos, or those in `included`, minus `excluded`, identifiers only.
    func members(scope: PhotoSelectionScope, included: Set<String>, excluded: Set<String>) async throws -> Set<String>
    /// Reads these assets again. Those Photos no longer has are left out.
    func items(_ ids: [String]) async throws -> [DeviceTimelineItem]
    /// The SHA-1 of the asset's current full-size file, never downloaded from iCloud.
    func fingerprint(of id: String) async throws -> String
    /// The asset's modification date now, nil when it has none or is gone.
    func revision(of id: String) async -> Date?
}

/// The server's side of matching: the identity rows of the owner's photos.
protocol DeviceIndexServer: Sendable {
    /// Every identity row in ID order, each saying whether the timeline shows it, or nil while
    /// the offline library isn't complete, when it can't prove a phone photo is absent from the
    /// server.
    func identities() async throws -> [LocalAssetMatch]?
    /// Only these owner identities, including hidden/trashed rows. Nil if unsupported or incomplete.
    func identities(ids: Set<String>) async throws -> [LocalAssetMatch]?
    /// An exact owner's identity and its currently accessible server record. A missing/deleted
    /// record is not a match, even if the offline library or an old receipt still names it.
    func copy(id: String) async throws -> DeviceServerCopy?
    /// Exact candidates for one stored checksum or cloud identity, without a full index pass.
    func identities(checksum: String?, cloudID: String?) async throws -> [LocalAssetMatch]
    /// Cheap completion check; absence from a partial catalog is not a missing server copy.
    func identityIndexComplete() async throws -> Bool
    /// The library's changes from now on.
    func changes() async -> AsyncStream<LibraryChange>
}

struct DeviceServerCopy: Sendable {
    let identity: LocalAssetMatch
    let asset: Asset
}

extension DeviceIndexServer {
    /// Never fall back to a full-catalog scan for background receipt revalidation.
    func identities(ids: Set<String>) async throws -> [LocalAssetMatch]? { nil }
    func copy(id: String) async throws -> DeviceServerCopy? { nil }
    func identityIndexComplete() async throws -> Bool { try await identities() != nil }
    func identities(checksum: String?, cloudID: String?) async throws -> [LocalAssetMatch] {
        guard checksum != nil || cloudID != nil else { return [] }
        return try await identities()?.filter { row in
            (checksum != nil && row.fileChecksum == checksum) || (cloudID != nil && row.cloudID == cloudID)
        } ?? []
    }
}

/// What backup tells the device index: the Photos selection and what was uploaded.
struct DeviceIndexBackupInputs: Equatable, Sendable {
    var scope: PhotoSelectionScope = .selectedAlbums
    var included: Set<String> = []
    var excluded: Set<String> = []
    /// The account's receipts by local ID.
    var receipts: [String: CleanupReceipt] = [:]
    /// Existing Photos excluded by a saved future-only starting point. Cached associations
    /// remain useful, but background timeline matching must not read these originals.
    var fingerprintExcludedIDs: Set<String> = []
}

/// Backup's preferences and receipts for the device index: the transfers database's
/// (CutoverReceipts), read as ReceiptRepository reads the receipts.
protocol DeviceIndexBackupSource: Sendable {
    /// The account's inputs, or nil while its backup state isn't the one taken up.
    func inputs(account: String) async -> DeviceIndexBackupInputs?
    /// One current receipt for source selection, without loading the entire backup history.
    func receipt(for localID: String, account: String) async -> DeviceBackupReceipt
    /// Tells of every change to them from now on, merged while unread.
    func changes() async -> AsyncStream<Void>
}

enum DeviceBackupReceipt: Sendable {
    case available(CleanupReceipt?)
    case unavailable
}

extension DeviceIndexBackupSource {
    func receipt(for localID: String, account: String) async -> DeviceBackupReceipt {
        guard let inputs = await inputs(account: account) else { return .unavailable }
        return .available(inputs.receipts[localID])
    }
}

/// The phone's photos as the merged library shows them at one moment.
struct DeviceIndexSnapshot: Sendable {
    let access: DeviceAccess
    /// What LibraryFeedStore merges today.
    let timeline: MergedTimeline
    /// Every phone photo in the backup albums, by local ID.
    let items: [String: DeviceTimelineItem]
    /// Phone photo to the server asset it matched.
    let associations: [String: String]

    static func empty(_ access: DeviceAccess) -> DeviceIndexSnapshot {
        DeviceIndexSnapshot(access: access, timeline: MergedTimeline(), items: [:], associations: [:])
    }

    /// The contract's view (architecture section 2): phone-only photos by month, newest first,
    /// each month with its digest, and the matches. Months are those MergedTimeline files them in.
    func device() -> DeviceSnapshot {
        var months: [MonthKey: DeviceSnapshot.Month] = [:]
        for (key, photos) in timeline.localOnly {
            guard let month = MonthKey(bucketID: key + "-01") else { continue }
            months[month] = DeviceSnapshot.Month(assets: photos.compactMap { items[$0.id]?.asset })
        }
        var matches: [DeviceAssetID: String] = [:]
        for (local, remote) in associations { matches[DeviceAssetID(rawValue: local)] = remote }
        return DeviceSnapshot(access: access, months: months, matches: matches)
    }
}

/// The phone's side of the merged library (REBUILD_ROADMAP.md P5), one per account runtime, which
/// owns it and shuts it down. It replaces DeviceTimelineIndex, which LibraryView owned and which
/// read the whole phone again after every change.
///
/// - It starts once a screen subscribes, and works only while the app is in front.
/// - The phone photos of the backup albums are read once; after that a change from Photos re-reads
///   only the assets it names, and album membership, identifiers only, when albums may have changed.
/// - Matching is today's, in order: a receipt for the same revision whose server copy is still
///   there, a fingerprint for the same revision with the server's checksum, then for an unedited
///   photo its cloud identity. Only server photos the timeline shows count, so a phone copy of a
///   trashed or archived photo stays a phone photo.
/// - Fingerprints are kept in device.sqlite, so a photo is hashed once per revision. Hashing is
///   serial, never downloads, waits in Low Power mode and when the phone is hot, checks the
///   revision again before keeping a checksum, and only runs once the offline library is complete.
actor DeviceIndexService {
    /// What a publish is compared on, so an identical one is not sent.
    private struct Published: Equatable {
        var itemsVersion: UInt64
        var associations: [String: String]
        var visibleLocalIDs: Set<String>
        var access: DeviceAccess
    }

    nonisolated let account: String
    private let reader: any DeviceIndexReading
    private let server: (any DeviceIndexServer)?
    private let backup: any DeviceIndexBackupSource
    private let database: DeviceDatabase
    private let presence: AppPresence
    private let pause: Duration
    private let coalescing: Duration
    private let powerAllowsHashing: @Sendable () -> Bool
    private let authorization: AuthorizationState?

    private var started = false
    private var ended = false
    private var tasks: [Task<Void, Never>] = []
    private var retry: Task<Void, Never>?
    private let wake: AsyncStream<Void>.Continuation
    private let wakes: AsyncStream<Void>
    private var subscribers: [UUID: AsyncStream<DeviceIndexSnapshot>.Continuation] = [:]

    // Inputs.
    private var inputs: DeviceIndexBackupInputs?
    private var needsInputs = true
    private var needsMembership = true
    private var needsRemotes = true
    private var fullReload = false
    private var pending: Set<String> = []
    private var removed: Set<String> = []
    private var access = DeviceAccess(status: .notDetermined, generation: 0)

    // What the index holds.
    private var members: Set<String>?
    private var items: [String: DeviceTimelineItem] = [:]
    private var itemsVersion: UInt64 = 0
    private var remotes = Remotes()
    private var fingerprints: [String: DeviceFingerprint]?
    private var unsaved: [String: DeviceFingerprint] = [:]
    /// Photos whose hashing failed at the revision given, not tried again until the app comes forward.
    private var failed: [String: Date?] = [:]
    private var associations: [String: String] = [:]
    private var queue: [String] = []
    private var cursor = 0
    private var matchedSincePublish = 0
    private var dirty = false
    private var published: Published?
    private var latest: DeviceIndexSnapshot?

    /// The server's identity rows, indexed as matching reads them. Only those the timeline shows
    /// can be matched; the hidden ones (archived, hidden, locked, trashed) only spare a phone photo
    /// uploaded as one of them a fingerprint that could never match.
    private struct Remotes {
        var complete = false
        var rows: [LocalAssetMatch] = []
        var byID: [String: LocalAssetMatch] = [:]
        var byHash: [String: String] = [:]
        var byCloud: [String: [LocalAssetMatch]] = [:]
        var hiddenByID: [String: LocalAssetMatch] = [:]
        var hiddenByCloud: [String: [LocalAssetMatch]] = [:]

        init(_ identities: [LocalAssetMatch]? = nil) {
            complete = identities != nil
            let all = identities ?? []
            let rows = all.filter(\.visible), hidden = all.filter { !$0.visible }
            self.rows = rows
            byID = Dictionary(rows.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first })
            byHash = Dictionary(rows.compactMap { row in row.fileChecksum.map { ($0, row.assetID) } }, uniquingKeysWith: { first, _ in first })
            byCloud = Dictionary(grouping: rows.filter { $0.cloudID != nil }, by: { $0.cloudID ?? "" })
            hiddenByID = Dictionary(hidden.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first })
            hiddenByCloud = Dictionary(grouping: hidden.filter { $0.cloudID != nil }, by: { $0.cloudID ?? "" })
        }
    }

    /// `pause` is the wait between two photos hashed; `coalescing`, how long server changes are
    /// gathered before they are read (backup changes, five times as long).
    init(account: String, reader: any DeviceIndexReading, server: (any DeviceIndexServer)?, backup: any DeviceIndexBackupSource,
         database: DeviceDatabase, presence: AppPresence,
         pause: Duration = .milliseconds(30), coalescing: Duration = .seconds(1),
         powerAllowsHashing: @escaping @Sendable () -> Bool = DeviceIndexService.powerAllowsHashing,
         authorization: AuthorizationState? = nil) {
        self.account = account
        self.reader = reader
        self.server = server
        self.backup = backup
        self.database = database
        self.presence = presence
        self.pause = pause
        self.coalescing = coalescing
        self.powerAllowsHashing = powerAllowsHashing
        self.authorization = authorization
        (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Low Power mode is off and the phone isn't hot.
    nonisolated static func powerAllowsHashing() -> Bool {
        let info = ProcessInfo.processInfo
        return !info.isLowPowerModeEnabled && info.thermalState != .serious && info.thermalState != .critical
    }

    // MARK: - Subscribing

    /// The snapshots from now on, the latest first if there is one. The first subscriber starts
    /// the index.
    func snapshots() -> AsyncStream<DeviceIndexSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceIndexSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        guard !ended else { continuation.finish(); return stream }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        if let latest { continuation.yield(latest) }
        start()
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// The latest snapshot, nil before the first.
    var snapshot: DeviceIndexSnapshot? { latest }

    /// Resolves a tapped phone row again, since matching may have finished after that row was
    /// displayed. Reads metadata and known identities only: opening a photo never hashes or
    /// downloads an original just to find its server copy. A known server outage remains
    /// distinct from an unmatched phone item and cannot turn into an automatic iCloud request.
    func resolveSource(of photo: LocalPhoto) async -> MediaSourceResolution {
        let epoch = authorization?.snapshot.epoch
        func authorized() -> Bool {
            guard !ended, !Task.isCancelled else { return false }
            guard let authorization else { return true }
            return authorization.account.digest == account && authorization.permitsServiceUse
                && authorization.snapshot.allows(.read) && epoch.map(authorization.isCurrent) == true
        }
        guard authorized() else { return .unavailable(message: "Your access changed. Open the photo again.") }
        let access = await reader.access()
        guard access.status == .authorized || access.status == .limited else {
            return .unavailable(message: "Allow Photos access to open this phone photo.")
        }
        guard let current = try? await reader.items([photo.id]).first, current.photo.modified == photo.modified else {
            return .unavailable(message: "This photo changed or is no longer on the phone. Open it again from the library.")
        }
        let receiptRead = await backup.receipt(for: photo.id, account: account)
        guard authorized() else { return .unavailable(message: "Your access changed. Open the photo again.") }
        var candidates: [(id: String, checksum: String, contentProof: Bool)] = []
        if let revision = current.photo.modified.map(AssetRevision.init),
           case .available(let stored) = receiptRead, let receipt = stored, receipt.revision == revision {
            candidates.append((receipt.original.id, receipt.original.checksum, true))
        }
        if items[photo.id]?.photo.modified == current.photo.modified,
           let remoteID = associations[photo.id], let identity = remotes.byID[remoteID] {
            candidates.append((remoteID, identity.checksum, false))
        }
        if current.unadjusted, let cloudID = current.cloudID,
           let identity = remotes.byCloud[cloudID]?.first(where: { LocalIdentityMatch.matches(current.photo, remote: $0) }) {
            candidates.append((identity.assetID, identity.checksum, false))
        }
        let fingerprint: DeviceFingerprint?
        if let known = fingerprints?[photo.id] { fingerprint = known }
        else { fingerprint = try? await database.fingerprint(for: photo.id) }
        let checksum = fingerprint.flatMap { $0.isCurrent(for: current.photo.modified) ? $0.checksum : nil }
        let cloudID = current.unadjusted ? current.cloudID : nil
        if let server, checksum != nil || cloudID != nil {
            let identities: [LocalAssetMatch]
            do { identities = try await server.identities(checksum: checksum, cloudID: cloudID) }
            catch { return .unavailable(message: "Could not check the photo’s server identity. Try again.") }
            guard authorized() else { return .unavailable(message: "Your access changed. Open the photo again.") }
            for identity in identities where identity.visible {
                let exactChecksum = checksum != nil && identity.fileChecksum == checksum
                let exactCloud = cloudID != nil && identity.cloudID == cloudID && LocalIdentityMatch.matches(current.photo, remote: identity)
                if (exactChecksum || exactCloud), !candidates.contains(where: { $0.id == identity.assetID && $0.checksum == identity.checksum }) {
                    candidates.append((identity.assetID, identity.checksum, false))
                }
            }
        }
        for candidate in candidates {
            let copy: DeviceServerCopy?
            do {
                guard let server else {
                    guard await sourceIsCurrent(photo, access: access), authorized() else {
                        return .unavailable(message: "Your access or this phone photo changed. Open it again.")
                    }
                    return .serverUnavailable(photo: photo, serverID: candidate.id, message: "The server library is unavailable. Try again shortly.")
                }
                copy = try await server.copy(id: candidate.id)
            } catch {
                guard authorized(), await sourceIsCurrent(photo, access: access), authorized() else {
                    return .unavailable(message: "Your access or this phone photo changed. Open it again.")
                }
                if case ServerFailure.notFound = error { continue }
                if error is CancellationError || error is PurchaseAccessRequired {
                    return .unavailable(message: error.localizedDescription)
                }
                switch error {
                case ServerFailure.sessionExpired, ServerFailure.forbidden, ServerFailure.proxyRejected,
                     ServerFailure.passwordChangeRequired, ServerFailure.credentialsRejected, APIError.signedOut:
                    return .unavailable(message: error.localizedDescription)
                default:
                    return .serverUnavailable(photo: photo, serverID: candidate.id, message: error.localizedDescription)
                }
            }
            guard let copy, authorized(),
                  copy.identity.assetID == candidate.id, copy.identity.visible,
                  (candidate.contentProof ? copy.identity.fileChecksum == candidate.checksum : copy.identity.checksum == candidate.checksum),
                  copy.asset.id == candidate.id, !copy.asset.isTrashed, copy.asset.visibility == .timeline else { continue }
            if let authorization, copy.asset.ownerId != authorization.account.userID { continue }
            guard await sourceIsCurrent(photo, access: access), authorized() else {
                return .unavailable(message: "Your access or this phone photo changed. Open it again.")
            }
            return .server(copy.asset)
        }
        guard authorized(), await sourceIsCurrent(photo, access: access), authorized() else {
            return .unavailable(message: "Your access or this phone photo changed. Open it again.")
        }
        if case .unavailable = receiptRead { return .unavailable(message: "Backup records are still being prepared. Try again shortly.") }
        return .device(photo)
    }

    private func sourceIsCurrent(_ photo: LocalPhoto, access: DeviceAccess) async -> Bool {
        let latest = try? await reader.items([photo.id]).first
        let after = await reader.access()
        return after == access && latest != nil && latest?.photo.modified == photo.modified
    }

    /// The app came forward or went to the background, as AppPresence now says.
    func presenceChanged() async {
        if presence.isForeground {
            // Changes made while the app was away may not all have been reported.
            needsMembership = true
            failed = [:]
            signal()
        } else {
            await saveFingerprints()
        }
    }

    /// Stops the index and keeps what was hashed. Nothing starts again.
    func shutdown() async {
        ended = true
        retry?.cancel()
        let running = tasks
        tasks = []
        for task in running { task.cancel() }
        wake.finish()
        for task in running { await task.value }
        await saveFingerprints()
        for subscriber in subscribers.values { subscriber.finish() }
        subscribers = [:]
    }

    // MARK: - Inputs

    private func start() {
        guard !started, !ended else { return }
        started = true
        let reader = reader, server = server, backup = backup, coalescing = coalescing
        // Receipts change with every upload; backup's first change is read at once and the rest
        // at most every few seconds, as nothing on screen waits for them.
        let backupCoalescing = coalescing * 5
        tasks.append(Task { [weak self] in
            for await change in reader.changes() { await self?.photosChanged(change) }
        })
        tasks.append(Task { [weak self] in
            for await _ in await backup.changes() {
                await self?.backupChanged()
                try? await Task.sleep(for: backupCoalescing)
            }
        })
        if let server {
            tasks.append(Task { [weak self] in
                for await _ in await server.changes() {
                    await self?.serverChanged()
                    try? await Task.sleep(for: coalescing)
                }
            })
        }
        tasks.append(Task { [weak self] in await self?.run() })
    }

    private func backupChanged() {
        needsInputs = true
        signal()
    }

    /// Any change to the offline library may add, remove or move an identity row.
    private func serverChanged() {
        needsRemotes = true
        signal()
    }

    private func signal() { wake.yield() }

    private func photosChanged(_ change: DeviceLibraryChange) {
        if change.requiresFullReload { fullReload = true }
        let named = change.inserted.union(change.removed).union(change.changed).map(\.rawValue)
        pending.formUnion(named)
        removed.formUnion(change.removed.map(\.rawValue))
        // Photos added to an album name no asset, a new photo joins smart albums, and a favorite or
        // an edit moves a photo in or out of smart albums such as Favorites, which Photos reports
        // only as a change to the photo. Membership is identifiers only, so it is read again.
        if change.albumsChanged || !change.inserted.isEmpty || !change.changed.isEmpty { needsMembership = true }
        signal()
    }

    // MARK: - The loop

    private func run() async {
        fingerprints = (try? await database.fingerprints()) ?? [:]
        var iterator = wakes.makeAsyncIterator()
        while !Task.isCancelled, !ended {
            if await step() { continue }
            guard await iterator.next() != nil else { return }
        }
    }

    /// Does one piece of work; false when there is none until something changes.
    private func step() async -> Bool {
        guard presence.isForeground else { return false }
        if needsInputs {
            needsInputs = false
            let read = await backup.inputs(account: account)
            if read?.scope != inputs?.scope || read?.included != inputs?.included || read?.excluded != inputs?.excluded { needsMembership = true }
            if read != inputs { dirty = true }
            inputs = read
            return true
        }
        // Before the account's backup state is taken up, nothing is known of its albums.
        guard let inputs else { return false }
        let now = await reader.access()
        if now.generation != access.generation || now.status != access.status {
            access = now
            fullReload = true
        }
        guard PhotoKitAdapter.canRead(now.status), (inputs.scope == .entireLibrary || !inputs.included.isEmpty) else {
            if members != nil || !items.isEmpty || published == nil { clear() }
            pending = []; removed = []; fullReload = false; needsMembership = true
            dirty = false
            return publish()
        }
        if fullReload {
            fullReload = false
            members = nil
            pending = []
            needsMembership = true
        }
        // A read that fails keeps what the index holds and is tried again at the next change.
        if needsMembership {
            needsMembership = false
            guard let found = try? await reader.members(scope: inputs.scope, included: inputs.included, excluded: inputs.excluded) else {
                needsMembership = true
                return false
            }
            // Only photos that joined are read; after a full reload, all of them.
            pending.formUnion(members.map { found.subtracting($0) } ?? found)
            for id in Set(items.keys).subtracting(found) { items[id] = nil; itemsVersion &+= 1 }
            members = found
            dirty = true
            return true
        }
        if !pending.isEmpty {
            let ids = pending.intersection(members ?? []).sorted()
            let gone = pending.subtracting(members ?? [])
            pending = []
            for id in gone where items[id] != nil { items[id] = nil; itemsVersion &+= 1 }
            guard let read = try? await reader.items(ids) else {
                pending.formUnion(ids)
                return false
            }
            var found = Set<String>()
            for item in read {
                found.insert(item.photo.id)
                if items[item.photo.id] != item { items[item.photo.id] = item; itemsVersion &+= 1 }
            }
            for id in ids where !found.contains(id) && items[id] != nil { items[id] = nil; itemsVersion &+= 1 }
            await forgetRemoved(found)
            dirty = true
            return true
        }
        if needsRemotes {
            needsRemotes = false
            do { remotes = Remotes(try await server?.identities()) }
            catch {
                needsRemotes = true
                return false
            }
            dirty = true
            return true
        }
        if dirty {
            dirty = false
            rematch()
            publish()
            return true
        }
        return await hashNext()
    }

    /// Fingerprints of photos Photos no longer has are forgotten.
    private func forgetRemoved(_ found: Set<String>) async {
        let gone = removed.subtracting(found)
        removed = []
        guard !gone.isEmpty else { return }
        for id in gone {
            fingerprints?[id] = nil
            unsaved[id] = nil
        }
        try? await database.removeFingerprints(gone.sorted())
    }

    private func clear() {
        members = nil
        if !items.isEmpty { items = [:]; itemsVersion &+= 1 }
        associations = [:]
        queue = []; cursor = 0
    }

    // MARK: - Matching

    private func rematch() {
        let receipts = inputs?.receipts ?? [:]
        let known = fingerprints ?? [:]
        var result: [String: String] = [:]
        var unhashed: [String] = []
        for id in items.keys.sorted() {
            guard let item = items[id] else { continue }
            let photo = item.photo
            let receipt = receipts[id].flatMap { photo.modified.map(AssetRevision.init) == $0.revision ? $0.original : nil }
            if let receipt, remotes.byID[receipt.id]?.fileChecksum == receipt.checksum {
                result[id] = receipt.id
            } else if let fingerprint = known[id], fingerprint.isCurrent(for: photo.modified), let remote = remotes.byHash[fingerprint.checksum] {
                result[id] = remote
            } else if item.unadjusted, let cloudID = item.cloudID,
                      let remote = remotes.byCloud[cloudID]?.first(where: { LocalIdentityMatch.matches(photo, remote: $0) }) {
                result[id] = remote.assetID
            } else if let receipt, remotes.hiddenByID[receipt.id]?.fileChecksum == receipt.checksum {
                // Uploaded as a photo the timeline doesn't show: the server keeps one checksum per
                // owner, so a fingerprint could only name that photo again.
                continue
            } else if item.unadjusted, let cloudID = item.cloudID,
                      remotes.hiddenByCloud[cloudID]?.contains(where: { LocalIdentityMatch.matches(photo, remote: $0) }) == true {
                continue
            } else if inputs?.fingerprintExcludedIDs.contains(id) != true {
                unhashed.append(id)
            }
        }
        associations = result
        // An incomplete offline library can't prove a fingerprint is absent from the server, so
        // nothing is hashed until it is complete.
        queue = remotes.complete ? unhashed : []
        cursor = 0
    }

    /// Sends a snapshot if it differs from the last one sent. True when one was sent.
    @discardableResult
    private func publish() -> Bool {
        matchedSincePublish = 0
        // Broadening backup to the whole phone must not insert thousands of unverified duplicate
        // rows into the server timeline. Only a complete identity set and a current fingerprint
        // can prove an unmatched photo is distinct. The index still holds every item for backup;
        // On this phone and the backup queue read Photos independently and remain available.
        let visibleLocalIDs = Set(items.keys.filter { id in
            inputs?.scope != .entireLibrary || associations[id] != nil
                || (remotes.complete && fingerprints?[id]?.isCurrent(for: items[id]?.photo.modified) == true)
        })
        let next = Published(itemsVersion: itemsVersion, associations: associations, visibleLocalIDs: visibleLocalIDs, access: access)
        guard next != published else { return false }
        published = next
        let photos = visibleLocalIDs.sorted().compactMap { items[$0]?.photo }
        let snapshot = DeviceIndexSnapshot(access: access, timeline: MergedTimeline(photos: photos, associations: associations),
                                           items: items, associations: associations)
        latest = snapshot
        for subscriber in subscribers.values { subscriber.yield(snapshot) }
        return true
    }

    // MARK: - Fingerprints

    private func hashNext() async -> Bool {
        while cursor < queue.count {
            let id = queue[cursor]
            guard let item = items[id], associations[id] == nil,
                  inputs?.fingerprintExcludedIDs.contains(id) != true else { cursor += 1; continue }
            let modified = item.photo.modified
            if fingerprints?[id]?.isCurrent(for: modified) == true { cursor += 1; continue }
            if let failure = failed[id], failure == modified { cursor += 1; continue }
            guard powerAllowsHashing() else {
                await saveFingerprints()
                retryLater()
                return false
            }
            cursor += 1
            do {
                let checksum = try await reader.fingerprint(of: id)
                // The photo may have changed while it was read.
                guard await reader.revision(of: id) == modified, items[id]?.photo.modified == modified else { return true }
                let fingerprint = DeviceFingerprint(modified: modified, checksum: checksum)
                fingerprints?[id] = fingerprint
                unsaved[id] = fingerprint
                if unsaved.count >= 25 { await saveFingerprints() }
                if associations[id] == nil, let remote = remotes.byHash[checksum] {
                    associations[id] = remote
                }
                matchedSincePublish += 1
                if matchedSincePublish >= 20 { publish() }
            } catch is CancellationError {
                return false
            } catch {
                // Cloud-only and unavailable files keep their honest phone-only state.
                failed[id] = modified
            }
            if pause > .zero { try? await Task.sleep(for: pause) }
            return true
        }
        await saveFingerprints()
        if matchedSincePublish > 0 { publish() }
        return false
    }

    /// Writes the fingerprints not yet kept, in one transaction. A failed write keeps them for
    /// the next one.
    private func saveFingerprints() async {
        guard !unsaved.isEmpty else { return }
        let values = unsaved
        unsaved = [:]
        do { try await database.saveFingerprints(values) }
        catch { unsaved.merge(values) { newer, _ in newer } }
    }

    /// Tries hashing again in a minute, when Low Power mode or the heat may have passed.
    private func retryLater() {
        guard retry == nil else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await self?.retried()
        }
    }

    private func retried() {
        retry = nil
        signal()
    }
}

enum LocalIdentityMatch {
    static func matches(_ photo: LocalPhoto, remote: LocalAssetMatch) -> Bool {
        guard remote.adjustmentTime == nil, let localDate = photo.date, let remoteDate = remote.createdAt else { return false }
        return Int64(localDate.timeIntervalSince1970) == Int64(remoteDate.timeIntervalSince1970)
            && photo.latitude == remote.latitude && photo.longitude == remote.longitude
    }
}

// MARK: - Live sources

/// The device index's reads over the app's one Photos adapter.
struct PhotoKitIndexReader: DeviceIndexReading {
    let adapter: PhotoKitAdapter

    func access() async -> DeviceAccess { await adapter.refreshAccess() }
    func changes() -> AsyncStream<DeviceLibraryChange> { adapter.changes() }
    func members(scope: PhotoSelectionScope, included: Set<String>, excluded: Set<String>) async throws -> Set<String> {
        try await adapter.timelineMembers(scope: scope, included: included, excluded: excluded)
    }
    func items(_ ids: [String]) async throws -> [DeviceTimelineItem] { try await adapter.timelineItems(ids) }
    func fingerprint(of id: String) async throws -> String { try await adapter.fingerprint(of: id) }
    func revision(of id: String) async -> Date? { await adapter.revision(of: id) }
}

/// The offline library's identity rows and the account's sync changes.
struct LibraryIndexIdentities: DeviceIndexServer {
    let entities: LibraryIndex
    let libraryChanges: @Sendable () async -> AsyncStream<LibraryChange>
    var lookup: (@Sendable (String) async throws -> DeviceServerCopy?)? = nil
    func identityIndexComplete() async throws -> Bool { try await entities.isComplete() }
    func identities(ids: Set<String>) async throws -> [LocalAssetMatch]? {
        guard try await entities.isComplete() else { return nil }
        return try await entities.identities(ids: ids)
    }

    func identities(checksum: String?, cloudID: String?) async throws -> [LocalAssetMatch] {
        try await entities.identities(checksum: checksum, cloudID: cloudID)
    }

    func copy(id: String) async throws -> DeviceServerCopy? {
        if let lookup {
            guard let copy = try await lookup(id), copy.asset.ownerId == entities.userID else { return nil }
            return copy
        }
        guard let identity = try await entities.identity(id: id), identity.visible else { return nil }
        let asset = try await entities.asset(id: id)
        guard let asset, asset.id == id, !asset.isTrashed, asset.visibility == .timeline else { return nil }
        return DeviceServerCopy(identity: identity, asset: asset)
    }

    func identities() async throws -> [LocalAssetMatch]? {
        guard try await entities.isComplete() else { return nil }
        var rows: [LocalAssetMatch] = []
        var cursor: String?
        while true {
            try Task.checkCancellation()
            let page = try await entities.identities(after: cursor, limit: 2_000)
            rows += page
            guard page.count == 2_000, let last = page.last?.assetID else { return rows }
            cursor = last
        }
    }

    func changes() async -> AsyncStream<LibraryChange> { await libraryChanges() }
}

extension APIClient {
    /// A direct authorized exact-ID read. It deliberately does not use the offline fallback:
    /// a stale receipt must not turn a removed or inaccessible remote asset into a match.
    func deviceServerCopy(id: String) async throws -> DeviceServerCopy? {
        let record: DeviceServerCopyRecord = try await request(.get, path: "assets/\(id)")
        let asset = record.asset
        guard asset.id == id, asset.ownerId == userID, !asset.isTrashed, asset.visibility == .timeline,
              let checksum = record.checksum, !checksum.isEmpty else { return nil }
        return DeviceServerCopy(identity: LocalAssetMatch(assetID: id, checksum: checksum, cloudID: nil,
                                                          createdAt: nil, adjustmentTime: nil, latitude: nil, longitude: nil,
                                                          checksumAlgorithm: record.checksumAlgorithm, contentChecksum: record.contentChecksum, isExternal: record.isExternal), asset: asset)
    }
}

private struct DeviceServerCopyRecord: Decodable, Sendable {
    let asset: Asset
    let checksum: String?
    let checksumAlgorithm: String?
    let contentChecksum: String?
    let isExternal: Bool?
    private enum CodingKeys: String, CodingKey { case checksum, checksumAlgorithm, contentChecksum, isExternal, libraryId, deletedAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var decoded = try Asset(from: decoder)
        if try values.decodeIfPresent(Date.self, forKey: .deletedAt) != nil { decoded.isTrashed = true }
        asset = decoded
        checksum = try values.decodeIfPresent(String.self, forKey: .checksum)
        checksumAlgorithm = try values.decodeIfPresent(String.self, forKey: .checksumAlgorithm)
        contentChecksum = try values.decodeIfPresent(String.self, forKey: .contentChecksum)
        if let explicit = try values.decodeIfPresent(Bool.self, forKey: .isExternal) { isExternal = explicit }
        else if values.contains(.libraryId) { isExternal = !(try values.decodeNil(forKey: .libraryId)) }
        else { isExternal = nil }
    }
}

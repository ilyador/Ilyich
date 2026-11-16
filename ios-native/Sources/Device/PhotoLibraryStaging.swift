import Foundation
import IlyichShareInbox
@preconcurrency import Photos
import UniformTypeIdentifiers

/// A Photos album backup can choose.
struct DeviceAlbum: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let count: Int
    let isShared: Bool
}

/// A photo or video discovery found, with its modification date as Photos reports it.
struct DeviceCandidate: Hashable, Sendable {
    let id: String
    let modified: Date?
}

/// How far staging may go to get an original.
struct StagingPolicy: Hashable, Sendable {
    /// Download originals kept only in iCloud.
    var allowCloud = false
    var cellularPhotos = false
    var cellularVideos = false
}

/// The unmodified source of an edited asset, observed at this exact device revision.
/// This identifies an archive original; it never confirms the current edited representation.
struct SourceOriginalFingerprint: Hashable, Sendable, Codable {
    let revision: AssetRevision
    /// Base64-encoded SHA-1, in the same format as upload checksums.
    let checksum: String
    /// Allows PhotoKit to revalidate resource identity without streaming the original again.
    let resourceSnapshot: [StagingResource]?

    init(revision: AssetRevision, checksum: String, resourceSnapshot: [StagingResource]? = nil) {
        self.revision = revision; self.checksum = checksum; self.resourceSnapshot = resourceSnapshot
    }

    private enum CodingKeys: String, CodingKey { case revisionBits, checksum, resourceSnapshot }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Preserve the exact revision fence, including Date's floating-point representation.
        let bits = try values.decode(UInt64.self, forKey: .revisionBits)
        revision = AssetRevision(referenceSeconds: Double(bitPattern: bits))
        checksum = try values.decode(String.self, forKey: .checksum)
        resourceSnapshot = try values.decodeIfPresent([StagingResource].self, forKey: .resourceSnapshot)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(revision.referenceSeconds.bitPattern, forKey: .revisionBits)
        try values.encode(checksum, forKey: .checksum)
        try values.encodeIfPresent(resourceSnapshot, forKey: .resourceSnapshot)
    }
}

/// Persistable reasons for ending or postponing a source-only lookup. None are backup proof.
enum SourceOriginalReason: String, Hashable, Sendable, Codable {
    case unedited, unsupportedResources, revisionSuperseded, revisionUnavailable
    case photosAccess, assetUnavailable, missingOriginal, incompleteResources
    case snapshotChanged, libraryChanged, cloudRequired, waitingForWiFi, networkUnavailable
    case sourceUnavailable, cachedSnapshotMissing, archiveNotFound

    /// Only errors from optional resource reads belong here. Account, server, lease and
    /// cancellation errors retain their normal throwing behavior.
    static func deferredSourceRead(_ error: any Error) -> Self? {
        if error is CancellationError || Task.isCancelled { return nil }
        if case BackupDeferral.waitingForWiFi = error { return .waitingForWiFi }
        if case PhotoResourceExport.Deferral.waitingForWiFi = error { return .waitingForWiFi }
        let details = error as NSError
        switch details.domain {
        case PHPhotosErrorDomain:
            switch PHPhotosError.Code(rawValue: details.code) {
            case .accessUserDenied, .accessRestricted: return .photosAccess
            case .identifierNotFound: return .assetUnavailable
            case .invalidResource, .missingResource: return .missingOriginal
            case .networkAccessRequired: return .cloudRequired
            case .networkError: return .networkUnavailable
            case .requestNotSupportedForAsset: return .sourceUnavailable
            default: return nil
            }
        case NSCocoaErrorDomain:
            switch CocoaError.Code(rawValue: details.code) {
            case .fileNoSuchFile, .fileReadNoSuchFile: return .missingOriginal
            case .fileReadCorruptFile: return .sourceUnavailable
            default: return nil
            }
        case NSURLErrorDomain:
            switch URLError.Code(rawValue: details.code) {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
                 .notConnectedToInternet, .resourceUnavailable, .dataNotAllowed: return .networkUnavailable
            case .fileDoesNotExist: return .missingOriginal
            default: return nil
            }
        default: return nil
        }
    }
}

enum SourceOriginalReadResult: Hashable, Sendable {
    case fingerprint(SourceOriginalFingerprint)
    case notApplicable(SourceOriginalReason)
    case deferred(SourceOriginalReason)
}

enum SourceOriginalValidation: Hashable, Sendable {
    case current
    case stale(SourceOriginalReason)
    case deferred(SourceOriginalReason)
}

/// What backup asks of the Photos library (architecture section 2). PhotoKitAdapter implements it,
/// on its own queue.
protocol PhotoLibraryStaging: Sendable {
    var authorization: PHAuthorizationStatus { get }
    /// Albums holding at least one item, by title.
    func albums() async -> [DeviceAlbum]
    /// All readable photos and videos, or those in `included`, minus `excluded`, in identifier order in batches.
    func candidates(scope: PhotoSelectionScope, included: Set<String>, excluded: Set<String>) -> AsyncThrowingStream<[DeviceCandidate], any Error>
    /// Copies the asset's current files into `directory` for upload.
    func stage(_ localID: String, into directory: URL, stageID: String, policy: StagingPolicy,
               progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedPhoto
    /// The photos and videos in one album and in none of `excluded`, in identifier order.
    func albumMembers(_ albumID: String, excluded: Set<String>, scope: PhotoSelectionScope) async -> [String]
    /// Those of `localIDs` that Photos still has. With limited access, only those selected.
    func existing(_ localIDs: [String]) async throws -> Set<String>
    /// Hashes a uniquely identified unmodified source, without staging it for upload.
    /// Nil means no safe source identity is available for this revision.
    func sourceOriginal(_ localID: String, revision: AssetRevision, policy: StagingPolicy) async throws -> SourceOriginalFingerprint?
    /// Revalidates source evidence after other asynchronous work, without downloading it again
    /// when the adapter can establish that its source snapshot is still current.
    func sourceOriginalIsCurrent(_ localID: String, fingerprint: SourceOriginalFingerprint, policy: StagingPolicy) async throws -> Bool
    /// Distinguishes an inapplicable source from a temporarily unavailable one, so completed
    /// uploads can leave durable source-matching work for later.
    func probeSourceOriginal(_ localID: String, revision: AssetRevision, policy: StagingPolicy) async throws -> SourceOriginalReadResult
    func validateSourceOriginal(_ localID: String, fingerprint: SourceOriginalFingerprint, policy: StagingPolicy) async throws -> SourceOriginalValidation
}

extension PhotoLibraryStaging {
    /// Older adapters and test doubles provide no source-original evidence.
    func sourceOriginal(_ localID: String, revision: AssetRevision, policy: StagingPolicy) async throws -> SourceOriginalFingerprint? { nil }
    func sourceOriginalIsCurrent(_ localID: String, fingerprint: SourceOriginalFingerprint, policy: StagingPolicy) async throws -> Bool {
        try await sourceOriginal(localID, revision: fingerprint.revision, policy: policy) == fingerprint
    }
    func probeSourceOriginal(_ localID: String, revision: AssetRevision, policy: StagingPolicy) async throws -> SourceOriginalReadResult {
        try Task.checkCancellation()
        do {
            let result = try await sourceOriginal(localID, revision: revision, policy: policy)
            try Task.checkCancellation()
            guard let fingerprint = result else {
                // Legacy nil does not explain whether the source is absent or temporarily unreadable.
                return .deferred(.sourceUnavailable)
            }
            guard fingerprint.revision == revision, !fingerprint.checksum.isEmpty else { return .deferred(.sourceUnavailable) }
            return .fingerprint(fingerprint)
        } catch {
            if let reason = SourceOriginalReason.deferredSourceRead(error) { return .deferred(reason) }
            throw error
        }
    }
    func validateSourceOriginal(_ localID: String, fingerprint: SourceOriginalFingerprint, policy: StagingPolicy) async throws -> SourceOriginalValidation {
        try Task.checkCancellation()
        do {
            let current = try await sourceOriginalIsCurrent(localID, fingerprint: fingerprint, policy: policy)
            try Task.checkCancellation()
            return current ? .current : .deferred(.sourceUnavailable)
        } catch {
            if let reason = SourceOriginalReason.deferredSourceRead(error) { return .deferred(reason) }
            throw error
        }
    }
}

/// The synchronous reads discovery makes, which tests fake. Safe on any thread; the adapter runs
/// them off its own queue (PhotoKitAdapter.offQueue).
protocol PhotoStagingReading: Sendable {
    /// Every album and smart album with at least one asset, unsorted.
    func albums() -> [DeviceAlbum]
    /// Every readable image and video, including assets in no album.
    func allAssetIDs() -> Set<String>
    /// The photos and videos in any of the albums.
    func members(of albumIDs: Set<String>, scope: PhotoSelectionScope) -> Set<String>
    /// The assets among `ids` that Photos still has, in no particular order.
    func candidates(_ ids: [String]) -> [DeviceCandidate]
}

extension PhotoKitAdapter: PhotoLibraryStaging {
    static let batchSize = 250

    // MARK: - Discovery

    /// Read once and kept until Photos reports a change. Only kept while the change observer runs,
    /// as nothing else would say it went stale.
    func albums() async -> [DeviceAlbum] {
        guard Self.canRead(authorization) else { return [] }
        let generation = albumGeneration.withLock { $0 }
        if let albumCache, albumCache.generation == generation { return albumCache.albums }
        let reader = stagingReader
        let albums = await Task.detached(priority: .utility) {
            reader.albums().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }.value
        // A change during the read leaves nothing cached; a later call reads again.
        if !isObserving { albumCache = nil }
        else if generation == albumGeneration.withLock({ $0 }) { albumCache = (generation, albums) }
        return albums
    }

    /// Runs a long PhotoKit read, such as enumerating every member of an album, at utility and off
    /// the adapter's queue, so a favorite, a delete or staging never waits behind it.
    private nonisolated static func offQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility, operation: body).value
    }

    nonisolated func candidates(scope: PhotoSelectionScope, included: Set<String>, excluded: Set<String>) -> AsyncThrowingStream<[DeviceCandidate], any Error> {
        candidates(scope: scope, included: included, excluded: excluded, batchSize: Self.batchSize)
    }

    /// Each batch is read on its own, off the adapter's queue and the caller's thread, so a change
    /// to Photos never waits behind discovery and dropping the stream stops it between batches.
    nonisolated func candidates(scope: PhotoSelectionScope, included: Set<String>, excluded: Set<String>, batchSize: Int) -> AsyncThrowingStream<[DeviceCandidate], any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [DeviceCandidate].self)
        let producer = Task {
            do {
                let ids = try await self.candidateIDs(scope: scope, included: included, excluded: excluded)
                for start in stride(from: 0, to: ids.count, by: batchSize) {
                    try Task.checkCancellation()
                    continuation.yield(try await self.readCandidates(Array(ids[start..<min(start + batchSize, ids.count)])))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }

    nonisolated func existing(_ localIDs: [String]) async throws -> Set<String> {
        var found = Set<String>()
        for start in stride(from: 0, to: localIDs.count, by: Self.batchSize) {
            found.formUnion(try await readCandidates(Array(localIDs[start..<min(start + Self.batchSize, localIDs.count)])).map(\.id))
        }
        return found
    }

    nonisolated func albumMembers(_ albumID: String, excluded: Set<String>, scope: PhotoSelectionScope = .selectedAlbums) async -> [String] {
        let reader = stagingReader
        // Scope controls PhotoKit's hidden/burst filtering here, never the album's identity.
        // Syncing a real album must not expand its members to the whole backup selection.
        return (try? await Self.offQueue {
            reader.members(of: [albumID], scope: scope).subtracting(reader.members(of: excluded, scope: scope)).sorted()
        }) ?? []
    }

    private nonisolated func candidateIDs(scope: PhotoSelectionScope, included: Set<String>, excluded: Set<String>) async throws -> [String] {
        try await selectedIDs(scope: scope, included: included, excluded: excluded).sorted()
    }

    private nonisolated func readCandidates(_ ids: [String]) async throws -> [DeviceCandidate] {
        let reader = stagingReader
        return try await Self.offQueue { reader.candidates(ids) }
    }

    /// The modification date Photos reports for the asset, nil when it has none or is gone.
    func revision(of localID: String) -> Date? {
        stagingReader.candidates([localID]).first.flatMap(\.modified)
    }

    /// The selected photos and videos, minus excluded album members, for the merged library:
    /// identifiers only, read off the adapter's queue.
    nonisolated func timelineMembers(scope: PhotoSelectionScope, included: Set<String>, excluded: Set<String>) async throws -> Set<String> {
        try await selectedIDs(scope: scope, included: included, excluded: excluded)
    }

    /// Backup and the merged timeline share selection and exclusion semantics.
    private nonisolated func selectedIDs(scope: PhotoSelectionScope, included: Set<String>, excluded: Set<String>) async throws -> Set<String> {
        let reader = stagingReader
        return try await Self.offQueue {
            let includedIDs = scope == .entireLibrary ? reader.allAssetIDs() : reader.members(of: included, scope: scope)
            return includedIDs.subtracting(reader.members(of: excluded, scope: scope))
        }
    }

    /// Phone photos for the merged library, read a batch at a time: each one, its cloud
    /// identifier, and how it is made. The assets Photos no longer has are left out.
    nonisolated func timelineItems(_ ids: [String]) async throws -> [DeviceTimelineItem] {
        var result: [DeviceTimelineItem] = []
        for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
            let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
            result += try await Self.offQueue { Self.timelineBatch(batch) }
        }
        return result
    }

    private nonisolated static func timelineBatch(_ batch: [String]) -> [DeviceTimelineItem] {
        let clouds = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: batch)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: batch, options: SystemPhotoKit.readableMediaOptions())
        return (0..<assets.count).map { index in
            let asset = assets.object(at: index)
            let types = PHAssetResource.assetResources(for: asset).map(\.type)
            return DeviceTimelineItem(photo: LocalPhoto(asset), cloudID: (try? clouds[asset.localIdentifier]?.get())?.stringValue,
                                      unadjusted: StagingRules.isUnadjusted(types),
                                      shape: ResourceShape.classify(types, isVideo: asset.mediaType == .video),
                                      canDelete: asset.canPerform(.delete), canEditProperties: asset.canPerform(.properties))
        }
    }

    // MARK: - Staging

    /// Compatibility for callers that cannot yet distinguish postponed source reads.
    func sourceOriginal(_ localID: String, revision: AssetRevision, policy: StagingPolicy) async throws -> SourceOriginalFingerprint? {
        if case .fingerprint(let fingerprint) = try await probeSourceOriginal(localID, revision: revision, policy: policy) { return fingerprint }
        return nil
    }

    /// Only an explicit original alongside a rendered edit can identify an archived source.
    /// The stream is hashed in bounded memory and no original file enters the upload directory.
    func probeSourceOriginal(_ localID: String, revision: AssetRevision, policy: StagingPolicy) async throws -> SourceOriginalReadResult {
        try Task.checkCancellation()
        let access = refreshAccess()
        let generation = albumGeneration.withLock { $0 }
        guard Self.canRead(access.status) else { return .deferred(.photosAccess) }
        guard let asset = Self.asset(localID) else { return .deferred(.assetUnavailable) }
        guard let modified = asset.modificationDate else { return .deferred(.revisionUnavailable) }
        guard AssetRevision(modified) == revision else { return .notApplicable(.revisionSuperseded) }
        let resources = PHAssetResource.assetResources(for: asset)
        let snapshot = resources.map(Self.describe)
        let isVideo = asset.mediaType == .video
        let selection = StagingRules.sourceOriginalSelection(snapshot, isVideo: isVideo)
        guard refreshAccess() == access, Self.canRead(authorization) else { return .deferred(.photosAccess) }
        guard albumGeneration.withLock({ $0 }) == generation else { return .deferred(.libraryChanged) }
        let index: Int
        switch selection {
        case .resource(let chosen): index = chosen
        case .notApplicable(let reason): return .notApplicable(reason)
        case .deferred(let reason): return .deferred(reason)
        }
        let checksum: String
        do {
            checksum = try await PhotoResourceExport.checksum(resources[index], allowCloud: policy.allowCloud,
                                                              allowCellular: isVideo ? policy.cellularVideos : policy.cellularPhotos)
        } catch {
            if let reason = SourceOriginalReason.deferredSourceRead(error) { return .deferred(reason) }
            throw error
        }
        try Task.checkCancellation()
        // Refetch instead of trusting PHAsset's immutable snapshot. Access changes, edits,
        // deletion, limited-library changes or a changed resource set invalidate this evidence.
        guard refreshAccess() == access, Self.canRead(authorization) else { return .deferred(.photosAccess) }
        guard let current = Self.asset(localID) else { return .deferred(.assetUnavailable) }
        guard let currentModified = current.modificationDate else { return .deferred(.revisionUnavailable) }
        guard AssetRevision(currentModified) == revision else { return .notApplicable(.revisionSuperseded) }
        guard current.mediaType == asset.mediaType,
              PHAssetResource.assetResources(for: current).map(Self.describe) == snapshot else { return .deferred(.snapshotChanged) }
        guard albumGeneration.withLock({ $0 }) == generation else { return .deferred(.libraryChanged) }
        return .fingerprint(SourceOriginalFingerprint(revision: revision, checksum: checksum, resourceSnapshot: snapshot))
    }

    /// PHAsset revisions fence content changes, and the resource signature also fences a
    /// changed source selection. The caller separately fences its account and access epoch.
    func sourceOriginalIsCurrent(_ localID: String, fingerprint: SourceOriginalFingerprint, policy: StagingPolicy) async throws -> Bool {
        try await validateSourceOriginal(localID, fingerprint: fingerprint, policy: policy) == .current
    }

    func validateSourceOriginal(_ localID: String, fingerprint: SourceOriginalFingerprint, policy: StagingPolicy) async throws -> SourceOriginalValidation {
        try Task.checkCancellation()
        let access = refreshAccess()
        let generation = albumGeneration.withLock { $0 }
        guard Self.canRead(access.status) else { return .deferred(.photosAccess) }
        guard let asset = Self.asset(localID) else { return .deferred(.assetUnavailable) }
        let current = PHAssetResource.assetResources(for: asset).map(Self.describe)
        let validation = StagingRules.validateSourceOriginal(fingerprint, revision: asset.modificationDate.map(AssetRevision.init),
                                                             resources: current, isVideo: asset.mediaType == .video)
        try Task.checkCancellation()
        guard refreshAccess() == access, Self.canRead(authorization) else { return .deferred(.photosAccess) }
        guard albumGeneration.withLock({ $0 }) == generation else { return .deferred(.libraryChanged) }
        return validation
    }

    func stage(_ localID: String, into directory: URL, stageID: String = UUID().uuidString, policy: StagingPolicy,
               progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedPhoto {
        guard Self.canRead(authorization) else {
            throw BackupError.message("Photos access was removed. Allow access in Settings before resuming backup.")
        }
        guard let asset = Self.asset(localID) else {
            throw BackupError.item("This photo is no longer available to Ilyich. Check Photos access and retry.")
        }
        let isVideo = asset.mediaType == .video
        let resources = PHAssetResource.assetResources(for: asset)
        let described = resources.map(Self.describe)
        let originalCellular = isVideo ? policy.cellularVideos : policy.cellularPhotos
        let original = try await currentResource(asset, resources: resources, allowCloud: policy.allowCloud,
                                                 allowCellular: originalCellular, progress: progress)
        let motion = StagingRules.motion(described).map { resources[$0] }
        try StagingRules.requireMotion(isLive: asset.mediaSubtypes.contains(.photoLive), motion: StagingRules.motion(described))
        let sidecar = StagingRules.sidecar(described).map { resources[$0] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalExport = try await Self.export(original, directory: directory, name: "original", allowCloud: policy.allowCloud,
                                                   allowCellular: originalCellular, computeChecksum: true,
                                                   noProgressTimeout: .seconds(180), progress: progress)
        var video: UploadFile?
        var videoChecksum: String?
        if let motion {
            let motionExport = try await Self.export(motion, directory: directory, name: "motion", allowCloud: policy.allowCloud,
                                                     allowCellular: policy.cellularVideos, computeChecksum: true,
                                                     noProgressTimeout: .seconds(180), progress: progress)
            video = motionExport.file
            videoChecksum = motionExport.checksum
        }
        var xmp: UploadFile?
        if let sidecar {
            xmp = try await Self.export(sidecar, directory: directory, name: "sidecar", allowCloud: policy.allowCloud,
                                        allowCellular: policy.cellularPhotos, computeChecksum: false,
                                        noProgressTimeout: .seconds(180), progress: progress).file
        }
        let created = asset.creationDate ?? Date()
        let modified = asset.modificationDate ?? created
        var fields = StagingRules.fields(created: created, modified: modified, isFavorite: asset.isFavorite, duration: asset.duration)
        if StagingRules.isUnadjusted(described.map(\.type)) {
            let cloudID = try await Self.offQueue {
                (try? PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [localID])[localID]?.get())?.stringValue
            }
            fields["metadata"] = try StagingRules.mobileAppMetadata(cloudID: cloudID, created: created, location: asset.location?.coordinate)
        }
        return PreparedPhoto(localID: localID, modificationDate: modified, original: originalExport.file, motion: video, sidecar: xmp,
                             fields: fields, isVideo: isVideo, originalChecksum: originalExport.checksum,
                             motionChecksum: videoChecksum, stageID: stageID)
    }

    /// The SHA-1 of the asset's current full-size file, streamed, never downloaded from iCloud.
    func fingerprint(of localID: String) async throws -> String {
        guard let asset = Self.asset(localID) else { throw CocoaError(.fileNoSuchFile) }
        let resource = try await currentResource(asset, resources: PHAssetResource.assetResources(for: asset),
                                                 allowCloud: false, allowCellular: false) { _ in }
        try Task.checkCancellation()
        return try await PhotoResourceExport.checksum(resource)
    }

    /// Copies the asset's current full-size file into `folder` under its original name, for sharing.
    func exportCurrent(of localID: String, into folder: URL, allowCloud: Bool,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let asset = Self.asset(localID) else {
            throw BackupError.item("This photo is no longer available to Ilyich. Check Photos access and retry.")
        }
        let resource = try await currentResource(asset, resources: PHAssetResource.assetResources(for: asset),
                                                 allowCloud: allowCloud, allowCellular: true, progress: progress)
        let name = (resource.originalFilename as NSString).lastPathComponent
        let file = folder.appendingPathComponent(name.isEmpty ? "Photo.\(resource.contentType.preferredFilenameExtension ?? "dat")" : name)
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = allowCloud; options.progressHandler = progress
        try await PhotoResourceExport(destination: file).write(resource, options: options)
        return file
    }

    private func currentResource(_ asset: PHAsset, resources: [PHAssetResource], allowCloud: Bool, allowCellular: Bool,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> PHAssetResource {
        let described = resources.map(Self.describe)
        switch StagingRules.currentResource(described, isVideo: asset.mediaType == .video) {
        case .resource(let index): return resources[index]
        case .byEditingInput(let candidates):
            let type = try await PhotoCurrentRepresentation(asset: asset).contentType(allowCloud: allowCloud, allowCellular: allowCellular, progress: progress)
            if let index = StagingRules.resolve(candidates, in: described, editingType: type) { return resources[index] }
        case .unidentified: break
        }
        throw BackupError.item(StagingRules.unidentified)
    }

    private static func export(_ resource: PHAssetResource, directory: URL, name: String, allowCloud: Bool, allowCellular: Bool,
                               computeChecksum: Bool, noProgressTimeout: Duration?,
                               progress: @escaping @Sendable (Double) -> Void,
                               isolation: isolated (any Actor)? = #isolation) async throws -> (file: UploadFile, checksum: String?) {
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        options.progressHandler = progress
        let localExport = PhotoResourceExport(destination: destination, computeChecksum: computeChecksum, noProgressTimeout: noProgressTimeout)
        var completedExport = localExport
        do { try await localExport.write(resource, options: options) }
        catch {
            let details = error as NSError
            guard allowCloud, details.domain == PHPhotosErrorDomain,
                  details.code == PHPhotosError.networkAccessRequired.rawValue else { throw error }
            try Task.checkCancellation()
            options.isNetworkAccessAllowed = true
            let cloudExport = PhotoResourceExport(destination: destination, computeChecksum: computeChecksum, noProgressTimeout: noProgressTimeout)
            do { try await cloudExport.write(resource, options: options, allowCellular: allowCellular) }
            catch PhotoResourceExport.Deferral.waitingForWiFi { throw BackupDeferral.waitingForWiFi }
            completedExport = cloudExport
        }
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        return (UploadFile(url: destination, filename: resource.originalFilename,
                           contentType: resource.contentType.preferredMIMEType ?? "application/octet-stream"), completedExport.checksum)
    }

    private static func asset(_ localID: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: SystemPhotoKit.readableMediaOptions()).firstObject
    }

    private static func describe(_ resource: PHAssetResource) -> StagingResource {
        StagingResource(type: resource.type, contentType: resource.contentType.identifier, filename: resource.originalFilename)
    }
}

/// A phone photo for the merged timeline.
struct DeviceTimelineItem: Hashable, Sendable {
    let photo: LocalPhoto
    let cloudID: String?
    /// Photos holds no edit of it, so its cloud identity can match an upload.
    let unadjusted: Bool
    var shape: ResourceShape = .other
    var canDelete = false
    var canEditProperties = false

    /// As the device index publishes it.
    var asset: DeviceAsset {
        DeviceAsset(id: DeviceAssetID(rawValue: photo.id), revision: photo.modified.map(AssetRevision.init), created: photo.date,
                    isVideo: photo.video, isLive: photo.live, isFavorite: photo.isFavorite,
                    location: photo.latitude.flatMap { latitude in photo.longitude.map { DeviceAsset.Coordinate(latitude: latitude, longitude: $0) } },
                    shape: shape, canDelete: canDelete, canEditProperties: canEditProperties)
    }
}

extension SystemPhotoKit: PhotoStagingReading {
    func albums() -> [DeviceAlbum] {
        var values: [DeviceAlbum] = []
        for type in [PHAssetCollectionType.smartAlbum, .album] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                if assets.count > 0 {
                    values.append(DeviceAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Album",
                                              count: assets.count, isShared: collection.assetCollectionSubtype == .albumCloudShared))
                }
            }
        }
        return values
    }

    /// Asset enumeration is independent of album membership and respects Photos authorization,
    /// including the user's limited-library selection. Only identifiers are held here.
    func allAssetIDs() -> Set<String> {
        var result = Set<String>()
        PHAsset.fetchAssets(with: Self.readableMediaOptions()).enumerateObjects { asset, _, _ in
            result.insert(asset.localIdentifier)
        }
        return result
    }

    static func readableMediaOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        return options
    }

    /// Cleanup and other album reads retain the established PhotoKit filtering.
    func members(of albumIDs: Set<String>) -> Set<String> { members(of: albumIDs, scope: .selectedAlbums) }

    func members(of albumIDs: Set<String>, scope: PhotoSelectionScope) -> Set<String> {
        guard !albumIDs.isEmpty else { return [] }
        var result = Set<String>()
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(albumIDs), options: nil).enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: scope == .entireLibrary ? Self.readableMediaOptions() : nil).enumerateObjects { asset, _, _ in
                if asset.mediaType == .image || asset.mediaType == .video { result.insert(asset.localIdentifier) }
            }
        }
        return result
    }

    func candidates(_ ids: [String]) -> [DeviceCandidate] {
        guard !ids.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: Self.readableMediaOptions())
        return (0..<assets.count).map { DeviceCandidate(id: assets.object(at: $0).localIdentifier, modified: assets.object(at: $0).modificationDate) }
    }
}

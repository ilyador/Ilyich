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

/// What backup asks of the Photos library (architecture section 2). PhotoKitAdapter implements it,
/// on its own queue.
protocol PhotoLibraryStaging: Sendable {
    var authorization: PHAuthorizationStatus { get }
    /// Albums holding at least one item, by title.
    func albums() async -> [DeviceAlbum]
    /// The photos and videos in `included` but not in `excluded`, in identifier order, a batch at a time.
    func candidates(included: Set<String>, excluded: Set<String>) -> AsyncThrowingStream<[DeviceCandidate], any Error>
    /// Copies the asset's current files into `directory` for upload.
    func stage(_ localID: String, into directory: URL, stageID: String, policy: StagingPolicy,
               progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedPhoto
    /// The photos and videos in one album and in none of `excluded`, in identifier order.
    func albumMembers(_ albumID: String, excluded: Set<String>) async -> [String]
}

/// The synchronous reads discovery makes, which tests fake. Safe on any thread; the adapter runs
/// them off its own queue (PhotoKitAdapter.offQueue).
protocol PhotoStagingReading: Sendable {
    /// Every album and smart album with at least one asset, unsorted.
    func albums() -> [DeviceAlbum]
    /// The photos and videos in any of the albums.
    func members(of albumIDs: Set<String>) -> Set<String>
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

    nonisolated func candidates(included: Set<String>, excluded: Set<String>) -> AsyncThrowingStream<[DeviceCandidate], any Error> {
        candidates(included: included, excluded: excluded, batchSize: Self.batchSize)
    }

    /// Each batch is read on its own, off the adapter's queue and the caller's thread, so a change
    /// to Photos never waits behind discovery and dropping the stream stops it between batches.
    nonisolated func candidates(included: Set<String>, excluded: Set<String>, batchSize: Int) -> AsyncThrowingStream<[DeviceCandidate], any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [DeviceCandidate].self)
        let producer = Task {
            do {
                let ids = try await self.candidateIDs(included: included, excluded: excluded)
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

    nonisolated func albumMembers(_ albumID: String, excluded: Set<String>) async -> [String] {
        (try? await candidateIDs(included: [albumID], excluded: excluded)) ?? []
    }

    private nonisolated func candidateIDs(included: Set<String>, excluded: Set<String>) async throws -> [String] {
        let reader = stagingReader
        return try await Self.offQueue { reader.members(of: included).subtracting(reader.members(of: excluded)).sorted() }
    }

    private nonisolated func readCandidates(_ ids: [String]) async throws -> [DeviceCandidate] {
        let reader = stagingReader
        return try await Self.offQueue { reader.candidates(ids) }
    }

    /// The modification date Photos reports for the asset, nil when it has none or is gone.
    func revision(of localID: String) -> Date? { revisionNow(of: localID) }

    /// The same, read on the calling thread: one fetch by identifier, for the viewer's synchronous
    /// offline-fallback check until P3 gives it the adapter's revisions.
    nonisolated func revisionNow(of localID: String) -> Date? {
        stagingReader.candidates([localID]).first.flatMap(\.modified)
    }

    /// How the asset is made, if it is still at `revision`. Nil when it is gone or changed.
    func removalShape(of localID: String, revision: Date) -> ResourceShape? {
        guard let asset = Self.asset(localID), asset.modificationDate == revision else { return nil }
        return ResourceShape.classify(PHAssetResource.assetResources(for: asset).map(\.type), isVideo: asset.mediaType == .video)
    }

    /// Phone photos for the merged timeline: each one, its cloud identifier, and whether Photos
    /// holds no edit of it.
    nonisolated func timelineItems(included: Set<String>, excluded: Set<String>) async throws -> [DeviceTimelineItem] {
        let ids = try await candidateIDs(included: included, excluded: excluded)
        var result: [DeviceTimelineItem] = []
        for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
            let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
            result += try await Self.offQueue { Self.timelineBatch(batch) }
        }
        return result
    }

    private nonisolated static func timelineBatch(_ batch: [String]) -> [DeviceTimelineItem] {
        let clouds = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: batch)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil)
        return (0..<assets.count).map { index in
            let asset = assets.object(at: index)
            let types = PHAssetResource.assetResources(for: asset).map(\.type)
            return DeviceTimelineItem(photo: LocalPhoto(asset), cloudID: (try? clouds[asset.localIdentifier]?.get())?.stringValue,
                                      unadjusted: StagingRules.isUnadjusted(types))
        }
    }

    // MARK: - Staging

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
        let file = try await Self.export(original, directory: directory, name: "original", allowCloud: policy.allowCloud,
                                         allowCellular: originalCellular, progress: progress)
        var video: UploadFile?
        if let motion {
            video = try await Self.export(motion, directory: directory, name: "motion", allowCloud: policy.allowCloud,
                                          allowCellular: policy.cellularVideos, progress: progress)
        }
        var xmp: UploadFile?
        if let sidecar {
            xmp = try await Self.export(sidecar, directory: directory, name: "sidecar", allowCloud: policy.allowCloud,
                                        allowCellular: policy.cellularPhotos, progress: progress)
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
        return PreparedPhoto(localID: localID, modificationDate: modified, original: file, motion: video, sidecar: xmp,
                             fields: fields, isVideo: isVideo, stageID: stageID)
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
                               progress: @escaping @Sendable (Double) -> Void,
                               isolation: isolated (any Actor)? = #isolation) async throws -> UploadFile {
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        options.progressHandler = progress
        do { try await PhotoResourceExport(destination: destination).write(resource, options: options) }
        catch {
            let details = error as NSError
            guard allowCloud, details.domain == PHPhotosErrorDomain,
                  details.code == PHPhotosError.networkAccessRequired.rawValue else { throw error }
            try Task.checkCancellation()
            options.isNetworkAccessAllowed = true
            do { try await PhotoResourceExport(destination: destination).write(resource, options: options, allowCellular: allowCellular) }
            catch PhotoResourceExport.Deferral.waitingForWiFi { throw BackupDeferral.waitingForWiFi }
        }
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        return UploadFile(url: destination, filename: resource.originalFilename,
                          contentType: resource.contentType.preferredMIMEType ?? "application/octet-stream")
    }

    private static func asset(_ localID: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject
    }

    private static func describe(_ resource: PHAssetResource) -> StagingResource {
        StagingResource(type: resource.type, contentType: resource.contentType.identifier, filename: resource.originalFilename)
    }
}

/// A phone photo for the merged timeline.
struct DeviceTimelineItem: Sendable {
    let photo: LocalPhoto
    let cloudID: String?
    let unadjusted: Bool
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

    func members(of albumIDs: Set<String>) -> Set<String> {
        guard !albumIDs.isEmpty else { return [] }
        var result = Set<String>()
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(albumIDs), options: nil).enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                if asset.mediaType == .image || asset.mediaType == .video { result.insert(asset.localIdentifier) }
            }
        }
        return result
    }

    func candidates(_ ids: [String]) -> [DeviceCandidate] {
        guard !ids.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        return (0..<assets.count).map { DeviceCandidate(id: assets.object(at: $0).localIdentifier, modified: assets.object(at: $0).modificationDate) }
    }
}

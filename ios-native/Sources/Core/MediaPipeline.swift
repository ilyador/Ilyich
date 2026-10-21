import CryptoKit
import Foundation
import IlyichPlatform
import ImageIO
import Synchronization
import UIKit

/// CGImage is immutable; only the UIKit wrapper is created on the UI actor.
struct PreparedImage: @unchecked Sendable {
    let cgImage: CGImage
    @MainActor var uiImage: UIImage { UIImage(cgImage: cgImage) }
    var byteCost: Int { cgImage.bytesPerRow * cgImage.height }
}

private final class CachedImage: Sendable {
    let image: PreparedImage
    let revision: String
    init(_ image: PreparedImage, revision: String = "") { self.image = image; self.revision = revision }
}

/// The decoded caches, with an index from each photo to its entries, so a photo's images can be
/// forgotten by its ID. Every write and removal of a photo's entries happens under the index's
/// lock, after a check of the media fence, so a decode that finishes after its photo was
/// forgotten never reaches memory. NSCache is thread-safe and has no delegate here, so it never
/// calls back into the lock.
private final class MediaMemory: @unchecked Sendable {
    let decoded = NSCache<NSString, CachedImage>()
    /// The newest thumbnail and preview of each asset at whatever size it was decoded. The viewer
    /// opens on it while a sharper copy loads.
    let latest = NSCache<NSString, CachedImage>()
    let fence: MediaFence
    private struct Index {
        /// Asset ID to the keys of its decoded entries, with each entry's revision.
        var decoded: [String: [String: String]] = [:]
        var count = 0
    }
    private let index = Mutex(Index())

    init(fence: MediaFence) { self.fence = fence }

    /// The latest cache's key for an asset's thumbnails or previews.
    static func latestKey(scope: String, resource: String, size: String) -> String {
        "\(scope.utf8.count):\(scope)\(resource)|\(size)"
    }

    private static func assetID(_ key: MediaCacheIdentity) -> String? {
        key.resource.hasPrefix("assets/") ? String(key.resource.dropFirst(7)) : nil
    }

    /// Keeps a decoded image, and for the edited, unlocked thumbnail and preview tiers also as the
    /// asset's latest. Refused when its photo was forgotten after `token` was taken.
    func remember(_ image: PreparedImage, as key: MediaCacheIdentity, token: UInt64, latestToo: Bool = true) {
        let stableKey = key.stableKey
        guard let id = Self.assetID(key) else {
            decoded.setObject(CachedImage(image), forKey: stableKey as NSString, cost: image.byteCost)
            return
        }
        index.withLock { index in
            guard fence.admits(id, since: token) else { return }
            if index.decoded[id, default: [:]].updateValue(key.revision, forKey: stableKey) == nil { index.count += 1 }
            decoded.setObject(CachedImage(image), forKey: stableKey as NSString, cost: image.byteCost)
            if latestToo, key.size.hasSuffix(":edited=true:locked=false"),
               let size = key.size.split(separator: ":").first, size != MediaSize.fullsize.rawValue {
                latest.setObject(CachedImage(image, revision: key.revision),
                                 forKey: Self.latestKey(scope: key.scope, resource: key.resource, size: String(size)) as NSString, cost: image.byteCost)
            }
            // Entries NSCache evicted by itself leave their keys behind; past a bound they go.
            if index.count > 3 * max(decoded.countLimit, 1_000) { prune(&index) }
        }
    }

    private func prune(_ index: inout Index) {
        var count = 0
        for (id, keys) in index.decoded {
            let live = keys.filter { decoded.object(forKey: $0.key as NSString) != nil }
            index.decoded[id] = live.isEmpty ? nil : live
            count += live.count
        }
        index.count = count
    }

    /// Every image of these photos, at every revision and size, leaves memory.
    func forget(_ ids: Set<String>, scope: String) {
        index.withLock { index in
            for id in ids {
                if let keys = index.decoded.removeValue(forKey: id) {
                    index.count -= keys.count
                    for key in keys.keys { decoded.removeObject(forKey: key as NSString) }
                }
                for size in [MediaSize.thumbnail, .preview] {
                    latest.removeObject(forKey: Self.latestKey(scope: scope, resource: "assets/\(id)", size: size.rawValue) as NSString)
                }
            }
        }
    }

    /// The photo's previews were made again: images of any other revision leave memory.
    func refresh(_ id: String, revision: String, scope: String) {
        index.withLock { index in
            if let keys = index.decoded[id] {
                let stale = keys.filter { $0.value != revision }
                for key in stale.keys { decoded.removeObject(forKey: key as NSString) }
                index.count -= stale.count
                let kept = keys.filter { $0.value == revision }
                index.decoded[id] = kept.isEmpty ? nil : kept
            }
            for size in [MediaSize.thumbnail, .preview] {
                let key = Self.latestKey(scope: scope, resource: "assets/\(id)", size: size.rawValue) as NSString
                if let cached = latest.object(forKey: key), cached.revision != revision { latest.removeObject(forKey: key) }
            }
        }
    }

    func removeAll() {
        index.withLock { index in
            index = Index()
            decoded.removeAllObjects()
            latest.removeAllObjects()
        }
    }
}

actor MediaPipeline {
    private struct Flight {
        let task: Task<PreparedImage, Error>
        var waiters: Set<UUID>
        let generation: UUID
        let privateGeneration: UUID?
        /// The media fence's token when the download began.
        let token: UInt64
    }
    private let client: APIClient
    private let session: URLSession
    private let privateSession: URLSession
    private let byteCache: URLCache
    private let limiter = ImageWorkLimiter()
    /// Few at a time: the server keeps working on a request even after the app gives it up, so a
    /// flood of thumbnails while scrolling slows down the photo that is actually opened.
    private let thumbnailLimiter = ImageWorkLimiter(limit: 6)
    /// Thumbnail bytes live in their own store, so they skip the URL cache.
    private let thumbnailSession: URLSession
    private let thumbnails: ThumbnailStore
    private let decoder: ThumbnailDecoder
    private struct ThumbnailFlight {
        let task: Task<Data, Error>
        var waiters: Set<UUID>
        /// A download that has started finishes and is kept, even if every cell gave up on it.
        var started = false
    }
    private var thumbnailFlights: [String: ThumbnailFlight] = [:]
    /// NSCache is thread-safe, so views can read it synchronously and draw a cached image in
    /// their first frame instead of flashing empty while an actor hop completes.
    private nonisolated let memory: MediaMemory
    private nonisolated var decoded: NSCache<NSString, CachedImage> { memory.decoded }
    private nonisolated var latest: NSCache<NSString, CachedImage> { memory.latest }
    private nonisolated var fence: MediaFence { thumbnails.fence }
    /// Previews and full-size images this launch put in the URL cache, by asset, so a photo whose
    /// access was lost can be removed from it alone.
    private var cachedRequests: [String: Set<URLRequest>] = [:]
    /// Whether the URL cache may hold entries from an earlier launch, which can't be found by
    /// asset. Nil until measured, soon after launch and off the main thread.
    private var urlCacheHasUnindexedEntries: Bool?
    private var flights: [MediaCacheIdentity: Flight] = [:]
    /// Small faces for the shelves and lists keep their own cache, so scrolling the photo grid
    /// never pushes them out.
    private nonisolated(unsafe) let faces = NSCache<NSString, CachedImage>()
    /// A face keeps downloading after the row that asked for it scrolls away, so a fast scrub
    /// through people finds it on the way back instead of starting over.
    private var faceFlights: [MediaCacheIdentity: Task<PreparedImage, Error>] = [:]
    private let faceLimiter = ImageWorkLimiter(limit: 6)
    private var generation = UUID()
    private var privateGeneration = UUID()
    private var privateKeys = Set<MediaCacheIdentity>()

    /// `protocolClasses` serve the downloads, and `earlierURLCacheEntries` says whether the URL
    /// cache holds entries from an earlier launch, for tests; it is measured otherwise.
    init(client: APIClient, memoryLimit: Int = 160 * 1024 * 1024, diskLimit: Int = 300 * 1024 * 1024,
         protocolClasses: [AnyClass]? = nil, earlierURLCacheEntries: Bool? = nil) {
        self.client = client
        urlCacheHasUnindexedEntries = earlierURLCacheEntries
        let scope = SHA256.hash(data: Data(client.cacheScope.utf8)).map { String(format: "%02x", $0) }.joined()
        byteCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: diskLimit, diskPath: "IlyichMedia/\(scope)")
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = byteCache
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpMaximumConnectionsPerHost = 12
        configuration.timeoutIntervalForRequest = 45
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: SameOriginRedirectDelegate(origin: client.baseURL), delegateQueue: nil)
        let ephemeral = URLSessionConfiguration.ephemeral
        ephemeral.urlCache = nil; ephemeral.httpCookieStorage = nil
        ephemeral.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { ephemeral.protocolClasses = protocolClasses }
        privateSession = URLSession(configuration: ephemeral, delegate: SameOriginRedirectDelegate(origin: client.baseURL), delegateQueue: nil)
        let thumbnailConfiguration = URLSessionConfiguration.default
        thumbnailConfiguration.urlCache = nil; thumbnailConfiguration.httpCookieStorage = nil
        thumbnailConfiguration.httpShouldSetCookies = false
        thumbnailConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        thumbnailConfiguration.httpMaximumConnectionsPerHost = 6
        thumbnailConfiguration.timeoutIntervalForRequest = 30
        if let protocolClasses { thumbnailConfiguration.protocolClasses = protocolClasses }
        thumbnailSession = URLSession(configuration: thumbnailConfiguration, delegate: SameOriginRedirectDelegate(origin: client.baseURL), delegateQueue: nil)
        thumbnails = ThumbnailStore(scope: client.cacheScope)
        let memory = MediaMemory(fence: thumbnails.fence)
        self.memory = memory
        decoder = ThumbnailDecoder(store: thumbnails) { image, request in memory.remember(image, as: request.identity, token: request.token) }
        let decoded = memory.decoded, latest = memory.latest
        decoded.totalCostLimit = memoryLimit
        decoded.countLimit = 2_000
        latest.totalCostLimit = memoryLimit / 4
        latest.countLimit = 600
        faces.totalCostLimit = 24 * 1024 * 1024
        faces.countLimit = 1_500
        Task { await self.measureURLCache() }
    }

    /// Anything on disk this early was put there by an earlier launch. Measured later, it may be
    /// this launch's too, and the cache's own database counts as well, which only makes the first
    /// revocation of a launch clear the URL cache, as every revocation did before.
    private func measureURLCache() {
        if urlCacheHasUnindexedEntries == nil { urlCacheHasUnindexedEntries = byteCache.currentDiskUsage > 0 }
    }

    /// A decoded copy already in memory, or nil. Never waits and never loads.
    nonisolated func cachedImage(for asset: Asset, size: MediaSize = .thumbnail, pixelSize: Int, edited: Bool = true) -> PreparedImage? {
        guard asset.visibility != .locked else { return nil }
        let identity = MediaCacheIdentity(scope: client.cacheScope, asset: asset, size: size, pixelSize: pixelSize, edited: edited)
        return decoded.object(forKey: identity.stableKey as NSString)?.image
    }

    /// The newest thumbnail or preview of an asset at any size. Without a revision any version
    /// matches, for views that know only the asset's ID.
    nonisolated func latestImage(assetID: String, size: MediaSize, revision: String? = nil) -> PreparedImage? {
        guard let cached = latest.object(forKey: Self.latestKey(scope: client.cacheScope, resource: "assets/\(assetID)", size: size.rawValue) as NSString),
              revision == nil || cached.revision == revision else { return nil }
        return cached.image
    }

    nonisolated func cachedPersonImage(person: Person, pixelSize: Int) -> PreparedImage? {
        cachedFace(MediaCacheIdentity(scope: client.cacheScope, person: person, pixelSize: pixelSize))
    }

    private nonisolated func cachedFace(_ identity: MediaCacheIdentity) -> PreparedImage? {
        faceCache(identity).object(forKey: identity.stableKey as NSString)?.image
    }

    private nonisolated func faceCache(_ identity: MediaCacheIdentity) -> NSCache<NSString, CachedImage> {
        identity.pixelSize <= Self.smallFacePixels ? faces : decoded
    }

    /// Faces drawn at about 40 points or less.
    nonisolated static let smallFacePixels = 160

    private nonisolated static func latestKey(scope: String, resource: String, size: String) -> String {
        MediaMemory.latestKey(scope: scope, resource: resource, size: size)
    }

    func image(for asset: Asset, size: MediaSize = .thumbnail, pixelSize: Int, edited: Bool = true) async throws -> PreparedImage {
        try await image(for: asset, size: size, pixelSize: pixelSize, edited: edited, token: fence.token())
    }

    /// `token` is the media fence's, taken when the image was asked for: a photo forgotten since
    /// then is neither downloaded, stored nor remembered.
    func image(for asset: Asset, size: MediaSize = .thumbnail, pixelSize: Int, edited: Bool = true, token: UInt64) async throws -> PreparedImage {
        guard fence.admits(asset.id, since: token) else { throw CancellationError() }
        if size == .thumbnail, edited, asset.visibility != .locked {
            guard let image = try await thumbnail(asset, pixelSize: pixelSize, network: true, token: token) else { throw CancellationError() }
            return image
        }
        let privacyToken = privateGeneration
        let identity = MediaCacheIdentity(scope: client.cacheScope, asset: asset, size: size, pixelSize: pixelSize, edited: edited)
        let request = try await mediaRequest(asset, size: size, edited: edited)
        guard asset.visibility != .locked || privacyToken == privateGeneration else { throw CancellationError() }
        return try await load(identity, request: request, isPrivate: asset.visibility == .locked, token: token)
    }

    /// The media fence's token now, for work that will store or remember a photo's media later.
    nonisolated func mediaToken() -> UInt64 { fence.token() }

    private func mediaRequest(_ asset: Asset, size: MediaSize, edited: Bool) async throws -> URLRequest {
        try await client.authorizedRequest(path: "assets/\(asset.id)/thumbnail", query: [
            .init(name: "size", value: size.rawValue), .init(name: "edited", value: String(edited)),
            .init(name: "c", value: asset.cacheRevision)
        ])
    }

    /// A grid thumbnail from memory or disk, or nil if only the network has it. Fast scrolling
    /// and scrubbing use this, so the server is asked only for what the user stops to look at.
    nonisolated func storedThumbnail(for asset: Asset, pixelSize: Int) async -> PreparedImage? {
        guard asset.visibility != .locked else { return nil }
        let request = thumbnailRequest(asset, pixelSize: pixelSize)
        if let image = decoded.object(forKey: request.identity.stableKey as NSString) { return image.image }
        return await decoder.image(request)
    }

    /// Photos about to scroll in move from disk to memory, behind the ones on screen.
    nonisolated func prefetchThumbnails(_ assets: [Asset], pixelSize: Int) {
        decoder.prefetch(assets.compactMap { asset in
            guard asset.visibility != .locked else { return nil }
            let request = thumbnailRequest(asset, pixelSize: pixelSize)
            return decoded.object(forKey: request.identity.stableKey as NSString) == nil ? request : nil
        })
    }

    nonisolated func cancelThumbnailPrefetch(_ assets: [Asset], pixelSize: Int) {
        decoder.cancelPrefetch(assets.map { thumbnailRequest($0, pixelSize: pixelSize).identity })
    }

    private nonisolated func thumbnailRequest(_ asset: Asset, pixelSize: Int, token: UInt64? = nil) -> ThumbnailDecoder.Request {
        ThumbnailDecoder.Request(identity: MediaCacheIdentity(scope: client.cacheScope, asset: asset, size: .thumbnail, pixelSize: pixelSize),
                                 assetID: asset.id, revision: asset.cacheRevision, token: token ?? fence.token())
    }

    nonisolated func hasStoredThumbnail(_ asset: Asset) -> Bool {
        thumbnails.contains(assetID: asset.id, revision: asset.cacheRevision)
    }

    /// Downloads a thumbnail into the store without decoding it, for keeping the library offline.
    /// `token` is the media fence's from when `asset` was read, so a photo locked or deleted since
    /// is not downloaded or stored.
    func storeThumbnail(_ asset: Asset, token: UInt64) async throws {
        guard asset.visibility != .locked, !hasStoredThumbnail(asset) else { return }
        _ = try await thumbnailData(asset, token: token)
    }

    private func thumbnail(_ asset: Asset, pixelSize: Int, network: Bool, token: UInt64) async throws -> PreparedImage? {
        let request = thumbnailRequest(asset, pixelSize: pixelSize, token: token), identity = request.identity
        if let image = decoded.object(forKey: identity.stableKey as NSString) { return image.image }
        let epoch = generation
        // The decoder remembers what it decodes, and a reset drops it.
        if let stored = await decoder.image(request) { return stored }
        try Task.checkCancellation()
        guard network else { return nil }
        let data = try await thumbnailData(asset, token: token)
        let image = try await Task.detached(priority: .userInitiated) { try Self.downsample(data, pixelSize: pixelSize) }.value
        try Task.checkCancellation()
        guard epoch == generation, fence.admits(asset.id, since: token) else { throw CancellationError() }
        memory.remember(image, as: identity, token: token)
        return image
    }

    /// One download per photo revision, shared by every cell size that wants it. A download that
    /// has not started is dropped when nobody waits for it; one that has started completes into
    /// the store, because the server does the work either way. `token` is the fence's from when the
    /// caller began; a joined download keeps the token of whoever started it.
    private func thumbnailData(_ asset: Asset, token: UInt64) async throws -> Data {
        let key = asset.id + "|" + asset.cacheRevision
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard fence.admits(asset.id, since: token) else { throw CancellationError() }
            if thumbnailFlights[key] == nil {
                let request = try await client.authorizedRequest(path: "assets/\(asset.id)/thumbnail", query: [
                    .init(name: "size", value: MediaSize.thumbnail.rawValue), .init(name: "edited", value: "true"),
                    .init(name: "c", value: asset.cacheRevision)
                ])
                try Task.checkCancellation()
                // Another caller may have started the same download while the request was built.
                if thumbnailFlights[key] == nil {
                    guard fence.admits(asset.id, since: token) else { throw CancellationError() }
                    let limiter = thumbnailLimiter, session = thumbnailSession, store = thumbnails, revision = asset.cacheRevision
                    let task = Task.detached(priority: .userInitiated) { [weak self] () -> Data in
                        try await limiter.acquire()
                        guard let self, await self.beginThumbnail(key), !Task.isCancelled else {
                            await limiter.release(); throw CancellationError()
                        }
                        do {
                            let (data, response) = try await session.data(for: request)
                            try ServerFailure.check(response, body: data)
                            await limiter.release()
                            // Waiters get the bytes now. The flight stays joinable until the file
                            // is written, so nobody downloads it twice meanwhile.
                            Task.detached(priority: .utility) { [weak self] in
                                await store.store(data, assetID: asset.id, revision: revision, token: token)
                                await self?.endThumbnail(key)
                            }
                            return data
                        } catch {
                            await limiter.release(); await self.endThumbnail(key)
                            throw error
                        }
                    }
                    thumbnailFlights[key] = ThumbnailFlight(task: task, waiters: [])
                }
            }
            guard var flight = thumbnailFlights[key] else { throw CancellationError() }
            flight.waiters.insert(waiter); thumbnailFlights[key] = flight
            defer { releaseThumbnail(key, waiter: waiter) }
            return try await flight.task.value
        } onCancel: {
            Task { await self.releaseThumbnail(key, waiter: waiter) }
        }
    }

    private func beginThumbnail(_ key: String) -> Bool {
        guard var flight = thumbnailFlights[key] else { return false }
        flight.started = true; thumbnailFlights[key] = flight
        return true
    }

    /// Waiters hold the task itself, so a finished download leaves the table at once.
    private func endThumbnail(_ key: String) { thumbnailFlights.removeValue(forKey: key) }

    private func releaseThumbnail(_ key: String, waiter: UUID) {
        guard var flight = thumbnailFlights[key], flight.waiters.remove(waiter) != nil else { return }
        if flight.waiters.isEmpty && !flight.started {
            flight.task.cancel(); thumbnailFlights.removeValue(forKey: key)
        } else {
            thumbnailFlights[key] = flight
        }
    }


    func animation(for asset: Asset, pixelSize: Int) async throws -> AnimatedImageSource {
        guard asset.hasKnownEditState, asset.isAnimatedImage, !asset.isDeveloped, !asset.isEdited else { throw APIError.invalidResponse("Use this photo’s processed preview until its edit information is available.") }
        let epoch = generation, privateEpoch = privateGeneration
        let file = try await client.download(asset: asset, original: true)
        do {
            try Task.checkCancellation()
            guard epoch == generation, asset.visibility != .locked || privateEpoch == privateGeneration else { throw CancellationError() }
            return try AnimatedImageSource(file: file, pixelSize: pixelSize)
        } catch { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()); throw error }
    }

    func personImage(person: Person, pixelSize: Int) async throws -> PreparedImage {
        let identity = MediaCacheIdentity(scope: client.cacheScope, person: person, pixelSize: pixelSize)
        if let image = cachedFace(identity) { return image }
        return try await faceFlight(identity, person: person).value
    }

    /// Starts every face not in memory yet, a few at a time, so the people shelf has them all
    /// before it is first scrubbed.
    func warmFaces(_ people: [Person], pixelSize: Int) async {
        for person in people {
            let identity = MediaCacheIdentity(scope: client.cacheScope, person: person, pixelSize: pixelSize)
            guard cachedFace(identity) == nil else { continue }
            _ = try? await faceFlight(identity, person: person)
        }
    }

    private func faceFlight(_ identity: MediaCacheIdentity, person: Person) async throws -> Task<PreparedImage, Error> {
        if let flight = faceFlights[identity] { return flight }
        let request = try await client.authorizedRequest(path: "people/\(person.id)/thumbnail", query: [.init(name: "c", value: identity.revision)])
        if let flight = faceFlights[identity] { return flight }
        let session = self.session, limiter = faceLimiter
        let task = Task.detached(priority: .utility) { () throws -> PreparedImage in
            try await limiter.acquire()
            do {
                let (data, response) = try await session.data(for: request)
                try ServerFailure.check(response, body: data)
                let image = try Self.downsample(data, pixelSize: identity.pixelSize)
                await limiter.release()
                return image
            } catch {
                await limiter.release()
                throw error
            }
        }
        faceFlights[identity] = task
        let generation = self.generation
        Task { await self.finishFace(identity, task: task, generation: generation) }
        return task
    }

    private func finishFace(_ identity: MediaCacheIdentity, task: Task<PreparedImage, Error>, generation: UUID) async {
        let image = try? await task.value
        if faceFlights[identity] == task { faceFlights[identity] = nil }
        guard let image, generation == self.generation else { return }
        faceCache(identity).setObject(CachedImage(image), forKey: identity.stableKey as NSString, cost: image.byteCost)
    }

    /// `token` is the media fence's from when the image was asked for. A photo forgotten since is
    /// not downloaded, or, if its download was already under way, not remembered or left in the
    /// URL cache.
    private func load(_ key: MediaCacheIdentity, request: URLRequest, isPrivate: Bool = false, token: UInt64) async throws -> PreparedImage {
        let assetID = key.resource.hasPrefix("assets/") ? String(key.resource.dropFirst(7)) : nil
        if let assetID, !fence.admits(assetID, since: token) { throw CancellationError() }
        if isPrivate {
            privateKeys.insert(key)
            byteCache.removeCachedResponse(for: request)
        } else if let assetID {
            cachedRequests[assetID, default: []].insert(request)
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let image = decoded.object(forKey: key.stableKey as NSString) { return image.image }
            let flight: Flight
            if var existing = flights[key] {
                existing.waiters.insert(waiter); flights[key] = existing; flight = existing
            } else {
                let session = isPrivate ? self.privateSession : self.session
                let limiter = key.size.hasPrefix(MediaSize.thumbnail.rawValue) ? self.thumbnailLimiter : self.limiter
                let task = Task.detached(priority: .userInitiated) {
                    try await limiter.acquire()
                    do {
                        try Task.checkCancellation()
                        let (data, response) = try await session.data(for: request)
                        try ServerFailure.check(response, body: data)
                        try Task.checkCancellation()
                        let image = try Self.downsample(data, pixelSize: key.pixelSize)
                        try Task.checkCancellation()
                        await limiter.release()
                        return image
                    } catch {
                        await limiter.release()
                        throw error
                    }
                }
                flight = Flight(task: task, waiters: [waiter], generation: generation, privateGeneration: isPrivate ? privateGeneration : nil,
                                token: token)
                flights[key] = flight
            }
            defer { release(key, waiter: waiter) }
            let image = try await flight.task.value
            try Task.checkCancellation()
            guard flight.generation == generation, flight.privateGeneration == nil || flight.privateGeneration == privateGeneration else { throw CancellationError() }
            // A joined flight may have begun after this caller's token, or before it.
            let admitted = min(token, flight.token)
            if let assetID, !fence.admits(assetID, since: admitted) {
                byteCache.removeCachedResponse(for: request)
                throw CancellationError()
            }
            memory.remember(image, as: key, token: admitted, latestToo: !isPrivate)
            return image
        } onCancel: {
            Task { await self.release(key, waiter: waiter) }
        }
    }

    private func release(_ key: MediaCacheIdentity, waiter: UUID) {
        guard var flight = flights[key], flight.waiters.remove(waiter) != nil else { return }
        if flight.waiters.isEmpty {
            flight.task.cancel()
            flights.removeValue(forKey: key)
        } else {
            flights[key] = flight
        }
    }

    func removePrivate() {
        privateGeneration = UUID()
        for key in privateKeys {
            flights.removeValue(forKey: key)?.task.cancel()
            decoded.removeObject(forKey: key.stableKey as NSString)
        }
        privateKeys.removeAll()
    }

    /// Sign-out and Clear browsing cache only: every image of the account, on disk too.
    func removeAll() async {
        removeAllButStoredThumbnails()
        await thumbnails.removeAll()
    }

    /// Everything in memory and the URL cache, and every download in flight, goes; grid thumbnails
    /// on disk stay. For a sync reset, whose sweep then removes the files the index no longer
    /// vouches for.
    func removeAllButStoredThumbnails() {
        removePrivate()
        generation = UUID()
        fence.forgetAll()
        decoder.reset()
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
        for flight in thumbnailFlights.values { flight.task.cancel() }
        thumbnailFlights.removeAll()
        for flight in faceFlights.values { flight.cancel() }
        faceFlights.removeAll()
        faces.removeAllObjects()
        memory.removeAll()
        byteCache.removeAllCachedResponses()
        cachedRequests.removeAll()
        urlCacheHasUnindexedEntries = false
    }

    /// Keeps only the grid thumbnails whose photo the index holds, at the revision it holds.
    func sweepStoredThumbnails(keeping valid: [String: String]) async -> Int {
        await thumbnails.sweep(keeping: valid)
    }

    /// What a library change means for media: the photos it removed, or whose access it took
    /// away, are forgotten, and photos whose previews were made again show them anew. Nothing
    /// else is touched. A sync's removals were already forgotten from the index's purge queue,
    /// which survives a crash, before the change was published.
    func apply(_ change: LibraryChange) async {
        if change.origin != .sync {
            await forget(assetIDs: change.accessLost, revoked: true)
            await forget(assetIDs: change.removed.subtracting(change.accessLost))
        }
        refresh(change.mediaRevisions.filter { !change.removed.contains($0.key) && !change.accessLost.contains($0.key) })
        if !change.mediaRevisions.isEmpty {
            for (id, revision) in change.mediaRevisions { await thumbnails.refresh(assetID: id, revision: revision) }
        }
    }

    /// Images of another revision than the one named leave memory and the URL cache, and a
    /// thumbnail download for one that hasn't started is dropped.
    private func refresh(_ revisions: [String: String]) {
        guard !revisions.isEmpty else { return }
        for (id, revision) in revisions {
            memory.refresh(id, revision: revision, scope: client.cacheScope)
            if let requests = cachedRequests.removeValue(forKey: id) {
                for request in requests { byteCache.removeCachedResponse(for: request) }
            }
        }
        for (key, flight) in thumbnailFlights where !flight.started {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2, let revision = revisions[parts[0]], revision != parts[1] {
                flight.task.cancel(); thumbnailFlights.removeValue(forKey: key)
            }
        }
    }

    /// Photos that left the library drop out of memory and disk, every revision and size of them;
    /// the rest of the library stays cached. Thumbnail downloads of them in flight are cancelled,
    /// and one that finishes anyway is not stored. When access was lost their previews in flight
    /// are cancelled too, and their URL cache entries go. Only when the URL cache may hold one this
    /// launch can't find, from an earlier launch, is the URL cache cleared, never the thumbnails.
    func forget(assetIDs: Set<String>, revoked: Bool = false) async {
        guard !assetIDs.isEmpty else { return }
        fence.forget(assetIDs)
        memory.forget(assetIDs, scope: client.cacheScope)
        for (key, flight) in thumbnailFlights where assetIDs.contains(String(key.prefix { $0 != "|" })) {
            flight.task.cancel(); thumbnailFlights.removeValue(forKey: key)
        }
        if revoked {
            for (key, flight) in flights where key.resource.hasPrefix("assets/") && assetIDs.contains(String(key.resource.dropFirst(7))) {
                flight.task.cancel(); flights.removeValue(forKey: key)
            }
        }
        for id in assetIDs {
            guard let requests = cachedRequests.removeValue(forKey: id) else { continue }
            for request in requests { byteCache.removeCachedResponse(for: request) }
        }
        measureURLCache()
        if revoked, urlCacheHasUnindexedEntries == true {
            byteCache.removeAllCachedResponses()
            cachedRequests.removeAll()
            urlCacheHasUnindexedEntries = false
        }
        await thumbnails.forget(assetIDs: assetIDs)
    }

    /// For tests: puts `data` in the URL cache as a download of the asset at `size` would, and
    /// says whether the URL cache holds it.
    func cacheForTesting(_ data: Data, asset: Asset, size: MediaSize) async throws {
        let request = try await mediaRequest(asset, size: size, edited: true)
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Cache-Control": "max-age=86400"]) else { return }
        byteCache.storeCachedResponse(CachedURLResponse(response: response, data: data, storagePolicy: .allowedInMemoryOnly), for: request)
        cachedRequests[asset.id, default: []].insert(request)
    }
    func urlCacheHolds(_ asset: Asset, size: MediaSize) async throws -> Bool {
        byteCache.cachedResponse(for: try await mediaRequest(asset, size: size, edited: true)) != nil
    }

    func cacheUsage() async -> MediaCacheUsage {
        MediaCacheUsage(memoryBytes: byteCache.currentMemoryUsage, diskBytes: byteCache.currentDiskUsage + (await thumbnails.currentUsage()),
                        pendingLoads: flights.count + thumbnailFlights.count + decoder.pendingCount, decodedMemoryLimit: decoded.totalCostLimit)
    }
    func trimMemory() { memory.removeAll() }

    nonisolated static func downsample(_ data: Data, pixelSize: Int) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, pixelSize)
              ] as CFDictionary) else {
            throw APIError.invalidResponse("This image could not be decoded.")
        }
        return PreparedImage(cgImage: cgImage)
    }
}

struct MediaCacheUsage: Sendable {
    let memoryBytes: Int
    let diskBytes: Int
    let pendingLoads: Int
    let decodedMemoryLimit: Int
}

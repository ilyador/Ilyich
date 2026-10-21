import CryptoKit
import Foundation
import IlyichPlatform
import ImageIO
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

/// The decoded caches, handed to the thumbnail decoder. NSCache is thread-safe.
private struct ThumbnailMemory: @unchecked Sendable {
    let decoded: NSCache<NSString, CachedImage>
    let latest: NSCache<NSString, CachedImage>
}

actor MediaPipeline {
    private struct Flight {
        let task: Task<PreparedImage, Error>
        var waiters: Set<UUID>
        let generation: UUID
        let privateGeneration: UUID?
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
    private nonisolated(unsafe) let decoded = NSCache<NSString, CachedImage>()
    /// The newest thumbnail and preview of each asset at whatever size it was decoded. The viewer
    /// opens on it while a sharper copy loads.
    private nonisolated(unsafe) let latest = NSCache<NSString, CachedImage>()
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

    init(client: APIClient, memoryLimit: Int = 160 * 1024 * 1024, diskLimit: Int = 300 * 1024 * 1024) {
        self.client = client
        let scope = SHA256.hash(data: Data(client.cacheScope.utf8)).map { String(format: "%02x", $0) }.joined()
        byteCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: diskLimit, diskPath: "IlyichMedia/\(scope)")
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = byteCache
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpMaximumConnectionsPerHost = 12
        configuration.timeoutIntervalForRequest = 45
        session = URLSession(configuration: configuration, delegate: SameOriginRedirectDelegate(origin: client.baseURL), delegateQueue: nil)
        let ephemeral = URLSessionConfiguration.ephemeral
        ephemeral.urlCache = nil; ephemeral.httpCookieStorage = nil
        ephemeral.requestCachePolicy = .reloadIgnoringLocalCacheData
        privateSession = URLSession(configuration: ephemeral, delegate: SameOriginRedirectDelegate(origin: client.baseURL), delegateQueue: nil)
        let thumbnailConfiguration = URLSessionConfiguration.default
        thumbnailConfiguration.urlCache = nil; thumbnailConfiguration.httpCookieStorage = nil
        thumbnailConfiguration.httpShouldSetCookies = false
        thumbnailConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        thumbnailConfiguration.httpMaximumConnectionsPerHost = 6
        thumbnailConfiguration.timeoutIntervalForRequest = 30
        thumbnailSession = URLSession(configuration: thumbnailConfiguration, delegate: SameOriginRedirectDelegate(origin: client.baseURL), delegateQueue: nil)
        thumbnails = ThumbnailStore(scope: client.cacheScope)
        let memory = ThumbnailMemory(decoded: decoded, latest: latest)
        decoder = ThumbnailDecoder(store: thumbnails) { image, key in Self.remember(image, as: key, in: memory) }
        decoded.totalCostLimit = memoryLimit
        decoded.countLimit = 2_000
        latest.totalCostLimit = memoryLimit / 4
        latest.countLimit = 600
        faces.totalCostLimit = 24 * 1024 * 1024
        faces.countLimit = 1_500
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
        "\(scope.utf8.count):\(scope)\(resource)|\(size)"
    }

    func image(for asset: Asset, size: MediaSize = .thumbnail, pixelSize: Int, edited: Bool = true) async throws -> PreparedImage {
        if size == .thumbnail, edited, asset.visibility != .locked {
            guard let image = try await thumbnail(asset, pixelSize: pixelSize, network: true) else { throw CancellationError() }
            return image
        }
        let privacyToken = privateGeneration
        let identity = MediaCacheIdentity(scope: client.cacheScope, asset: asset, size: size, pixelSize: pixelSize, edited: edited)
        let request = try await client.authorizedRequest(path: "assets/\(asset.id)/thumbnail", query: [
            .init(name: "size", value: size.rawValue), .init(name: "edited", value: String(edited)),
            .init(name: "c", value: asset.cacheRevision)
        ])
        guard asset.visibility != .locked || privacyToken == privateGeneration else { throw CancellationError() }
        return try await load(identity, request: request, isPrivate: asset.visibility == .locked)
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

    private nonisolated func thumbnailRequest(_ asset: Asset, pixelSize: Int) -> ThumbnailDecoder.Request {
        ThumbnailDecoder.Request(identity: MediaCacheIdentity(scope: client.cacheScope, asset: asset, size: .thumbnail, pixelSize: pixelSize),
                                 assetID: asset.id, revision: asset.cacheRevision)
    }

    nonisolated func hasStoredThumbnail(_ asset: Asset) -> Bool {
        thumbnails.contains(assetID: asset.id, revision: asset.cacheRevision)
    }

    /// Downloads a thumbnail into the store without decoding it, for keeping the library offline.
    func storeThumbnail(_ asset: Asset) async throws {
        guard asset.visibility != .locked, !hasStoredThumbnail(asset) else { return }
        _ = try await thumbnailData(asset)
    }

    private func thumbnail(_ asset: Asset, pixelSize: Int, network: Bool) async throws -> PreparedImage? {
        let request = thumbnailRequest(asset, pixelSize: pixelSize), identity = request.identity
        if let image = decoded.object(forKey: identity.stableKey as NSString) { return image.image }
        let epoch = generation
        // The decoder remembers what it decodes, and a reset drops it.
        if let stored = await decoder.image(request) { return stored }
        try Task.checkCancellation()
        guard network else { return nil }
        let data = try await thumbnailData(asset)
        let image = try await Task.detached(priority: .userInitiated) { try Self.downsample(data, pixelSize: pixelSize) }.value
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        remember(image, as: identity)
        return image
    }

    /// One download per photo revision, shared by every cell size that wants it. A download that
    /// has not started is dropped when nobody waits for it; one that has started completes into
    /// the store, because the server does the work either way.
    private func thumbnailData(_ asset: Asset) async throws -> Data {
        let key = asset.id + "|" + asset.cacheRevision
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if thumbnailFlights[key] == nil {
                let request = try await client.authorizedRequest(path: "assets/\(asset.id)/thumbnail", query: [
                    .init(name: "size", value: MediaSize.thumbnail.rawValue), .init(name: "edited", value: "true"),
                    .init(name: "c", value: asset.cacheRevision)
                ])
                try Task.checkCancellation()
                // Another caller may have started the same download while the request was built.
                if thumbnailFlights[key] == nil {
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
                                await store.store(data, assetID: asset.id, revision: revision)
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

    private nonisolated func remember(_ image: PreparedImage, as key: MediaCacheIdentity) {
        Self.remember(image, as: key, in: ThumbnailMemory(decoded: decoded, latest: latest))
    }

    private nonisolated static func remember(_ image: PreparedImage, as key: MediaCacheIdentity, in memory: ThumbnailMemory) {
        memory.decoded.setObject(CachedImage(image), forKey: key.stableKey as NSString, cost: image.byteCost)
        if key.resource.hasPrefix("assets/"), key.size.hasSuffix(":edited=true:locked=false"),
           let size = key.size.split(separator: ":").first, size != MediaSize.fullsize.rawValue {
            memory.latest.setObject(CachedImage(image, revision: key.revision),
                                    forKey: latestKey(scope: key.scope, resource: key.resource, size: String(size)) as NSString, cost: image.byteCost)
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

    private func load(_ key: MediaCacheIdentity, request: URLRequest, isPrivate: Bool = false) async throws -> PreparedImage {
        if isPrivate {
            privateKeys.insert(key)
            byteCache.removeCachedResponse(for: request)
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
                flight = Flight(task: task, waiters: [waiter], generation: generation, privateGeneration: isPrivate ? privateGeneration : nil)
                flights[key] = flight
            }
            defer { release(key, waiter: waiter) }
            let image = try await flight.task.value
            try Task.checkCancellation()
            guard flight.generation == generation, flight.privateGeneration == nil || flight.privateGeneration == privateGeneration else { throw CancellationError() }
            if isPrivate { decoded.setObject(CachedImage(image), forKey: key.stableKey as NSString, cost: image.byteCost) }
            else { remember(image, as: key) }
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

    func removeAll() async {
        removePrivate()
        generation = UUID()
        decoder.reset()
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
        for flight in thumbnailFlights.values { flight.task.cancel() }
        thumbnailFlights.removeAll()
        for flight in faceFlights.values { flight.cancel() }
        faceFlights.removeAll()
        faces.removeAllObjects()
        decoded.removeAllObjects()
        latest.removeAllObjects()
        byteCache.removeAllCachedResponses()
        await thumbnails.removeAll()
    }

    /// Photos that left the library drop out of memory and disk; the rest of the library stays
    /// cached. Decoded copies are keyed by revision and cell size, so they can't be found by ID,
    /// but nothing asks for them once their photo is gone, and they age out. When access was lost
    /// the URL cache goes too, since its previews can't be found by ID either.
    func forget(assetIDs: Set<String>, revoked: Bool = false) async {
        guard !assetIDs.isEmpty else { return }
        for id in assetIDs {
            for size in [MediaSize.thumbnail, .preview] {
                latest.removeObject(forKey: Self.latestKey(scope: client.cacheScope, resource: "assets/\(id)", size: size.rawValue) as NSString)
            }
        }
        for (key, flight) in thumbnailFlights where assetIDs.contains(String(key.prefix { $0 != "|" })) {
            flight.task.cancel(); thumbnailFlights.removeValue(forKey: key)
        }
        if revoked {
            for (key, flight) in flights where key.resource.hasPrefix("assets/") && assetIDs.contains(String(key.resource.dropFirst(7))) {
                flight.task.cancel(); flights.removeValue(forKey: key)
            }
            byteCache.removeAllCachedResponses()
        }
        await thumbnails.forget(assetIDs: assetIDs)
    }

    func cacheUsage() async -> MediaCacheUsage {
        MediaCacheUsage(memoryBytes: byteCache.currentMemoryUsage, diskBytes: byteCache.currentDiskUsage + (await thumbnails.currentUsage()),
                        pendingLoads: flights.count + thumbnailFlights.count + decoder.pendingCount, decodedMemoryLimit: decoded.totalCostLimit)
    }
    func trimMemory() { decoded.removeAllObjects(); latest.removeAllObjects() }

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

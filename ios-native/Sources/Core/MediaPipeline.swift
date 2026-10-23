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

/// The decoded previews and full-size images (grid thumbnails live in DecodedThumbnailCache),
/// with an index from each photo to its entries, so a photo's images can be
/// forgotten by its ID. Every write and removal of a photo's entries happens under the index's
/// lock, after a check of the media fence, so a decode that finishes after its photo was
/// forgotten never reaches memory. NSCache is thread-safe and has no delegate here, so it never
/// calls back into the lock.
private final class MediaMemory: @unchecked Sendable {
    let decoded = NSCache<NSString, CachedImage>()
    /// The newest preview of each asset at whatever size it was decoded. The viewer opens on it
    /// while a sharper copy loads.
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

/// The Locked Folder's images, apart from every other cache (REBUILD_ROADMAP.md N5). Only a locked
/// photo's media is kept here, only while the account's Locked Folder is unlocked, and a relock
/// empties it at once from any thread. Each image is asked for under a ticket: emptying, or the
/// account's private epoch moving, makes every earlier ticket stale, so a download that ends after
/// the folder relocked is never kept. Writes and emptying happen under one lock, so nothing lands
/// once `purge` has returned. NSCache is thread-safe and has no delegate here.
private final class PrivateMediaMemory: @unchecked Sendable {
    struct Ticket: Hashable, Sendable {
        let generation: UInt64
        /// The account's private epoch the folder was unlocked under; nil for a client without an
        /// account, whose locked media needs no unlocking.
        let privateEpoch: UInt64?
    }

    private let images = NSCache<NSString, CachedImage>()
    private struct State {
        var generation: UInt64 = 0
        /// The keys of the images kept, some of which NSCache may have evicted.
        var keys: Set<String> = []
    }
    private let state = Mutex(State())
    private let authorization: AuthorizationState?

    init(authorization: AuthorizationState?) {
        self.authorization = authorization
        images.totalCostLimit = 48 * 1024 * 1024
        images.countLimit = 400
    }

    /// A ticket for media asked for now, or nil while the account's Locked Folder is locked.
    func ticket() -> Ticket? { state.withLock { ticket(generation: $0.generation) } }

    /// The ticket that is current, given the memory's generation. Reads the account's snapshot,
    /// which takes its own lock but never this one.
    private func ticket(generation: UInt64) -> Ticket? {
        guard let authorization else { return Ticket(generation: generation, privateEpoch: nil) }
        let snapshot = authorization.snapshot
        guard snapshot.allows(.lockedMedia) else { return nil }
        return Ticket(generation: generation, privateEpoch: snapshot.privateEpoch)
    }

    func isCurrent(_ ticket: Ticket) -> Bool { state.withLock { self.ticket(generation: $0.generation) == ticket } }

    func image(_ key: String, ticket: Ticket) -> PreparedImage? {
        state.withLock { state in
            guard self.ticket(generation: state.generation) == ticket else { return nil }
            return images.object(forKey: key as NSString)?.image
        }
    }

    /// Keeps `image` unless its ticket went stale meanwhile. Says whether it was kept.
    func remember(_ image: PreparedImage, as key: String, ticket: Ticket) -> Bool {
        state.withLock { state in
            guard self.ticket(generation: state.generation) == ticket else { return false }
            images.setObject(CachedImage(image), forKey: key as NSString, cost: image.byteCost)
            state.keys.insert(key)
            return true
        }
    }

    /// Every image goes, and every ticket given out before is stale.
    func purge() {
        state.withLock { state in
            state.generation &+= 1
            state.keys.removeAll()
            images.removeAllObjects()
        }
    }

    /// A memory warning: the images go; downloads still under way are kept when they land.
    func trim() {
        state.withLock { state in
            state.keys.removeAll()
            images.removeAllObjects()
        }
    }

    var isEmpty: Bool { state.withLock { state in !state.keys.contains { images.object(forKey: $0 as NSString) != nil } } }
}

actor MediaPipeline {
    private struct Flight {
        let task: Task<PreparedImage, Error>
        var waiters: Set<UUID>
        let generation: UUID
        /// The Locked Folder ticket of a locked photo's download; nil for every other.
        let privateTicket: PrivateMediaMemory.Ticket?
        /// The media fence's token when the download began.
        let token: UInt64
    }
    private let client: APIClient
    private let session: URLSession
    private let privateSession: URLSession
    private let byteCache: URLCache
    private let limiter = ImageWorkLimiter()
    /// Few at a time: the server keeps working on a request even after the app gives it up, so a
    /// flood of thumbnails slows down the photo that is actually opened. Grid thumbnails go through
    /// the scheduler; this bounds the other thumbnail-sized images (locked, unedited).
    private let thumbnailLimiter = ImageWorkLimiter(limit: 6)
    /// Grid thumbnails on disk, which the coverage worker checks and resumes from.
    nonisolated let thumbnails: ThumbnailDiskStore
    /// Grid thumbnails decoded in memory, readable from any thread.
    private nonisolated let thumbs: DecodedThumbnailCache
    /// Loads every grid thumbnail: from disk, from the server, for the grid and everyone else.
    nonisolated let scheduler: ThumbnailScheduler
    /// The caches are thread-safe, so views can read them synchronously and draw a cached image
    /// in their first frame instead of flashing empty while an actor hop completes.
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
    /// Locked Folder photos' images, which no other cache ever holds (REBUILD_ROADMAP.md N5).
    private nonisolated let privateMedia: PrivateMediaMemory

    /// Names a server photo from the offline library, with its revision, so a tile that knows only
    /// an ID needs no round trip to the server. Set once the account's index is open.
    private nonisolated let indexedAssets = Mutex<(@Sendable (String) async -> Asset?)?>(nil)

    /// `protocolClasses` serve the downloads, and `earlierURLCacheEntries` says whether the URL
    /// cache holds entries from an earlier launch, for tests; it is measured otherwise.
    /// `memoryLimit` is for previews and full-size images; grid thumbnails have their own budget.
    /// `device` renders phone photos' thumbnails, when the account browses the phone's photos.
    init(client: APIClient, memoryLimit: Int = 64 * 1024 * 1024, diskLimit: Int = 300 * 1024 * 1024,
         protocolClasses: [AnyClass]? = nil, earlierURLCacheEntries: Bool? = nil, device: (any DeviceThumbnailProviding)? = nil) {
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
        let thumbnails = ThumbnailDiskStore.shared(scope: client.cacheScope)
        self.thumbnails = thumbnails
        let memory = MediaMemory(fence: thumbnails.fence)
        self.memory = memory
        let thumbs = DecodedThumbnailCache()
        self.thumbs = thumbs
        // Locked media needs the account's Locked Folder unlocked, as its authorization says.
        privateMedia = PrivateMediaMemory(authorization: client.authorization)
        scheduler = ThumbnailScheduler(store: thumbnails, memory: thumbs,
                                       fetcher: ThumbnailFetcher(client: client, protocolClasses: protocolClasses),
                                       device: device, lanes: ThumbnailScheduler.deviceLanes, watchesNetwork: true)
        let decoded = memory.decoded, latest = memory.latest
        decoded.totalCostLimit = memoryLimit
        decoded.countLimit = 2_000
        latest.totalCostLimit = 40 * 1024 * 1024
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

    /// A decoded copy already in memory, or nil. Never waits and never loads. For a grid thumbnail
    /// `pixelSize` is the cell's short side, and a copy decoded for a larger cell serves too.
    nonisolated func cachedImage(for asset: Asset, size: MediaSize = .thumbnail, pixelSize: Int, edited: Bool = true) -> PreparedImage? {
        guard asset.visibility != .locked else { return nil }
        if size == .thumbnail, edited { return thumbs.image(assetID: asset.id, revision: asset.cacheRevision, shortSide: pixelSize) }
        let identity = MediaCacheIdentity(scope: client.cacheScope, asset: asset, size: size, pixelSize: pixelSize, edited: edited)
        return decoded.object(forKey: identity.stableKey as NSString)?.image
    }

    /// The grid thumbnail in memory that covers a cell of `shortSide` pixels, or nil.
    nonisolated func cachedThumbnail(assetID: String, revision: String, shortSide: Int) -> PreparedImage? {
        thumbs.image(assetID: assetID, revision: revision, shortSide: shortSide)
    }

    /// The newest thumbnail or preview of an asset at any size. Without a revision any version
    /// matches, for views that know only the asset's ID.
    nonisolated func latestImage(assetID: String, size: MediaSize, revision: String? = nil) -> PreparedImage? {
        if size == .thumbnail { return thumbs.largest(assetID: assetID, revision: revision) }
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
        if asset.visibility == .locked {
            // A Locked Folder photo, only while the folder is unlocked: over the session that keeps
            // nothing, into the folder's own memory alone. Never the thumbnail scheduler, its
            // caches, the disk or the URL cache (N5).
            guard let ticket = privateMedia.ticket() else { throw CancellationError() }
            let identity = MediaCacheIdentity(scope: client.cacheScope, asset: asset, size: size, pixelSize: pixelSize, edited: edited)
            if let image = privateMedia.image(identity.stableKey, ticket: ticket) { return image }
            let request = try await mediaRequest(asset, size: size, edited: edited)
            guard privateMedia.isCurrent(ticket) else { throw CancellationError() }
            return try await load(identity, request: request, privately: ticket, token: token)
        }
        if size == .thumbnail, edited {
            guard let image = try await scheduler.image(assetID: asset.id, revision: asset.cacheRevision, shortSide: pixelSize,
                                                        band: .explicit, network: true, token: token) else { throw CancellationError() }
            return image
        }
        let identity = MediaCacheIdentity(scope: client.cacheScope, asset: asset, size: size, pixelSize: pixelSize, edited: edited)
        let request = try await mediaRequest(asset, size: size, edited: edited)
        return try await load(identity, request: request, token: token)
    }

    /// The media fence's token now, for work that will store or remember a photo's media later.
    nonisolated func mediaToken() -> UInt64 { fence.token() }

    /// Where a photo known only by its ID is looked up before the server: the offline library.
    nonisolated func setIndexedAssets(_ lookup: (@Sendable (String) async -> Asset?)?) {
        indexedAssets.withLock { $0 = lookup }
    }

    /// The photo a tile knows only by its ID, as the offline library names it, with its revision.
    /// Only a photo the library lacks is fetched with `fetch`, the server's GET assets/{id}. A tile
    /// names its photo once and asks for its sizes with the name.
    func namedAsset(_ assetID: String, fetch: @Sendable (String) async throws -> Asset) async throws -> Asset {
        let lookup = indexedAssets.withLock { $0 }
        if let lookup, let named = await lookup(assetID) { return named }
        try Task.checkCancellation()
        return try await fetch(assetID)
    }

    /// The grid thumbnail of a photo a tile knows only by its ID, for a tile of `shortSide`
    /// pixels: the offline library names the photo and its revision, so the thumbnail comes from
    /// memory, the disk or the server's thumbnail endpoint with no asset round trip. Only a photo
    /// the library lacks is first fetched with `fetch`, the server's GET assets/{id}.
    func thumbnail(assetID: String, shortSide: Int, fetch: @Sendable (String) async throws -> Asset) async throws -> PreparedImage {
        try await image(for: namedAsset(assetID, fetch: fetch), size: .thumbnail, pixelSize: shortSide)
    }

    private func mediaRequest(_ asset: Asset, size: MediaSize, edited: Bool) async throws -> URLRequest {
        try await client.authorizedRequest(path: "assets/\(asset.id)/thumbnail", query: [
            .init(name: "size", value: size.rawValue), .init(name: "edited", value: String(edited)),
            .init(name: "c", value: asset.cacheRevision)
        ])
    }

    /// A grid thumbnail from memory or disk, or nil if only the network has it.
    nonisolated func storedThumbnail(for asset: Asset, pixelSize: Int) async -> PreparedImage? {
        guard asset.visibility != .locked else { return nil }
        return try? await scheduler.image(assetID: asset.id, revision: asset.cacheRevision, shortSide: pixelSize,
                                          band: .explicit, network: false, token: fence.token())
    }

    /// The grid shows this photo: memory pressure and the budget keep its thumbnail. Every pin is
    /// matched by one unpin.
    nonisolated func pinThumbnail(_ assetID: String) { thumbs.pin(assetID) }
    nonisolated func unpinThumbnail(_ assetID: String) { thumbs.unpin(assetID) }

    nonisolated func hasStoredThumbnail(_ asset: Asset) -> Bool {
        thumbnails.contains(assetID: asset.id, revision: asset.cacheRevision)
    }

    func animation(for asset: Asset, pixelSize: Int) async throws -> AnimatedImageSource {
        guard asset.hasKnownEditState, asset.isAnimatedImage, !asset.isDeveloped, !asset.isEdited else { throw APIError.invalidResponse("Use this photo’s processed preview until its edit information is available.") }
        let epoch = generation
        // A locked photo's animation plays only while the folder is unlocked, and not after it relocks.
        let ticket = asset.visibility == .locked ? privateMedia.ticket() : nil
        if asset.visibility == .locked, ticket == nil { throw CancellationError() }
        let file = try await client.download(asset: asset, original: true)
        do {
            try Task.checkCancellation()
            guard epoch == generation, ticket.map(privateMedia.isCurrent) ?? true else { throw CancellationError() }
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
    /// URL cache. A locked photo's image (`privately` its Locked Folder ticket) is downloaded over
    /// the session that keeps nothing and kept only in the folder's own memory, and only if the
    /// folder hasn't relocked meanwhile.
    private func load(_ key: MediaCacheIdentity, request: URLRequest, privately ticket: PrivateMediaMemory.Ticket? = nil,
                      token: UInt64) async throws -> PreparedImage {
        let assetID = key.resource.hasPrefix("assets/") ? String(key.resource.dropFirst(7)) : nil
        if let assetID, !fence.admits(assetID, since: token) { throw CancellationError() }
        if ticket != nil {
            // Should the photo's media be in the URL cache from before it was locked, it goes.
            byteCache.removeCachedResponse(for: request)
        } else if let assetID {
            cachedRequests[assetID, default: []].insert(request)
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let ticket {
                if let image = privateMedia.image(key.stableKey, ticket: ticket) { return image }
            } else if let image = decoded.object(forKey: key.stableKey as NSString) { return image.image }
            let flight: Flight
            // A download from before the folder relocked is never joined: it is dropped when it lands.
            if var existing = flights[key], existing.privateTicket == ticket {
                existing.waiters.insert(waiter); flights[key] = existing; flight = existing
            } else {
                flights.removeValue(forKey: key)?.task.cancel()
                let session = ticket != nil ? self.privateSession : self.session
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
                flight = Flight(task: task, waiters: [waiter], generation: generation, privateTicket: ticket, token: token)
                flights[key] = flight
            }
            defer { release(key, waiter: waiter) }
            let image = try await flight.task.value
            try Task.checkCancellation()
            guard flight.generation == generation else { throw CancellationError() }
            // A joined flight may have begun after this caller's token, or before it.
            let admitted = min(token, flight.token)
            if let assetID, !fence.admits(assetID, since: admitted) {
                byteCache.removeCachedResponse(for: request)
                throw CancellationError()
            }
            if let ticket {
                guard privateMedia.remember(image, as: key.stableKey, ticket: ticket) else { throw CancellationError() }
                return image
            }
            memory.remember(image, as: key, token: admitted)
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

    /// The Locked Folder relocked (REBUILD_ROADMAP.md N5): every locked photo's image leaves memory
    /// at once, from any thread, and nothing downloading for the folder is kept when it lands.
    /// Those downloads are cancelled on the pipeline's own executor soon after.
    nonisolated func purgePrivateMedia() {
        privateMedia.purge()
        Task { await self.cancelPrivateFlights() }
    }

    /// Whether any locked photo's image is in memory.
    nonisolated var holdsPrivateMedia: Bool { !privateMedia.isEmpty }

    /// Locked photos' downloads asked for before the folder last relocked.
    private func cancelPrivateFlights() {
        for (key, flight) in flights {
            guard let ticket = flight.privateTicket, !privateMedia.isCurrent(ticket) else { continue }
            flight.task.cancel()
            flights.removeValue(forKey: key)
        }
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
        privateMedia.purge()
        generation = UUID()
        fence.forgetAll()
        scheduler.reset()
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
        for flight in faceFlights.values { flight.cancel() }
        faceFlights.removeAll()
        faces.removeAllObjects()
        memory.removeAll()
        thumbs.removeAll()
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
            thumbs.refresh(assetID: id, revision: revision)
            if let requests = cachedRequests.removeValue(forKey: id) {
                for request in requests { byteCache.removeCachedResponse(for: request) }
            }
        }
        scheduler.refresh(revisions)
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
        thumbs.forget(assetIDs)
        scheduler.forget(assetIDs)
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
                        pendingLoads: flights.count + scheduler.pendingCount + scheduler.downloadsRunning,
                        decodedMemoryLimit: decoded.totalCostLimit + thumbs.budget)
    }
    /// A memory warning: previews go, the Locked Folder's images, and every grid thumbnail not on screen.
    func trimMemory() {
        memory.removeAll()
        privateMedia.trim()
        thumbs.trimUnpinned()
    }

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

    /// A grid thumbnail decoded to fill a cell whose short side is `shortSide` pixels: the image's
    /// short side reaches it, so aspect-fill never stretches, and it is never decoded larger than
    /// the file.
    nonisolated static func downsampleThumbnail(_ data: Data, shortSide: Int) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw APIError.invalidResponse("This image could not be decoded.")
        }
        var longSide = max(1, shortSide)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 {
            let short = min(width, height), long = max(width, height)
            longSide = shortSide >= short ? long : Int((Double(shortSide) * Double(long) / Double(short)).rounded(.up))
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide
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

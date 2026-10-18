import CryptoKit
import Foundation
import ImageIO
import UIKit

/// CGImage is immutable; only the UIKit wrapper is created on the UI actor.
struct PreparedImage: @unchecked Sendable {
    let cgImage: CGImage
    @MainActor var uiImage: UIImage { UIImage(cgImage: cgImage) }
    var byteCost: Int { cgImage.bytesPerRow * cgImage.height }
}

private final class CachedImage {
    let image: PreparedImage
    init(_ image: PreparedImage) { self.image = image }
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
    private let decoded = NSCache<NSString, CachedImage>()
    private var flights: [MediaCacheIdentity: Flight] = [:]
    private var generation = UUID()
    private var privateGeneration = UUID()
    private var privateKeys = Set<MediaCacheIdentity>()

    init(client: APIClient, memoryLimit: Int = 80 * 1024 * 1024, diskLimit: Int = 300 * 1024 * 1024) {
        self.client = client
        let scope = SHA256.hash(data: Data(client.cacheScope.utf8)).map { String(format: "%02x", $0) }.joined()
        byteCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: diskLimit, diskPath: "IlyichMedia/\(scope)")
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = byteCache
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 45
        session = URLSession(configuration: configuration, delegate: SameOriginRedirectDelegate(origin: client.baseURL), delegateQueue: nil)
        let ephemeral = URLSessionConfiguration.ephemeral
        ephemeral.urlCache = nil; ephemeral.httpCookieStorage = nil
        ephemeral.requestCachePolicy = .reloadIgnoringLocalCacheData
        privateSession = URLSession(configuration: ephemeral, delegate: SameOriginRedirectDelegate(origin: client.baseURL), delegateQueue: nil)
        decoded.totalCostLimit = memoryLimit
        decoded.countLimit = 300
    }

    func image(for asset: Asset, size: MediaSize = .thumbnail, pixelSize: Int, edited: Bool = true) async throws -> PreparedImage {
        let privacyToken = privateGeneration
        let identity = MediaCacheIdentity(scope: client.cacheScope, asset: asset, size: size, pixelSize: pixelSize, edited: edited)
        let request = try await client.authorizedRequest(path: "assets/\(asset.id)/thumbnail", query: [
            .init(name: "size", value: size.rawValue), .init(name: "edited", value: String(edited)),
            .init(name: "c", value: asset.cacheRevision)
        ])
        guard asset.visibility != .locked || privacyToken == privateGeneration else { throw CancellationError() }
        return try await load(identity, request: request, isPrivate: asset.visibility == .locked)
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
        let request = try await client.authorizedRequest(path: "people/\(person.id)/thumbnail", query: [.init(name: "c", value: identity.revision)])
        return try await load(identity, request: request)
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
                let limiter = self.limiter
                let task = Task.detached(priority: .userInitiated) {
                    try await limiter.acquire()
                    do {
                        try Task.checkCancellation()
                        let (data, response) = try await session.data(for: request)
                        try APIClient.validate(response)
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
            decoded.setObject(CachedImage(image), forKey: key.stableKey as NSString, cost: image.byteCost)
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

    func removeAll() {
        removePrivate()
        generation = UUID()
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
        decoded.removeAllObjects()
        byteCache.removeAllCachedResponses()
    }

    func cacheUsage() -> MediaCacheUsage {
        MediaCacheUsage(memoryBytes: byteCache.currentMemoryUsage, diskBytes: byteCache.currentDiskUsage,
                        pendingLoads: flights.count, decodedMemoryLimit: decoded.totalCostLimit)
    }
    func trimMemory() { decoded.removeAllObjects() }

    private nonisolated static func downsample(_ data: Data, pixelSize: Int) throws -> PreparedImage {
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

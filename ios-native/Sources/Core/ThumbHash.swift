import CoreGraphics
import Foundation
import Synchronization
import UIKit

/// Immich gives every photo a thumbhash: about 25 bytes that sketch it as a few blurred color
/// waves. Decoded here, it fills a grid cell the moment the cell appears, before any thumbnail
/// has loaded. A port of the reference `thumbHashToRGBA`, so a sketch matches the web app's.
enum ThumbHash {
    struct Pixels: Equatable {
        let width: Int
        let height: Int
        /// Straight (not premultiplied) RGBA, row by row.
        let rgba: [UInt8]
    }

    static func aspectRatio(_ hash: [UInt8]) -> Double? {
        guard hash.count >= 5 else { return nil }
        let hasAlpha = hash[2] & 0x80 != 0, isLandscape = hash[4] & 0x80 != 0
        let lx = isLandscape ? (hasAlpha ? 5 : 7) : Int(hash[3] & 7)
        let ly = isLandscape ? Int(hash[3] & 7) : (hasAlpha ? 5 : 7)
        guard lx > 0, ly > 0 else { return nil }
        return Double(lx) / Double(ly)
    }

    static func pixels(_ hash: [UInt8]) -> Pixels? {
        guard hash.count >= 5, let ratio = aspectRatio(hash) else { return nil }
        let header24 = Int(hash[0]) | Int(hash[1]) << 8 | Int(hash[2]) << 16
        let header16 = Int(hash[3]) | Int(hash[4]) << 8
        let lDC = Double(header24 & 63) / 63
        let pDC = Double((header24 >> 6) & 63) / 31.5 - 1
        let qDC = Double((header24 >> 12) & 63) / 31.5 - 1
        let lScale = Double((header24 >> 18) & 31) / 31
        let hasAlpha = header24 >> 23 != 0
        let pScale = Double((header16 >> 3) & 63) / 63
        let qScale = Double((header16 >> 9) & 63) / 63
        let isLandscape = header16 >> 15 != 0
        let lx = max(3, isLandscape ? (hasAlpha ? 5 : 7) : header16 & 7)
        let ly = max(3, isLandscape ? header16 & 7 : (hasAlpha ? 5 : 7))
        guard !hasAlpha || hash.count > 5 else { return nil }
        let aDC = hasAlpha ? Double(hash[5] & 15) / 15 : 1
        let aScale = hasAlpha ? Double(hash[5] >> 4) / 15 : 0

        // The varying factors; saturation is boosted 1.25x to make up for quantization.
        let acStart = hasAlpha ? 6 : 5
        var acIndex = 0
        func channel(_ nx: Int, _ ny: Int, _ scale: Double) -> [Double]? {
            var ac: [Double] = []
            for cy in 0..<ny {
                var cx = cy > 0 ? 0 : 1
                while cx * ny < nx * (ny - cy) {
                    let byte = acStart + acIndex >> 1
                    guard byte < hash.count else { return nil }
                    ac.append((Double(Int(hash[byte]) >> ((acIndex & 1) << 2) & 15) / 7.5 - 1) * scale)
                    acIndex += 1; cx += 1
                }
            }
            return ac
        }
        guard let lAC = channel(lx, ly, lScale), let pAC = channel(3, 3, pScale * 1.25),
              let qAC = channel(3, 3, qScale * 1.25), let aAC = hasAlpha ? channel(5, 5, aScale) : [] else { return nil }

        let width = Int((ratio > 1 ? 32 : 32 * ratio).rounded())
        let height = Int((ratio > 1 ? 32 / ratio : 32).rounded())
        guard width > 0, height > 0 else { return nil }
        // The cosine terms depend only on the column or the row, so they are computed once each.
        let columns = max(lx, hasAlpha ? 5 : 3), rows = max(ly, hasAlpha ? 5 : 3)
        let fx = (0..<width).map { x in (0..<columns).map { cos(.pi / Double(width) * (Double(x) + 0.5) * Double($0)) } }
        let fy = (0..<height).map { y in (0..<rows).map { cos(.pi / Double(height) * (Double(y) + 0.5) * Double($0)) } }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var i = 0
        for y in 0..<height {
            for x in 0..<width {
                var l = lDC, p = pDC, q = qDC, a = aDC
                var j = 0
                for cy in 0..<ly {
                    let fy2 = fy[y][cy] * 2
                    var cx = cy > 0 ? 0 : 1
                    while cx * ly < lx * (ly - cy) { l += lAC[j] * fx[x][cx] * fy2; j += 1; cx += 1 }
                }
                j = 0
                for cy in 0..<3 {
                    let fy2 = fy[y][cy] * 2
                    var cx = cy > 0 ? 0 : 1
                    while cx < 3 - cy {
                        let f = fx[x][cx] * fy2
                        p += pAC[j] * f; q += qAC[j] * f
                        j += 1; cx += 1
                    }
                }
                if hasAlpha {
                    j = 0
                    for cy in 0..<5 {
                        let fy2 = fy[y][cy] * 2
                        var cx = cy > 0 ? 0 : 1
                        while cx < 5 - cy { a += aAC[j] * fx[x][cx] * fy2; j += 1; cx += 1 }
                    }
                }
                let b = l - 2 / 3 * p
                let r = (3 * l - b + q) / 2
                let g = r - q
                rgba[i] = UInt8(max(0, 255 * min(1, r)))
                rgba[i + 1] = UInt8(max(0, 255 * min(1, g)))
                rgba[i + 2] = UInt8(max(0, 255 * min(1, b)))
                rgba[i + 3] = UInt8(max(0, 255 * min(1, a)))
                i += 4
            }
        }
        return Pixels(width: width, height: height, rgba: rgba)
    }

    /// The sketch in the format Core Animation draws without converting it: 32-bit little-endian
    /// BGRA, premultiplied, and opaque when the photo has no transparency. Straight RGBA made Core
    /// Animation convert every sketch on the main thread as it was committed.
    static func image(_ base64: String) -> CGImage? {
        guard let data = Data(base64Encoded: base64), let pixels = pixels([UInt8](data)) else { return nil }
        var bgra = [UInt8](repeating: 0, count: pixels.rgba.count)
        var opaque = true
        for i in stride(from: 0, to: pixels.rgba.count, by: 4) {
            let alpha = pixels.rgba[i + 3]
            if alpha != 255 { opaque = false }
            bgra[i] = premultiply(pixels.rgba[i + 2], alpha)
            bgra[i + 1] = premultiply(pixels.rgba[i + 1], alpha)
            bgra[i + 2] = premultiply(pixels.rgba[i], alpha)
            bgra[i + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        let alpha = opaque ? CGImageAlphaInfo.noneSkipFirst : .premultipliedFirst
        return CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | alpha.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func premultiply(_ channel: UInt8, _ alpha: UInt8) -> UInt8 {
        UInt8((UInt16(channel) * UInt16(alpha) + 127) / 255)
    }

    /// The sketch's average colour, read from the hash's header alone: what a cell shows for the
    /// moment before its sketch is decoded. A port of the reference `thumbHashToAverageRGBA`.
    static func averageColor(_ hash: [UInt8]) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard hash.count >= 5 else { return nil }
        let header = Int(hash[0]) | Int(hash[1]) << 8 | Int(hash[2]) << 16
        let l = Double(header & 63) / 63
        let p = Double((header >> 6) & 63) / 31.5 - 1
        let q = Double((header >> 12) & 63) / 31.5 - 1
        let hasAlpha = header >> 23 != 0
        guard !hasAlpha || hash.count > 5 else { return nil }
        let b = l - 2 / 3 * p
        let r = (3 * l - b + q) / 2
        let g = r - q
        return (max(0, min(1, r)), max(0, min(1, g)), max(0, min(1, b)), hasAlpha ? Double(hash[5] & 15) / 15 : 1)
    }

    static func averageColor(_ base64: String) -> UIColor? {
        guard let data = Data(base64Encoded: base64), let color = averageColor([UInt8](data)) else { return nil }
        return UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

/// Decoded sketches are tiny (about 2 KB), so thousands stay in memory for scrolling back. They
/// decode on a queue of their own, never on the main thread: a scrub binds hundreds of cells a
/// second, and decoding each sketch as its cell was bound took a large share of every frame.
final class ThumbHashSketches: Sendable {
    static let shared = ThumbHashSketches()

    /// NSCache is thread-safe.
    private nonisolated(unsafe) let cache = NSCache<NSString, CGImage>()
    private let queue = DispatchQueue(label: "ilyich.thumbhash-sketches", qos: .userInitiated)
    /// Callers waiting for a sketch that is being decoded, by hash.
    private let waiting = Mutex<[String: [CheckedContinuation<CGImage?, Never>]]>([:])

    init(countLimit: Int = 6_000) { cache.countLimit = countLimit }

    /// The sketch, if it has been decoded. Never waits.
    func cached(_ hash: String) -> CGImage? { cache.object(forKey: hash as NSString) }

    /// The sketch, decoded off the main thread, or nil for a damaged hash.
    func sketch(_ hash: String) async -> CGImage? {
        if let image = cached(hash) { return image }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let first = waiting.withLock { waiting -> Bool in
                waiting[hash, default: []].append(continuation)
                return waiting[hash]?.count == 1
            }
            guard first else { return }
            queue.async { [self] in
                let image = decode(hash)
                for waiter in waiting.withLock({ $0.removeValue(forKey: hash) ?? [] }) { waiter.resume(returning: image) }
            }
        }
    }

    /// The sketch decoded on the calling thread, for a grid moving slowly enough that few cells
    /// bind a frame; nil for a damaged hash.
    func decodeNow(_ hash: String) -> CGImage? { decode(hash) }

    /// Decodes the sketches of photos about to scroll in, so their cells have them at once.
    func prefetch(_ hashes: [String]) {
        let missing = hashes.filter { !$0.isEmpty && cached($0) == nil }
        guard !missing.isEmpty else { return }
        queue.async { [self] in
            for hash in missing { _ = decode(hash) }
        }
    }

    private func decode(_ hash: String) -> CGImage? {
        if let image = cached(hash) { return image }
        guard let image = autoreleasepool(invoking: { ThumbHash.image(hash) }) else { return nil }
        cache.setObject(image, forKey: hash as NSString)
        return image
    }
}

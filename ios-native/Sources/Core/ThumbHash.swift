import CoreGraphics
import Foundation
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

    static func image(_ base64: String) -> CGImage? {
        guard let data = Data(base64Encoded: base64), let pixels = pixels([UInt8](data)),
              let provider = CGDataProvider(data: Data(pixels.rgba) as CFData) else { return nil }
        return CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Decoded sketches are tiny (about 2 KB), so thousands stay in memory for scrolling back.
@MainActor enum ThumbHashImages {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 6_000
        return cache
    }()

    static func image(for asset: Asset) -> UIImage? {
        guard let hash = asset.thumbhash, !hash.isEmpty else { return nil }
        if let image = cache.object(forKey: hash as NSString) { return image }
        guard let cgImage = ThumbHash.image(hash) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: hash as NSString)
        return image
    }
}

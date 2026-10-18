import Foundation
import ImageIO

struct AnimatedImageFrame: Sendable {
    let image: PreparedImage
    let duration: TimeInterval
}

/// ImageIO decodes one displayed frame at a time off the UI actor. The original
/// remains a temporary file, rather than an array of every decompressed frame.
actor AnimatedImageSource {
    private var source: CGImageSource?
    private let file: URL
    private let pixelSize: Int
    private let frameCount: Int
    private let totalLoops: Int?
    private var index = 0
    private var completedLoops = 0

    init(file: URL, pixelSize: Int) throws {
        self.file = file; self.pixelSize = min(max(pixelSize, 1), 4096)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 1 else {
            throw APIError.invalidResponse("This image does not contain playable animation frames.")
        }
        self.source = source; frameCount = CGImageSourceGetCount(source)
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any]
        if let count = (gif?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue {
            // GIF's Netscape extension counts repeats after the first play.
            totalLoops = count == 0 ? nil : max(1, count + 1)
        } else if let count = ((png?[kCGImagePropertyAPNGLoopCount] ?? webp?[kCGImagePropertyWebPLoopCount]) as? NSNumber)?.intValue {
            totalLoops = count == 0 ? nil : max(1, count)
        } else { totalLoops = 1 }
    }
    deinit { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    func next() throws -> AnimatedImageFrame? {
        try Task.checkCancellation()
        guard let source, totalLoops == nil || completedLoops < totalLoops! else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                                      kCGImageSourceShouldCacheImmediately: true,
                                      kCGImageSourceShouldCache: false]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw APIError.invalidResponse("An animation frame could not be read.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let duration = Self.duration(properties)
        index += 1
        if index == frameCount { index = 0; completedLoops += 1 }
        return AnimatedImageFrame(image: PreparedImage(cgImage: image), duration: duration)
    }
    func close() {
        source = nil
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
    private static func duration(_ properties: [CFString: Any]) -> TimeInterval {
        for (dictionary, unclamped, clamped) in [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
        ] {
            if let values = properties[dictionary] as? [CFString: Any], let value = ((values[unclamped] ?? values[clamped]) as? NSNumber)?.doubleValue {
                // Match common image decoders for missing/zero or sub-20 ms delays.
                return value.isFinite && value >= 0.02 ? min(value, 86_400) : 0.1
            }
        }
        return 0.1
    }
}

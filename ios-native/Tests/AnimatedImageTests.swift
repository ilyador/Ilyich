import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Ilyich

@MainActor
final class AnimatedImageTests: XCTestCase {
    func testGIFDecodesDifferentFramesAtBoundedResolutionAndHonorsRepeatCount() async throws {
        let file = try makeGIF(repeats: 1)
        let animation = try AnimatedImageSource(file: file, pixelSize: 4)
        let firstFrame = try await animation.next(), secondFrame = try await animation.next()
        let first = try XCTUnwrap(firstFrame), second = try XCTUnwrap(secondFrame)
        XCTAssertEqual(first.image.cgImage.width, 4)
        XCTAssertEqual(first.image.cgImage.height, 2)
        XCTAssertEqual(first.duration, 0.08, accuracy: 0.001)
        XCTAssertEqual(second.duration, 0.16, accuracy: 0.001)
        XCTAssertNotEqual(pixel(first.image.cgImage), pixel(second.image.cgImage))
        let repeated = try await animation.next()
        let repeatFirst = try XCTUnwrap(repeated)
        XCTAssertEqual(pixel(first.image.cgImage), pixel(repeatFirst.image.cgImage))
        _ = try await animation.next()
        let finished = try await animation.next()
        XCTAssertNil(finished)
        await animation.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    func testInfiniteGIFStopsAndRemovesTemporaryFileWhenClosed() async throws {
        let file = try makeGIF(repeats: 0)
        let animation = try AnimatedImageSource(file: file, pixelSize: 12)
        for _ in 0..<6 {
            let frame = try await animation.next()
            XCTAssertNotNil(frame)
        }
        await animation.close()
        let closed = try await animation.next()
        XCTAssertNil(closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    private func makeGIF(repeats: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("animation.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: repeats]] as CFDictionary)
        for (index, components) in [[CGFloat(1), 0, 0, 1], [CGFloat(0), 0, 1, 1]].enumerated() {
            let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 6, bitsPerComponent: 8, bytesPerRow: 48,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: components)!); context.fill(CGRect(x: 0, y: 0, width: 12, height: 6))
            let image = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: index == 0 ? 0.08 : 0.16]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw APIError.invalidResponse("Animation fixture could not be created.") }
        return file
    }
    private func pixel(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}

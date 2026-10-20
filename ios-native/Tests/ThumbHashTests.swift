import XCTest
@testable import Ilyich

/// Expected values come from the reference JavaScript library (thumbhash 0.1.1), which the
/// server and the web app use, decoding hashes it encoded from synthetic images.
final class ThumbHashTests: XCTestCase {
    private struct Vector {
        let hash: String
        let width: Int
        let height: Int
        let ratio: Double
        let samples: [(x: Int, y: Int, rgba: [UInt8])]
    }

    private let vectors = [
        Vector(hash: "HIcNXIyGh4d/eHh5eIWHcEf3dQ==", width: 32, height: 18, ratio: 1.75, samples: [
            (0, 0, [66, 123, 249, 255]), (16, 9, [61, 118, 108, 255]), (31, 17, [79, 200, 57, 255]), (3, 14, [22, 148, 20, 255])]),
        Vector(hash: "nMcJLBRyB4iHeId4eHhycNgIhw==", width: 18, height: 32, ratio: 4.0 / 7.0, samples: [
            (0, 0, [0, 46, 125, 255]), (9, 16, [90, 133, 118, 255]), (17, 31, [192, 187, 117, 255]), (3, 28, [197, 57, 118, 255])]),
        Vector(hash: "W1eGHQYmgIqAeqinh4R/B4iIB3iHiICJeA==", width: 32, height: 32, ratio: 1, samples: [
            (0, 0, [109, 87, 104, 0]), (16, 16, [125, 83, 125, 244]), (31, 31, [149, 70, 148, 0]), (3, 28, [98, 83, 151, 0])]),
    ]

    func testDecodingMatchesTheReferenceImplementation() throws {
        for vector in vectors {
            let bytes = [UInt8](try XCTUnwrap(Data(base64Encoded: vector.hash)))
            XCTAssertEqual(try XCTUnwrap(ThumbHash.aspectRatio(bytes)), vector.ratio, accuracy: 0.000001)
            let pixels = try XCTUnwrap(ThumbHash.pixels(bytes))
            XCTAssertEqual(pixels.width, vector.width)
            XCTAssertEqual(pixels.height, vector.height)
            XCTAssertEqual(pixels.rgba.count, vector.width * vector.height * 4)
            for sample in vector.samples {
                let start = (sample.y * pixels.width + sample.x) * 4
                for channel in 0..<4 {
                    // Platform cosines may differ in the last bit; truncation can move a value by one.
                    XCTAssertEqual(Int(pixels.rgba[start + channel]), Int(sample.rgba[channel]), accuracy: 1,
                                   "\(vector.hash) at \(sample.x),\(sample.y) channel \(channel)")
                }
            }
        }
    }

    func testImagesKeepTheSketchSizeAndRejectDamagedHashes() throws {
        let image = try XCTUnwrap(ThumbHash.image("HIcNXIyGh4d/eHh5eIWHcEf3dQ=="))
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 18)
        XCTAssertNil(ThumbHash.image(""))
        XCTAssertNil(ThumbHash.image("not base64"))
        XCTAssertNil(ThumbHash.pixels([0x1c, 0x87]), "A truncated header is not a sketch.")
        XCTAssertNil(ThumbHash.pixels(Array([UInt8](Data(base64Encoded: "HIcNXIyGh4d/eHh5eIWHcEf3dQ==")!).prefix(8))),
                     "A hash cut short must not read past its end.")
    }
}

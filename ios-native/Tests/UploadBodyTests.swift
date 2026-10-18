import XCTest
@testable import Ilyich

final class UploadBodyTests: XCTestCase {
    func testStreamingChecksumMatchesServerSHA1Encoding() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try UploadBody.checksum(file), "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=")
    }

    func testMultipartPreservesAssetAndSidecarAndEscapesHeaderInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let assetURL = directory.appendingPathComponent("asset")
        let sidecarURL = directory.appendingPathComponent("sidecar")
        let output = directory.appendingPathComponent("body")
        try Data([0, 1, 2, 255]).write(to: assetURL)
        try Data("<xmp>edits</xmp>".utf8).write(to: sidecarURL)
        try UploadBody.write(to: output, boundary: "TestBoundary", fields: ["fileCreatedAt": "2026-10-18T12:00:00Z"],
                             asset: UploadFile(url: assetURL, filename: "image\r\nInjected: x.jpg", contentType: "image/jpeg"),
                             sidecar: UploadFile(url: sidecarURL, filename: "image.xmp", contentType: "application/rdf+xml"))
        let body = try Data(contentsOf: output)
        XCTAssertNotNil(body.range(of: Data([0, 1, 2, 255])))
        XCTAssertNotNil(body.range(of: Data("name=\"sidecarData\"; filename=\"image.xmp\"".utf8)))
        XCTAssertNotNil(body.range(of: Data("<xmp>edits</xmp>".utf8)))
        XCTAssertNil(body.range(of: Data("\r\nInjected:".utf8)))
        XCTAssertTrue(body.suffix(18).elementsEqual(Data("--TestBoundary--\r\n".utf8)))
    }
}

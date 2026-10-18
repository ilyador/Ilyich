import Foundation
import XCTest
@testable import Ilyich

final class SharedInboxTests: XCTestCase {
    func testManifestOnlyReferencesFilesInsideItsOwnBatch() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = parent.appendingPathComponent("batch", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let inside = folder.appendingPathComponent("photo")
        let outside = parent.appendingPathComponent("private-photo")
        try Data([1, 2, 3]).write(to: inside)
        try Data([4, 5, 6]).write(to: outside)
        func batch(_ file: URL) -> SharedBatch {
            SharedBatch(id: UUID(), createdAt: Date(), attachments: [SharedAttachment(original: UploadFile(url: file, filename: "image.jpg", contentType: "image/jpeg"))])
        }
        XCTAssertNoThrow(try SharedInbox.validate(batch(inside), folder: folder))
        XCTAssertThrowsError(try SharedInbox.validate(batch(outside), folder: folder))
        let link = folder.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try SharedInbox.validate(batch(link), folder: folder))
    }

    func testLivePhotoAndSidecarSurviveManifestRoundTrip() throws {
        let folder = URL(fileURLWithPath: "/test/shared")
        let photo = UploadFile(url: folder.appendingPathComponent("still"), filename: "photo.heic", contentType: "image/heic")
        let motion = UploadFile(url: folder.appendingPathComponent("motion"), filename: "photo.mov", contentType: "video/quicktime")
        let sidecar = UploadFile(url: folder.appendingPathComponent("sidecar"), filename: "photo.xmp", contentType: "application/rdf+xml")
        let batch = SharedBatch(id: UUID(), createdAt: Date(), attachments: [SharedAttachment(original: photo, motion: motion, sidecar: sidecar)])
        let restored = try JSONDecoder().decode(SharedBatch.self, from: JSONEncoder().encode(batch))
        XCTAssertEqual(restored.id, batch.id)
        XCTAssertEqual(restored.attachments.first?.motion?.url, motion.url)
        XCTAssertEqual(restored.attachments.first?.sidecar?.filename, sidecar.filename)
    }
}

import Photos
import XCTest
@testable import Ilyich

final class ResourceShapeTests: XCTestCase {
    private let table: [(types: [PHAssetResourceType], isVideo: Bool, shape: ResourceShape)] = [
        ([.photo], false, .singleOriginal),
        ([.video], true, .singleOriginal),
        ([.photo, .pairedVideo], false, .livePhoto),
        ([.pairedVideo, .photo], false, .livePhoto),
        // Edited in Photos, whatever else is there.
        ([.photo, .adjustmentData, .fullSizePhoto], false, .edited),
        ([.photo, .adjustmentBasePhoto, .adjustmentData, .fullSizePhoto], false, .edited),
        ([.video, .adjustmentData, .adjustmentBaseVideo, .fullSizeVideo], true, .edited),
        ([.photo, .pairedVideo, .adjustmentData, .fullSizePhoto, .fullSizePairedVideo, .adjustmentBasePairedVideo], false, .edited),
        ([.photo, .pairedVideo, .fullSizePairedVideo], false, .edited),
        ([.photo, .alternatePhoto, .adjustmentData, .fullSizePhoto], false, .edited),
        // More than one original.
        ([.photo, .alternatePhoto], false, .multipleOriginals),
        ([.photo, .photo], false, .multipleOriginals),
        ([.photo, .video], false, .multipleOriginals),
        ([.video, .video], true, .multipleOriginals),
        // Anything else.
        ([], false, .other),
        ([], true, .other),
        ([.photo], true, .other),
        ([.video], false, .other),
        ([.pairedVideo], false, .other),
        ([.video, .pairedVideo], true, .other),
        ([.photo, .pairedVideo, .pairedVideo], false, .other),
        ([.photo, .audio], false, .other),
        ([.video, .audio], true, .other),
        ([.photo, .photoProxy], false, .other),
    ]

    func testClassificationTable() {
        for row in table {
            XCTAssertEqual(ResourceShape.classify(row.types, isVideo: row.isVideo), row.shape,
                           "\(row.types.map(\.rawValue)) video: \(row.isVideo)")
        }
    }

    /// Only single originals and Live Photos can ever be removed after backup, and never an asset
    /// today's DevicePhotos.canRemove would keep.
    func testRemovableShapesAreNoWiderThanToday() {
        func today(_ types: [PHAssetResourceType]) -> Bool {
            types.filter { $0 == .photo || $0 == .video }.count == 1 && types.allSatisfy { [.photo, .video, .pairedVideo].contains($0) }
        }
        for row in table where [.singleOriginal, .livePhoto].contains(row.shape) {
            XCTAssertTrue(today(row.types), "\(row.types.map(\.rawValue))")
        }
    }
}

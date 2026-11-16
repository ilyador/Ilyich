import Photos
import XCTest
@testable import Ilyich

/// Source matches are evidence about the archived unmodified file, never the edited upload.
final class SourceOriginalRulesTests: XCTestCase {
    private func r(_ type: PHAssetResourceType, _ contentType: String = "public.heic") -> StagingResource {
        StagingResource(type: type, contentType: contentType, filename: "source")
    }

    func testOnlyUniqueGenuineSourcesAlongsideRenderedEdits() {
        let table: [(resources: [StagingResource], isVideo: Bool, source: Int?)] = [
            ([r(.photo), r(.fullSizePhoto)], false, 0),
            ([r(.fullSizePhoto), r(.adjustmentData), r(.photo)], false, 2),
            ([r(.photo), r(.adjustmentBasePhoto), r(.fullSizePhoto)], false, 0),
            ([r(.photo, "com.adobe.raw-image"), r(.fullSizePhoto)], false, 0),
            ([r(.video), r(.fullSizeVideo)], true, 0),
            ([r(.fullSizeVideo), r(.adjustmentBaseVideo), r(.video)], true, 2),
            // No rendered edit: no separate source-original evidence is needed.
            ([r(.photo)], false, nil),
            ([r(.video)], true, nil),
            ([r(.photo), r(.adjustmentData)], false, nil),
            ([r(.video), r(.adjustmentData)], true, nil),
            // Missing originals and adjustment bases never identify the source.
            ([r(.fullSizePhoto)], false, nil),
            ([r(.adjustmentBasePhoto), r(.fullSizePhoto)], false, nil),
            ([r(.adjustmentBaseVideo), r(.fullSizeVideo)], true, nil),
            ([r(.alternatePhoto), r(.fullSizePhoto)], false, nil),
            // RAW+JPEG and duplicated originals or renders are ambiguous.
            ([r(.photo), r(.alternatePhoto, "com.adobe.raw-image"), r(.fullSizePhoto)], false, nil),
            ([r(.photo), r(.photo), r(.fullSizePhoto)], false, nil),
            ([r(.video), r(.video), r(.fullSizeVideo)], true, nil),
            ([r(.photo), r(.fullSizePhoto), r(.fullSizePhoto)], false, nil),
            ([r(.video), r(.fullSizeVideo), r(.fullSizeVideo)], true, nil),
            // A source of the wrong media kind is never substituted.
            ([r(.video), r(.fullSizePhoto)], false, nil),
            ([r(.photo), r(.fullSizeVideo)], true, nil),
            ([r(.photo), r(.video), r(.fullSizePhoto)], false, nil),
            ([], false, nil),
            ([], true, nil),
        ]
        for row in table {
            XCTAssertEqual(StagingRules.sourceOriginal(row.resources, isVideo: row.isVideo), row.source,
                           "\(row.resources.map(\.type.rawValue)) video: \(row.isVideo)")
        }
    }

    func testLivePhotoSourceIdentifiesOnlyTheStillAndDoesNotChooseMotion() {
        let resources = [r(.pairedVideo), r(.photo), r(.fullSizePairedVideo), r(.fullSizePhoto)]
        XCTAssertEqual(StagingRules.sourceOriginal(resources, isVideo: false), 1)
        XCTAssertEqual(StagingRules.motion(resources), 2, "The current motion selection stays independent.")
        XCTAssertNil(StagingRules.sourceOriginal([r(.photo), r(.pairedVideo), r(.fullSizePairedVideo)], isVideo: false),
                     "An edited motion alone does not establish a rendered still edit.")
        XCTAssertNil(StagingRules.sourceOriginal([r(.pairedVideo), r(.fullSizePhoto)], isVideo: false))
    }

}

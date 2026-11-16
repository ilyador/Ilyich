import Foundation
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

    func testIncompleteResourcesDeferWhileUneditedAndUnsupportedShapesEndThisRevision() {
        let table: [(resources: [StagingResource], isVideo: Bool, choice: SourceOriginalResourceChoice)] = [
            ([r(.photo)], false, .notApplicable(.unedited)),
            ([r(.video)], true, .notApplicable(.unedited)),
            ([r(.photo), r(.pairedVideo)], false, .notApplicable(.unedited)),
            ([r(.fullSizePhoto)], false, .deferred(.missingOriginal)),
            ([r(.fullSizeVideo), r(.adjustmentBaseVideo)], true, .deferred(.missingOriginal)),
            ([r(.photo), r(.adjustmentData)], false, .deferred(.incompleteResources)),
            ([r(.adjustmentBasePhoto)], false, .deferred(.incompleteResources)),
            ([r(.pairedVideo)], false, .deferred(.incompleteResources)),
            ([], false, .deferred(.incompleteResources)),
            ([r(.photo), r(.alternatePhoto), r(.fullSizePhoto)], false, .notApplicable(.unsupportedResources)),
            ([r(.video), r(.video), r(.fullSizeVideo)], true, .notApplicable(.unsupportedResources)),
            ([r(.photo), r(.fullSizePhoto), r(.fullSizePhoto)], false, .notApplicable(.unsupportedResources)),
        ]
        for row in table {
            XCTAssertEqual(StagingRules.sourceOriginalSelection(row.resources, isVideo: row.isVideo), row.choice)
        }
    }

    func testIncompleteSameRevisionResourcesPreserveCachedEvidenceAsDeferred() {
        let revision = AssetRevision(referenceSeconds: 700_000_000.25)
        let resources = [r(.photo), r(.fullSizePhoto)]
        let fingerprint = SourceOriginalFingerprint(revision: revision, checksum: "source", resourceSnapshot: resources)
        XCTAssertEqual(StagingRules.validateSourceOriginal(fingerprint, revision: revision, resources: resources, isVideo: false), .current)
        XCTAssertEqual(StagingRules.validateSourceOriginal(fingerprint, revision: revision, resources: [r(.fullSizePhoto)], isVideo: false),
                       .deferred(.snapshotChanged), "An unavailable original does not disprove the saved hash.")
        XCTAssertEqual(StagingRules.validateSourceOriginal(fingerprint, revision: nil, resources: resources, isVideo: false),
                       .deferred(.revisionUnavailable))
        XCTAssertEqual(StagingRules.validateSourceOriginal(fingerprint, revision: AssetRevision(referenceSeconds: 700_000_001),
                                                          resources: resources, isVideo: false), .stale(.revisionSuperseded))
        let legacy = SourceOriginalFingerprint(revision: revision, checksum: "source")
        XCTAssertEqual(StagingRules.validateSourceOriginal(legacy, revision: revision, resources: resources, isVideo: false),
                       .stale(.cachedSnapshotMissing), "Legacy evidence needs a new snapshot rather than waiting forever.")
    }

    func testCompleteSameRevisionResourceChangesPermitFreshEvidenceInsteadOfDeferringForever() {
        let revision = AssetRevision(referenceSeconds: 700_000_000.25)
        for isVideo in [false, true] {
            let original = r(isVideo ? .video : .photo)
            let rendered = r(isVideo ? .fullSizeVideo : .fullSizePhoto)
            let cached = SourceOriginalFingerprint(revision: revision, checksum: "source", resourceSnapshot: [original, rendered])
            for current in [[rendered, original], [original, rendered, r(.adjustmentData)]] {
                XCTAssertEqual(StagingRules.validateSourceOriginal(cached, revision: revision, resources: current, isVideo: isVideo),
                               .stale(.snapshotChanged), "Complete changed resources must allow the matcher to probe again.")
                XCTAssertNotNil(StagingRules.sourceOriginal(current, isVideo: isVideo))
                let refreshed = SourceOriginalFingerprint(revision: revision, checksum: "fresh-source", resourceSnapshot: current)
                XCTAssertEqual(StagingRules.validateSourceOriginal(refreshed, revision: revision, resources: current, isVideo: isVideo),
                               .current, "The refreshed complete snapshot must finish validation on its next attempt.")
            }
        }
    }

    func testOptionalReadErrorsDeferWithoutSwallowingCancellationOrServerFailures() {
        XCTAssertEqual(SourceOriginalReason.deferredSourceRead(NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.networkAccessRequired.rawValue)), .cloudRequired)
        XCTAssertEqual(SourceOriginalReason.deferredSourceRead(NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.missingResource.rawValue)), .missingOriginal)
        XCTAssertEqual(SourceOriginalReason.deferredSourceRead(NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.accessUserDenied.rawValue)), .photosAccess)
        XCTAssertEqual(SourceOriginalReason.deferredSourceRead(URLError(.notConnectedToInternet)), .networkUnavailable)
        XCTAssertEqual(SourceOriginalReason.deferredSourceRead(BackupDeferral.waitingForWiFi), .waitingForWiFi)
        XCTAssertNil(SourceOriginalReason.deferredSourceRead(CancellationError()))
        XCTAssertNil(SourceOriginalReason.deferredSourceRead(URLError(.cancelled)))
        XCTAssertNil(SourceOriginalReason.deferredSourceRead(APIError.signedOut))
        XCTAssertNil(SourceOriginalReason.deferredSourceRead(ServerFailure.http(503, nil)))
    }

    func testLegacyDefaultsKeepUnknownSourceAbsenceAndFalseValidationRetryable() async throws {
        let revision = AssetRevision(referenceSeconds: 700_000_000.25)
        let fingerprint = SourceOriginalFingerprint(revision: revision, checksum: "source")
        let absent = LegacySourceStaging(read: { nil })
        let unknown = try await absent.probeSourceOriginal("asset", revision: revision, policy: StagingPolicy())
        let unavailable = try await absent.validateSourceOriginal("asset", fingerprint: fingerprint, policy: StagingPolicy())
        XCTAssertEqual(unknown, .deferred(.sourceUnavailable))
        XCTAssertEqual(unavailable, .deferred(.sourceUnavailable))
        let available = LegacySourceStaging(read: { fingerprint })
        let found = try await available.probeSourceOriginal("asset", revision: revision, policy: StagingPolicy())
        let current = try await available.validateSourceOriginal("asset", fingerprint: fingerprint, policy: StagingPolicy())
        XCTAssertEqual(found, .fingerprint(fingerprint))
        XCTAssertEqual(current, .current)
        let cancelled = LegacySourceStaging(read: { throw CancellationError() })
        do {
            _ = try await cancelled.probeSourceOriginal("asset", revision: revision, policy: StagingPolicy())
            XCTFail("Cancellation must not become retryable absence.")
        } catch is CancellationError {}
    }
}

/// Intentionally implements only the original optional API, exercising the compatibility bridge.
private struct LegacySourceStaging: PhotoLibraryStaging {
    let read: @Sendable () throws -> SourceOriginalFingerprint?
    var authorization: PHAuthorizationStatus { .authorized }
    func sourceOriginal(_ localID: String, revision: AssetRevision, policy: StagingPolicy) async throws -> SourceOriginalFingerprint? { try read() }
    func albums() async -> [DeviceAlbum] { [] }
    func candidates(scope: PhotoSelectionScope, included: Set<String>, excluded: Set<String>) -> AsyncThrowingStream<[DeviceCandidate], any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func stage(_ localID: String, into directory: URL, stageID: String, policy: StagingPolicy,
               progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedPhoto { throw CocoaError(.fileReadUnknown) }
    func albumMembers(_ albumID: String, excluded: Set<String>, scope: PhotoSelectionScope) async -> [String] { [] }
    func existing(_ localIDs: [String]) async throws -> Set<String> { [] }
}

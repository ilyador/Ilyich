import Foundation
import Photos

/// The authorization epoch is metadata. Capturing a baseline never requests resource bytes.
protocol NewPhotosBaselineAccessReading: Sendable {
    func newPhotosBaselineAccess() async -> DeviceAccess
}

extension PhotoKitAdapter: NewPhotosBaselineAccessReading {
    func newPhotosBaselineAccess() async -> DeviceAccess { refreshAccess() }
}

func newPhotosBaselineAccess(_ staging: any PhotoLibraryStaging) async -> DeviceAccess {
    if let reader = staging as? any NewPhotosBaselineAccessReading { return await reader.newPhotosBaselineAccess() }
    return DeviceAccess(status: staging.authorization, generation: 0)
}

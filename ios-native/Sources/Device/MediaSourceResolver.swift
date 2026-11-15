import Foundation
import Observation

/// A source choice for one phone photo, made before a viewer requests full-size media. An
/// unverified photo remains a device source; that does not assert it is absent from the server.
enum MediaSourceResolution: Equatable, Sendable {
    case server(Asset)
    case device(LocalPhoto)
    /// An exact account-scoped identity is known, but the server could not currently serve it.
    /// Keep this distinct from a device-only choice so an outage never becomes an iCloud prompt.
    case serverUnavailable(photo: LocalPhoto, serverID: String, message: String)
    case unavailable(message: String)
}

/// One account's source resolver and the dependencies its common viewer needs. Every phone
/// entry point uses this service; screens never choose media by file name or assume that a
/// PhotoKit thumbnail proves the full-size original is present on the phone.
@Observable final class MediaSourceResolver: Sendable {
    let api: APIClient
    let pipeline: MediaPipeline
    private let index: DeviceIndexService?
    private let authorization: AuthorizationState

    init(api: APIClient, pipeline: MediaPipeline, index: DeviceIndexService?, authorization: AuthorizationState) {
        self.api = api
        self.pipeline = pipeline
        self.index = index
        self.authorization = authorization
    }

    func resolve(_ photo: LocalPhoto) async -> MediaSourceResolution {
        let epoch = authorization.snapshot.epoch
        guard authorization.permitsServiceUse, authorization.snapshot.allows(.read), !Task.isCancelled else {
            return .unavailable(message: "Sign in again to open this photo.")
        }
        guard let index else { return .unavailable(message: "Photo sources are still being prepared. Try again shortly.") }
        let result = await index.resolveSource(of: photo)
        guard authorization.isCurrent(epoch), authorization.permitsServiceUse,
              authorization.snapshot.allows(.read), !Task.isCancelled else {
            return .unavailable(message: "Your access changed. Open the photo again.")
        }
        return result
    }
}

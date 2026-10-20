import Foundation
import Synchronization

/// The background sessions: one BackgroundTransport per TransferSessionID, created on first use and
/// never twice, whichever launch path asks first (launch, background events or the engine), with
/// their events merged into one stream for the transfer engine.
///
/// Dormant until B9: nothing in the app creates a registry, since a live one would open a second
/// session beside today's BackgroundUploads for the same identifier. scripts/check-single-engine.sh
/// fails the build if code outside this folder names it, and a test checks that the app creates
/// none of its sessions at launch or for background events.
final class TransportRegistry: Sendable {
    typealias Factory = @Sendable (TransferSessionID, _ emit: @escaping @Sendable (TransportEvent) -> Void) -> BackgroundTransport

    /// Every session's progress, finished tasks and drains, each session's in the order it reported them.
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let factory: Factory
    private let transports = Mutex<[TransferSessionID: BackgroundTransport]>([:])

    init(factory: @escaping Factory) {
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.factory = factory
    }

    /// The real sessions, recording outcomes in the App Group. For B9's launch sequence only.
    static func live() -> TransportRegistry { TransportRegistry { BackgroundTransport.live($0, emit: $1) } }

    /// A session's transport, created the first time it is asked for. Racing callers wait for that
    /// one creation behind the lock, so iOS never sees two sessions with one identifier.
    func transport(_ session: TransferSessionID) -> BackgroundTransport {
        transports.withLock { transports in
            if let existing = transports[session] { return existing }
            let stream = self.continuation
            let created = factory(session) { _ = stream.yield($0) }
            transports[session] = created
            return created
        }
    }

    /// The transport for an identifier iOS names, or nil for one this app never created.
    func transport(identifier: String) -> BackgroundTransport? {
        TransferSessionID(identifier: identifier).map { transport($0) }
    }

    /// Creates every session, so iOS delivers what it queued for each.
    func connect() {
        for session in TransferSessionID.allCases { _ = transport(session) }
    }

    /// The sessions created so far.
    var connected: Set<TransferSessionID> { transports.withLock { Set($0.keys) } }
}

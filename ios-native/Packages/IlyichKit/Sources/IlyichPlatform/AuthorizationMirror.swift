import Foundation

/// The account and authorization epoch the app last published in the App Group, for the
/// extensions and upload delegates, which cannot ask the app. The epoch is the app's write
/// generation: it moves when read-only mode is turned on or off and when the session ends, and
/// never repeats on the phone. A reader must not write unless the mirror still shows the digest
/// and epoch its work started under; no value, another digest or another epoch fails closed.
/// Sign-out publishes an empty digest. Beside them the app keeps its access epoch, which no
/// extension reads.
public struct AuthorizationMirror: Sendable {
    public struct Value: Equatable, Sendable {
        public let digest: String
        public let epoch: UInt64

        public init(digest: String, epoch: UInt64) {
            self.digest = digest
            self.epoch = epoch
        }
    }

    static let digestKey = "account.digest"
    static let epochKey = "account.authorizationEpoch"
    static let accessEpochKey = "account.accessEpoch"
    private let suiteName: String

    /// The mirror in an App Group's preferences.
    public init(appGroup: String) { suiteName = appGroup }

    /// The mirror in this bundle's App Group, or nil when the group is unavailable.
    public static func current() -> AuthorizationMirror? {
        guard let group = try? AppGroup.identifier else { return nil }
        return AuthorizationMirror(appGroup: group)
    }

    public func read() -> Value? {
        guard let defaults = UserDefaults(suiteName: suiteName), let digest = defaults.string(forKey: Self.digestKey),
              let epoch = (defaults.object(forKey: Self.epochKey) as? NSNumber)?.uint64Value else { return nil }
        return Value(digest: digest, epoch: epoch)
    }

    public func publish(_ value: Value) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(value.digest, forKey: Self.digestKey)
        defaults.set(NSNumber(value: value.epoch), forKey: Self.epochKey)
    }

    /// The app's access epoch for the account `read()` names, kept beside the write generation so
    /// that a relaunch goes on from both and neither repeats. Only the app reads it.
    public func accessEpoch() -> UInt64? {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        return (defaults.object(forKey: Self.accessEpochKey) as? NSNumber)?.uint64Value
    }

    public func keepAccessEpoch(_ epoch: UInt64) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(NSNumber(value: epoch), forKey: Self.accessEpochKey)
    }
}

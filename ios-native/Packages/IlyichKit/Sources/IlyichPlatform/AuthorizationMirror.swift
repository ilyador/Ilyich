import Foundation

/// The account and authorization epoch the app last published in the App Group, for the
/// extensions and upload delegates, which cannot ask the app. A reader that finds no value,
/// or an older epoch than the one its work started under, must not write.
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
    private let suiteName: String

    /// The mirror in an App Group's preferences.
    public init(appGroup: String) { suiteName = appGroup }

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
}

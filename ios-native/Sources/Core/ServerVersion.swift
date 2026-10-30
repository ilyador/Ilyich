import Foundation

/// The release a server says it runs (GET server/version).
struct ServerVersion: Decodable, Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    /// A release candidate's number; nil for a release, and from servers too old to say.
    var prerelease: Int?

    /// The oldest release the app works with: the first whose sync stream has every type it asks
    /// for (AuthUsersV2, MemoriesV2, MemoryToAssetsV2 and AssetFacesV3 came in 3.3.0, whose
    /// release candidates lacked the memories), with search's filters and cursors (3.2.0).
    static let minimum = ServerVersion(major: 3, minor: 3, patch: 0)

    init(major: Int, minor: Int, patch: Int, prerelease: Int? = nil) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    var isSupported: Bool { self >= Self.minimum }

    /// A release comes after its release candidates.
    static func < (a: Self, b: Self) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        switch (a.prerelease, b.prerelease) {
        case (let x?, let y?): return x < y
        case (_?, nil): return true
        default: return false
        }
    }

    /// Major, minor and patch, as the server's settings show it.
    var name: String { "\(major).\(minor).\(patch)" }
}

/// A server older than ServerVersion.minimum, which the app won't sign in to or sync with.
struct UnsupportedServer: Error, LocalizedError, Equatable, Sendable {
    /// What the server said it runs; nil when it is too old to say.
    let version: ServerVersion?

    var errorDescription: String? {
        let minimum = ServerVersion.minimum.name
        guard let version else { return "This server is too old for Ilyich, which needs version \(minimum) or later." }
        let runs = version.prerelease == nil ? "version \(version.name)" : "a prerelease of version \(version.name)"
        return "This server runs \(runs). Ilyich needs version \(minimum) or later."
    }
}

import CryptoKit
import Foundation

/// Verbatim Codable mirrors of formats on disk that no store of the app's owns: the widget's
/// snapshot metadata, what the Flutter app left for its widget (W4, skipped by the owner, would
/// have imported both), and the thumbnail store's v1 file layout. Each mirror reads every shape its
/// writer ever produced and keeps the writer's key names and types. The writers used JSONEncoder's
/// defaults, so dates are seconds since 2001 (deferredToDate) and URLs are absolute strings: decode
/// with `Legacy.decoder()`. Golden fixtures in Tests/Fixtures pin each format.
///
/// The backup, share manifest, places and fingerprint mirrors went with their importers and
/// readers in C8: nothing on the phone still holds those formats, and no build that writes them
/// will be installed again.
enum Legacy {
    /// JSONDecoder's defaults, which every legacy writer's JSONEncoder matched.
    static func decoder() -> JSONDecoder { JSONDecoder() }

    // MARK: Widget

    /// <AppGroup>/WidgetCache2/<digest>/<key>_metadata.json beside <key>_image.png, written by
    /// the widget's ImageEntry.cache(for:). Keys are random_<album ID>_<family> and
    /// memory_<family>, the family being WidgetFamily's raw value. Flutter builds wrote the same
    /// pair at the container's root, without an account scope; builds before 3040055 wrote it
    /// under WidgetCache/<digest>.
    struct WidgetMetadata: Codable, Sendable {
        var subtitle: String? = nil
        var error: WidgetError? = nil
        var deepLink: URL? = nil
        var forceFullColor: Bool = true
        /// The account digest the snapshot belongs to. Absent in Flutter snapshots.
        var accountScope: String? = nil

        init(subtitle: String? = nil, error: WidgetError? = nil, deepLink: URL? = nil, forceFullColor: Bool = true, accountScope: String? = nil) {
            self.subtitle = subtitle; self.error = error; self.deepLink = deepLink
            self.forceFullColor = forceFullColor; self.accountScope = accountScope
        }
        private enum CodingKeys: String, CodingKey { case subtitle, error, deepLink, forceFullColor, accountScope }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            error = try c.decodeIfPresent(WidgetError.self, forKey: .error)
            deepLink = try c.decodeIfPresent(URL.self, forKey: .deepLink)
            forceFullColor = try c.decodeIfPresent(Bool.self, forKey: .forceFullColor) ?? true
            accountScope = try c.decodeIfPresent(String.self, forKey: .accountScope)
        }
    }

    /// Encoded as Swift encodes a case without values: {"fetchFailed":{}}.
    enum WidgetError: Codable, Equatable, Sendable {
        case noLogin
        case fetchFailed
        case albumNotFound
        case noAssetsAvailable
    }

    /// What the Flutter app left in the App Group's preferences for its widget, through
    /// home_widget's saveWidgetData. Signing out wrote empty strings rather than removing them.
    struct FlutterWidgetCredentials: Equatable, Sendable {
        static let serverURLKey = "widget_server_url"
        static let tokenKey = "widget_auth_token"
        /// A JSON object of header names and values, written only when there were headers.
        static let customHeadersKey = "widget_custom_headers"
        static let keys = [serverURLKey, tokenKey, customHeadersKey]

        let serverURL: String
        let token: String
        let customHeaders: [String: String]

        /// Read as the Flutter widget read them: both strings set and non-empty, and headers that
        /// fail to parse ignored.
        init?(defaults: UserDefaults) {
            guard let serverURL = defaults.string(forKey: Self.serverURLKey), let token = defaults.string(forKey: Self.tokenKey),
                  !serverURL.isEmpty, !token.isEmpty else { return nil }
            self.serverURL = serverURL; self.token = token
            let headers = defaults.string(forKey: Self.customHeadersKey) ?? ""
            customHeaders = headers.isEmpty ? [:] : (try? JSONDecoder().decode([String: String].self, from: Data(headers.utf8))) ?? [:]
        }
    }

    // MARK: Caches

    /// A grid thumbnail written by ThumbnailDiskStore, below Caches:
    /// IlyichThumbnails/<32 digits of sha256(cache scope)>/<stem's first 2>/<stem>.<16 digits of
    /// sha256(revision)>. The stem is the lowercased asset ID, or 32 digits of its SHA-256 when the
    /// ID holds anything but ASCII letters, digits and hyphens. The revision is the asset's media
    /// revision, else its thumbhash, else "unversioned". The file holds the server's bytes.
    static func thumbnailPath(scope: String, assetID: String, revision: String) -> String {
        let safe = !assetID.isEmpty && assetID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        let stem = safe ? assetID.lowercased() : String(sha256(assetID).prefix(32))
        return "IlyichThumbnails/\(sha256(scope).prefix(32))/\(stem.prefix(2))/\(stem).\(sha256(revision).prefix(16))"
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

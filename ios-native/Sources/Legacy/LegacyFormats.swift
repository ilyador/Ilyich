import CryptoKit
import Foundation

/// Verbatim mirrors of formats on disk, kept apart from the code that writes them: the thumbnail
/// store's v1 file layout. The legacy writers used JSONEncoder's defaults, so dates are seconds
/// since 2001 (deferredToDate) and URLs are absolute strings: decode with `Legacy.decoder()`.
/// Golden fixtures in Tests/Fixtures pin each format.
///
/// The backup, share manifest, places and fingerprint mirrors went with their importers and
/// readers in C8: nothing on the phone still holds those formats, and no build that writes them
/// will be installed again. The widget's snapshot mirrors, and the keys the Flutter app left for
/// its widget, went with the widget in A1.
enum Legacy {
    /// JSONDecoder's defaults, which every legacy writer's JSONEncoder matched.
    static func decoder() -> JSONDecoder { JSONDecoder() }

    // MARK: Thumbnails

    /// A grid thumbnail written by ThumbnailDiskStore, below Caches before T8 and below Application
    /// Support since, where T8 moved the same tree by renaming it:
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

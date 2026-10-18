import Foundation

enum MediaSize: String, Codable, Sendable { case thumbnail, preview, fullsize }

struct MediaCacheIdentity: Hashable, Sendable {
    let scope: String
    let resource: String
    let revision: String
    let size: String
    let pixelSize: Int

    init(scope: String, asset: Asset, size: MediaSize, pixelSize: Int, edited: Bool = true) {
        self.scope = scope; self.resource = "assets/\(asset.id)"
        self.revision = asset.cacheRevision
        self.size = size.rawValue + ":edited=\(edited)"
        self.pixelSize = max(1, pixelSize)
    }

    init(scope: String, person: Person, pixelSize: Int) {
        self.scope = scope; self.resource = "people/\(person.id)"
        self.revision = person.updatedAt.map { String($0.timeIntervalSince1970) } ?? "unversioned"
        self.size = "thumbnail"
        self.pixelSize = max(1, pixelSize)
    }

    var stableKey: String {
        // Length-prefix components so delimiters inside a revision cannot collide.
        let components = [scope, resource, revision, size, String(pixelSize)]
        return components.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

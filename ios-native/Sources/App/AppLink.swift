import Foundation

enum AppLink: Hashable, Sendable {
    case asset(String, albumID: String? = nil), album(String), person(String), memory(String?), activity(String), sharedFiles

    init?(url: URL, server: URL?) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil else { return nil }
        var route: String?
        var identifier: String?
        var albumID: String?
        if components.scheme == "immich" {
            route = components.host
            if route == "share", components.path.isEmpty || components.path == "/" {
                self = .sharedFiles
                return
            }
            identifier = components.queryItems?.first { $0.name == "id" }?.value
            if route == "memory", identifier == nil { self = .memory(nil); return }
            if route == "activity" { identifier = components.queryItems?.first { $0.name == "albumId" }?.value }
            if route == "asset" { albumID = components.queryItems?.first { $0.name == "albumId" }?.value }
        } else if let server, SameOriginRedirectDelegate.sameOrigin(url, server) {
            let prefix = server.deletingLastPathComponent().path.split(separator: "/").map(String.init)
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.starts(with: prefix) else { return nil }
            let path = Array(parts.dropFirst(prefix.count))
            if path.count == 4, path[0] == "albums", path[2] == "photos" {
                route = "photos"; identifier = path[3]; albumID = path[1]
            } else {
                guard path.count == 2 else { return nil }
                route = path[0]; identifier = path[1]
            }
        }
        guard let identifier, UUID(uuidString: identifier) != nil else { return nil }
        if let albumID, UUID(uuidString: albumID) == nil { return nil }
        switch route {
        case "asset", "photos": self = .asset(identifier, albumID: albumID)
        case "album", "albums": self = .album(identifier)
        case "person", "people": self = .person(identifier)
        case "memory": self = .memory(identifier)
        case "activity": self = .activity(identifier)
        default: return nil
        }
    }
}

import Foundation

enum AppLink: Hashable, Sendable {
    case asset(String), album(String), person(String)

    init?(url: URL, server: URL?) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil else { return nil }
        var route: String?
        var identifier: String?
        if components.scheme == "immich" {
            route = components.host
            identifier = components.queryItems?.first { $0.name == "id" }?.value
        } else if let server, SameOriginRedirectDelegate.sameOrigin(url, server) {
            let prefix = server.deletingLastPathComponent().path.split(separator: "/").map(String.init)
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.starts(with: prefix) else { return nil }
            let path = Array(parts.dropFirst(prefix.count))
            guard path.count == 2 else { return nil }
            route = path[0]; identifier = path[1]
        }
        guard let identifier, UUID(uuidString: identifier) != nil else { return nil }
        switch route {
        case "asset", "photos": self = .asset(identifier)
        case "album", "albums": self = .album(identifier)
        case "person", "people": self = .person(identifier)
        default: return nil
        }
    }
}

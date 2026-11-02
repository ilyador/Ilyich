import SwiftUI

/// The city each of the server's place names lies in, for the screens that name one photo's
/// place (REBUILD_ROADMAP.md L1): "Massarelos, Porto". The account's places keep it current.
@MainActor @Observable final class PlaceNaming {
    /// By "country|name", as PlaceHierarchy.citiesByServerName keys them.
    private(set) var cities: [String: String] = [:]
    @ObservationIgnored private var following: Task<Void, Never>?

    /// Follows the account's places: each build of the library's hierarchy names the cities again.
    func follow(_ directory: PlaceDirectory) {
        following?.cancel()
        following = Task { [weak self] in
            for await snapshot in await directory.places() {
                guard case .loaded(let hierarchy) = snapshot else { continue }
                self?.cities = hierarchy.citiesByServerName
            }
        }
    }

    /// The city `name` lies in when that is another place; nil for a name that is its own city,
    /// or one not looked up yet.
    func city(of name: String?, country: String?) -> String? {
        guard let name = PlaceGeometry.text(name), let city = cities["\(country ?? "")|\(name)"], city != name else { return nil }
        return city
    }

    /// One photo's place: its name with its city, else its name, else its country.
    func place(name: String?, country: String?) -> String? {
        guard let name = PlaceGeometry.text(name) else { return PlaceGeometry.text(country) }
        if let city = city(of: name, country: country) { return "\(name), \(city)" }
        return name
    }
}

extension EnvironmentValues {
    /// The signed-in account's place naming. Nil while nobody is signed in.
    @Entry var placeNaming: PlaceNaming? = nil
}

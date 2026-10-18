import Foundation

struct SearchSuggestionRequest: Hashable, Sendable {
    enum Kind: String, Sendable { case country, state, city, make = "camera-make", model = "camera-model" }
    let kind: Kind
    var country: String? = nil
    var state: String? = nil
    var make: String? = nil
    var query: [URLQueryItem] {
        var result = [URLQueryItem(name: "type", value: kind.rawValue)]
        if [.state, .city].contains(kind), let country, !country.isEmpty { result.append(.init(name: "country", value: country)) }
        if kind == .city, let state, !state.isEmpty { result.append(.init(name: "state", value: state)) }
        if kind == .model, let make, !make.isEmpty { result.append(.init(name: "make", value: make)) }
        return result
    }
}

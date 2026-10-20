import Foundation

/// The order the owner gave people and albums on the shelves. The server keeps no such order, so
/// it lives on this phone, per server and account. People and albums it does not know yet follow
/// the ordered ones in the server's order.
struct ShelfOrder {
    enum Kind: String { case people, albums }
    let scope: String
    var defaults: UserDefaults = .standard

    func ids(_ kind: Kind) -> [String] { defaults.stringArray(forKey: key(kind)) ?? [] }
    func save(_ ids: [String], for kind: Kind) { defaults.set(ids, forKey: key(kind)) }

    private func key(_ kind: Kind) -> String { "shelfOrder.\(kind.rawValue).\(scope)" }

    static func apply<Item>(_ order: [String], to items: [Item], id: (Item) -> String) -> [Item] {
        guard !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { left, right in
            switch (rank[id(left.element)], rank[id(right.element)]) {
            case let (a?, b?): a < b
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): left.offset < right.offset
            }
        }.map(\.element)
    }
}

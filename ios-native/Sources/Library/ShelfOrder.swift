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

    /// `ids` with the row at `from` of those `listed` moved to `to` among them, as a drag or Move up
    /// and Move down set it. The shelves may list only some rows, those in a stack of filters'
    /// photos (N6), in the order of `ids`: the row goes just before the row it now precedes, or just
    /// after the one it now follows, so the rows not listed keep their places. Nil when nothing moves.
    static func moving(_ from: Int, to: Int, among listed: [String], in ids: [String]) -> [String]? {
        guard from != to, listed.indices.contains(from), listed.indices.contains(to) else { return nil }
        let moved = listed[from], neighbor = listed[to]
        var ids = ids
        guard let source = ids.firstIndex(of: moved) else { return nil }
        ids.remove(at: source)
        guard let target = ids.firstIndex(of: neighbor) else { return nil }
        ids.insert(moved, at: to < from ? target : target + 1)
        return ids
    }

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

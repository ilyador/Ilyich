import CoreGraphics
import Foundation

/// Which places the Earth shows at a zoom (REBUILD_ROADMAP.md L1): cities, and the closer the
/// camera comes, the neighborhoods they open into, as the phone's own Photos opens its places.
/// Countries and continents are for the list and for search (the owner's choice). What is shown
/// depends only on the zoom, so turning the Earth never changes it, and a place opens a little
/// later than it closes, so pinching across the point doesn't make it flicker. Pure.
enum PlaceCut {
    /// A place opens into its parts once they stand this far apart on screen: a pin's width.
    static let pinPoints = 64.0
    static let opensAt = 1.15
    static let closesAt = 0.85

    /// A city also opens once the view is shorter than one, about 16 km, whatever its parts'
    /// distance apart. Its parts may then be too close to each pin a label; the biggest keeps its own.
    static let citySpan = 16_000 / PlaceGeometry.earthRadius

    /// The places shown, and which places are open, for the next cut to hold them open a little
    /// longer. `viewPoints` is the view's height. `forced` places and those above them are open
    /// whatever the zoom: a photo's own place is shown when the Earth turns to it.
    static func shown(_ hierarchy: PlaceHierarchy, radiansPerPoint: Double, viewPoints: Double = 800, open: Set<String>, forced: Set<String> = []) -> (nodes: [PlaceHierarchy.Node], open: Set<String>) {
        var held = Set<String>()
        for id in forced { for node in hierarchy.lineage(of: id).dropFirst() { held.insert(node.id) } }
        var shown: [PlaceHierarchy.Node] = []
        var opened = Set<String>()
        var pending = hierarchy.cities
        while let node = pending.popLast() {
            let opens: Bool
            if node.childIDs.isEmpty { opens = false }
            else if held.contains(node.id) { opens = true }
            else {
                let hysteresis = open.contains(node.id) ? closesAt : opensAt
                let apart = node.split / max(radiansPerPoint, 1e-12)
                opens = apart > pinPoints * hysteresis || (node.level == .city && radiansPerPoint * viewPoints < citySpan / hysteresis)
            }
            if opens {
                opened.insert(node.id)
                pending += hierarchy.children(of: node)
            } else {
                shown.append(node)
            }
        }
        return (shown, opened)
    }
}

/// Where each pin's label goes, beside its round thumbnail, which sits on the place itself. Pins
/// placed last time go first, then the rest biggest first, so a pin at the edge of the room
/// doesn't trade places with another every frame; a label keeps the side it had while it fits,
/// else takes the first side that covers no other pin's place, else any side that fits, and a pin
/// whose label fits nowhere keeps its thumbnail alone. Pure.
enum PinPlacement {
    enum Side: CaseIterable, Sendable {
        case right, left, below, above
    }

    struct Candidate {
        let id: String
        let point: CGPoint
        let label: CGSize
    }

    struct Placed: Equatable {
        let id: String
        let frame: CGRect
        /// Nil for a thumbnail without its label.
        let side: Side?
    }

    /// The round thumbnail's edge, in points.
    static let thumbnail = 36.0
    /// How far the label's capsule tucks under the thumbnail.
    static let overlap = 4.0
    static let margin = 6.0
    /// The room kept between pins.
    static let spacing = CGSize(width: 8, height: 10)

    /// A pin's frame for a label on `side` of a thumbnail at `point`.
    static func frame(at point: CGPoint, label: CGSize, side: Side?) -> CGRect {
        let edge = thumbnail
        guard let side else { return CGRect(x: point.x - edge / 2, y: point.y - edge / 2, width: edge, height: edge) }
        switch side {
        case .right:
            let height = max(edge, label.height)
            return CGRect(x: point.x - edge / 2, y: point.y - height / 2, width: edge + label.width - overlap, height: height)
        case .left:
            let height = max(edge, label.height)
            return CGRect(x: point.x + edge / 2 - (edge + label.width - overlap), y: point.y - height / 2, width: edge + label.width - overlap, height: height)
        case .below:
            let width = max(edge, label.width)
            return CGRect(x: point.x - width / 2, y: point.y - edge / 2, width: width, height: edge + label.height - overlap)
        case .above:
            let width = max(edge, label.width)
            return CGRect(x: point.x - width / 2, y: point.y + edge / 2 - (edge + label.height - overlap), width: width, height: edge + label.height - overlap)
        }
    }

    /// The thumbnail's frame inside a pin's frame.
    static func thumbnailFrame(in frame: CGRect, side: Side?) -> CGRect {
        let edge = thumbnail
        switch side {
        case nil, .right?: return CGRect(x: frame.minX, y: frame.midY - edge / 2, width: edge, height: edge)
        case .left?: return CGRect(x: frame.maxX - edge, y: frame.midY - edge / 2, width: edge, height: edge)
        case .below?: return CGRect(x: frame.midX - edge / 2, y: frame.minY, width: edge, height: edge)
        case .above?: return CGRect(x: frame.midX - edge / 2, y: frame.maxY - edge, width: edge, height: edge)
        }
    }

    /// The label's frame inside a pin's frame; nil without a label.
    static func labelFrame(in frame: CGRect, label: CGSize, side: Side?) -> CGRect? {
        let edge = thumbnail
        switch side {
        case nil: return nil
        case .right?: return CGRect(x: frame.minX + edge - overlap, y: frame.midY - label.height / 2, width: label.width, height: label.height)
        case .left?: return CGRect(x: frame.minX, y: frame.midY - label.height / 2, width: label.width, height: label.height)
        case .below?: return CGRect(x: frame.midX - label.width / 2, y: frame.minY + edge - overlap, width: label.width, height: label.height)
        case .above?: return CGRect(x: frame.midX - label.width / 2, y: frame.minY, width: label.width, height: label.height)
        }
    }

    /// Places `candidates`, in order, inside `bounds`. `sides` are the sides pins had last time
    /// and `before` the pins placed last time.
    static func place(_ candidates: [Candidate], in bounds: CGRect, sides: [String: Side], before: Set<String> = [], limit: Int) -> [Placed] {
        var taken: [CGRect] = []
        var placed: [Placed] = []
        let inside = bounds.insetBy(dx: margin, dy: margin)
        func fits(_ frame: CGRect) -> Bool {
            inside.contains(frame) && !taken.contains { $0.insetBy(dx: -spacing.width, dy: -spacing.height).intersects(frame) }
        }
        let points = candidates.map { ($0.id, $0.point) }
        let ordered = candidates.filter { before.contains($0.id) } + candidates.filter { !before.contains($0.id) }
        for candidate in ordered where placed.count < limit {
            var chosen: (CGRect, Side?)?
            if let last = sides[candidate.id] {
                let kept = frame(at: candidate.point, label: candidate.label, side: last)
                if fits(kept) { chosen = (kept, last) }
            }
            if chosen == nil {
                let frames = Side.allCases.map { ($0, frame(at: candidate.point, label: candidate.label, side: $0)) }.filter { fits($0.1) }
                chosen = frames.first { frame in !points.contains { $0.0 != candidate.id && frame.1.contains($0.1) } }.map { ($0.1, Optional($0.0)) }
                if chosen == nil, let first = frames.first { chosen = (first.1, first.0) }
            }
            if chosen == nil {
                let alone = frame(at: candidate.point, label: candidate.label, side: nil)
                if fits(alone) { chosen = (alone, nil) }
            }
            guard let (frame, side) = chosen else { continue }
            taken.append(frame)
            placed.append(Placed(id: candidate.id, frame: frame, side: side))
        }
        return placed
    }
}

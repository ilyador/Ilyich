import UIKit

/// One finger dragged across the grid while selecting, as in Photos: every photo in reading order
/// between the photo the drag started on and the one under the finger takes the drag's state.
/// Pulling back shrinks the range, and the photos it leaves return to what they were before.
///
/// The work for each move is the photos that entered or left the range, never the library.
struct GridDragSelection {
    /// What a move asks of the selection.
    struct Change: Equatable {
        var select: [IndexPath] = []
        var deselect: [IndexPath] = []
        var isEmpty: Bool { select.isEmpty && deselect.isEmpty }
    }

    /// Where the drag started.
    let anchor: IndexPath
    /// The drag selects, or it deselects because it started on a selected photo.
    let selects: Bool
    /// The photo under the finger, or nil before the first move.
    private(set) var current: IndexPath?
    /// The photos this drag changed; leaving the range puts them back.
    private(set) var changed: Set<IndexPath> = []
    /// Photos in the range whose month was not loaded when they entered it, by section. Each step
    /// tries them again, so a range never covers only the loaded photos.
    private(set) var pending: [Int: Set<Int>] = [:]

    init(anchor: IndexPath, selects: Bool) {
        self.anchor = anchor
        self.selects = selects
    }

    /// The range now runs from the anchor to `target`. `counts` holds each section's photo count;
    /// `isSelected` answers for a loaded photo and is nil for one not loaded yet, which waits in
    /// `pending` until its month loads.
    mutating func move(to target: IndexPath, counts: [Int], isSelected: (IndexPath) -> Bool?) -> Change {
        guard target != current else { return retry(isSelected: isSelected) }
        let new = (low: min(anchor, target), high: max(anchor, target))
        var leaving: [IndexPath] = []
        var entering: [IndexPath] = []
        if let current {
            let old = (low: min(anchor, current), high: max(anchor, current))
            // Both ranges hold the anchor, so they differ only at their ends.
            if old.low < new.low { Self.walk(old.low, new.low, openHigh: true, counts: counts) { leaving.append($0) } }
            if old.high > new.high { Self.walk(new.high, old.high, openLow: true, counts: counts) { leaving.append($0) } }
            if new.low < old.low { Self.walk(new.low, old.low, openHigh: true, counts: counts) { entering.append($0) } }
            if new.high > old.high { Self.walk(old.high, new.high, openLow: true, counts: counts) { entering.append($0) } }
        } else {
            Self.walk(new.low, new.high, counts: counts) { entering.append($0) }
        }
        current = target
        var change = Change()
        for index in leaving {
            if pending[index.section]?.remove(index.item) != nil {
                if pending[index.section]?.isEmpty == true { pending[index.section] = nil }
            } else if changed.remove(index) != nil {
                if selects { change.deselect.append(index) } else { change.select.append(index) }
            }
        }
        for index in entering {
            guard let selected = isSelected(index) else { pending[index.section, default: []].insert(index.item); continue }
            take(index, selected: selected, into: &change)
        }
        let later = retry(isSelected: isSelected)
        change.select += later.select
        change.deselect += later.deselect
        return change
    }

    /// Settles the photos in the range whose month has loaded since they entered it. A month loads
    /// whole, so one photo answers for its section and an unloaded month costs one question.
    mutating func retry(isSelected: (IndexPath) -> Bool?) -> Change {
        var change = Change()
        for (section, items) in pending {
            guard let probe = items.first, isSelected(IndexPath(item: probe, section: section)) != nil else { continue }
            var left: Set<Int> = []
            for item in items.sorted() {
                let index = IndexPath(item: item, section: section)
                guard let selected = isSelected(index) else { left.insert(item); continue }
                take(index, selected: selected, into: &change)
            }
            pending[section] = left.isEmpty ? nil : left
        }
        return change
    }

    private mutating func take(_ index: IndexPath, selected: Bool, into change: inout Change) {
        guard selected != selects else { return }
        changed.insert(index)
        if selects { change.select.append(index) } else { change.deselect.append(index) }
    }

    /// Calls `body` for each photo from `low` to `high` in reading order, leaving out either end
    /// when asked.
    static func walk(_ low: IndexPath, _ high: IndexPath, openLow: Bool = false, openHigh: Bool = false,
                     counts: [Int], _ body: (IndexPath) -> Void) {
        let lastSection = min(high.section, counts.count - 1)
        guard low <= high, low.section >= 0, low.section <= lastSection else { return }
        for section in low.section...lastSection {
            let first = section == low.section ? low.item : 0
            let last = section == high.section ? min(high.item, counts[section] - 1) : counts[section] - 1
            guard first <= last else { continue }
            for item in first...last {
                let index = IndexPath(item: item, section: section)
                if openLow && index == low || openHigh && index == high { continue }
                body(index)
            }
        }
    }
}

/// Drives a `GridDragSelection` from a gesture on the grid, and scrolls the grid while the finger
/// holds near its top or bottom edge, extending the range as photos come into view.
@MainActor final class GridDragSelector {
    /// How far from the grid's visible top or bottom edge holding the finger scrolls it.
    nonisolated static let edgeZone: CGFloat = 70
    /// Points a second at the very edge.
    nonisolated static let maximumSpeed: CGFloat = 1_400

    weak var collection: UICollectionView?
    /// Each section's photo count.
    var counts: () -> [Int] = { [] }
    /// Whether a loaded photo is selected; nil when it is not loaded.
    var isSelected: (IndexPath) -> Bool? = { _ in nil }
    /// Applies one move's change to the selection.
    var apply: (GridDragSelection.Change) -> Void = { _ in }

    private var session: GridDragSelection?
    private weak var gesture: UIGestureRecognizer?
    private let clock = LibraryShelfFrameClock()

    var isActive: Bool { session != nil }

    /// Starts a drag on `anchor`; one from a selected photo deselects.
    func begin(at anchor: IndexPath, gesture: UIGestureRecognizer) {
        end()
        guard let state = isSelected(anchor) else { return }
        var session = GridDragSelection(anchor: anchor, selects: !state)
        let first = session.move(to: anchor, counts: counts(), isSelected: isSelected)
        self.session = session
        self.gesture = gesture
        if !first.isEmpty { apply(first); Haptics.selectionChanged() }
        update()
    }

    /// Follows the finger.
    func update() {
        guard let collection, let gesture, session != nil else { return }
        let point = gesture.location(in: collection)
        if let index = Self.photo(near: point, in: collection) { move(to: index) }
        if Self.edgeVelocity(at: point, in: collection) != 0 {
            clock.run { [weak self] seconds in self?.scrollFrame(seconds) ?? false }
        }
    }

    /// Settles photos in the range whose month has loaded, while the finger holds still.
    func refresh() {
        guard var session else { return }
        let change = session.retry(isSelected: isSelected)
        self.session = session
        if !change.isEmpty { apply(change) }
    }

    func end() {
        clock.stop()
        session = nil
        gesture = nil
    }

    private func move(to index: IndexPath) {
        guard var session else { return }
        let change = session.move(to: index, counts: counts(), isSelected: isSelected)
        self.session = session
        guard !change.isEmpty else { return }
        apply(change)
        Haptics.selectionChanged()
    }

    /// One frame of scrolling at the edge; false once the finger has left it or the grid can go no further.
    private func scrollFrame(_ seconds: CGFloat) -> Bool {
        guard let collection, let gesture, session != nil else { return false }
        let velocity = Self.edgeVelocity(at: gesture.location(in: collection), in: collection)
        guard velocity != 0 else { return false }
        let top = -collection.adjustedContentInset.top
        let bottom = max(top, collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.height)
        let y = min(bottom, max(top, collection.contentOffset.y + velocity * seconds))
        guard abs(y - collection.contentOffset.y) > 0.01 else { return false }
        collection.contentOffset.y = y
        let point = gesture.location(in: collection)
        if let index = Self.photo(near: point, in: collection) { move(to: index) }
        return true
    }

    /// Faster the deeper the finger is in the zone at the grid's visible top or bottom.
    static func edgeVelocity(at point: CGPoint, in collection: UIScrollView) -> CGFloat {
        let top = collection.contentOffset.y + collection.adjustedContentInset.top
        let bottom = collection.contentOffset.y + collection.bounds.height - collection.adjustedContentInset.bottom
        return edgeVelocity(fingerY: point.y, visibleTop: top, visibleBottom: bottom)
    }

    nonisolated static func edgeVelocity(fingerY y: CGFloat, visibleTop top: CGFloat, visibleBottom bottom: CGFloat) -> CGFloat {
        guard bottom - top > edgeZone * 2 else { return 0 }
        if y < top + edgeZone {
            let depth = min(1, (top + edgeZone - y) / edgeZone)
            return -maximumSpeed * depth * depth
        }
        if y > bottom - edgeZone {
            let depth = min(1, (y - (bottom - edgeZone)) / edgeZone)
            return maximumSpeed * depth * depth
        }
        return 0
    }

    /// The photo under the point, or in a gap or beside a day heading the nearest one in its rows.
    static func photo(near point: CGPoint, in collection: UICollectionView) -> IndexPath? {
        if let index = collection.indexPathForItem(at: point) { return index }
        let side = (collection.collectionViewLayout as? VirtualPhotoLayout)?.itemSide ?? 80
        let x = min(max(point.x, 0), max(0, collection.bounds.width - 1))
        let rect = CGRect(x: 0, y: point.y - side, width: collection.bounds.width, height: side * 2)
        return (collection.collectionViewLayout.layoutAttributesForElements(in: rect) ?? [])
            .filter { $0.representedElementCategory == .cell }
            .min { distance($0.frame, x, point.y) < distance($1.frame, x, point.y) }?.indexPath
    }

    private static func distance(_ frame: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let dx = max(frame.minX - x, 0, x - frame.maxX)
        let dy = max(frame.minY - y, 0, y - frame.maxY)
        return dy * 10_000 + dx
    }
}

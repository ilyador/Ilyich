import UIKit
import Observation

/// Where the grid's first photo on screen is, as the grid last reported it. The month heading,
/// the rail's month and month selection read it.
@MainActor @Observable final class TimelinePosition {
    var section = 0
    var item = 0
}

/// The grid's scroll position, and moving it directly (REBUILD_ROADMAP.md T4, moved out of
/// LibraryStore). The rail scrubs through it at the finger's pace, so scrubbing is one continuous
/// movement instead of jumps from row to row through view updates; the rail marks the months
/// where the grid's own layout puts them; and the viewer finds the cell it zooms back into.
@MainActor final class GridScrollController {
    weak var collection: UICollectionView?

    private var range: ClosedRange<CGFloat>? {
        guard let collection else { return nil }
        let top = -collection.adjustedContentInset.top
        let bottom = collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.height
        return top...max(top, bottom)
    }

    /// How far the timeline scrolls, in points.
    var scrollableHeight: CGFloat? { range.map { $0.upperBound - $0.lowerBound } }

    /// How far down the timeline the grid is, from 0 to 1.
    var fraction: CGFloat? {
        guard let collection, let range, range.upperBound > range.lowerBound else { return nil }
        return min(1, max(0, (collection.contentOffset.y - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    /// The content offset `fraction` of the way down the timeline.
    func offset(atFraction fraction: CGFloat) -> CGFloat? {
        guard let range else { return nil }
        return range.lowerBound + min(1, max(0, fraction)) * (range.upperBound - range.lowerBound)
    }

    func scroll(toFraction fraction: CGFloat) {
        guard let collection, let y = offset(atFraction: fraction) else { return }
        collection.setContentOffset(CGPoint(x: 0, y: y.rounded(.toNearestOrEven)), animated: false)
    }

    /// Where a month starts on the rail, from the grid's own layout.
    func fraction(ofSection section: Int) -> CGFloat? {
        guard let range, range.upperBound > range.lowerBound,
              let top = (collection?.collectionViewLayout as? VirtualPhotoLayout)?.top(ofSection: section) else { return nil }
        return min(1, max(0, (top - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    func scroll(toSection section: Int, animated: Bool) {
        guard let collection, let range, let top = (collection.collectionViewLayout as? VirtualPhotoLayout)?.top(ofSection: section) else { return }
        collection.setContentOffset(CGPoint(x: 0, y: min(range.upperBound, max(range.lowerBound, top - collection.adjustedContentInset.top))), animated: animated)
    }
}

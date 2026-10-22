import UIKit

/// Puts server photos into one grid's cells and tells the thumbnail scheduler what the grid
/// wants. Binding is synchronous and never loads: the exact size from memory, else this photo at
/// another size from memory, else its sketch, else the sketch's average colour while the sketch
/// decodes off the main thread. Whatever the scheduler delivers later is drawn into the cells that
/// still show that photo, with a crossfade only over a placeholder and never under Reduce Motion.
@MainActor final class ThumbnailBinder {
    /// What a cell shows of its server photo.
    enum Stage: Equatable {
        case empty, color, sketch
        /// The photo could not be loaded; a symbol says so.
        case failed
        /// This photo, decoded for another cell size.
        case other
        case exact

        /// Nothing of the photo itself yet.
        var isPlaceholder: Bool { self == .empty || self == .color || self == .sketch || self == .failed }
    }

    /// The server photo a cell is bound to.
    struct Binding: Equatable {
        let assetID: String
        let revision: String
        let shortSide: Int
        let thumbhash: String?
        let name: String
        var stage: Stage

        var key: String { assetID + "|" + revision }
    }

    let pipeline: MediaPipeline
    private nonisolated let scheduler: ThumbnailScheduler
    private nonisolated let source = ThumbnailScheduler.Source()
    private nonisolated(unsafe) var listener: UUID?
    /// Every cell this grid has bound, so deliveries find theirs.
    private let cells = NSHashTable<PhotoCell>.weakObjects()
    /// For tests; UIKit's setting otherwise.
    var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    /// Sends the grid's demand again, as after the scheduler dropped everything it was asked for.
    var needsDemand: (() -> Void)?

    init(pipeline: MediaPipeline) {
        self.pipeline = pipeline
        scheduler = pipeline.scheduler
        listener = scheduler.addListener({ [weak self] batch in self?.deliver(batch) },
                                         reset: { [weak self] in self?.needsDemand?() })
    }

    deinit {
        if let listener { scheduler.removeListener(listener) }
        scheduler.withdraw(source)
    }

    /// Whether drawing a delivered thumbnail over `stage` fades: only over a placeholder, and
    /// never under Reduce Motion.
    nonisolated static func crossfades(over stage: Stage, reduceMotion: Bool) -> Bool {
        stage.isPlaceholder && !reduceMotion
    }

    // MARK: Binding

    /// Shows `asset` in `cell` for a cell of `shortSide` pixels. Returns whether the cell still
    /// needs its thumbnail, so the grid's demand should be sent again.
    @discardableResult
    func bind(_ cell: PhotoCell, to asset: Asset, shortSide: Int) -> Bool {
        cells.add(cell)
        let previous = cell.binding
        let samePhoto = previous.map { $0.assetID == asset.id && $0.revision == asset.cacheRevision } ?? false
        if samePhoto, let previous, previous.shortSide == shortSide { return previous.stage != .exact }
        var binding = Binding(assetID: asset.id, revision: asset.cacheRevision, shortSide: shortSide, thumbhash: asset.thumbhash,
                              name: asset.displayName, stage: .empty)
        if !samePhoto { cell.displayProbe.bind() }
        // A thumbnail in memory draws in this frame instead of after an empty one.
        if let exact = pipeline.cachedThumbnail(assetID: asset.id, revision: asset.cacheRevision, shortSide: shortSide) {
            binding.stage = .exact
            cell.binding = binding
            cell.draw(exact.cgImage, thumbnail: true, crossfade: false)
            if !samePhoto { cell.displayProbe.displayed(.memory) }
            return false
        }
        // A density change keeps the photo it shows while the sharper copy comes.
        if samePhoto, let previous, previous.stage == .exact || previous.stage == .other {
            binding.stage = .other
            cell.binding = binding
            return true
        }
        // Never an empty brick: this photo at another size, its sketch, or its sketch's colour.
        if let other = pipeline.latestImage(assetID: asset.id, size: .thumbnail, revision: asset.cacheRevision) {
            binding.stage = .other
            cell.binding = binding
            cell.draw(other.cgImage, thumbnail: true, crossfade: false)
            cell.displayProbe.displayed(.memoryOther)
            return true
        }
        guard let hash = asset.thumbhash, !hash.isEmpty else {
            cell.binding = binding
            cell.draw(nil, thumbnail: false, crossfade: false)
            cell.displayProbe.placeholder(.empty)
            return true
        }
        if let sketch = ThumbHashSketches.shared.cached(hash) {
            binding.stage = .sketch
            cell.binding = binding
            cell.draw(sketch, thumbnail: false, crossfade: false)
            cell.displayProbe.placeholder(.sketch)
            return true
        }
        binding.stage = .color
        cell.binding = binding
        cell.draw(nil, thumbnail: false, crossfade: false, color: ThumbHash.averageColor(hash))
        cell.displayProbe.placeholder(.color)
        let key = binding.key
        Task { [weak cell] in
            guard let sketch = await ThumbHashSketches.shared.sketch(hash), let cell,
                  let current = cell.binding, current.key == key, current.stage == .color else { return }
            cell.binding?.stage = .sketch
            cell.draw(sketch, thumbnail: false, crossfade: false)
        }
        return true
    }

    /// The cell shows something else now: a photo only on this phone, or nothing.
    func unbind(_ cell: PhotoCell) {
        cell.binding = nil
    }

    // MARK: Demand

    /// What the grid wants: the cells on screen in `viewport` that lack their exact thumbnail,
    /// nearest the middle first, then the photos about to scroll in, at `shortSide` pixels.
    /// `motion` says whether the network may be used for them.
    func submit(viewport: CGRect, ahead: [(asset: Asset, distance: CGFloat)], shortSide: Int, motion: Motion) {
        let middle = CGPoint(x: viewport.midX, y: viewport.midY)
        var onScreen: [(binding: Binding, distance: CGFloat)] = []
        var shown = Set<String>()
        // Cells waiting in UIKit's reuse pool keep their last photo; only those on screen count.
        for cell in cells.allObjects where cell.isOnScreen {
            guard let binding = cell.binding else { continue }
            let frame = cell.frame
            guard frame.intersects(viewport) else { continue }
            shown.insert(binding.assetID)
            guard binding.stage != .exact else { continue }
            onScreen.append((binding, hypot(frame.midX - middle.x, frame.midY - middle.y)))
        }
        onScreen.sort { $0.distance < $1.distance }
        var items: [ViewportDemand.Item] = []
        items.reserveCapacity(onScreen.count + ahead.count)
        for (rank, entry) in onScreen.enumerated() {
            let binding = entry.binding
            items.append(.init(request: ThumbnailRequest(key: .server(assetID: binding.assetID, revision: binding.revision),
                                                         thumbhash: binding.thumbhash, shortSide: binding.shortSide),
                               band: .visible, rank: rank))
        }
        for (rank, entry) in ahead.sorted(by: { $0.distance < $1.distance }).prefix(Self.aheadLimit).enumerated()
            where !shown.contains(entry.asset.id) && entry.asset.visibility != .locked {
            items.append(.init(request: ThumbnailRequest(key: .server(assetID: entry.asset.id, revision: entry.asset.cacheRevision),
                                                         thumbhash: entry.asset.thumbhash, shortSide: shortSide),
                               band: .ahead, rank: rank))
        }
        scheduler.submit(ViewportDemand(generation: pipeline.mediaToken(), items: items, motion: motion), from: source)
    }

    /// Photos about to scroll in; past this many the farthest have usually scrolled past already.
    static let aheadLimit = 120

    // MARK: Deliveries

    private func deliver(_ batch: [ThumbnailDelivery]) {
        var arrived: [String: ThumbnailDelivery] = [:]
        for delivery in batch { arrived[delivery.assetID + "|" + delivery.revision] = delivery }
        let reduceMotion = reduceMotion()
        for cell in cells.allObjects {
            guard let binding = cell.binding, binding.stage != .exact, let delivery = arrived[binding.key] else { continue }
            if let image = delivery.image {
                let exact = pipeline.cachedThumbnail(assetID: binding.assetID, revision: binding.revision, shortSide: binding.shortSide)
                guard exact != nil || binding.stage.isPlaceholder else { continue }
                cell.binding?.stage = exact != nil ? .exact : .other
                cell.draw((exact ?? image).cgImage, thumbnail: true,
                          crossfade: Self.crossfades(over: binding.stage, reduceMotion: reduceMotion))
                cell.displayProbe.displayed(delivery.fromNetwork ? .network : .disk)
            } else if binding.stage.isPlaceholder, binding.stage != .failed {
                cell.binding?.stage = .failed
                cell.displayProbe.failed()
                cell.showUnavailable(name: binding.name)
            }
        }
    }
}

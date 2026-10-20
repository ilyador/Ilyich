import SwiftUI
import UIKit
import Observation

private final class ChromeAwareCollectionView: UICollectionView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) && bounds.inset(by: contentInset).contains(point)
    }
}

struct PhotoGrid: UIViewRepresentable {
    let store: LibraryStore
    let pipeline: MediaPipeline
    let columns: Int
    var showsDayHeaders = false
    let topInset: CGFloat
    let bottomInset: CGFloat
    var onDensityChange: ((Int) -> Void)? = nil
    var onOpenLocal: ((LocalPhoto) -> Void)? = nil
    let onOpen: (Asset) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UICollectionView {
        let layout = VirtualPhotoLayout()
        layout.columns = columns
        layout.showsDayHeaders = showsDayHeaders
        let view = ChromeAwareCollectionView(frame: .zero, collectionViewLayout: layout)
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (collection: UICollectionView, _: UITraitCollection) in
            collection.collectionViewLayout.invalidateLayout()
        }
        view.backgroundColor = .black
        view.contentInsetAdjustmentBehavior = .never
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = true
        view.accessibilityIdentifier = "library.grid"
        view.register(PhotoCell.self, forCellWithReuseIdentifier: "photo")
        view.register(DayHeaderView.self, forSupplementaryViewOfKind: VirtualPhotoLayout.dayHeaderKind, withReuseIdentifier: "day-header")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.prefetchDataSource = context.coordinator
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
        view.refreshControl = refresh
        context.coordinator.collection = view
        store.scroller.collection = view
        let selection = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectByDragging(_:)))
        selection.minimumPressDuration = 0.35
        view.addGestureRecognizer(selection)
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.changeDensity(_:))))
        // Two fingers always pinch; scrolling takes one.
        view.panGestureRecognizer.maximumNumberOfTouches = 1
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.isScrollEnabled = !store.isReplacingFeed
        view.isUserInteractionEnabled = !store.isReplacingFeed
        let sections = store.sections
        let reset = coordinator.resetID != store.resetID
        let dayGroups = showsDayHeaders ? sections.indices.map { store.dayGroups(section: $0) } : Array(repeating: [], count: sections.count)
        let groupingChanged = coordinator.dayGroups != dayGroups || coordinator.showsDayHeaders != showsDayHeaders
        let wasAtTop = view.contentOffset.y <= -view.contentInset.top + 1
        let topInsetChanged = abs(view.contentInset.top - topInset) > 0.5
        let anchor: (IndexPath, CGFloat)? = groupingChanged && !reset ? coordinator.firstVisiblePhoto().flatMap { index in
            guard let attributes = view.layoutAttributesForItem(at: index) else { return nil }
            return (index, view.contentOffset.y - attributes.frame.minY)
        } : nil
        if let layout = view.collectionViewLayout as? VirtualPhotoLayout {
            layout.showsDayHeaders = showsDayHeaders
            if groupingChanged { layout.dayGroups = dayGroups }
            if layout.columns != columns {
                let anchor = coordinator.firstVisiblePhoto()
                layout.columns = columns; layout.invalidateLayout(); view.layoutIfNeeded()
                if let anchor, let frame = layout.layoutAttributesForItem(at: anchor)?.frame {
                    view.setContentOffset(CGPoint(x: 0, y: frame.minY - topInset), animated: false)
                }
            }
        }
        view.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        let needsReload = coordinator.sections != sections || reset
        coordinator.dayGroups = dayGroups
        coordinator.showsDayHeaders = showsDayHeaders
        if needsReload {
            coordinator.sections = sections; coordinator.resetID = store.resetID
            view.reloadData()
            if reset {
                view.layoutIfNeeded()
                if let position = store.restorePosition, let index = store.restoredIndex(for: position),
                   let attributes = view.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: index.item, section: index.section)) {
                    view.setContentOffset(CGPoint(x: 0, y: attributes.frame.minY + position.offset), animated: false)
                } else { view.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false) }
            }
        }
        if groupingChanged && !reset {
            // Loading a neighboring month changes header geometry, not item identity.
            // Invalidating the layout keeps existing photo cells and their image tasks alive.
            view.layoutIfNeeded()
            if wasAtTop {
                view.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
            } else if let (index, offset) = anchor,
                      let frame = view.collectionViewLayout.layoutAttributesForItem(at: index)?.frame {
                view.setContentOffset(CGPoint(x: 0, y: frame.minY + offset), animated: false)
            }
            for index in view.indexPathsForVisibleSupplementaryElements(ofKind: VirtualPhotoLayout.dayHeaderKind) {
                guard let header = view.supplementaryView(forElementKind: VirtualPhotoLayout.dayHeaderKind, at: index) as? DayHeaderView else { continue }
                coordinator.configure(header, at: index)
            }
        }
        if topInsetChanged && wasAtTop && !reset {
            // Growing chrome (Dynamic Type or a filter chip) must not cover the
            // first day header. Scrolled photo positions stay unchanged.
            view.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
        }
        if !needsReload && (groupingChanged || coordinator.revision != store.revision || coordinator.selection != store.selected || coordinator.selecting != store.isSelecting) {
            for cell in view.visibleCells {
                guard let cell = cell as? PhotoCell, let index = view.indexPath(for: cell) else { continue }
                coordinator.configure(cell, at: index)
            }
        }
        coordinator.revision = store.revision; coordinator.selection = store.selected; coordinator.selecting = store.isSelecting
        if let request = store.scrollRequest, request.id != coordinator.lastScrollRequest,
           let index = store.restoredIndex(for: request.position) {
            coordinator.lastScrollRequest = request.id
            let resetID = store.resetID
            view.scrollToItem(at: IndexPath(item: index.item, section: index.section), at: .top, animated: false)
            coordinator.publishPositionAfterLayout(requestID: request.id, resetID: resetID)
        }
    }

    @MainActor final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        var parent: PhotoGrid
        weak var collection: UICollectionView?
        var sections: [LibrarySection] = []
        var dayGroups: [[TimelineDayGroup]] = []
        var resetID: UUID?
        var revision = -1
        var selection: Set<String> = []
        var selecting = false
        var showsDayHeaders = false
        var lastScrollRequest: UUID?
        /// Downloads wait while photos fly past faster than they could arrive, or while the rail
        /// scrubs. Memory and disk still fill cells; the visible ones download when the grid slows.
        private(set) var allowsNetwork = true
        private var lastScroll: (offset: CGFloat, time: CFTimeInterval)?
        /// Any stop counts as rest, however the grid moved: a drag, a fling, the rail or a jump.
        private var rest: DispatchWorkItem?
        init(_ parent: PhotoGrid) { self.parent = parent }

        func setAllowsNetwork(_ allowed: Bool) {
            guard allowed != allowsNetwork else { return }
            allowsNetwork = allowed
            if allowed { loadVisibleFromNetwork() }
        }

        /// The middle of the screen first, where the eye is.
        func loadVisibleFromNetwork() {
            guard let collection else { return }
            let middle = collection.contentOffset.y + collection.bounds.height / 2
            collection.visibleCells.compactMap { $0 as? PhotoCell }.filter(\.waitsForNetwork)
                .sorted { abs($0.center.y - middle) < abs($1.center.y - middle) }
                .forEach { $0.loadFromNetworkIfWaiting() }
        }
        func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].count }
        func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
            let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "day-header", for: indexPath) as! DayHeaderView
            configure(header, at: indexPath)
            return header
        }
        fileprivate func configure(_ header: DayHeaderView, at index: IndexPath) {
            let title = dayGroups.indices.contains(index.section)
                ? dayGroups[index.section].first(where: { $0.startItem == index.item })?.title : nil
            header.configure(title ?? "")
        }
        func collectionView(_ view: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath) as! PhotoCell
            configure(cell, at: indexPath)
            return cell
        }
        func configure(_ cell: PhotoCell, at index: IndexPath) {
            let entry = parent.store.entry(section: index.section, item: index.item)
            cell.configure(entry: entry, pipeline: parent.pipeline,
                           selected: entry.map { parent.store.selected.contains($0.id) } ?? false,
                           selecting: parent.store.isSelecting,
                           month: index.item == 0 && sections.indices.contains(index.section)
                                && !(dayGroups.indices.contains(index.section) && dayGroups[index.section].contains(where: { $0.startItem == 0 }))
                                ? monthBadge(for: sections[index.section].id) : nil,
                           network: allowsNetwork)
            if entry == nil && !parent.store.isReplacingFeed { parent.store.requestBucket(index.section) }
            if sections.indices.contains(index.section), sections[index.section].id == "results",
               index.item >= max(0, sections[index.section].count - 12) {
                Task { [weak self] in self?.parent.store.loadMore() }
            }
        }
        private func monthBadge(for bucket: String) -> String? {
            guard let date = APIDate.parse(bucket) else { return nil }
            var style = Date.FormatStyle().month(.abbreviated).locale(Locale(identifier: "en"))
            style.timeZone = TimeZone(secondsFromGMT: 0)!
            return date.formatted(style).uppercased()
        }
        func collectionView(_ view: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let entry = parent.store.entry(section: indexPath.section, item: indexPath.item) else { return }
            if parent.store.isSelecting {
                parent.store.toggleSelection(entry)
                Haptics.selectionChanged()
            } else if let asset = entry.remote { parent.onOpen(asset) }
            else if let photo = entry.local { parent.onOpenLocal?(photo) }
        }
        @objc func selectByDragging(_ gesture: UILongPressGestureRecognizer) {
            guard let collection, let index = collection.indexPathForItem(at: gesture.location(in: collection)),
                  let entry = parent.store.entry(section: index.section, item: index.item) else { return }
            if gesture.state == .began { parent.store.isSelecting = true; Haptics.selectionChanged() }
            if gesture.state == .began || gesture.state == .changed { parent.store.select(entry) }
        }
        /// The gesture scale at the last density change, so one pinch can step several times.
        private var pinchBase: CGFloat = 1
        /// The photo under the fingers and where on it they rest; it stays under them.
        private var pinchAnchor: (index: IndexPath, unit: CGPoint)?
        /// How far the grid currently leans toward the next density.
        private var hintScale: CGFloat = 1
        /// The fading picture of the previous density, if a step is still settling.
        private weak var densityPicture: UIView?

        /// Density follows the fingers while they move: a small spread or squeeze changes it at
        /// once, animated around the photo being pinched, and the grid leans toward the next step
        /// in between.
        @objc func changeDensity(_ gesture: UIPinchGestureRecognizer) {
            guard let collection, let layout = collection.collectionViewLayout as? VirtualPhotoLayout else { return }
            let finger = gesture.location(in: collection)
            switch gesture.state {
            case .began:
                pinchBase = 1
                pinchAnchor = anchor(at: finger, in: collection, layout: layout)
            case .changed:
                let step = gesture.scale / pinchBase
                if step > 1.18 || step < 0.85 {
                    let columns = min(6, max(2, layout.columns + (step > 1 ? -1 : 1)))
                    pinchBase = gesture.scale
                    guard columns != layout.columns else { hintScale = 1; zoom(1, around: finger, in: collection, animated: true); return }
                    changeColumns(to: columns, finger: finger, in: collection, layout: layout)
                    Haptics.selectionChanged()
                } else {
                    // A hint of the next density under the fingers, without leaving the grid.
                    hintScale = 1 + (step - 1) * 0.6
                    zoom(hintScale, around: finger, in: collection)
                }
            default:
                hintScale = 1
                zoom(1, around: finger, in: collection, animated: true)
                pinchAnchor = nil
            }
        }

        private func anchor(at point: CGPoint, in collection: UICollectionView, layout: VirtualPhotoLayout) -> (index: IndexPath, unit: CGPoint)? {
            guard let index = collection.indexPathForItem(at: point) ?? firstVisiblePhoto(),
                  let frame = layout.layoutAttributesForItem(at: index)?.frame else { return nil }
            return (index, CGPoint(x: (point.x - frame.minX) / max(1, frame.width), y: (point.y - frame.minY) / max(1, frame.height)))
        }

        /// The new density appears at once around the photo under the fingers, while a picture of
        /// the old grid zooms toward the new size and fades, as in Photos. Animating thousands of
        /// cells between layouts would tear.
        private func changeColumns(to columns: Int, finger: CGPoint, in collection: UICollectionView, layout: VirtualPhotoLayout) {
            let growth = CGFloat(layout.columns) / CGFloat(columns) / hintScale
            // Quick steps must not photograph the previous step's fading picture into a tunnel; the
            // grid is rendered again without it first.
            let stacked = densityPicture != nil
            densityPicture?.removeFromSuperview()
            let picture = UIAccessibility.isReduceMotionEnabled ? nil : collection.snapshotView(afterScreenUpdates: stacked)
            hintScale = 1
            zoom(1, around: finger, in: collection)
            let screen = CGPoint(x: finger.x - collection.contentOffset.x, y: finger.y - collection.contentOffset.y)
            layout.columns = columns
            layout.invalidateLayout()
            collection.layoutIfNeeded()
            if let anchor = pinchAnchor, let frame = layout.layoutAttributesForItem(at: anchor.index)?.frame {
                let top = -collection.adjustedContentInset.top
                let bottom = max(top, collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.height)
                collection.setContentOffset(CGPoint(x: 0, y: min(bottom, max(top, frame.minY + anchor.unit.y * frame.height - screen.y))), animated: false)
                collection.layoutIfNeeded()
            }
            // Cells grew or shrank; ask for thumbnails at their new size, keeping the old ones meanwhile.
            for cell in collection.visibleCells {
                guard let cell = cell as? PhotoCell, let index = collection.indexPath(for: cell) else { continue }
                configure(cell, at: index)
            }
            parent.onDensityChange?(columns)
            guard let picture else { return }
            picture.frame = CGRect(origin: collection.contentOffset, size: collection.bounds.size)
            picture.layer.zPosition = 1_000
            picture.isUserInteractionEnabled = false
            collection.addSubview(picture)
            densityPicture = picture
            let pivot = CGPoint(x: screen.x - picture.bounds.midX, y: screen.y - picture.bounds.midY)
            UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                picture.transform = CGAffineTransform(translationX: pivot.x, y: pivot.y).scaledBy(x: growth, y: growth).translatedBy(x: -pivot.x, y: -pivot.y)
                picture.alpha = 0
            } completion: { _ in picture.removeFromSuperview() }
        }

        private func zoom(_ scale: CGFloat, around point: CGPoint, in collection: UICollectionView, animated: Bool = false) {
            let center = CGPoint(x: collection.bounds.midX, y: collection.bounds.midY)
            var transform = CATransform3DIdentity
            if abs(scale - 1) > 0.001 {
                transform = CATransform3DMakeTranslation(point.x - center.x, point.y - center.y, 0)
                transform = CATransform3DScale(transform, scale, scale, 1)
                transform = CATransform3DTranslate(transform, center.x - point.x, center.y - point.y, 0)
            }
            if animated && !UIAccessibility.isReduceMotionEnabled {
                let animation = CABasicAnimation(keyPath: "sublayerTransform")
                animation.fromValue = NSValue(caTransform3D: collection.layer.presentation()?.sublayerTransform ?? collection.layer.sublayerTransform)
                animation.toValue = NSValue(caTransform3D: transform)
                animation.duration = 0.22
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                collection.layer.add(animation, forKey: "zoom")
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            collection.layer.sublayerTransform = transform
            CATransaction.commit()
        }
        func collectionView(_ view: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            // A cell shown again after leaving the screen restarts the thumbnail it gave up.
            if let cell = cell as? PhotoCell, cell.needsImage { configure(cell, at: indexPath) }
        }
        func collectionView(_ view: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            // Cells that scrolled or scrubbed away give their place in the thumbnail queue to what is on screen.
            (cell as? PhotoCell)?.cancelImage()
        }
        func collectionView(_ view: UICollectionView, prefetchItemsAt paths: [IndexPath]) {
            guard !parent.store.isReplacingFeed else { return }
            for section in Set(paths.map(\.section)) { parent.store.requestBucket(section) }
            // Photos about to scroll in move from disk to memory, so they draw in their first frame.
            guard let side = (view.collectionViewLayout as? VirtualPhotoLayout)?.itemSide else { return }
            let pixels = max(128, Int(side * view.traitCollection.displayScale))
            let assets = paths.compactMap { parent.store.entry(section: $0.section, item: $0.item)?.remote }
            let pipeline = parent.pipeline
            guard !assets.isEmpty else { return }
            Task.detached(priority: .utility) {
                for asset in assets where pipeline.cachedImage(for: asset, pixelSize: pixels) == nil {
                    _ = await pipeline.storedThumbnail(for: asset, pixelSize: pixels)
                }
            }
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            publishVisiblePosition()
            let now = CACurrentMediaTime()
            if let last = lastScroll, now > last.time, now - last.time < 0.25 {
                let speed = abs(scrollView.contentOffset.y - last.offset) / CGFloat(now - last.time)
                let screen = max(1, scrollView.bounds.height)
                // Above about two screens a second photos pass before they could download.
                if speed > screen * 2.2 { setAllowsNetwork(false) }
                else if speed < screen * 1.2 { setAllowsNetwork(true) }
            }
            lastScroll = (scrollView.contentOffset.y, now)
            rest?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.settle() }
            rest = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        func publishVisiblePosition() {
            guard let collection else { return }
            let visible = visiblePhotos()
            guard let first = visible.min() else { return }
            parent.store.visibleSection(first.section, visible: Set(visible.map(\.section)))
            parent.store.navigation.section = first.section
            parent.store.navigation.item = first.item
            if sections.indices.contains(first.section), let attributes = collection.collectionViewLayout.layoutAttributesForItem(at: first) {
                parent.store.position = GridPosition(section: sections[first.section].id, item: first.item,
                                                     offset: collection.contentOffset.y - attributes.frame.minY,
                                                     assetID: parent.store.entry(section: first.section, item: first.item)?.id)
            }
        }
        func publishPositionAfterLayout(requestID: UUID, resetID: UUID) {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, let collection = self.collection,
                      self.parent.store.resetID == resetID,
                      self.parent.store.scrollRequest?.id == requestID else { return }
                collection.layoutIfNeeded()
                self.publishVisiblePosition()
            }
        }
        func firstVisiblePhoto() -> IndexPath? { visiblePhotos().min() }

        /// The photos on screen, asked of the layout itself. Right after a rail jump the collection
        /// view has not laid out its cells yet, and its own visible list still describes where it
        /// was, which left the month heading and month loading behind the photos.
        func visiblePhotos() -> [IndexPath] {
            guard let collection, collection.bounds.width > 0 else { return [] }
            let top = collection.contentOffset.y + collection.adjustedContentInset.top
            let bottom = collection.contentOffset.y + collection.bounds.height - collection.adjustedContentInset.bottom
            guard bottom > top else { return [] }
            let rect = CGRect(x: 0, y: top, width: collection.bounds.width, height: bottom - top)
            return (collection.collectionViewLayout.layoutAttributesForElements(in: rect) ?? [])
                .filter { $0.representedElementCategory == .cell && $0.frame.maxY > top && $0.frame.minY < bottom }
                .map(\.indexPath)
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            parent.store.cancelPendingNavigation()
            parent.store.navigation.isScrolling = true
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { parent.store.navigation.isScrolling = false; settle() }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { parent.store.navigation.isScrolling = false; settle() }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }
        /// The grid has come to rest: whatever is on screen downloads now.
        func settle() {
            rest?.cancel(); rest = nil
            lastScroll = nil
            setAllowsNetwork(true)
            loadVisibleFromNetwork()
        }
        @objc func refresh(_ sender: UIRefreshControl) {
            Task { await parent.store.refreshAfterMutation(); sender.endRefreshing() }
        }
    }
}

/// The layout computes attributes only for visible rows, not for every photo in the library.
@MainActor final class VirtualPhotoLayout: UICollectionViewLayout {
    static let dayHeaderKind = "timeline-day-header"
    var columns = 4
    var showsDayHeaders = false { didSet { if oldValue != showsDayHeaders { invalidateLayout() } } }
    var dayGroups: [[TimelineDayGroup]] = [] { didSet { invalidateLayout() } }
    private var sectionOffsets: [CGFloat] = []
    private var sectionCounts: [Int] = []
    private var sectionItemOffsets: [Int] = []
    private struct GroupLayout {
        let group: TimelineDayGroup
        let header: CGRect
        let itemsTop: CGFloat
        let bottom: CGFloat
    }
    private var groupLayouts: [[GroupLayout]] = []
    private var edge: CGFloat = 1
    /// The side of one photo, for sizing the thumbnails that are about to appear.
    var itemSide: CGFloat { edge }
    /// Where a month's first row starts, so the rail can mark it.
    func top(ofSection section: Int) -> CGFloat? {
        sectionOffsets.indices.contains(section) ? sectionOffsets[section] : nil
    }
    private var totalHeight: CGFloat = 0
    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        edge = max(1, (collectionView.bounds.width - CGFloat(columns - 1)) / CGFloat(columns))
        sectionOffsets = []; sectionCounts = []; sectionItemOffsets = []; groupLayouts = []; totalHeight = 0
        if !showsDayHeaders {
            // Month boundaries are labels on photos, not breaks in the contact sheet.
            // Preserve section index paths while packing their items into shared rows.
            var itemOffset = 0
            for section in 0..<collectionView.numberOfSections {
                let count = collectionView.numberOfItems(inSection: section)
                sectionItemOffsets.append(itemOffset)
                sectionCounts.append(count)
                sectionOffsets.append(CGFloat(itemOffset / columns) * (edge + 1))
                groupLayouts.append([])
                itemOffset += count
            }
            totalHeight = CGFloat((itemOffset + columns - 1) / columns) * (edge + 1)
            return
        }
        for section in 0..<collectionView.numberOfSections {
            let count = collectionView.numberOfItems(inSection: section)
            sectionOffsets.append(totalHeight); sectionCounts.append(count)
            let groups = dayGroups.indices.contains(section) ? dayGroups[section] : []
            let complete = !groups.isEmpty && groups.first?.startItem == 0
                && groups.last.map { $0.startItem + $0.count == count } == true
                && zip(groups, groups.dropFirst()).allSatisfy { pair in pair.0.startItem + pair.0.count == pair.1.startItem }
            guard complete else { groupLayouts.append([]); totalHeight += CGFloat((count + columns - 1) / columns) * (edge + 1); continue }
            var y = totalHeight
            var layouts: [GroupLayout] = []
            for group in groups {
                let header = CGRect(x: 0, y: y, width: collectionView.bounds.width,
                                    height: DayHeaderView.height(for: group.title, width: collectionView.bounds.width,
                                                                 traits: collectionView.traitCollection))
                let itemsTop = header.maxY + 2
                let rows = (group.count + columns - 1) / columns
                let bottom = itemsTop + CGFloat(rows) * (edge + 1)
                layouts.append(GroupLayout(group: group, header: header, itemsTop: itemsTop, bottom: bottom))
                y = bottom + 4
            }
            groupLayouts.append(layouts)
            totalHeight = max(totalHeight, y - 4)
        }
    }
    override var collectionViewContentSize: CGSize { CGSize(width: collectionView?.bounds.width ?? 0, height: totalHeight) }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result: [UICollectionViewLayoutAttributes] = []
        if !showsDayHeaders {
            let firstGlobalItem = max(0, Int(floor(rect.minY / (edge + 1)))) * columns
            let lastGlobalItem = max(0, Int(floor(rect.maxY / (edge + 1))) + 1) * columns
            for section in sectionCounts.indices {
                let offset = sectionItemOffsets[section]
                let first = max(0, firstGlobalItem - offset)
                let last = min(sectionCounts[section], lastGlobalItem - offset)
                guard first < last else { continue }
                for item in first..<last {
                    if let attributes = layoutAttributesForItem(at: IndexPath(item: item, section: section)) { result.append(attributes) }
                }
            }
            return result
        }
        for section in sectionOffsets.indices {
            let top = sectionOffsets[section]
            let bottom = section + 1 < sectionOffsets.count ? sectionOffsets[section + 1] : totalHeight
            guard bottom >= rect.minY && top <= rect.maxY else { continue }
            if !groupLayouts[section].isEmpty {
                let groups = groupLayouts[section]
                var low = 0, high = groups.count
                while low < high {
                    let middle = (low + high) / 2
                    if groups[middle].bottom <= rect.minY { low = middle + 1 } else { high = middle }
                }
                for group in groups[low...] {
                    if group.header.minY > rect.maxY { break }
                    if group.header.intersects(rect) { result.append(headerAttributes(section: section, layout: group)) }
                    guard group.bottom >= rect.minY, group.itemsTop <= rect.maxY else { continue }
                    let rows = (group.group.count + columns - 1) / columns
                    let firstRow = max(0, Int((rect.minY - group.itemsTop) / (edge + 1)))
                    let lastRow = min(rows - 1, max(firstRow, Int((rect.maxY - group.itemsTop) / (edge + 1))))
                    if firstRow <= lastRow {
                        let firstItem = group.group.startItem + firstRow * columns
                        let lastItem = min(group.group.startItem + group.group.count, group.group.startItem + (lastRow + 1) * columns)
                        for item in firstItem..<lastItem {
                            if let attributes = layoutAttributesForItem(at: IndexPath(item: item, section: section)) { result.append(attributes) }
                        }
                    }
                }
                continue
            }
            let firstRow = max(0, Int((rect.minY - top) / (edge + 1)))
            let lastRow = max(firstRow, Int((rect.maxY - top) / (edge + 1)))
            let first = min(sectionCounts[section], firstRow * columns)
            let last = min(sectionCounts[section], (lastRow + 1) * columns)
            for item in first..<last {
                if let attributes = layoutAttributesForItem(at: IndexPath(item: item, section: section)) { result.append(attributes) }
            }
        }
        return result
    }
    override func layoutAttributesForItem(at index: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard sectionOffsets.indices.contains(index.section), index.item >= 0, index.item < sectionCounts[index.section] else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: index)
        if !showsDayHeaders {
            let item = sectionItemOffsets[index.section] + index.item
            attributes.frame = CGRect(x: CGFloat(item % columns) * (edge + 1),
                                      y: CGFloat(item / columns) * (edge + 1), width: edge, height: edge)
            return attributes
        }
        let groups = groupLayouts[index.section]
        if !groups.isEmpty, let group = groupLayout(section: index.section, item: index.item) {
            let local = index.item - group.group.startItem
            attributes.frame = CGRect(x: CGFloat(local % columns) * (edge + 1),
                                      y: group.itemsTop + CGFloat(local / columns) * (edge + 1), width: edge, height: edge)
        } else {
            attributes.frame = CGRect(x: CGFloat(index.item % columns) * (edge + 1),
                                      y: sectionOffsets[index.section] + CGFloat(index.item / columns) * (edge + 1),
                                      width: edge, height: edge)
        }
        return attributes
    }
    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard elementKind == Self.dayHeaderKind, let group = groupLayouts.indices.contains(indexPath.section)
            ? groupLayouts[indexPath.section].first(where: { $0.group.startItem == indexPath.item }) : nil else { return nil }
        return headerAttributes(section: indexPath.section, layout: group)
    }
    private func groupLayout(section: Int, item: Int) -> GroupLayout? {
        let groups = groupLayouts[section]
        var low = 0, high = groups.count
        while low < high {
            let middle = (low + high) / 2
            if groups[middle].group.startItem + groups[middle].group.count <= item { low = middle + 1 } else { high = middle }
        }
        guard groups.indices.contains(low), groups[low].group.startItem <= item else { return nil }
        return groups[low]
    }
    private func headerAttributes(section: Int, layout: GroupLayout) -> UICollectionViewLayoutAttributes {
        let index = IndexPath(item: layout.group.startItem, section: section)
        let attributes = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.dayHeaderKind, with: index)
        attributes.frame = layout.header
        return attributes
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { newBounds.width != collectionView?.bounds.width }
}

@MainActor private final class DayHeaderView: UICollectionReusableView {
    private let label = UILabel()
    private static let horizontalPadding: CGFloat = 14
    private static let verticalPadding: CGFloat = 8
    static func titleFont(for traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 15, weight: .semibold), compatibleWith: traits)
    }
    static func height(for title: String, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let font = titleFont(for: traits)
        let bounds = (title as NSString).boundingRect(
            with: CGSize(width: max(0, width - horizontalPadding * 2), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        return ceil(bounds.height) + verticalPadding * 2
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = Self.titleFont(for: traitCollection)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textColor = .secondaryLabel
        isAccessibilityElement = true
        accessibilityTraits = .header
        accessibilityIdentifier = "library.dayHeader"
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Day header is created programmatically") }
    func configure(_ title: String) {
        label.font = Self.titleFont(for: traitCollection)
        label.text = title
        accessibilityLabel = title
    }
}

@MainActor final class PhotoCell: UICollectionViewCell {
    private let image = UIImageView()
    private let badge = UILabel()
    private let month = UILabel()
    /// The first photo of a month carries the month as a small glass chip, as in the design. The
    /// glass is dark and tinted, so the white label stays legible over a white photo too.
    private let monthChip: UIVisualEffectView = {
        let glass = UIGlassEffect(style: .regular)
        glass.tintColor = UIColor(white: 0, alpha: 0.38)
        let chip = UIVisualEffectView(effect: glass)
        chip.overrideUserInterfaceStyle = .dark
        return chip
    }()
    private let check = UIImageView()
    private var localMedia: LocalPhotoMedia?
    private var task: Task<Void, Never>?
    private var identity: String?
    private var mediaID: String?
    /// The cell shows a real thumbnail, not the thumbhash sketch or nothing.
    private var showsThumbnail = false
    /// The thumbnail is neither in memory nor on disk; it downloads once scrolling settles.
    private(set) var waitsForNetwork = false
    private var pending: (asset: Asset, pixels: Int, pipeline: MediaPipeline)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        image.contentMode = .scaleAspectFill; image.clipsToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(image)
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), image.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), image.topAnchor.constraint(equalTo: contentView.topAnchor), image.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)])
        // Durations are bare monospaced text with a shadow, legible on any photo.
        badge.textColor = .white
        badge.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedDigitSystemFont(ofSize: 10, weight: .medium))
        badge.adjustsFontForContentSizeCategory = true
        badge.layer.shadowColor = UIColor.black.cgColor; badge.layer.shadowOpacity = 0.8; badge.layer.shadowRadius = 3; badge.layer.shadowOffset = CGSize(width: 0, height: 1)
        badge.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(badge)
        month.textColor = .white
        month.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedSystemFont(ofSize: 9.5, weight: .medium))
        month.adjustsFontForContentSizeCategory = true
        month.layer.shadowColor = UIColor.black.cgColor; month.layer.shadowOpacity = 0.45; month.layer.shadowRadius = 1.5; month.layer.shadowOffset = CGSize(width: 0, height: 0.5)
        month.translatesAutoresizingMaskIntoConstraints = false
        monthChip.cornerConfiguration = .capsule()
        monthChip.translatesAutoresizingMaskIntoConstraints = false
        monthChip.contentView.addSubview(month)
        contentView.addSubview(monthChip)
        check.tintColor = .systemCyan; check.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(check)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4), badge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            monthChip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6), monthChip.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6), monthChip.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -4),
            month.leadingAnchor.constraint(equalTo: monthChip.contentView.leadingAnchor, constant: 8), month.trailingAnchor.constraint(equalTo: monthChip.contentView.trailingAnchor, constant: -7),
            month.topAnchor.constraint(equalTo: monthChip.contentView.topAnchor, constant: 4), month.bottomAnchor.constraint(equalTo: monthChip.contentView.bottomAnchor, constant: -4),
            check.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5), check.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5), check.widthAnchor.constraint(equalToConstant: 24), check.heightAnchor.constraint(equalToConstant: 24)
        ])
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("PhotoCell is created programmatically") }
    override func prepareForReuse() {
        super.prepareForReuse(); task?.cancel(); task = nil; localMedia?.cancel(); localMedia = nil
        identity = nil; mediaID = nil; image.image = nil; showsThumbnail = false; waitsForNetwork = false; pending = nil
    }
    var needsImage: Bool { identity == nil }
    /// Drops a thumbnail that has not arrived yet; one already shown stays.
    func cancelImage() {
        if task != nil { task?.cancel(); task = nil; identity = nil }
        if waitsForNetwork { waitsForNetwork = false; identity = nil }
        if let localMedia, localMedia.loading { localMedia.cancel(); self.localMedia = nil; identity = nil }
    }
    /// Swaps in the next stage of the photo: nothing, its sketch, a stored or downloaded thumbnail.
    private func show(_ next: UIImage?, thumbnail: Bool, animated: Bool) {
        showsThumbnail = thumbnail && next != nil
        guard animated, image.image !== next, !UIAccessibility.isReduceMotionEnabled else { image.image = next; return }
        UIView.transition(with: image, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction]) { self.image.image = next }
    }
    /// Starts the download the cell has been waiting for, once the grid has slowed down.
    func loadFromNetworkIfWaiting() {
        guard waitsForNetwork, let key = identity, let (asset, pixels, pipeline) = pending else { return }
        waitsForNetwork = false
        task = Task { [weak self] in
            do {
                let prepared = try await pipeline.image(for: asset, size: .thumbnail, pixelSize: pixels)
                guard !Task.isCancelled, let self, self.identity == key else { return }
                self.show(prepared.uiImage, thumbnail: true, animated: true)
                self.task = nil
            } catch is CancellationError {
                // A shared download can be dropped independently of this cell. Wait for the next chance.
                if let self, self.identity == key { self.waitsForNetwork = true; self.task = nil }
            } catch {
                guard let self, self.identity == key else { return }
                self.image.image = UIImage(systemName: "photo.badge.exclamationmark")
                self.image.tintColor = .secondaryLabel
                self.showsThumbnail = false
                self.accessibilityLabel = "Preview unavailable, \(asset.displayName)"
                // Permit retry when the row is next configured after connectivity returns.
                self.identity = nil
            }
        }
    }
    func configure(entry: LibraryEntry?, pipeline: MediaPipeline, selected: Bool, selecting: Bool, month: String?, network: Bool = true) {
        check.isHidden = !selecting
        check.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        self.month.attributedText = month.map { NSAttributedString(string: $0, attributes: [.kern: 0.95]) }
        monthChip.isHidden = month == nil
        accessibilityTraits = selected ? [.button, .selected] : [.button]
        if case .local(let photo) = entry {
            accessibilityLabel = photo.title + ", on this phone"
            badge.isHidden = !photo.video && !photo.live
            badge.text = photo.video ? Self.duration(Int(photo.duration * 1000)) : "LIVE"
            let key = "local:\(photo.id)|\(photo.modified?.timeIntervalSince1970 ?? 0)"
            guard key != identity else { return }
            task?.cancel(); localMedia?.cancel(); identity = key; mediaID = key; image.image = nil
            showsThumbnail = false; waitsForNetwork = false; pending = nil
            let media = LocalPhotoMedia(); localMedia = media
            media.load(photo, full: false, network: false)
            observeLocal(media, key: key)
            return
        }
        localMedia?.cancel(); localMedia = nil
        let asset = entry?.remote
        guard let asset else {
            task?.cancel(); identity = nil; mediaID = nil; image.image = nil; badge.isHidden = true
            showsThumbnail = false; waitsForNetwork = false; pending = nil
            accessibilityLabel = "Loading photo"; return
        }
        accessibilityLabel = asset.displayName + (asset.isVideo ? ", video" : "")
        badge.isHidden = !asset.isVideo && asset.livePhotoVideoId == nil
        badge.text = asset.isVideo ? Self.duration(asset.duration ?? 0) : "LIVE"
        let pixels = max(128, Int(bounds.width * traitCollection.displayScale))
        let source = "\(asset.id)|\(asset.cacheRevision)"
        let key = "\(source)|\(pixels)"
        guard identity != key else {
            if network { loadFromNetworkIfWaiting() }
            return
        }
        task?.cancel(); identity = key; waitsForNetwork = false
        pending = (asset, pixels, pipeline)
        // A thumbnail still in memory draws in this frame instead of after an empty one.
        if let cached = pipeline.cachedImage(for: asset, size: .thumbnail, pixelSize: pixels) {
            show(cached.uiImage, thumbnail: true, animated: false); mediaID = source; task = nil; return
        }
        // Never an empty brick: a density change keeps the current thumbnail, a recycled cell
        // shows this photo at another size if memory has one, and otherwise its thumbhash sketch.
        if mediaID != source {
            if let latest = pipeline.latestImage(assetID: asset.id, size: .thumbnail, revision: asset.cacheRevision) {
                show(latest.uiImage, thumbnail: true, animated: false)
            } else {
                show(ThumbHashImages.image(for: asset), thumbnail: false, animated: false)
            }
        }
        mediaID = source
        task = Task { [weak self] in
            if let stored = await pipeline.storedThumbnail(for: asset, pixelSize: pixels) {
                guard !Task.isCancelled, let self, self.identity == key else { return }
                self.show(stored.uiImage, thumbnail: true, animated: true)
                self.task = nil
                return
            }
            guard !Task.isCancelled, let self, self.identity == key else { return }
            self.task = nil
            self.waitsForNetwork = true
            if network { self.loadFromNetworkIfWaiting() }
        }
    }
    private func observeLocal(_ media: LocalPhotoMedia, key: String) {
        guard identity == key else { return }
        withObservationTracking {
            image.image = media.image
            if media.image == nil && !media.loading {
                image.image = UIImage(systemName: media.cloud ? "icloud.and.arrow.down" : "photo.badge.exclamationmark")
                image.tintColor = .secondaryLabel
            }
        } onChange: { [weak self, weak media] in
            Task { @MainActor in
                guard let self, let media, self.identity == key else { return }
                self.observeLocal(media, key: key)
            }
        }
    }
    private static func duration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

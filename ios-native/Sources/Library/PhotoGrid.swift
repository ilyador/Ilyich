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
    /// The grid's motion, shared with the rail that scrubs it; a grid without a rail has its own.
    var viewport: GridViewport? = nil
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
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
        view.refreshControl = refresh
        context.coordinator.collection = view
        context.coordinator.viewport.attach(view)
        let selection = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectByDragging(_:)))
        selection.minimumPressDuration = 0.35
        view.addGestureRecognizer(selection)
        // While selecting, a sideways drag from a photo selects a range of photos, as in Photos.
        // Scrolling waits only for it to decide; a drag that starts vertical scrolls as before.
        let drag = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectRange(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = context.coordinator
        drag.isEnabled = false
        view.addGestureRecognizer(drag)
        view.panGestureRecognizer.require(toFail: drag)
        context.coordinator.rangeDrag = drag
        context.coordinator.dragSelector.collection = view
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.changeDensity(_:))))
        // Two fingers always pinch; scrolling takes one.
        view.panGestureRecognizer.maximumNumberOfTouches = 1
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.binder.pipeline !== pipeline { coordinator.binder = ThumbnailBinder(pipeline: pipeline) }
        view.isScrollEnabled = !store.isReplacingFeed
        view.isUserInteractionEnabled = !store.isReplacingFeed
        coordinator.rangeDrag?.isEnabled = store.isSelecting && !store.isReplacingFeed
        if !store.isSelecting || store.isReplacingFeed { coordinator.dragSelector.end() }
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
        var columnsChanged = false
        if let layout = view.collectionViewLayout as? VirtualPhotoLayout {
            layout.showsDayHeaders = showsDayHeaders
            if groupingChanged { layout.dayGroups = dayGroups }
            if layout.columns != columns {
                columnsChanged = true
                let anchor = coordinator.firstVisiblePhoto()
                layout.columns = columns; layout.invalidateLayout(); view.layoutIfNeeded()
                if let anchor, let frame = layout.layoutAttributesForItem(at: anchor)?.frame {
                    view.setContentOffset(CGPoint(x: 0, y: frame.minY - topInset), animated: false)
                }
            }
        }
        view.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        let needsReload = coordinator.sections != sections || reset
        let revisionChanged = coordinator.revision != store.revision
        coordinator.dayGroups = dayGroups
        coordinator.showsDayHeaders = showsDayHeaders
        if needsReload {
            // Index paths of a drag in progress no longer name the same photos, unless more
            // search results were only added after the ones already shown.
            let appended = !reset && sections.count == 1 && coordinator.sections.count == 1
                && sections[0].id == "results" && coordinator.sections[0].id == "results"
                && sections[0].count >= coordinator.sections[0].count
            if !appended { coordinator.dragSelector.end() }
            coordinator.sections = sections; coordinator.resetID = store.resetID
            view.reloadData()
            if reset {
                view.layoutIfNeeded()
                if let position = store.restorePosition, let index = store.restoredIndex(for: position),
                   let attributes = view.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: index.item, section: index.section)) {
                    view.setContentOffset(CGPoint(x: 0, y: attributes.frame.minY + position.offset), animated: false)
                } else { view.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false) }
            }
            // New rows or a reset change what is on screen without a scroll, and UIKit reports
            // none for an offset that did not move (a feed opened from the top of the one before,
            // or a cold start). Cells no longer ask for their months, so the viewport is published.
            coordinator.publishPositionAfterReload(resetID: store.resetID)
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
        if coordinator.dragSelector.isActive {
            // A month the drag passed before it loaded may have arrived. The selection changes
            // after this update, not during it.
            Task { @MainActor [weak coordinator] in coordinator?.dragSelector.refresh() }
        }
        if topInsetChanged && wasAtTop && !reset {
            // Growing chrome (Dynamic Type or a filter chip) must not cover the
            // first day header. Scrolled photo positions stay unchanged.
            view.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
        }
        if !needsReload && (groupingChanged || revisionChanged || coordinator.selection != store.selected || coordinator.selecting != store.isSelecting) {
            for cell in view.visibleCells {
                guard let cell = cell as? PhotoCell, let index = view.indexPath(for: cell) else { continue }
                coordinator.configure(cell, at: index)
            }
        }
        coordinator.revision = store.revision; coordinator.selection = store.selected; coordinator.selecting = store.isSelecting
        // The rows changed under the grid without a scroll (a month became ready, new rows, a
        // reset, a new density): the photos ahead of and behind the screen are read again.
        if needsReload || revisionChanged || groupingChanged || columnsChanged { coordinator.viewport.contentChanged() }
        if let request = store.scrollRequest, request.id != coordinator.lastScrollRequest,
           let index = store.restoredIndex(for: request.position) {
            coordinator.lastScrollRequest = request.id
            let resetID = store.resetID
            view.scrollToItem(at: IndexPath(item: index.item, section: index.section), at: .top, animated: false)
            coordinator.publishPositionAfterLayout(requestID: request.id, resetID: resetID)
        }
    }

    @MainActor final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        var parent: PhotoGrid
        weak var collection: UICollectionView?
        var sections: [LibrarySection] = [] { didSet { sectionCounts = sections.map(\.count) } }
        private var sectionCounts: [Int] = []
        /// The sideways drag that selects a range while selecting.
        weak var rangeDrag: UIPanGestureRecognizer?
        let dragSelector = GridDragSelector()
        /// The entries the drag in progress changed, by where they sit in the grid.
        private var dragEntries: [IndexPath: LibraryEntry] = [:]
        var dayGroups: [[TimelineDayGroup]] = []
        var resetID: UUID?
        var revision = -1
        var selection: Set<String> = []
        var selecting = false
        var showsDayHeaders = false
        var lastScrollRequest: UUID?
        /// Binds photos to cells and sends the grid's thumbnail demand.
        var binder: ThumbnailBinder { didSet { binder.needsDemand = { [weak self] in self?.viewport.setNeedsDemand() } } }
        /// How the grid moves and what it is about to show. It sends the demand at most once per
        /// frame; the policy decides from its motion what may download.
        let viewport: GridViewport
        init(_ parent: PhotoGrid) {
            self.parent = parent
            viewport = parent.viewport ?? GridViewport()
            binder = ThumbnailBinder(pipeline: parent.pipeline)
            super.init()
            binder.needsDemand = { [weak self] in self?.viewport.setNeedsDemand() }
            viewport.entry = { [weak self] path in self?.parent.store.entry(section: path.section, item: path.item) }
            viewport.shortSide = { [weak self] in
                guard let self, let collection else { return 128 }
                return thumbnailPixels(collection) ?? 128
            }
            viewport.submit = { [weak self] windows in self?.submitDemand(windows) }
            dragSelector.counts = { [weak self] in self?.sectionCounts ?? [] }
            dragSelector.isSelected = { [weak self] index in
                guard let store = self?.parent.store, let entry = store.entry(section: index.section, item: index.item) else { return nil }
                return store.selected.contains(entry.id)
            }
            dragSelector.apply = { [weak self] change in
                guard let self else { return }
                let store = parent.store
                // A photo the drag changed keeps its entry, so putting it back still works after
                // its month was evicted while the drag went on.
                let entries = { (paths: [IndexPath]) in
                    paths.compactMap { path -> LibraryEntry? in
                        let entry = store.entry(section: path.section, item: path.item) ?? self.dragEntries[path]
                        if let entry { self.dragEntries[path] = entry }
                        return entry
                    }
                }
                store.changeSelection(adding: entries(change.select), removing: entries(change.deselect))
            }
        }

        /// The grid's demand, once per frame: the cells on screen that lack their thumbnail, then
        /// the windows the viewport read off the layout. While the feed is being replaced under
        /// the grid only what is on screen counts.
        private func submitDemand(_ windows: GridViewport.Windows) {
            guard let collection else { return }
            // Right after a jump the cells for the new offset are not laid out yet.
            collection.layoutIfNeeded()
            guard parent.store.isReplacingFeed else { return binder.submit(windows) }
            binder.submit(GridViewport.Windows(visible: windows.visible, visibleBand: windows.visibleBand, ahead: [], behind: [], target: [],
                                               shortSide: windows.shortSide, motion: windows.motion))
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
            let changed = cell.configure(entry: entry, binder: binder,
                           selected: entry.map { parent.store.selected.contains($0.id) } ?? false,
                           selecting: parent.store.isSelecting,
                           month: index.item == 0 && sections.indices.contains(index.section)
                                && !(dayGroups.indices.contains(index.section) && dayGroups[index.section].contains(where: { $0.startItem == 0 }))
                                ? monthBadge(for: sections[index.section].id) : nil)
            if changed { viewport.setNeedsDemand() }
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
        @objc func selectRange(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                guard let index = dragStart(gesture) else { return }
                dragEntries = [:]
                dragSelector.begin(at: index, gesture: gesture)
            case .changed: dragSelector.update()
            default: dragSelector.end()
            }
        }
        /// The photo under the point where the drag started.
        private func dragStart(_ gesture: UIPanGestureRecognizer) -> IndexPath? {
            guard let collection else { return nil }
            let location = gesture.location(in: collection), moved = gesture.translation(in: collection)
            let index = collection.indexPathForItem(at: CGPoint(x: location.x - moved.x, y: location.y - moved.y))
            return index.flatMap { parent.store.entry(section: $0.section, item: $0.item) != nil ? $0 : nil }
        }
        /// The range drag takes only a drag that starts on a photo and moves mostly sideways;
        /// anything else fails it at once and the grid scrolls.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard gesture === rangeDrag, let pan = gesture as? UIPanGestureRecognizer, let collection else { return true }
            guard parent.store.isSelecting, !parent.store.isReplacingFeed else { return false }
            let moved = pan.translation(in: collection), speed = pan.velocity(in: collection)
            let sideways = moved == .zero ? abs(speed.x) > abs(speed.y) : abs(moved.x) > abs(moved.y)
            return sideways && dragStart(pan) != nil
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
            viewport.contentChanged()
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
            // A cell on screen joins the demand.
            guard let cell = cell as? PhotoCell else { return }
            cell.setOnScreen(true)
            if cell.binding.map({ $0.stage != .exact }) ?? false { viewport.setNeedsDemand() }
        }
        func collectionView(_ view: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            // Cells that scrolled or scrubbed away give their place in the thumbnail queue to what is on screen.
            guard let cell = cell as? PhotoCell else { return }
            cell.abandonDisplay()
            cell.setOnScreen(false)
            if cell.binding.map({ $0.stage != .exact }) ?? false { viewport.setNeedsDemand() }
        }
        /// The pixel size cells decode their thumbnails at.
        private func thumbnailPixels(_ view: UICollectionView) -> Int? {
            guard let side = (view.collectionViewLayout as? VirtualPhotoLayout)?.itemSide else { return nil }
            return max(128, Int(side * view.traitCollection.displayScale))
        }
        // The scroll delegate goes to the viewport, which measures the motion, knows where a
        // fling lands and sends the demand once per frame; the policy decides what may download.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            publishVisiblePosition()
            viewport.didScroll()
        }
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            viewport.willEndDragging(velocity: velocity, target: targetContentOffset.pointee)
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
        /// The grid's rows changed under it: what is on screen is published once this update is
        /// over, so the feed hears of the months new rows or a reset put there without a scroll.
        func publishPositionAfterReload(resetID: UUID) {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, let collection = self.collection, self.parent.store.resetID == resetID,
                      !self.parent.store.isReplacingFeed else { return }
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
            viewport.willBeginDragging()
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            viewport.didEndDragging(decelerate: decelerate)
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            viewport.didEndDecelerating()
        }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { viewport.didEndScrollingAnimation() }
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
    /// A server photo's sketch and thumbnail draw straight into this view's layer: an image view
    /// does a good deal of work for every new image, and a scrub brings a cell several a second. A
    /// view's own layer moves with the cell when UIKit animates its size, as when the app turns
    /// back upright, and has no animations of its own: changes show at once unless a cross-dissolve
    /// is added.
    private let photo: UIView = {
        let view = UIView()
        view.layer.contentsGravity = .resizeAspectFill
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        return view
    }()
    /// What the photo layer draws.
    private var drawn: CGImage?
    /// A status symbol, which needs its tint, in an image view made when first needed.
    private var image: UIImageView?
    /// The length of a video or LIVE, the month chip and the selection check are made when first
    /// needed and sit in the cell only while they show. UIKit walks every view of a cell each time
    /// it reuses it, and the glass chip alone is several, so hidden overlays in every cell cost a
    /// scrub more than its photos did.
    private var badge: UILabel?
    /// The first photo of a month carries the month as a small glass chip, as in the design. The
    /// glass is dark and tinted, so the white label stays legible over a white photo too.
    private var monthChip: (glass: UIVisualEffectView, label: UILabel)?
    private var monthText: String?
    private var check: UIImageView?
    private static let checked = UIImage(systemName: "checkmark.circle.fill")
    private static let unchecked = UIImage(systemName: "circle")
    /// The photo shown, on the server or only on this phone, and how far it has arrived. Set by
    /// the grid's ThumbnailBinder; the cell itself never loads anything.
    var binding: ThumbnailBinder.Binding?
    /// The cell shows a real thumbnail, not the thumbhash sketch or nothing.
    private(set) var showsThumbnail = false
    /// Times the bind to the first real thumbnail while a perf scenario runs.
    var displayProbe = ThumbDisplayProbe()
    /// The photo this cell shows, and whether the cell is on screen. While both hold, its decoded
    /// thumbnail is pinned: memory pressure and the budget evict around it.
    private var pinTarget: (pipeline: MediaPipeline, assetID: String)?
    private var onScreen = true
    /// The pin held now. Read by deinit, which runs off the main actor once nothing else holds the cell.
    private nonisolated(unsafe) var pin: (pipeline: MediaPipeline, assetID: String)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        photo.frame = contentView.bounds
        contentView.insertSubview(photo, at: 0)
        isAccessibilityElement = true
        // The overlays are placed by hand, so a new text size lays them out again.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: PhotoCell, _: UITraitCollection) in
            cell.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError("PhotoCell is created programmatically") }
    /// The grid gives every photo its size. Left to the default, UIKit asked Auto Layout for each
    /// cell's fitting size on every bind, which took a sixth of the main thread while scrubbing.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }
    /// The overlays sit where their constraints used to put them: the length 4 points in from the
    /// bottom right, the month chip 6 in from the top left and no closer than 4 to the right edge,
    /// the check 5 in from the top right.
    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        photo.frame = bounds
        if let image, image.superview != nil { image.frame = bounds }
        if let badge, badge.superview != nil {
            let size = badge.intrinsicContentSize
            badge.frame = CGRect(x: bounds.maxX - 4 - size.width, y: bounds.maxY - 4 - size.height, width: size.width, height: size.height)
        }
        if let chip = monthChip, chip.glass.superview != nil {
            let size = chip.label.intrinsicContentSize
            let width = max(0, min(size.width + 15, bounds.width - 10))
            chip.glass.frame = CGRect(x: bounds.minX + 6, y: bounds.minY + 6, width: width, height: size.height + 8)
            chip.label.frame = CGRect(x: 8, y: 4, width: max(0, width - 15), height: size.height)
        }
        if let check, check.superview != nil {
            check.frame = CGRect(x: bounds.maxX - 29, y: bounds.minY + 5, width: 24, height: 24)
        }
    }
    override func prepareForReuse() {
        // The next bind always sets the image, so it is not cleared here as well; a cross-dissolve
        // still running is dropped, so the next photo shows at once.
        super.prepareForReuse(); photo.layer.removeAllAnimations()
        binding = nil; showsThumbnail = false
        displayProbe.reset()
        setPinTarget(nil)
    }
    deinit { if let pin { pin.pipeline.unpinThumbnail(pin.assetID) } }
    /// Whether UIKit shows the cell now: only these join the grid's demand.
    var isOnScreen: Bool { onScreen }
    /// The cell came on screen again, or left it.
    func setOnScreen(_ visible: Bool) {
        onScreen = visible
        updatePin()
    }
    private func setPinTarget(_ target: (pipeline: MediaPipeline, assetID: String)?) {
        pinTarget = target
        updatePin()
    }
    private func updatePin() {
        let wanted = onScreen ? pinTarget : nil
        guard wanted?.assetID != pin?.assetID || wanted?.pipeline !== pin?.pipeline else { return }
        if let pin { pin.pipeline.unpinThumbnail(pin.assetID) }
        if let wanted { wanted.pipeline.pinThumbnail(wanted.assetID) }
        pin = wanted
    }
    /// Puts a view into the cell, under any that stack above it: image, length, month, check.
    private func attach(_ view: UIView) {
        guard view.superview !== contentView else { return }
        let order: [UIView?] = [image, badge, monthChip?.glass, check]
        if let above = order.drop(while: { $0 !== view }).dropFirst().compactMap({ $0 }).first(where: { $0.superview === contentView }) {
            contentView.insertSubview(view, belowSubview: above)
        } else {
            contentView.addSubview(view)
        }
        setNeedsLayout()
    }
    private func detach(_ view: UIView?) {
        if let view, view.superview != nil { view.removeFromSuperview() }
    }
    /// A video's length or LIVE.
    private func showBadge(_ text: String?) {
        guard let text else { detach(badge); return }
        let badge = self.badge ?? makeBadge()
        if badge.text != text { badge.text = text; setNeedsLayout() }
        attach(badge)
    }
    /// Lengths are bare monospaced text with a shadow, legible on any photo.
    private func makeBadge() -> UILabel {
        let label = UILabel()
        label.textColor = .white
        label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), compatibleWith: traitCollection)
        label.adjustsFontForContentSizeCategory = true
        label.layer.shadowColor = UIColor.black.cgColor; label.layer.shadowOpacity = 0.8; label.layer.shadowRadius = 3; label.layer.shadowOffset = CGSize(width: 0, height: 1)
        badge = label
        return label
    }
    private func showMonth(_ text: String?) {
        guard let text else { detach(monthChip?.glass); return }
        let chip = monthChip ?? makeMonthChip()
        if monthText != text {
            monthText = text
            chip.label.attributedText = NSAttributedString(string: text, attributes: [.kern: 0.95])
            setNeedsLayout()
        }
        attach(chip.glass)
    }
    private func makeMonthChip() -> (glass: UIVisualEffectView, label: UILabel) {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = UIColor(white: 0, alpha: 0.38)
        let glass = UIVisualEffectView(effect: effect)
        glass.overrideUserInterfaceStyle = .dark
        glass.cornerConfiguration = .capsule()
        let label = UILabel()
        label.textColor = .white
        label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedSystemFont(ofSize: 9.5, weight: .medium), compatibleWith: traitCollection)
        label.adjustsFontForContentSizeCategory = true
        label.layer.shadowColor = UIColor.black.cgColor; label.layer.shadowOpacity = 0.45; label.layer.shadowRadius = 1.5; label.layer.shadowOffset = CGSize(width: 0, height: 0.5)
        glass.contentView.addSubview(label)
        monthChip = (glass, label)
        return (glass, label)
    }
    private func showCheck(selected: Bool, selecting: Bool) {
        guard selecting else { detach(check); return }
        let check = self.check ?? makeCheck()
        let symbol = selected ? Self.checked : Self.unchecked
        if check.image !== symbol { check.image = symbol }
        attach(check)
    }
    private func makeCheck() -> UIImageView {
        let view = UIImageView()
        view.tintColor = .systemCyan
        check = view
        return view
    }
    /// The cell left the screen before its thumbnail came.
    func abandonDisplay() { displayProbe.abandon() }
    /// Draws a server photo's next stage: nothing, its sketch's average colour, its sketch, or a
    /// thumbnail. The binder decides whether it crossfades.
    func draw(_ next: CGImage?, thumbnail: Bool, crossfade: Bool, color: UIColor? = nil) {
        showsThumbnail = thumbnail && next != nil
        detach(image)
        let fill = next == nil ? color?.cgColor : nil
        guard drawn !== next || photo.layer.backgroundColor != fill else { return }
        if crossfade {
            // The cross-dissolve UIView.transition made, added straight to the layer: UIKit's
            // animation setup for each thumbnail cost more than the fade itself.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            photo.layer.add(fade, forKey: kCATransition)
        }
        photo.layer.backgroundColor = fill
        if drawn !== next { photo.layer.contents = next; drawn = next }
    }
    /// The photo could not be loaded; a phone photo Photos holds only in iCloud says so.
    func showUnavailable(name: String, inCloud: Bool = false) {
        show(UIImage(systemName: inCloud ? "icloud.and.arrow.down" : "photo.badge.exclamationmark"), thumbnail: false, tint: .secondaryLabel)
        accessibilityLabel = "Preview unavailable, \(name)"
    }
    /// A status symbol in the given tint, in the image view.
    private func show(_ next: UIImage?, thumbnail: Bool, tint: UIColor? = nil) {
        showsThumbnail = thumbnail && next != nil
        if drawn != nil || photo.layer.backgroundColor != nil { photo.layer.contents = nil; photo.layer.backgroundColor = nil; drawn = nil }
        guard let next else { detach(image); return }
        let view = image ?? {
            let view = UIImageView(frame: contentView.bounds)
            view.contentMode = .scaleAspectFill; view.clipsToBounds = true
            image = view
            return view
        }()
        if let tint { view.tintColor = tint }
        if view.image !== next { view.image = next }
        attach(view)
    }
    /// Shows `entry`. Returns whether the grid's thumbnail demand changed.
    @discardableResult
    func configure(entry: LibraryEntry?, binder: ThumbnailBinder, selected: Bool, selecting: Bool, month: String?) -> Bool {
        showCheck(selected: selected, selecting: selecting)
        showMonth(month)
        let traits: UIAccessibilityTraits = selected ? [.button, .selected] : [.button]
        if accessibilityTraits != traits { accessibilityTraits = traits }
        if case .local(let photo) = entry {
            // Photos renders phone photos through the thumbnail service, like server photos (T6).
            let key = ThumbnailBinder.Ahead.deviceKey(photo)
            setPinTarget((binder.pipeline, key.assetID))
            if binding?.stage != .failed { accessibilityLabel = photo.title + ", on this phone" }
            showBadge(photo.video ? Self.duration(Int(photo.duration * 1000)) : photo.live ? "LIVE" : nil)
            let pixels = max(128, Int(bounds.width * traitCollection.displayScale))
            let before = binding
            let needs = binder.bind(self, toDevice: photo, shortSide: pixels)
            if binding?.stage == .failed { accessibilityLabel = "Preview unavailable, \(photo.title)" }
            return needs || before?.key != binding?.key || before?.shortSide != binding?.shortSide
        }
        let asset = entry?.remote
        setPinTarget(asset.map { (binder.pipeline, $0.id) })
        guard let asset else {
            let wasBound = binding != nil
            binder.unbind(self); showBadge(nil)
            draw(nil, thumbnail: false, crossfade: false)
            displayProbe.awaitMonth()
            accessibilityLabel = "Loading photo"
            return wasBound
        }
        if binding?.stage != .failed { accessibilityLabel = asset.displayName + (asset.isVideo ? ", video" : "") }
        showBadge(asset.isVideo ? Self.duration(asset.duration ?? 0) : asset.livePhotoVideoId != nil ? "LIVE" : nil)
        let pixels = max(128, Int(bounds.width * traitCollection.displayScale))
        let before = binding
        let needs = binder.bind(self, to: asset, shortSide: pixels)
        if binding?.stage == .failed { accessibilityLabel = "Preview unavailable, \(asset.displayName)" }
        return needs || before?.key != binding?.key || before?.shortSide != binding?.shortSide
    }
    private static func duration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

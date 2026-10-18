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
    var showsStorageIndicator = true
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
        let view = ChromeAwareCollectionView(frame: .zero, collectionViewLayout: layout)
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (collection: UICollectionView, _: UITraitCollection) in
            collection.collectionViewLayout.invalidateLayout()
        }
        view.backgroundColor = .systemBackground
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
        let selection = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectByDragging(_:)))
        selection.minimumPressDuration = 0.35
        view.addGestureRecognizer(selection)
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.changeDensity(_:))))
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let sections = store.sections
        let reset = coordinator.resetID != store.resetID
        let dayGroups = showsDayHeaders ? sections.indices.map { store.dayGroups(section: $0) } : Array(repeating: [], count: sections.count)
        let groupingChanged = coordinator.dayGroups != dayGroups
        let wasAtTop = view.contentOffset.y <= -view.contentInset.top + 1
        let anchor: (IndexPath, CGFloat)? = groupingChanged && !reset ? coordinator.firstVisiblePhoto().flatMap { index in
            guard let attributes = view.layoutAttributesForItem(at: index) else { return nil }
            return (index, view.contentOffset.y - attributes.frame.minY)
        } : nil
        if let layout = view.collectionViewLayout as? VirtualPhotoLayout {
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
        if coordinator.sections != sections || reset || groupingChanged {
            coordinator.sections = sections; coordinator.dayGroups = dayGroups; coordinator.resetID = store.resetID
            view.reloadData()
            if reset {
                view.layoutIfNeeded()
                if let position = store.restorePosition, let index = store.restoredIndex(for: position),
                   let attributes = view.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: index.item, section: index.section)) {
                    view.setContentOffset(CGPoint(x: 0, y: attributes.frame.minY + position.offset), animated: false)
                } else { view.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false) }
            } else if groupingChanged {
                view.layoutIfNeeded()
                if wasAtTop {
                    view.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
                } else if let (index, offset) = anchor,
                          let frame = view.collectionViewLayout.layoutAttributesForItem(at: index)?.frame {
                    view.setContentOffset(CGPoint(x: 0, y: frame.minY + offset), animated: false)
                }
            }
        } else if coordinator.revision != store.revision || coordinator.selection != store.selected || coordinator.selecting != store.isSelecting || coordinator.showsStorage != showsStorageIndicator {
            for cell in view.visibleCells {
                guard let cell = cell as? PhotoCell, let index = view.indexPath(for: cell) else { continue }
                coordinator.configure(cell, at: index)
            }
        }
        coordinator.revision = store.revision; coordinator.selection = store.selected; coordinator.selecting = store.isSelecting
        coordinator.showsStorage = showsStorageIndicator
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
        var showsStorage = true
        var lastScrollRequest: UUID?
        init(_ parent: PhotoGrid) { self.parent = parent }
        func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].count }
        func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
            let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "day-header", for: indexPath) as! DayHeaderView
            let title = dayGroups.indices.contains(indexPath.section)
                ? dayGroups[indexPath.section].first(where: { $0.startItem == indexPath.item })?.title : nil
            header.configure(title ?? "")
            return header
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
                           selecting: parent.store.isSelecting, showsStorage: parent.showsStorageIndicator,
                           month: index.item == 0 && sections.indices.contains(index.section)
                                && !(dayGroups.indices.contains(index.section) && dayGroups[index.section].contains(where: { $0.startItem == 0 }))
                                ? sections[index.section].title : nil)
            if entry == nil { parent.store.requestBucket(index.section) }
            if sections.indices.contains(index.section), sections[index.section].id == "results",
               index.item >= max(0, sections[index.section].count - 12) {
                Task { [weak self] in self?.parent.store.loadMore() }
            }
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
        @objc func changeDensity(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .ended, gesture.scale < 0.85 || gesture.scale > 1.15 else { return }
            parent.onDensityChange?(min(6, max(2, parent.columns + (gesture.scale > 1 ? -1 : 1))))
        }
        func collectionView(_ view: UICollectionView, prefetchItemsAt paths: [IndexPath]) {
            for section in Set(paths.map(\.section)) { parent.store.requestBucket(section) }
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            publishVisiblePosition()
        }
        func publishVisiblePosition() {
            guard let collection, let first = firstVisiblePhoto() else { return }
            parent.store.visibleSection(first.section)
            parent.store.navigation.section = first.section
            parent.store.navigation.item = first.item
            if sections.indices.contains(first.section), let attributes = collection.layoutAttributesForItem(at: first) {
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
        func firstVisiblePhoto() -> IndexPath? {
            guard let collection else { return nil }
            let top = collection.contentOffset.y + collection.adjustedContentInset.top
            let bottom = collection.contentOffset.y + collection.bounds.height - collection.adjustedContentInset.bottom
            return collection.indexPathsForVisibleItems.filter { index in
                guard let frame = collection.layoutAttributesForItem(at: index)?.frame else { return false }
                return frame.maxY > top && frame.minY < bottom
            }.min()
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            parent.store.cancelPendingNavigation()
            parent.store.navigation.isScrolling = true
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { parent.store.navigation.isScrolling = false }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { parent.store.navigation.isScrolling = false }
        @objc func refresh(_ sender: UIRefreshControl) {
            Task { await parent.store.refreshAfterMutation(); sender.endRefreshing() }
        }
    }
}

/// The layout computes attributes only for visible rows, not for every photo in the library.
@MainActor final class VirtualPhotoLayout: UICollectionViewLayout {
    static let dayHeaderKind = "timeline-day-header"
    var columns = 4
    var dayGroups: [[TimelineDayGroup]] = [] { didSet { invalidateLayout() } }
    private var sectionOffsets: [CGFloat] = []
    private var sectionCounts: [Int] = []
    private struct GroupLayout {
        let group: TimelineDayGroup
        let header: CGRect
        let itemsTop: CGFloat
        let bottom: CGFloat
    }
    private var groupLayouts: [[GroupLayout]] = []
    private var edge: CGFloat = 1
    private var totalHeight: CGFloat = 0
    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        edge = max(1, (collectionView.bounds.width - CGFloat(columns - 1)) / CGFloat(columns))
        sectionOffsets = []; sectionCounts = []; groupLayouts = []; totalHeight = 0
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
        guard sectionOffsets.indices.contains(index.section), index.item < sectionCounts[index.section] else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: index)
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
    private let check = UIImageView()
    private let storage = UIImageView()
    private var localMedia: LocalPhotoMedia?
    private var task: Task<Void, Never>?
    private var identity: String?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        image.contentMode = .scaleAspectFill; image.clipsToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(image)
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), image.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), image.topAnchor.constraint(equalTo: contentView.topAnchor), image.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)])
        for label in [badge, month] {
            label.textColor = .white; label.backgroundColor = .black.withAlphaComponent(0.6)
            label.font = .preferredFont(forTextStyle: .caption2); label.layer.cornerRadius = 5; label.clipsToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(label)
        }
        check.tintColor = .systemCyan; check.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(check)
        storage.tintColor = .white; storage.layer.shadowOpacity = 0.7; storage.layer.shadowRadius = 2
        storage.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(storage)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4), badge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            month.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4), month.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4), month.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -4),
            check.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5), check.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5), check.widthAnchor.constraint(equalToConstant: 24), check.heightAnchor.constraint(equalToConstant: 24),
            storage.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5), storage.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5), storage.widthAnchor.constraint(equalToConstant: 18), storage.heightAnchor.constraint(equalToConstant: 16)
        ])
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("PhotoCell is created programmatically") }
    override func prepareForReuse() { super.prepareForReuse(); task?.cancel(); task = nil; localMedia?.cancel(); localMedia = nil; identity = nil; image.image = nil }
    func configure(entry: LibraryEntry?, pipeline: MediaPipeline, selected: Bool, selecting: Bool, showsStorage: Bool = true, month: String?) {
        check.isHidden = !selecting
        check.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        self.month.text = month.map { " \($0) " }; self.month.isHidden = month == nil
        accessibilityTraits = selected ? [.button, .selected] : [.button]
        storage.isHidden = entry == nil || !showsStorage
        if case .local(let photo) = entry {
            accessibilityLabel = photo.title + ", on this phone"
            storage.image = UIImage(systemName: "iphone")
            badge.isHidden = !photo.video && !photo.live
            badge.text = photo.video ? " \(Self.duration(Int(photo.duration * 1000))) " : " LIVE "
            let key = "local:\(photo.id)|\(photo.modified?.timeIntervalSince1970 ?? 0)"
            guard key != identity else { return }
            task?.cancel(); localMedia?.cancel(); identity = key; image.image = nil
            let media = LocalPhotoMedia(); localMedia = media
            media.load(photo, full: false, network: false)
            observeLocal(media, key: key)
            return
        }
        localMedia?.cancel(); localMedia = nil
        let asset = entry?.remote
        guard let asset else {
            task?.cancel(); identity = nil; image.image = nil; badge.isHidden = true
            accessibilityLabel = "Loading photo"; return
        }
        storage.image = UIImage(systemName: entry?.local == nil ? "icloud" : "checkmark.icloud")
        accessibilityLabel = asset.displayName + (asset.isVideo ? ", video" : "")
        badge.isHidden = !asset.isVideo && asset.livePhotoVideoId == nil
        badge.text = asset.isVideo ? " \(Self.duration(asset.duration ?? 0)) " : " LIVE "
        let pixels = max(128, Int(bounds.width * traitCollection.displayScale))
        let key = "\(asset.id)|\(asset.cacheRevision)|\(pixels)"
        guard identity != key else { return }
        task?.cancel(); identity = key; image.image = nil
        task = Task { [weak self] in
            do {
                let prepared = try await pipeline.image(for: asset, size: .thumbnail, pixelSize: pixels)
                guard !Task.isCancelled, self?.identity == key else { return }
                self?.image.image = prepared.uiImage
            } catch is CancellationError {} catch {
                guard self?.identity == key else { return }
                self?.image.image = UIImage(systemName: "photo.badge.exclamationmark")
                self?.image.tintColor = .secondaryLabel
                self?.accessibilityLabel = "Preview unavailable, \(asset.displayName)"
                // Permit retry when the row is next configured after connectivity returns.
                self?.identity = nil
            }
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

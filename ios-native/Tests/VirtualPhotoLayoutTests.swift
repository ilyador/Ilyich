import UIKit
import XCTest
@testable import Ilyich

@MainActor final class VirtualPhotoLayoutTests: XCTestCase {
    @MainActor private final class DataSource: NSObject, UICollectionViewDataSource {
        let counts: [Int]
        init(counts: [Int]) { self.counts = counts }
        func numberOfSections(in collectionView: UICollectionView) -> Int { counts.count }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { counts[section] }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }
        func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
            collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath)
        }
    }

    func testDayHeadersPreserveItemIndicesAndReturnOnlyVisibleLayoutAttributes() throws {
        let layout = VirtualPhotoLayout()
        layout.columns = 2
        layout.dayGroups = [[
            TimelineDayGroup(startItem: 0, count: 3, title: "Day one"),
            TimelineDayGroup(startItem: 3, count: 9_997, title: "Day two")
        ]]
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), collectionViewLayout: layout)
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        collection.register(UICollectionReusableView.self, forSupplementaryViewOfKind: VirtualPhotoLayout.dayHeaderKind, withReuseIdentifier: "header")
        let dataSource = DataSource(counts: [10_000])
        collection.dataSource = dataSource
        collection.reloadData()
        collection.layoutIfNeeded()

        let visible = try XCTUnwrap(layout.layoutAttributesForElements(in: CGRect(x: 0, y: 0, width: 300, height: 200)))
        let headers = visible.filter { $0.representedElementKind == VirtualPhotoLayout.dayHeaderKind }
        let items = visible.filter { $0.representedElementCategory == .cell }
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(items.map(\.indexPath.item).sorted(), [0, 1, 2])
        XCTAssertLessThanOrEqual(visible.count, 5, "The layout should emit visible rows and their headers, not attributes for the whole month.")

        let secondHeader = try XCTUnwrap(layout.layoutAttributesForSupplementaryView(
            ofKind: VirtualPhotoLayout.dayHeaderKind, at: IndexPath(item: 3, section: 0)))
        let thirdPhoto = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0)))
        let fourthPhoto = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 3, section: 0)))
        XCTAssertGreaterThanOrEqual(secondHeader.frame.minY, thirdPhoto.frame.maxY)
        XCTAssertGreaterThanOrEqual(fourthPhoto.frame.minY, secondHeader.frame.maxY)
        for first in visible.indices {
            for second in visible.indices where second > first {
                XCTAssertFalse(visible[first].frame.intersects(visible[second].frame), "Visible layout elements must not overlap.")
            }
        }
    }

    func testUnloadedMonthUsesOriginalHeaderlessGridLayout() throws {
        let layout = VirtualPhotoLayout()
        layout.columns = 2
        layout.dayGroups = [[]]
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), collectionViewLayout: layout)
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        collection.register(UICollectionReusableView.self, forSupplementaryViewOfKind: VirtualPhotoLayout.dayHeaderKind, withReuseIdentifier: "header")
        let dataSource = DataSource(counts: [7])
        collection.dataSource = dataSource
        collection.reloadData()
        collection.layoutIfNeeded()

        let visible = try XCTUnwrap(layout.layoutAttributesForElements(in: CGRect(x: 0, y: 0, width: 300, height: 200)))
        XCTAssertFalse(visible.contains { $0.representedElementCategory == .supplementaryView })
        XCTAssertEqual(try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame.minY, 0)
        XCTAssertEqual(try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))).frame.minY, 150.5, accuracy: 0.1)
    }
}

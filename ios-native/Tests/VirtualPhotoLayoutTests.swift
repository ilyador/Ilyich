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
        layout.showsDayHeaders = true
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

    func testMonthBoundariesShareRowsWithoutChangingSectionIndexPaths() throws {
        let layout = VirtualPhotoLayout()
        layout.columns = 4
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 403, height: 100), collectionViewLayout: layout)
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        let dataSource = DataSource(counts: [3, 0, 6, 9_991])
        collection.dataSource = dataSource
        collection.reloadData()
        collection.layoutIfNeeded()

        let nextMonth = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 2)))
        XCTAssertEqual(nextMonth.frame, CGRect(x: 303, y: 0, width: 100, height: 100))
        let nextRow = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 2)))
        XCTAssertEqual(nextRow.frame, CGRect(x: 0, y: 101, width: 100, height: 100))
        let thirdMonth = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 3)))
        XCTAssertEqual(thirdMonth.frame, CGRect(x: 101, y: 202, width: 100, height: 100))
        XCTAssertEqual(layout.collectionViewContentSize.height, 252_500)

        let firstRow = try XCTUnwrap(layout.layoutAttributesForElements(in: CGRect(x: 0, y: 0, width: 403, height: 100)))
        XCTAssertEqual(firstRow.map(\.indexPath), [
            IndexPath(item: 0, section: 0), IndexPath(item: 1, section: 0),
            IndexPath(item: 2, section: 0), IndexPath(item: 0, section: 2)
        ])
        let boundaryRow = try XCTUnwrap(layout.layoutAttributesForElements(in: CGRect(x: 0, y: 202, width: 403, height: 100)))
        XCTAssertEqual(boundaryRow.map(\.indexPath), [
            IndexPath(item: 5, section: 2), IndexPath(item: 0, section: 3),
            IndexPath(item: 1, section: 3), IndexPath(item: 2, section: 3)
        ], "Visible attributes must include both months sharing a row without scanning their photos.")
        XCTAssertTrue((firstRow + boundaryRow).allSatisfy { $0.representedElementCategory == .cell })
    }

    func testUnloadedDayModeKeepsSeparateSectionRows() throws {
        let layout = VirtualPhotoLayout()
        layout.columns = 2
        layout.showsDayHeaders = true
        layout.dayGroups = [[], []]
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), collectionViewLayout: layout)
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        collection.register(UICollectionReusableView.self, forSupplementaryViewOfKind: VirtualPhotoLayout.dayHeaderKind, withReuseIdentifier: "header")
        let dataSource = DataSource(counts: [7, 1])
        collection.dataSource = dataSource
        collection.reloadData()
        collection.layoutIfNeeded()

        let visible = try XCTUnwrap(layout.layoutAttributesForElements(in: CGRect(x: 0, y: 0, width: 300, height: 200)))
        XCTAssertFalse(visible.contains { $0.representedElementCategory == .supplementaryView })
        XCTAssertEqual(try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame.minY, 0)
        XCTAssertEqual(try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))).frame.minY, 150.5, accuracy: 0.1)
        let nextMonth = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1)))
        XCTAssertEqual(nextMonth.frame.minX, 0)
        XCTAssertEqual(nextMonth.frame.minY, 602, accuracy: 0.1)
    }
}

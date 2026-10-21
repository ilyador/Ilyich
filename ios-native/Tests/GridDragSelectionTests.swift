import XCTest
@testable import Ilyich

final class GridDragSelectionTests: XCTestCase {
    /// A selection held as the store holds it, changed only through what the drag asks.
    private struct Grid {
        let counts: [Int]
        var selected: Set<IndexPath>
        var unloaded: Set<IndexPath> = []
        func isSelected(_ index: IndexPath) -> Bool? { unloaded.contains(index) ? nil : selected.contains(index) }
        mutating func apply(_ change: GridDragSelection.Change) {
            selected.subtract(change.deselect); selected.formUnion(change.select)
        }
        mutating func drag(_ drag: inout GridDragSelection, to index: IndexPath) {
            apply(drag.move(to: index, counts: counts, isSelected: isSelected))
        }
    }
    private func at(_ section: Int, _ item: Int) -> IndexPath { IndexPath(item: item, section: section) }
    private func range(_ low: IndexPath, _ high: IndexPath, counts: [Int]) -> Set<IndexPath> {
        var result: Set<IndexPath> = []
        GridDragSelection.walk(low, high, counts: counts) { result.insert($0) }
        return result
    }

    func testADragFromAnUnselectedPhotoSelectsTheWholeRangeNotOnlyTheCellsTouched() {
        var grid = Grid(counts: [20], selected: [])
        var drag = GridDragSelection(anchor: at(0, 2), selects: true)
        grid.drag(&drag, to: at(0, 2))
        XCTAssertEqual(grid.selected, [at(0, 2)])
        // The finger jumps a row down; every photo between is selected.
        grid.drag(&drag, to: at(0, 9))
        XCTAssertEqual(grid.selected, range(at(0, 2), at(0, 9), counts: grid.counts))
    }

    func testMovingBackShrinksTheRangeAndRestoresEarlierState() {
        let before: Set<IndexPath> = [at(0, 5), at(0, 12)]
        var grid = Grid(counts: [20], selected: before)
        var drag = GridDragSelection(anchor: at(0, 3), selects: true)
        grid.drag(&drag, to: at(0, 3))
        grid.drag(&drag, to: at(0, 14))
        XCTAssertEqual(grid.selected, range(at(0, 3), at(0, 14), counts: grid.counts))
        grid.drag(&drag, to: at(0, 6))
        XCTAssertEqual(grid.selected, range(at(0, 3), at(0, 6), counts: grid.counts).union([at(0, 12)]),
                       "Photos the range left go back; the one selected before stays selected.")
        // Back past the anchor: the range now runs the other way.
        grid.drag(&drag, to: at(0, 1))
        XCTAssertEqual(grid.selected, range(at(0, 1), at(0, 3), counts: grid.counts).union(before))
        grid.drag(&drag, to: at(0, 3))
        XCTAssertEqual(grid.selected, before.union([at(0, 3)]))
    }

    func testADragFromASelectedPhotoDeselectsAndRestoresOnTheWayBack() {
        let before = range(at(0, 0), at(0, 15), counts: [20]).subtracting([at(0, 8)])
        var grid = Grid(counts: [20], selected: before)
        var drag = GridDragSelection(anchor: at(0, 4), selects: !grid.selected.contains(at(0, 4)))
        XCTAssertFalse(drag.selects)
        grid.drag(&drag, to: at(0, 4))
        grid.drag(&drag, to: at(0, 10))
        XCTAssertEqual(grid.selected, before.subtracting(range(at(0, 4), at(0, 10), counts: grid.counts)))
        grid.drag(&drag, to: at(0, 7))
        XCTAssertEqual(grid.selected, before.subtracting(range(at(0, 4), at(0, 7), counts: grid.counts)),
                       "The photo that was not selected before stays unselected as the range shrinks past it.")
        XCTAssertFalse(grid.selected.contains(at(0, 8)))
    }

    func testTheRangeCrossesSectionsInReadingOrder() {
        let counts = [3, 0, 4, 5]
        var grid = Grid(counts: counts, selected: [])
        var drag = GridDragSelection(anchor: at(0, 1), selects: true)
        grid.drag(&drag, to: at(0, 1))
        grid.drag(&drag, to: at(3, 1))
        XCTAssertEqual(grid.selected, [at(0, 1), at(0, 2), at(2, 0), at(2, 1), at(2, 2), at(2, 3), at(3, 0), at(3, 1)])
        grid.drag(&drag, to: at(2, 1))
        XCTAssertEqual(grid.selected, [at(0, 1), at(0, 2), at(2, 0), at(2, 1)])
    }

    func testEachMoveTouchesOnlyWhatEnteredOrLeft() {
        var grid = Grid(counts: [10_000], selected: [])
        var drag = GridDragSelection(anchor: at(0, 4), selects: true)
        grid.drag(&drag, to: at(0, 4))
        grid.drag(&drag, to: at(0, 8))
        XCTAssertEqual(grid.selected, range(at(0, 4), at(0, 8), counts: grid.counts))
        var asked = 0
        let change = drag.move(to: at(0, 9), counts: grid.counts) { _ in asked += 1; return false }
        XCTAssertEqual(change.select, [at(0, 9)])
        XCTAssertEqual(asked, 1, "One step asks about the one photo that entered, not the range or the library.")
        XCTAssertTrue(drag.move(to: at(0, 9), counts: grid.counts) { _ in false }.isEmpty)
    }

    func testAPhotoPassedBeforeItsMonthLoadedIsSelectedOnceItLoads() {
        var grid = Grid(counts: [3, 4, 3], selected: [], unloaded: Set((0..<4).map { at(1, $0) }))
        var drag = GridDragSelection(anchor: at(0, 0), selects: true)
        grid.drag(&drag, to: at(0, 0))
        grid.drag(&drag, to: at(2, 1))
        XCTAssertEqual(grid.selected, [at(0, 0), at(0, 1), at(0, 2), at(2, 0), at(2, 1)])
        // An unloaded month costs one question per step, not one per photo.
        var asked = 0
        let unloaded = grid.unloaded
        XCTAssertTrue(drag.move(to: at(2, 1), counts: grid.counts) { index in
            if unloaded.contains(index) { asked += 1; return nil }
            return true
        }.isEmpty)
        XCTAssertEqual(asked, 1)
        // The month loads while the finger stays beyond it.
        grid.unloaded = []
        let loaded = grid
        grid.apply(drag.retry { loaded.isSelected($0) })
        XCTAssertEqual(grid.selected, range(at(0, 0), at(2, 1), counts: grid.counts))
        // And pulling back puts it back.
        grid.drag(&drag, to: at(0, 1))
        XCTAssertEqual(grid.selected, [at(0, 0), at(0, 1)])
    }

    func testADeselectingDragOverAnEvictedMonthDeselectsItOnceItReloads() {
        let counts = [2, 3, 2]
        let all = range(at(0, 0), at(2, 1), counts: counts)
        var grid = Grid(counts: counts, selected: all, unloaded: Set((0..<3).map { at(1, $0) }))
        var drag = GridDragSelection(anchor: at(0, 0), selects: false)
        grid.drag(&drag, to: at(0, 0))
        grid.drag(&drag, to: at(2, 1))
        XCTAssertEqual(grid.selected, Set((0..<3).map { at(1, $0) }), "The evicted month waits, still selected.")
        grid.unloaded = []
        grid.drag(&drag, to: at(2, 1))
        XCTAssertTrue(grid.selected.isEmpty, "Once it reloads, the sweep deselects it too.")
    }

    func testLeavingThePhotosOfAMonthStillLoadingForgetsThem() {
        var grid = Grid(counts: [2, 3, 2], selected: [], unloaded: Set((0..<3).map { at(1, $0) }))
        var drag = GridDragSelection(anchor: at(0, 0), selects: true)
        grid.drag(&drag, to: at(0, 0))
        grid.drag(&drag, to: at(2, 0))
        grid.drag(&drag, to: at(0, 1))
        XCTAssertTrue(drag.pending.isEmpty)
        grid.unloaded = []
        let loaded = grid
        grid.apply(drag.retry { loaded.isSelected($0) })
        XCTAssertEqual(grid.selected, [at(0, 0), at(0, 1)], "A month the range has left is not selected when it loads.")
    }

    func testTheEdgeScrollsFasterTheDeeperTheFingerIsAndNotInTheMiddle() {
        let top: CGFloat = 100, bottom: CGFloat = 800
        XCTAssertEqual(GridDragSelector.edgeVelocity(fingerY: 450, visibleTop: top, visibleBottom: bottom), 0)
        let shallow = GridDragSelector.edgeVelocity(fingerY: bottom - 20, visibleTop: top, visibleBottom: bottom)
        let deep = GridDragSelector.edgeVelocity(fingerY: bottom + 30, visibleTop: top, visibleBottom: bottom)
        XCTAssertGreaterThan(shallow, 0)
        XCTAssertGreaterThan(deep, shallow)
        XCTAssertEqual(deep, GridDragSelector.maximumSpeed)
        XCTAssertLessThan(GridDragSelector.edgeVelocity(fingerY: top + 10, visibleTop: top, visibleBottom: bottom), 0)
    }
}

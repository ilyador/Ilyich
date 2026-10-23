import XCTest
@testable import Ilyich

final class LibraryEdgeInteractionTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 759)

    func testShelfUnderFingerGetsLongestWidthAsFingerMovesInBothDirections() {
        let layout = LibraryShelfGeometry(count: 5, size: phone, topInset: 88, bottomInset: 100, top: 300)
        for focus in [0, 4, 2, 1, 3] {
            let y = layout.center(focus)
            XCTAssertEqual(layout.row(at: CGPoint(x: 20, y: y)), focus)
            XCTAssertEqual(layout.width(focus, fingerY: y), layout.maximumWidth, accuracy: 0.001)
            for other in 0..<5 where other != focus {
                XCTAssertLessThan(layout.width(other, fingerY: y), layout.width(focus, fingerY: y))
            }
        }
    }

    func testTheFocusedRowIsTallerAndKeepsClearGapsWhileOuterRowsMerge() {
        let layout = LibraryShelfGeometry(count: 11, size: CGSize(width: 393, height: 900), topInset: 80, bottomInset: 100, top: 180, rowStep: 60)
        let y = layout.center(5)
        XCTAssertEqual(layout.height(5, fingerY: y) / 50, 1.3, accuracy: 0.01, "The focused row is about 30% taller than before.")
        for row in [3, 4, 6, 7] {
            XCTAssertEqual(layout.height(row, fingerY: y), 56 - 6 * layout.focusStrength(row, fingerY: y), accuracy: 0.001,
                           "Only the focused row grows; the rest keep their previous size.")
        }
        func gap(_ a: Int, _ b: Int) -> CGFloat {
            (layout.center(b) + layout.shift(b, fingerY: y) - layout.height(b, fingerY: y) / 2)
                - (layout.center(a) + layout.shift(a, fingerY: y) + layout.height(a, fingerY: y) / 2)
        }
        XCTAssertGreaterThan(gap(5, 6), 8, "Clear gaps around the focus.")
        XCTAssertGreaterThan(gap(4, 5), 8)
        XCTAssertLessThan(gap(9, 10), 6, "Outer rows nearly touch, so their glass merges.")
        XCTAssertEqual(layout.shift(5, fingerY: y), 0, accuracy: 0.5, "The focused row stays under the finger.")
    }

    @MainActor func testTheCurrentRowHoldsUntilTheFingerIsWellPastIt() {
        var layout = LibraryShelfGeometry(count: 40, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        layout.top = layout.top(placing: 10, at: 400)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.beginStroke(at: CGPoint(x: 60, y: 400))
        _ = interaction.moveStroke(to: CGPoint(x: 60, y: 400), in: layout, nested: true)
        XCTAssertEqual(interaction.highlighted, 10)
        _ = interaction.moveStroke(to: CGPoint(x: 60, y: 400 + layout.step * 0.53), in: layout, nested: true)
        XCTAssertEqual(interaction.highlighted, 10, "Just past the row's edge it still holds, lightly.")
        _ = interaction.moveStroke(to: CGPoint(x: 60, y: 400 + layout.step * 0.62), in: layout, nested: true)
        XCTAssertEqual(interaction.highlighted, 11, "A little further the next row takes over, one row at a time.")
        // The wave leans toward the row near its center and lets go before the hand-over.
        let step = layout.step, center: CGFloat = 400
        XCTAssertEqual(LibraryShelfGeometry.detent(center + step * 0.1, toward: center, step: step), center + step * 0.1, accuracy: step * 0.06)
        XCTAssertLessThan(LibraryShelfGeometry.detent(center + step * 0.2, toward: center, step: step), center + step * 0.2, "Near the center it leans in.")
        let edge = step * (0.5 - LibraryShelfGeometry.rowLock)
        XCTAssertEqual(LibraryShelfGeometry.detent(center + edge, toward: center, step: step), center + edge, accuracy: 0.001,
                       "At the hand-over it follows the finger exactly, so nothing jumps.")
        interaction.endStroke()
    }

    @MainActor func testASidewaysPushHoldsItsRowWhileTheThumbDrifts() async throws {
        var layout = LibraryShelfGeometry(count: 40, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        layout.top = layout.top(placing: 10, at: 400)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.beginStroke(at: CGPoint(x: 60, y: 400))
        _ = interaction.moveStroke(to: CGPoint(x: 60, y: 400), in: layout, nested: true)
        XCTAssertEqual(interaction.highlighted, 10)
        // The thumb pushes toward the tip in an arc, drifting well past the row's edge.
        var x: CGFloat = 60, y: CGFloat = 400
        while x < layout.maximumWidth - 10 {
            x += 12; y += 2.7
            _ = interaction.moveStroke(to: CGPoint(x: x, y: y), in: layout, nested: true)
        }
        XCTAssertGreaterThan(y - 400, layout.step / 2, "The finger ends past the row's edge.")
        XCTAssertEqual(interaction.highlighted, 10, "The pushed row stays chosen while the thumb drifts.")
        XCTAssertEqual(interaction.selectionHold, 10)
        XCTAssertGreaterThan(interaction.tipNearness, 0.5)
        try await Task.sleep(for: .seconds(0.9))
        XCTAssertEqual(interaction.openReady, 10, "Its selection keeps building and opens it.")
        interaction.endStroke()
        XCTAssertNil(interaction.selectionHold)
    }

    @MainActor func testAHeldRowLetsGoARowAway() {
        var layout = LibraryShelfGeometry(count: 40, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        layout.top = layout.top(placing: 10, at: 400)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.beginStroke(at: CGPoint(x: 150, y: 330))
        for y: CGFloat in stride(from: 340, through: 400, by: 10) {
            _ = interaction.moveStroke(to: CGPoint(x: 150, y: y), in: layout, nested: true)
        }
        XCTAssertNil(interaction.selectionHold, "Sliding up and down never takes hold, even out by the tips.")
        interaction.endStroke()

        interaction.shelfTop = layout.top
        interaction.beginStroke(at: CGPoint(x: 60, y: 400))
        for x: CGFloat in [60, 80, 100, 120, 150] {
            _ = interaction.moveStroke(to: CGPoint(x: x, y: 400), in: layout, nested: true)
        }
        XCTAssertEqual(interaction.selectionHold, 10, "Pushing toward the tip takes hold of the row.")
        _ = interaction.moveStroke(to: CGPoint(x: 150, y: 420), in: layout, nested: true)
        XCTAssertEqual(interaction.highlighted, 10)
        _ = interaction.moveStroke(to: CGPoint(x: 150, y: 470), in: layout, nested: true)
        XCTAssertNil(interaction.selectionHold, "A row away it lets go.")
        XCTAssertEqual(interaction.highlighted, 11)
        XCTAssertEqual(interaction.shelfTop, layout.top, "The rows stand still under the finger throughout.")
        interaction.endStroke()
    }

    func testShelfRestingWidthsAreEqualAndFocusBumpIsLocal() {
        let layout = LibraryShelfGeometry(count: 11, size: CGSize(width: 393, height: 900), topInset: 80, bottomInset: 100, top: 180)
        let resting = (0..<layout.count).map { layout.width($0, fingerY: nil) }
        XCTAssertTrue(resting.allSatisfy { abs($0 - layout.restingWidth) < 0.001 })

        let focus = 5
        let fingerY = layout.center(focus)
        XCTAssertEqual(layout.width(focus, fingerY: fingerY), layout.maximumWidth, accuracy: 0.001)
        XCTAssertGreaterThan(layout.width(focus - 1, fingerY: fingerY), layout.maximumWidth * 0.75,
                             "The neighboring shelf should soften the bump instead of forming a sharp point.")
        XCTAssertLessThan(layout.width(focus - 1, fingerY: fingerY), layout.width(focus, fingerY: fingerY))
        XCTAssertGreaterThan(layout.width(focus + 1, fingerY: fingerY), layout.restingWidth)
        XCTAssertEqual(layout.width(focus - 4, fingerY: fingerY), layout.restingWidth, accuracy: 0.001)
        XCTAssertEqual(layout.width(focus + 4, fingerY: fingerY), layout.restingWidth, accuracy: 0.001)
    }

    func testPopOutLeadsWithTheFocusedRowAndEndsFullyOpen() {
        let layout = LibraryShelfGeometry(count: 9, size: CGSize(width: 393, height: 900), topInset: 80, bottomInset: 100, top: 180)
        let fingerY = layout.center(4)
        XCTAssertGreaterThan(layout.revealProgress(4, fingerY: fingerY, reveal: 0.5), layout.revealProgress(3, fingerY: fingerY, reveal: 0.5))
        XCTAssertGreaterThan(layout.revealProgress(3, fingerY: fingerY, reveal: 0.5), layout.revealProgress(0, fingerY: fingerY, reveal: 0.5))
        XCTAssertEqual(layout.horizontalOffset(4, fingerY: fingerY, reveal: 0),
                       layout.horizontalOffset(0, fingerY: fingerY, reveal: 0), accuracy: 0.001)
        for index in 0..<layout.count {
            XCTAssertEqual(layout.horizontalOffset(index, fingerY: fingerY, reveal: 1), 0, accuracy: 0.001)
        }
    }

    func testShelvesOpenWithAQuarterOfTheRowsAboveTheFinger() {
        XCTAssertEqual(LibraryShelfGeometry(count: 5, size: phone, topInset: 88, bottomInset: 100).openingRow, 1,
                       "The top shelves open on their second row, with one above the finger.")
        let people = LibraryShelfGeometry(count: 147, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        XCTAssertGreaterThanOrEqual(people.openingRow, 2, "A long list keeps a few rows above the finger.")
        XCTAssertLessThanOrEqual(people.openingRow, 3, "It still opens near its top, not deep in the list.")
        XCTAssertEqual(LibraryShelfGeometry(count: 1, size: phone, topInset: 88, bottomInset: 100).openingRow, 0)
    }

    func testShelvesOpenAtTheFingerAndStayOnScreenNearEitherEdge() {
        let layout = LibraryShelfGeometry(count: 5, size: phone, topInset: 88, bottomInset: 100)
        XCTAssertEqual(layout.top(placing: 0, at: 300), 300, "The first shelf should come up under the finger.")
        for y: CGFloat in [0, 200, 420, 759] {
            var placed = layout
            placed.top = layout.top(placing: 0, at: y)
            XCTAssertGreaterThanOrEqual(placed.center(0) - 26, 88)
            XCTAssertLessThanOrEqual(placed.center(4) + 26, 759 - 100)
        }
        var low = layout
        low.top = layout.top(placing: 0, at: 650)
        XCTAssertEqual(low.row(at: CGPoint(x: 10, y: 650)), 4, "Near the bottom the shelves rise so every row stays visible.")
    }

    @MainActor func testAShelfThatFitsHoldsStillWhileTheFingerMoves() async throws {
        var layout = LibraryShelfGeometry(count: 5, size: phone, topInset: 88, bottomInset: 100)
        layout.top = layout.top(placing: 0, at: 300)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.beginStroke(at: CGPoint(x: 60, y: 300))
        for y: CGFloat in [0, 120, 290, 333, 480, 700] {
            XCTAssertEqual(layout.scrollVelocity(fingerY: y), 0)
            _ = interaction.moveStroke(to: CGPoint(x: 60, y: y), in: layout, nested: false)
        }
        try await Task.sleep(for: .seconds(0.2))
        XCTAssertEqual(interaction.shelfTop, layout.top, accuracy: 0.001, "Even by the screen's end, a list that fits stays put.")
        interaction.endStroke()
        XCTAssertEqual(layout.row(at: CGPoint(x: 12, y: layout.center(3) + 20)), 3)
        XCTAssertNil(layout.row(at: CGPoint(x: 12, y: layout.center(0) - 40)), "Above the first shelf nothing is chosen.")
        XCTAssertNil(layout.row(at: CGPoint(x: 12, y: layout.center(4) + 40)), "Below the last shelf nothing is chosen.")
        XCTAssertNil(layout.row(at: CGPoint(x: 380, y: layout.center(2))), "Far right of the fan nothing is chosen.")
    }

    /// Selection and scrolling are separate: away from the band's ends the rows stand still, so
    /// the finger moves one row per row height at the top of a long list and at its bottom alike.
    @MainActor func testALongShelfMovesOneRowPerRowHeightAtItsTopAndItsBottom() {
        var layout = LibraryShelfGeometry(count: 147, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        let ends = layout.scrollRange
        for top in [ends.upperBound, (ends.lowerBound + ends.upperBound) / 2, ends.lowerBound] {
            layout.top = top
            let interaction = LibraryEdgeInteraction()
            interaction.shelfTop = top
            let first = layout.row(atY: 220)!
            let start = layout.center(first)
            interaction.beginStroke(at: CGPoint(x: 60, y: start))
            _ = interaction.moveStroke(to: CGPoint(x: 60, y: start), in: layout, nested: true)
            for rows in 1...5 {
                let y = start + CGFloat(rows) * layout.step
                for nudge in stride(from: y - layout.step + 4, through: y, by: 4) {
                    _ = interaction.moveStroke(to: CGPoint(x: 60, y: nudge), in: layout, nested: true)
                }
                XCTAssertEqual(interaction.highlighted, first + rows, "One row per row height, wherever the list is.")
            }
            XCTAssertEqual(interaction.shelfTop, top, "The rows stand still under the finger.")
            interaction.endStroke()
        }
    }

    func testALongListScrollsOnlyNearTheBandsEndsAndFasterFurtherOut() {
        let people = LibraryShelfGeometry(count: 147, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        let inset = LibraryShelfGeometry.scrollZoneInset
        for y in stride(from: people.minCenter + people.step * inset, through: people.maxCenter - people.step * inset, by: 10) {
            XCTAssertEqual(people.scrollVelocity(fingerY: y), 0, "Away from the ends the rows stand still.")
        }
        let shallow = people.scrollVelocity(fingerY: people.maxCenter)
        let deep = people.scrollVelocity(fingerY: people.maxCenter + people.step * 1.5)
        XCTAssertLessThan(shallow, 0, "Near the bottom the list moves up, bringing the rows below.")
        XCTAssertLessThan(shallow, -people.step, "It moves as soon as the finger is there, if slowly.")
        XCTAssertLessThan(deep, shallow * 4, "Further out it scrolls much faster.")
        XCTAssertEqual(people.scrollVelocity(fingerY: people.maxCenter + people.step * 5),
                       -LibraryShelfGeometry.scrollRates.upperBound * people.step, accuracy: 0.001, "Its speed tops out.")
        XCTAssertGreaterThan(people.scrollVelocity(fingerY: people.minCenter), 0, "Near the top it moves down, bringing the rows above.")
        let depthOneRowOut = (1 + inset) / LibraryShelfGeometry.scrollZoneLength
        XCTAssertEqual(people.scrollVelocity(fingerY: people.maxCenter + people.step, bottomFloor: 0.4),
                       -LibraryShelfGeometry.scrollRate(depthOneRowOut - 0.4) * people.step, accuracy: 0.001,
                       "A stroke that began deep in the zone counts only how much further it goes.")
        // Rows pass the finger at the same pace, whatever their height.
        let albums = LibraryShelfGeometry(count: 147, size: phone, topInset: 56, bottomInset: 100, rowStep: 44)
        XCTAssertEqual(albums.scrollVelocity(fingerY: albums.maxCenter + 44) / 44,
                       people.scrollVelocity(fingerY: people.maxCenter + 60) / 60, accuracy: 0.001)
    }

    @MainActor func testHoldingTheFingerNearTheBottomScrollsALongListUntilItMovesBack() async throws {
        var layout = LibraryShelfGeometry(count: 147, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        layout.top = layout.scrollRange.upperBound
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.beginStroke(at: CGPoint(x: 80, y: 300))
        let low = layout.maxCenter + layout.step * 0.25
        for y in stride(from: CGFloat(300), through: low, by: 10) {
            _ = interaction.moveStroke(to: CGPoint(x: 80, y: y), in: layout, nested: true)
        }
        _ = interaction.moveStroke(to: CGPoint(x: 80, y: low), in: layout, nested: true)
        let reached = try XCTUnwrap(interaction.highlighted)
        var previous = reached
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(50))
            let row = try XCTUnwrap(interaction.highlighted, "The highlight never blinks off as rows scroll in.")
            XCTAssertGreaterThanOrEqual(row, previous, "Rows are highlighted in turn, the way the list goes.")
            previous = row
        }
        XCTAssertLessThan(interaction.shelfTop, layout.top - layout.step * 2, "Held near the bottom, the list scrolls on by itself.")
        XCTAssertGreaterThanOrEqual(previous, reached + 2, "Rows pass under the still finger, highlighted in turn.")
        _ = interaction.moveStroke(to: CGPoint(x: 80, y: 400), in: layout, nested: true)
        let stopped = interaction.shelfTop
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(interaction.shelfTop, stopped, "Back toward the middle the list stops.")
        interaction.endStroke()
    }

    func testPastTheBandsEndsALongListPicksItsOutermostRowInView() throws {
        var layout = LibraryShelfGeometry(count: 147, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        for offset in stride(from: CGFloat(0), to: layout.step, by: 3) {
            layout.top = layout.minCenter - 600 - offset
            for y in [layout.maxCenter, layout.maxCenter + 15, layout.maxCenter + 60, 759] {
                let row = try XCTUnwrap(layout.pickedRow(atY: y), "Rows scrolling in under the finger never leave it blank.")
                XCTAssertGreaterThan(layout.visibility(row), 0.5, "The picked row is at least half in view.")
                XCTAssertGreaterThan(layout.center(row), layout.maxCenter - layout.step, "It is the outermost one.")
            }
            for y in [layout.minCenter, layout.minCenter - 40, 0] {
                let row = try XCTUnwrap(layout.pickedRow(atY: y))
                XCTAssertGreaterThan(layout.visibility(row), 0.5)
                XCTAssertLessThan(layout.center(row), layout.minCenter + layout.step)
            }
        }
        var fits = LibraryShelfGeometry(count: 5, size: phone, topInset: 88, bottomInset: 100)
        fits.top = fits.top(placing: 0, at: 300)
        XCTAssertNil(fits.pickedRow(atY: fits.center(4) + 40), "Below a list that fits, nothing is picked.")
    }

    @MainActor func testASidewaysPushCatchesAPassingRowAndTheListWaits() async throws {
        var layout = LibraryShelfGeometry(count: 147, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        layout.top = layout.scrollRange.upperBound
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.beginStroke(at: CGPoint(x: 80, y: 300))
        let low = layout.maxCenter + layout.step * 0.25
        for y in stride(from: CGFloat(300), through: low, by: 10) {
            _ = interaction.moveStroke(to: CGPoint(x: 80, y: y), in: layout, nested: true)
        }
        _ = interaction.moveStroke(to: CGPoint(x: 80, y: low), in: layout, nested: true)
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertLessThan(interaction.shelfTop, layout.top, "The list scrolls under the finger.")
        for x: CGFloat in [96, 104, 112, 120] {
            _ = interaction.moveStroke(to: CGPoint(x: x, y: low), in: layout, nested: true)
        }
        let caught = try XCTUnwrap(interaction.highlighted)
        XCTAssertEqual(interaction.selectionHold, caught, "A sideways push takes hold of the row passing under the finger.")
        let held = interaction.shelfTop
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(interaction.shelfTop, held, "While a row is held the list waits.")
        XCTAssertEqual(interaction.highlighted, caught)
        interaction.endStroke()
    }

    @MainActor func testAListOpenedUnderAFingerNearItsEndWaitsForTheFingerToGoFurther() async throws {
        var layout = LibraryShelfGeometry(count: 147, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        let low = layout.maxCenter + layout.step * 0.3
        layout.top = layout.top(placing: 3, at: low)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.rebase(at: CGPoint(x: 200, y: low), armed: true, in: layout)
        _ = interaction.moveStroke(to: CGPoint(x: 196, y: low - 4), in: layout, nested: true)
        _ = interaction.moveStroke(to: CGPoint(x: 192, y: low), in: layout, nested: true)
        try await Task.sleep(for: .seconds(0.4))
        XCTAssertEqual(interaction.shelfTop, layout.top, "A group opened low down does not run off by itself.")
        _ = interaction.moveStroke(to: CGPoint(x: 192, y: low + layout.step * 0.6), in: layout, nested: true)
        try await Task.sleep(for: .seconds(0.4))
        XCTAssertLessThan(interaction.shelfTop, layout.top, "Going further down scrolls it.")
        interaction.endStroke()
    }

    @MainActor func testHoldingNearTheTopScrollsBackAndStopsAtTheFirstRow() async throws {
        var layout = LibraryShelfGeometry(count: 30, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        layout.top = layout.top(placing: 12, at: 400)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.beginStroke(at: CGPoint(x: 80, y: 400))
        for y in stride(from: CGFloat(400), through: 0, by: -10) {
            _ = interaction.moveStroke(to: CGPoint(x: 80, y: y), in: layout, nested: true)
        }
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(interaction.shelfTop, layout.scrollRange.upperBound, accuracy: 0.001, "It stops with the first row at the top.")
        interaction.endStroke()
    }

    func testALongShelfOpenedFromTheTopKeepsNeighborsVisible() {
        var layout = LibraryShelfGeometry(count: 40, size: phone, topInset: 144, bottomInset: 100, rowStep: 60)
        layout.top = layout.top(placing: 12, at: 110)
        XCTAssertEqual(layout.center(12), layout.minCenter + 120, accuracy: 0.001)
        XCTAssertEqual(layout.row(at: CGPoint(x: 12, y: layout.minCenter)), 10)
    }

    func testALongShelfFillsTheScreenInsteadOfHangingBelowTheFinger() {
        var layout = LibraryShelfGeometry(count: 9, size: phone, topInset: 148, bottomInset: 100, rowStep: 60)
        XCTAssertFalse(layout.fits)
        layout.top = layout.top(placing: 0, at: 430)
        XCTAssertEqual(layout.top, layout.minCenter, accuracy: 0.001)
        XCTAssertEqual(layout.visibility(6), 1, "Rows that fit on screen must be reachable without a drag.")
    }

    func testTheTipGlowBuildsWhileTheFingerStaysAndFallsAwayWhenItLeaves() {
        let tip: CGFloat = 244
        XCTAssertEqual(LibraryShelfGeometry.tipNearness(fingerX: 100, tip: tip), 0, "Away from the tip there is no glow.")
        XCTAssertEqual(LibraryShelfGeometry.tipNearness(fingerX: tip * 0.52, tip: tip), 0,
                       "The zone that opens a group begins just past the row's middle (the owner's setting).")
        XCTAssertGreaterThan(LibraryShelfGeometry.tipNearness(fingerX: tip * 0.56, tip: tip), 0, "Past its start the glow builds.")
        XCTAssertEqual(LibraryShelfGeometry.tipNearness(fingerX: tip, tip: tip), 1)
        func timeToPeak(nearness: CGFloat) -> CGFloat {
            var glow: CGFloat = 0, time: CGFloat = 0
            while glow < 1 && time < 3 { glow = LibraryShelfGeometry.nextGlow(glow, nearness: nearness, building: true, seconds: 1 / 60); time += 1 / 60 }
            return time
        }
        XCTAssertGreaterThan(timeToPeak(nearness: 1), 0.25, "The glow builds; it does not snap open.")
        XCTAssertLessThan(timeToPeak(nearness: 1), 0.45, "Holding by the tip opens the row in about a third of a second.")
        XCTAssertLessThan(timeToPeak(nearness: 0), 0.75, "Holding at the zone's start still opens, a little slower.")
        var back: CGFloat = 0, backTime: CGFloat = 0
        while back < 1 && backTime < 3 { back = LibraryShelfGeometry.nextBackGlow(back, building: true, seconds: 1 / 60); backTime += 1 / 60 }
        XCTAssertEqual(backTime / timeToPeak(nearness: 1), 0.7, accuracy: 0.06, "Going back at the edge takes about 30% less than opening a row by its tip.")
        var early: CGFloat = 0
        for _ in 0..<6 { early = LibraryShelfGeometry.nextGlow(early, nearness: 1, building: true, seconds: 1 / 60) }
        var late: CGFloat = 0.7
        for _ in 0..<6 { late = LibraryShelfGeometry.nextGlow(late, nearness: 1, building: true, seconds: 1 / 60) }
        XCTAssertGreaterThan(late - 0.7, early, "It builds faster as it nears its peak.")
        var fading: CGFloat = 0.9
        for _ in 0..<18 { fading = LibraryShelfGeometry.nextGlow(fading, nearness: 1, building: false, seconds: 1 / 60) }
        XCTAssertEqual(fading, 0, "Moving back lets it fall away completely.")
    }

    @MainActor func testStayingByARowsTipOpensItAndTheEdgeGoesBack() async throws {
        var layout = LibraryShelfGeometry(count: 5, size: phone, topInset: 88, bottomInset: 100)
        layout.top = layout.top(placing: 0, at: 300)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.beginStroke(at: CGPoint(x: 8, y: 300))
        _ = interaction.moveStroke(to: CGPoint(x: 20, y: layout.center(2)), in: layout, nested: false)
        XCTAssertEqual(interaction.highlighted, 2)
        _ = interaction.moveStroke(to: CGPoint(x: layout.maximumWidth, y: layout.center(2)), in: layout, nested: false)
        XCTAssertGreaterThan(interaction.tipNearness, 0.9)
        XCTAssertNil(interaction.openReady, "Reaching the tip alone opens nothing; the glow has to build.")
        try await Task.sleep(for: .seconds(0.9))
        XCTAssertEqual(interaction.openReady, 2, "Staying by the tip opens the row at the glow's peak.")
        interaction.openReady = nil

        _ = interaction.moveStroke(to: CGPoint(x: 60, y: layout.center(3)), in: layout, nested: false)
        _ = interaction.moveStroke(to: CGPoint(x: layout.maximumWidth, y: layout.center(3)), in: layout, nested: false)
        try await Task.sleep(for: .seconds(0.2))
        _ = interaction.moveStroke(to: CGPoint(x: 80, y: layout.center(3)), in: layout, nested: false)
        try await Task.sleep(for: .seconds(0.8))
        XCTAssertNil(interaction.openReady, "Moving back lets the glow fall away without opening.")
        XCTAssertEqual(interaction.openProgress, 0)

        // The group that opened continues under the same finger.
        interaction.rebase(at: CGPoint(x: layout.maximumWidth, y: layout.center(2)), armed: true, in: layout)
        XCTAssertEqual(interaction.highlighted, 2, "Whatever is under the finger is already highlighted.")
        _ = interaction.moveStroke(to: CGPoint(x: layout.maximumWidth + 4, y: layout.center(3)), in: layout, nested: true)
        XCTAssertEqual(interaction.highlighted, 3)
        try await Task.sleep(for: .seconds(0.8))
        XCTAssertNil(interaction.openReady, "Sliding along near the tips highlights without opening.")
        XCTAssertEqual(interaction.moveStroke(to: CGPoint(x: 10, y: layout.center(3)), in: layout, nested: true), .none,
                       "Reaching the left edge alone goes nowhere; its glow has to build.")
        XCTAssertFalse(interaction.backReady)
        try await Task.sleep(for: .seconds(0.7))
        XCTAssertTrue(interaction.backReady, "Inside a group, staying at the left edge goes back at the glow's peak.")
        interaction.backReady = false
        _ = interaction.moveStroke(to: CGPoint(x: 8, y: layout.center(3)), in: layout, nested: true)
        try await Task.sleep(for: .seconds(0.7))
        XCTAssertFalse(interaction.backReady, "Going back happens once; the finger has to move in again.")
        XCTAssertEqual(interaction.backProgress, 0)

        // Moving in before the peak lets the edge's glow fall away without going back.
        _ = interaction.moveStroke(to: CGPoint(x: 60, y: layout.center(3)), in: layout, nested: true)
        _ = interaction.moveStroke(to: CGPoint(x: 10, y: layout.center(3)), in: layout, nested: true)
        try await Task.sleep(for: .seconds(0.1))
        XCTAssertGreaterThan(interaction.backProgress, 0, "The glow builds while the finger stays at the edge.")
        _ = interaction.moveStroke(to: CGPoint(x: 60, y: layout.center(3)), in: layout, nested: true)
        try await Task.sleep(for: .seconds(0.7))
        XCTAssertFalse(interaction.backReady, "Moving in lets it fall away without going back.")
        XCTAssertEqual(interaction.backProgress, 0)

        // Back at the top level, the same stroke can open a group again straight away.
        interaction.openReady = nil
        interaction.rebase(at: CGPoint(x: 10, y: layout.center(1)), armed: false, in: layout, needsReturn: false)
        _ = interaction.moveStroke(to: CGPoint(x: layout.maximumWidth, y: layout.center(1)), in: layout, nested: false)
        try await Task.sleep(for: .seconds(0.9))
        XCTAssertEqual(interaction.openReady, 1, "After going back, pushing along a row opens it again.")

        // In a group just opened, another row opens straight away when pushed.
        interaction.openReady = nil
        interaction.rebase(at: CGPoint(x: layout.maximumWidth * 0.7, y: layout.center(1)), armed: true, in: layout)
        _ = interaction.moveStroke(to: CGPoint(x: 70, y: layout.center(2)), in: layout, nested: true, reorder: true)
        _ = interaction.moveStroke(to: CGPoint(x: layout.maximumWidth - 30, y: layout.center(2)), in: layout, nested: true, reorder: true)
        try await Task.sleep(for: .seconds(1.0))
        XCTAssertEqual(interaction.openReady, 2, "Items stay selectable after a group reopens.")
        interaction.endStroke()
    }

    @MainActor func testInsideAGroupTheRowNearTheEdgeHintsBeforeGoingBack() {
        var layout = LibraryShelfGeometry(count: 5, size: phone, topInset: 88, bottomInset: 100)
        layout.top = layout.top(placing: 0, at: 300)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.rebase(at: CGPoint(x: 120, y: layout.center(2)), armed: true, in: layout)
        _ = interaction.moveStroke(to: CGPoint(x: 100, y: layout.center(2)), in: layout, nested: true)
        XCTAssertEqual(interaction.edgeNearness, 0, "Away from the edge there is no hint.")
        XCTAssertNil(interaction.backRow)
        _ = interaction.moveStroke(to: CGPoint(x: 40, y: layout.center(2)), in: layout, nested: true)
        XCTAssertGreaterThan(interaction.edgeNearness, 0, "Nearing the edge hints at going back.")
        XCTAssertEqual(interaction.backRow, 2, "The hint sits in the row under the finger.")
        _ = interaction.moveStroke(to: CGPoint(x: 40, y: layout.center(2)), in: layout, nested: false)
        XCTAssertEqual(interaction.edgeNearness, 0, "At the top level the edge puts the shelves away instead.")
        XCTAssertNil(interaction.backRow)
        interaction.endStroke()
    }

    @MainActor func testTheRowAlreadySelectedNeverActivates() async throws {
        var layout = LibraryShelfGeometry(count: 5, size: phone, topInset: 88, bottomInset: 100)
        layout.top = layout.top(placing: 0, at: 300)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.beginStroke(at: CGPoint(x: 20, y: layout.center(2)))
        _ = interaction.moveStroke(to: CGPoint(x: 30, y: layout.center(2)), in: layout, nested: true, selected: 2)
        _ = interaction.moveStroke(to: CGPoint(x: layout.maximumWidth - 10, y: layout.center(2)), in: layout, nested: true, selected: 2)
        try await Task.sleep(for: .seconds(0.8))
        XCTAssertNil(interaction.openReady, "The selected row does not activate again.")
        XCTAssertEqual(interaction.openProgress, 0)
        interaction.endStroke()
    }

    @MainActor func testPastTheTipTheRowStaysFocusedAndTheReorderButtonTakesTheLift() async throws {
        var layout = LibraryShelfGeometry(count: 5, size: phone, topInset: 88, bottomInset: 100)
        layout.top = layout.top(placing: 0, at: 300)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.beginStroke(at: CGPoint(x: 20, y: 300))
        _ = interaction.moveStroke(to: CGPoint(x: 30, y: 300), in: layout, nested: true, reorder: true)
        _ = interaction.moveStroke(to: CGPoint(x: layout.maximumWidth + 30, y: 300), in: layout, nested: true, reorder: true)
        XCTAssertEqual(interaction.highlighted, 0, "Past the row's right edge it stays focused.")
        XCTAssertEqual(interaction.tipNearness, 0)
        try await Task.sleep(for: .seconds(0.8))
        XCTAssertNil(interaction.openReady, "Past the right edge the row's activation ends.")
        let button = LibraryShelfGeometry.reorderButtonCenter(tip: layout.maximumWidth, rowCenter: layout.center(0))
        _ = interaction.moveStroke(to: CGPoint(x: button.x + 20, y: button.y + 30), in: layout, nested: true, reorder: true)
        XCTAssertTrue(interaction.overReorder, "The button reaches about a row's height around it.")
        _ = interaction.moveStroke(to: CGPoint(x: button.x + 90, y: button.y), in: layout, nested: true, reorder: true)
        XCTAssertFalse(interaction.overReorder)
        _ = interaction.moveStroke(to: CGPoint(x: layout.maximumWidth - 10, y: 300), in: layout, nested: true, reorder: true)
        XCTAssertFalse(interaction.overReorder, "Inside the row is the row's own activation, not the button.")
        _ = interaction.moveStroke(to: button, in: layout, nested: true, reorder: false)
        XCTAssertFalse(interaction.overReorder, "Only People and Albums offer the button.")
        interaction.endStroke()
    }

    @MainActor func testReorderingScrollsLikeANormalList() {
        var layout = LibraryShelfGeometry(count: 40, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        layout.top = layout.top(placing: 10, at: 400)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.isRearranging = true
        interaction.beginRearrangeStroke(at: CGPoint(x: 160, y: 400), in: layout)
        _ = interaction.moveRearrangeStroke(to: CGPoint(x: 160, y: 460), in: layout)
        XCTAssertEqual(interaction.shelfTop, layout.top + 60, accuracy: 0.001, "Dragging down moves the rows down with the finger.")
        // Pulled 200 points past its first row, the list stretches as a scroll view does.
        _ = interaction.moveRearrangeStroke(to: CGPoint(x: 160, y: 400 + layout.minCenter - layout.top + 200), in: layout)
        let stretch = interaction.shelfTop - layout.minCenter
        XCTAssertGreaterThan(stretch, 50, "Past its first row the list stretches.")
        XCTAssertLessThan(stretch, 100, "It stretches less than the finger moves.")
        XCTAssertEqual(layout.unbandedTop(interaction.shelfTop), layout.minCenter + 200, accuracy: 0.01)
        interaction.endStroke()
    }

    func testAFlickedListCoastsAndSlowsToAStopLikeAScrollView() {
        var momentum = LibraryShelfMomentum(top: 0, velocity: -1000, range: -5000...200)
        var speed = abs(momentum.velocity), frames = 0
        while momentum.step(1.0 / 120), frames < 2000 {
            XCTAssertLessThanOrEqual(abs(momentum.velocity), speed, "It only slows down.")
            speed = abs(momentum.velocity); frames += 1
        }
        // A scroll view's normal deceleration carries a flick about half its speed, in points.
        XCTAssertEqual(momentum.top, -492, accuracy: 10)
        XCTAssertLessThan(frames, 120 * 3, "It comes to rest within a few seconds.")
    }

    func testAListLetGoPastItsEndSpringsBackWithoutBouncing() {
        var momentum = LibraryShelfMomentum(top: 260, velocity: 300, range: -800...200)
        var frames = 0
        while momentum.step(1.0 / 120), frames < 2000 {
            XCTAssertGreaterThan(momentum.top, 199.5, "It returns to its end without running past it.")
            XCTAssertLessThanOrEqual(momentum.top, 260, "A flick farther out does not stretch it more.")
            frames += 1
        }
        XCTAssertEqual(momentum.top, 200, accuracy: 0.001)
        XCTAssertLessThan(frames, 120, "It is back in under a second.")
    }

    func testAListCoastingPastItsEndRunsOnALittleAndComesBack() {
        var momentum = LibraryShelfMomentum(top: 100, velocity: 2000, range: -800...200)
        var farthest: CGFloat = 100, frames = 0
        while momentum.step(1.0 / 60), frames < 2000 { farthest = max(farthest, momentum.top); frames += 1 }
        XCTAssertGreaterThan(farthest, 220, "It runs on past its end...")
        XCTAssertLessThan(farthest, 260, "...but not far.")
        XCTAssertEqual(momentum.top, 200, accuracy: 0.001)
    }

    @MainActor func testALetGoReorderListCoastsUntilAFingerStopsIt() async throws {
        var layout = LibraryShelfGeometry(count: 40, size: phone, topInset: 56, bottomInset: 100, rowStep: 60)
        layout.top = layout.top(placing: 10, at: 400)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.isRearranging = true
        interaction.beginRearrangeStroke(at: CGPoint(x: 160, y: 400), in: layout)
        _ = interaction.moveRearrangeStroke(to: CGPoint(x: 160, y: 380), in: layout)
        let lifted = interaction.shelfTop
        interaction.releaseRearrangeStroke(velocity: -800)
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertLessThan(interaction.shelfTop, lifted - 50, "The list coasts on after the finger lifts.")
        interaction.touchDown()
        let caught = interaction.shelfTop
        try await Task.sleep(for: .seconds(0.2))
        XCTAssertEqual(interaction.shelfTop, caught, "A finger landing stops it where it is.")
        XCTAssertTrue(interaction.consumeScrollCatch(), "The tap that stopped it does nothing else.")
        XCTAssertFalse(interaction.consumeScrollCatch())
        interaction.touchDown()
        XCTAssertFalse(interaction.consumeScrollCatch(), "A tap on a list at rest is an ordinary tap.")
    }

    @MainActor func testACarriedRowDropsWhereTheFingerHoldsIt() {
        var layout = LibraryShelfGeometry(count: 5, size: phone, topInset: 88, bottomInset: 100, rowStep: 60)
        layout.top = layout.top(placing: 0, at: 200)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.isRearranging = true
        interaction.beginRearrangeStroke(at: CGPoint(x: 20, y: layout.center(3)), in: layout)
        XCTAssertEqual(interaction.carried?.from, 3, "A stroke on the handle carries that row.")
        _ = interaction.moveRearrangeStroke(to: CGPoint(x: 30, y: layout.center(1) - 10), in: layout)
        XCTAssertEqual(interaction.carried?.to, 1)
        interaction.endStroke()

        interaction.carried = nil
        interaction.beginRearrangeStroke(at: CGPoint(x: 160, y: layout.center(2)), in: layout)
        XCTAssertNil(interaction.carried, "Away from the handles a stroke only scrolls.")
        _ = interaction.moveRearrangeStroke(to: CGPoint(x: 200, y: layout.center(2)), in: layout)
        XCTAssertEqual(interaction.moveRearrangeStroke(to: CGPoint(x: 10, y: layout.center(2)), in: layout), .back,
                       "The left edge finishes reordering.")
        interaction.endStroke()
    }

    @MainActor func testComingBackOverTheEdgeAfterMovingInCancelsTheChoice() {
        var layout = LibraryShelfGeometry(count: 5, size: phone, topInset: 88, bottomInset: 100)
        layout.top = layout.top(placing: 2, at: 400)
        let interaction = LibraryEdgeInteraction()
        interaction.shelfTop = layout.top
        interaction.beginStroke(at: CGPoint(x: 8, y: 400))
        _ = interaction.moveStroke(to: CGPoint(x: 14, y: 400), in: layout, nested: false)
        XCTAssertFalse(interaction.isCancelling, "The swipe that opens the shelves starts at the edge and must not cancel.")
        XCTAssertEqual(interaction.highlighted, 2)
        _ = interaction.moveStroke(to: CGPoint(x: 140, y: 400), in: layout, nested: false)
        _ = interaction.moveStroke(to: CGPoint(x: 6, y: 400), in: layout, nested: false)
        XCTAssertTrue(interaction.isCancelling)
        XCTAssertNil(interaction.highlighted, "Over the edge nothing is chosen, so lifting chooses nothing.")
        _ = interaction.moveStroke(to: CGPoint(x: 90, y: 400), in: layout, nested: false)
        XCTAssertFalse(interaction.isCancelling, "Moving back in picks rows again.")
        XCTAssertEqual(interaction.highlighted, 2)
        interaction.endStroke()
    }
}

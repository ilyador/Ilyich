import XCTest
@testable import Ilyich

final class TimeRailRestTests: XCTestCase {
    func testTheRollOfALiftingFingerAfterAStopNeverMovesThePhotos() {
        var rest = TimeRailRest()
        XCTAssertEqual(rest.move(to: 300, at: 0), 300)
        XCTAssertEqual(rest.move(to: 400, at: 0.2), 400, "While scrubbing the photos follow the finger.")
        // The finger stops at 400, then rolls ten points as it lifts.
        XCTAssertNil(rest.move(to: 403, at: 0.7), "After a stop, a move close by waits.")
        XCTAssertNil(rest.move(to: 410, at: 0.74))
        XCTAssertNil(rest.due(at: 0.78), "Nothing arrives before it has waited.")
        rest.end()
        XCTAssertNil(rest.nextDue, "Lifting drops the roll, so the photos stay where the finger stopped.")
    }

    func testAnAdjustmentAfterAStopIsFollowedOnceTheFingerStaysDown() {
        var rest = TimeRailRest()
        _ = rest.move(to: 400, at: 0)
        XCTAssertNil(rest.move(to: 403, at: 0.5))
        XCTAssertEqual(rest.nextDue ?? 0, 0.5 + TimeRailRest.delay, accuracy: 0.0001)
        XCTAssertEqual(rest.due(at: 0.5 + TimeRailRest.delay + 0.01), 403, "Still down a moment later, the adjustment is followed.")
        XCTAssertNil(rest.nextDue)
        XCTAssertNil(rest.move(to: 404, at: 0.8), "A small adjustment keeps the stop, so the next roll waits too.")
    }

    func testOnlyMovesThatHaveWaitedArrive() {
        var rest = TimeRailRest()
        _ = rest.move(to: 400, at: 0)
        XCTAssertNil(rest.move(to: 401, at: 0.5))
        XCTAssertNil(rest.move(to: 412, at: 0.6))
        XCTAssertEqual(rest.due(at: 0.66), 401, "Tremor before the lift has waited; the roll has not.")
        rest.end()
        XCTAssertNil(rest.nextDue, "The roll never arrives.")
    }

    func testAMoveFarFromTheStopIsFollowedAtOnce() {
        var rest = TimeRailRest()
        _ = rest.move(to: 400, at: 0)
        XCTAssertNil(rest.move(to: 405, at: 0.5))
        let far = 400 + TimeRailRest.holdRadius + 6
        XCTAssertEqual(rest.move(to: far, at: 0.52), far, "A deliberate move is followed at once.")
        XCTAssertNil(rest.nextDue, "The move that was waiting is dropped.")
        XCTAssertEqual(rest.move(to: far + 3, at: 0.6), far + 3, "Moving on, the finger has not stopped yet.")
    }

    func testAPauseShorterThanAStopDoesNotHold() {
        var rest = TimeRailRest()
        _ = rest.move(to: 400, at: 0)
        XCTAssertEqual(rest.move(to: 404, at: TimeRailRest.holdAfter - 0.1), 404, "A glance at the lens mid-scrub is not a stop.")
    }

    func testTremorWhileStoppedCountsAsResting() {
        var rest = TimeRailRest()
        _ = rest.move(to: 400, at: 0)
        XCTAssertEqual(rest.move(to: 402, at: 0.1), 402)
        XCTAssertEqual(rest.move(to: 399, at: 0.2), 399)
        XCTAssertNil(rest.move(to: 401, at: 0.4), "The stop counts from when the finger stopped, not from its last tremor.")
    }

    func testAStopIsLongerThanAGlanceAndShorterThanALongPress() {
        XCTAssertGreaterThan(TimeRailRest.holdAfter, 0.25)
        XCTAssertLessThan(TimeRailRest.holdAfter, 0.5)
        XCTAssertLessThan(TimeRailRest.delay, 0.2, "A held adjustment still follows quickly.")
    }
}

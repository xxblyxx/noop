import XCTest
@testable import Strand

final class BackgroundAnalyzeSchedulePolicyTests: XCTestCase {
    func testScoredReArmsAtTheAnalyzePolicyFloor() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            BackgroundAnalyzeSchedulePolicy.earliestBeginDate(after: now, scored: true),
            now.addingTimeInterval(AnalyzePolicy.forcedFloorSeconds)
        )
    }

    func testNoopReArmsLaterThanScored() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scored = BackgroundAnalyzeSchedulePolicy.earliestBeginDate(after: now, scored: true)
        let noop = BackgroundAnalyzeSchedulePolicy.earliestBeginDate(after: now, scored: false)
        XCTAssertGreaterThan(noop, scored)
    }

    func testNoopIntervalIsFourTimesTheScoredInterval() {
        XCTAssertEqual(BackgroundAnalyzeSchedulePolicy.reArmAfterNoopSeconds,
                       BackgroundAnalyzeSchedulePolicy.reArmAfterScoredSeconds * 4)
    }
}

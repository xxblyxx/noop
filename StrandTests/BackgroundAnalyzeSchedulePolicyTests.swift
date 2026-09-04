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

    // MARK: - #1005-CONVERGE: a truncated pass must not back off like a no-op

    /// The regression this exists for: a pass cut short mid-scan advances neither the watermark nor
    /// `completedPassCount`, so it used to report as "nothing to do" and re-arm 60 minutes out — the exact
    /// hourly cadence the 2026-09-04 device log showed. A truncated pass has MORE work waiting than a
    /// scored one, so it must never wait longer than one.
    func testTruncatedReArmsAtTheShortInterval() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            BackgroundAnalyzeSchedulePolicy.earliestBeginDate(after: now, outcome: .truncated),
            now.addingTimeInterval(AnalyzePolicy.forcedFloorSeconds)
        )
    }

    func testTruncatedDoesNotBackOffLikeANoop() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let truncated = BackgroundAnalyzeSchedulePolicy.earliestBeginDate(after: now, outcome: .truncated)
        let noop = BackgroundAnalyzeSchedulePolicy.earliestBeginDate(after: now, outcome: .noop)
        XCTAssertLessThan(truncated, noop)
    }

    /// The two-way form must stay a faithful shorthand for the three-way one, or the "arm before work"
    /// call (which runs before any outcome is known) would silently drift from the post-work re-arm.
    func testBoolFormAgreesWithOutcomeForm() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(BackgroundAnalyzeSchedulePolicy.earliestBeginDate(after: now, scored: true),
                       BackgroundAnalyzeSchedulePolicy.earliestBeginDate(after: now, outcome: .scored))
        XCTAssertEqual(BackgroundAnalyzeSchedulePolicy.earliestBeginDate(after: now, scored: false),
                       BackgroundAnalyzeSchedulePolicy.earliestBeginDate(after: now, outcome: .noop))
    }
}

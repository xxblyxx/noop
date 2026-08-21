import XCTest
import WhoopStore
import StrandDesign
@testable import Strand

/// `WatchGlance.compose` — the wrist's honesty rules, pulled out of the `#if os(iOS)`-gated
/// `WatchSessionBridge` so they can be asserted on macOS without a phone, a watch or an `AppModel`.
///
/// The wrist used to derive all three `*Calibrating` flags from `anchorDay != nil`, i.e. from whether SOME
/// day carried a recovery score. That conflated "the phone has data" with "the phone has a SCORED day", so
/// one null recovery column blanked Charge, Effort AND Rest together — the same coupling that blanked the
/// Home Screen widget. The flag now keys off whether any day rows exist at all, which is what the rule
/// always meant. See `WidgetGlanceFieldsTests` for the per-field resolution this consumes.
final class WatchGlanceComposeTests: XCTestCase {

    private func day(_ key: String, sleepMin: Double? = nil, efficiency: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleepMin, efficiency: efficiency, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    private func compose(_ fields: Repository.GlanceFields,
                         hasAnyData: Bool = true,
                         anchorDay: DailyMetric? = nil,
                         todayRow: DailyMetric? = nil) -> WatchScoreSnapshot {
        WatchGlance.compose(fields: fields, hasAnyData: hasAnyData, anchorDay: anchorDay,
                            todayRow: todayRow, hr: 58, asOf: Date(timeIntervalSince1970: 0))
    }

    /// The reported shape: nothing scored, so Charge is genuinely mid-calibration — but Effort and Rest
    /// have real numbers and must NOT be flagged or blanked alongside it.
    func testNothingScored_onlyChargeCalibrates() {
        let f = Repository.GlanceFields(charge: nil, effort: 11.4, rest: 88, hrv: 64, restingHr: 52)
        let snap = compose(f, todayRow: day("2026-06-19"))

        XCTAssertNil(snap.charge)
        XCTAssertTrue(snap.chargeCalibrating, "no usable baseline yet: a cal marker, not a bare dash")
        XCTAssertEqual(snap.effort, 11.4)
        XCTAssertFalse(snap.effortCalibrating, "Effort has a real number and must not be flagged")
        XCTAssertEqual(snap.rest, 88)
        XCTAssertFalse(snap.restCalibrating)
    }

    /// A fresh, never-synced phone: no rows at all. Every flag stays false so the watch shows its neutral
    /// "open NOOP on your iPhone" empty state rather than implying calibration is underway.
    func testNoDataAtAll_nothingIsFlaggedAsCalibrating() {
        let f = Repository.GlanceFields(charge: nil, effort: nil, rest: nil, hrv: nil, restingHr: nil)
        let snap = compose(f, hasAnyData: false)

        XCTAssertFalse(snap.chargeCalibrating)
        XCTAssertFalse(snap.effortCalibrating)
        XCTAssertFalse(snap.restCalibrating)
        XCTAssertNil(snap.scoreDay, "no row to name")
    }

    /// Rows exist but no number is earned for any of the three — all genuinely calibrating.
    func testRowsButNoNumbers_allThreeCalibrate() {
        let f = Repository.GlanceFields(charge: nil, effort: nil, rest: nil, hrv: nil, restingHr: nil)
        let snap = compose(f, hasAnyData: true, todayRow: day("2026-06-19"))

        XCTAssertTrue(snap.chargeCalibrating)
        XCTAssertTrue(snap.effortCalibrating)
        XCTAssertTrue(snap.restCalibrating)
    }

    /// A present number is never flagged, whatever `hasAnyData` says.
    func testPresentNumbersAreNeverFlagged() {
        let f = Repository.GlanceFields(charge: 61, effort: 9, rest: 80, hrv: 55, restingHr: 50)
        let snap = compose(f, anchorDay: day("2026-06-19"), todayRow: day("2026-06-19"))

        XCTAssertFalse(snap.chargeCalibrating)
        XCTAssertFalse(snap.effortCalibrating)
        XCTAssertFalse(snap.restCalibrating)
    }

    // MARK: - scoreDay

    /// The anchor is the field most likely to describe an EARLIER day, so it owns the recency label.
    func testScoreDayPrefersTheAnchorDay() {
        let f = Repository.GlanceFields(charge: 72, effort: 6, rest: nil, hrv: nil, restingHr: nil)
        let snap = compose(f, anchorDay: day("2026-06-18"), todayRow: day("2026-06-19"))
        XCTAssertEqual(snap.scoreDay, "2026-06-18")
    }

    /// With no anchor at all the remaining numbers are today's, so today's key is the honest label —
    /// previously this went nil and the watch lost its recency label entirely.
    func testScoreDayFallsBackToTodayWhenNoAnchor() {
        let f = Repository.GlanceFields(charge: nil, effort: 6, rest: 80, hrv: nil, restingHr: nil)
        let snap = compose(f, anchorDay: nil, todayRow: day("2026-06-19"))
        XCTAssertEqual(snap.scoreDay, "2026-06-19")
    }

    // MARK: - sleepSummary

    /// Sleep is keyed by the local WAKE day, so today's banked night is the right source.
    func testSleepSummaryPrefersTodaysBankedNight() {
        let f = Repository.GlanceFields(charge: 72, effort: nil, rest: nil, hrv: nil, restingHr: nil)
        let snap = compose(f,
                           anchorDay: day("2026-06-18", sleepMin: 300, efficiency: 70),
                           todayRow: day("2026-06-19", sleepMin: 432, efficiency: 81))
        XCTAssertEqual(snap.sleepSummary, "7h 12m · 81%")
    }

    /// Rollover window: today's row exists but holds no night yet, so the anchor day's night still shows
    /// rather than the line going blank.
    func testSleepSummaryFallsBackToTheAnchorBeforeTonightIsBanked() {
        let f = Repository.GlanceFields(charge: 72, effort: nil, rest: nil, hrv: nil, restingHr: nil)
        let snap = compose(f,
                           anchorDay: day("2026-06-18", sleepMin: 300, efficiency: 70),
                           todayRow: day("2026-06-19"))
        XCTAssertEqual(snap.sleepSummary, "5h 0m · 70%")
    }
}

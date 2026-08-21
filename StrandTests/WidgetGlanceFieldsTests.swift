import XCTest
import WhoopStore
@testable import Strand

/// `Repository.glanceFields` — the per-field glance resolver the off-dashboard surfaces publish through.
///
/// It exists because the widget publish used to funnel Charge, Effort, Rest, HRV and Resting HR through the
/// single recovery-gated `widgetAnchor`. A store with no scored `recovery` row anywhere then blanked all five
/// stat blocks together on the Home Screen, while Today — which resolves the same stats through four
/// INDEPENDENT selectors — kept showing four of them. These tests pin that decoupling: the recovery gate
/// applies to Charge and to nothing else, and each other field reaches the same value its Today call site does.
///
/// Pure: no clock, no `AppModel`, no store, no strap. Mirror the Kotlin twin in `WidgetGlanceFieldsTest.kt`.
final class WidgetGlanceFieldsTests: XCTestCase {

    private func day(_ key: String,
                     recovery: Double? = nil,
                     sleepMin: Double? = nil,
                     strain: Double? = nil,
                     hrv: Double? = nil,
                     rhr: Int? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery,
                    strain: strain, exerciseCount: nil)
    }

    /// Convenience for the common same-key case (logical == local, i.e. any time after 04:00 local).
    private func fields(_ days: [DailyMetric],
                        today: String,
                        localKey: String? = nil,
                        restByDay: [String: Double] = [:],
                        restTail: (day: String, value: Double)? = nil) -> Repository.GlanceFields {
        Repository.glanceFields(days: days,
                                logicalKey: today,
                                localKey: localKey ?? today,
                                restByDay: restByDay,
                                restTail: restTail)
    }

    // MARK: - (1) The reported bug

    /// The exact reported state: nothing in the store is scored, so the anchor is nil — but today's row
    /// carries real strain / HRV / resting HR and a Rest point exists. Before the decoupling this published
    /// five nils and the Home Screen showed only HR + battery.
    func testNoScoredRecoveryAnywhere_onlyChargeBlanks() {
        let days = [day("2026-06-18", recovery: nil),
                    day("2026-06-19", recovery: nil, strain: 11.4, hrv: 64, rhr: 52)]
        let f = fields(days, today: "2026-06-19", restByDay: ["2026-06-19": 88])

        XCTAssertNil(f.charge, "no scored row anywhere: a blank Charge is the honest answer")
        XCTAssertEqual(f.effort, 11.4, "Effort must NOT be gated on a recovery score")
        XCTAssertEqual(f.rest, 88, "Rest is an independent series and must survive a nil anchor")
        XCTAssertEqual(f.hrv, 64, "HRV must NOT be gated on a recovery score")
        XCTAssertEqual(f.restingHr, 52, "Resting HR must NOT be gated on a recovery score")
    }

    // MARK: - (2) Effort never carries

    /// Charge carries a strictly-prior scored day; Effort must NOT come along for the ride. Yesterday's
    /// strain presented as today's is a false statement, not merely a stale one.
    func testEffortNeverCarriesFromTheAnchorRow() {
        let days = [day("2026-06-18", recovery: 72, strain: 14),
                    day("2026-06-19", recovery: nil, strain: nil)]
        let f = fields(days, today: "2026-06-19")

        XCTAssertEqual(f.charge, 72, "Charge carries the freshest strictly-prior scored day")
        XCTAssertNil(f.effort, "Effort must read today's own row or nothing — never the carried anchor's")
    }

    /// Today's own strain always wins, even when Charge is carried from another day.
    func testEffortReadsTodaysOwnRowWhileChargeIsCarried() {
        let days = [day("2026-06-18", recovery: 72, strain: 14),
                    day("2026-06-19", recovery: nil, strain: 6.2)]
        let f = fields(days, today: "2026-06-19")

        XCTAssertEqual(f.charge, 72)
        XCTAssertEqual(f.effort, 6.2, "today's own accumulation, not the anchor day's")
    }

    // MARK: - (3) Vitals carry, recovery-independently

    /// A prior night with real HRV/RHR but a NULL recovery is a valid vitals source (`lastVitalsDay` is
    /// explicitly recovery-independent) — unlike for Charge, which stays blank here.
    func testVitalsCarryFromAnUnscoredPriorNight() {
        let days = [day("2026-06-18", recovery: nil, hrv: 58, rhr: 49),
                    day("2026-06-19", recovery: nil, strain: nil)]
        let f = fields(days, today: "2026-06-19")

        XCTAssertNil(f.charge, "the vitals carry must never feed Charge")
        XCTAssertNil(f.effort, "the vitals carry must never feed Effort")
        XCTAssertEqual(f.hrv, 58, "HRV carries from the freshest strictly-prior night with vitals")
        XCTAssertEqual(f.restingHr, 49)
    }

    /// The carry is a FALLBACK only — today's own value wins per field.
    func testTodaysOwnVitalsBeatTheCarry() {
        let days = [day("2026-06-18", recovery: nil, hrv: 58, rhr: 49),
                    day("2026-06-19", recovery: nil, hrv: 71, rhr: 54)]
        let f = fields(days, today: "2026-06-19")

        XCTAssertEqual(f.hrv, 71)
        XCTAssertEqual(f.restingHr, 54)
    }

    // MARK: - (4) Rest survives a nil anchor

    /// Rest used to be read inside `if let anchor`, so a nil anchor blanked it for a reason that has
    /// nothing to do with the `sleep_performance` series.
    func testRestResolvesWithNoScoredRowAnywhere() {
        let days = [day("2026-06-19", recovery: nil)]
        let f = fields(days, today: "2026-06-19", restByDay: ["2026-06-19": 91])

        XCTAssertNil(f.charge)
        XCTAssertEqual(f.rest, 91, "Rest must not be nested behind the recovery anchor")
    }

    // MARK: - (5) Rest resolution (the #977 staleness gate)

    func testRestTodaysValueBeatsTheTail() {
        let f = fields([day("2026-06-19")], today: "2026-06-19",
                       restByDay: ["2026-06-19": 77],
                       restTail: (day: "2026-06-18", value: 42))
        XCTAssertEqual(f.rest, 77, "today's own scored Rest always wins")
    }

    func testRestCarriesAFreshTail() {
        // Yesterday is inside `TodayView.carryFreshnessDays` (2), the legitimate morning carry.
        let f = fields([day("2026-06-19")], today: "2026-06-19",
                       restTail: (day: "2026-06-18", value: 84))
        XCTAssertEqual(f.rest, 84, "last night's Rest carries before today scores")
    }

    func testRestDoesNotCarryAStaleTail() {
        // Beyond the freshness cap: a strap whose sleep never scores must fall through to blank rather
        // than pin Rest to a weeks-old night.
        let f = fields([day("2026-06-19")], today: "2026-06-19",
                       restTail: (day: "2026-05-30", value: 84))
        XCTAssertNil(f.rest, "a tail older than carryFreshnessDays must not be passed off as today's")
    }

    // MARK: - (6) Fully scored today

    func testTodayScored_everyFieldFromTodaysOwnRow() {
        let days = [day("2026-06-18", recovery: 60, strain: 14, hrv: 40, rhr: 60),
                    day("2026-06-19", recovery: 55, strain: 9.1, hrv: 66, rhr: 51)]
        let f = fields(days, today: "2026-06-19", restByDay: ["2026-06-19": 80])

        XCTAssertEqual(f.charge, 55)
        XCTAssertEqual(f.effort, 9.1)
        XCTAssertEqual(f.rest, 80)
        XCTAssertEqual(f.hrv, 66)
        XCTAssertEqual(f.restingHr, 51)
    }

    // MARK: - (7) #304 pre-04:00 carve-out

    /// Small hours: the logical day is still the 17th, but the just-finished night is banked under the new
    /// LOCAL day (the 18th). `resolveToday` prefers the local banked row, so Effort/HRV must come from the
    /// 18th while Charge carries the scored 17th. This is the case where a `max(logicalKey, localKey)`
    /// today-key would silently drift.
    func testPre0400CarveOut_perFieldRowsAreCorrect() {
        let days = [day("2026-06-16", recovery: 60, strain: 3, hrv: 30, rhr: 70),
                    day("2026-06-17", recovery: 71, strain: 14, hrv: 40, rhr: 60),
                    day("2026-06-18", recovery: nil, sleepMin: 430, strain: 1.2, hrv: 68, rhr: 50)]
        let f = fields(days, today: "2026-06-17", localKey: "2026-06-18",
                       restByDay: ["2026-06-18": 93])

        XCTAssertEqual(f.charge, 71, "Charge carries the scored 17th")
        XCTAssertEqual(f.effort, 1.2, "Effort comes from the LOCAL banked row (the 18th)")
        XCTAssertEqual(f.hrv, 68, "vitals come from the local banked row, not the carried anchor")
        XCTAssertEqual(f.restingHr, 50)
        XCTAssertEqual(f.rest, 93, "Rest is keyed on the resolved today row's day, the 18th")
    }

    // MARK: - (8) #547 future-day guard

    func testStrayFutureRowIsNeverSelected() {
        let days = [day("2026-06-18", recovery: nil, hrv: 58, rhr: 49),
                    day("2026-06-19", recovery: nil),
                    day("2026-07-12", recovery: 80, strain: 19, hrv: 99, rhr: 40)]
        let f = fields(days, today: "2026-06-19")

        XCTAssertNil(f.charge, "a future-only scored row must never become Charge")
        XCTAssertNil(f.effort, "today's row has no strain; the future row must not supply one")
        XCTAssertEqual(f.hrv, 58, "the vitals carry is bounded to strictly-prior days")
        XCTAssertEqual(f.restingHr, 49)
    }

    // MARK: - (9) Degenerate input

    func testEmptyDays_allNilNoCrash() {
        let f = fields([], today: "2026-06-19")
        XCTAssertNil(f.charge)
        XCTAssertNil(f.effort)
        XCTAssertNil(f.rest)
        XCTAssertNil(f.hrv)
        XCTAssertNil(f.restingHr)
    }

    /// With no row for today at all, the Rest key falls back to `logicalKey` (matching `widgetAnchor`'s
    /// own `carriedKey`), so an existing Rest point for that key still resolves.
    func testNoTodayRow_restStillKeysOnTheLogicalDay() {
        let f = fields([day("2026-06-18", recovery: nil)], today: "2026-06-19",
                       restByDay: ["2026-06-19": 70])
        XCTAssertEqual(f.rest, 70)
        XCTAssertNil(f.effort)
    }
}

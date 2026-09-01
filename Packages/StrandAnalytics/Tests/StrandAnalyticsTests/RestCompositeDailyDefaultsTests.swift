import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Pins the coupling `IntelligenceEngine`'s day-scan cache (`Strand/Data/IntelligenceEngine.swift`,
/// `dayCacheConfigParts`) depends on: `pass 2` (`IntelligenceEngine.analyzeRecent`'s second half) reads
/// `Rest.composite(daily:)` — never `Rest.composite(daily:needHours:consistency:)` with the personalized
/// values — for the persisted `sleep_performance` series, the Charge "Rest quality" term, and every display
/// surface. That is why `sleepNeedHours`/`sleepConsistency` can be dropped from the pass config signature
/// outside a Sleep trace (#1005-CHURN, see that call site): outside the trace, a reused day-scan cache entry
/// is byte-identical to a fresh one regardless of what those two values were at scan time, because nothing
/// downstream of a cache hit ever asks `Rest.composite(daily:)` for anything but its DEFAULTS.
///
/// If a future change wires the personalized sleep-need/regularity into `Rest.composite(daily:)`'s call
/// sites (making Rest actually consistency-aware on display), THIS test starts failing — which is the
/// point: it is the signal that `IntelligenceEngine`'s conditional signature must be revisited alongside it.
final class RestCompositeDailyDefaultsTests: XCTestCase {
    private func sleepableDaily(day: String = "2026-08-30") -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 90,
                   lightMin: 240, disturbances: 2, restingHr: 52, avgHrv: 60,
                   recovery: nil, strain: nil, exerciseCount: nil)
    }

    func testDefaultCallMatchesExplicitDefaults() {
        let d = sleepableDaily()
        let byDefault = AnalyticsEngine.Rest.composite(daily: d)
        let explicit = AnalyticsEngine.Rest.composite(daily: d, needHours: AnalyticsEngine.Rest.defaultNeedHours,
                                                       consistency: nil)
        XCTAssertEqual(byDefault, explicit, "Rest.composite(daily:)'s implicit defaults must stay "
                       + "defaultNeedHours / nil — that IS the contract the day-scan cache signature relies on.")
    }

    func testExplicitConsistencyMovesTheScoreAwayFromTheDefault() {
        // Proves the explicit-parameter overload IS live (not dead-code-equivalent to the default), so a
        // caller that started passing a real `consistency` would visibly diverge from what the cache
        // signature currently assumes is irrelevant outside a trace.
        let d = sleepableDaily()
        let byDefault = AnalyticsEngine.Rest.composite(daily: d)
        let lowConsistency = AnalyticsEngine.Rest.composite(daily: d, consistency: 0.0)
        let highConsistency = AnalyticsEngine.Rest.composite(daily: d, consistency: 1.0)
        XCTAssertNotEqual(byDefault, lowConsistency)
        XCTAssertNotEqual(byDefault, highConsistency)
        XCTAssertNotEqual(lowConsistency, highConsistency)
    }

    func testExplicitNeedHoursMovesTheScoreAwayFromTheDefault() {
        let d = sleepableDaily()
        let byDefault = AnalyticsEngine.Rest.composite(daily: d)
        let shortNeed = AnalyticsEngine.Rest.composite(daily: d, needHours: 5.0)
        XCTAssertNotEqual(byDefault, shortNeed)
    }
}

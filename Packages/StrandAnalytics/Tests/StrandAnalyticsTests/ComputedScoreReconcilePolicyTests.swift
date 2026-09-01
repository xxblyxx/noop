import XCTest
@testable import StrandAnalytics

/// `ComputedScoreReconcilePolicy` — how far a pass may reach when it reconciles the persisted
/// computed-score window against what it just scored. Oracle for the Kotlin twin
/// (`ComputedScoreReconcilePolicyTest.kt`); the rules must match value-for-value.
final class ComputedScoreReconcilePolicyTests: XCTestCase {
    private typealias P = ComputedScoreReconcilePolicy

    // ── mayEvictStaleDays ────────────────────────────────────────────────────────────────────────────

    func testCompletePassWithScoresMayEvict() {
        XCTAssertTrue(P.mayEvictStaleDays(scoredDayCount: 21, cancelled: false))
        XCTAssertTrue(P.mayEvictStaleDays(scoredDayCount: 1, cancelled: false))
    }

    func testEmptyPassMayNotEvict() {
        // The #1196 case: a degenerate pass produced nothing — a full-window eviction would blank the store.
        XCTAssertFalse(P.mayEvictStaleDays(scoredDayCount: 0, cancelled: false))
    }

    func testCancelledPassMayNotEvict() {
        // A pass cut short after scoring some newest days: the older days it never reached would all read
        // as "stale" against the truncated fresh-key set.
        XCTAssertFalse(P.mayEvictStaleDays(scoredDayCount: 3, cancelled: true))
        XCTAssertFalse(P.mayEvictStaleDays(scoredDayCount: 0, cancelled: true))
    }

    // ── reconcileFromDay ─────────────────────────────────────────────────────────────────────────────

    func testCompletePassKeepsFullWindow() {
        let from = P.reconcileFromDay(cancelled: false,
                                     scoredDays: ["2026-08-20", "2026-09-01"],
                                     windowOldestDay: "2026-08-12", windowNewestDay: "2026-09-01")
        XCTAssertEqual(from, "2026-08-12")
    }

    func testCancelledPassContractsToEarliestScoredDay() {
        // Loop scans newest-first, so a truncated `dailies` covers only recent days. The destructive
        // delete must not span older than the earliest one actually scored.
        let from = P.reconcileFromDay(cancelled: true,
                                     scoredDays: ["2026-09-01", "2026-08-31", "2026-08-30"],
                                     windowOldestDay: "2026-08-12", windowNewestDay: "2026-09-01")
        XCTAssertEqual(from, "2026-08-30")
    }

    func testCancelledPassWithNoScoredDaysFallsBackToNewest() {
        let from = P.reconcileFromDay(cancelled: true, scoredDays: [],
                                     windowOldestDay: "2026-08-12", windowNewestDay: "2026-09-01")
        XCTAssertEqual(from, "2026-09-01")
    }

    func testYyyyMmDdStringOrderIsDateOrder() {
        // The policy relies on lexical `min` being chronological `min` — true for zero-padded yyyy-MM-dd.
        let from = P.reconcileFromDay(cancelled: true,
                                     scoredDays: ["2026-01-05", "2025-12-30", "2026-01-02"],
                                     windowOldestDay: "2025-11-01", windowNewestDay: "2026-01-05")
        XCTAssertEqual(from, "2025-12-30")
    }
}

package com.noop.analytics

/**
 * Pure rules for how far an `analyzeRecent` pass may reach when it reconciles the persisted
 * computed-score window against what it just scored. Twin of the Swift
 * `ComputedScoreReconcilePolicy` (`Packages/StrandAnalytics/Sources/StrandAnalytics/ComputedScoreReconcilePolicy.swift`),
 * value-for-value.
 *
 * Why this exists (Swift side): pass 1's day loop scans NEWEST day first and `break`s on
 * `Task.isCancelled` — a `BGProcessingTask` whose `expirationHandler` fired mid-scan — returning a
 * PARTIAL `dailies` that covers only the newest days it reached. The window reconcile
 * (`replaceComputedScoreWindow`'s wide `deleteDailyMetricsInRange` + provenance wide-delete) then
 * spans the pass's full `maxDays` window and would delete every older day the pass never re-scored.
 * The existing `#1196` guard covers a pass that scored *nothing*; it does NOT cover a pass cut short
 * after scoring some days.
 *
 * **Android note.** The Kotlin day loop does not `break`-and-bank on cancellation — a coroutine
 * cancellation throws `CancellationException` out of `analyzeRecentOnCpu` before it ever reaches
 * `replaceComputedScoreWindow`, so there is no truncated-pass persist path today. The Kotlin caller
 * therefore always passes `cancelled = false`; this policy is the shared, documented home for the rule
 * so that if partial banking is ever added on Android the guard is already correct. `mayEvictStaleDays`
 * with `cancelled = false` reduces to the existing "scored nothing ⇒ skip" guard, and `reconcileFromDay`
 * with `cancelled = false` returns the full-window `windowOldestDay` unchanged.
 */
object ComputedScoreReconcilePolicy {

    /**
     * Whether a pass may run the full-window stale-day eviction. False when the pass scored nothing
     * (`#1196`) or was cancelled mid-scan: in both cases the scored set no longer tiles the window, so a
     * full-window eviction deletes days the pass simply did not get to.
     */
    fun mayEvictStaleDays(scoredDayCount: Int, cancelled: Boolean): Boolean =
        scoredDayCount > 0 && !cancelled

    /**
     * The `from` day-key the destructive reconcile (the `dailyMetrics` + provenance wide-delete in
     * `replaceComputedScoreWindow`) may span. On a complete pass this is [windowOldestDay]; on a
     * cancelled pass it contracts to the earliest day actually scored, so the delete-then-reinsert can
     * never outrun what this pass produced. [scoredDays] is the set of `DailyMetric.day` keys this pass
     * banked; [windowNewestDay] is the fallback when it is empty.
     */
    fun reconcileFromDay(
        cancelled: Boolean,
        scoredDays: List<String>,
        windowOldestDay: String,
        windowNewestDay: String,
    ): String {
        if (!cancelled) return windowOldestDay
        return scoredDays.minOrNull() ?: windowNewestDay
    }
}

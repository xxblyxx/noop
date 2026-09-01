import Foundation

/// Pure rules for how far an `analyzeRecent` pass may reach when it reconciles the persisted
/// computed-score window against what it just scored. No store / BLE / UI deps — mirrors the
/// `AnalyzePolicy` / `BackfillPolicy` shape so the rule is unit-testable and twin-able
/// (`android/app/src/main/java/com/noop/analytics/ComputedScoreReconcilePolicy.kt`).
///
/// Why this exists: pass 1's day loop (`IntelligenceEngine.analyzeRecent`) scans NEWEST day first and
/// `break`s on `Task.isCancelled` — a `BGProcessingTask` whose `expirationHandler` fired mid-scan —
/// returning a PARTIAL `dailies` that covers only the newest days it reached. Two reconcile steps then
/// span the pass's full `maxDays` window:
///   * the stale-day eviction (Swift: a per-day diff loop; Kotlin: `replaceComputedScoreWindow`'s wide
///     `deleteDailyMetricsInRange`), which would delete every older day the pass never re-scored;
///   * `persistComputedScores` / `replaceComputedScoreWindow`'s provenance wide-delete, which would
///     blank attribution for those same days.
/// The existing `#1196` guard covers a pass that scored *nothing*; it does NOT cover a pass that
/// scored *some* days and was then cut short. This policy covers both.
public enum ComputedScoreReconcilePolicy {

    /// Whether a pass may run the full-window stale-day eviction. False when the pass scored nothing
    /// (`#1196`) or was cancelled mid-scan: in both cases `dailies` no longer tiles the window, so a
    /// full-window eviction deletes days the pass simply did not get to.
    public static func mayEvictStaleDays(scoredDayCount: Int, cancelled: Bool) -> Bool {
        scoredDayCount > 0 && !cancelled
    }

    /// The `from` day-key the destructive reconcile (provenance wide-delete, and on Android the
    /// `dailyMetrics` wide-delete) may span. On a complete pass this is the caller's full-window
    /// `windowOldestDay`; on a cancelled pass it contracts to the earliest day actually scored, so the
    /// delete-then-reinsert can never outrun what this pass produced. `scoredDays` is the set of
    /// `DailyMetric.day` keys this pass banked; `windowNewestDay` is the fallback when it is empty
    /// (paired with `mayEvictStaleDays` returning false, nothing destructive runs anyway).
    public static func reconcileFromDay(cancelled: Bool, scoredDays: [String],
                                        windowOldestDay: String, windowNewestDay: String) -> String {
        guard cancelled else { return windowOldestDay }
        return scoredDays.min() ?? windowNewestDay
    }
}

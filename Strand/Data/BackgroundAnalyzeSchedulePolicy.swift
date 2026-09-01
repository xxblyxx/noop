import Foundation

/// Pure scheduling policy for iOS's deferred-analyze `BGProcessingTask` self-re-arm
/// (`SyncAnalyzeBackgroundScheduler`). Framework-free so the interval choice is testable in the
/// macOS-hosted app test target, matching `HealthWritebackSchedulePolicy`'s precedent.
///
/// #1005-STORM follow-up. The task used to be strictly one-shot — `schedule()` called once per
/// `.background` scene transition, never re-armed from inside the task's own body — on the reasoning
/// that "an analyze wake is USUALLY a no-op" and a permanent re-arm would buy a standing cadence for a
/// handler with nothing to do most of the time. That reasoning left the strap-disconnects-right-after-
/// HISTORY_COMPLETE case with nothing armed for the rest of a night: one request, delivered early,
/// found nothing new (a fresh offload hadn't landed yet), and no successor existed for the offloads that
/// followed hours later. Measured against a real device: the last analyze pass before noon ended at
/// 00:53:55 over data ending 00:52:51, and no analyze pass ran for the next 12 hours despite OTHER
/// background work (a folder backup, the `.healthwriteback` BGTask) running fine in that window — the
/// `.analyze` task specifically was never woken again.
///
/// The counter-argument was weaker than it looked: a no-op wake costs one indexed
/// `store.hrFingerprint()` per day slot (`AnalyzeRecentDayCache.cacheKey`'s witness) plus the whole-store
/// gate `analyzeIfStale` already checks first — not the multi-minute pass the original doc's "nothing to
/// do most of the time" language implied.
///
/// **Two different intervals, not one**, matching the "arm before work" pattern
/// `HealthWritebackBackgroundScheduler` already uses: the task's worker re-arms its OWN successor at the
/// conservative `noop` interval BEFORE calling `operation()` (so an expiration mid-work still leaves a
/// successor scheduled), then tightens it to the `scored` interval if the pass actually found something —
/// a run that did real work is evidence another might be waiting soon; a run that found nothing is not.
enum BackgroundAnalyzeSchedulePolicy {
    /// Re-arm interval after a pass that scored something. Matches `AnalyzePolicy.forcedFloorSeconds` —
    /// the cadence of the thing an automatic re-score is already throttled to elsewhere, so this doesn't
    /// introduce a tighter automatic cadence than the foreground path already allows.
    static let reArmAfterScoredSeconds: TimeInterval = AnalyzePolicy.forcedFloorSeconds

    /// Re-arm interval after a no-op or an expiration (outcome unknown). Deliberately longer — this is
    /// the "nothing to do right now" case the original one-shot design was trying to avoid polling
    /// tightly for; 4x the scored interval keeps a standing background presence without approaching a
    /// permanent tight cadence.
    static let reArmAfterNoopSeconds: TimeInterval = 4 * AnalyzePolicy.forcedFloorSeconds

    /// The `earliestBeginDate` for the next self-armed request. `scored` is whether the pass THIS
    /// interval follows found something (an expiration, whose outcome is unknown, should pass `false` —
    /// treat it the same as a no-op rather than assume it would have scored).
    static func earliestBeginDate(after date: Date, scored: Bool) -> Date {
        date.addingTimeInterval(scored ? reArmAfterScoredSeconds : reArmAfterNoopSeconds)
    }
}

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

    /// #1005-CONVERGE (2026-09-04): re-arm interval after a pass that did real work but was cut short
    /// before finishing its window. Same as `scored` — a truncated pass is the strongest possible signal
    /// that more work is waiting, so it must NOT fall into the no-op interval. It did, until this existed:
    /// a truncated pass reports no completed pass, which read as "nothing to do" and re-armed 60 minutes
    /// out. The 2026-09-04 device log shows exactly that hourly cadence, which cannot converge a window
    /// that needs several fires to finish.
    static let reArmAfterTruncatedSeconds: TimeInterval = AnalyzePolicy.forcedFloorSeconds

    /// What one delivered pass resolved to, for scheduling purposes.
    enum PassOutcome {
        /// Ran to completion and advanced the watermark.
        case scored
        /// Did real work and banked it, but was cancelled before finishing the window — more remains.
        case truncated
        /// Ran, found nothing new. The common case.
        case noop
    }

    /// The `earliestBeginDate` for the next self-armed request.
    static func earliestBeginDate(after date: Date, outcome: PassOutcome) -> Date {
        switch outcome {
        case .scored:    return date.addingTimeInterval(reArmAfterScoredSeconds)
        case .truncated: return date.addingTimeInterval(reArmAfterTruncatedSeconds)
        case .noop:      return date.addingTimeInterval(reArmAfterNoopSeconds)
        }
    }

    /// Two-way form, kept for the "arm before work" call that runs before any outcome is known (and for
    /// an expiration, whose outcome is unknown — it passes `false`, treating it as a no-op rather than
    /// assuming it would have scored).
    static func earliestBeginDate(after date: Date, scored: Bool) -> Date {
        earliestBeginDate(after: date, outcome: scored ? .scored : .noop)
    }
}

import Foundation
import StrandAnalytics

/// What prompted an `analyzeRecent` call. Mirrors `BackfillTrigger`'s shape
/// (`Strand/BLE/BackfillPolicy.swift`) , used to floor the AUTOMATIC cadence only, never the user- or
/// data-driven paths.
enum AnalyzeTrigger: Equatable {
    case postOffload  // refreshAfterCompletedBackfill, right after a completed sync
    case idleTick      // AppModel's 30-min steady-state cadence loop (#836 backstop)
    case background    // SyncAnalyzeBackgroundScheduler's BGProcessingTask, via analyzeIfStale()
    case dataChange    // every user- or data-driven caller: manual re-score, import, sleep/workout
                       // edit, recalibrate, the #547 heal, the #313 Effort rescore, device adoption.
                       // The default `AnalyzeTrigger` for `analyzeRecent`'s existing (pre-#1005-STORM)
                       // callers, so none of them are floored by this type's introduction.
}

/// A floored trigger's outcome: run now, or the earliest instant it may run.
enum AnalyzeDecision: Equatable {
    case run
    case deferUntil(TimeInterval)
}

/// #1005-STORM (2026-08-25): pure rate-limiter for the AUTOMATIC re-score cadence. No store/BLE/UI deps.
///
/// Why this exists: a device log pulled 2026-08-25 (post the overlap-removal fix already on this branch)
/// still showed 5 re-score passes / ~7.9 min CPU in a 44-minute window, versus a ≤2 passes / <2 min
/// target. The cause was that the original plan's forced-pass floor — explicitly deferred in commit
/// `59771a02`'s message, never implemented — never landed: nothing capped how often a FORCED
/// `analyzeRecent` pass could run, so the `#899-A` re-arm turned every dropped trigger into a full extra
/// pass (measured: the same 7 nights re-scored twice in 3 minutes, back to back).
///
/// Deliberately shaped like `BackfillPolicy` (`Strand/BLE/BackfillPolicy.swift`): a pure enum, a
/// `Trigger` naming what asked, and a `shouldRun`-shaped decision function — but this one returns
/// `AnalyzeDecision` rather than `Bool`, because a floored trigger must be DEFERRED, not dropped (an
/// automatic re-score guards a freshly-synced night's data reaching the dashboard, unlike a backfill kick
/// which the strap will simply re-offer on its own next tick). The caller (`IntelligenceEngine`) is
/// responsible for scheduling exactly one retry at the returned instant — see `deferredRescoreDueAt`.
enum AnalyzePolicy {
    /// At most one AUTOMATIC forced pass per floor interval. 900s matches
    /// `BackfillPolicy.periodicFloorSeconds` — the cadence of the thing this throttles: at most one
    /// analyze per periodic-offload window. At the measured ~48s steady-state pass cost, this caps
    /// automatic re-score duty cycle at ~5%.
    static let forcedFloorSeconds: TimeInterval = 900

    /// `trigger` — see `AnalyzeTrigger`. `now`/`lastPassEndedAt` — unix seconds; `lastPassEndedAt` is the
    /// wall-clock instant the most recent pass that ran to completion (not cancelled) finished, persisted
    /// so the floor survives a relaunch (iOS suspends/kills this process routinely — the measured window
    /// alone contained a 12-minute suspension, so an in-memory floor would reset for free on almost every
    /// morning's first background wake). `tzOffsetSec` — `TimeZone.current.secondsFromGMT()`, the SAME
    /// value `analyzeRecent`'s own day-key loop uses (`IntelligenceEngine.swift:381,574`), so the
    /// rollover boundary computed here is byte-identical to the one scoring uses.
    static func decide(trigger: AnalyzeTrigger, now: TimeInterval,
                       lastPassEndedAt: TimeInterval?, tzOffsetSec: Int) -> AnalyzeDecision {
        // `.dataChange`: every user- or data-driven caller. Same treatment `BackfillPolicy` gives
        // `.manual`/`.autoContinue` — deliberately un-floored, because a user action or a real data event
        // (import, edit, heal) must never wait on an automatic-cadence throttle.
        // `.background`: the BGProcessingTask wake via `analyzeIfStale()`. Nothing streams HR while the
        // process is suspended, so that caller's OWN whole-store `hrFingerprint()` gate (force: false) is
        // genuinely trustworthy here — unlike the foreground case, where live HR defeats it every second.
        // The wake is also already rationed by iOS's opportunistic BGProcessingTask scheduling, so a
        // second throttle on top would only delay an already-rare, already-cheap-when-no-op wake.
        switch trigger {
        case .dataChange, .background: return .run
        default: break
        }
        guard let last = lastPassEndedAt else { return .run }  // fresh install / first pass since the key was added
        // Backwards clock (timezone travel, clock correction) — never wedge on a bad clock. Self-healing:
        // the next `.run` advances `lastPassEndedAt` to a sane value.
        if now < last { return .run }
        // Local-day rollover: the first pass after local midnight must be allowed regardless of the floor
        // — it is the one that finalizes last night and opens today's slot. Uses the exact helper the
        // scoring loop uses for day keys, so this boundary can never disagree with scoring's own.
        if AnalyticsEngine.dayString(Int(now), offsetSec: tzOffsetSec)
            != AnalyticsEngine.dayString(Int(last), offsetSec: tzOffsetSec) {
            return .run
        }
        let elapsed = now - last
        return elapsed >= forcedFloorSeconds ? .run : .deferUntil(last + forcedFloorSeconds)
    }
}

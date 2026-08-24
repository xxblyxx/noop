import Foundation

/// #1005-STORM: a determinate 0…1 progress signal for "catching up on last night", deliberately
/// separate from `LiveState` so it does not ride the `@Published`-churn `LiveState` carries (~60
/// properties, invalidated on every live HR tick — see `LiveState.swift`'s doc notes on that).
///
/// TWO PHASES, one visible sweep:
///   - **Offload** (0…`offloadWeight`): the fraction of the record-frontier gap closed since this burst
///     started. The strap reports no pending-record COUNT anywhere in the protocol (`LiveState.swift`'s
///     `syncChunksThisSession` doc: "total pending is unknowable... a count, never a percent"), so this
///     is NOT a fraction of records — it is a fraction of WALL-CLOCK TIME closed, using the fact that the
///     record frontier (`Collector.latestHRSampleTs()`) advances in step with real time during a drain
///     (verified during the #1005-STORM investigation: a frontier delta of 2,189s against a measured wall
///     delta of 2,187s over 37 minutes on real hardware — within ~4s). `(frontier - frontierAtBurstStart)
///     / (now - frontierAtBurstStart)`, clamped 0…1.
///   - **Analyze** (`offloadWeight`…1): NOT record-counted — the per-day scoring loop
///     (`IntelligenceEngine.analyzeRecent`) runs inside a `@Sendable Task.detached` that captures nothing
///     MainActor-bound by design (see that file's comment at the detached-task call site), so wiring a
///     live per-day counter out of it means passing a `Sendable` counter in, a bigger change than this
///     session's budget covers carefully. Instead this phase is a smooth ELAPSED-TIME estimate against
///     `analyzeEstimateSeconds` (seeded from this device's own measured passes, not a guess pulled from
///     nowhere — see that constant's doc). This is a PRESENTATION choice, not a measurement: it can run
///     ahead of or behind the real pass. Documented here so nobody mistakes it for instrumented data.
///
/// `offloadWeight = 0.7`: the offload phase dominates wall time (tens of minutes vs. the analyze phase's
/// now-single-digit-seconds-to-~48s after the earlier commits on this branch), but the analyze phase is
/// the part users actually feel as lag (per the investigation, the CPU cost lives there) — parking the
/// bar at 90% for the whole felt-laggy part would read backwards. Giving analyze the last 30% keeps the
/// bar visibly moving during the part that matters, at the cost of the split not being time-proportional.
@MainActor
public final class SyncProgress: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case offload
        case analyze
    }

    /// 0…1. Callers should treat `phase == .idle` as "hide the bar" regardless of this value.
    @Published public private(set) var fraction: Double = 0
    @Published public private(set) var phase: Phase = .idle

    private static let offloadWeight = 0.7

    /// Seed for the analyze-phase time estimate. #1005-STORM's on-device baseline (post the earlier
    /// commits on this branch, which removed the overlap/repeat-pass inflation) measured single-digit
    /// seconds to ~48s per pass for a small history; this errs toward the slower end so the bar rarely
    /// completes and stalls before the real pass finishes. Deliberately NOT tied to this device's actual
    /// history size (that would need a store read this object has no access to) — a rough shared estimate,
    /// not a per-user measurement.
    private static let analyzeEstimateSeconds: TimeInterval = 45

    private var frontierAtBurstStart: Int?
    private var burstStartedAt: Date?
    private var analyzeStartedAt: Date?

    /// Call once, from `beginBackfill`, ONLY when `consecutiveAutoContinues == 0` (a fresh burst, not an
    /// auto-continue re-kick within an already-tracked one) — an auto-continue must NOT reset the frontier
    /// anchor, or the bar would jump back toward 0 on every continuation instead of sweeping smoothly
    /// across the whole burst.
    public func beginOffload(frontier: Int?) {
        frontierAtBurstStart = frontier
        burstStartedAt = Date()
        phase = .offload
        fraction = 0
    }

    /// Call per acked chunk (`ackHistoricalChunk`) with the current record frontier. A nil frontier (no HR
    /// banked yet this burst) or a missing `frontierAtBurstStart` (should not happen if `beginOffload` ran
    /// first, but defensive) leaves `fraction` at its last value rather than jumping — a transient nil read
    /// must not visibly regress the bar.
    public func updateOffload(frontier: Int?) {
        guard phase == .offload, let start = frontierAtBurstStart, let startedAt = burstStartedAt,
              let frontier else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0 else { return }
        let closed = Double(frontier - start)
        let total = elapsed  // frontier tracks wall-clock 1:1 during a drain (see type doc)
        let raw = total > 0 ? closed / total : 0
        fraction = min(max(raw, 0), 1) * Self.offloadWeight
    }

    /// Call once the offload burst has fully finished (no more auto-continue) and the post-sync analyze
    /// pass is starting. Transitions to the time-estimated second phase.
    public func beginAnalyze() {
        phase = .analyze
        analyzeStartedAt = Date()
        fraction = Self.offloadWeight
    }

    /// Call on a timer (or per-tick) while `phase == .analyze` to advance the estimated fill. Safe to call
    /// when not in the analyze phase (no-op).
    public func tickAnalyzeEstimate() {
        guard phase == .analyze, let startedAt = analyzeStartedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let raw = min(elapsed / Self.analyzeEstimateSeconds, 1)
        fraction = Self.offloadWeight + raw * (1 - Self.offloadWeight)
    }

    /// Call when the whole chain (offload + analyze) is done — `refreshAfterCompletedBackfill` returning,
    /// or an abort/disconnect. Resets to hidden.
    public func finish() {
        phase = .idle
        fraction = 0
        frontierAtBurstStart = nil
        burstStartedAt = nil
        analyzeStartedAt = nil
    }
}

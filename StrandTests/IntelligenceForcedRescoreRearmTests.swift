import XCTest
@testable import Strand

/// Pins the #899-A forced-rescore re-arm contract in `IntelligenceEngine.analyzeRecent`.
///
/// THE BUG: `analyzeRecent` opens with `guard !computing else { return }`. A `force: true` post-backfill
/// recompute (AppModel kicks one off after a sync) that arrives while a 15-min idle tick already holds the
/// `computing` lock was SILENTLY DROPPED, so a freshly-synced WHOOP 5.0 night intermittently never got
/// re-scored until the next cycle and Today fell back to the last scored day.
///
/// THE FIX: a dropped FORCED call sets `pendingForcedRescore`; the in-flight pass's `defer` clears the flag
/// and re-invokes `analyzeRecent(force: true)` ONCE. A NON-forced idle tick is still safely dropped (the
/// running pass already covers the same window). The flag is cleared BEFORE the re-invoke (a single re-arm),
/// so a quiet pass cannot recurse and a forced call landing DURING the re-invoke re-arms it again , exactly
/// once per genuinely-dropped force.
///
/// The engine's re-arm is a tiny `(computing, force) → drop | rearm` state machine plus a "rerun once when
/// the flag is set at defer time" rule. `IntelligenceEngine` is `@MainActor` and needs a live store/repo to
/// run a real pass (not constructible in a unit context), so this models the SAME decision rules the engine
/// implements and pins the contract: a forced call during an in-flight pass schedules EXACTLY ONE rerun, a
/// non-forced one schedules NONE, and the re-arm can never loop. Mirrors the Android no-op rationale: Android
/// has no shared `computing` lock (the forced post-backfill rescore runs on its own ioScope coroutine and is
/// never dropped), so there is nothing to re-arm there.
///
/// #1005-STORM (2026-08-25) EXTENSION: `analyzeRecent` now checks `AnalyzePolicy`'s forced-pass floor
/// BEFORE this re-arm's own `guard !computing`, and the re-arm carries the dropped call's `trigger`/
/// `skipIfUnchanged` into its re-invoke instead of hardcoding `.dataChange`/`force: true`. A device log
/// pulled 2026-08-25 showed WHY this matters: a `.postOffload` re-arm re-invoked IMMEDIATELY (no floor)
/// re-scored the same 7 nights twice in 3 minutes, back to back. `RearmModel` below models both the
/// original lock and the floor together, so the tests can pin that a floored automatic re-arm defers
/// (never drops) instead of running twice.
final class IntelligenceForcedRescoreRearmTests: XCTestCase {

    /// A faithful model of the engine's re-arm state machine. Each method mirrors one decision in
    /// `analyzeRecent`: the floor check, the entry guard, and the `defer`. `reruns` counts how many times
    /// the `defer` would re-invoke `analyzeRecent(force: true, …)`; `runsStarted` counts how many times a
    /// pass actually began (`computing` flipped true) — the thing that must eventually happen at least
    /// once for any genuinely dropped forced call, floored or not.
    private struct RearmModel {
        private(set) var computing = false
        private(set) var pendingForcedRescore = false
        private(set) var pendingTrigger: AnalyzeTrigger?
        private(set) var pendingSkipIfUnchanged = false
        private(set) var reruns = 0
        private(set) var runsStarted = 0
        private(set) var deferredRescoreDueAt: TimeInterval?
        private(set) var lastPassEndedAt: TimeInterval?

        /// Mirrors `analyzeRecent`'s full prelude: `AnalyzePolicy`'s floor FIRST (before any lock check —
        /// a floored trigger never touches `computing`/`pendingForcedRescore`), then the `#899-A` lock
        /// guard with the most-privileged-wins merge (see `IntelligenceEngine.pendingForcedRescoreTrigger`'s
        /// doc). Returns true when the call proceeds into the body (took the lock, started a pass).
        /// `trigger` defaults to `.dataChange` — production's own bypass default — so existing calls below
        /// that only pass `force:` are unaffected by the floor, exactly as in production.
        mutating func enter(force: Bool, trigger: AnalyzeTrigger = .dataChange,
                            skipIfUnchanged: Bool = false, now: TimeInterval = 0) -> Bool {
            switch AnalyzePolicy.decide(trigger: trigger, now: now, lastPassEndedAt: lastPassEndedAt, tzOffsetSec: 0) {
            case .deferUntil(let dueAt):
                deferredRescoreDueAt = dueAt
                return false
            case .run:
                break
            }
            if computing {
                if force {
                    pendingForcedRescore = true
                    if pendingTrigger == nil || trigger == .dataChange {
                        pendingTrigger = trigger
                        pendingSkipIfUnchanged = skipIfUnchanged
                    }
                }
                return false
            }
            computing = true
            deferredRescoreDueAt = nil
            runsStarted += 1
            return true
        }

        /// The body's `defer`: clear the lock, advance the floor's watermark to `now`, then if a forced
        /// rescore was dropped while we held it, clear the flag (single re-arm) and re-invoke once with
        /// the CARRIED trigger/gate. The re-invoke runs its OWN `enter()`/`leave()` — including the floor
        /// check — so a nested re-arm, and a nested FLOORED re-arm, are both modelled.
        mutating func leave(now: TimeInterval = 0) {
            computing = false
            lastPassEndedAt = now
            let wasPending = pendingForcedRescore
            pendingForcedRescore = false
            let rearmTrigger = pendingTrigger ?? .dataChange
            let rearmSkipIfUnchanged = pendingSkipIfUnchanged
            pendingTrigger = nil
            pendingSkipIfUnchanged = false
            if wasPending {
                reruns += 1
                // The re-invoke is `analyzeRecent(force: true, skipIfUnchanged: …, trigger: …)`: it
                // re-enters (lock is free now, `lastPassEndedAt` was JUST set to `now` above) and leaves.
                if enter(force: true, trigger: rearmTrigger, skipIfUnchanged: rearmSkipIfUnchanged, now: now) {
                    leave(now: now)
                }
                // If `enter` returned false here, the re-invoke was floored: `deferredRescoreDueAt` is set
                // and the model stops , matching production, where a real caller awaits the scheduled
                // retry (`AppModel`'s `$deferredRescoreDueAt` sink) instead of looping synchronously.
            }
        }
    }

    /// A forced call dropped while a pass is in-flight schedules EXACTLY ONE rerun.
    func testForcedCallDuringInFlightPassSchedulesExactlyOneRerun() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))          // idle tick / first pass takes the lock
        XCTAssertFalse(m.enter(force: true))         // a forced post-sync call lands mid-flight → dropped + re-armed
        XCTAssertTrue(m.pendingForcedRescore)
        m.leave()                                    // the in-flight pass finishes → re-arms once
        XCTAssertEqual(m.reruns, 1, "a dropped forced call must trigger exactly one rerun")
        XCTAssertFalse(m.pendingForcedRescore, "the flag is cleared by the single re-arm")
        XCTAssertFalse(m.computing, "the lock is released after the rerun")
    }

    /// A NON-forced idle tick dropped while a pass is in-flight is NOT re-armed (the running pass already
    /// covers the same window) , so no rerun, no wasted recompute.
    func testNonForcedCallDuringInFlightPassIsNotRearmed() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))
        XCTAssertFalse(m.enter(force: false))        // a non-forced idle tick lands mid-flight → dropped, NOT re-armed
        XCTAssertFalse(m.pendingForcedRescore)
        m.leave()
        XCTAssertEqual(m.reruns, 0)
    }

    /// A pass with NOTHING dropped while it ran re-arms NOTHING , the re-arm can't fire spuriously.
    func testQuietPassDoesNotRerun() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))
        m.leave()
        XCTAssertEqual(m.reruns, 0)
        XCTAssertFalse(m.pendingForcedRescore)
        XCTAssertFalse(m.computing)
    }

    /// Many forced calls piling up against ONE in-flight pass collapse to a SINGLE rerun (the flag is a
    /// boolean latch, not a counter) , the re-arm bounds the extra work to one pass, never a storm.
    func testMultipleDroppedForcedCallsCollapseToOneRerun() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))
        for _ in 0..<5 { XCTAssertFalse(m.enter(force: true)) }   // five forced calls all land mid-flight
        m.leave()
        XCTAssertEqual(m.reruns, 1, "the boolean latch collapses N dropped forces to one rerun")
    }

    /// The single re-arm terminates: a forced call that lands DURING the re-invoke re-arms exactly once more
    /// (one extra pass), and once nothing new lands the chain stops , it can never recurse unbounded.
    func testReArmTerminatesAndDoesNotLoop() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true))
        XCTAssertFalse(m.enter(force: true))         // one forced call dropped against the first pass
        m.leave()                                    // re-arms once; the re-invoke runs to completion cleanly
        XCTAssertEqual(m.reruns, 1)
        XCTAssertFalse(m.pendingForcedRescore)
        XCTAssertFalse(m.computing)                  // settled , no lingering lock, no further reruns queued
    }

    // MARK: - #1005-STORM (2026-08-25): the forced-pass floor + carried re-arm

    /// The single most important test in this extension: a floored `.postOffload` trigger must result in
    /// EXACTLY ONE pass eventually running, never zero , this is the assertion that proves the floor did
    /// NOT reintroduce the silent-drop failure `#899-A` exists to prevent.
    func testFlooredPostOffloadTriggerStillEventuallyRunsExactlyOnePass() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: true, trigger: .postOffload, skipIfUnchanged: true, now: 0))
        m.leave(now: 0)
        XCTAssertEqual(m.runsStarted, 1)
        // A post-offload trigger 30s later is floored , 900s hasn't elapsed.
        XCTAssertFalse(m.enter(force: true, trigger: .postOffload, skipIfUnchanged: true, now: 30))
        XCTAssertNotNil(m.deferredRescoreDueAt, "a floored trigger must schedule a retry, not vanish")
        XCTAssertFalse(m.computing, "a floored trigger never touches the lock")
        XCTAssertFalse(m.pendingForcedRescore, "a floored trigger never sets the #899-A flag , it can't, it never reached that guard")
        // AppModel's `$deferredRescoreDueAt` retry sink fires at the deferred instant , simulate it.
        let retryAt = m.deferredRescoreDueAt!
        XCTAssertTrue(m.enter(force: true, trigger: .postOffload, skipIfUnchanged: true, now: retryAt))
        m.leave(now: retryAt)
        XCTAssertEqual(m.runsStarted, 2, "the floored trigger eventually ran , no data was ever silently dropped")
    }

    /// Replays the 2026-08-25 device log's measured timeline: pass 1 (the cold launch cadence tick) runs
    /// from t=0 to t=1021; a `.postOffload` trigger lands at t=33 and is dropped mid-flight; the re-arm
    /// fires in pass 1's `defer`. Without Commits 2+3, the re-invoke ran IMMEDIATELY , a second full pass
    /// at t=1021, then a THIRD shortly after (the measured chain). With the floor + carried trigger, the
    /// re-invoke's own `lastPassEndedAt` is already t=1021 (just set by the SAME `leave()` call), so it is
    /// floored and becomes ONE deferred retry instead.
    func testMeasuredChainCollapsesToOneDeferredPass() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: false, trigger: .idleTick, now: 0))                 // pass 1 starts
        XCTAssertFalse(m.enter(force: true, trigger: .postOffload, skipIfUnchanged: true, now: 33))  // dropped
        XCTAssertTrue(m.pendingForcedRescore)
        m.leave(now: 1021)                                                                // pass 1 ends
        XCTAssertEqual(m.runsStarted, 1, "the re-armed call must NOT start a second pass immediately")
        XCTAssertEqual(m.reruns, 1, "exactly one re-arm was scheduled")
        XCTAssertEqual(m.deferredRescoreDueAt, 1021 + AnalyzePolicy.forcedFloorSeconds,
                       "the re-arm's own re-invoke was floored , it must retry later, not vanish")
    }

    /// `.dataChange` (a heal/import/edit/recalibrate) dropped against an in-flight pass re-runs
    /// IMMEDIATELY on re-arm, never floored , a real data event must never wait on the automatic-cadence
    /// throttle.
    func testDataChangeTriggerIsNeverFloored() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: false, trigger: .idleTick, now: 0))
        XCTAssertFalse(m.enter(force: true, trigger: .dataChange, now: 10))     // e.g. the #547 heal fires mid-pass
        m.leave(now: 100)
        XCTAssertEqual(m.runsStarted, 2, ".dataChange re-arms must run immediately, never floored")
        XCTAssertEqual(m.reruns, 1)
        XCTAssertNil(m.deferredRescoreDueAt)
        XCTAssertFalse(m.computing, "the immediate re-invoke also completed synchronously in this model")
    }

    /// Most-privileged-wins merge (`IntelligenceEngine.pendingForcedRescoreTrigger`'s doc): once a
    /// `.dataChange` drop is recorded, a LATER `.postOffload` drop against the same in-flight pass must
    /// never downgrade it , and the reverse order must never let a `.postOffload` drop block `.dataChange`
    /// from winning once it arrives.
    func testMergedRearmKeepsTheMostPrivilegedTrigger() {
        var m = RearmModel()
        XCTAssertTrue(m.enter(force: false, trigger: .idleTick, now: 0))
        XCTAssertFalse(m.enter(force: true, trigger: .postOffload, skipIfUnchanged: true, now: 10))
        XCTAssertEqual(m.pendingTrigger, .postOffload)
        XCTAssertTrue(m.pendingSkipIfUnchanged)
        XCTAssertFalse(m.enter(force: true, trigger: .dataChange, skipIfUnchanged: false, now: 20))
        XCTAssertEqual(m.pendingTrigger, .dataChange, ".dataChange must override an already-pending .postOffload")
        XCTAssertFalse(m.pendingSkipIfUnchanged, "merging into .dataChange must also clear skipIfUnchanged")

        var m2 = RearmModel()
        XCTAssertTrue(m2.enter(force: false, trigger: .idleTick, now: 0))
        XCTAssertFalse(m2.enter(force: true, trigger: .dataChange, now: 10))
        XCTAssertFalse(m2.enter(force: true, trigger: .postOffload, skipIfUnchanged: true, now: 20))
        XCTAssertEqual(m2.pendingTrigger, .dataChange, "a later .postOffload drop must never overwrite a pending .dataChange")
    }

    /// The retry chain is bounded and each cycle's deferral strictly increases , it can never get stuck
    /// repeating the same instant, and (by construction , `deferredRescoreDueAt` is a single `Date?`, not
    /// a queue) there is never more than one outstanding retry.
    func testRetryChainTerminates() {
        var m = RearmModel()
        var t: TimeInterval = 0
        var previousDue: TimeInterval = -1
        for cycle in 0..<5 {
            XCTAssertTrue(m.enter(force: true, trigger: .postOffload, skipIfUnchanged: true, now: t),
                          "cycle \(cycle): the floor must be satisfied by the time the retry fires")
            m.leave(now: t)
            let triggerAt = t + 5
            XCTAssertFalse(m.enter(force: true, trigger: .postOffload, skipIfUnchanged: true, now: triggerAt))
            let due = m.deferredRescoreDueAt!
            XCTAssertGreaterThan(due, previousDue, "cycle \(cycle): each deferral must strictly increase")
            previousDue = due
            t = due
        }
    }
}

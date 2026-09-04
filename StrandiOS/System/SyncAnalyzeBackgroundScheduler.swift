#if os(iOS)
import BackgroundTasks
import Foundation

/// Background pass that scores already-banked strap data when the foreground/BLE-connected analyze path
/// (`AppModel.refreshAfterCompletedBackfill`) never got to run — the strap disconnected right after
/// HISTORY_COMPLETE (taken off to charge, walked out of range) before its 30s post-offload debounce fired
/// or its analyze pass finished, and iOS suspended the process. `bluetooth-central` only keeps NOOP alive
/// for an ACTIVE BLE session, not after the link drops, so this is the only path that finishes a deferred
/// night's scoring without the user reopening the app. #1005-STORM.
///
/// **Self-re-arms inside its own task body** (#1005-STORM follow-up), mirroring
/// `HealthWritebackBackgroundScheduler` — see `BackgroundAnalyzeSchedulePolicy`'s doc for why the original
/// deliberately-one-shot design left real nights unscored. `schedule()` is still ALSO called on every
/// `.background` scene transition and on every completed offload (`AppModel.armBackgroundAnalyzeFallback`)
/// — those submit with NO `earliestBeginDate` (fire as soon as iOS is willing; a genuine new opportunity),
/// while the self-re-arm here submits with an explicit, policy-driven one, so it stays a bounded floor
/// rather than an unbounded standing cadence. Whichever call happens most recently wins (both `cancel()`
/// the pending request first), which is correct — the most recent signal is the most informative one.
///
/// Opportunistic, not a guarantee — `BGProcessingTaskRequest` scheduling is entirely up to iOS and may be
/// delayed or skipped, especially unplugged. This is an ADDITIONAL path, not a replacement for the one
/// that actually runs today: `bluetooth-central` keeps the process alive for the live BLE session itself.
@MainActor
enum SyncAnalyzeBackgroundScheduler {
    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".analyze"

    /// Register at launch, before the first scene finishes connecting — iOS only delivers a background
    /// task whose identifier was registered at launch AND listed in `BGTaskSchedulerPermittedIdentifiers`
    /// (project.yml).
    /// `operation` returns whether the pass actually scored anything (`false` = the fingerprint gate
    /// found nothing new, the common case) — recorded as the delivered task's outcome.
    static func register(
        perform operation: @escaping @MainActor () async -> BackgroundAnalyzeSchedulePolicy.PassOutcome
    ) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                BackgroundAnalyzeTelemetry.recordFire()
                // Arm the successor BEFORE doing any work, mirroring
                // `HealthWritebackBackgroundScheduler.register` — an expiration below cannot leave the
                // deferred-analyze path permanently unscheduled. Conservative (`scored: false`) interval
                // since the outcome isn't known yet; tightened below if this pass actually scores.
                scheduleReArm(scored: false)
                let outcome = await operation()
                // #1005-COST: report completion HERE on both paths — the cancelled one too. When the
                // `expirationHandler` cancels this worker, `analyzeRecent` unwinds its per-day scan,
                // writes back the newest nights it did finish, and PERSISTS that partial checkpoint to
                // `DayScanCacheStore` synchronously before `operation()` returns. So by this line the
                // checkpoint is on disk and it is safe to tell iOS we're done. The old code called
                // `completion.finish(success: false)` straight from the `expirationHandler`, which
                // green-lit suspension immediately and raced that persist — a killed pass then kept
                // none of its work.
                guard !Task.isCancelled else {
                    completion.finish(success: false)
                    return
                }
                // #1005-CONVERGE (2026-09-04): three-way, not two. A `.truncated` pass banked real work
                // and has more of the window waiting, so it re-arms at the SHORT interval like `.scored`.
                // Previously it was indistinguishable from `.noop` and re-armed 60 minutes out — the exact
                // hourly cadence the device log showed, which cannot converge a window that needs several
                // fires. `.noop` keeps the long interval: nothing to do is genuinely worth backing off for.
                BackgroundAnalyzeTelemetry.recordOutcome(
                    outcome == .scored ? .scored : (outcome == .truncated ? .truncated : .noop))
                if outcome != .noop { scheduleReArm(outcome: outcome) }
                completion.finish(success: true)
            }
            task.expirationHandler = {
                BackgroundAnalyzeTelemetry.recordOutcome(.expired)
                worker.cancel()
                // Deliberately do NOT `completion.finish()` here — the worker does it above once its
                // partial checkpoint is persisted. This bounded fallback only fires if that unwind
                // stalls past the grace iOS gives after `expirationHandler` returns, so the task still
                // reports done and scheduling isn't frozen. `TaskCompletionGuard` is single-shot, so
                // whichever call lands first wins and the other is a no-op.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    completion.finish(success: false)
                }
            }
        }
    }

    /// Submit one request that fires as soon as iOS is willing (no `earliestBeginDate`) — a genuine new
    /// opportunity: called from the `.background` scene-phase transition and from
    /// `AppModel.armBackgroundAnalyzeFallback` on every completed offload. Returns whether the submit
    /// itself succeeded (distinct from whether iOS ever actually RUNS the task, which this can't observe)
    /// — the caller logs a failure, since `runBackgroundAnalyze`'s own "scored=" line only tells the
    /// device log the task fired at all, not that requesting it worked.
    @discardableResult
    static func schedule() -> Bool {
        submit(earliestBeginDate: nil)
    }

    /// The self-re-arm submitted from inside the task's own body — see `BackgroundAnalyzeSchedulePolicy`.
    /// Private: every OTHER caller wants "as soon as possible" (`schedule()`), never a deferred date.
    private static func scheduleReArm(scored: Bool) {
        let date = BackgroundAnalyzeSchedulePolicy.earliestBeginDate(after: Date(), scored: scored)
        submit(earliestBeginDate: date)
    }

    /// #1005-CONVERGE: three-way form, for the post-work re-arm where the outcome is actually known.
    private static func scheduleReArm(outcome: BackgroundAnalyzeSchedulePolicy.PassOutcome) {
        let date = BackgroundAnalyzeSchedulePolicy.earliestBeginDate(after: Date(), outcome: outcome)
        submit(earliestBeginDate: date)
    }

    @discardableResult
    private static func submit(earliestBeginDate: Date?) -> Bool {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
            BackgroundAnalyzeTelemetry.recordSubmit(ok: true, error: nil)
            return true
        } catch {
            // Was swallowed before — capture it. `.notPermitted` here means the `processing` mode /
            // `.analyze` identifier never took effect on this install (an OTA upgrade over a build
            // without them needs a fresh install), which a bare `false` could not distinguish from
            // "iOS declined to run it".
            BackgroundAnalyzeTelemetry.recordSubmit(ok: false, error: error)
            return false
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    /// `BGTask` completion is single-shot even when normal completion races expiration.
    private final class TaskCompletionGuard: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var finished = false

        init(task: BGTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
            task.expirationHandler = nil
        }
    }
}
#endif

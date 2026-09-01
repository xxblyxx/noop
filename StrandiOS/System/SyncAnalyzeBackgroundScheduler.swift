#if os(iOS)
import BackgroundTasks
import Foundation

/// One-shot background pass that scores already-banked strap data when the foreground/BLE-connected
/// analyze path (`AppModel.refreshAfterCompletedBackfill`) never got to run — the strap disconnected
/// right after HISTORY_COMPLETE (taken off to charge, walked out of range) before its 30s post-offload
/// debounce fired or its analyze pass finished, and iOS suspended the process. `bluetooth-central` only
/// keeps NOOP alive for an ACTIVE BLE session, not after the link drops, so this is the only path that
/// finishes a deferred night's scoring without the user reopening the app. #1005-STORM.
///
/// Deliberately does NOT self-re-arm inside its own task body, unlike `HealthWritebackBackgroundScheduler`
/// (which is "always plausibly pending" while HealthKit access stays authorized). An analyze wake is
/// USUALLY a no-op — `AppModel.runBackgroundAnalyze` defers to `analyzeRecent`'s `force: false` fingerprint
/// gate, which correctly skips when nothing changed since the last pass. A permanent re-arm would buy a
/// standing background cadence for a handler that has nothing to do most of the time; instead `schedule()`
/// is called once per `.background` scene transition (mirroring the debug-export / health-writeback
/// re-submit-on-every-transition pattern), so a request exists only when the app might actually have left
/// something unscored.
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
    static func register(perform operation: @escaping @MainActor () async -> Bool) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                BackgroundAnalyzeTelemetry.recordFire()
                let scored = await operation()
                guard !Task.isCancelled else { return }
                BackgroundAnalyzeTelemetry.recordOutcome(scored ? .scored : .noop)
                completion.finish(success: true)
            }
            task.expirationHandler = {
                worker.cancel()
                BackgroundAnalyzeTelemetry.recordOutcome(.expired)
                completion.finish(success: false)
            }
        }
    }

    /// Submit one request. Called from the `.background` scene-phase transition; NOT called from inside
    /// the task's own body — see the type doc for why this is deliberately one-shot, not self-re-arming.
    /// Returns whether the submit itself succeeded (distinct from whether iOS ever actually RUNS the
    /// task, which this can't observe) — the caller logs a failure, since `runBackgroundAnalyze`'s own
    /// "scored=" line only tells the device log the task fired at all, not that requesting it worked.
    @discardableResult
    static func schedule() -> Bool {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
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

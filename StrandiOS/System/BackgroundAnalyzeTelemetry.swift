#if os(iOS)
import Foundation

/// Durable record of what the deferred-analyze `BGProcessingTask` (`SyncAnalyzeBackgroundScheduler`)
/// actually did, written to `UserDefaults` so it survives the app being suspended/killed for hours.
///
/// Why not the strap log: the live `strapLog.tail` holds ~2000 lines plus three 1000-line generations —
/// roughly a connected morning's worth. A question like "did the analyze task run at all between 01:00
/// and 08:00 last night?" is a 7-hour question, and by the time the owner opens the app the lines that
/// would answer it are long gone. These keys are a handful of scalars and answer it directly from a
/// `devicectl` plist pull (or the debug export, via `debugLines()`).
///
/// NOT added to `BackupSettings`'s import whitelist — device-local scheduling state must never be
/// carried in from another device's `.noopbak`, same precedent as `noop.analyzeWatermark`
/// (`IntelligenceEngine.swift`). These keys are write-only telemetry; nothing reads them back into a
/// decision.
enum BackgroundAnalyzeTelemetry {

    /// What one delivered background pass resolved to.
    enum Outcome: String {
        /// `runBackgroundAnalyze` found stale data and scored it.
        case scored
        /// The pass ran but `analyzeIfStale`'s fingerprint gate found nothing new (the common case).
        case noop
        /// iOS fired the task's `expirationHandler` before the pass finished — it was cancelled.
        case expired
    }

    private static let prefix = "noop.analyze.bg."
    private static var d: UserDefaults { .standard }

    // MARK: - Write (called only from SyncAnalyzeBackgroundScheduler)

    /// Record the result of asking iOS to schedule the task. `error` is the thrown `BGTaskScheduler`
    /// error, if any — `.notPermitted` here means the `processing` background mode / `.analyze`
    /// identifier never took effect for this install (needs a fresh install), which is otherwise
    /// indistinguishable from "iOS just never ran it".
    static func recordSubmit(ok: Bool, error: Error?) {
        d.set(Date().timeIntervalSince1970, forKey: prefix + "lastSubmitAt")
        d.set(ok, forKey: prefix + "lastSubmitOK")
        if let error {
            d.set(String(describing: error), forKey: prefix + "lastSubmitError")
        } else {
            d.removeObject(forKey: prefix + "lastSubmitError")
        }
    }

    /// iOS delivered the task and its worker started.
    static func recordFire() {
        d.set(Date().timeIntervalSince1970, forKey: prefix + "lastFireAt")
        d.set(d.integer(forKey: prefix + "fireCount") + 1, forKey: prefix + "fireCount")
    }

    /// The pass resolved (or was expired). Bumps `expireCount` on `.expired`.
    static func recordOutcome(_ outcome: Outcome) {
        d.set(outcome.rawValue, forKey: prefix + "lastOutcome")
        d.set(Date().timeIntervalSince1970, forKey: prefix + "lastOutcomeAt")
        if outcome == .expired {
            d.set(d.integer(forKey: prefix + "expireCount") + 1, forKey: prefix + "expireCount")
        }
    }

    // MARK: - Stage breadcrumbs (#1005-CONVERGE, 2026-09-04)

    /// Why this exists: on 2026-09-04 the device showed `fireCount` 20 → 31 — iOS granted 11 background
    /// windows — while `lastOutcome`/`lastOutcomeAt` stayed frozen at the previous evening and
    /// `expireCount` never moved. Every write above is a bare `UserDefaults.set` with no flush, and
    /// `recordFire` runs at the START of a pass (minutes of process life for the periodic flush to land
    /// it) while `recordOutcome` runs at the END, immediately before whatever ends the process. So
    /// "fireCount persisted, outcome didn't" is equally consistent with "control flow never got there"
    /// and "it got there and the write was lost" — and the two want completely different fixes.
    ///
    /// These breadcrumbs settle it. Each records WHERE the pass was last seen alive and is forced to
    /// disk immediately, so an unannounced termination still leaves the marker behind.
    ///
    /// Gated on `passInFlight` so this costs nothing on the foreground paths, which run the same
    /// diagnostics constantly and must not pay a synchronous flush per line.
    @MainActor private static var passInFlight = false

    /// Milestones, in the order a healthy pass passes them. Matched by prefix against the lines
    /// `IntelligenceEngine`/`AppModel` already emit, so the engine needs no new API and there is no
    /// second set of call sites to keep in step — the cost is that renaming a diagnostic line silently
    /// stops a breadcrumb, which `debugLines()` makes visible by showing the stage it did reach.
    private static let stageMarkers: [(prefix: String, stage: String)] = [
        ("re-score: trigger=", "analyzeEntered"),
        ("analyzeRecent dayCache LOADED", "cacheLoaded"),
        ("analyzeRecent dayCache DROPPED", "cacheDropped"),
        ("analyzeRecent dayCache reused=", "scanFinished"),
        ("analyzeRecent cost prep=", "costTallied"),
        ("analyzeRecent CANCELLED mid-scan", "scanTruncated"),
        ("re-score: done", "pass2Finished"),
        ("background analyze: scored=", "returned"),
    ]

    /// Bracket one delivered background pass. `runBackgroundAnalyze` owns both calls.
    @MainActor static func beginPass() {
        passInFlight = true
        write(stage: "fired")
    }

    @MainActor static func endPass() { passInFlight = false }

    /// Tap on the engine's existing diagnostic sink — see `AppModel.init()`'s wiring.
    @MainActor static func noteStage(_ line: String) {
        guard passInFlight,
              let marker = stageMarkers.first(where: { line.hasPrefix($0.prefix) }) else { return }
        write(stage: marker.stage)
    }

    @MainActor private static func write(stage: String) {
        d.set(stage, forKey: prefix + "lastStage")
        d.set(Date().timeIntervalSince1970, forKey: prefix + "lastStageAt")
        // The whole point: survive a termination that gives no notice. `synchronize()` is the only
        // forced flush `UserDefaults` offers; it is documented as unnecessary for normal use, which is
        // exactly why it is warranted here and nowhere else in this file.
        d.synchronize()
    }

    // MARK: - Read (debug export)

    /// Lines for the iOS debug export's "Strap & data" block — so the record rides the shareable log,
    /// not only a raw plist pull.
    static func debugLines() -> [String] {
        var lines: [String] = [String(repeating: "─", count: 40), "Background analyze (#1005-STORM)"]
        let now = Date().timeIntervalSince1970
        func rel(_ key: String) -> String {
            let t = d.double(forKey: prefix + key)
            return t > 0 ? relTime(now - t) : "never"
        }
        let submitAt = d.double(forKey: prefix + "lastSubmitAt")
        if submitAt > 0 {
            let ok = d.bool(forKey: prefix + "lastSubmitOK")
            var l = "Last submit: \(rel("lastSubmitAt")) · \(ok ? "ok" : "FAILED")"
            if let err = d.string(forKey: prefix + "lastSubmitError") { l += " — \(err)" }
            lines.append(l)
        } else {
            lines.append("Last submit: never (app has not backgrounded since install?)")
        }
        let fires = d.integer(forKey: prefix + "fireCount")
        lines.append("Delivered: \(fires)× · last \(rel("lastFireAt"))")
        let outcome = d.string(forKey: prefix + "lastOutcome") ?? "—"
        let expires = d.integer(forKey: prefix + "expireCount")
        lines.append("Last outcome: \(outcome) (\(rel("lastOutcomeAt")))\(expires > 0 ? " · \(expires) expired total" : "")")
        // #1005-CONVERGE: the discriminator. A `lastStage` NEWER than `lastOutcomeAt` means the pass got
        // that far and then died without recording an outcome — which is the failure this was added to
        // catch. A stage of `fired` alone means it never even reached `analyzeRecent`.
        if let stage = d.string(forKey: prefix + "lastStage") {
            lines.append("Last stage: \(stage) (\(rel("lastStageAt")))")
        }
        return lines
    }

    private static func relTime(_ deltaSec: Double) -> String {
        if deltaSec < 60 { return "just now" }
        let min = Int(deltaSec / 60)
        switch true {
        case min < 60:   return "\(min)m ago"
        case min < 1440: return "\(min / 60)h \(min % 60)m ago"
        default:         return "\(min / 1440)d ago"
        }
    }
}
#endif

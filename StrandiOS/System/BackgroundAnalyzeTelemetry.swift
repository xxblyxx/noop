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

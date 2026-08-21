import Foundation
import WhoopStore
import StrandDesign

/// The wrist glance's PURE composition rules — how resolved glance fields plus the day rows they came
/// from become a `WatchScoreSnapshot`, including the calibrating-vs-missing honesty rule and the sleep
/// line's formatting.
///
/// Deliberately NOT inside `WatchSessionBridge`, which is `#if os(iOS)`-gated: nothing here is
/// iOS-specific, and the app-target test bundle builds for macOS. Keeping the rules platform-neutral is
/// what makes them assertable without a phone, a watch or an `AppModel` (see `WatchGlanceComposeTests`).
/// `WatchSessionBridge.buildSnapshot` reads the store and then calls straight through to this.
enum WatchGlance {

    /// The honesty rules, pure and testable.
    ///
    /// A missing number that is genuinely mid-calibration is flagged so the watch shows a cal marker, not
    /// a dash that looks like an outage. `hasAnyData` is what separates the two: with NO day data at all
    /// (a fresh, never-synced phone) every flag stays false and the watch shows its neutral "open NOOP on
    /// your iPhone" empty state instead of implying calibration is underway.
    ///
    /// SEMANTICS CHANGE, deliberate: `hasAnyData` used to be `anchorDay != nil`, i.e. "some day carries a
    /// recovery score". That conflated "the phone has data" with "the phone has a SCORED day", which is
    /// what made one null recovery column blank Charge, Effort AND Rest on the wrist together. It is now
    /// literally "the phone has day rows", which is what the rule always meant to say. Visible effect on a
    /// phone with rows but nothing scored: Charge changes from a bare dash to a dash + cal marker (the
    /// baseline genuinely is not usable yet), while Effort and Rest show their real numbers instead of
    /// dashes.
    static func compose(fields: Repository.GlanceFields,
                        hasAnyData: Bool,
                        anchorDay: DailyMetric?,
                        todayRow: DailyMetric?,
                        hr: Int?,
                        asOf: Date) -> WatchScoreSnapshot {
        // Last night's sleep is keyed by the local WAKE day, so today's own row is the right source once a
        // night is banked. Fall back to the anchor day only when it is not — that keeps the rollover window
        // (today's row exists but holds no night yet) reading as it did rather than going blank.
        let sleepRow = todayRow?.totalSleepMin != nil ? todayRow : anchorDay
        return WatchScoreSnapshot(
            charge: fields.charge,
            chargeCalibrating: hasAnyData && fields.charge == nil,
            effort: fields.effort,
            effortCalibrating: hasAnyData && fields.effort == nil,
            rest: fields.rest,
            restCalibrating: hasAnyData && fields.rest == nil,
            hr: hr,
            sleepSummary: sleepSummary(for: sleepRow),
            asOf: asOf,
            // The day the scores are ABOUT (not when we built this), so the watch can label recency
            // honestly ("Yesterday") even when the build is fresh. The anchor day when there is one — it is
            // the field most likely to be describing an EARLIER day, so it is the one the recency label
            // needs to cover. With no anchor at all the remaining numbers are today's, so today's key is
            // the honest label; nil only when there is no row to name.
            scoreDay: anchorDay?.day ?? todayRow?.day)
    }

    /// A one line sleep summary for the glance, formatted on the phone (the watch never recomputes it).
    /// "7h 12m · 81%" when both are present; just the duration or just the efficiency when only one is;
    /// empty when neither is known (the watch then hides the line). Formatted through the app's string
    /// catalog ("%lldh %lldm" / "%lld%%", the same keys the Sleep screens use) so the wrist shows the
    /// phone's language, not hardcoded English.
    static func sleepSummary(for day: DailyMetric?) -> String {
        guard let day else { return "" }
        var parts: [String] = []
        if let mins = day.totalSleepMin, mins > 0 {
            let h = Int(mins) / 60
            let m = Int(mins) % 60
            parts.append(String(localized: "\(h)h \(m)m"))
        }
        if let eff = day.efficiency, eff > 0 {
            // efficiency is stored as a fraction in [0,1] in some paths and as a percent in others; the
            // cached DailyMetric carries the percent-style value the Today tile reads, so render it as a
            // whole percent and clamp defensively.
            let pct = eff <= 1.0 ? eff * 100 : eff
            parts.append(String(localized: "\(Int(pct.rounded()))%"))
        }
        return parts.joined(separator: " · ")
    }
}

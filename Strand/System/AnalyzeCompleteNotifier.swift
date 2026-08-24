import Foundation
import UserNotifications

/// Notifies once a background sync/analyze pass finishes while the app was closed. Mirrors
/// `BatteryNotifier`/`IllnessNotifier`: `requestAuthorization()` up front when the toggle is enabled, a
/// status-only check at fire time (no second system prompt). On-device only; gated behind the user's
/// "Notify when sync finishes" setting (default OFF, #1005-STORM).
///
/// Deliberately narrower than those two: there is no crossing/hysteresis policy here — the caller decides
/// WHETHER to fire (`AppModel.runBackgroundAnalyze`, called only from `SyncAnalyzeBackgroundScheduler`'s
/// registered `BGProcessingTask` handler — see `StrandiOS/System/SyncAnalyzeBackgroundScheduler.swift` —
/// so every call site is already known to be backgrounded), this type only posts.
enum AnalyzeCompleteNotifier {
    /// Ask up front (called when the user enables the toggle) so the system dialog appears at a
    /// predictable moment, not on the first background completion.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post the completion notice. No-op when the setting is off (checked by the caller — see the call
    /// site's comment) or when authorization was never granted.
    static func post() {
        let center = UNUserNotificationCenter.current()
        // Authorization is requested once via requestAuthorization() when the toggle is enabled; here we
        // only check status (no second system prompt).
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Sync complete")
            content.body = String(localized: "Last night's data is scored and ready.")
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "analyze-complete", content: content, trigger: nil))
        }
    }
}

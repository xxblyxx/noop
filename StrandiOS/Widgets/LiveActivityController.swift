#if os(iOS)
import Foundation
import ActivityKit

/// Starts, updates, and ends the live-HR Live Activity. The activity appears on the Lock Screen and
/// in the Dynamic Island while the strap is bonded and streaming heart rate.
@MainActor
final class LiveActivityController {
    /// The workout half of an `update()` call — nil renders today's ambient Live-HR layout, non-nil
    /// renders the workout layout ("Zone Glass"). Built by `StrandiOSApp.workoutActivityPayload()`,
    /// which pre-formats every unit-dependent field so this controller (and the widget target) never
    /// need `Strand/Data/Units.swift`.
    struct WorkoutActivityPayload {
        let start: Date
        let sport: String
        let zone: Int
        /// nil while `StrainScorer.strain` hasn't scored yet (its own ~10-minute gate) — renders "—".
        let effortText: String?
        let kcal: Int?
        /// Both nil unless GPS is actually live for a distance sport.
        let distanceText: String?
        let paceText: String?
    }

    private var activity: Activity<NOOPActivityAttributes>?
    private var lastPush: Date = .distantPast
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Synchronous gate against concurrent `Activity.request` calls. The `else` branch below is
    /// re-entered while the first request is still in flight (it hasn't assigned `self.activity`
    /// yet), so without this guard two close-together HR samples could both fire `Activity.request`
    /// and create duplicate Live Activities.
    private var isStarting = false
    /// How long after the last push iOS may keep showing the activity as fresh. The activity is
    /// refreshed every ~2 s while streaming, so this never bites a live session; it auto-greys a
    /// frozen activity if the app is suspended/killed without an explicit end (a missed-tick safety net
    /// on top of the connected-driven end below).
    private static let staleAfter: TimeInterval = 120
    /// Same safety net, but wide enough to survive a normal WHOOP 5/MG lull rather than fire during
    /// one. `BLEManager.swift` documents standard-HR (0x2A37) going quiet for over 120 s at rest/off-
    /// wrist as "a FAMILY trait of the 5/MG HR profile" — its own `bounceFuse` gives that link 600 s
    /// before treating it as genuinely gone. 120 s would greatly outpace a healthy workout activity
    /// during an ordinary lull; match the strap's own tolerance instead.
    private static let workoutStaleAfter: TimeInterval = 600

    /// Drive the activity from the latest live values. Lazily starts when the strap is CONNECTED (the
    /// live link, not the sticky "paired" flag) and a heart rate is present — OR a workout is
    /// recording, in which case the ticking elapsed clock alone justifies the surface even through an
    /// HR lull. Ends the moment the live link drops, UNLESS a workout is active: that case keeps the
    /// activity up with HR rendering "—" rather than vanishing mid-session over a transient dropout.
    /// Throttled to ~once every 2 s so we stay well under the Live Activity update budget.
    func update(bpm: Int?, recovery: Int?, connected: Bool, effort: Int? = nil,
               workout: WorkoutActivityPayload? = nil) {
        guard authInfo.areActivitiesEnabled else { return }

        // Re-adopt an activity that outlived a previous app session. ActivityKit keeps Live Activities
        // alive across launches/relaunches, but a fresh controller starts with `activity == nil`, so
        // without recovering the handle here we can neither update nor END an already-showing activity
        // — which made the #336 opt-out a no-op (#341: toggle off, heart stays) and risked spawning a
        // duplicate on the start path below. Done on the HR tick rather than in `init` because
        // `Activity.activities` isn't reliably hydrated at the instant of process launch.
        if activity == nil { activity = Activity<NOOPActivityAttributes>.activities.first }

        // User opt-out (#336): if the in-app toggle is off, never start — and end any activity that's
        // already showing (the user just turned it off; this fires on the next ~1 Hz HR tick).
        guard UnitPrefs.liveActivityEnabled() else {
            if activity != nil { Task { await end() } }
            return
        }

        // End the moment the live link drops — UNLESS a workout is recording. `bonded` stays true
        // across every disconnect (it means "this strap is paired"), so keying off IT left a frozen,
        // fabricated "live" HR indefinitely after the strap went out of range; `connected` fixed that
        // for the ambient case, but during a workout a transient dropout must not take the whole Lock
        // Screen down with it — `bpm` renders "—" instead (it's already nil from the call site whenever
        // `connected` is false), while TIME and Effort carry on.
        if !connected && workout == nil {
            Task { await end() }
            return
        }
        // A workout's ticking clock justifies the activity even with no HR yet (starting during a
        // strap lull previously produced no activity at all).
        guard bpm != nil || workout != nil else { return }

        let state = NOOPActivityAttributes.ContentState(
            bpm: bpm, recovery: recovery, bonded: connected, effort: effort,
            workoutStart: workout?.start, sport: workout?.sport, zone: workout?.zone,
            workoutEffortText: workout?.effortText, workoutKcal: workout?.kcal,
            distanceText: workout?.distanceText, paceText: workout?.paceText)
        let staleDate = Date().addingTimeInterval(workout != nil ? Self.workoutStaleAfter : Self.staleAfter)

        if let activity {
            guard Date().timeIntervalSince(lastPush) > 2 else { return }
            lastPush = Date()
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
            // Set the start gate SYNCHRONOUSLY before any await so a second `update` arriving on the
            // main actor while `Activity.request` is still in flight bails here instead of issuing a
            // second request. The 2-second throttle above only guards the update path.
            guard !isStarting else { return }
            isStarting = true
            do {
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(title: String(localized: "Live HR")),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                lastPush = Date()
            } catch {
                activity = nil
            }
            isStarting = false
        }
    }

    func end() async {
        // End every NOOP Live Activity, not just our cached handle — covers a straggler from a prior
        // session we never re-adopted (#341) and any rare duplicate. Iterating the live list is the
        // only way to reach activities this controller instance never started.
        for act in Activity<NOOPActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }
}
#endif

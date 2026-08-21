#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for an active live-HR / workout session. Shared between the app (which
/// starts/updates the activity) and the widget extension (which renders it on the Lock Screen and in
/// the Dynamic Island).
public struct NOOPActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var bpm: Int?
        public var recovery: Int?
        public var bonded: Bool
        // Effort / strain on NOOP's 0–100 axis (#446) — one more stat in the Dynamic Island expanded
        // region. OPTIONAL with a nil default so an activity started by an older build still decodes.
        public var effort: Int?

        // Workout mode ("Zone Glass") — all OPTIONAL with nil defaults, same back-compat contract as
        // `effort` above, so an activity started by an older build keeps decoding. `workoutStart` is
        // the single switch the widget renders on: nil means "no workout, show the ambient Live-HR
        // layout"; non-nil means "render the workout layout". It lives here in ContentState rather than
        // on `attributes` because the activity is often ALREADY running (started by strap connection)
        // when a workout begins, and `attributes` is immutable after `Activity.request` — an immutable
        // start date would force an end/start swap, which the design deliberately avoids. Fed straight
        // into `Text(timerInterval:)`, so the elapsed clock still self-ticks with zero pushes.
        public var workoutStart: Date?
        /// `ActiveWorkout.sport` verbatim — the widget derives its icon via
        /// `WorkoutTypeIconography.systemSymbolName(for:)`, so no separate symbol-name field is needed.
        public var sport: String?
        /// `HRZoneSet.zoneNumber(forBPM:)`. 0 means below Zone 1 (no zone tint yet).
        public var zone: Int?
        /// Pre-formatted via `UnitFormatter.effortDisplay(_:scale:)` on the app side — the widget target
        /// doesn't link `Strand/Data/Units.swift`, so unit-dependent values cross as display strings, not
        /// raw doubles. nil while `StrainScorer.strain` hasn't scored yet (its own ~10-minute gate) —
        /// the widget must render "—", never "0", for that window.
        public var workoutEffortText: String?
        /// Live estimate from `Calories.estimateBoutCalories`, whole kcal. nil under the same gate as
        /// effort (both derive from the same `samples` window).
        public var workoutKcal: Int?
        /// Pre-formatted via `UnitFormatter.distanceFromMeters(_:system:)` / `.paceFromSecPerKm(_:system:)`.
        /// Both nil unless GPS is actually live for a distance sport — the widget's distance/pace row
        /// must collapse to nothing, not a reserved empty slot, when they're absent.
        public var distanceText: String?
        public var paceText: String?

        public init(bpm: Int?, recovery: Int?, bonded: Bool, effort: Int? = nil,
                    workoutStart: Date? = nil, sport: String? = nil, zone: Int? = nil,
                    workoutEffortText: String? = nil, workoutKcal: Int? = nil,
                    distanceText: String? = nil, paceText: String? = nil) {
            self.bpm = bpm
            self.recovery = recovery
            self.bonded = bonded
            self.effort = effort
            self.workoutStart = workoutStart
            self.sport = sport
            self.zone = zone
            self.workoutEffortText = workoutEffortText
            self.workoutKcal = workoutKcal
            self.distanceText = distanceText
            self.paceText = paceText
        }
    }

    /// Static title shown for the session.
    public var title: String

    public init(title: String = "Live HR") {
        self.title = title
    }
}
#endif

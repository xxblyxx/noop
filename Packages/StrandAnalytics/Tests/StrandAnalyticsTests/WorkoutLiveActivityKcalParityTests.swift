import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Pins the parity the workout Live Activity's `AppModel.liveKcal` depends on: a partial sample
/// window scored mid-workout must produce the EXACT SAME kcal `endWorkout()` would produce scoring
/// that same window at save time — there is no separate "live" formula, only
/// `Calories.estimateBoutCalories` called earlier, with the same measured resting HR both times.
/// (`NOOPActivityAttributes`/`AppModel.liveKcal` themselves aren't testable here — `StrandTests` is
/// macOS-only and `ActivityKit` has no macOS availability; see the plan's Verification section.)
final class WorkoutLiveActivityKcalParityTests: XCTestCase {

    private func hr(_ pairs: [(ts: Int, bpm: Int)]) -> [HRSample] {
        pairs.map { HRSample(ts: $0.ts, bpm: $0.bpm) }
    }

    /// `AppModel.liveKcal` and `endWorkout()` both gate on `samples.count >= 2` before calling
    /// `estimateBoutCalories` — pins that the function itself produces a real, finite, positive value
    /// right at that boundary, so the gate is meaningful rather than guarding a degenerate result.
    func testTwoSampleWindowProducesARealValue() {
        let profile = UserProfile(weightKg: 75, heightCm: 178, age: 32, sex: "male")
        let samples = hr([(ts: 0, bpm: 140), (ts: 60, bpm: 145)])
        let (kcal, kj) = Calories.estimateBoutCalories(samples, profile: profile, hrmax: 190.0, restingHR: 55.0)
        XCTAssertGreaterThan(kcal, 0)
        XCTAssertTrue(kcal.isFinite)
        XCTAssertGreaterThan(kj, 0)
    }

    /// The actual live-vs-saved parity claim: scoring the SAME partial window with the SAME resting
    /// HR twice — once as a "mid-workout" live tick, once as the "save time" call — must agree
    /// exactly. A growing live window re-scored from scratch each tick and the final save are the
    /// same pure function on the same input, not two formulas that happen to usually agree.
    func testRepeatedScoringOfTheSameWindowAgreesExactly() {
        let profile = UserProfile(weightKg: 68, heightCm: 165, age: 41, sex: "female")
        let samples = hr([(ts: 0, bpm: 128), (ts: 30, bpm: 132), (ts: 60, bpm: 138),
                          (ts: 90, bpm: 141), (ts: 120, bpm: 136)])
        let live = Calories.estimateBoutCalories(samples, profile: profile, hrmax: 182.0, restingHR: 58.0)
        let saved = Calories.estimateBoutCalories(samples, profile: profile, hrmax: 182.0, restingHR: 58.0)
        XCTAssertEqual(live.0, saved.0, accuracy: 1e-12)
        XCTAssertEqual(live.1, saved.1, accuracy: 1e-12)
    }

    /// The live path deliberately uses the wearer's MEASURED resting HR (matching `endWorkout()`'s
    /// #983 fix), not the analytics package's flat default — a different resting HR shifts the
    /// active-vs-resting threshold, so the two are not interchangeable. Pins that swapping one for the
    /// other changes the result, so a future edit can't quietly collapse them back together.
    func testMeasuredRestingHRIsNotInterchangeableWithTheDefault() {
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        // Hovers near a typical measured resting HR but well below the analytics package's flat 60
        // default, so the active-vs-resting threshold genuinely moves between the two calls.
        let samples = hr((0..<20).map { (ts: $0 * 30, bpm: 118) })
        let withMeasuredResting = Calories.estimateBoutCalories(
            samples, profile: profile, hrmax: 190.0, restingHR: 52.0).0
        let withDefaultResting = Calories.estimateBoutCalories(
            samples, profile: profile, hrmax: 190.0, restingHR: StrainScorer.defaultRestingHR).0
        XCTAssertGreaterThan(abs(withMeasuredResting - withDefaultResting), 0.01,
                             "resting HR must materially change the estimate, or liveKcal's #983 fix is inert")
    }
}

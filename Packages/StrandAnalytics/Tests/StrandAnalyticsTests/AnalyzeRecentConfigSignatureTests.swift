import XCTest
@testable import StrandAnalytics

/// `AnalyzeRecentConfigSignature` — the pass-global half of `analyzeRecent`'s cache identity.
///
/// The contract has two halves and BOTH are load-bearing: re-banking noise must NOT invalidate (that is the
/// churn this closes), and a real change MUST still invalidate (dropping the fields outright would have
/// staled every cached night against a genuine profile change). Oracle for the Android twin — the exact
/// strings may differ across platforms, the invalidation rules may not.
final class AnalyzeRecentConfigSignatureTests: XCTestCase {
    private typealias Sig = AnalyzeRecentConfigSignature

    // ── sleepNeedHours: 0.25 h quantum ────────────────────────────────────────────────────────────────
    // Sub-quantum drift is what a re-banked session produces: pass 1 banks the night, pass 2 recomputes the
    // need from a fractionally different nightlyHours. It must not move the signature.
    func testSleepNeedIgnoresSubQuantumDrift() {
        XCTAssertEqual(Sig.sleepNeedHours(7.9), Sig.sleepNeedHours(7.93))
        XCTAssertEqual(Sig.sleepNeedHours(8.0), Sig.sleepNeedHours(8.0 + 1.0 / 3600))  // one second
    }

    // A real change in need — half an hour, two whole quanta — must still drop the cache.
    func testSleepNeedInvalidatesOnRealChange() {
        XCTAssertNotEqual(Sig.sleepNeedHours(8.0), Sig.sleepNeedHours(8.5))
        XCTAssertNotEqual(Sig.sleepNeedHours(8.0), Sig.sleepNeedHours(7.75))   // exactly one quantum
    }

    // ── sleepConsistency: 0.01 quantum, and nil is a distinct, stable state ───────────────────────────
    func testSleepConsistencyQuantumAndNil() {
        XCTAssertEqual(Sig.sleepConsistency(0.732), Sig.sleepConsistency(0.7315))
        XCTAssertNotEqual(Sig.sleepConsistency(0.73), Sig.sleepConsistency(0.75))
        XCTAssertEqual(Sig.sleepConsistency(nil), Sig.sleepConsistency(nil))
        XCTAssertNotEqual(Sig.sleepConsistency(nil), Sig.sleepConsistency(0))
    }

    // ── habitualMidsleepSec: 300 s quantum ────────────────────────────────────────────────────────────
    // A couple of minutes' drift within a step is absorbed; a 20-minute shift is a genuinely different
    // overnight band and must invalidate. 12_600 is the CENTRE of step 42, so ±2 min stays inside it.
    func testMidsleepAbsorbsMinutesButNotABandShift() {
        XCTAssertEqual(Sig.habitualMidsleepSec(12_600), Sig.habitualMidsleepSec(12_600 + 120))
        XCTAssertEqual(Sig.habitualMidsleepSec(12_600), Sig.habitualMidsleepSec(12_600 - 120))
        XCTAssertNotEqual(Sig.habitualMidsleepSec(12_600), Sig.habitualMidsleepSec(12_600 + 1_200))
        XCTAssertEqual(Sig.habitualMidsleepSec(nil), Sig.habitualMidsleepSec(nil))
        XCTAssertNotEqual(Sig.habitualMidsleepSec(nil), Sig.habitualMidsleepSec(0))
    }

    // The LIMIT of the whole approach, pinned rather than left implicit: a drift that crosses a step
    // boundary still invalidates, however small it is. 12_750 is the boundary between steps 42 and 43, so
    // one second either side lands in different steps. Quantizing is a noise FILTER, not a guarantee — and
    // this case degrades to exactly the pre-change behaviour (one extra cold pass), never to a wrong score.
    // If a future session sees churn survive this fix, this is the reason, and the answer is a coarser
    // quantum or a hysteresis band, not a claim that the fix regressed.
    func testMidsleepStillInvalidatesAcrossAStepBoundary() {
        XCTAssertNotEqual(Sig.habitualMidsleepSec(12_749), Sig.habitualMidsleepSec(12_750))
    }

    // A midsleep can sit BEFORE local midnight and be negative; rounding must stay symmetric rather than
    // biasing one direction across zero (which would make a band straddling midnight invalidate on noise).
    func testMidsleepRoundingIsSymmetricAboutZero() {
        XCTAssertEqual(Sig.habitualMidsleepSec(-1_800), Sig.habitualMidsleepSec(-1_800 - 60))
        XCTAssertEqual(Sig.habitualMidsleepSec(-149), Sig.habitualMidsleepSec(149))   // both → step 0
        XCTAssertNotEqual(Sig.habitualMidsleepSec(-1_800), Sig.habitualMidsleepSec(1_800))
    }

    // ── baselineState: baseline/spread quantum 0.5, status kept, nValid/nightsSinceUpdate dropped ─────
    private func base(_ baseline: Double, spread: Double = 8.0, nValid: Int = 40,
                      nightsSinceUpdate: Int = 0, status: BaselineStatus = .trusted) -> BaselineState {
        BaselineState(baseline: baseline, spread: spread, nValid: nValid,
                      nightsSinceUpdate: nightsSinceUpdate, status: status)
    }

    // The churn this closes: a banked night increments `nValid` and nudges `nightsSinceUpdate`, and the
    // old `String(describing:)` encoding moved on both — a full cache drop every pass with new sleep data.
    func testBaselineIgnoresNValidAndStalenessCounters() {
        XCTAssertEqual(Sig.baselineState(base(52.0, nValid: 40, nightsSinceUpdate: 0)),
                       Sig.baselineState(base(52.0, nValid: 41, nightsSinceUpdate: 3)))
    }

    // Sub-quantum drift in the robust EWMA centre/spread (one new night into a long window) is absorbed.
    // 52.1 and 52.4 both round to step 52; 8.1 and 8.3 both to step 8.
    func testBaselineAbsorbsSubQuantumDrift() {
        XCTAssertEqual(Sig.baselineState(base(52.1, spread: 8.1)),
                       Sig.baselineState(base(52.4, spread: 8.3)))
    }

    // A genuine multi-night baseline shift — more than a whole quantum — must still invalidate.
    func testBaselineInvalidatesOnRealDrift() {
        XCTAssertNotEqual(Sig.baselineState(base(52.1)), Sig.baselineState(base(53.4)))
        XCTAssertNotEqual(Sig.baselineState(base(52.0, spread: 8.1)),
                          Sig.baselineState(base(52.0, spread: 9.7)))
    }

    // `status` gates `usable`/`trusted` — which recovery scoring and ScoreConfidence both key on — so a
    // status transition at unchanged baseline/spread MUST invalidate. nil is its own stable state.
    func testBaselineStatusAndNil() {
        XCTAssertNotEqual(Sig.baselineState(base(52.0, status: .provisional)),
                          Sig.baselineState(base(52.0, status: .trusted)))
        XCTAssertNotEqual(Sig.baselineState(base(52.0, status: .trusted)),
                          Sig.baselineState(base(52.0, status: .stale)))
        XCTAssertEqual(Sig.baselineState(nil), Sig.baselineState(nil))
        XCTAssertNotEqual(Sig.baselineState(nil), Sig.baselineState(base(0.0, spread: 0.0,
                                                                        status: .calibrating)))
    }

    // ── Degenerate Doubles must not trap ──────────────────────────────────────────────────────────────
    // `Int64(_:)` traps on NaN/infinity/out-of-range, and this runs on every analyze pass, so a degenerate
    // upstream value would CRASH rather than mis-cache. The fallback is the exact bit pattern — i.e. the
    // pre-quantization behaviour — which must still be self-consistent.
    func testNonFiniteFallsBackWithoutTrapping() {
        XCTAssertEqual(Sig.sleepNeedHours(.nan), Sig.sleepNeedHours(.nan))
        XCTAssertEqual(Sig.sleepNeedHours(.infinity), Sig.sleepNeedHours(.infinity))
        XCTAssertNotEqual(Sig.sleepNeedHours(.infinity), Sig.sleepNeedHours(-.infinity))
        XCTAssertEqual(Sig.sleepConsistency(.nan), Sig.sleepConsistency(.nan))
        XCTAssertEqual(Sig.sleepNeedHours(1e300), Sig.sleepNeedHours(1e300))
    }

    // ── The churn case, end to end ────────────────────────────────────────────────────────────────────
    // The measured 2026-08-27 failure: pass 2 recomputes all three from re-banked sessions, each drifts by
    // well under its quantum, and the OLD encoding dropped all 9 cached nights. The joined component slice
    // must now be identical across that pass boundary.
    func testRebankingDriftProducesAnIdenticalSignatureSlice() {
        func slice(need: Double, consistency: Double?, midsleep: Int?) -> String {
            [Sig.sleepNeedHours(need),
             Sig.sleepConsistency(consistency),
             Sig.habitualMidsleepSec(midsleep)].joined(separator: "|")
        }
        XCTAssertEqual(slice(need: 8.02, consistency: 0.681, midsleep: 12_540),
                       slice(need: 8.04, consistency: 0.683, midsleep: 12_600))
        // …and a genuine shift in any ONE of the three still drops the cache.
        XCTAssertNotEqual(slice(need: 8.02, consistency: 0.681, midsleep: 12_540),
                          slice(need: 8.02, consistency: 0.681, midsleep: 14_400))
    }
}

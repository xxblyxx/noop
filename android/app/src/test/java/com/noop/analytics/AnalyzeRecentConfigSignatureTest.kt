package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * [AnalyzeRecentConfigSignature] — the pass-global half of `analyzeRecent`'s cache identity. Twin of the
 * Swift `AnalyzeRecentConfigSignatureTests`.
 *
 * The contract has two halves and BOTH are load-bearing: re-banking noise must NOT invalidate (that is the
 * churn this closes), and a real change MUST still invalidate (dropping the fields outright would have
 * staled every cached night against a genuine profile change). The exact strings may differ from Swift's;
 * the invalidation rules may not.
 */
class AnalyzeRecentConfigSignatureTest {
    private val sig = AnalyzeRecentConfigSignature

    // ── sleepNeedHours: 0.25 h quantum ───────────────────────────────────────────────────────────────
    // Sub-quantum drift is what a re-banked session produces: pass 1 banks the night, pass 2 recomputes the
    // need from a fractionally different nightlyHours. It must not move the signature.
    @Test fun sleepNeedIgnoresSubQuantumDrift() {
        assertEquals(sig.sleepNeedHours(7.9), sig.sleepNeedHours(7.93))
        assertEquals(sig.sleepNeedHours(8.0), sig.sleepNeedHours(8.0 + 1.0 / 3600))   // one second
    }

    // A real change in need — half an hour, and exactly one quantum — must still drop the cache.
    @Test fun sleepNeedInvalidatesOnRealChange() {
        assertNotEquals(sig.sleepNeedHours(8.0), sig.sleepNeedHours(8.5))
        assertNotEquals(sig.sleepNeedHours(8.0), sig.sleepNeedHours(7.75))
    }

    // ── sleepConsistency: 0.01 quantum, and null is a distinct, stable state ─────────────────────────
    @Test fun sleepConsistencyQuantumAndNull() {
        assertEquals(sig.sleepConsistency(0.732), sig.sleepConsistency(0.7315))
        assertNotEquals(sig.sleepConsistency(0.73), sig.sleepConsistency(0.75))
        assertEquals(sig.sleepConsistency(null), sig.sleepConsistency(null))
        assertNotEquals(sig.sleepConsistency(null), sig.sleepConsistency(0.0))
    }

    // ── habitualMidsleepSec: 300 s quantum ──────────────────────────────────────────────────────────
    // A couple of minutes' drift within a step is absorbed; a 20-minute shift is a genuinely different
    // overnight band and must invalidate. 12_600 is the CENTRE of step 42, so +/-2 min stays inside it.
    @Test fun midsleepAbsorbsMinutesButNotABandShift() {
        assertEquals(sig.habitualMidsleepSec(12_600L), sig.habitualMidsleepSec(12_720L))
        assertEquals(sig.habitualMidsleepSec(12_600L), sig.habitualMidsleepSec(12_480L))
        assertNotEquals(sig.habitualMidsleepSec(12_600L), sig.habitualMidsleepSec(13_800L))
        assertEquals(sig.habitualMidsleepSec(null), sig.habitualMidsleepSec(null))
        assertNotEquals(sig.habitualMidsleepSec(null), sig.habitualMidsleepSec(0L))
    }

    // The LIMIT of the whole approach, pinned rather than left implicit: a drift that crosses a step
    // boundary still invalidates, however small it is. Quantizing is a noise FILTER, not a guarantee - and
    // this case degrades to exactly the pre-change behaviour (one extra cold pass), never to a wrong score.
    @Test fun midsleepStillInvalidatesAcrossAStepBoundary() {
        assertNotEquals(sig.habitualMidsleepSec(12_749L), sig.habitualMidsleepSec(12_750L))
    }

    // A midsleep can sit BEFORE local midnight and be negative; rounding must stay symmetric rather than
    // biasing one direction across zero (which would make a band straddling midnight invalidate on noise).
    @Test fun midsleepRoundingIsSymmetricAboutZero() {
        assertEquals(sig.habitualMidsleepSec(-1_800L), sig.habitualMidsleepSec(-1_860L))
        assertEquals(sig.habitualMidsleepSec(-149L), sig.habitualMidsleepSec(149L))   // both -> step 0
        assertNotEquals(sig.habitualMidsleepSec(-1_800L), sig.habitualMidsleepSec(1_800L))
    }

    // ── baselineState: baseline/spread quantum 0.5, status kept, nValid/nightsSinceUpdate dropped ────
    private fun base(
        baseline: Double, spread: Double = 8.0, nValid: Int = 40,
        nightsSinceUpdate: Int = 0, status: BaselineStatus = BaselineStatus.TRUSTED,
    ) = BaselineState(baseline, spread, nValid, nightsSinceUpdate, status)

    // The churn this closes: a banked night increments nValid and nudges nightsSinceUpdate, and the old
    // toString() encoding moved on both — a full cache drop every pass with new sleep data.
    @Test fun baselineIgnoresNValidAndStalenessCounters() {
        assertEquals(
            sig.baselineState(base(52.0, nValid = 40, nightsSinceUpdate = 0)),
            sig.baselineState(base(52.0, nValid = 41, nightsSinceUpdate = 3)),
        )
    }

    // 52.1 and 52.4 both round to step 52; 8.1 and 8.3 both to step 8.
    @Test fun baselineAbsorbsSubQuantumDrift() {
        assertEquals(sig.baselineState(base(52.1, spread = 8.1)), sig.baselineState(base(52.4, spread = 8.3)))
    }

    @Test fun baselineInvalidatesOnRealDrift() {
        assertNotEquals(sig.baselineState(base(52.1)), sig.baselineState(base(53.4)))
        assertNotEquals(sig.baselineState(base(52.0, spread = 8.1)), sig.baselineState(base(52.0, spread = 9.7)))
    }

    @Test fun baselineStatusAndNull() {
        assertNotEquals(
            sig.baselineState(base(52.0, status = BaselineStatus.PROVISIONAL)),
            sig.baselineState(base(52.0, status = BaselineStatus.TRUSTED)),
        )
        assertNotEquals(
            sig.baselineState(base(52.0, status = BaselineStatus.TRUSTED)),
            sig.baselineState(base(52.0, status = BaselineStatus.STALE)),
        )
        assertEquals(sig.baselineState(null), sig.baselineState(null))
        assertNotEquals(
            sig.baselineState(null),
            sig.baselineState(base(0.0, spread = 0.0, status = BaselineStatus.CALIBRATING)),
        )
    }

    // ── Degenerate Doubles must not alias ───────────────────────────────────────────────────────────
    // Kotlin's roundToLong() SATURATES on NaN/infinity rather than throwing, which would collapse every
    // non-finite value onto the same step and alias distinct states. The guard falls back to raw bits.
    @Test fun nonFiniteFallsBackWithoutAliasing() {
        assertEquals(sig.sleepNeedHours(Double.NaN), sig.sleepNeedHours(Double.NaN))
        assertNotEquals(sig.sleepNeedHours(Double.POSITIVE_INFINITY),
                        sig.sleepNeedHours(Double.NEGATIVE_INFINITY))
        assertNotEquals(sig.sleepNeedHours(Double.NaN), sig.sleepNeedHours(Double.POSITIVE_INFINITY))
        assertEquals(sig.sleepConsistency(Double.NaN), sig.sleepConsistency(Double.NaN))
        assertEquals(sig.sleepNeedHours(1e300), sig.sleepNeedHours(1e300))
    }

    // ── The churn case, end to end ──────────────────────────────────────────────────────────────────
    // The measured 2026-08-27 failure: pass 2 recomputes all three from re-banked sessions, each drifts by
    // well under its quantum, and the OLD encoding dropped all 9 cached nights.
    @Test fun rebankingDriftProducesAnIdenticalSignatureSlice() {
        fun slice(need: Double, consistency: Double?, midsleep: Long?) = listOf(
            sig.sleepNeedHours(need), sig.sleepConsistency(consistency),
            sig.habitualMidsleepSec(midsleep),
        ).joinToString("|")
        assertEquals(slice(8.02, 0.681, 12_540L), slice(8.04, 0.683, 12_600L))
        assertNotEquals(slice(8.02, 0.681, 12_540L), slice(8.02, 0.681, 14_400L))
    }
}

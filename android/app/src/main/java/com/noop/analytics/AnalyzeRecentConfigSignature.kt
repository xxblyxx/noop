package com.noop.analytics

import kotlin.math.absoluteValue
import kotlin.math.roundToLong

/**
 * The PASS-GLOBAL half of `analyzeRecent`'s cache identity: how the three `computeHabitualSleep`-derived
 * inputs are encoded into the pass config signature. Twin of the Swift `AnalyzeRecentConfigSignature`.
 *
 * The defect this closes (measured on iOS, 2026-08-27; the Kotlin path had the identical shape). The
 * signature folded these three by raw value, and all three are derived from the computed `-noop` sleep
 * sessions **a previous pass banked**. So the pass fed its own output back into its own cache identity: pass
 * 1 banks the night, pass 2's `computeHabitualSleep` reads a fractionally different `nightlyHours`, the
 * signature moves, and the whole cache is dropped — every night re-read and re-scored. The iOS device log
 * named it outright: `analyzeRecent dayCache DROPPED — sig changed: sleepNeedHours,sleepConsistency`, on a
 * pass whose 9 nights were all in the cache the previous pass had just filled, and which then produced
 * byte-identical output for every one of them.
 *
 * **Quantize rather than drop.** These are genuine scoring inputs: a real change (a habitual bedtime
 * actually shifting, a new night extending the window) MUST still invalidate, or every cached night goes
 * stale against a real profile change — a correctness regression traded for speed. Rounding to a quantum far
 * below display resolution keeps that invalidation and removes only the re-banking noise.
 *
 * **Signature only.** Nothing here touches what reaches `analyzeDay` — the full-precision values still
 * thread through to scoring unchanged, so no score, tier or displayed number moves.
 *
 * Quantizing is a noise filter, not a guarantee: a value drifting across a quantum boundary still
 * invalidates. That degrades to the previous behaviour (one extra cold pass), never to a wrong score.
 *
 * Like [AnalyzeRecentDayCache.cacheKey], this is compared only against itself, in memory, on one platform —
 * so the twin must match the invalidation RULES, not produce byte-identical strings. (Kotlin's `toString()`
 * for a Double already differs from Swift's `bitPattern` encoding in the pre-existing code.)
 */
object AnalyzeRecentConfigSignature {
    /** Personalised sleep need, to the nearest **0.25 h** — far below what moves a displayed score. */
    const val SLEEP_NEED_QUANTUM_HOURS = 0.25
    /** Sleep regularity (a 0…1 index), to **2 decimal places**. */
    const val SLEEP_CONSISTENCY_QUANTUM = 0.01
    /** Habitual midsleep, to the nearest **5 minutes** — well inside the overnight band's own width. */
    const val HABITUAL_MIDSLEEP_QUANTUM_SEC = 300L

    fun sleepNeedHours(hours: Double): String =
        quantized(hours, SLEEP_NEED_QUANTUM_HOURS) ?: hours.toRawBits().toString()

    fun sleepConsistency(index: Double?): String {
        if (index == null) return "nil"
        return quantized(index, SLEEP_CONSISTENCY_QUANTUM) ?: index.toRawBits().toString()
    }

    fun habitualMidsleepSec(seconds: Long?): String {
        if (seconds == null) return "nil"
        // Integer arithmetic, so there is no float rounding to reason about. Symmetric about zero: a midsleep
        // can sit BEFORE local midnight and be negative, and a biased rounding there would make a band
        // straddling midnight invalidate on noise.
        val q = HABITUAL_MIDSLEEP_QUANTUM_SEC
        val steps = if (seconds >= 0) (seconds + q / 2) / q else -((-seconds + q / 2) / q)
        return steps.toString()
    }

    /**
     * The quantum STEP INDEX as a string — never the re-multiplied Double, so there is no float formatting or
     * `-0.0`/`0.0` ambiguity in the signature.
     *
     * Returns null, and the callers above fall back to the exact raw bits, when the value cannot be stepped
     * safely. `roundToLong()` saturates rather than throwing on NaN/infinity (unlike Swift's trapping
     * `Int64(_:)`), which would silently collapse every non-finite value onto the same step and alias
     * distinct states — so the guard is required for CORRECTNESS here, not only for safety as it is on Swift.
     */
    private fun quantized(value: Double, quantum: Double): String? {
        if (!value.isFinite() || quantum <= 0) return null
        val steps = value / quantum
        if (!steps.isFinite() || steps.absoluteValue >= 9.0e15) return null
        return steps.roundToLong().toString()
    }
}

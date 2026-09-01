package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [ComputedScoreReconcilePolicy] — how far a pass may reach when it reconciles the persisted
 * computed-score window against what it just scored. Twin of the Swift
 * `ComputedScoreReconcilePolicyTests`; the rules match value-for-value.
 */
class ComputedScoreReconcilePolicyTest {
    private val p = ComputedScoreReconcilePolicy

    @Test
    fun completePassWithScoresMayEvict() {
        assertTrue(p.mayEvictStaleDays(scoredDayCount = 21, cancelled = false))
        assertTrue(p.mayEvictStaleDays(scoredDayCount = 1, cancelled = false))
    }

    @Test
    fun emptyPassMayNotEvict() {
        assertFalse(p.mayEvictStaleDays(scoredDayCount = 0, cancelled = false))
    }

    @Test
    fun cancelledPassMayNotEvict() {
        assertFalse(p.mayEvictStaleDays(scoredDayCount = 3, cancelled = true))
        assertFalse(p.mayEvictStaleDays(scoredDayCount = 0, cancelled = true))
    }

    @Test
    fun completePassKeepsFullWindow() {
        assertEquals(
            "2026-08-12",
            p.reconcileFromDay(
                cancelled = false,
                scoredDays = listOf("2026-08-20", "2026-09-01"),
                windowOldestDay = "2026-08-12",
                windowNewestDay = "2026-09-01",
            ),
        )
    }

    @Test
    fun cancelledPassContractsToEarliestScoredDay() {
        assertEquals(
            "2026-08-30",
            p.reconcileFromDay(
                cancelled = true,
                scoredDays = listOf("2026-09-01", "2026-08-31", "2026-08-30"),
                windowOldestDay = "2026-08-12",
                windowNewestDay = "2026-09-01",
            ),
        )
    }

    @Test
    fun cancelledPassWithNoScoredDaysFallsBackToNewest() {
        assertEquals(
            "2026-09-01",
            p.reconcileFromDay(
                cancelled = true,
                scoredDays = emptyList(),
                windowOldestDay = "2026-08-12",
                windowNewestDay = "2026-09-01",
            ),
        )
    }

    @Test
    fun yyyyMmDdStringOrderIsDateOrder() {
        assertEquals(
            "2025-12-30",
            p.reconcileFromDay(
                cancelled = true,
                scoredDays = listOf("2026-01-05", "2025-12-30", "2026-01-02"),
                windowOldestDay = "2025-11-01",
                windowNewestDay = "2026-01-05",
            ),
        )
    }
}

package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The per-field widget resolution both Android producers now use: the recovery anchor gates RECOVERY
 * ONLY, while Rest and Effort read today's own row.
 *
 * Both producers (the in-app republish in [AppViewModel] and the background-service producer in
 * `WhoopConnectionService.NotifyDayStateCache`) used to funnel recovery, Rest AND Effort through
 * [widgetAnchorRow]. A store with no scored recovery row anywhere then blanked every stat block on the
 * home-screen widget at once, while the dashboard — which resolves the same stats per-field — still
 * showed Rest and Effort. Twin of the Swift `WidgetGlanceFieldsTests` (`Repository.glanceFields`).
 *
 * These assert the SELECTORS the producers compose, since the producers themselves need a Context.
 */
class WidgetGlanceFieldsTest {

    private fun day(key: String, recovery: Double?, sleepMin: Double? = null, strain: Double? = null) =
        DailyMetric(
            deviceId = "my-whoop", day = key, recovery = recovery,
            totalSleepMin = sleepMin, strain = strain,
        )

    /** (1) The reported bug: nothing scored anywhere, but today's row carries real strain. */
    @Test
    fun noScoredRecoveryAnywhere_onlyRecoveryBlanks() {
        val days = listOf(
            day("2026-06-18", null),
            day("2026-06-19", null, strain = 11.4),
        )
        val anchor = widgetAnchorRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19")
        val today = resolveTodayRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19")

        assertNull("no scored row anywhere: a blank recovery is the honest answer", anchor)
        assertEquals("Effort must NOT be gated on a recovery score", 11.4, today?.strain)
    }

    /** (2) Effort must never ride along on the carried anchor row. */
    @Test
    fun effortNeverCarriesFromTheAnchorRow() {
        val days = listOf(
            day("2026-06-18", 72.0, strain = 14.0),
            day("2026-06-19", null, strain = null),
        )
        val anchor = widgetAnchorRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19")
        val today = resolveTodayRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19")

        assertEquals("recovery carries the freshest strictly-prior scored day", 72.0, anchor?.recovery)
        assertNull("Effort reads today's own row or nothing — never the carried anchor's", today?.strain)
    }

    /** (2, cont.) today's own strain wins even while recovery is carried from another day. */
    @Test
    fun effortReadsTodaysOwnRowWhileRecoveryIsCarried() {
        val days = listOf(
            day("2026-06-18", 72.0, strain = 14.0),
            day("2026-06-19", null, strain = 6.2),
        )
        val anchor = widgetAnchorRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19")
        val today = resolveTodayRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19")

        assertEquals(72.0, anchor?.recovery)
        assertEquals("today's own accumulation, not the anchor day's", 6.2, today?.strain)
    }

    /** (4) Rest's source row survives a nil anchor — it is banked stage data, not a recovery score. */
    @Test
    fun restSourceRowResolvesWithNoScoredRowAnywhere() {
        val days = listOf(day("2026-06-19", null, sleepMin = 430.0))
        val anchor = widgetAnchorRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19")
        val today = resolveTodayRow(days, logicalKey = "2026-06-19", localKey = "2026-06-19")

        assertNull(anchor)
        assertEquals(
            "Rest must resolve off today's own banked row, not behind the recovery anchor",
            "2026-06-19", today?.day,
        )
    }
}

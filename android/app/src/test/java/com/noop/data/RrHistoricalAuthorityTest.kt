package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1451: the strap's own banked record is authoritative for every second it covers, so a historical
 * batch replaces what the live stream already wrote for those seconds instead of piling on beside it.
 *
 * The defect: two paths write R-R for the same wall-second — the live stream as beats arrive, and the
 * offload when the strap's record of those seconds is downloaded later. They disagree by a few
 * milliseconds, so ON CONFLICT … IGNORE cannot collapse them and both survive. Measured on a real 5.0:
 * 1.65x the strap's own claim stored, ~2.1 s of beat-time per wall second wherever two batches wrote,
 * and zero duplication across a 2 h 18 m BLE disconnect.
 *
 * These are the PURE halves — [rrSecondsCovered] (the delete's entire blast radius) and the chunking
 * that keeps it under SQLite's bound-variable limit. The end-to-end DB behaviour is exercised on the
 * Swift twin (`WhoopStoreTests/RrHistoricalAuthorityTests`, which CI actually runs); there is no SQLite
 * driver on this unit-test classpath, the same split the other rrInterval tests here use.
 */
class RrHistoricalAuthorityTest {

    @Test
    fun coveredSecondsAreTheDistinctTimestampsAscending() {
        val covered = rrSecondsCovered(
            listOf(RrRow(102L, 800), RrRow(100L, 810), RrRow(102L, 795), RrRow(100L, 805)),
        )
        assertEquals(listOf(100L, 102L), covered)
    }

    /** Empty in, empty out — an empty batch must name no seconds, so it deletes nothing. */
    @Test
    fun anEmptyBatchCoversNothing() {
        assertEquals(emptyList<Long>(), rrSecondsCovered(emptyList()))
    }

    /**
     * A second the batch carries no beats for is ABSENT by construction: the list is built from the rows
     * themselves, so there is no path by which an uncovered second reaches the delete. That is the
     * deliberate exception — the strap's detector finding nothing does not license deleting what the live
     * stream saw there.
     */
    @Test
    fun onlySecondsWithBeatsAreNamed() {
        val covered = rrSecondsCovered(listOf(RrRow(100L, 810), RrRow(102L, 795)))
        assertTrue("101 carried no beats and must not be cleared", 101L !in covered)
        assertEquals(listOf(100L, 102L), covered)
    }

    /** SQLite binds each IN-list element as its own variable and caps that at 999 by default. */
    @Test
    fun clearChunkStaysUnderSqlitesBoundVariableLimit() {
        assertTrue(
            "RR_CLEAR_CHUNK=${WhoopRepository.RR_CLEAR_CHUNK} must leave headroom under 999",
            WhoopRepository.RR_CLEAR_CHUNK in 1..900,
        )
    }

    /**
     * A long offload chunk is split, but every covered second must still be named exactly once — a
     * chunking bug here would silently leave duplicates behind in whichever piece got dropped.
     */
    @Test
    fun chunkingCoversEverySecondExactlyOnce() {
        val rows = (0 until 1_300).map { RrRow(1_787_173_050L + it, 800) }
        val covered = rrSecondsCovered(rows)
        val chunks = covered.chunked(WhoopRepository.RR_CLEAR_CHUNK)

        assertTrue("no chunk may exceed the limit", chunks.all { it.size <= WhoopRepository.RR_CLEAR_CHUNK })
        assertEquals("every second named, in order, with none repeated", covered, chunks.flatten())
        assertEquals(1_300, chunks.flatten().distinct().size)
    }
}

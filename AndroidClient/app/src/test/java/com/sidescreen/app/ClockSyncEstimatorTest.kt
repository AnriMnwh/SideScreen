package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClockSyncEstimatorTest {
    /**
     * One exchange starting at client instant [t0] against a host clock [offset] ns ahead of the
     * client, with the given one-way delays and host turnaround.
     */
    private fun ClockSyncEstimator.exchange(
        t0: Long,
        offset: Long,
        up: Long,
        down: Long,
        turnaround: Long = 50,
    ) {
        val t1 = t0 + up + offset
        val t2 = t1 + turnaround
        val t3 = t0 + up + turnaround + down
        addSample(t0, t1, t2, t3)
    }

    @Test
    fun emptyEstimatorKnowsNothing() {
        val sync = ClockSyncEstimator()
        assertNull(sync.offsetNs)
        assertNull(sync.minRttNs)
        assertFalse(sync.isConfident)
        assertNull(sync.hostToClientNs(1_000_000L))
    }

    @Test
    fun symmetricExchangeGivesTheExactOffsetAndRtt() {
        val sync = ClockSyncEstimator()
        // t0 = 10 000, t1 = 1 010 200, t2 = 1 010 250, t3 = 10 450
        sync.addSample(10_000L, 1_010_200L, 1_010_250L, 10_450L)
        assertEquals(1_000_000L, sync.offsetNs)
        assertEquals(400L, sync.minRttNs)
    }

    @Test
    fun asymmetricDelayBiasesTheOffsetByHalfTheDifference() {
        val sync = ClockSyncEstimator()
        sync.exchange(t0 = 10_000L, offset = 1_000_000L, up = 300L, down = 100L)
        assertEquals(400L, sync.minRttNs)
        assertEquals(1_000_100L, sync.offsetNs)
    }

    @Test
    fun hostClockBehindTheClientGivesANegativeOffset() {
        val sync = ClockSyncEstimator()
        sync.exchange(t0 = 5_000_000_000L, offset = -3_000_000_000L, up = 200L, down = 200L)
        assertEquals(-3_000_000_000L, sync.offsetNs)
        assertEquals(5_000_000_000L, sync.hostToClientNs(2_000_000_000L))
    }

    @Test
    fun minimumRttSampleWins() {
        val sync = ClockSyncEstimator()
        sync.exchange(t0 = 0L, offset = 1_000_000L, up = 5_000L, down = 100L) // rtt 5100, offset +2450
        assertEquals(1_002_450L, sync.offsetNs)
        sync.exchange(t0 = 100_000L, offset = 1_000_000L, up = 150L, down = 150L) // rtt 300, exact
        assertEquals(300L, sync.minRttNs)
        assertEquals(1_000_000L, sync.offsetNs)
        sync.exchange(t0 = 200_000L, offset = 1_000_000L, up = 100L, down = 9_000L) // rtt 9100
        assertEquals(300L, sync.minRttNs)
        assertEquals(1_000_000L, sync.offsetNs)
    }

    @Test
    fun bestSampleIsEvictedOnceTheWindowMovesPastIt() {
        val sync = ClockSyncEstimator(window = 4)
        sync.exchange(t0 = 0L, offset = 7_000L, up = 50L, down = 50L) // rtt 100, offset 7000
        sync.exchange(t0 = 10_000L, offset = 7_000L, up = 400L, down = 200L) // rtt 600, offset 7100
        sync.exchange(t0 = 20_000L, offset = 7_000L, up = 300L, down = 100L) // rtt 400, offset 7100
        sync.exchange(t0 = 30_000L, offset = 7_000L, up = 500L, down = 300L) // rtt 800, offset 7100
        assertEquals(100L, sync.minRttNs)
        assertEquals(7_000L, sync.offsetNs)

        sync.exchange(t0 = 40_000L, offset = 7_000L, up = 600L, down = 400L) // rtt 1000; evicts rtt 100
        assertEquals(400L, sync.minRttNs)
        assertEquals(7_100L, sync.offsetNs)

        sync.exchange(t0 = 50_000L, offset = 7_000L, up = 900L, down = 700L) // rtt 1600; evicts rtt 600
        assertEquals(400L, sync.minRttNs)

        sync.exchange(t0 = 60_000L, offset = 7_000L, up = 1_000L, down = 600L) // rtt 1600; evicts rtt 400
        assertEquals(800L, sync.minRttNs)
        assertEquals(7_100L, sync.offsetNs)
    }

    @Test
    fun confidenceNeedsAFewSamples() {
        val sync = ClockSyncEstimator()
        repeat(ClockSyncEstimator.MIN_CONFIDENT_SAMPLES - 1) {
            sync.exchange(t0 = it * 1_000_000L, offset = 0L, up = 100L, down = 100L)
            assertFalse(sync.isConfident)
        }
        sync.exchange(t0 = 99_000_000L, offset = 0L, up = 100L, down = 100L)
        assertTrue(sync.isConfident)
    }

    @Test
    fun smallWindowIsConfidentWhenFull() {
        val sync = ClockSyncEstimator(window = 2)
        sync.exchange(t0 = 0L, offset = 0L, up = 100L, down = 100L)
        assertFalse(sync.isConfident)
        sync.exchange(t0 = 1_000L, offset = 0L, up = 100L, down = 100L)
        assertTrue(sync.isConfident)
    }

    @Test
    fun hostToClientSubtractsTheOffset() {
        val sync = ClockSyncEstimator()
        sync.exchange(t0 = 1_000_000L, offset = 250_000_000L, up = 500L, down = 500L)
        val hostCapture = 900_000_000L
        assertEquals(650_000_000L, sync.hostToClientNs(hostCapture))
    }

    @Test
    fun impossibleSamplesAreDropped() {
        val sync = ClockSyncEstimator()
        // Host turnaround longer than the whole round trip: negative RTT.
        sync.addSample(0L, 1_000L, 2_000L, 500L)
        // Reply before request on the client clock.
        sync.addSample(1_000L, 5_000L, 5_010L, 900L)
        // Host sent before it received.
        sync.addSample(0L, 5_000L, 4_990L, 500L)
        assertNull(sync.offsetNs)
        assertNull(sync.minRttNs)
    }

    @Test
    fun resetForgetsEverySample() {
        val sync = ClockSyncEstimator()
        repeat(5) { sync.exchange(t0 = it * 1_000L, offset = 42L, up = 10L, down = 10L) }
        assertTrue(sync.isConfident)
        sync.reset()
        assertNull(sync.offsetNs)
        assertNull(sync.minRttNs)
        assertFalse(sync.isConfident)
        sync.exchange(t0 = 0L, offset = 7L, up = 20L, down = 20L)
        assertEquals(7L, sync.offsetNs)
        assertEquals(40L, sync.minRttNs)
    }

    @Test(expected = IllegalArgumentException::class)
    fun zeroWindowIsRejected() {
        ClockSyncEstimator(window = 0)
    }
}

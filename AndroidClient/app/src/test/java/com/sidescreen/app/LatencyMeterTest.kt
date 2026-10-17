package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LatencyMeterTest {
    @Test
    fun emptyStatsHaveNoPercentiles() {
        val stats = LatencyStats(window = 10)
        assertNull(stats.p50())
        assertNull(stats.p95())
        assertEquals(0, stats.size)
    }

    @Test
    fun nearestRankPercentiles() {
        val stats = LatencyStats(window = 100)
        // Insert 1..100 shuffled so sorting is exercised.
        (1..100L).shuffled(java.util.Random(7)).forEach { stats.add(it) }
        assertEquals(50L, stats.p50())
        assertEquals(95L, stats.p95())
        assertEquals(100L, stats.percentile(1.0))
        assertEquals(1L, stats.percentile(0.01))
    }

    @Test
    fun singleSampleIsEveryPercentile() {
        val stats = LatencyStats(window = 4)
        stats.add(42)
        assertEquals(42L, stats.p50())
        assertEquals(42L, stats.p95())
    }

    @Test
    fun oldestSamplesAreEvicted() {
        val stats = LatencyStats(window = 4)
        listOf(1000L, 1000L, 1000L, 1000L, 1L, 2L, 3L, 4L).forEach { stats.add(it) }
        assertEquals(4, stats.size)
        assertEquals(8L, stats.total)
        assertEquals(2L, stats.p50())
        assertEquals(4L, stats.p95())
    }

    @Test
    fun clearResetsSamplesAndTotal() {
        val stats = LatencyStats(window = 4)
        stats.add(5)
        stats.clear()
        assertNull(stats.p50())
        assertEquals(0L, stats.total)
    }

    @Test
    fun timelineFindsRecordedFrames() {
        val timeline = FrameTimeline(capacity = 8)
        timeline.record(ptsUs = 1_000, recvNs = 1_000_000, hostCaptureNs = 555)
        timeline.record(ptsUs = 2_000, recvNs = 2_000_000, hostCaptureNs = 0)
        assertEquals(1_000_000L, timeline.recvNs(1_000))
        assertEquals(555L, timeline.hostCaptureNs(1_000))
        assertEquals(0L, timeline.hostCaptureNs(2_000))
        assertEquals(FrameTimeline.MISSING, timeline.recvNs(3_000))
        assertEquals(FrameTimeline.MISSING, timeline.hostCaptureNs(3_000))
    }

    @Test
    fun timelineEvictsOldestBeyondCapacity() {
        val timeline = FrameTimeline(capacity = 4)
        for (i in 1..6L) timeline.record(ptsUs = i, recvNs = i * 10, hostCaptureNs = i * 100)
        assertEquals(FrameTimeline.MISSING, timeline.recvNs(1))
        assertEquals(FrameTimeline.MISSING, timeline.recvNs(2))
        assertEquals(30L, timeline.recvNs(3))
        assertEquals(600L, timeline.hostCaptureNs(6))
    }

    @Test
    fun timelineClearForgetsEverything() {
        val timeline = FrameTimeline(capacity = 4)
        timeline.record(1, 10, 100)
        timeline.clear()
        assertEquals(FrameTimeline.MISSING, timeline.recvNs(1))
    }

    @Test
    fun capturedToRenderedThroughClockOffset() {
        // Host clock runs 5 s ahead of the client; a frame captured at host 5_000_010 ms,
        // rendered at client 25 ms, is 15 ms end-to-end.
        val clock = ClockSyncEstimator()
        val offset = 5_000_000_000_000L
        repeat(4) { i ->
            val t0 = i * 1_000_000L
            clock.addSample(t0, t0 + offset + 500_000, t0 + offset + 600_000, t0 + 1_100_000)
        }
        val timeline = FrameTimeline()
        val hostCapture = offset + 10_000_000L
        timeline.record(ptsUs = 20_000, recvNs = 20_000_000, hostCaptureNs = hostCapture)
        val captureClient = clock.hostToClientNs(timeline.hostCaptureNs(20_000))!!
        assertEquals(15_000_000L, 25_000_000L - captureClient)
    }
}

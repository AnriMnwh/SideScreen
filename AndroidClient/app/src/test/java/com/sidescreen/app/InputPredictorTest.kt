package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class InputPredictorTest {
    private val ms = 1_000_000L
    private val eps = 1e-4f

    private class FakeClock(
        var now: Long = 0L,
    ) {
        fun read() = now
    }

    @Test
    fun emptyPredictorPredictsOrigin() {
        val p = InputPredictor(nowNs = { 0L })
        p.predict(8f)
        assertEquals(0f, p.predictedX, eps)
        assertEquals(0f, p.predictedY, eps)
    }

    @Test
    fun singleSampleIsReturnedUnchanged() {
        val p = InputPredictor(nowNs = { 0L })
        p.addSample(0.3f, 0.4f, 0L)
        p.predict(8f)
        assertEquals(0.3f, p.predictedX, eps)
        assertEquals(0.4f, p.predictedY, eps)
    }

    @Test
    fun constantVelocityExtrapolatesByLead() {
        val clock = FakeClock()
        val p = InputPredictor(nowNs = clock::read)
        // 0.001 per ms in x, -0.0005 per ms in y, sampled every 4 ms.
        for (i in 0..5) p.addSample(0.2f + 0.004f * i, 0.6f - 0.002f * i, i * 4 * ms)
        clock.now = 20 * ms // sampled right now: no staleness
        p.predict(8f)
        assertEquals(0.22f + 0.008f, p.predictedX, eps)
        assertEquals(0.59f - 0.004f, p.predictedY, eps)
    }

    @Test
    fun stalenessOfNewestSampleIsAddedAndCapped() {
        val clock = FakeClock()
        val p = InputPredictor(nowNs = clock::read)
        for (i in 0..3) p.addSample(0.1f + 0.004f * i, 0.5f, i * 4 * ms) // 0.001 / ms
        clock.now = 12 * ms + 3 * ms
        p.predict(2f)
        assertEquals(0.112f + 0.005f, p.predictedX, eps)
        clock.now = 12 * ms + 100 * ms // a stalled finger: staleness capped at 8 ms
        p.predict(2f)
        assertEquals(0.112f + 0.010f, p.predictedX, eps)
    }

    @Test
    fun leastSquaresAveragesJitter() {
        val clock = FakeClock()
        val p = InputPredictor(nowNs = clock::read)
        // True motion 0.001/ms; alternating ±0.0005 noise that a two-point estimate would amplify.
        val noise = floatArrayOf(0.0005f, -0.0005f, 0.0005f, -0.0005f, 0.0005f, -0.0005f, 0.0005f, -0.0005f)
        for (i in 0..7) p.addSample(0.3f + 0.004f * i + noise[i], 0.5f, i * 4 * ms)
        clock.now = 28 * ms
        p.predict(8f)
        val last = 0.3f + 0.028f - 0.0005f
        val twoPoint = last + (0.004f - 0.001f) / 4f * 8f
        val predicted = p.predictedX
        // Within 0.001 of the true lead (0.008), clearly better than the two-point extrapolation.
        assertEquals(last + 0.008f, predicted, 0.001f)
        assertTrue(kotlin.math.abs(predicted - (last + 0.008f)) < kotlin.math.abs(twoPoint - (last + 0.008f)))
    }

    @Test
    fun samplesOutsideTheFitWindowAreIgnored() {
        val clock = FakeClock()
        val p = InputPredictor(nowNs = clock::read)
        // An old, fast stroke segment followed (after a pause) by slow recent motion.
        p.addSample(0.0f, 0.5f, 0L)
        p.addSample(0.5f, 0.5f, 4 * ms)
        for (i in 0..3) p.addSample(0.5f + 0.0004f * i, 0.5f, 200 * ms + i * 4 * ms) // 0.0001 / ms
        clock.now = 212 * ms
        p.predict(8f)
        assertEquals(0.5012f + 0.0008f, p.predictedX, eps)
    }

    @Test
    fun outOfOrderAndDuplicateTimesAreIgnored() {
        val p = InputPredictor(nowNs = { 8 * ms })
        p.addSample(0.1f, 0.1f, 0L)
        p.addSample(0.2f, 0.1f, 4 * ms)
        p.addSample(0.9f, 0.9f, 4 * ms) // duplicate timestamp
        p.addSample(0.9f, 0.9f, 2 * ms) // older than the newest
        p.addSample(0.3f, 0.1f, 8 * ms)
        p.predict(0f)
        assertEquals(0.3f, p.predictedX, eps)
        assertEquals(0.1f, p.predictedY, eps)
    }

    @Test
    fun predictionIsClampedToTheStream() {
        val p = InputPredictor(nowNs = { 8 * ms })
        p.addSample(0.9f, 0.05f, 0L)
        p.addSample(0.95f, 0.02f, 4 * ms)
        p.addSample(0.99f, 0.01f, 8 * ms)
        p.predict(8f)
        assertEquals(1f, p.predictedX, eps)
        assertEquals(0f, p.predictedY, eps)
    }

    @Test
    fun resetForgetsHistory() {
        val p = InputPredictor(nowNs = { 8 * ms })
        p.addSample(0.1f, 0.1f, 0L)
        p.addSample(0.2f, 0.2f, 4 * ms)
        p.reset()
        p.addSample(0.7f, 0.7f, 8 * ms)
        p.predict(8f)
        assertEquals(0.7f, p.predictedX, eps)
    }

    @Test
    fun leadIsHalfMinRttPlusTwoCappedAtEight() {
        assertEquals(2.5f, InputPredictor.leadMsFor(1.0), eps)
        assertEquals(7f, InputPredictor.leadMsFor(10.0), eps)
        assertEquals(8f, InputPredictor.leadMsFor(12.0), eps)
        assertEquals(8f, InputPredictor.leadMsFor(40.0), eps)
        assertEquals(2f, InputPredictor.leadMsFor(0.0), eps)
        assertEquals(8f, InputPredictor.leadMsFor(null), eps)
    }
}

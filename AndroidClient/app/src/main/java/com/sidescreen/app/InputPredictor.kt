package com.sidescreen.app

/**
 * Single-finger touch prediction: extrapolates the newest sample along a least-squares velocity
 * fitted over the recent samples (including the batched historical ones of each MotionEvent), so
 * the host sees the finger roughly where it is by the time the frame showing it comes back.
 *
 * Coordinates are the 0..1 stream space; times are nanoseconds in the [nowNs] clock domain (on
 * Android `System.nanoTime()` and `MotionEvent` times share CLOCK_MONOTONIC). Not thread-safe:
 * use from the UI thread only. Allocation-free after construction.
 */
class InputPredictor(
    private val nowNs: () -> Long = System::nanoTime,
    private val maxSamples: Int = 8,
) {
    init {
        require(maxSamples >= 2) { "maxSamples must be at least 2" }
    }

    private val xs = FloatArray(maxSamples)
    private val ys = FloatArray(maxSamples)
    private val ts = LongArray(maxSamples)
    private var next = 0
    private var count = 0

    /** Result of the last [predict]. */
    var predictedX = 0f
        private set
    var predictedY = 0f
        private set

    /** Adds a sample; out-of-order or duplicate timestamps are ignored so the fit stays well-posed. */
    fun addSample(
        x: Float,
        y: Float,
        timeNs: Long,
    ) {
        if (count > 0 && timeNs <= ts[newestIndex()]) return
        xs[next] = x
        ys[next] = y
        ts[next] = timeNs
        next = (next + 1) % maxSamples
        if (count < maxSamples) count++
    }

    /**
     * Predicts the position [leadMs] after now into [predictedX]/[predictedY], clamped to 0..1.
     * Falls back to the newest sample when there is too little recent history to trust a velocity.
     */
    fun predict(leadMs: Float) {
        if (count == 0) {
            predictedX = 0f
            predictedY = 0f
            return
        }
        val newest = newestIndex()
        val lastX = xs[newest]
        val lastY = ys[newest]
        predictedX = lastX
        predictedY = lastY

        // Least-squares slope over samples no older than FIT_WINDOW_NS before the newest.
        val tNewest = ts[newest]
        var n = 0
        var sumT = 0.0
        var sumX = 0.0
        var sumY = 0.0
        var sumTT = 0.0
        var sumTX = 0.0
        var sumTY = 0.0
        var i = newest
        var visited = 0
        while (visited < count) {
            val dtNs = tNewest - ts[i]
            if (dtNs > FIT_WINDOW_NS) break // older samples are older still
            val t = -dtNs / 1_000_000.0 // ms relative to the newest sample, keeps the sums small
            n++
            sumT += t
            sumX += xs[i]
            sumY += ys[i]
            sumTT += t * t
            sumTX += t * xs[i]
            sumTY += t * ys[i]
            i = if (i == 0) maxSamples - 1 else i - 1
            visited++
        }
        if (n < 2) return
        val denom = n * sumTT - sumT * sumT
        if (denom < MIN_TIME_SPREAD_MS2 * n * n) return // samples (nearly) simultaneous: no usable velocity
        val vx = (n * sumTX - sumT * sumX) / denom // units per ms
        val vy = (n * sumTY - sumT * sumY) / denom

        // Horizon: how stale the newest sample already is, plus the requested lead.
        val staleMs = ((nowNs() - tNewest) / 1_000_000.0).coerceIn(0.0, MAX_STALENESS_MS)
        val horizon = staleMs + leadMs.coerceAtLeast(0f)
        predictedX = (lastX + vx * horizon).toFloat().coerceIn(0f, 1f)
        predictedY = (lastY + vy * horizon).toFloat().coerceIn(0f, 1f)
    }

    fun reset() {
        next = 0
        count = 0
    }

    private fun newestIndex() = if (next == 0) maxSamples - 1 else next - 1

    companion object {
        /** Samples older than this before the newest one no longer describe the current stroke. */
        const val FIT_WINDOW_NS = 50_000_000L

        /** Never extrapolate a sample older than this; a stalled finger must not keep sliding. */
        const val MAX_STALENESS_MS = 8.0

        /** Minimum variance of the sample times (ms²) for a velocity to be meaningful. */
        private const val MIN_TIME_SPREAD_MS2 = 0.25

        const val MAX_LEAD_MS = 8f

        /** Lead = min(8 ms, minRtt / 2 + 2 ms): about the one-way trip; the cap when RTT is unknown. */
        fun leadMsFor(minRttMs: Double?): Float {
            if (minRttMs == null || minRttMs.isNaN() || minRttMs < 0) return MAX_LEAD_MS
            return minOf(MAX_LEAD_MS, (minRttMs / 2 + 2).toFloat())
        }
    }
}

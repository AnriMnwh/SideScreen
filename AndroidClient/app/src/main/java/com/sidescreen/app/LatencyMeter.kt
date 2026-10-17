package com.sidescreen.app

/**
 * Per-frame timestamps keyed by the decoder PTS (the receive `System.nanoTime() / 1000` handed to
 * [VideoDecoder.decode]), so decoder output and render callbacks can find when their frame arrived
 * and when the host captured it. Fixed-size ring, oldest entry evicted first; no allocation per
 * frame. Written on the socket thread, read on the decoder thread.
 */
class FrameTimeline(
    val capacity: Int = 256,
) {
    init {
        require(capacity > 0) { "capacity must be positive" }
    }

    private val lock = Any()
    private val ptsUs = LongArray(capacity)
    private val recvNs = LongArray(capacity)
    private val hostCaptureNs = LongArray(capacity)
    private var next = 0
    private var count = 0

    /** [hostCaptureNs] is in the host clock, 0 when the host did not stamp the frame. */
    fun record(
        ptsUs: Long,
        recvNs: Long,
        hostCaptureNs: Long,
    ) {
        synchronized(lock) {
            this.ptsUs[next] = ptsUs
            this.recvNs[next] = recvNs
            this.hostCaptureNs[next] = hostCaptureNs
            next = (next + 1) % capacity
            if (count < capacity) count++
        }
    }

    /** Receive instant recorded for [ptsUs], or [MISSING] when evicted or never recorded. */
    fun recvNs(ptsUs: Long): Long =
        synchronized(lock) {
            val i = indexOf(ptsUs)
            if (i < 0) MISSING else recvNs[i]
        }

    /** Host capture instant for [ptsUs]: 0 when unstamped, [MISSING] when evicted or never recorded. */
    fun hostCaptureNs(ptsUs: Long): Long =
        synchronized(lock) {
            val i = indexOf(ptsUs)
            if (i < 0) MISSING else hostCaptureNs[i]
        }

    fun clear() {
        synchronized(lock) {
            next = 0
            count = 0
        }
    }

    /** Newest first: decoder callbacks almost always ask about one of the last few frames. Caller holds [lock]. */
    private fun indexOf(pts: Long): Int {
        var i = next
        repeat(count) {
            i = if (i == 0) capacity - 1 else i - 1
            if (ptsUs[i] == pts) return i
        }
        return -1
    }

    companion object {
        const val MISSING = -1L
    }
}

/**
 * Rolling percentiles over the last [window] latency samples (nanoseconds). Thread-safe: samples
 * arrive on the decoder thread, the overlay reads on the main thread.
 */
class LatencyStats(
    val window: Int = 240,
) {
    init {
        require(window > 0) { "window must be positive" }
    }

    private val lock = Any()
    private val samples = LongArray(window)
    private val scratch = LongArray(window)
    private var next = 0
    private var count = 0

    /** Samples ever added since the last [clear]; lets a reader tell whether this source is still live. */
    @Volatile var total = 0L
        private set

    val size: Int get() = synchronized(lock) { count }

    fun add(ns: Long) {
        synchronized(lock) {
            samples[next] = ns
            next = (next + 1) % window
            if (count < window) count++
            total++
        }
    }

    fun p50(): Long? = percentile(0.50)

    fun p95(): Long? = percentile(0.95)

    /** Nearest-rank percentile, `fraction` in (0, 1]; null while empty. */
    fun percentile(fraction: Double): Long? {
        require(fraction > 0.0 && fraction <= 1.0) { "fraction must be in (0, 1]" }
        synchronized(lock) {
            if (count == 0) return null
            System.arraycopy(samples, 0, scratch, 0, count)
            java.util.Arrays.sort(scratch, 0, count)
            val rank = kotlin.math.ceil(fraction * count).toInt().coerceIn(1, count)
            return scratch[rank - 1]
        }
    }

    fun clear() {
        synchronized(lock) {
            next = 0
            count = 0
            total = 0
        }
    }
}

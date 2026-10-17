package com.sidescreen.app

import android.media.MediaFormat

/**
 * Type 16 (host → client): the colour format and frame rate the host encodes, plus what the
 * host supports. Colour fields are ITU-T H.273 code points.
 *
 * Wire payload after the type byte, [WIRE_SIZE] bytes:
 * `[ver=1][bitDepth][primaries][transfer][matrix][range][fps][flags]`, range 1 = full, 0 = limited,
 * flags bit0 = clock sync (types 17/18) supported, bit1 = host display matches the client panel
 * (the client owns orientation and ignores the type-1 rotation).
 */
data class StreamFormat(
    val bitDepth: Int,
    val primaries: Int,
    val transfer: Int,
    val matrix: Int,
    val fullRange: Boolean,
    val fps: Int,
    val hostSupportsClockSync: Boolean,
    val hostMatchesPanel: Boolean,
) {
    /** PQ (16) or HLG (18). */
    val isHdr: Boolean get() = transfer == TRANSFER_PQ || transfer == TRANSFER_HLG

    /** [MediaFormat.KEY_COLOR_STANDARD] for these primaries. */
    fun colorStandard(): Int =
        when (primaries) {
            PRIMARIES_BT2020 -> MediaFormat.COLOR_STANDARD_BT2020
            PRIMARIES_BT601_625 -> MediaFormat.COLOR_STANDARD_BT601_PAL
            PRIMARIES_BT601_525 -> MediaFormat.COLOR_STANDARD_BT601_NTSC
            else -> MediaFormat.COLOR_STANDARD_BT709
        }

    /** [MediaFormat.KEY_COLOR_TRANSFER] for this transfer characteristic. */
    fun colorTransfer(): Int =
        when (transfer) {
            TRANSFER_PQ -> MediaFormat.COLOR_TRANSFER_ST2084
            TRANSFER_HLG -> MediaFormat.COLOR_TRANSFER_HLG
            TRANSFER_LINEAR -> MediaFormat.COLOR_TRANSFER_LINEAR
            else -> MediaFormat.COLOR_TRANSFER_SDR_VIDEO
        }

    /** [MediaFormat.KEY_COLOR_RANGE]. */
    fun colorRange(): Int = if (fullRange) MediaFormat.COLOR_RANGE_FULL else MediaFormat.COLOR_RANGE_LIMITED

    companion object {
        const val WIRE_SIZE = 8
        private const val VERSION = 1
        private const val PRIMARIES_BT709 = 1
        private const val PRIMARIES_BT601_625 = 5
        private const val PRIMARIES_BT601_525 = 6
        private const val PRIMARIES_BT2020 = 9
        private const val TRANSFER_LINEAR = 8
        private const val TRANSFER_PQ = 16
        private const val TRANSFER_HLG = 18
        private const val FLAG_CLOCK_SYNC = 1
        private const val FLAG_MATCHES_PANEL = 2

        /** What an old host that never sends type 16 streams: 8-bit BT.709, limited range. */
        val SDR_709 =
            StreamFormat(
                bitDepth = 8,
                primaries = PRIMARIES_BT709,
                transfer = 1,
                matrix = 1,
                fullRange = false,
                fps = 60,
                hostSupportsClockSync = false,
                hostMatchesPanel = false,
            )

        /** Null when [payload] is short, carries an unknown version, or holds impossible values. */
        fun parse(payload: ByteArray): StreamFormat? {
            if (payload.size < WIRE_SIZE) return null
            val b = IntArray(WIRE_SIZE) { payload[it].toInt() and 0xFF }
            if (b[0] != VERSION) return null
            val bitDepth = b[1]
            val fps = b[6]
            if (bitDepth !in 8..16 || fps == 0 || b[5] > 1) return null
            val flags = b[7]
            return StreamFormat(
                bitDepth = bitDepth,
                primaries = b[2],
                transfer = b[3],
                matrix = b[4],
                fullRange = b[5] == 1,
                fps = fps,
                hostSupportsClockSync = flags and FLAG_CLOCK_SYNC != 0,
                hostMatchesPanel = flags and FLAG_MATCHES_PANEL != 0,
            )
        }
    }
}

/**
 * Type 15 (client → host): what this device decodes and displays, and the area it presents video
 * in right now. Re-sent whenever any field changes (rotation, fold switch, cutout mode).
 *
 * Payload after the type byte, [WIRE_SIZE] bytes, every byte with bit7 set so an old host that
 * skips unknown input byte by byte never mistakes it for a message type:
 * `[flagsHi][flagsLo][hzHi][hzLo][nitsHi][nitsLo][pwHi][pwLo][phHi][phLo][0x80|panelKind][0x80|ver]`,
 * pairs are 14-bit values in two 7-bit groups (high first), nits travel divided by 10.
 */
data class ClientCapabilities(
    val decodesHevcMain10: Boolean,
    val decodesHdr10Profile: Boolean,
    val displayHdr10: Boolean,
    val displayHlg: Boolean,
    val peakRefreshHz: Int,
    val maxLuminanceNits: Int,
    val presentationWidth: Int,
    val presentationHeight: Int,
    val panelKind: Int,
    val protocolVersion: Int = 1,
) {
    fun encode(): ByteArray {
        var flags = 0
        if (decodesHevcMain10) flags = flags or FLAG_MAIN10
        if (displayHdr10) flags = flags or FLAG_DISPLAY_HDR10
        if (displayHlg) flags = flags or FLAG_DISPLAY_HLG
        if (decodesHdr10Profile) flags = flags or FLAG_HDR10_PROFILE
        val out = ByteArray(WIRE_SIZE)
        putPair(out, 0, flags)
        putPair(out, 2, peakRefreshHz)
        putPair(out, 4, (maxLuminanceNits + 5) / 10)
        putPair(out, 6, presentationWidth)
        putPair(out, 8, presentationHeight)
        out[10] = (0x80 or panelKind.coerceIn(0, 0x7F)).toByte()
        out[11] = (0x80 or protocolVersion.coerceIn(0, 0x7F)).toByte()
        return out
    }

    companion object {
        const val WIRE_SIZE = 12
        private const val MAX_PAIR = 0x3FFF
        private const val FLAG_MAIN10 = 1
        private const val FLAG_DISPLAY_HDR10 = 2
        private const val FLAG_DISPLAY_HLG = 4
        private const val FLAG_HDR10_PROFILE = 8

        private fun putPair(
            out: ByteArray,
            offset: Int,
            value: Int,
        ) {
            val v = value.coerceIn(0, MAX_PAIR)
            out[offset] = (0x80 or (v shr 7)).toByte()
            out[offset + 1] = (0x80 or (v and 0x7F)).toByte()
        }

        /** Inverse of [encode]. Null when short or when any byte lacks bit7. */
        fun decode(bytes: ByteArray): ClientCapabilities? {
            if (bytes.size < WIRE_SIZE) return null
            val b = IntArray(WIRE_SIZE) { bytes[it].toInt() and 0xFF }
            if (b.any { it and 0x80 == 0 }) return null

            fun pair(offset: Int) = ((b[offset] and 0x7F) shl 7) or (b[offset + 1] and 0x7F)
            val flags = pair(0)
            return ClientCapabilities(
                decodesHevcMain10 = flags and FLAG_MAIN10 != 0,
                decodesHdr10Profile = flags and FLAG_HDR10_PROFILE != 0,
                displayHdr10 = flags and FLAG_DISPLAY_HDR10 != 0,
                displayHlg = flags and FLAG_DISPLAY_HLG != 0,
                peakRefreshHz = pair(2),
                maxLuminanceNits = pair(4) * 10,
                presentationWidth = pair(6),
                presentationHeight = pair(8),
                panelKind = b[10] and 0x7F,
                protocolVersion = b[11] and 0x7F,
            )
        }
    }
}

/**
 * Types 17/18. Request: the client's `System.nanoTime()` as Int64 BE. Response: `t0` echoed, then
 * the host's receive (`t1`) and send (`t2`) instants in its uptime-nanosecond clock, all UInt64 BE.
 */
object ClockSyncWire {
    const val MESSAGE_REQUEST = 17
    const val MESSAGE_RESPONSE = 18

    /** Payload size of a type-18 message after its type byte. */
    const val RESPONSE_SIZE = 24

    /** The complete type-17 message, type byte included, ready for a single write. */
    fun encodeRequest(t0: Long): ByteArray {
        val out = ByteArray(9)
        out[0] = MESSAGE_REQUEST.toByte()
        putLong(out, 1, t0)
        return out
    }

    /** `[t0, t1, t2]` from a type-18 payload (after the type byte). Requires [RESPONSE_SIZE] bytes. */
    fun parseResponse(p: ByteArray): LongArray {
        require(p.size >= RESPONSE_SIZE) { "clock-sync response needs $RESPONSE_SIZE bytes, got ${p.size}" }
        return longArrayOf(getLong(p, 0), getLong(p, 8), getLong(p, 16))
    }

    private fun putLong(
        out: ByteArray,
        offset: Int,
        value: Long,
    ) {
        for (i in 0 until 8) {
            out[offset + i] = (value ushr (56 - 8 * i)).toByte()
        }
    }

    private fun getLong(
        p: ByteArray,
        offset: Int,
    ): Long {
        var v = 0L
        for (i in 0 until 8) {
            v = (v shl 8) or (p[offset + i].toLong() and 0xFF)
        }
        return v
    }
}

/**
 * NTP-style host↔client clock estimate. Each exchange gives
 * `rtt = (t3 − t0) − (t2 − t1)` and `offset = ((t1 − t0) + (t2 − t3)) / 2` (host minus client);
 * the sample with the smallest RTT among the last [window] is trusted, since its one-way delays
 * can be the least asymmetric. Writers and readers may be on different threads.
 */
class ClockSyncEstimator(
    private val window: Int = 16,
) {
    private class Estimate(
        val offsetNs: Long,
        val minRttNs: Long,
        val samples: Int,
    )

    init {
        require(window > 0) { "window must be positive" }
    }

    private val lock = Any()
    private val rtts = LongArray(window)
    private val offsets = LongArray(window)
    private var next = 0
    private var count = 0

    @Volatile private var estimate: Estimate? = null

    /** t0/t3 in the client's `System.nanoTime()`, t1/t2 in the host clock. Negative-RTT samples are dropped. */
    fun addSample(
        t0: Long,
        t1: Long,
        t2: Long,
        t3: Long,
    ) {
        val rtt = (t3 - t0) - (t2 - t1)
        if (rtt < 0 || t3 < t0 || t2 < t1) return
        val offset = ((t1 - t0) + (t2 - t3)) / 2
        synchronized(lock) {
            rtts[next] = rtt
            offsets[next] = offset
            next = (next + 1) % window
            if (count < window) count++
            var best = 0
            for (i in 1 until count) {
                if (rtts[i] < rtts[best]) best = i
            }
            estimate = Estimate(offsets[best], rtts[best], count)
        }
    }

    fun reset() {
        synchronized(lock) {
            next = 0
            count = 0
            estimate = null
        }
    }

    /** Host clock minus client clock, from the minimum-RTT sample in the window. */
    val offsetNs: Long? get() = estimate?.offsetNs

    val minRttNs: Long? get() = estimate?.minRttNs

    /** Enough samples in the window that the minimum-RTT pick is meaningful. */
    val isConfident: Boolean get() = (estimate?.samples ?: 0) >= minOf(MIN_CONFIDENT_SAMPLES, window)

    /** A host-clock instant mapped into the client's `System.nanoTime()` domain. */
    fun hostToClientNs(hostNs: Long): Long? = estimate?.let { hostNs - it.offsetNs }

    companion object {
        const val MIN_CONFIDENT_SAMPLES = 4
    }
}

package com.sidescreen.app

/**
 * Wire encoding shared by the decoder-limit messages (types 11 and 14): each dimension is two
 * bytes of 7 data bits with the high bit always set, so a Mac that does not know the type and
 * skips unknown input one byte at a time never mistakes a payload byte for a message type.
 */
object DecoderLimitWire {
    /** Largest value two 7-bit bytes can carry. */
    const val MAX_DIMENSION = 16383

    /** [w]x[h] as 4 bytes: w-hi, w-lo, h-hi, h-lo. Values are clamped to 0..[MAX_DIMENSION]. */
    fun encodeSize(
        w: Int,
        h: Int,
    ): ByteArray {
        val cw = w.coerceIn(0, MAX_DIMENSION)
        val ch = h.coerceIn(0, MAX_DIMENSION)
        return byteArrayOf(
            (0x80 or ((cw shr 7) and 0x7F)).toByte(),
            (0x80 or (cw and 0x7F)).toByte(),
            (0x80 or ((ch shr 7) and 0x7F)).toByte(),
            (0x80 or (ch and 0x7F)).toByte(),
        )
    }

    /** The sizes back to back, in the order given. */
    fun encodeTable(sizes: List<Pair<Int, Int>>): ByteArray =
        sizes.fold(ByteArray(0)) { acc, (w, h) -> acc + encodeSize(w, h) }

    /** Inverse of [encodeSize] at [offset], for tests and diagnostics. Null unless every high bit is set. */
    fun decodeSize(
        bytes: ByteArray,
        offset: Int = 0,
    ): Pair<Int, Int>? {
        if (offset < 0 || bytes.size < offset + 4) return null
        val b = (0 until 4).map { bytes[offset + it].toInt() and 0xFF }
        if (b.any { it and 0x80 == 0 }) return null
        return (((b[0] and 0x7F) shl 7) or (b[1] and 0x7F)) to (((b[2] and 0x7F) shl 7) or (b[3] and 0x7F))
    }
}

package com.sidescreen.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DecoderLimitWireTest {
    @Test
    fun everyPayloadByteHasTheHighBitSet() {
        val bytes = DecoderLimitWire.encodeTable(listOf(2000 to 1200, 1744 to 1040, 1248 to 752))
        assertEquals(12, bytes.size)
        assertTrue(bytes.all { it.toInt() and 0x80 != 0 })
    }

    @Test
    fun sizesRoundTrip() {
        val bytes = DecoderLimitWire.encodeTable(listOf(2800 to 1840, 1248 to 752))
        assertEquals(2800 to 1840, DecoderLimitWire.decodeSize(bytes, 0))
        assertEquals(1248 to 752, DecoderLimitWire.decodeSize(bytes, 4))
    }

    @Test
    fun matchesTheType11Encoding() {
        // 2336 = 18 * 128 + 32 -> 0x92 0xA0; 1072 = 8 * 128 + 48 -> 0x88 0xB0
        assertArrayEquals(
            byteArrayOf(0x92.toByte(), 0xA0.toByte(), 0x88.toByte(), 0xB0.toByte()),
            DecoderLimitWire.encodeSize(2336, 1072),
        )
    }

    @Test
    fun oversizeDimensionsClampToWhatTwoSevenBitBytesHold() {
        assertEquals(16383 to 16383, DecoderLimitWire.decodeSize(DecoderLimitWire.encodeSize(20000, 99999)))
    }

    @Test
    fun rejectsBytesWithoutTheHighBit() {
        assertNull(DecoderLimitWire.decodeSize(byteArrayOf(0x12, 0x20, 0x08, 0x30)))
        assertNull(DecoderLimitWire.decodeSize(byteArrayOf(0x92.toByte(), 0xA0.toByte()), 0))
    }
}

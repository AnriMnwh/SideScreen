package com.sidescreen.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamWireTest {
    private fun caps(
        width: Int,
        height: Int,
        main10: Boolean = true,
        hdr10Profile: Boolean = true,
        hdr10: Boolean = true,
        hlg: Boolean = true,
        hz: Int = 120,
        nits: Int = 1000,
        kind: Int = PanelGeometry.PANEL_KIND_BUILT_IN,
    ) = ClientCapabilities(
        decodesHevcMain10 = main10,
        decodesHdr10Profile = hdr10Profile,
        displayHdr10 = hdr10,
        displayHlg = hlg,
        peakRefreshHz = hz,
        maxLuminanceNits = nits,
        presentationWidth = width,
        presentationHeight = height,
        panelKind = kind,
    )

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    // Type 15

    @Test
    fun portraitAdvertMatchesTheGoldenBytes() {
        // flags 0b1111, 120 Hz, 1000 nits -> 100, 1080 = 8*128+56, 2340 = 18*128+36, built-in, ver 1
        assertArrayEquals(
            bytes(0x80, 0x8F, 0x80, 0xF8, 0x80, 0xE4, 0x88, 0xB8, 0x92, 0xA4, 0x81, 0x81),
            caps(1080, 2340).encode(),
        )
    }

    @Test
    fun landscapeAdvertMatchesTheGoldenBytes() {
        assertArrayEquals(
            bytes(0x80, 0x8F, 0x80, 0xF8, 0x80, 0xE4, 0x92, 0xA4, 0x88, 0xB8, 0x81, 0x81),
            caps(2340, 1080).encode(),
        )
    }

    @Test
    fun portraitAndLandscapeAdvertsRoundTrip() {
        for (advert in listOf(caps(1080, 2340), caps(2340, 1080), caps(1848, 2448), caps(2448, 1848))) {
            val encoded = advert.encode()
            assertEquals(ClientCapabilities.WIRE_SIZE, encoded.size)
            assertEquals(advert, ClientCapabilities.decode(encoded))
        }
    }

    @Test
    fun rotatedAdvertsDifferOnlyInTheSizeBytes() {
        val portrait = caps(1080, 2340).encode()
        val landscape = caps(2340, 1080).encode()
        for (i in 0 until ClientCapabilities.WIRE_SIZE) {
            if (i in 6..9) continue
            assertEquals("byte $i", portrait[i], landscape[i])
        }
        assertFalse(portrait.contentEquals(landscape))
    }

    @Test
    fun everyAdvertByteHasTheHighBitSet() {
        val adverts =
            listOf(
                caps(1080, 2340),
                caps(2448, 1848, kind = PanelGeometry.PANEL_KIND_EXTERNAL),
                caps(
                    0,
                    0,
                    main10 = false,
                    hdr10Profile = false,
                    hdr10 = false,
                    hlg = false,
                    hz = 0,
                    nits = 0,
                    kind = 0,
                ),
                caps(16383, 16383, hz = 240, nits = 10000),
            )
        for (advert in adverts) {
            val encoded = advert.encode()
            assertEquals(12, encoded.size)
            encoded.forEachIndexed { i, b -> assertTrue("byte $i of $advert", b.toInt() and 0x80 != 0) }
        }
    }

    @Test
    fun capabilityFlagsUseTheirOwnBits() {
        val none = caps(1, 1, main10 = false, hdr10Profile = false, hdr10 = false, hlg = false)
        assertEquals(0x80.toByte(), none.encode()[1])
        assertEquals(0x81.toByte(), none.copy(decodesHevcMain10 = true).encode()[1])
        assertEquals(0x82.toByte(), none.copy(displayHdr10 = true).encode()[1])
        assertEquals(0x84.toByte(), none.copy(displayHlg = true).encode()[1])
        assertEquals(0x88.toByte(), none.copy(decodesHdr10Profile = true).encode()[1])
        for (single in listOf(
            none.copy(decodesHevcMain10 = true),
            none.copy(displayHdr10 = true),
            none.copy(displayHlg = true),
            none.copy(decodesHdr10Profile = true),
        )) {
            assertEquals(single, ClientCapabilities.decode(single.encode()))
        }
    }

    @Test
    fun luminanceTravelsInTensOfNits() {
        assertEquals(1000, ClientCapabilities.decode(caps(1, 1, nits = 1000).encode())?.maxLuminanceNits)
        assertEquals(0, ClientCapabilities.decode(caps(1, 1, nits = 0).encode())?.maxLuminanceNits)
        assertEquals(1010, ClientCapabilities.decode(caps(1, 1, nits = 1006).encode())?.maxLuminanceNits)
    }

    @Test
    fun oversizeValuesClampToFourteenBits() {
        val decoded = ClientCapabilities.decode(caps(20000, 99999, hz = 50000).encode())
        assertNotNull(decoded)
        assertEquals(16383, decoded?.presentationWidth)
        assertEquals(16383, decoded?.presentationHeight)
        assertEquals(16383, decoded?.peakRefreshHz)
    }

    @Test
    fun decodeRejectsShortOrUnmarkedPayloads() {
        val good = caps(1080, 2340).encode()
        assertNull(ClientCapabilities.decode(good.copyOf(11)))
        for (i in good.indices) {
            val bad = good.copyOf()
            bad[i] = (bad[i].toInt() and 0x7F).toByte()
            assertNull("byte $i without bit7", ClientCapabilities.decode(bad))
        }
    }

    // Type 16

    @Test
    fun parsesHdr10At120MatchingThePanel() {
        val format = StreamFormat.parse(bytes(1, 10, 9, 16, 9, 0, 120, 0x03))
        assertEquals(
            StreamFormat(
                bitDepth = 10,
                primaries = 9,
                transfer = 16,
                matrix = 9,
                fullRange = false,
                fps = 120,
                hostSupportsClockSync = true,
                hostMatchesPanel = true,
            ),
            format,
        )
        assertTrue(format!!.isHdr)
    }

    @Test
    fun parsesSdr709At60WithoutPanelMatch() {
        val format = StreamFormat.parse(bytes(1, 8, 1, 1, 1, 0, 60, 0x01))
        assertNotNull(format)
        assertFalse(format!!.isHdr)
        assertTrue(format.hostSupportsClockSync)
        assertFalse(format.hostMatchesPanel)
        assertEquals(StreamFormat.SDR_709.copy(hostSupportsClockSync = true), format)
    }

    @Test
    fun flagBitsAreIndependent() {
        val matchOnly = StreamFormat.parse(bytes(1, 8, 1, 1, 1, 0, 60, 0x02))!!
        assertFalse(matchOnly.hostSupportsClockSync)
        assertTrue(matchOnly.hostMatchesPanel)

        val none = StreamFormat.parse(bytes(1, 8, 1, 1, 1, 0, 60, 0x00))!!
        assertFalse(none.hostSupportsClockSync)
        assertFalse(none.hostMatchesPanel)

        val unknownBitsToo = StreamFormat.parse(bytes(1, 8, 1, 1, 1, 0, 60, 0xFF))!!
        assertTrue(unknownBitsToo.hostSupportsClockSync)
        assertTrue(unknownBitsToo.hostMatchesPanel)
    }

    @Test
    fun parsesHlgFullRangeAndUnsignedFps() {
        val format = StreamFormat.parse(bytes(1, 10, 9, 18, 9, 1, 240, 0x01))!!
        assertTrue(format.isHdr)
        assertTrue(format.fullRange)
        assertEquals(240, format.fps)
    }

    @Test
    fun rejectsMalformedStreamFormats() {
        assertNull(StreamFormat.parse(bytes(1, 10, 9, 16, 9, 0, 120)))
        assertNull(StreamFormat.parse(bytes(2, 10, 9, 16, 9, 0, 120, 0x03)))
        assertNull(StreamFormat.parse(bytes(1, 7, 9, 16, 9, 0, 120, 0x03)))
        assertNull(StreamFormat.parse(bytes(1, 10, 9, 16, 9, 2, 120, 0x03)))
        assertNull(StreamFormat.parse(bytes(1, 10, 9, 16, 9, 0, 0, 0x03)))
    }

    @Test
    fun oldHostDefaultIsSdr709WithoutExtras() {
        val sdr = StreamFormat.SDR_709
        assertEquals(8, sdr.bitDepth)
        assertFalse(sdr.isHdr)
        assertFalse(sdr.fullRange)
        assertFalse(sdr.hostSupportsClockSync)
        assertFalse(sdr.hostMatchesPanel)
    }

    // Types 17/18

    @Test
    fun clockSyncRequestIsTypeThenBigEndianT0() {
        assertArrayEquals(
            bytes(17, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08),
            ClockSyncWire.encodeRequest(0x0102030405060708L),
        )
        assertArrayEquals(
            bytes(17, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE),
            ClockSyncWire.encodeRequest(-2L),
        )
    }

    @Test
    fun clockSyncResponseParsesThreeBigEndianInstants() {
        val payload =
            bytes(
                // 12345
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x39,
                // 1 shl 40
                0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
                // Long.MAX_VALUE
                0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            )
        assertArrayEquals(longArrayOf(12345L, 1L shl 40, Long.MAX_VALUE), ClockSyncWire.parseResponse(payload))
    }

    @Test
    fun clockSyncRequestT0EchoesBackThroughAResponse() {
        val t0 = 987_654_321_012_345L
        val request = ClockSyncWire.encodeRequest(t0)
        val payload = request.copyOfRange(1, 9) + ByteArray(16)
        assertEquals(t0, ClockSyncWire.parseResponse(payload)[0])
    }

    @Test(expected = IllegalArgumentException::class)
    fun shortClockSyncResponseIsRejected() {
        ClockSyncWire.parseResponse(ByteArray(ClockSyncWire.RESPONSE_SIZE - 1))
    }
}

package com.sidescreen.app

import android.content.pm.ActivityInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamLayoutTest {
    private val eps = 1e-3f

    private fun assertRect(
        expected: StreamRect,
        actual: StreamRect,
    ) {
        assertEquals(expected.left, actual.left, eps)
        assertEquals(expected.top, actual.top, eps)
        assertEquals(expected.width, actual.width, eps)
        assertEquals(expected.height, actual.height, eps)
    }

    @Test
    fun matchingAspectFillsTheView() {
        assertRect(StreamRect(0f, 0f, 2340f, 1080f), StreamLayout.fitRect(2340f, 1080f, 2340, 1080))
        // 1:1 pixels not required, only the aspect: a 2× HiDPI stream still fills.
        assertRect(StreamRect(0f, 0f, 2340f, 1080f), StreamLayout.fitRect(2340f, 1080f, 1170, 540))
    }

    @Test
    fun widerStreamIsLetterboxedTopAndBottom() {
        // Landscape stream still on screen right after the phone turned portrait.
        val r = StreamLayout.fitRect(1080f, 2340f, 2340, 1080)
        assertRect(StreamRect(0f, (2340f - 498.4615f) / 2f, 1080f, 498.4615f), r)
    }

    @Test
    fun tallerStreamIsPillarboxed() {
        // Retroid Pocket 6 landscape panel showing a 16:10 stream.
        val r = StreamLayout.fitRect(1920f, 1080f, 1920, 1200)
        assertRect(StreamRect((1920f - 1728f) / 2f, 0f, 1728f, 1080f), r)
    }

    @Test
    fun tabletopTopHalfLetterboxes() {
        // Fold inner panel, video confined above the hinge.
        val r = StreamLayout.fitRect(2448f, 924f, 2448, 1848)
        assertEquals(924f, r.height, eps)
        assertEquals(924f * 2448f / 1848f, r.width, eps)
        assertEquals(0f, r.top, eps)
    }

    @Test
    fun unknownStreamSizeFillsAndEmptyViewIsEmpty() {
        assertRect(StreamRect(0f, 0f, 800f, 600f), StreamLayout.fitRect(800f, 600f, 0, 0))
        assertTrue(StreamLayout.fitRect(0f, 600f, 1920, 1080).isEmpty)
    }

    @Test
    fun normalizeInsideMapsToUnitSquare() {
        val r = StreamLayout.fitRect(1920f, 1080f, 1920, 1200) // x 96..1824
        val (x, y) = StreamLayout.normalizeTouch(96f, 0f, r)!!
        assertEquals(0f, x, eps)
        assertEquals(0f, y, eps)
        val (cx, cy) = StreamLayout.normalizeTouch(960f, 540f, r)!!
        assertEquals(0.5f, cx, eps)
        assertEquals(0.5f, cy, eps)
        val (ex, ey) = StreamLayout.normalizeTouch(1824f, 1080f, r)!!
        assertEquals(1f, ex, eps)
        assertEquals(1f, ey, eps)
    }

    @Test
    fun normalizeOutsideIsDropped() {
        val r = StreamLayout.fitRect(1920f, 1080f, 1920, 1200)
        assertNull(StreamLayout.normalizeTouch(50f, 540f, r))
        assertNull(StreamLayout.normalizeTouch(1900f, 540f, r))
        assertNull(StreamLayout.normalizeTouch(960f, -1f, r))
        assertNull(StreamLayout.normalizeTouch(10f, 10f, StreamRect(0f, 0f, 0f, 0f)))
        assertNotNull(StreamLayout.normalizeTouch(100f, 540f, r))
    }

    @Test
    fun clampPinsToEdges() {
        val r = StreamLayout.fitRect(1920f, 1080f, 1920, 1200)
        val (x, y) = StreamLayout.clampTouch(0f, 2000f, r)
        assertEquals(0f, x, eps)
        assertEquals(1f, y, eps)
    }

    @Test
    fun legacyOrientationFollowsHostRotation() {
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, StreamLayout.legacyOrientationFor(1920, 1200, 0))
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, StreamLayout.legacyOrientationFor(1200, 1920, 90))
        assertEquals(
            ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE,
            StreamLayout.legacyOrientationFor(1920, 1200, 180),
        )
        assertEquals(
            ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT,
            StreamLayout.legacyOrientationFor(1200, 1920, 270),
        )
        // Unknown size behaves exactly like the rotation-only mapping.
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, StreamLayout.legacyOrientationFor(0, 0, 0))
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, StreamLayout.legacyOrientationFor(0, 0, 90))
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, StreamLayout.legacyOrientationFor(1920, 1200, 45))
    }

    @Test
    fun legacyPortraitShapedStreamWithoutRotationStaysUpright() {
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, StreamLayout.legacyOrientationFor(1080, 1920, 0))
        assertEquals(
            ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT,
            StreamLayout.legacyOrientationFor(1080, 1920, 180),
        )
        // A square stream counts as landscape.
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, StreamLayout.legacyOrientationFor(1500, 1500, 0))
    }

    @Test
    fun orientationModeMapping() {
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR, StreamLayout.orientationFor(OrientationMode.AUTO))
        assertEquals(
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT,
            StreamLayout.orientationFor(OrientationMode.PORTRAIT),
        )
        assertEquals(
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE,
            StreamLayout.orientationFor(OrientationMode.LANDSCAPE),
        )
    }
}

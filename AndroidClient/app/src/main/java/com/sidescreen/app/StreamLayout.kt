package com.sidescreen.app

import android.content.pm.ActivityInfo

/** Axis-aligned rectangle in view pixels. Plain Kotlin so the layout math runs in JVM unit tests. */
data class StreamRect(
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float,
) {
    val right: Float get() = left + width
    val bottom: Float get() = top + height
    val isEmpty: Boolean get() = width <= 0f || height <= 0f
}

/** Where the video sits inside its view, how touches map back onto it, and who picks the orientation. */
object StreamLayout {
    /**
     * Largest rectangle with the stream's aspect ratio centred in a `viewW`×`viewH` view: the
     * picture's real position while the view and the stream disagree (the moments after a rotation
     * re-mode, tabletop posture, an old host's fixed resolution). Unknown stream size → the whole view.
     */
    fun fitRect(
        viewW: Float,
        viewH: Float,
        streamW: Int,
        streamH: Int,
    ): StreamRect {
        if (viewW <= 0f || viewH <= 0f) return StreamRect(0f, 0f, 0f, 0f)
        if (streamW <= 0 || streamH <= 0) return StreamRect(0f, 0f, viewW, viewH)
        val scale = minOf(viewW / streamW, viewH / streamH)
        val w = streamW * scale
        val h = streamH * scale
        return StreamRect((viewW - w) / 2f, (viewH - h) / 2f, w, h)
    }

    /** View coordinates → 0..1 stream coordinates, or null when the point is outside the picture. */
    fun normalizeTouch(
        x: Float,
        y: Float,
        rect: StreamRect,
    ): Pair<Float, Float>? {
        if (rect.isEmpty) return null
        if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) return null
        return Pair((x - rect.left) / rect.width, (y - rect.top) / rect.height)
    }

    /**
     * Like [normalizeTouch] but pinned to the picture's edge instead of rejected. For events that
     * must reach the host whatever the position: the release of a gesture that started inside, and
     * the second finger of a two-finger gesture.
     */
    fun clampTouch(
        x: Float,
        y: Float,
        rect: StreamRect,
    ): Pair<Float, Float> {
        if (rect.isEmpty) return Pair(0f, 0f)
        return Pair(
            ((x - rect.left) / rect.width).coerceIn(0f, 1f),
            ((y - rect.top) / rect.height).coerceIn(0f, 1f),
        )
    }

    /**
     * Old host (or "match device" off): the host rotates its desktop and the client follows. The
     * type-1 rotation decides, exactly as before; with rotation 0/180 a portrait-shaped stream (a
     * custom portrait resolution) is shown upright in portrait instead of squeezed into landscape.
     */
    fun legacyOrientationFor(
        streamW: Int,
        streamH: Int,
        rotation: Int,
    ): Int {
        val portraitStream = streamW in 1 until streamH
        return when (rotation) {
            90 -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            270 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
            180 ->
                if (portraitStream) {
                    ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
                } else {
                    ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                }
            else ->
                if (portraitStream) {
                    ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                } else {
                    ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                }
        }
    }

    /** Host matches the panel: the phone owns orientation and the host follows its adverts. */
    fun orientationFor(mode: OrientationMode): Int =
        when (mode) {
            OrientationMode.AUTO -> ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
            OrientationMode.PORTRAIT -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
            OrientationMode.LANDSCAPE -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        }
}

package com.sidescreen.app

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.view.Display
import kotlin.math.roundToInt

/**
 * Native panel size in landscape orientation, plus the fastest mode it can present and its HDR
 * abilities. Width/height stay landscape-normalised so the decoder limit tables are stable.
 */
data class PanelGeometry(
    val width: Int,
    val height: Int,
    val refreshHz: Int,
    val isHdr10: Boolean = false,
    val isHlg: Boolean = false,
    /** Desired peak luminance the panel reports, in nits; 0 when unknown. */
    val maxLuminanceNits: Int = 0,
    /** Wire panel kind: [PANEL_KIND_UNKNOWN], [PANEL_KIND_BUILT_IN] or [PANEL_KIND_EXTERNAL]. */
    val panelKind: Int = PANEL_KIND_UNKNOWN,
) {
    companion object {
        const val PANEL_KIND_UNKNOWN = 0
        const val PANEL_KIND_BUILT_IN = 1
        const val PANEL_KIND_EXTERNAL = 3

        /**
         * [Display.Mode.physicalWidth] and [Display.Mode.physicalHeight] report the panel in its
         * natural orientation whatever the current rotation, so this answer is stable when the
         * tablet is turned. Null when the display or its mode is unavailable.
         */
        fun of(display: Display?): PanelGeometry? {
            val mode = display?.mode ?: return null
            val w = maxOf(mode.physicalWidth, mode.physicalHeight)
            val h = minOf(mode.physicalWidth, mode.physicalHeight)
            if (w <= 0 || h <= 0) return null
            // Peak rate over all modes, not the current one: a panel parked at 60 can still be
            // asked for 90, and decoding faster than the peak only burns throughput budget.
            val hz =
                display.supportedModes
                    ?.maxOfOrNull { it.refreshRate }
                    ?.roundToInt()
                    ?: display.refreshRate.roundToInt()
            val hdrTypes = supportedHdrTypes(display, mode)
            val nits =
                display.hdrCapabilities
                    ?.desiredMaxLuminance
                    ?.takeIf { it.isFinite() && it > 0f }
                    ?.roundToInt()
                    ?: 0
            val kind =
                when {
                    display.displayId == Display.DEFAULT_DISPLAY -> PANEL_KIND_BUILT_IN
                    display.flags and Display.FLAG_PRESENTATION != 0 -> PANEL_KIND_EXTERNAL
                    else -> PANEL_KIND_UNKNOWN
                }
            return PanelGeometry(
                width = w,
                height = h,
                refreshHz = hz.coerceIn(24, 240),
                isHdr10 = Display.HdrCapabilities.HDR_TYPE_HDR10 in hdrTypes,
                isHlg = Display.HdrCapabilities.HDR_TYPE_HLG in hdrTypes,
                maxLuminanceNits = nits,
                panelKind = kind,
            )
        }

        /** Per-mode HDR types on API 34+ (they can differ between modes); the display-wide list before. */
        private fun supportedHdrTypes(
            display: Display,
            mode: Display.Mode,
        ): IntArray =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                mode.supportedHdrTypes
            } else {
                @Suppress("DEPRECATION")
                display.hdrCapabilities?.supportedHdrTypes ?: IntArray(0)
            }

        fun ofDefaultDisplay(context: Context): PanelGeometry? =
            try {
                val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
                of(dm.getDisplay(Display.DEFAULT_DISPLAY))
            } catch (_: Exception) {
                null
            }
    }
}

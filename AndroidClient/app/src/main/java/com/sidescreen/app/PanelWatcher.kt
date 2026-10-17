package com.sidescreen.app

import android.app.Activity
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.WindowInsets

/**
 * Tracks the presentation geometry (window bounds in the current orientation, minus the camera
 * cutout in [CutoutMode.AVOID]) and reports it once it has been stable for [DEBOUNCE_MS].
 * Only changes are emitted. All methods must be called on the main thread.
 */
class PanelWatcher(
    private val activity: Activity,
    private val cutoutMode: () -> CutoutMode,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val displayManager = activity.getSystemService(DisplayManager::class.java)
    private var onChanged: ((PresentationGeometry) -> Unit)? = null
    private var last: PresentationGeometry? = null
    private var started = false

    private val emit =
        Runnable {
            val callback = onChanged ?: return@Runnable
            val geometry = compute() ?: return@Runnable
            if (geometry == last) return@Runnable
            last = geometry
            callback(geometry)
        }

    private val displayListener =
        object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) = Unit

            override fun onDisplayRemoved(displayId: Int) = Unit

            override fun onDisplayChanged(displayId: Int) {
                if (displayId == Display.DEFAULT_DISPLAY) schedule()
            }
        }

    fun start(onChanged: (PresentationGeometry) -> Unit) {
        if (started) stop()
        started = true
        this.onChanged = onChanged
        last = null
        displayManager.registerDisplayListener(displayListener, handler)
        schedule()
    }

    fun stop() {
        if (!started) return
        started = false
        handler.removeCallbacks(emit)
        displayManager.unregisterDisplayListener(displayListener)
        onChanged = null
    }

    /** Latest measured geometry right now, independent of the debounce. */
    fun current(): PresentationGeometry? = compute()

    fun notifyConfigurationChanged() = schedule()

    fun notifyInsetsChanged() = schedule()

    private fun schedule() {
        if (!started) return
        handler.removeCallbacks(emit)
        handler.postDelayed(emit, DEBOUNCE_MS)
    }

    private fun compute(): PresentationGeometry? {
        val panel = PanelGeometry.of(activity.display) ?: PanelGeometry.ofDefaultDisplay(activity) ?: return null
        val metrics = activity.windowManager.currentWindowMetrics
        val bounds = metrics.bounds
        var w = bounds.width()
        var h = bounds.height()
        if (cutoutMode() == CutoutMode.AVOID) {
            val cutout = metrics.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.displayCutout())
            w -= cutout.left + cutout.right
            h -= cutout.top + cutout.bottom
        }
        w = w and 1.inv()
        h = h and 1.inv()
        if (w <= 0 || h <= 0) return null
        return PresentationGeometry(w, h, panel)
    }

    private companion object {
        const val DEBOUNCE_MS = 300L
    }
}

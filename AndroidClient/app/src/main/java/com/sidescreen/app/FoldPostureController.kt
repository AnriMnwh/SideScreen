package com.sidescreen.app

import android.app.Activity
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

sealed class Posture {
    object Flat : Posture() {
        override fun toString() = "Flat"
    }

    /** Half-opened with a horizontal hinge; content belongs above [hingeTopPx]. */
    data class Tabletop(
        val hingeTopPx: Int,
    ) : Posture()

    /** Half-opened with a vertical hinge at [hingeLeftPx]. */
    data class Book(
        val hingeLeftPx: Int,
    ) : Posture()
}

class FoldPostureController(
    private val activity: Activity,
) {
    /** Collects posture changes in [scope] until it is cancelled; callbacks run on [scope]'s dispatcher. */
    fun observe(
        scope: CoroutineScope,
        onPosture: (Posture) -> Unit,
    ): Job =
        scope.launch {
            WindowInfoTracker
                .getOrCreate(activity)
                .windowLayoutInfo(activity)
                .map { info ->
                    val fold = info.displayFeatures.filterIsInstance<FoldingFeature>().firstOrNull()
                    when {
                        fold == null || fold.state != FoldingFeature.State.HALF_OPENED -> Posture.Flat
                        fold.orientation == FoldingFeature.Orientation.HORIZONTAL -> Posture.Tabletop(fold.bounds.top)
                        else -> Posture.Book(fold.bounds.left)
                    }
                }.distinctUntilChanged()
                .collect(onPosture)
        }
}

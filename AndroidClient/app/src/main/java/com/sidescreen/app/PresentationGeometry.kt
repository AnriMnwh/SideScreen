package com.sidescreen.app

/**
 * The area the video is shown in, in the window's current orientation (minus the cutout in
 * "avoid" mode), plus the static panel description it was measured on.
 */
data class PresentationGeometry(
    val width: Int,
    val height: Int,
    val panel: PanelGeometry,
)

fun PresentationGeometry.toCapabilities(main10: CodecCapabilities.Main10Support): ClientCapabilities =
    ClientCapabilities(
        decodesHevcMain10 = main10.main10,
        decodesHdr10Profile = main10.hdr10Profile,
        displayHdr10 = panel.isHdr10,
        displayHlg = panel.isHlg,
        peakRefreshHz = panel.refreshHz,
        maxLuminanceNits = panel.maxLuminanceNits,
        presentationWidth = width,
        presentationHeight = height,
        panelKind = panel.panelKind,
    )

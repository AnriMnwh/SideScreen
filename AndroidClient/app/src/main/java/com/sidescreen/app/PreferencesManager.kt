package com.sidescreen.app

import android.content.Context
import android.content.SharedPreferences

class PreferencesManager(
    context: Context,
) {
    private val prefs: SharedPreferences = context.getSharedPreferences("app_prefs", Context.MODE_PRIVATE)

    var showStatsOverlay: Boolean
        get() = prefs.getBoolean("show_stats", true)
        set(value) = prefs.edit().putBoolean("show_stats", value).apply()

    var overlayOpacity: Float
        get() = prefs.getFloat("overlay_opacity", 0.8f)
        set(value) = prefs.edit().putFloat("overlay_opacity", value).apply()

    var overlayX: Float
        get() = prefs.getFloat("overlay_x", -1f)
        set(value) = prefs.edit().putFloat("overlay_x", value).apply()

    var overlayY: Float
        get() = prefs.getFloat("overlay_y", -1f)
        set(value) = prefs.edit().putFloat("overlay_y", value).apply()

    var settingsButtonX: Float
        get() = prefs.getFloat("settings_x", -1f)
        set(value) = prefs.edit().putFloat("settings_x", value).apply()

    var settingsButtonY: Float
        get() = prefs.getFloat("settings_y", -1f)
        set(value) = prefs.edit().putFloat("settings_y", value).apply()

    // Corner position: 0=bottom-right, 1=bottom-left, 2=top-right, 3=top-left
    var settingsButtonCorner: Int
        get() = prefs.getInt("settings_corner", 0)
        set(value) = prefs.edit().putInt("settings_corner", value).apply()

    var hideSettingsButton: Boolean
        get() = prefs.getBoolean("hide_settings_button", false)
        set(value) = prefs.edit().putBoolean("hide_settings_button", value).apply()

    var connectionMode: ConnectionMode
        get() = ConnectionMode.fromName(prefs.getString("connection_mode", null))
        set(value) = prefs.edit().putString("connection_mode", value.name).apply()

    var orientationMode: OrientationMode
        get() = OrientationMode.fromName(prefs.getString("orientation_mode", null))
        set(value) = prefs.edit().putString("orientation_mode", value.name).apply()

    var cutoutMode: CutoutMode
        get() = CutoutMode.fromName(prefs.getString("cutout_mode", null))
        set(value) = prefs.edit().putString("cutout_mode", value.name).apply()
}

enum class OrientationMode {
    AUTO,
    PORTRAIT,
    LANDSCAPE,
    ;

    companion object {
        fun fromName(name: String?): OrientationMode = entries.firstOrNull { it.name == name } ?: AUTO
    }
}

enum class CutoutMode {
    FILL,
    AVOID,
    ;

    companion object {
        fun fromName(name: String?): CutoutMode = entries.firstOrNull { it.name == name } ?: FILL
    }
}

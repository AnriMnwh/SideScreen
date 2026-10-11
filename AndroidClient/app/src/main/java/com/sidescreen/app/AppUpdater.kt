package com.sidescreen.app

import android.app.Activity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.google.android.play.core.appupdate.AppUpdateManager
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.UpdateAvailability

private fun updDiag(msg: String) = DiagLog.log("UP", msg)

/**
 * Google Play in-app updates, immediate flavour: when Play has a newer build, Play's
 * full-screen update UI takes over, installs it and restarts the app. The check runs
 * from onResume while idle (never over a stream or the demo), so a session is never
 * interrupted, but the next idle resume insists again. Backing out of Play's UI closes
 * the app: a Play-installed build must run the current version. Only Play installs get
 * offers — sideloaded APKs and the .debug build just log the failure and carry on.
 */
class AppUpdater(
    private val activity: AppCompatActivity,
) {
    private val manager: AppUpdateManager = AppUpdateManagerFactory.create(activity)

    private val launcher: ActivityResultLauncher<IntentSenderRequest> =
        activity.registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
            updDiag("Update flow result: ${result.resultCode}")
            if (result.resultCode != Activity.RESULT_OK) {
                // Cancelled or failed: the update is mandatory, so do not run the stale build.
                activity.finish()
            }
        }

    /** Call when the app is idle (not streaming) — typically from onResume. */
    fun checkForUpdate() {
        manager.appUpdateInfo
            .addOnSuccessListener { info ->
                val availability = info.updateAvailability()
                // DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS: an immediate flow was interrupted
                // (e.g. the app was backgrounded mid-download); resume it the same way.
                val wanted =
                    availability == UpdateAvailability.UPDATE_AVAILABLE ||
                        availability == UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS
                if (wanted && info.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE)) {
                    updDiag("Update required: versionCode=${info.availableVersionCode()}")
                    manager.startUpdateFlowForResult(
                        info,
                        launcher,
                        AppUpdateOptions.newBuilder(AppUpdateType.IMMEDIATE).build(),
                    )
                }
            }.addOnFailureListener { e ->
                // Expected for non-Play installs (APK from GitHub, .debug build).
                updDiag("Update check unavailable: ${e.message}")
            }
    }
}

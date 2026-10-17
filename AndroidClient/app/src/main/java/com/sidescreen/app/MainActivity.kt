package com.sidescreen.app

import android.annotation.SuppressLint
import android.app.Dialog
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.graphics.drawable.ColorDrawable
import android.hardware.usb.UsbManager
import android.media.MediaFormat
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.constraintlayout.widget.ConstraintLayout
import androidx.constraintlayout.widget.ConstraintSet
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import com.google.android.material.button.MaterialButton
import com.google.android.material.button.MaterialButtonToggleGroup
import com.google.android.material.slider.Slider
import com.google.android.material.switchmaterial.SwitchMaterial
import com.sidescreen.app.databinding.ActivityMainBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import java.net.InetSocketAddress
import java.net.Socket

private fun mainDiag(msg: String) = DiagLog.log("MA", msg)

private const val MAC_APP_URL = "https://sidescreen.dev"

class MainActivity : AppCompatActivity() {
    private lateinit var wirelessController: WirelessTabController
    private lateinit var appUpdater: AppUpdater
    private val pairedHostStorage by lazy { PairedHostStorage(this) }
    private val cameraPerm by lazy { CameraPermissionManager(this) }
    private lateinit var binding: ActivityMainBinding
    private lateinit var prefs: PreferencesManager
    private var videoDecoder: VideoDecoder? = null
    private var streamClient: StreamClient? = null

    /** In-flight code-pairing attempt (issue #35); cancelled when its dialog closes. */
    private var pairingJob: Job? = null
    private var currentSurfaceHolder: SurfaceHolder? = null
    private var currentTextureSurface: Surface? = null
    private var decoderUsingTextureView = false

    // Logical desktop behind the stream, 0 when the Mac predates desktopGeometry.
    // Shown next to the stream size; never used to size the decoder.
    private var desktopWidth = 0
    private var desktopHeight = 0

    private var displayWidth = 0 // 0 = no config received yet
    private var displayHeight = 0 // 0 = no config received yet
    private var displayRotation = 0 // 0, 90, 180, 270 degrees
    private var displayFlipHorizontal = false
    private var displayFlipVertical = false
    private var wakeLock: PowerManager.WakeLock? = null
    private var pingJob: kotlinx.coroutines.Job? = null

    // For dragging stats overlay
    private var isDraggingOverlay = false
    private var overlayDx = 0f
    private var overlayDy = 0f

    // Input prediction for low-latency gaming (UI thread only)
    private val inputPredictor = InputPredictor()

    /** False after a DOWN outside the picture: the rest of that gesture is not sent. */
    private var touchGestureActive = false

    // Presentation geometry → type 15, and fold posture → tabletop layout; live only during a session.
    private lateinit var panelWatcher: PanelWatcher
    private lateinit var postureController: FoldPostureController
    private var postureJob: Job? = null
    private var posture: Posture = Posture.Flat

    /** Last capabilities measured on the main thread; read by StreamClient's connect sequence on IO. */
    @Volatile private var latestCapabilities: ClientCapabilities? = null

    /** Camera cutout insets of the window, applied as video margins in [CutoutMode.AVOID]. */
    private var cutoutInsets: Insets = Insets.NONE

    // Latency overlay. Timeline written on the socket thread, stats on the decoder thread.
    private val frameTimeline = FrameTimeline()
    private val e2eRenderedStats = LatencyStats(120)
    private val e2eDecodedStats = LatencyStats(120)
    private val decodeStats = LatencyStats(120)

    @Volatile private var pingRttMs = -1.0

    @Volatile private var lastFrameRecvNs = 0L
    private var lastRenderedTotal = 0L
    private var lastDecodedTotal = 0L
    private var overlayLogTicks = 0
    private val latencyHandler = Handler(Looper.getMainLooper())
    private val latencyOverlayRunnable =
        object : Runnable {
            override fun run() {
                updateLatencyOverlay()
                latencyHandler.postDelayed(this, LATENCY_OVERLAY_INTERVAL_MS)
            }
        }

    // Checklist status handler
    private val checklistHandler = Handler(Looper.getMainLooper())
    private var checklistRunnable: Runnable? = null
    private var isConnected = false // Track connection state to prevent checklist conflicts

    // Demo mode: plays a bundled clip so the app can be tried without a Mac
    private var demoPlayer: DemoPlayer? = null
    private var demoActive = false
    private var demoTouchHintShown = false

    /** True while video is on screen — a real session or the demo. Drives the streaming chrome. */
    private val isStreamingUi get() = isConnected || demoActive

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        DiagLog.init(applicationContext)
        prefs = PreferencesManager(this)

        // Allow rotation based on device sensor when not connected
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR

        // Keep screen on
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Edge-to-edge on every edge, cutout included: the safe area is applied as video margins
        // (see applyVideoMargins) according to the user's cutout mode, not by the window manager.
        window.attributes.layoutInDisplayCutoutMode =
            WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        appUpdater = AppUpdater(this)
        panelWatcher = PanelWatcher(this) { prefs.cutoutMode }
        postureController = FoldPostureController(this)
        setupWindowInsets()
        // Warm the Main10 probe (a MediaCodecList walk) off the main thread before the first advert.
        lifecycleScope.launch(Dispatchers.IO) { CodecCapabilities.hevcMain10Support() }

        // Apply fullscreen mode immediately
        enableFullscreenMode()

        // Enable performance mode for gaming (after binding is initialized)
        enablePerformanceMode()

        setupSurface()
        setupUI()
        setupDraggableOverlay()
        setupSettingsButton()
        restoreOverlayPosition()
        restoreSettingsButtonPosition()
        startChecklistUpdates()
        setupModeToggle()
        setupWirelessController()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        panelWatcher.notifyConfigurationChanged()
    }

    /**
     * Gesture-navigation and system-bar insets never shrink the video (the bars are hidden while
     * streaming); only the camera cutout does, and only in [CutoutMode.AVOID].
     */
    private fun setupWindowInsets() {
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { _, insets ->
            cutoutInsets = insets.getInsetsIgnoringVisibility(WindowInsetsCompat.Type.displayCutout())
            applyVideoMargins()
            panelWatcher.notifyInsetsChanged()
            insets
        }
    }

    /** Video margins: cutout insets in AVOID (0 in FILL), plus the lower half in tabletop posture. */
    private fun applyVideoMargins() {
        val avoid = prefs.cutoutMode == CutoutMode.AVOID
        val left = if (avoid) cutoutInsets.left else 0
        val top = if (avoid) cutoutInsets.top else 0
        val right = if (avoid) cutoutInsets.right else 0
        var bottom = if (avoid) cutoutInsets.bottom else 0
        val rootHeight = binding.root.height
        val p = posture
        if (p is Posture.Tabletop && isStreamingUi && p.hingeTopPx in 1 until rootHeight) {
            bottom = maxOf(bottom, rootHeight - p.hingeTopPx)
        }
        for (v in arrayOf(binding.surfaceView, binding.textureView)) {
            val lp = v.layoutParams as ViewGroup.MarginLayoutParams
            if (lp.leftMargin != left || lp.topMargin != top || lp.rightMargin != right || lp.bottomMargin != bottom) {
                lp.setMargins(left, top, right, bottom)
                v.layoutParams = lp
            }
        }
    }

    /** Session start (main thread): measure the first advert, follow geometry and posture changes. */
    private fun startSessionObservers() {
        latestCapabilities = panelWatcher.current()?.toCapabilities(CodecCapabilities.hevcMain10Support())
        panelWatcher.start { geometry ->
            val caps = geometry.toCapabilities(CodecCapabilities.hevcMain10Support())
            latestCapabilities = caps
            mainDiag("Presentation geometry ${geometry.width}x${geometry.height}")
            streamClient?.advertiseCapabilities(caps)
        }
        postureJob?.cancel()
        // Posture changes only re-lay the video out: re-advertising would re-mode the host
        // (a picture gap) every time a foldable is opened a little further.
        postureJob = postureController.observe(lifecycleScope) { onPosture(it) }
    }

    private fun stopSessionObservers() {
        panelWatcher.stop()
        postureJob?.cancel()
        postureJob = null
        if (posture != Posture.Flat) onPosture(Posture.Flat)
    }

    private fun onPosture(newPosture: Posture) {
        mainDiag("Posture: $newPosture")
        posture = newPosture
        applyVideoMargins()
        applyPostureControls()
    }

    /** Tabletop: settings button and stats overlay docked in the lower half, below the hinge. */
    private fun applyPostureControls() {
        val p = posture
        if (p is Posture.Tabletop && isStreamingUi) {
            updateSettingsButtonPosition(SETTINGS_POSITION_BOTTOM_CENTER)
            val overlay = binding.statusBar
            overlay.post {
                val margin = 16 * resources.displayMetrics.density
                overlay.x = margin
                overlay.y = (p.hingeTopPx + margin).coerceAtMost(binding.root.height - overlay.height.toFloat())
            }
        } else {
            restoreSettingsButtonPosition()
            restoreOverlayXY()
        }
    }

    private fun setupModeToggle() {
        // Restore previous mode and reflect in toggle.
        val saved = prefs.connectionMode
        binding.modeToggleGroup.check(if (saved == ConnectionMode.WIRELESS) R.id.modeWireless else R.id.modeUSB)
        applyModeVisibility(saved)

        binding.modeToggleGroup.addOnButtonCheckedListener { _, checkedId, isChecked ->
            if (!isChecked) return@addOnButtonCheckedListener
            val mode = if (checkedId == R.id.modeWireless) ConnectionMode.WIRELESS else ConnectionMode.USB
            prefs.connectionMode = mode
            applyModeVisibility(mode)
            if (mode == ConnectionMode.WIRELESS) {
                wirelessController.show()
            }
        }
    }

    private fun applyModeVisibility(mode: ConnectionMode) {
        binding.usbModeContent.visibility = if (mode == ConnectionMode.USB) View.VISIBLE else View.GONE
        binding.wirelessModeContent.visibility = if (mode == ConnectionMode.WIRELESS) View.VISIBLE else View.GONE
        // USB checklist polls 127.0.0.1:port every 2s via adb-reverse to verify Mac
        // server reachability. While in Wireless mode that probe creates loopback
        // connections that fight the wireless session for the Mac's single client
        // slot — kicking the wireless client off seconds after it auths. Pause
        // checklist updates whenever Wireless is the active tab.
        if (mode == ConnectionMode.WIRELESS) {
            stopChecklistUpdates()
        } else {
            startChecklistUpdates()
        }
    }

    private fun setupWirelessController() {
        wirelessController =
            WirelessTabController(
                activity = this,
                views =
                    WirelessTabController.Views(
                        connecting = binding.wirelessConnecting,
                        firstTime = binding.wirelessFirstTime,
                        connected = binding.wirelessConnected,
                        pairedIdle = binding.wirelessPairedIdle,
                        repair = binding.wirelessTokenMismatch,
                        permDenied = binding.wirelessPermDenied,
                        scanButton = binding.wirelessScanButton,
                        rescanButton = binding.wirelessRescanButton,
                        enterCodeButton = binding.wirelessEnterCodeButton,
                        repairEnterCodeButton = binding.wirelessRepairEnterCodeButton,
                        permDeniedEnterCodeButton = binding.wirelessPermDeniedEnterCodeButton,
                        disconnectButton = binding.wirelessDisconnectButton,
                        forgetButton = binding.wirelessForgetButton,
                        reconnectButton = binding.wirelessReconnectButton,
                        idleForgetButton = binding.wirelessIdleForgetButton,
                        openSettingsButton = binding.wirelessOpenSettingsButton,
                        connectedMacName = binding.connectedMacName,
                        connectedMacIp = binding.connectedMacIp,
                        connectingLabel = binding.connectingLabel,
                        connectingSubtitle = binding.connectingSubtitle,
                        idleMacName = binding.idleMacName,
                        idleMacIp = binding.idleMacIp,
                        repairTitle = binding.repairTitle,
                        repairMessage = binding.repairMessage,
                    ),
                storage = pairedHostStorage,
                cameraPerm = cameraPerm,
                onConnectRequested = { host, port, token, deviceName, macName ->
                    connectWireless(host, port, token, deviceName, macName)
                },
                onCodePairRequested = { showCodePairingDialog() },
            )
        wirelessController.bind()
        binding.wirelessDisconnectButton.setOnClickListener { disconnect() }
        if (prefs.connectionMode == ConnectionMode.WIRELESS) {
            wirelessController.show()
        }
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: android.content.Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == WirelessTabController.REQ_SCAN && resultCode == RESULT_OK) {
            val url = data?.getStringExtra(QRScannerActivity.EXTRA_URL) ?: return
            wirelessController.onScanResult(url)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == WirelessTabController.REQ_CAMERA) {
            val granted = grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED
            wirelessController.onCameraPermissionResult(granted)
        }
    }

    /**
     * Enable performance mode for streaming
     * NOTE: setSustainedPerformanceMode is DISABLED - it causes thermal throttling
     * which makes the entire device laggy. Normal power management is more efficient.
     */
    private fun enablePerformanceMode() {
        try {
            // REMOVED: setSustainedPerformanceMode(true)
            // Sustained performance mode forces max CPU/GPU clocks which causes
            // thermal throttling on extended use, making the device laggy.
            // Let the SoC manage power efficiently instead.

            // Use PARTIAL_WAKE_LOCK with timeout to prevent battery drain
            // Screen is already kept on via FLAG_KEEP_SCREEN_ON
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock =
                powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "SideScreen::PerformanceMode",
                )
            // 30 minute timeout instead of infinite acquire
            wakeLock?.acquire(30 * 60 * 1000L)

            log("🎮 Performance mode ENABLED (balanced)")
        } catch (e: Exception) {
            log("⚠️ Performance mode failed: ${e.message}")
        }
    }

    /**
     * Immersive sticky: draw behind the system bars, hide them, let a swipe show them transiently.
     * The cutout mode is fixed to ALWAYS in onCreate; the safe area is applyVideoMargins' job.
     */
    private fun enableFullscreenMode() {
        // Deprecated at API 35, where edge-to-edge is the default; still required on 33-34.
        @Suppress("DEPRECATION")
        window.setDecorFitsSystemWindows(false)
        window.insetsController?.let { controller ->
            controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
            controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    /**
     * Disable fullscreen mode (when disconnected)
     */
    private fun disableFullscreenMode() {
        window.insetsController?.show(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupSurface() {
        binding.surfaceView.holder.addCallback(
            object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    mainDiag("surfaceCreated")
                    log("Surface created")
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) {
                    mainDiag("surfaceChanged: ${width}x$height")
                    log("Surface changed: ${width}x$height")
                    currentSurfaceHolder = holder
                    initializeDecoderForCurrentSurface()
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    mainDiag("surfaceDestroyed")
                    log("Surface destroyed")
                    if (!decoderUsingTextureView) {
                        videoDecoder?.release()
                        videoDecoder = null
                    }
                    currentSurfaceHolder = null
                }
            },
        )

        binding.textureView.surfaceTextureListener =
            object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(
                    surface: SurfaceTexture,
                    width: Int,
                    height: Int,
                ) {
                    mainDiag("textureAvailable: ${width}x$height")
                    currentTextureSurface = Surface(surface)
                    initializeDecoderForCurrentSurface()
                }

                override fun onSurfaceTextureSizeChanged(
                    surface: SurfaceTexture,
                    width: Int,
                    height: Int,
                ) {
                    mainDiag("textureSizeChanged: ${width}x$height")
                    applyTextureTransform()
                }

                override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                    mainDiag("textureDestroyed")
                    if (decoderUsingTextureView) {
                        videoDecoder?.release()
                        videoDecoder = null
                    }
                    currentTextureSurface?.release()
                    currentTextureSurface = null
                    return true
                }

                override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
            }

        if (binding.textureView.isAvailable && currentTextureSurface == null) {
            binding.textureView.surfaceTexture?.let { currentTextureSurface = Surface(it) }
        }

        binding.surfaceView.setOnTouchListener { view, event ->
            if (demoActive) showDemoTouchHint(event) else handleTouch(view, event)
            true
        }
        binding.textureView.setOnTouchListener { view, event ->
            if (demoActive) showDemoTouchHint(event) else handleTouch(view, event)
            true
        }
    }

    private fun setupUI() {
        binding.connectButton.setOnClickListener {
            var host =
                binding.hostInput.text
                    .toString()
                    .ifEmpty { "127.0.0.1" }
            val port =
                binding.portInput.text
                    .toString()
                    .toIntOrNull() ?: 54321

            // Convert localhost to 127.0.0.1 for better Android compatibility
            if (host.equals("localhost", ignoreCase = true)) {
                host = "127.0.0.1"
            }

            // Validate input
            if (host.isBlank()) {
                showError("Please enter a host address")
                return@setOnClickListener
            }

            updateStatus("Connecting...")
            connect(host, port)
        }

        binding.disconnectButton.setOnClickListener {
            disconnect()
        }

        // Advanced settings toggle
        var advancedVisible = false
        binding.showAdvanced.setOnClickListener {
            advancedVisible = !advancedVisible
            binding.advancedSettings.visibility = if (advancedVisible) View.VISIBLE else View.GONE
            binding.showAdvanced.text = if (advancedVisible) "Hide Advanced Settings" else "Advanced Settings"
        }

        binding.demoButton.setOnClickListener { startDemo() }
        binding.watchVideoButton.setOnClickListener { showHowItWorksVideo() }
        binding.getMacAppLink.setOnClickListener {
            try {
                startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(MAC_APP_URL)))
            } catch (_: Exception) {
                showError("Open $MAC_APP_URL in a browser to download the Mac app.")
            }
        }

        // Initial status
        updateStatus("Ready to connect")
    }

    // ==================== Demo Mode ====================

    private fun startDemo() {
        if (demoActive || isConnected) return
        val player =
            try {
                DemoPlayer(applicationContext) { videoDecoder }
            } catch (e: Exception) {
                mainDiag("Demo load failed: ${e.message}")
                showError("Could not start the demo: ${e.message}")
                return
            }
        mainDiag("Demo started")
        demoActive = true
        demoTouchHintShown = false
        // Cancel any in-flight connection attempt (USB connect or wireless
        // auto-reconnect) so its callbacks can't feed real frames into the demo
        // decoder or flip the UI to "connected" mid-demo.
        streamClient?.disconnect()
        streamClient = null
        videoDecoder?.release()
        videoDecoder = null

        displayWidth = DemoPlayer.WIDTH
        displayHeight = DemoPlayer.HEIGHT
        desktopWidth = 0
        desktopHeight = 0
        displayRotation = 0
        displayFlipHorizontal = false
        displayFlipVertical = false

        binding.settingsPanel.visibility = View.GONE
        applySettingsButtonVisibility()
        restoreSettingsButtonPosition()
        enableFullscreenMode()
        applyRotation(0, false, false)
        // The clip is a real 16:10 extended display: letterbox it instead of stretching
        // UI text on phones (a real session sizes the Mac display to the tablet).
        setSurfaceAspect("${DemoPlayer.WIDTH}:${DemoPlayer.HEIGHT}")
        updateResolutionOverlay()
        binding.resolutionText.append(" (demo)")
        binding.latencyLabel.text = "LATENCY"
        binding.latencyText.text = "—"
        updateOverlayVisibility(prefs.showStatsOverlay)
        initializeDecoderForCurrentSurface()

        player.onStats = { fps, mbps ->
            runOnUiThread {
                binding.fpsText.text = String.format("%.1f", fps)
                binding.bitrateText.text = String.format("%.1f Mbps", mbps)
            }
        }
        demoPlayer = player
        player.start()
        android.widget.Toast
            .makeText(this, "Demo mode — open Settings (⚙) or press Back to exit", android.widget.Toast.LENGTH_LONG)
            .show()
    }

    private fun stopDemo() {
        if (!demoActive) return
        mainDiag("Demo stopped")
        demoPlayer?.stop()
        demoPlayer = null
        demoActive = false
        videoDecoder?.release()
        videoDecoder = null
        displayWidth = 0
        displayHeight = 0

        binding.settingsButton.visibility = View.GONE
        binding.statusBar.visibility = View.GONE
        binding.settingsPanel.visibility = View.VISIBLE
        setSurfaceAspect(null)
        // Recreate the surface so the last demo frame doesn't linger behind the panel
        binding.surfaceView.visibility = View.GONE
        binding.surfaceView.post { binding.surfaceView.visibility = View.VISIBLE }
        disableFullscreenMode()
        resetOrientationToSensor()
    }

    /**
     * Letterboxes the video views to the stream's aspect inside their margins, so the picture fills
     * exactly StreamLayout.fitRect of the available area (what touch mapping assumes). Null = fill.
     */
    private fun setSurfaceAspect(ratio: String?) {
        for (v in arrayOf(binding.surfaceView, binding.textureView)) {
            val params = v.layoutParams as ConstraintLayout.LayoutParams
            if (params.dimensionRatio == ratio) continue
            params.dimensionRatio = ratio
            v.layoutParams = params
        }
    }

    /** Plays the bundled recording of a real Mac + phone session, looping, full screen. */
    private fun showHowItWorksVideo() {
        val dialog = Dialog(this, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
        dialog.setContentView(R.layout.dialog_how_it_works)
        val video = dialog.findViewById<android.widget.VideoView>(R.id.howItWorksVideo)
        video.setVideoURI(android.net.Uri.parse("android.resource://$packageName/${R.raw.how_it_works}"))
        video.setOnPreparedListener { player ->
            player.isLooping = true
            video.start()
        }
        dialog.findViewById<View>(R.id.closeVideoButton).setOnClickListener { dialog.dismiss() }
        dialog.setOnDismissListener { video.stopPlayback() }
        dialog.show()
    }

    /** Touch has nothing to control in demo mode — say what it would do instead. */
    private fun showDemoTouchHint(event: MotionEvent) {
        if (event.actionMasked != MotionEvent.ACTION_UP || demoTouchHintShown) return
        demoTouchHintShown = true
        android.widget.Toast
            .makeText(
                this,
                "Demo mode — when connected, touching here clicks, drags and scrolls on your Mac.",
                android.widget.Toast.LENGTH_LONG,
            ).show()
    }

    private fun showError(message: String) {
        runOnUiThread {
            android.app.AlertDialog
                .Builder(this)
                .setTitle("Connection Error")
                .setMessage(message)
                .setPositiveButton("OK", null)
                .show()
        }
    }

    private fun updateStatus(status: String) {
        runOnUiThread {
            binding.statusText.text = status
        }
    }

    @SuppressLint("ClickableViewAccessibility", "InflateParams")
    private fun setupDraggableOverlay() {
        binding.statusBar.setOnTouchListener { view, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    isDraggingOverlay = true
                    overlayDx = view.x - event.rawX
                    overlayDy = view.y - event.rawY
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    if (isDraggingOverlay) {
                        // Calculate new position
                        var newX = event.rawX + overlayDx
                        var newY = event.rawY + overlayDy

                        // Get screen bounds
                        val parent = view.parent as View
                        val maxX = parent.width - view.width.toFloat()
                        val maxY = parent.height - view.height.toFloat()

                        // Constrain to screen bounds
                        newX = newX.coerceIn(0f, maxX)
                        newY = newY.coerceIn(0f, maxY)

                        view
                            .animate()
                            .x(newX)
                            .y(newY)
                            .setDuration(0)
                            .start()
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (isDraggingOverlay) {
                        // Save position
                        prefs.overlayX = view.x
                        prefs.overlayY = view.y
                        isDraggingOverlay = false
                    }
                    true
                }

                else -> {
                    false
                }
            }
        }
    }

    private fun restoreOverlayPosition() {
        val x = prefs.overlayX
        val y = prefs.overlayY

        if (x >= 0 && y >= 0) {
            binding.statusBar.post {
                binding.statusBar.x = x
                binding.statusBar.y = y
            }
        }

        // Apply opacity to both overlay and settings button
        val opacity = prefs.overlayOpacity
        updateOverlayOpacity(opacity)
        updateSettingsButtonOpacity(opacity)

        // Apply visibility
        updateOverlayVisibility(prefs.showStatsOverlay)
    }

    private fun updateOverlayOpacity(opacity: Float) {
        binding.statusBar.alpha = opacity
    }

    private fun updateOverlayVisibility(show: Boolean) {
        if ((streamClient != null || demoActive) && show) {
            binding.statusBar.visibility = View.VISIBLE
            // Restore position when showing (docked below the hinge in tabletop)
            if (posture is Posture.Tabletop) applyPostureControls() else restoreOverlayXY()
        } else {
            binding.statusBar.visibility = View.GONE
        }
    }

    /** The user's dragged overlay position, or the layout default when none is saved. */
    private fun restoreOverlayXY() {
        val x = prefs.overlayX
        val y = prefs.overlayY
        binding.statusBar.post {
            binding.statusBar.translationX = 0f
            binding.statusBar.translationY = 0f
            if (x >= 0 && y >= 0) {
                binding.statusBar.x = x
                binding.statusBar.y = y
            }
        }
    }

    /** Orientation and cutout toggles → prefs → re-applied live; geometry changes re-advertise via the watcher. */
    private fun bindDisplayModeToggles(view: View) {
        val orientationGroup = view.findViewById<MaterialButtonToggleGroup>(R.id.orientationModeGroup)
        val cutoutGroup = view.findViewById<MaterialButtonToggleGroup>(R.id.cutoutModeGroup)
        orientationGroup.check(
            when (prefs.orientationMode) {
                OrientationMode.AUTO -> R.id.orientationAuto
                OrientationMode.PORTRAIT -> R.id.orientationPortrait
                OrientationMode.LANDSCAPE -> R.id.orientationLandscape
            },
        )
        cutoutGroup.check(if (prefs.cutoutMode == CutoutMode.AVOID) R.id.cutoutAvoid else R.id.cutoutFill)

        orientationGroup.addOnButtonCheckedListener { _, checkedId, isChecked ->
            if (!isChecked) return@addOnButtonCheckedListener
            val mode =
                when (checkedId) {
                    R.id.orientationPortrait -> OrientationMode.PORTRAIT
                    R.id.orientationLandscape -> OrientationMode.LANDSCAPE
                    else -> OrientationMode.AUTO
                }
            if (mode == prefs.orientationMode) return@addOnButtonCheckedListener
            prefs.orientationMode = mode
            applyClientOrientation()
        }
        cutoutGroup.addOnButtonCheckedListener { _, checkedId, isChecked ->
            if (!isChecked) return@addOnButtonCheckedListener
            val mode = if (checkedId == R.id.cutoutAvoid) CutoutMode.AVOID else CutoutMode.FILL
            if (mode == prefs.cutoutMode) return@addOnButtonCheckedListener
            prefs.cutoutMode = mode
            applyVideoMargins()
            panelWatcher.notifyInsetsChanged()
        }
    }

    /** Applies the user's orientation mode, but only when this phone owns orientation (host matches the panel). */
    private fun applyClientOrientation() {
        if (isConnected && streamClient?.streamFormat?.hostMatchesPanel == true) {
            requestedOrientation = StreamLayout.orientationFor(prefs.orientationMode)
        }
    }

    @SuppressLint("InflateParams", "SetTextI18n")
    private fun showSettingsDialog() {
        val dialog = Dialog(this)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        dialog.setContentView(R.layout.dialog_settings)
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))

        val view = dialog.findViewById<View>(android.R.id.content)
        val showStatsSwitch = view.findViewById<SwitchMaterial>(R.id.showStatsSwitch)
        val hideSettingsSwitch = view.findViewById<SwitchMaterial>(R.id.hideSettingsSwitch)
        val opacitySlider = view.findViewById<Slider>(R.id.opacitySlider)
        val opacityValue = view.findViewById<TextView>(R.id.opacityValue)
        val resetButton = view.findViewById<View>(R.id.resetPositionButton)
        val resetSettingsBtn = view.findViewById<View>(R.id.resetSettingsButton)
        val disconnectButton = view.findViewById<View>(R.id.disconnectSettingsButton)
        val closeButton = view.findViewById<View>(R.id.closeButton)

        // Only show Disconnect when actually streaming. Otherwise the button is
        // a no-op and confuses users into clicking it twice.
        disconnectButton.visibility = if (isStreamingUi) View.VISIBLE else View.GONE
        if (demoActive) (disconnectButton as TextView).text = "Exit demo"

        // Position buttons (8 directions)
        val cornerTopLeft = view.findViewById<MaterialButton>(R.id.cornerTopLeft)
        val cornerTopRight = view.findViewById<MaterialButton>(R.id.cornerTopRight)
        val cornerBottomLeft = view.findViewById<MaterialButton>(R.id.cornerBottomLeft)
        val cornerBottomRight = view.findViewById<MaterialButton>(R.id.cornerBottomRight)
        val positionTopCenter = view.findViewById<MaterialButton>(R.id.positionTopCenter)
        val positionBottomCenter = view.findViewById<MaterialButton>(R.id.positionBottomCenter)
        val positionCenterLeft = view.findViewById<MaterialButton>(R.id.positionCenterLeft)
        val positionCenterRight = view.findViewById<MaterialButton>(R.id.positionCenterRight)

        // Load current settings
        showStatsSwitch.isChecked = prefs.showStatsOverlay
        hideSettingsSwitch.isChecked = prefs.hideSettingsButton
        opacitySlider.value = prefs.overlayOpacity
        opacityValue.text = "${(prefs.overlayOpacity * 100).toInt()}%"
        bindDisplayModeToggles(view)

        // Highlight current position selection (8 positions)
        // 0=BottomRight, 1=BottomLeft, 2=TopRight, 3=TopLeft
        // 4=TopCenter, 5=BottomCenter, 6=CenterLeft, 7=CenterRight
        fun updatePositionSelection(selectedPosition: Int) {
            val buttons =
                listOf(
                    cornerBottomRight,
                    cornerBottomLeft,
                    cornerTopRight,
                    cornerTopLeft,
                    positionTopCenter,
                    positionBottomCenter,
                    positionCenterLeft,
                    positionCenterRight,
                )
            buttons.forEachIndexed { index, button ->
                if (index == selectedPosition) {
                    button.backgroundTintList =
                        android.content.res.ColorStateList
                            .valueOf(0x3310B981)
                    button.strokeColor =
                        android.content.res.ColorStateList
                            .valueOf(0xFF10B981.toInt())
                } else {
                    button.backgroundTintList = null
                    button.strokeColor =
                        android.content.res.ColorStateList
                            .valueOf(0x33FFFFFF)
                }
            }
        }
        updatePositionSelection(prefs.settingsButtonCorner)

        // Setup listeners
        showStatsSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.showStatsOverlay = isChecked
            updateOverlayVisibility(isChecked)
        }

        hideSettingsSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.hideSettingsButton = isChecked
            if (isStreamingUi) {
                applySettingsButtonVisibility()
            }
            if (isChecked) {
                android.widget.Toast
                    .makeText(
                        this,
                        "Settings icon hidden — use the back gesture to reveal it",
                        android.widget.Toast.LENGTH_LONG,
                    ).show()
            }
        }

        opacitySlider.addOnChangeListener { _, value, _ ->
            prefs.overlayOpacity = value
            updateOverlayOpacity(value)
            updateSettingsButtonOpacity(value)
            opacityValue.text = "${(value * 100).toInt()}%"
        }

        resetButton.setOnClickListener {
            prefs.overlayX = -1f
            prefs.overlayY = -1f
            // Use displayMetrics for reliable positioning
            val dm = resources.displayMetrics
            binding.statusBar
                .animate()
                .x(dm.widthPixels - binding.statusBar.width - 48f)
                .y(48f)
                .setDuration(300)
                .start()
        }

        // Position button listeners (8 directions)
        cornerBottomRight.setOnClickListener {
            prefs.settingsButtonCorner = 0
            updatePositionSelection(0)
            updateSettingsButtonPosition(0)
        }

        cornerBottomLeft.setOnClickListener {
            prefs.settingsButtonCorner = 1
            updatePositionSelection(1)
            updateSettingsButtonPosition(1)
        }

        cornerTopRight.setOnClickListener {
            prefs.settingsButtonCorner = 2
            updatePositionSelection(2)
            updateSettingsButtonPosition(2)
        }

        cornerTopLeft.setOnClickListener {
            prefs.settingsButtonCorner = 3
            updatePositionSelection(3)
            updateSettingsButtonPosition(3)
        }

        positionTopCenter.setOnClickListener {
            prefs.settingsButtonCorner = 4
            updatePositionSelection(4)
            updateSettingsButtonPosition(4)
        }

        positionBottomCenter.setOnClickListener {
            prefs.settingsButtonCorner = 5
            updatePositionSelection(5)
            updateSettingsButtonPosition(5)
        }

        positionCenterLeft.setOnClickListener {
            prefs.settingsButtonCorner = 6
            updatePositionSelection(6)
            updateSettingsButtonPosition(6)
        }

        positionCenterRight.setOnClickListener {
            prefs.settingsButtonCorner = 7
            updatePositionSelection(7)
            updateSettingsButtonPosition(7)
        }

        resetSettingsBtn.setOnClickListener {
            prefs.settingsButtonCorner = 0
            updatePositionSelection(0)
            updateSettingsButtonPosition(0)
        }

        disconnectButton.setOnClickListener {
            dialog.dismiss()
            if (demoActive) stopDemo() else disconnect()
        }

        closeButton.setOnClickListener {
            dialog.dismiss()
        }

        dialog.show()

        // Cap dialog height to 85% of screen so content scrolls on smaller screens / landscape
        dialog.window?.let { win ->
            val dm = resources.displayMetrics
            val maxW = minOf((dm.widthPixels * 0.94).toInt(), (520 * dm.density).toInt())
            val maxH = (dm.heightPixels * 0.88).toInt()
            win.setLayout(maxW, maxH)
        }
    }

    private fun updateSettingsButtonOpacity(opacity: Float) {
        binding.settingsButton.alpha = opacity
    }

    private fun setupSettingsButton() {
        // Simple click to show settings dialog
        // Position can be changed via corner buttons in settings
        binding.settingsButton.setOnClickListener {
            showSettingsDialog()
        }

        // Escape hatch for the hidden icon: the back gesture briefly reveals it
        // instead of leaving the app. Back is not forwarded to the Mac, so this
        // cannot conflict with streamed touch input.
        onBackPressedDispatcher.addCallback(
            this,
            object : androidx.activity.OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    if (isStreamingUi && prefs.hideSettingsButton &&
                        binding.settingsButton.visibility != View.VISIBLE
                    ) {
                        revealSettingsButtonTemporarily()
                    } else if (demoActive) {
                        stopDemo()
                    } else {
                        isEnabled = false
                        onBackPressedDispatcher.onBackPressed()
                        isEnabled = true
                    }
                }
            },
        )
    }

    /** Streaming-time visibility of the settings icon, honoring the hide preference. */
    private fun applySettingsButtonVisibility() {
        binding.settingsButton.visibility =
            if (prefs.hideSettingsButton) View.GONE else View.VISIBLE
    }

    private val revealHandler = Handler(Looper.getMainLooper())
    private val hideSettingsButtonRunnable =
        Runnable {
            if (isStreamingUi && prefs.hideSettingsButton) {
                binding.settingsButton.visibility = View.GONE
            }
        }

    private fun revealSettingsButtonTemporarily() {
        binding.settingsButton.visibility = View.VISIBLE
        revealHandler.removeCallbacks(hideSettingsButtonRunnable)
        revealHandler.postDelayed(hideSettingsButtonRunnable, 5_000L)
    }

    private fun restoreSettingsButtonPosition() {
        updateSettingsButtonPosition(prefs.settingsButtonCorner)
    }

    /**
     * Use ConstraintSet to position settings button - most reliable method
     * Works correctly with orientation changes
     * Supports 8 positions: 4 corners + 4 edges
     */
    private fun updateSettingsButtonPosition(position: Int) {
        val constraintLayout = binding.root as ConstraintLayout
        val constraintSet = ConstraintSet()
        constraintSet.clone(constraintLayout)

        val buttonId = binding.settingsButton.id
        val marginDp = (24 * resources.displayMetrics.density).toInt()

        // Clear all constraints first
        constraintSet.clear(buttonId, ConstraintSet.TOP)
        constraintSet.clear(buttonId, ConstraintSet.BOTTOM)
        constraintSet.clear(buttonId, ConstraintSet.START)
        constraintSet.clear(buttonId, ConstraintSet.END)

        when (position) {
            0 -> { // Bottom Right (default)
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }

            1 -> { // Bottom Left
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.START,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.START,
                    marginDp,
                )
            }

            2 -> { // Top Right
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, marginDp)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }

            3 -> { // Top Left
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, marginDp)
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.START,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.START,
                    marginDp,
                )
            }

            4 -> { // Top Center
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, marginDp)
                constraintSet.connect(buttonId, ConstraintSet.START, ConstraintSet.PARENT_ID, ConstraintSet.START, 0)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, 0)
            }

            5 -> { // Bottom Center
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(buttonId, ConstraintSet.START, ConstraintSet.PARENT_ID, ConstraintSet.START, 0)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, 0)
            }

            6 -> { // Center Left
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, 0)
                constraintSet.connect(buttonId, ConstraintSet.BOTTOM, ConstraintSet.PARENT_ID, ConstraintSet.BOTTOM, 0)
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.START,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.START,
                    marginDp,
                )
            }

            7 -> { // Center Right
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, 0)
                constraintSet.connect(buttonId, ConstraintSet.BOTTOM, ConstraintSet.PARENT_ID, ConstraintSet.BOTTOM, 0)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }

            else -> { // Default to bottom right
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }
        }

        // Reset any absolute positioning that might have been set
        binding.settingsButton.translationX = 0f
        binding.settingsButton.translationY = 0f

        constraintSet.applyTo(constraintLayout)
    }

    /**
     * Display config from a new Mac always arrives AFTER codecSelected, so a
     * missing negotiation at this point proves the Mac app predates H.264
     * support — surface that instead of a silent black screen.
     */
    private fun warnIfAvcOnlyWithoutNegotiation() {
        if (!CodecCapabilities.hasHevcDecoder && streamClient?.codecNegotiated != true) {
            mainDiag("AVC-only device but Mac did not negotiate codec — Mac app too old")
            runOnUiThread {
                updateStatus("This device has no HEVC decoder. Update the SideScreen Mac app to enable H.264 support.")
            }
        }
    }

    /**
     * Recreate the decoder when the negotiated stream codec doesn't match the
     * decoder's mime. Display config and codecSelected can arrive in either
     * order on reconnect; without this, a decoder created with the default
     * HEVC mime keeps consuming the H.264 stream and never outputs a frame —
     * a permanent black screen on AVC-only devices (e.g. Unisoc tablets).
     */
    private fun onStreamCodecSelected(isHevc: Boolean) {
        val expectedMime =
            if (isHevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        runOnUiThread {
            val dec = videoDecoder
            when {
                dec == null -> {
                    mainDiag("Codec selected ($expectedMime) — initializing deferred decoder")
                    initializeDecoderForCurrentSurface()
                }
                dec.mime != expectedMime -> {
                    mainDiag("Stream codec is $expectedMime but decoder is ${dec.mime} — recreating")
                    dec.release()
                    videoDecoder = null
                    initializeDecoderForCurrentSurface()
                }
            }
        }
    }

    /**
     * Stream size first, since that is what the decoder and every other stat in this overlay
     * describe. The desktop size is appended only when it differs, so a scaled HiDPI desktop is
     * visible rather than silently standing in for the resolution actually being sent.
     */
    private fun updateResolutionOverlay() {
        if (displayWidth <= 0 || displayHeight <= 0) return
        val stream = "${displayWidth}x$displayHeight"
        val differs = desktopWidth > 0 && (desktopWidth != displayWidth || desktopHeight != displayHeight)
        binding.resolutionText.text =
            if (differs) "$stream (desktop ${desktopWidth}x$desktopHeight)" else stream
    }

    private fun shouldUseTextureView(): Boolean = displayFlipHorizontal || displayFlipVertical

    private fun activeVideoSurface(): Pair<Surface, Boolean>? {
        return if (shouldUseTextureView()) {
            currentTextureSurface?.takeIf { it.isValid }?.let { it to true }
        } else {
            currentSurfaceHolder?.surface?.takeIf { it.isValid }?.let { it to false }
        }
    }

    private fun initializeDecoderForCurrentSurface() {
        if (displayWidth <= 0 || displayHeight <= 0) {
            mainDiag("initializeDecoder skipped — no display config yet")
            return
        }
        // AVC-only device: an HEVC decoder can never decode the H.264 stream
        // the Mac will send — defer until codecSelected arrives, then
        // onStreamCodecSelected initializes with the correct mime.
        if (!demoActive && !CodecCapabilities.hasHevcDecoder && streamClient?.codecNegotiated != true) {
            mainDiag("initializeDecoder deferred — AVC-only device awaiting codec negotiation")
            return
        }

        val (surface, useTextureView) =
            activeVideoSurface() ?: run {
                val kind = if (shouldUseTextureView()) "TextureView" else "SurfaceView"
                mainDiag("initializeDecoder skipped — no valid $kind surface")
                return
            }

        if (videoDecoder != null && decoderUsingTextureView == useTextureView) {
            try {
                videoDecoder?.updateResolution(displayWidth, displayHeight)
            } catch (e: Exception) {
                // Every configure rung failed at the new size: drop the decoder instead of crashing.
                videoDecoder?.release()
                videoDecoder = null
                decoderUsingTextureView = false
                mainDiag("Decoder resize FAILED: ${e.message}")
                runOnUiThread { updateStatus("Video decoder failed: ${e.message}") }
                return
            }
            resetLatencyStats()
            if (!demoActive) applyStreamPresentation()
            return
        }

        videoDecoder?.release()
        videoDecoder = null
        decoderUsingTextureView = useTextureView

        mainDiag(
            "initializeDecoder called, surface=$surface, valid=${surface.isValid}, " +
                "res=${displayWidth}x$displayHeight, texture=$useTextureView",
        )
        try {
            val displayObj = display
            val mime =
                if (demoActive || streamClient?.streamCodecIsHevc == false) {
                    MediaFormat.MIMETYPE_VIDEO_AVC
                } else {
                    MediaFormat.MIMETYPE_VIDEO_HEVC
                }
            val format = if (demoActive) null else streamClient?.streamFormat
            val dec =
                VideoDecoder(
                    surface,
                    displayObj,
                    displayWidth,
                    displayHeight,
                    mime,
                    streamFormat = format,
                    targetFps = format?.fps?.takeIf { it > 0 } ?: DEFAULT_TARGET_FPS,
                )
            videoDecoder = dec
            dec.onFrameDecoded = { buffer ->
                streamClient?.releaseBuffer(buffer)
            }
            dec.onKeyframeRequired = { force, reason ->
                streamClient?.requestKeyframe(force = force, reason = reason)
            }
            dec.onFrameOutput = { ptsUs, nowNs -> onFrameOutput(ptsUs, nowNs) }
            dec.onFrameRendered = { ptsUs, renderNs -> onFrameRendered(ptsUs, renderNs) }
            videoDecoder?.onDecoderStalled = {
                // Black screen with live stats: tell the user why instead of
                // staying silent (issue #41). Toast renders above the (black)
                // SurfaceView; the settings panel is hidden while streaming.
                // The sustainable size, not the decoder's advertised one — that is typically far
                // above anything it can really output, which made this message actively misleading.
                val panel = PanelGeometry.of(displayObj)
                val cap =
                    panel?.let {
                        CodecCapabilities.maxStreamSize(
                            mime,
                            it.width,
                            it.height,
                            CodecCapabilities.REFERENCE_FPS,
                        )
                    }
                runOnUiThread {
                    val capText = cap?.let { " (max ~${it.first}×${it.second})" } ?: ""
                    android.widget.Toast
                        .makeText(
                            this,
                            "No video output — the stream resolution may exceed " +
                                "this tablet's decoder limit$capText. " +
                                "Lower the resolution or refresh rate, or disable HiDPI, on the Mac.",
                            android.widget.Toast.LENGTH_LONG,
                        ).show()
                }
            }
            resetLatencyStats()
            streamClient?.requestKeyframe(force = true, reason = "decoder initialized")
            if (!demoActive) applyStreamPresentation()
            log("✅ Decoder initialized ${displayWidth}x$displayHeight $mime (${displayObj?.refreshRate ?: 60f}Hz)")
        } catch (e: Exception) {
            decoderUsingTextureView = false
            mainDiag("Decoder init FAILED: ${e.message}")
            log("❌ Failed to initialize decoder: ${e.message}")
            runOnUiThread {
                updateStatus("Video decoder failed: ${e.message}")
            }
        }
    }

    /**
     * Wire up all StreamClient callbacks. Used by both USB connect() and wireless connectWireless().
     */
    private fun setupStreamClientCallbacks() {
        val client = streamClient ?: return
        client.capabilitiesProvider = { latestCapabilities }

        client.onFrameReceived = { frameData, frameSize, recvNs, isKeyframe, hostCaptureNs ->
            val dec = videoDecoder
            if (dec != null) {
                val prevRecvNs = lastFrameRecvNs
                lastFrameRecvNs = recvNs
                // Exclude isolated idle keepalive frames (>250 ms gap) from active latency stats:
                // waking the VPU from power collapse and an LTPO panel from idle refresh is not
                // representative of active streaming latency.
                val isIdleKeepalive = prevRecvNs > 0L && (recvNs - prevRecvNs) > IDLE_FRAME_GAP_NS
                if (!isIdleKeepalive) {
                    frameTimeline.record(recvNs / 1000, recvNs, hostCaptureNs)
                }
                dec.decode(frameData, frameSize, recvNs, isKeyframe)
            } else {
                client.releaseBuffer(frameData)
            }
        }

        videoDecoder?.onFrameDecoded = { buffer ->
            streamClient?.releaseBuffer(buffer)
        }

        client.onLatencyMeasured = { rttMs -> pingRttMs = rttMs }

        client.onStreamFormat = { format -> runOnUiThread { onStreamFormatChanged(format) } }

        client.onConnectionStatus = { connected ->
            runOnUiThread {
                isConnected = connected
                if (connected) {
                    updateStatus("Connected - Streaming active")
                } else {
                    updateStatus("Disconnected")
                }
                binding.connectButton.isEnabled = !connected
                binding.disconnectButton.isEnabled = connected
                binding.statusIndicator.setBackgroundResource(
                    if (connected) R.drawable.status_indicator_green else R.drawable.status_indicator_red,
                )
                if (connected) {
                    startPingTimer()
                    startLatencyOverlay()
                    applyStreamPresentation()
                    stopChecklistUpdates()
                    enableFullscreenMode()
                    binding.settingsPanel.visibility = View.GONE
                    applySettingsButtonVisibility()
                    restoreSettingsButtonPosition()
                    updateOverlayVisibility(prefs.showStatsOverlay)
                    applyVideoMargins()
                    applyPostureControls()
                    // For wireless mode, transition controller to CONNECTED here —
                    // not in MainActivity.connectWireless's coroutine after the
                    // receive loop returns (that runs AFTER disconnect, causing
                    // a stale CONNECTED transition that hides the PAIRED_IDLE UI).
                    if (prefs.connectionMode == ConnectionMode.WIRELESS) {
                        val entry = pairedHostStorage.load()
                        wirelessController.onConnectSuccess(
                            entry?.macName ?: "Mac",
                            entry?.host ?: "—",
                        )
                    }
                } else {
                    streamClient = null
                    stopPingTimer()
                    stopLatencyOverlay()
                    stopSessionObservers()
                    resetStreamPresentation()
                    setSurfaceAspect(null)
                    disableFullscreenMode()
                    resetOrientationToSensor()
                    binding.settingsPanel.visibility = View.VISIBLE
                    binding.settingsButton.visibility = View.GONE
                    binding.statusBar.visibility = View.GONE
                    val mode = prefs.connectionMode
                    val willTransition = mode == ConnectionMode.WIRELESS
                    android.util.Log.i(
                        "MainActivity",
                        "onConnectionStatus(false) — mode=$mode, willTransition=$willTransition",
                    )
                    if (mode == ConnectionMode.WIRELESS) {
                        // Don't restart checklist (it conflicts with wireless on Mac).
                        // Tell wireless controller to show the idle/reconnect UI.
                        wirelessController.onStreamDisconnected()
                    } else {
                        log("📋 Restarting checklist updates")
                        startChecklistUpdates()
                    }
                }
            }
        }

        client.onDesktopSize = { w, h ->
            desktopWidth = w
            desktopHeight = h
            runOnUiThread { updateResolutionOverlay() }
        }

        client.onCodecSelected = { isHevc -> onStreamCodecSelected(isHevc) }

        client.onDisplaySize = { width, height, rotation, flipHorizontal, flipVertical ->
            mainDiag("onDisplaySize: ${width}x$height @ $rotation°, h=$flipHorizontal, v=$flipVertical")
            warnIfAvcOnlyWithoutNegotiation()
            displayWidth = width
            displayHeight = height
            displayRotation = rotation
            displayFlipHorizontal = flipHorizontal
            displayFlipVertical = flipVertical
            runOnUiThread {
                updateResolutionOverlay()
                setSurfaceAspect("$width:$height")
                applyRotation(rotation, flipHorizontal, flipVertical)
                initializeDecoderForCurrentSurface()
            }
            log("Display: ${width}x$height @ $rotation°")
        }

        client.onStats = { fps, mbps ->
            runOnUiThread {
                binding.fpsText.text = String.format("%.1f", fps)
                binding.bitrateText.text = String.format("%.1f Mbps", mbps)
            }
        }
    }

    /**
     * Type 16 (main thread). With a panel-matching host this phone owns orientation, so the user's
     * mode applies and the type-1 rotation is ignored from here on (see applyRotation).
     */
    private fun onStreamFormatChanged(format: StreamFormat) {
        if (streamClient == null) return
        if (format.hostMatchesPanel) {
            requestedOrientation = StreamLayout.orientationFor(prefs.orientationMode)
        }
        videoDecoder?.updateStreamFormat(format)
        applyStreamPresentation()
    }

    /** Window colour mode and refresh-rate pin for the current stream (main thread, live session only). */
    private fun applyStreamPresentation() {
        if (!isConnected) return
        val format = streamClient?.streamFormat
        val hdr = format?.isHdr == true && videoDecoder?.isHdrConfigured == true
        val colorMode = if (hdr) ActivityInfo.COLOR_MODE_HDR else ActivityInfo.COLOR_MODE_DEFAULT
        if (window.colorMode != colorMode) {
            window.colorMode = colorMode
            mainDiag("Window colour mode ${if (hdr) "HDR" else "default"}")
        }
        pinRefreshRate(format?.fps?.takeIf { it > 0 })
    }

    /**
     * Pins the panel's fastest mode at its current resolution (an LTPO panel would otherwise idle
     * down and add a frame of latency) and tells the compositor the video's real cadence.
     * Mode sizes are compared orientation-independently: some panels list modes in their native
     * portrait size while the device is used in landscape.
     * `preferredMinDisplayRefreshRate` is not public SDK API (@hide in android-36), so the mode id
     * plus `preferredRefreshRate` carry the request.
     */
    private fun pinRefreshRate(streamFps: Int?) {
        val d = display ?: return
        val current = d.mode
        val longSide = maxOf(current.physicalWidth, current.physicalHeight)
        val shortSide = minOf(current.physicalWidth, current.physicalHeight)
        val best =
            d.supportedModes
                .filter {
                    maxOf(it.physicalWidth, it.physicalHeight) == longSide &&
                        minOf(it.physicalWidth, it.physicalHeight) == shortSide
                }.maxByOrNull { it.refreshRate } ?: current
        val attrs = window.attributes
        if (attrs.preferredDisplayModeId != best.modeId || attrs.preferredRefreshRate != best.refreshRate) {
            attrs.preferredDisplayModeId = best.modeId
            attrs.preferredRefreshRate = best.refreshRate
            attrs.preferMinimalPostProcessing = true
            window.attributes = attrs
            val size = "${best.physicalWidth}x${best.physicalHeight}"
            mainDiag("Pinned display mode ${best.modeId} ($size@${best.refreshRate})")
        }
        // Always vote the panel's peak refresh rate on the video Surface so LTPO panels
        // never throttle down to 60 Hz (adding +8.33 ms VSYNC latency) on 60 fps or idle content.
        val fps = maxOf(streamFps?.toFloat() ?: 0f, best.refreshRate)
        setVideoSurfaceFrameRate(fps)
    }

    private fun setVideoSurfaceFrameRate(fps: Float) {
        val surface = activeVideoSurface()?.first ?: return
        try {
            if (fps > 0f) {
                surface.setFrameRate(
                    fps,
                    Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                    Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS,
                )
            } else {
                surface.setFrameRate(0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
            }
        } catch (e: Exception) {
            mainDiag("setFrameRate($fps) failed: ${e.message}")
        }
    }

    /** Back to the system's colour mode and refresh-rate policy once no session is shown. */
    private fun resetStreamPresentation() {
        window.colorMode = ActivityInfo.COLOR_MODE_DEFAULT
        val attrs = window.attributes
        if (attrs.preferredDisplayModeId != 0 || attrs.preferredRefreshRate != 0f) {
            attrs.preferredDisplayModeId = 0
            attrs.preferredRefreshRate = 0f
            attrs.preferMinimalPostProcessing = false
            window.attributes = attrs
        }
        setVideoSurfaceFrameRate(0f)
    }

    // ==================== Latency overlay ====================

    /** Host capture instant of the frame with this PTS in the local clock, or null when unknown. */
    private fun captureClientNs(ptsUs: Long): Long? {
        val hostNs = frameTimeline.hostCaptureNs(ptsUs)
        if (hostNs <= 0L) return null
        val clock = streamClient?.clockSync ?: return null
        if (!clock.isConfident) return null
        return clock.hostToClientNs(hostNs)
    }

    /** Decoder thread. */
    private fun onFrameOutput(
        ptsUs: Long,
        nowNs: Long,
    ) {
        val recvNs = frameTimeline.recvNs(ptsUs)
        if (recvNs != FrameTimeline.MISSING) addLatencySample(decodeStats, nowNs - recvNs)
        captureClientNs(ptsUs)?.let { addLatencySample(e2eDecodedStats, nowNs - it) }
    }

    /** Decoder thread. */
    private fun onFrameRendered(
        ptsUs: Long,
        renderNs: Long,
    ) {
        captureClientNs(ptsUs)?.let { addLatencySample(e2eRenderedStats, renderNs - it) }
    }

    /** Negative or absurd values mean a clock estimate that is still settling; they are not latency. */
    private fun addLatencySample(
        stats: LatencyStats,
        ns: Long,
    ) {
        if (ns in 0..MAX_PLAUSIBLE_LATENCY_NS) stats.add(ns)
    }

    private fun resetLatencyStats() {
        frameTimeline.clear()
        e2eRenderedStats.clear()
        e2eDecodedStats.clear()
        decodeStats.clear()
        lastFrameRecvNs = 0L
        lastRenderedTotal = 0L
        lastDecodedTotal = 0L
    }

    private fun startLatencyOverlay() {
        resetLatencyStats()
        pingRttMs = -1.0
        overlayLogTicks = 0
        binding.latencyLabel.text = "LATENCY"
        binding.latencyText.text = "--"
        latencyHandler.removeCallbacks(latencyOverlayRunnable)
        latencyHandler.postDelayed(latencyOverlayRunnable, LATENCY_OVERLAY_INTERVAL_MS)
    }

    private fun stopLatencyOverlay() {
        latencyHandler.removeCallbacks(latencyOverlayRunnable)
    }

    /**
     * "E2E p50/p95 · dec · rtt". Primary E2E is host capture → decoded (true streaming pipeline
     * completion before SurfaceFlinger's asynchronous future VSYNC scanout wait), while
     * capture → render (HWC present fence) is tracked in [e2eRenderedStats] for diagnostics.
     */
    @SuppressLint("SetTextI18n")
    private fun updateLatencyOverlay() {
        val clock = streamClient?.clockSync
        val rttMs = clock?.minRttNs?.let { it / 1e6 } ?: pingRttMs.takeIf { it >= 0 }
        val rttText = rttMs?.let { String.format("rtt %.1f", it) } ?: "rtt --"
        val decText = decodeStats.p50()?.let { String.format("dec %.1f", it / 1e6) } ?: "dec --"

        val renderedTotal = e2eRenderedStats.total
        val decodedTotal = e2eDecodedStats.total
        val renderedLive = renderedTotal > lastRenderedTotal
        val decodedLive = decodedTotal > lastDecodedTotal
        lastRenderedTotal = renderedTotal
        lastDecodedTotal = decodedTotal

        val (stats, endpoint) =
            when {
                decodedTotal > 0 && (decodedLive || !renderedLive) -> e2eDecodedStats to "capture→decode"
                renderedTotal > 0 -> e2eRenderedStats to "capture→render"
                else -> null to null
            }
        val p50 = stats?.p50()
        val p95 = stats?.p95()
        if (stats != null && p50 != null && p95 != null) {
            binding.latencyLabel.text = "E2E $endpoint (ms)"
            binding.latencyText.text =
                String.format("E2E %.1f/%.1f · %s · %s", p50 / 1e6, p95 / 1e6, decText, rttText)
            overlayLogTicks++
            if (overlayLogTicks % 4 == 0) {
                val decP50 = e2eDecodedStats.p50()?.let { it / 1e6 } ?: -1.0
                val decP95 = e2eDecodedStats.p95()?.let { it / 1e6 } ?: -1.0
                val renP50 = e2eRenderedStats.p50()?.let { it / 1e6 } ?: -1.0
                val renP95 = e2eRenderedStats.p95()?.let { it / 1e6 } ?: -1.0
                mainDiag(
                    String.format(
                        "Latency summary: capture→decode=%.1f/%.1fms, capture→render=%.1f/%.1fms, %s, %s",
                        decP50,
                        decP95,
                        renP50,
                        renP95,
                        decText,
                        rttText,
                    ),
                )
            }
        } else if (streamClient?.streamFormat?.hostSupportsClockSync == true) {
            binding.latencyLabel.text = "E2E (ms, clock syncing…)"
            binding.latencyText.text = "$decText · $rttText"
        } else {
            binding.latencyLabel.text = "RTT (ms, host has no clock sync)"
            binding.latencyText.text = "$rttText · $decText"
        }
    }

    /**
     * Code pairing (issue #35): manual host/port/code entry for tablets without
     * a camera. On success the Mac issues the real token and we connect through
     * the same path as a QR scan.
     */
    private fun showCodePairingDialog() {
        val view = layoutInflater.inflate(R.layout.dialog_code_pairing, null)
        val hostField = view.findViewById<android.widget.EditText>(R.id.codePairHost)
        val portField = view.findViewById<android.widget.EditText>(R.id.codePairPort)
        val codeField = view.findViewById<android.widget.EditText>(R.id.codePairCode)
        val errorText = view.findViewById<android.widget.TextView>(R.id.codePairError)

        // Re-pair convenience: prefill the last paired Mac so only the fresh
        // code needs typing.
        pairedHostStorage.load()?.let { cached ->
            hostField.setText(cached.host)
            portField.setText(cached.port.toString())
        }

        val dialog =
            com.google.android.material.dialog.MaterialAlertDialogBuilder(this)
                .setTitle("Pair with code")
                .setView(view)
                .setPositiveButton("Pair", null) // listener installed below so it doesn't auto-dismiss
                .setNegativeButton("Cancel", null)
                .create()

        dialog.setOnShowListener {
            val pairButton = dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE)
            pairButton.setOnClickListener {
                val host = hostField.text.toString().trim()
                val port = portField.text.toString().trim().toIntOrNull()
                val code = codeField.text.toString().filter { it.isDigit() }

                errorText.visibility = View.GONE
                when {
                    host.isEmpty() -> {
                        errorText.text = "Enter the Mac's address (shown as \"Listening\" under the QR)."
                        errorText.visibility = View.VISIBLE
                        return@setOnClickListener
                    }
                    port == null || port !in 1..65535 -> {
                        errorText.text = "Port must be between 1 and 65535."
                        errorText.visibility = View.VISIBLE
                        return@setOnClickListener
                    }
                    code.length != AuthHandshake.PAIR_CODE_LEN -> {
                        errorText.text = "The code is ${AuthHandshake.PAIR_CODE_LEN} digits."
                        errorText.visibility = View.VISIBLE
                        return@setOnClickListener
                    }
                }
                pairButton.isEnabled = false
                pairButton.text = "Pairing…"

                fun showPairError(message: String) {
                    runOnUiThread {
                        pairButton.isEnabled = true
                        pairButton.text = "Pair"
                        errorText.text = message
                        errorText.visibility = View.VISIBLE
                    }
                }

                val deviceName = WirelessTabController.defaultDeviceName()
                pairingJob =
                    lifecycleScope.launch(Dispatchers.IO) {
                        try {
                            val client = StreamClient(host, port!!, applicationContext)
                            val result = client.pairWithCode(code, deviceName)
                            // Dialog dismissed mid-flight (Cancel/back): drop the
                            // token instead of silently connecting.
                            ensureActive()
                            runOnUiThread {
                                dialog.dismiss()
                                wirelessController.onCodePairComplete(host, port, result.token, result.macName)
                            }
                        } catch (e: StreamClient.PairingError) {
                            showPairError(
                                when (e) {
                                    is StreamClient.PairingError.CodeRejected ->
                                        "Code not accepted. Codes change after each use — " +
                                            "check the Mac for the current one."
                                    is StreamClient.PairingError.HostTooOld ->
                                        "Update Side Screen on the Mac to use code pairing."
                                },
                            )
                        } catch (e: StreamClient.WirelessConnectError) {
                            showPairError(
                                when (e) {
                                    is StreamClient.WirelessConnectError.NetworkUnreachable ->
                                        "No response from $host:$port. Check both devices are " +
                                            "on the same WiFi and the Mac app is running."
                                    else -> "Connection error — try again."
                                },
                            )
                        } catch (e: kotlinx.coroutines.CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            log("Code pairing failed unexpectedly: ${e.message}")
                            showPairError("Pairing failed — try again.")
                        }
                    }
            }
        }
        dialog.setOnDismissListener {
            pairingJob?.cancel()
            pairingJob = null
        }
        dialog.show()
    }

    private fun connectWireless(
        host: String,
        port: Int,
        token: ByteArray,
        deviceName: String,
        macName: String,
    ) {
        stopDemo() // a real connection (incl. wireless auto-reconnect) takes over the decoder
        stopChecklistUpdates()
        isConnected = true
        startSessionObservers()
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                log("Connecting wirelessly to $host:$port...")
                streamClient = StreamClient(host, port, applicationContext)
                setupStreamClientCallbacks()
                streamClient?.connectWireless(token, deviceName)
            } catch (e: StreamClient.WirelessConnectError) {
                isConnected = false
                streamClient = null
                runOnUiThread {
                    stopSessionObservers()
                    wirelessController.onConnectError(e)
                }
            } catch (e: Exception) {
                isConnected = false
                streamClient = null
                log("Wireless connect failed: ${e.message}")
                runOnUiThread {
                    stopSessionObservers()
                    wirelessController.onConnectError(StreamClient.WirelessConnectError.NetworkUnreachable)
                }
            }
        }
    }

    private fun connect(
        host: String,
        port: Int,
    ) {
        stopDemo()
        stopChecklistUpdates()
        isConnected = true
        startSessionObservers()
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                log("Connecting to $host:$port...")
                streamClient = StreamClient(host, port, applicationContext)
                setupStreamClientCallbacks()
                streamClient?.connect()
            } catch (e: Exception) {
                isConnected = false
                streamClient = null
                startChecklistUpdates()
                val errorMessage =
                    when {
                        e.message?.contains("ECONNREFUSED") == true -> {
                            "Mac server is not running.\n\nPlease start Side Screen.app on your Mac first."
                        }

                        e.message?.contains("Network is unreachable") == true -> {
                            "Cannot reach Mac.\n\n" +
                                "Make sure both devices are connected via USB cable and ADB reverse is configured."
                        }

                        e.message?.contains("timeout") == true -> {
                            "Connection timeout.\n\nCheck if Mac firewall is blocking port $port."
                        }

                        else -> {
                            "Connection failed: ${e.message}\n\n" +
                                "Try:\n• Start Side Screen.app on Mac\n" +
                                "• Check USB connection\n• Run: adb reverse tcp:$port tcp:$port"
                        }
                    }
                runOnUiThread { stopSessionObservers() }
                updateStatus("Connection failed")
                showError(errorMessage)
            }
        }
    }

    private fun disconnect() {
        stopPingTimer()
        stopLatencyOverlay()
        stopSessionObservers()
        isConnected = false
        streamClient?.disconnect()
        streamClient = null
        if (prefs.connectionMode == ConnectionMode.USB) {
            startChecklistUpdates()
        }
        displayWidth = 0
        displayHeight = 0
        desktopWidth = 0
        desktopHeight = 0
        displayFlipHorizontal = false
        displayFlipVertical = false
        runOnUiThread {
            binding.textureView.visibility = View.GONE
            applyTextureTransform()
        }
        log("Disconnected")
    }

    private fun startPingTimer() {
        stopPingTimer()
        pingJob =
            lifecycleScope.launch(Dispatchers.IO) {
                while (true) {
                    kotlinx.coroutines.delay(1000) // Ping every 1 second
                    streamClient?.sendPing()
                }
            }
    }

    private fun stopPingTimer() {
        pingJob?.cancel()
        pingJob = null
    }

    private fun cleanup() {
        try {
            stopDemo()
            disconnect()
            videoDecoder?.release()
            videoDecoder = null
            currentTextureSurface?.release()
            currentTextureSurface = null

            // Release wake lock safely
            try {
                if (wakeLock?.isHeld == true) {
                    wakeLock?.release()
                }
            } catch (e: Exception) {
                // Ignore wake lock release errors
            }
            wakeLock = null
            log("🎮 Performance mode DISABLED")
        } catch (e: Exception) {
            log("⚠️ Cleanup error: ${e.message}")
        }
    }

    /**
     * Touch → host, in 0..1 coordinates of the picture: mapped through [StreamLayout.fitRect] so a
     * letterboxed picture (a rotation re-mode in flight, tabletop, an old host's fixed size) maps
     * correctly. A gesture that starts outside the picture is not sent at all; moves outside it are
     * dropped; releases and the second finger are pinned to the edge so the host never sees a
     * press without its release.
     */
    private fun handleTouch(
        view: View,
        event: MotionEvent,
    ) {
        val rect = StreamLayout.fitRect(view.width.toFloat(), view.height.toFloat(), displayWidth, displayHeight)
        val action = event.actionMasked
        if (action == MotionEvent.ACTION_DOWN) {
            touchGestureActive = StreamLayout.normalizeTouch(event.x, event.y, rect) != null
            if (touchGestureActive) inputPredictor.reset()
        }
        if (!touchGestureActive) return
        val client = streamClient ?: return
        val pointerCount = event.pointerCount.coerceAtMost(2)

        var x2 = 0f
        var y2 = 0f
        if (pointerCount >= 2) {
            val (nx2, ny2) = StreamLayout.clampTouch(event.getX(1), event.getY(1), rect)
            x2 = flipX(nx2)
            y2 = flipY(ny2)
        }

        when (action) {
            MotionEvent.ACTION_DOWN -> {
                val (x, y) = StreamLayout.clampTouch(event.x, event.y, rect)
                inputPredictor.addSample(flipX(x), flipY(y), event.eventTime * NANOS_PER_MILLI)
                client.sendTouch(flipX(x), flipY(y), 0, pointerCount, x2, y2)
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                val (x, y) = StreamLayout.clampTouch(event.x, event.y, rect)
                client.sendTouch(flipX(x), flipY(y), 0, pointerCount, x2, y2)
            }

            MotionEvent.ACTION_MOVE -> {
                val (x, y) = StreamLayout.normalizeTouch(event.x, event.y, rect) ?: return
                if (pointerCount == 1) {
                    // Batched samples since the last frame sharpen the velocity fit.
                    for (i in 0 until event.historySize) {
                        val (hx, hy) =
                            StreamLayout.normalizeTouch(event.getHistoricalX(i), event.getHistoricalY(i), rect)
                                ?: continue
                        val timeNs = event.getHistoricalEventTime(i) * NANOS_PER_MILLI
                        inputPredictor.addSample(flipX(hx), flipY(hy), timeNs)
                    }
                    inputPredictor.addSample(flipX(x), flipY(y), event.eventTime * NANOS_PER_MILLI)
                    inputPredictor.predict(predictionLeadMs())
                    client.sendTouch(inputPredictor.predictedX, inputPredictor.predictedY, 1, 1)
                } else {
                    client.sendTouch(flipX(x), flipY(y), 1, pointerCount, x2, y2)
                }
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                inputPredictor.reset()
                touchGestureActive = false
                val (x, y) = StreamLayout.clampTouch(event.x, event.y, rect)
                client.sendTouch(flipX(x), flipY(y), 2, 1)
            }

            MotionEvent.ACTION_POINTER_UP -> {
                val (x, y) = StreamLayout.clampTouch(event.x, event.y, rect)
                client.sendTouch(flipX(x), flipY(y), 2, pointerCount, x2, y2)
            }
        }
    }

    private fun flipX(x: Float) = if (displayFlipHorizontal) 1f - x else x

    private fun flipY(y: Float) = if (displayFlipVertical) 1f - y else y

    /** Prediction lead from the best RTT known: clock-sync minimum, else the ping round trip. */
    private fun predictionLeadMs(): Float {
        val rttMs = streamClient?.clockSync?.minRttNs?.let { it / 1e6 } ?: pingRttMs.takeIf { it >= 0 }
        return InputPredictor.leadMsFor(rttMs)
    }

    /**
     * Flips and the TextureView switch always apply. Orientation is set here only for a host that
     * rotates its own desktop (old host, or "match device" off); a panel-matching host leaves it
     * to the user's orientation mode (onStreamFormatChanged), so exactly one side decides.
     */
    private fun applyRotation(
        rotation: Int,
        flipHorizontal: Boolean,
        flipVertical: Boolean,
    ) {
        val hostMatchesPanel = streamClient?.streamFormat?.hostMatchesPanel == true
        if (!hostMatchesPanel) {
            requestedOrientation = StreamLayout.legacyOrientationFor(displayWidth, displayHeight, rotation)
        }

        binding.surfaceView.rotation = 0f
        binding.surfaceView.visibility = View.VISIBLE
        binding.textureView.visibility = if (flipHorizontal || flipVertical) View.VISIBLE else View.GONE
        applyTextureTransform()

        val orientation =
            if (hostMatchesPanel) {
                "follows phone (${prefs.orientationMode.name.lowercase()})"
            } else {
                when (rotation) {
                    90 -> "Portrait"
                    180 -> "Landscape (flipped)"
                    270 -> "Portrait (flipped)"
                    else -> "Landscape"
                }
            }
        log("🔄 Orientation: $orientation${if (flipHorizontal || flipVertical) " mirrored" else ""}")
    }

    private fun applyTextureTransform() {
        val view = binding.textureView
        val matrix = Matrix()
        val centerX = view.width / 2f
        val centerY = view.height / 2f
        matrix.postScale(
            if (displayFlipHorizontal) -1f else 1f,
            if (displayFlipVertical) -1f else 1f,
            centerX,
            centerY,
        )
        view.setTransform(matrix)
    }

    /**
     * Reset orientation to follow device sensor (when disconnected)
     */
    private fun resetOrientationToSensor() {
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
    }

    private fun log(message: String) {
        runOnUiThread {
            val current = binding.logText.text.toString()
            val lines = current.split("\n").takeLast(5)
            binding.logText.text = (lines + message).joinToString("\n")
        }
    }

    override fun onResume() {
        super.onResume()
        // Only nudge about updates while idle — never over a live stream or the demo.
        if (!isStreamingUi) {
            appUpdater.checkForUpdate()
            if (prefs.connectionMode == ConnectionMode.USB) {
                startChecklistUpdates()
            }
        }
    }

    override fun onPause() {
        super.onPause()
        if (!isConnected) {
            stopChecklistUpdates()
        }
    }

    override fun onDestroy() {
        stopChecklistUpdates()
        cleanup()
    }

    // ==================== Connection Checklist ====================

    private fun startChecklistUpdates() {
        // Stop any existing runnable first to prevent duplicates
        checklistRunnable?.let {
            checklistHandler.removeCallbacks(it)
        }

        checklistRunnable =
            object : Runnable {
                override fun run() {
                    updateChecklist()
                    checklistHandler.postDelayed(this, 2000) // Update every 2 seconds
                }
            }
        checklistHandler.post(checklistRunnable!!)
    }

    private fun stopChecklistUpdates() {
        checklistRunnable?.let {
            checklistHandler.removeCallbacks(it)
            checklistRunnable = null
        }
    }

    private fun updateChecklist() {
        // Skip if connecting or connected (to prevent socket conflicts and stream disruption)
        if (isConnected || streamClient != null) return

        // Check Developer Mode (if we can run this app with USB debugging, dev mode is enabled)
        val isDeveloperModeEnabled =
            Settings.Secure.getInt(
                contentResolver,
                Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
                0,
            ) == 1
        updateChecklistItem(binding.checkDeveloperMode, isDeveloperModeEnabled)

        // Check USB Debugging (ADB enabled)
        val isAdbEnabled =
            Settings.Secure.getInt(
                contentResolver,
                Settings.Global.ADB_ENABLED,
                0,
            ) == 1
        updateChecklistItem(binding.checkUsbDebugging, isAdbEnabled)

        // Check USB connected (check if any USB device is connected)
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val isUsbConnected = usbManager.deviceList.isNotEmpty() || isCharging()
        updateChecklistItem(binding.checkUsbConnected, isUsbConnected)

        // Check Mac Server (try to connect to port)
        lifecycleScope.launch(Dispatchers.IO) {
            // Double-check connection state before socket test
            if (isConnected) return@launch

            val port =
                binding.portInput.text
                    .toString()
                    .toIntOrNull() ?: 54321
            val isServerRunning = checkServerRunning("127.0.0.1", port)
            runOnUiThread {
                // Final check before updating UI
                if (isConnected) return@runOnUiThread

                updateChecklistItem(binding.checkMacServer, isServerRunning)

                // Update main status indicator based on all checklist items
                val allReady = isDeveloperModeEnabled && isAdbEnabled && isUsbConnected && isServerRunning
                updateMainStatus(allReady)
            }
        }
    }

    private fun updateMainStatus(allReady: Boolean) {
        binding.statusIndicator.setBackgroundResource(
            if (allReady) {
                R.drawable.status_indicator_green
            } else {
                R.drawable.status_indicator_red
            },
        )
        binding.statusText.text = if (allReady) "Ready to connect" else "Not ready to connect"
    }

    private fun updateChecklistItem(
        indicator: View,
        isOk: Boolean,
    ) {
        indicator.setBackgroundResource(
            if (isOk) {
                R.drawable.status_indicator_green
            } else {
                R.drawable.status_indicator_red
            },
        )
    }

    private fun isCharging(): Boolean {
        val intentFilter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        val batteryStatus = registerReceiver(null, intentFilter)
        val status = batteryStatus?.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1) ?: -1
        return status == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
            status == android.os.BatteryManager.BATTERY_STATUS_FULL
    }

    /**
     * Check if Mac server is actually running (not just ADB reverse)
     *
     * Problem: When `adb reverse tcp:8888 tcp:8888` is active, ADB daemon listens on port 8888.
     * A simple socket connect will succeed to ADB daemon, not the actual Mac server.
     *
     * Solution: After connecting, try to read data with a short timeout.
     * Mac server sends display config (type=1) immediately upon connection.
     * ADB daemon doesn't send anything, so read will timeout → false.
     */
    private fun checkServerRunning(
        host: String,
        port: Int,
    ): Boolean {
        if (isConnected || streamClient != null) return true
        var socket: Socket? = null
        return try {
            socket = Socket()
            socket.connect(InetSocketAddress(host, port), 300) // 300ms connect timeout
            socket.soTimeout = 200 // 200ms read timeout

            // Try to read - Mac server sends display config immediately
            // ADB daemon doesn't send anything, so read will timeout
            val input = socket.getInputStream()
            val firstByte = input.read() // Blocks up to soTimeout

            // If we got data (>= 0), it's the real Mac server
            // -1 means EOF (connection closed), anything else is data
            firstByte >= 0
        } catch (e: Exception) {
            // Timeout, connection refused, or other error = server not running
            false
        } finally {
            try {
                socket?.close()
            } catch (e: Exception) {
                // ignore
            }
        }
    }

    private companion object {
        const val LATENCY_OVERLAY_INTERVAL_MS = 500L

        /** Beyond this a "latency" is a clock estimate still settling, not a frame that took that long. */
        const val MAX_PLAUSIBLE_LATENCY_NS = 2_000_000_000L

        /** Frames arriving after >250 ms silence are idle keepalives, excluded from active E2E stats. */
        const val IDLE_FRAME_GAP_NS = 250_000_000L

        /** Decoder frame-rate hint when the host does not announce its fps (old host, demo). */
        const val DEFAULT_TARGET_FPS = 60
        const val NANOS_PER_MILLI = 1_000_000L

        /** updateSettingsButtonPosition index: bottom centre, the lower half in tabletop posture. */
        const val SETTINGS_POSITION_BOTTOM_CENTER = 5
    }
}

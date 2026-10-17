import Cocoa
import SwiftUI
import Combine
import ApplicationServices
import os
@preconcurrency import ScreenCaptureKit

// Debug file logger - writes to /tmp/sidescreen.log
private let logQueue = DispatchQueue(label: "com.sidescreen.log", qos: .utility)
func debugLog(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    print(message)
    logQueue.async {
        let url = URL(fileURLWithPath: "/tmp/sidescreen.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        } else if let data = line.data(using: .utf8) {
            try? data.write(to: url)
        }
    }
}

// MARK: - Gesture State Machine

enum GestureState {
    case idle
    case pending          // Touch down, waiting to determine gesture
    case scrolling        // 1-finger scroll
    case longPressReady   // Long press detected, waiting for drag or release
    case dragging         // Long press + drag (left mouse drag)
    case twoFingerScroll  // 2-finger scroll
    case pinching         // Pinch zoom
}

struct GestureThresholds {
    static let tapMaxDistance: CGFloat = 15
    static let tapMaxTime: UInt64 = 250_000_000       // 250ms
    static let doubleTapMaxTime: UInt64 = 400_000_000  // 400ms
    static let doubleTapMaxDistance: CGFloat = 20
    static let longPressTime: UInt64 = 500_000_000     // 500ms
    static let scrollSensitivity: CGFloat = 1.2
    static let pinchMinDistance: CGFloat = 20
    static let minTouchInterval: UInt64 = 3_000_000    // ~333Hz; finer than any client touch rate
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var streamingServer: StreamingServer?
    var screenCapture: ScreenCapture?
    var virtualDisplayManager: VirtualDisplayManager?
    var settings = DisplaySettings()
    var settingsWindow: SettingsWindowController?
    var statusItem: NSStatusItem?
    let pairedDeviceStore = PairedDeviceStore()
    /// Name of the wireless device currently streaming (nil when no wireless client is active).
    /// Used to roll its `lastConnected` timestamp forward every status refresh tick so the UI
    /// shows "just now" while connected and freezes at the disconnect moment afterward.
    private var currentWirelessDevice: String?
    private var cancellables = Set<AnyCancellable>()
    private var permissionCheckTimer: Timer?
    private var statusRefreshTimer: Timer?
    /// Reentrancy latch for startServer() — a second Start (double-clicked menu
    /// item, auto-start racing a manual click) must not build a second virtual
    /// display / server. Main-actor confined.
    private var isStartingServer = false
    /// The effective refresh rate the running pipeline was built with — lets
    /// the refresh-rate observer skip restarts that would change nothing.
    private var lastAppliedRefreshRate: Int?
    /// Latest type-15 advert applied to the display; sizes the display on the
    /// next start so a restart comes up matched. Main-actor confined.
    private var lastKnownCaps: ClientCapabilities?
    /// Newest advert waiting for `handlePanelChange` (latest wins).
    private var pendingCaps: ClientCapabilities?
    /// A panel change is being applied; later adverts queue in `pendingCaps`.
    private var isReconfiguring = false
    /// HDR state requested for the live display (`vdm.isHDR` may be false
    /// when the OS lacks HDR modes; this avoids recreate loops).
    private var displayRequestedHDR = false
    /// Format and fps the live encoder reports, for the status row.
    private var streamFormat: (format: StreamColorFormat, fps: Int)?
    /// `settings.transformSettings`, mirrored on the main thread for the
    /// server's network queue and the encoder threads.
    private let transformMirror = OSAllocatedUnfairLock(initialState: DisplayTransformSettings())
    private var screenParamsObserver: NSObjectProtocol?
    var isDaemonMode = false // Deprecated: keeping variable for ABI compatibility but unused

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ App launched")

        // Create menu bar item
        setupMenuBar()

        // Setup settings window
        setupSettingsWindow()

        // Setup settings observers
        setupSettingsObservers()

        // Touch maps through the virtual display's bounds; re-read them only
        // when the display arrangement or mode changes.
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshTouchBounds()
        }

        // Check permissions
        Task {
            await checkPermissions()
        }

        // Periodic status refresh for the per-mode checklist (ADB / WiFi / Listening IP).
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusIndicators()
            }
        }
        // Initial refresh so the UI isn't blank for 2 seconds.
        Task { @MainActor in
            refreshStatusIndicators()
        }

        if #available(macOS 13.0, *) {
            if DaemonManager.shared.isEnabled {
                print("🚀 Launch at Login is enabled - starting silently in background")
                // Do not show settings window automatically.
                // applicationShouldHandleReopen will show it if the user manually launched the app.
            } else {
                showSettings()
            }
        } else {
            showSettings()
        }

        // Declarative auto-start (no Mac interaction): start the server in the
        // chosen Startup mode if enabled. No blocking permission modal here —
        // it cannot be acted on when the Mac is headless.
        if settings.autoStartStreamingOnLaunch {
            settings.connectionMode = settings.startupMode
            Task {
                await self.checkPermissions()
                if self.settings.hasScreenRecordingPermission {
                    await self.startServer()
                } else {
                    debugLog("Auto-start skipped: Screen Recording permission not granted")
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettings()
        }
        return true
    }

    @MainActor
    private func refreshStatusIndicators() {
        settings.adbInstalled = StatusDetector.adbInstalled()
        settings.wifiConnected = StatusDetector.wifiReachable()
        settings.listeningAddress = LANAddressResolver.primaryIPv4()

        // "Displays have separate Spaces" off → any fullscreen app blanks the
        // virtual display (#50). Nothing we can do about it from capture side;
        // surface it so the user knows why the tablet went black.
        let separateSpaces = NSScreen.screensHaveSeparateSpaces
        if separateSpaces != settings.displaysHaveSeparateSpaces {
            settings.displaysHaveSeparateSpaces = separateSpaces
            if !separateSpaces {
                debugLog("WARNING: 'Displays have separate Spaces' is OFF — fullscreen apps on the Mac will blank the tablet (#50)")
            }
        }

        // While a wireless client is actively streaming, keep its lastConnected
        // rolling forward so the UI shows "just now". On disconnect, the
        // onClientDisconnected handler clears currentWirelessDevice — from that
        // point lastConnected stays frozen at the disconnect moment, so the
        // "X minutes ago" label counts up correctly.
        if let name = currentWirelessDevice {
            pairedDeviceStore.upsert(name: name, lastConnected: Date())
        }

        let port = Int(settings.port)
        let isStreaming = settings.isRunning && settings.clientConnected
        guard !isStreaming else { return }
        Task.detached { [weak self] in
            let devices = StatusDetector.usbDevices()
            let reverseOK = StatusDetector.adbReverseConfigured(port: port)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                
                let isConnected = !devices.isEmpty

                self.settings.usbDeviceConnected = isConnected
                self.settings.adbReverseConfigured = reverseOK

                // Self-healing USB bridge (level-triggered, not edge-triggered):
                // whenever we are in USB mode with the server running and a
                // device present but adb reverse missing, (re)establish it.
                // Covers replug, adb-server restart, etc. The server lifecycle
                // is NOT tied to device events — it stays up and the tablet
                // reconnects via its own connect button.
                if self.settings.connectionMode == .usb
                    && isConnected
                    && self.settings.isRunning
                    && !reverseOK {
                    debugLog("🔌 USB bridge missing while running — (re)establishing adb reverse")
                    Task { await self.setupADBReverse() }
                }
            }
        }
    }

    @MainActor
    private func handleConnectionModeChange(to mode: ConnectionMode) async {
        debugLog("Connection mode changed to: \(mode.rawValue)")
        // Disconnect any active client immediately (per spec §6 / fix #2).
        let wasRunning = settings.isRunning
        if wasRunning {
            stopServer()
        }
        if mode == .wireless {
            // Generate token if missing; the QR will reflect it.
            _ = WirelessAuth.loadOrCreate()
        }
        if wasRunning {
            await startServer()
        }
    }

    /// Check permissions on demand (called when settings window opens or manually)
    func refreshPermissions() {
        Task {
            await checkPermissions()
        }
    }

    func setupSettingsObservers() {
        // Observer cho gaming boost changes
        settings.$gamingBoost
            .dropFirst() // Skip initial value
            .sink { [weak self] gamingBoost in
                guard let self = self, self.settings.isRunning else { return }
                print("🎮 Gaming Boost \(gamingBoost ? "ENABLED" : "DISABLED")")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: self.settings.effectiveBitrate,
                    quality: self.settings.effectiveQuality,
                    gamingBoost: gamingBoost
                )
            }
            .store(in: &cancellables)

        // Observer cho bitrate/quality changes (chỉ khi không gaming boost)
        Publishers.CombineLatest(settings.$bitrate, settings.$quality)
            .dropFirst()
            .sink { [weak self] bitrate, quality in
                guard let self = self, self.settings.isRunning, !self.settings.gamingBoost else { return }
                print("⚙️ Settings updated: \(bitrate)Mbps, \(quality)")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: bitrate,
                    quality: quality,
                    gamingBoost: false
                )
            }
            .store(in: &cancellables)

        // Mirror first (it emits the current values at once) for the threads
        // that must not read @Published settings.
        Publishers.CombineLatest4(settings.$matchDevice, settings.$rotation, settings.$flipHorizontal, settings.$flipVertical)
            .sink { [weak self] matchDevice, rotation, flipHorizontal, flipVertical in
                let mirrored = DisplayTransformSettings(matchDevice: matchDevice, rotation: rotation,
                                                        flipHorizontal: flipHorizontal, flipVertical: flipVertical)
                self?.transformMirror.withLock { $0 = mirrored }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(settings.$rotation, settings.$flipHorizontal, settings.$flipVertical)
            .dropFirst()
            .sink { [weak self] rotation, flipHorizontal, flipVertical in
                guard let self = self, self.settings.isRunning else { return }
                // The client owns orientation while matching the device, if it advertised its panel.
                var transform = self.settings.transformSettings
                transform.rotation = rotation
                let advertised = self.streamingServer?.clientCapabilities != nil
                let transformRotation = transform.hostRotation(clientAdvertisesPanel: advertised)
                print("🔄 Display transform changed: \(transformRotation)°, h=\(flipHorizontal), v=\(flipVertical)")
                self.streamingServer?.updateDisplayTransform(rotation: transformRotation, flipHorizontal: flipHorizontal, flipVertical: flipVertical)
            }
            .store(in: &cancellables)

        // Observer cho touch enable/disable - propagate to streaming server so
        // incoming touch frames from the client are dropped early when off.
        settings.$touchEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.streamingServer?.touchEnabled = enabled
            }
            .store(in: &cancellables)

        // Observer cho connection mode changes — restart server with new auth/ADB policy.
        settings.$connectionMode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.handleConnectionModeChange(to: mode)
                }
            }
            .store(in: &cancellables)

        // Observer cho resolution changes — the virtual display is created at
        // server start, so a new resolution (list row or custom Apply) needs a
        // stop/start cycle to take effect, same as a connection-mode change.
        // Without this, changing resolution mid-run silently did nothing.
        settings.$resolution
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] resolution in
                guard let self = self else { return }
                // A matched display ignores the configured resolution.
                if self.settings.matchDevice && self.lastKnownCaps != nil { return }
                self.restartRunningServer(reason: "Resolution changed to \(resolution)")
            }
            .store(in: &cancellables)

        // HDR mode decides the virtual display's transfer function and the
        // capture preset; Match device decides its size and who owns
        // orientation (type-16 bit1). Both need a rebuild.
        settings.$hdrMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.restartRunningServer(reason: "HDR mode changed to \(mode.rawValue)")
            }
            .store(in: &cancellables)

        settings.$matchDevice
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] match in
                self?.restartRunningServer(reason: "Match device \(match ? "enabled" : "disabled")")
            }
            .store(in: &cancellables)

        // Refresh rate shapes the virtual display mode AND the capture
        // interval, so it needs the same rebuild as a resolution change.
        // Debounced: the custom-FPS slider (issue #41) emits continuously
        // while dragging — restart once the value settles. The effective-rate
        // guard skips no-op restarts (drag ends back on the applied value, or
        // Gaming Boost is pinning the rate to 120).
        settings.$refreshRate
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1.2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    let effective = self.settings.effectiveRefreshRate
                    guard effective != self.lastAppliedRefreshRate else { return }
                    self.restartRunningServer(reason: "Refresh rate changed to \(effective) Hz")
                }
            }
            .store(in: &cancellables)
    }

    /// Stop-and-restart the server to rebuild the virtual display and capture
    /// pipeline. No-op while stopped.
    private func restartRunningServer(reason: String) {
        Task { @MainActor in
            guard self.settings.isRunning else { return }
            debugLog("\(reason) — restarting server to rebuild virtual display")
            self.stopServer()
            await self.startServer()
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Side Screen")
        }

        // Items are rebuilt on every open (menuNeedsUpdate) so the menu always
        // reflects live server/connection state.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem?.menu = menu

        // Dim the menu bar icon while the server is stopped — at-a-glance
        // state without opening the menu.
        settings.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.statusItem?.button?.appearsDisabled = !running
            }
            .store(in: &cancellables)
    }

    @objc private func toggleServerFromMenu() {
        if settings.isRunning {
            stopServer()
        } else {
            Task { [weak self] in
                await self?.startServer()
            }
        }
    }

    @objc private func selectUSBMode() {
        guard settings.connectionMode != .usb else { return }
        settings.connectionMode = .usb
    }

    @objc private func selectWirelessMode() {
        guard settings.connectionMode != .wireless else { return }
        settings.connectionMode = .wireless
    }

    func setupSettingsWindow() {
        settingsWindow = SettingsWindowController(settings: settings)

        settings.onToggleServer = { [weak self] in
            guard let self else { return }
            if self.settings.isRunning {
                self.stopServer()
            } else {
                Task { [weak self] in
                    await self?.startServer()
                }
            }
        }
    }

    @objc func showSettings() {
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func checkPermissions() async {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        debugLog("checkPermissions — macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")

        // Check Screen Recording permission using CoreGraphics API
        let hasScreenCapture = CGPreflightScreenCaptureAccess()
        await MainActor.run {
            settings.hasScreenRecordingPermission = hasScreenCapture
        }
        if hasScreenCapture {
            debugLog("Screen recording permission granted (CGPreflight)")

            // On macOS 26+, also verify ScreenCaptureKit is actually functional
            if version.majorVersion >= 26 {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    debugLog("SCShareableContent verification OK — \(content.displays.count) displays found")
                } catch {
                    debugLog("WARNING: CGPreflight OK but SCShareableContent failed on macOS 26: \(error.localizedDescription)")
                    debugLog("CGDisplayStream fallback will likely activate at capture time")
                }
            }
        } else {
            debugLog("Screen recording permission not granted yet")
            CGRequestScreenCaptureAccess()
        }

        // Check Accessibility permission (required for touch/mouse injection)
        await checkAccessibilityPermission()
    }

    func checkAccessibilityPermission() async {
        let trusted = AXIsProcessTrusted()
        await MainActor.run {
            settings.hasAccessibilityPermission = trusted
        }
        debugLog(trusted ? "Accessibility permission granted"
                         : "Accessibility permission not granted - touch control will not work")
    }

    @MainActor
    func promptAccessibilityPermission() {
        // This will show the system prompt to grant Accessibility permission
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        settings.hasAccessibilityPermission = trusted

        if !trusted {
            print("⚠️  User needs to grant Accessibility permission in System Settings")
        }
    }

    /// Setup ADB reverse port forwarding for USB connection
    func setupADBReverse() async {
        let port = settings.port
        print("🔌 Setting up ADB reverse for port \(port)...")
        debugLog("🔌 setupADBReverse() invoked for port \(port)...")

        await Task.detached(priority: .utility) {
            // Try common adb paths
            let adbPaths = [
                "/usr/local/bin/adb",
                "/opt/homebrew/bin/adb",
                "~/Library/Android/sdk/platform-tools/adb",
                "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb"
            ]

            var adbPath: String?
            for path in adbPaths {
                let expandedPath = NSString(string: path).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expandedPath) {
                    adbPath = expandedPath
                    break
                }
            }

            // Also try 'which adb' to find it in PATH
            if adbPath == nil {
                let whichProcess = Process()
                whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                whichProcess.arguments = ["adb"]
                let whichPipe = Pipe()
                whichProcess.standardOutput = whichPipe
                whichProcess.standardError = FileHandle.nullDevice

                do {
                    try whichProcess.run()
                    whichProcess.waitUntilExit()
                    let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !path.isEmpty {
                        adbPath = path
                    }
                } catch {
                    // Ignore
                }
            }

            guard let finalAdbPath = adbPath else {
                print("⚠️  ADB not found - USB connection may not work")
                print("💡 Install Android SDK or run manually: adb reverse tcp:\(port) tcp:\(port)")
                return
            }

            print("📱 Found ADB at: \(finalAdbPath)")

            // Retry adb reverse up to 3 times — handles first-install authorization delay
            for attempt in 1...3 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: finalAdbPath)
                process.arguments = ["reverse", "tcp:\(port)", "tcp:\(port)"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        print("✅ ADB reverse setup successful: tcp:\(port) -> tcp:\(port)")
                        return
                    } else {
                        print("⚠️  ADB reverse attempt \(attempt)/3 failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                        if attempt < 3 {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                    }
                } catch {
                    print("⚠️  Failed to run ADB (attempt \(attempt)/3): \(error.localizedDescription)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }

            print("💡 Make sure Android device is connected via USB with debugging enabled")
        }.value
    }

    @MainActor
    func showPermissionAlert() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let isMacOS26 = version.majorVersion >= 26

        let alert = NSAlert()
        if isMacOS26 {
            alert.messageText = "Screen & System Audio Recording Permission Required"
            alert.informativeText = "Please grant Screen & System Audio Recording permission in System Settings > Privacy & Security."
        } else {
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = "Please grant Screen Recording permission in System Settings > Privacy & Security."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func startServer() async {
        let canStart = await MainActor.run { () -> Bool in
            guard !isStartingServer, !settings.isRunning else { return false }
            isStartingServer = true
            return true
        }
        guard canStart else {
            debugLog("startServer() ignored — already starting or already running")
            return
        }
        defer {
            Task { @MainActor [weak self] in self?.isStartingServer = false }
        }
        debugLog("🚀 startServer() invoked. Check permission: \(settings.hasScreenRecordingPermission)")
        guard settings.hasScreenRecordingPermission else {
            debugLog("❌ startServer aborted: Missing Screen Recording permission")
            await showPermissionAlert()
            return
        }

        do {
            // Create virtual display and run ADB setup in parallel. With
            // "Match device" and a known client panel, the display is sized to
            // it from the start; otherwise the configured resolution is used
            // until the client advertises its presentation area.
            virtualDisplayManager = VirtualDisplayManager()
            let (caps, initialRotation) = await MainActor.run {
                (lastKnownCaps, settings.transformSettings.hostRotation(clientAdvertisesPanel: lastKnownCaps != nil))
            }
            let plan = displayPlan(for: caps)
            let wantHDR = wantsHDRDisplay
            displayRequestedHDR = wantHDR
            try virtualDisplayManager?.createDisplay(
                width: plan.logicalWidth,
                height: plan.logicalHeight,
                refreshRate: settings.effectiveRefreshRate,
                hiDPI: plan.hiDPI,
                hdr: wantHDR,
                name: "SideScreen"
            )

            // Disable mirror mode (may fail if already in extend mode)
            do {
                try virtualDisplayManager?.disableMirrorMode()
            } catch {
                // Not critical - continue anyway
            }

            await MainActor.run {
                settings.displayCreated = true
            }

            // Run ADB setup (USB only) and display init wait in parallel.
            // For wireless mode, skip ADB entirely — the auth handshake gates LAN connections instead.
            await withTaskGroup(of: Void.self) { group in
                if settings.connectionMode == .usb {
                    group.addTask { await self.setupADBReverse() }
                } else {
                    debugLog("Wireless mode: skipping ADB setup")
                }
                group.addTask { try? await Task.sleep(nanoseconds: 500_000_000) }
            }

            virtualDisplayManager?.restoreDisplayPosition()

            // Verify display is registered in the system
            if let vdm = virtualDisplayManager {
                let registered = vdm.verifyDisplayRegistered()
                if !registered {
                    debugLog("WARNING: Virtual display not found in online display list — capture may fail")
                }
                // Blocks ~300 ms; WindowServer needs the main run loop to publish the mode list.
                let selected = await Task.detached(priority: .userInitiated) { vdm.applyPlannedMode() }.value
                if !selected { debugLog("WARNING: planned display mode not adopted — WindowServer default kept") }
            }

            // Setup capture
            guard let displayID = virtualDisplayManager?.displayID else {
                throw NSError(
                    domain: "SideScreen.Startup",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The virtual display was created without a display ID."]
                )
            }
            screenCapture = try await ScreenCapture()
            screenCapture?.onCaptureMethodChanged = { [weak self] method in
                guard let self = self else { return }
                debugLog("Capture method: \(method)")
                Task { @MainActor in
                    self.settings.captureMethod = method
                }
            }
            // Fires on arbitrary threads with the encoder's achieved format.
            // Type 16 must precede the display config that follows a change,
            // so it goes to the server synchronously.
            screenCapture?.onStreamFormatChanged = { [weak self] format, fps in
                guard let self = self else { return }
                self.publishStreamFormat(format, fps: fps, to: self.streamingServer)
                Task { @MainActor in
                    self.streamFormat = (format, fps)
                    self.updateStreamFormatDescription()
                }
            }
            lastAppliedRefreshRate = settings.effectiveRefreshRate
            try await screenCapture?.setupForVirtualDisplay(
                displayID,
                refreshRate: settings.effectiveRefreshRate,
                hdrMode: settings.hdrMode,
                displayIsHDR: virtualDisplayManager?.isHDR ?? false
            )

            // Setup server
            streamingServer = StreamingServer(port: settings.port)
            streamingServer?.touchEnabled = settings.touchEnabled
            if settings.connectionMode == .wireless {
                streamingServer?.expectedAuthToken = WirelessAuth.loadOrCreate()
                configurePairingCode(on: streamingServer)
                streamingServer?.onWirelessClientPaired = { [weak self] deviceName in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.currentWirelessDevice = deviceName
                        self.settings.currentWirelessDevice = deviceName
                        self.pairedDeviceStore.upsert(name: deviceName, lastConnected: Date())
                    }
                }
            }
            // displayConfig carries the ENCODED size, always. The client sizes and
            // selects its decoder from it, so a friendlier number here makes it
            // check capabilities against a resolution it will never receive. The
            // logical desktop travels separately, for display only.
            let initialEncode = ScreenCapture.physicalSize(for: displayID)
            streamingServer?.setDesktopSize(width: plan.logicalWidth, height: plan.logicalHeight)
            streamingServer?.setDisplaySize(width: initialEncode.width, height: initialEncode.height, rotation: initialRotation, flipHorizontal: settings.flipHorizontal, flipVertical: settings.flipVertical)
            streamingServer?.onClientConnected = { [weak self] in
                guard let self = self else { return }
                self.screenCapture?.requestKeyframeOrReplayCachedFrame(force: true)
                // The connect-time advert (type 15) precedes startup and is
                // only negotiated; bring the display to the client's panel now.
                let caps = self.streamingServer?.clientCapabilities
                Task { @MainActor in
                    self.settings.clientConnected = true
                    if let caps { await self.handlePanelChange(caps) }
                }
            }
            // Runs synchronously on the server's network queue BEFORE the
            // display config is sent, so the config below carries the right
            // dimensions for the negotiated codec.
            streamingServer?.onCodecNegotiated = { [weak self] codec in
                guard let self = self, let capture = self.screenCapture, let server = self.streamingServer else { return }
                capture.negotiate(
                    codec: codec,
                    clientLimit: server.clientDecodeLimits,
                    clientLimitTable: server.clientDecodeLimitTable,
                    clientCapabilities: server.clientCapabilities
                )
                // The format may predate this client: refresh type 16's
                // matches-panel flag now that its capabilities are known.
                self.publishStreamFormat(capture.activeStreamFormat, fps: capture.encodeFps, to: server)
                let enc = capture.encodeSize(for: codec)
                // Whatever the codec negotiation settled on, this is what the
                // stream's SPS will carry, so it is what the client must size
                // its decoder for.
                let transform = self.transformMirror.withLock { $0 }
                let rotation = transform.hostRotation(clientAdvertisesPanel: server.clientCapabilities != nil)
                server.setDisplaySize(width: enc.width, height: enc.height, rotation: rotation,
                                      flipHorizontal: transform.flipHorizontal, flipVertical: transform.flipVertical)
                Task { @MainActor in self.updateStreamFormatDescription() }
            }
            // Rotation, fold switch, cutout-mode change: re-mode the display
            // on the live connection.
            streamingServer?.onClientCapabilities = { [weak self] caps in
                Task { @MainActor in await self?.handlePanelChange(caps) }
            }
            streamingServer?.onKeyframeRequested = { [weak self] force in
                self?.screenCapture?.requestKeyframeOrReplayCachedFrame(force: force)
            }

            streamingServer?.onClientDisconnected = { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    self.settings.clientConnected = false
                    // Final lastConnected snapshot at the disconnect moment, then
                    // freeze (currentWirelessDevice = nil stops the rolling update
                    // in refreshStatusIndicators).
                    if let name = self.currentWirelessDevice {
                        self.pairedDeviceStore.upsert(name: name, lastConnected: Date())
                        self.currentWirelessDevice = nil
                        self.settings.currentWirelessDevice = nil
                    }
                }
            }

            streamingServer?.onTouchEvent = { [weak self] x, y, action, pointerCount, x2, y2 in
                self?.handleTouch(x: x, y: y, action: action, pointerCount: pointerCount, x2: x2, y2: y2)
            }

            streamingServer?.onStats = { [weak self] fps, mbps in
                let captured = self
                Task { @MainActor in
                    captured?.settings.currentFPS = fps
                    captured?.settings.currentBitrate = mbps
                }
            }

            guard let server = streamingServer else {
                throw NSError(
                    domain: "SideScreen.Startup",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The streaming server could not be created."]
                )
            }
            screenCapture?.shouldSkipEncode = { [weak server] in server?.isBackpressured ?? false }
            try await server.start()
            screenCapture?.startStreaming(
                to: server,
                bitrateMbps: settings.effectiveBitrate,
                quality: settings.effectiveQuality,
                gamingBoost: settings.gamingBoost
            )

            await MainActor.run {
                settings.isRunning = true
                refreshTouchBounds()
            }
            // An advert that landed while starting found the server not yet
            // running; apply it now.
            if let caps = server.clientCapabilities {
                Task { @MainActor [weak self] in await self?.handlePanelChange(caps) }
            }

            print("✅ Server started on port \(settings.port)")
        } catch {
            print("❌ Failed to start: \(error)")
            await MainActor.run {
                self.tearDownServerResources(saveDisplayPosition: false)

                let alert = NSAlert()
                alert.messageText = "Failed to Start Server"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    /// Code pairing (issue #35): issue a fresh one-time code for this wireless
    /// session. The server consumes/invalidates the code atomically on its
    /// network queue (one-time use, 5-attempt budget); these callbacks only
    /// install the replacement.
    private func configurePairingCode(on server: StreamingServer?) {
        guard let server = server else { return }
        rotatePairingCode(on: server)
        server.pairingMacName = Host.current().localizedName ?? "Mac"
        server.onPairingSuccess = { [weak self, weak server] deviceName in
            guard let self = self else { return }
            self.rotatePairingCode(on: server)
            Task { @MainActor in
                self.pairedDeviceStore.upsert(name: deviceName, lastConnected: Date())
            }
        }
        server.onPairingCodeExhausted = { [weak self, weak server] in
            debugLog("Pairing attempt budget exhausted — rotating code")
            self?.rotatePairingCode(on: server)
        }
    }

    private func rotatePairingCode(on server: StreamingServer?) {
        let code = PairingCode.generate()
        server?.expectedPairingCode = code
        Task { @MainActor in
            // A rotation queued just before Stop must not resurrect the code
            // in the UI after stopServer() cleared it.
            guard self.settings.isRunning || self.isStartingServer else { return }
            self.settings.pairingCode = code
        }
    }

    private func tearDownServerResources(saveDisplayPosition: Bool) {
        if saveDisplayPosition {
            virtualDisplayManager?.saveDisplayPosition()
        }
        settings.pairingCode = nil
        streamingServer?.expectedPairingCode = nil

        screenCapture?.stopStreaming()
        streamingServer?.stop()
        virtualDisplayManager?.destroyDisplay()

        screenCapture = nil
        streamingServer = nil
        virtualDisplayManager = nil
        currentWirelessDevice = nil
        pendingCaps = nil
        streamFormat = nil
        touchDisplayBounds = nil

        settings.isRunning = false
        settings.displayCreated = false
        settings.clientConnected = false
        settings.currentWirelessDevice = nil
        settings.currentFPS = 0
        settings.currentBitrate = 0
        settings.streamFormatDescription = ""
    }

    func stopServer() {
        tearDownServerResources(saveDisplayPosition: true)

        print("⏹️ Server stopped")
    }

    /// Type 16 for the live encoder; any thread. `matchesPanel` (the client
    /// owns orientation) needs "Match device" AND a client that advertised its
    /// panel; old clients keep host rotation.
    private func publishStreamFormat(_ format: StreamColorFormat, fps: Int, to server: StreamingServer?) {
        guard let server else { return }
        let advertised = server.clientCapabilities != nil
        let matching = transformMirror.withLock { $0 }.clientOwnsOrientation(clientAdvertisesPanel: advertised)
        server.setStreamFormat(format, fps: fps, matchesPanel: matching)
    }

    // MARK: - Display plan & panel changes (type 15)

    /// Display geometry for a start or re-mode: the client's presentation
    /// area while matching the device and its panel is known, else the
    /// configured resolution.
    private func displayPlan(for caps: ClientCapabilities?) -> DisplayPlan {
        if settings.matchDevice, let caps, caps.presentationWidth > 0, caps.presentationHeight > 0 {
            return DisplayPlan.resolve(
                presentationWidth: caps.presentationWidth,
                presentationHeight: caps.presentationHeight,
                hiDPIRequested: settings.hiDPI
            )
        }
        let size = settings.resolutionSize(clientAdvertisesPanel: caps != nil)
        let scale = settings.hiDPI ? 2 : 1
        return DisplayPlan(logicalWidth: size.width, logicalHeight: size.height, hiDPI: settings.hiDPI,
                           physicalWidth: size.width * scale, physicalHeight: size.height * scale)
    }

    /// Whether the virtual display itself should be an HDR (EDR) display. Independent of the
    /// client: SDR clients get an SDR capture of the EDR display, so a client's first advert
    /// never forces a display recreate (only toggling the HDR setting does).
    private var wantsHDRDisplay: Bool {
        guard ScreenCapture.captureSupportsHDR else { return false }
        return settings.hdrMode != .off
    }

    private enum PanelChangeOutcome {
        case applied
        /// The server was stopped or restarted meanwhile; nothing to do.
        case superseded
        case failed(String)
    }

    /// One entry point for rotation, fold switch and cutout-mode change
    /// (plan §3/§11). Serialised and latest-wins: adverts arriving while one
    /// is applied replace `pendingCaps`, and only the newest is applied next.
    /// The StreamingServer and its connection are never touched; a failure
    /// falls back to a full server restart.
    @MainActor
    private func handlePanelChange(_ caps: ClientCapabilities) async {
        pendingCaps = caps
        guard !isReconfiguring else { return }
        isReconfiguring = true
        defer { isReconfiguring = false }

        while let next = pendingCaps ?? newerServerCaps() {
            pendingCaps = nil
            guard settings.isRunning,
                  let server = streamingServer,
                  let capture = screenCapture,
                  let vdm = virtualDisplayManager else { return }
            switch await applyPanelChange(next, server: server, capture: capture, vdm: vdm) {
            case .applied:
                lastKnownCaps = next
            case .superseded:
                pendingCaps = nil
                return
            case .failed(let reason):
                pendingCaps = nil
                lastKnownCaps = next
                restartRunningServer(reason: "Display re-mode failed (\(reason))")
                return
            }
        }
    }

    /// The live connection's advert when it differs from the last applied
    /// one: catches an advert whose main-actor hop was overtaken by an older one.
    @MainActor
    private func newerServerCaps() -> ClientCapabilities? {
        guard let caps = streamingServer?.clientCapabilities, caps != lastKnownCaps else { return nil }
        return caps
    }

    @MainActor
    private func applyPanelChange(
        _ caps: ClientCapabilities,
        server: StreamingServer,
        capture: ScreenCapture,
        vdm: VirtualDisplayManager
    ) async -> PanelChangeOutcome {
        let plan = displayPlan(for: caps)
        let wantHDR = wantsHDRDisplay

        if wantHDR != displayRequestedHDR {
            debugLog("Panel change: display HDR \(displayRequestedHDR) -> \(wantHDR) — recreating display")
            return await recreateDisplay(plan, caps: caps, server: server, capture: capture, vdm: vdm)
        }

        let target = (plan.physicalWidth, plan.physicalHeight)
        let sizeChanged = settings.matchDevice && vdm.physicalSize.map { $0 != target } ?? true
        if sizeChanged {
            let outcome = await remodeInPlace(plan, caps: caps, server: server, capture: capture, vdm: vdm)
            guard case .failed(let reason) = outcome else { return outcome }
            debugLog("In-place re-mode failed (\(reason)) — recreating display")
            return await recreateDisplay(plan, caps: caps, server: server, capture: capture, vdm: vdm)
        }

        if caps != lastKnownCaps {
            renegotiate(caps, server: server, capture: capture, vdm: vdm)
        }
        return .applied
    }

    /// Fast path (§11): new modes on the live display (same ID), the same
    /// SCStream retargeted, a new encoder, a new stream segment. ~100–200 ms.
    /// Wire order: old frames → new segment + display config → new-size IDR.
    @MainActor
    private func remodeInPlace(
        _ plan: DisplayPlan,
        caps: ClientCapabilities,
        server: StreamingServer,
        capture: ScreenCapture,
        vdm: VirtualDisplayManager
    ) async -> PanelChangeOutcome {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let refreshRate = lastAppliedRefreshRate ?? settings.effectiveRefreshRate
        // Negotiate first: a capture restart it triggers is serialised ahead
        // of the resize below instead of racing it.
        if caps != lastKnownCaps {
            renegotiate(caps, server: server, capture: capture, vdm: vdm)
        }
        // Blocks up to 500 ms polling for the new mode: keep it off the main thread.
        let remoded = await Task.detached(priority: .userInitiated) {
            vdm.reconfigure(width: plan.logicalWidth, height: plan.logicalHeight,
                            refreshRate: refreshRate, hiDPI: plan.hiDPI)
        }.value
        guard streamingServer === server else { return .superseded }
        guard remoded, let displayID = vdm.displayID else { return .failed("reconfigure returned false") }

        let physical = await settledPhysicalSize(of: displayID, plan: plan)
        guard streamingServer === server else { return .superseded }
        do {
            // Waits for any capture restart in flight (e.g. the connect-time
            // negotiation's) before retargeting the stream.
            try await capture.resize(width: physical.width, height: physical.height)
        } catch {
            guard streamingServer === server else { return .superseded }
            return .failed("capture resize: \(error.localizedDescription)")
        }
        guard streamingServer === server else { return .superseded }

        capture.startNewSegment {
            server.beginNewStreamSegment()
            announceDisplay(server: server, capture: capture, displayID: displayID, plan: plan)
        }
        // Covers an idle display: re-encodes the cached frame on the new encoder.
        capture.requestKeyframeOrReplayCachedFrame(force: true)
        refreshTouchBounds()
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
        debugLog("Display re-moded in place to \(plan.logicalWidth)x\(plan.logicalHeight)\(plan.hiDPI ? " HiDPI" : "") in \(elapsedMs) ms")
        return .applied
    }

    /// The adopted mode's physical size, re-polled for up to ~200 ms while it
    /// differs from the plan: CG can report a transient (e.g. 1×) mode right
    /// after apply. Returns the last read when it never matches.
    @MainActor
    private func settledPhysicalSize(of displayID: CGDirectDisplayID, plan: DisplayPlan) async -> (width: Int, height: Int) {
        let planned = (plan.physicalWidth, plan.physicalHeight)
        var physical = ScreenCapture.physicalSize(for: displayID)
        var polls = 0
        while physical != planned, polls < 20 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            physical = ScreenCapture.physicalSize(for: displayID)
            polls += 1
        }
        if physical != planned {
            debugLog("Re-mode read back \(physical.width)x\(physical.height), planned \(plan.physicalWidth)x\(plan.physicalHeight)")
        }
        return physical
    }

    /// Fallback: destroy and recreate the virtual display (new ID), re-set up
    /// capture on the same ScreenCapture, and resume on the same connection.
    /// Also the only way to switch the display's HDR state. ~1–2 s.
    @MainActor
    private func recreateDisplay(
        _ plan: DisplayPlan,
        caps: ClientCapabilities,
        server: StreamingServer,
        capture: ScreenCapture,
        vdm: VirtualDisplayManager
    ) async -> PanelChangeOutcome {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let refreshRate = lastAppliedRefreshRate ?? settings.effectiveRefreshRate
        let hdr = wantsHDRDisplay
        vdm.saveDisplayPosition()
        capture.stopStreaming()
        do {
            // Replaces the live display (createDisplay destroys it first).
            try vdm.createDisplay(width: plan.logicalWidth, height: plan.logicalHeight, refreshRate: refreshRate,
                                  hiDPI: plan.hiDPI, hdr: hdr, name: "SideScreen")
        } catch {
            return .failed("createDisplay: \(error.localizedDescription)")
        }
        displayRequestedHDR = hdr
        try? vdm.disableMirrorMode()
        // Same settle time as startServer before the display is capturable.
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard streamingServer === server else { return .superseded }
        vdm.restoreDisplayPosition()
        if !vdm.verifyDisplayRegistered() {
            debugLog("WARNING: Recreated virtual display not found in online display list — capture may fail")
        }
        if !(await Task.detached(priority: .userInitiated) { vdm.applyPlannedMode() }.value) {
            debugLog("WARNING: planned display mode not adopted — WindowServer default kept")
        }
        guard streamingServer === server else { return .superseded }
        guard let displayID = vdm.displayID else { return .failed("recreated display has no ID") }

        // Negotiate first so the stream is set up for the new caps' fps/format.
        negotiate(caps, server: server, capture: capture)
        do {
            try await capture.setupForVirtualDisplay(displayID, refreshRate: refreshRate,
                                                     hdrMode: settings.hdrMode, displayIsHDR: vdm.isHDR)
        } catch {
            return .failed("capture setup: \(error.localizedDescription)")
        }
        guard streamingServer === server else { return .superseded }

        server.beginNewStreamSegment()
        // Installs the encoder synchronously, so a changed format (type 16)
        // goes out before the display config below.
        capture.startStreaming(to: server, bitrateMbps: settings.effectiveBitrate,
                               quality: settings.effectiveQuality, gamingBoost: settings.gamingBoost)
        announceDisplay(server: server, capture: capture, displayID: displayID, plan: plan)
        capture.requestKeyframeOrReplayCachedFrame(force: true)
        refreshTouchBounds()
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
        debugLog("Display recreated at \(plan.logicalWidth)x\(plan.logicalHeight)\(plan.hiDPI ? " HiDPI" : "")\(vdm.isHDR ? " HDR" : "") in \(elapsedMs) ms")
        return .applied
    }

    /// Same display, changed HDR/fps capabilities: re-negotiate only. When the
    /// encode size changes, the new segment and display config go out after
    /// the old encoder's last frame and before the new one's IDR.
    @MainActor
    private func renegotiate(_ caps: ClientCapabilities, server: StreamingServer, capture: ScreenCapture, vdm: VirtualDisplayManager) {
        let before = capture.encodeSize(for: capture.codec)
        let plan = displayPlan(for: caps)
        var announced = false
        negotiate(caps, server: server, capture: capture) {
            guard let displayID = vdm.displayID else { return }
            server.beginNewStreamSegment()
            announceDisplay(server: server, capture: capture, displayID: displayID, plan: plan)
            announced = true
        }
        let after = capture.encodeSize(for: capture.codec)
        guard after != before, let displayID = vdm.displayID else {
            updateStreamFormatDescription()
            return
        }
        if !announced {
            // No live encoder to swap: just announce the new size.
            server.beginNewStreamSegment()
            announceDisplay(server: server, capture: capture, displayID: displayID, plan: plan)
        }
        capture.requestKeyframeOrReplayCachedFrame(force: true)
    }

    private func negotiate(_ caps: ClientCapabilities, server: StreamingServer, capture: ScreenCapture,
                           openSegment: () -> Void = {}) {
        capture.negotiate(codec: capture.codec, clientLimit: server.clientDecodeLimits,
                          clientLimitTable: server.clientDecodeLimitTable, clientCapabilities: caps,
                          openSegment: openSegment)
    }

    /// Sends the display config for the live encode size (and the logical
    /// desktop as macOS actually laid it out).
    @MainActor
    private func announceDisplay(server: StreamingServer, capture: ScreenCapture, displayID: CGDirectDisplayID, plan: DisplayPlan) {
        let desktop = CGDisplayBounds(displayID).size
        if desktop.width > 0, desktop.height > 0 {
            server.setDesktopSize(width: Int(desktop.width), height: Int(desktop.height))
        } else {
            server.setDesktopSize(width: plan.logicalWidth, height: plan.logicalHeight)
        }
        let enc = capture.encodeSize(for: capture.codec)
        let transform = settings.transformSettings
        let rotation = transform.hostRotation(clientAdvertisesPanel: server.clientCapabilities != nil)
        server.setDisplaySize(width: enc.width, height: enc.height, rotation: rotation,
                              flipHorizontal: transform.flipHorizontal, flipVertical: transform.flipVertical)
        server.sendDisplaySize()
        updateStreamFormatDescription()
    }

    /// "HDR10 · 10-bit · 120 fps · 2340×1080" from the live encoder.
    @MainActor
    private func updateStreamFormatDescription() {
        guard let capture = screenCapture, let streamFormat else {
            settings.streamFormatDescription = ""
            return
        }
        let enc = capture.encodeSize(for: capture.codec)
        settings.streamFormatDescription = DisplaySettings.describeStreamFormat(
            streamFormat.format, fps: streamFormat.fps, width: enc.width, height: enc.height)
    }

    private func refreshTouchBounds() {
        touchDisplayBounds = virtualDisplayManager?.displayID.map { (id: $0, bounds: CGDisplayBounds($0)) }
    }

    // MARK: - Gesture Properties

    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var accessibilityWarningShown = false
    private var gestureState: GestureState = .idle
    private var lastTouchTime: UInt64 = 0
    /// `CGDisplayBounds` of the virtual display, cached off the per-event path;
    /// refreshed on screen-parameter changes and after every re-mode.
    private var touchDisplayBounds: (id: CGDirectDisplayID, bounds: CGRect)?

    // Touch tracking
    private var touchStartPosition: CGPoint = .zero
    private var touchLastPosition: CGPoint = .zero
    private var touchStartTime: UInt64 = 0
    private var touchLastMoveTime: UInt64 = 0
    private var lastScrollDeltaX: CGFloat = 0
    private var lastScrollDeltaY: CGFloat = 0

    // Double tap tracking
    private var lastTapTime: UInt64 = 0
    private var lastTapPosition: CGPoint = .zero

    // Long press timer
    private var longPressTimer: DispatchWorkItem?

    // 2-finger tracking
    private var initialPinchDistance: CGFloat = 0
    private var lastPinchDistance: CGFloat = 0

    // Momentum scrolling
    private var momentumTimer: Timer?
    private var momentumVelocityX: CGFloat = 0
    private var momentumVelocityY: CGFloat = 0
    private var lastMomentumPosition: CGPoint = .zero

    // MARK: - Touch Entry Point

    func handleTouch(x: Float, y: Float, action: Int, pointerCount: Int = 1, x2: Float = 0, y2: Float = 0) {
        guard settings.touchEnabled else { return }

        if !AXIsProcessTrusted() {
            if !accessibilityWarningShown {
                accessibilityWarningShown = true
                debugLog("Accessibility not granted - touch ignored")
                Task { @MainActor in
                    settings.hasAccessibilityPermission = false
                }
            }
            return
        }

        guard let displayID = virtualDisplayManager?.displayID else { return }
        if touchDisplayBounds?.id != displayID {
            refreshTouchBounds()
        }
        guard let bounds = touchDisplayBounds?.bounds else { return }

        let p1 = CGPoint(
            x: bounds.origin.x + CGFloat(x) * bounds.width,
            y: bounds.origin.y + CGFloat(y) * bounds.height
        )
        let p2 = CGPoint(
            x: bounds.origin.x + CGFloat(x2) * bounds.width,
            y: bounds.origin.y + CGFloat(y2) * bounds.height
        )

        if pointerCount >= 2 {
            handleTwoFingerTouch(p1: p1, p2: p2, action: action)
        } else {
            handleOneFingerTouch(at: p1, action: action)
        }
    }

    // MARK: - 1-Finger Gesture State Machine

    private func handleOneFingerTouch(at point: CGPoint, action: Int) {
        switch action {
        case 0: oneFingerDown(at: point)
        case 1: oneFingerMove(to: point)
        case 2: oneFingerUp(at: point)
        default: break
        }
    }

    private func oneFingerDown(at point: CGPoint) {
        stopMomentumScroll()
        cancelLongPressTimer()

        touchStartPosition = point
        touchLastPosition = point
        touchStartTime = DispatchTime.now().uptimeNanoseconds
        touchLastMoveTime = touchStartTime
        gestureState = .pending

        // Move cursor to touch position (absolute)
        moveCursor(to: point)

        // Start long press timer
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.gestureState == .pending else { return }
            self.gestureState = .longPressReady
        }
        longPressTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(GestureThresholds.longPressTime)),
            execute: timer
        )
    }

    private func oneFingerMove(to point: CGPoint) {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastTouchTime < GestureThresholds.minTouchInterval { return }
        lastTouchTime = now

        let deltaX = point.x - touchLastPosition.x
        let deltaY = point.y - touchLastPosition.y
        let totalDistance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            if totalDistance > GestureThresholds.tapMaxDistance {
                cancelLongPressTimer()
                gestureState = .scrolling
                let sx = deltaX * GestureThresholds.scrollSensitivity
                let sy = deltaY * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .longPressReady:
            if totalDistance > GestureThresholds.tapMaxDistance {
                // Long press + drag → left mouse drag
                gestureState = .dragging
                injectMouseDown(at: touchStartPosition)
                injectMouseDragged(to: point)
            }

        case .scrolling:
            let sx = deltaX * GestureThresholds.scrollSensitivity
            let sy = deltaY * GestureThresholds.scrollSensitivity
            injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
            let timeDelta = now - touchLastMoveTime
            if timeDelta > 0 && timeDelta < 100_000_000 {
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .dragging:
            injectMouseDragged(to: point)

        default:
            break
        }

        touchLastPosition = point
        touchLastMoveTime = now
    }

    private func oneFingerUp(at point: CGPoint) {
        cancelLongPressTimer()
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - touchStartTime
        let distance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            // Quick release, no movement → tap or double tap
            if distance < GestureThresholds.tapMaxDistance && elapsed < GestureThresholds.tapMaxTime {
                // Check double tap
                let timeSinceLastTap = now - lastTapTime
                let distFromLastTap = hypot(point.x - lastTapPosition.x, point.y - lastTapPosition.y)

                if timeSinceLastTap < GestureThresholds.doubleTapMaxTime
                    && distFromLastTap < GestureThresholds.doubleTapMaxDistance {
                    performDoubleClick(at: point)
                    lastTapTime = 0  // Reset so triple tap doesn't trigger
                } else {
                    performClick(at: point)
                    lastTapTime = now
                    lastTapPosition = point
                }
            }

        case .longPressReady:
            // Held long but didn't drag → right click
            performRightClick(at: point)

        case .scrolling:
            // Check momentum
            let timeSinceLastMove = now - touchLastMoveTime
            if timeSinceLastMove < 50_000_000 {
                let threshold: CGFloat = 2.0
                if abs(lastScrollDeltaX) > threshold || abs(lastScrollDeltaY) > threshold {
                    startMomentumScroll(
                        velocityX: lastScrollDeltaX * 6.0,
                        velocityY: lastScrollDeltaY * 6.0,
                        at: point
                    )
                }
            }

        case .dragging:
            injectMouseUp(at: point)

        default:
            break
        }

        gestureState = .idle
    }

    // MARK: - 2-Finger Gestures

    private func handleTwoFingerTouch(p1: CGPoint, p2: CGPoint, action: Int) {
        let distance = hypot(p2.x - p1.x, p2.y - p1.y)
        let midpoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

        switch action {
        case 0: // Down
            cancelLongPressTimer()
            stopMomentumScroll()
            gestureState = .idle  // Reset so 2-finger detection starts fresh
            initialPinchDistance = distance
            lastPinchDistance = distance
            touchLastPosition = midpoint

        case 1: // Move
            let distanceChange = abs(distance - initialPinchDistance)
            let midDelta = hypot(midpoint.x - touchLastPosition.x, midpoint.y - touchLastPosition.y)

            // Determine mode if not yet decided
            if gestureState != .twoFingerScroll && gestureState != .pinching {
                if distanceChange > GestureThresholds.pinchMinDistance {
                    gestureState = .pinching
                } else if midDelta > GestureThresholds.tapMaxDistance {
                    gestureState = .twoFingerScroll
                }
            }

            switch gestureState {
            case .twoFingerScroll:
                let dx = (midpoint.x - touchLastPosition.x) * GestureThresholds.scrollSensitivity
                let dy = (midpoint.y - touchLastPosition.y) * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: dx, deltaY: dy, at: midpoint)

            case .pinching:
                let scaleDelta = distance - lastPinchDistance
                // Cmd + scroll = zoom in most Mac apps
                let zoomAmount = Int32(scaleDelta * 0.5)
                if zoomAmount != 0 {
                    injectZoomEvent(delta: zoomAmount, at: midpoint)
                }
                lastPinchDistance = distance

            default:
                break
            }

            touchLastPosition = midpoint

        case 2: // Up
            gestureState = .idle
            // Reset 1-finger tracking so leftover moves don't trigger scroll
            touchStartPosition = .zero
            touchLastPosition = .zero

        default:
            break
        }
    }

    // MARK: - Event Injection

    private func moveCursor(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func performClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performDoubleClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 2)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 2)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performRightClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) {
            up.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDown(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDragged(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseUp(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectScrollEvent(deltaX: CGFloat, deltaY: CGFloat, at position: CGPoint) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        scrollEvent.post(tap: .cghidEventTap)
    }

    private func injectZoomEvent(delta: Int32, at position: CGPoint) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        // Set Cmd flag for zoom
        scrollEvent.flags = .maskCommand
        scrollEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Long Press Timer

    private func cancelLongPressTimer() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    // MARK: - Momentum Scrolling

    private func startMomentumScroll(velocityX: CGFloat, velocityY: CGFloat, at position: CGPoint) {
        stopMomentumScroll()
        momentumVelocityX = velocityX
        momentumVelocityY = velocityY
        lastMomentumPosition = position
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.momentumTick()
        }
    }

    private func momentumTick() {
        let decay: CGFloat = 0.92
        let minVelocity: CGFloat = 0.5

        if abs(momentumVelocityX) < minVelocity && abs(momentumVelocityY) < minVelocity {
            stopMomentumScroll()
            return
        }

        injectScrollEvent(deltaX: momentumVelocityX, deltaY: momentumVelocityY, at: lastMomentumPosition)
        momentumVelocityX *= decay
        momentumVelocityY *= decay
    }

    private func stopMomentumScroll() {
        momentumTimer?.invalidate()
        momentumTimer = nil
        momentumVelocityX = 0
        momentumVelocityY = 0
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop momentum scrolling
        stopMomentumScroll()

        // Stop server and cleanup
        stopServer()

        // Cancel all combine subscriptions
        cancellables.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - Menu bar quick actions

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Live status line (not clickable)
        let statusTitle: String
        if settings.isRunning {
            if settings.clientConnected {
                let device = settings.currentWirelessDevice ?? "tablet"
                statusTitle = "🟢 Connected — \(device)"
            } else {
                statusTitle = "🟡 Waiting for tablet on port \(settings.port)"
            }
        } else {
            statusTitle = "⚪️ Server stopped"
        }
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        // Start / Stop
        let toggle = NSMenuItem(
            title: settings.isRunning ? "Stop Streaming" : "Start Streaming",
            action: #selector(toggleServerFromMenu),
            keyEquivalent: "t"
        )
        toggle.target = self
        // Mirror the settings-window Start button: starting needs the Screen
        // Recording permission, stopping is always allowed.
        toggle.isEnabled = settings.isRunning || settings.hasScreenRecordingPermission
        menu.addItem(toggle)

        // Connection mode (switching while running restarts the server, same
        // as changing it in the settings window)
        let modeMenu = NSMenu()
        modeMenu.autoenablesItems = false
        let usb = NSMenuItem(title: "USB", action: #selector(selectUSBMode), keyEquivalent: "")
        usb.target = self
        usb.state = settings.connectionMode == .usb ? .on : .off
        modeMenu.addItem(usb)
        let wireless = NSMenuItem(title: "Wireless", action: #selector(selectWirelessMode), keyEquivalent: "")
        wireless.target = self
        wireless.state = settings.connectionMode == .wireless ? .on : .off
        modeMenu.addItem(wireless)
        let modeItem = NSMenuItem(title: "Connection Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "s")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Side Screen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

import Cocoa
import SwiftUI

// MARK: - Frosted GroupBox Component

struct FrostedGroupBox<Content: View, Trailing: View>: View {
    let title: String
    var icon: String?
    var accentTint: Color = .accentColor
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let icon = icon {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(accentTint.opacity(0.14))
                            .frame(width: 24, height: 24)
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(accentTint)
                    }
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                trailing
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.06), radius: 8, y: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.14), Color.primary.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
    }
}

extension FrostedGroupBox where Trailing == EmptyView {
    init(
        title: String,
        icon: String? = nil,
        accentTint: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.accentTint = accentTint
        self.content = content()
        self.trailing = EmptyView()
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var settings: DisplaySettings
    @State private var showPermissionAlert = false
    @State private var showResetConfirmation = false
    @State private var headerHovered = false
    // Plain strings for the custom resolution fields: TextField(value:format:)
    // only commits on Return/focus-loss, so clicking Apply read stale values,
    // and .number formatting injected locale grouping separators ("1,200").
    @State private var customWidthText = ""
    @State private var customHeightText = ""
    @State private var daemonEnabled = false

    private var customWidthValue: Int? { Int(customWidthText.trimmingCharacters(in: .whitespaces)) }
    private var customHeightValue: Int? { Int(customHeightText.trimmingCharacters(in: .whitespaces)) }
    private var customResolutionValid: Bool {
        guard let w = customWidthValue, let h = customHeightValue else { return false }
        return DisplaySettings.isValidCustomResolution(width: w, height: h)
    }

    private var hdrHint: String {
        switch settings.hdrMode {
        case .off:
            return "Always 8-bit SDR."
        case _ where !ScreenCapture.captureSupportsHDR:
            return "HDR capture needs macOS 26 or later — streaming SDR."
        case .auto:
            return "HDR10 (10-bit) when the phone can decode and show it, else SDR."
        case .on:
            return "HDR display always; HDR10 stream to phones that report capabilities."
        }
    }

    private var hdrStatusBadgeText: String {
        if settings.hdrMode == .off {
            return "8-bit SDR"
        }
        if !ScreenCapture.captureSupportsHDR {
            return "SDR Fallback"
        }
        return settings.hdrMode == .on ? "HDR10 Forced" : "HDR10 Auto"
    }

    private var hdrStatusBadgeColor: Color {
        if settings.hdrMode == .off {
            return .secondary
        }
        return ScreenCapture.captureSupportsHDR ? .green : .orange
    }

    private var activeResolutionLabel: String {
        if settings.isRunning && !settings.streamFormatDescription.isEmpty {
            let parts = settings.streamFormatDescription.components(separatedBy: " · ")
            if let last = parts.last, !last.isEmpty {
                return last
            }
        }
        if settings.matchDevice {
            return "Auto Match"
        }
        return settings.resolution.replacingOccurrences(of: "x", with: "×")
    }

    private var latencyBadgeLabel: String {
        if settings.gamingBoost {
            return "<10 ms Boost"
        }
        return settings.effectiveQuality == "ultralow" ? "Ultra-Low E2E" : "Standard E2E"
    }

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // Subtle ambient top glow that responds to server & boost state
            VStack {
                LinearGradient(
                    colors: [
                        (settings.gamingBoost ? Color.cyan : Color.accentColor).opacity(settings.isRunning ? 0.14 : 0.06),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)
                Spacer()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                headerSection

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Wireless pairing section surfaced immediately when Wireless mode is active
                        if settings.connectionMode == .wireless {
                            WirelessSection(
                                settings: settings,
                                pairedDeviceStore: (NSApp.delegate as? AppDelegate)?.pairedDeviceStore ?? PairedDeviceStore()
                            )
                        }

                        lowLatencyHeroCard

                        displayConfigurationCard

                        refreshRateCard

                        streamingSettingsCard

                        touchAndNetworkCard

                        startupCard

                        statusAndPermissionsCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }

                footerSection
            }
        }
        .frame(width: 500, height: 800)
    }

    // MARK: - Header & Status Bar

    private var headerSection: some View {
        VStack(spacing: 12) {
            // Top Brand & Quick Actions Row
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: settings.gamingBoost
                                    ? [Color.cyan, Color.accentColor]
                                    : [Color.accentColor, Color.accentColor.opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 3)

                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                        .frame(width: 44, height: 44)

                    Image(systemName: settings.gamingBoost ? "bolt.display" : "rectangle.on.rectangle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                }
                .scaleEffect(headerHovered ? 1.04 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: headerHovered)
                .onHover { headerHovered = $0 }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Side Screen")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        if settings.gamingBoost {
                            Text("LOW LATENCY")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.cyan.opacity(0.2)))
                                .foregroundColor(.cyan)
                        }
                    }
                    Text("Turn your tablet or phone into a high-refresh second display")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { showResetConfirmation = true }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 30)
                        .background {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                }
                        }
                }
                .buttonStyle(.plain)
                .help("Reset settings to defaults")
                .alert("Reset Settings", isPresented: $showResetConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Reset", role: .destructive) {
                        settings.resetToDefaults()
                        customWidthText = String(settings.customWidth)
                        customHeightText = String(settings.customHeight)
                        if let window = NSApp.windows.first(where: { $0.title == "Side Screen" }) {
                            window.center()
                        }
                    }
                } message: {
                    Text("This will reset all settings to default values.")
                }
            }

            // Polished Live Telemetry Status Bar
            HStack(spacing: 6) {
                HeaderStatusBadge(
                    icon: "circle.fill",
                    label: settings.clientConnected
                        ? "Streaming"
                        : (settings.isRunning ? "Listening" : "Stopped"),
                    tint: settings.clientConnected
                        ? .green
                        : (settings.isRunning ? .orange : .secondary),
                    isPulsing: settings.isRunning
                )

                HeaderStatusBadge(
                    icon: "speedometer",
                    label: settings.clientConnected
                        ? String(format: "%.0f fps", settings.currentFPS)
                        : "\(settings.effectiveRefreshRate) Hz",
                    tint: settings.clientConnected ? .green : .primary
                )

                HeaderStatusBadge(
                    icon: "waveform.path.ecg",
                    label: settings.clientConnected
                        ? String(format: "%.1f Mbps", settings.currentBitrate)
                        : "\(settings.effectiveBitrate) Mbps",
                    tint: settings.clientConnected ? .accentColor : .primary
                )

                HeaderStatusBadge(
                    icon: "aspectratio",
                    label: activeResolutionLabel,
                    tint: .primary
                )

                HeaderStatusBadge(
                    icon: settings.gamingBoost ? "bolt.fill" : "timer",
                    label: latencyBadgeLabel,
                    tint: settings.gamingBoost ? .cyan : .secondary
                )
            }

            // Pinned Connection Mode Segmented Control
            HStack(spacing: 6) {
                ForEach(ConnectionMode.allCases, id: \.self) { mode in
                    let isSelected = settings.connectionMode == mode
                    Button(action: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            settings.connectionMode = mode
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: mode == .usb ? "cable.connector" : "wifi")
                                .font(.system(size: 12, weight: .semibold))
                            Text(mode == .usb ? "USB Cable" : "Wireless Wi-Fi")
                                .font(.system(size: 12, weight: .semibold))
                            Text(mode == .usb ? "Lowest Latency" : "QR Pairing")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        isSelected
                                            ? Color.white.opacity(0.22)
                                            : Color.primary.opacity(0.06)
                                    )
                                )
                                .foregroundColor(isSelected ? .white : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.accentColor)
                                    .shadow(color: Color.accentColor.opacity(0.25), radius: 4, y: 2)
                            }
                        }
                        .foregroundColor(isSelected ? .white : .primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Low Latency Mode Hero Card

    private var lowLatencyHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            settings.gamingBoost
                                ? LinearGradient(
                                    colors: [Color.cyan, Color.accentColor],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.10)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                        )
                        .frame(width: 36, height: 36)

                    Image(systemName: settings.gamingBoost ? "bolt.fill" : "bolt")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(settings.gamingBoost ? .white : .accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Low Latency Mode")
                            .font(.system(size: 14, weight: .bold))
                        Text(settings.gamingBoost ? "ACTIVE" : "PRO")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    settings.gamingBoost
                                        ? Color.green.opacity(0.2)
                                        : Color.accentColor.opacity(0.15)
                                )
                            )
                            .foregroundColor(settings.gamingBoost ? .green : .accentColor)
                    }
                    Text("Sub-10ms response time with 120 fps, 150 Mbps, and zero-reorder pipeline")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("", isOn: $settings.gamingBoost)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            // Visual indicator grid
            HStack(spacing: 8) {
                LowLatencyMetricPill(
                    icon: "speedometer",
                    title: "120 Hz",
                    subtitle: "Refresh Rate",
                    isActive: settings.gamingBoost
                )
                LowLatencyMetricPill(
                    icon: "dial.high.fill",
                    title: "150 Mbps",
                    subtitle: "High Bitrate",
                    isActive: settings.gamingBoost
                )
                LowLatencyMetricPill(
                    icon: "bolt.horizontal.fill",
                    title: "< 10 ms",
                    subtitle: "E2E Pipeline",
                    isActive: settings.gamingBoost
                )
                LowLatencyMetricPill(
                    icon: "sparkles.tv",
                    title: "HDR10",
                    subtitle: "Full Sharpness",
                    isActive: settings.gamingBoost
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    if settings.gamingBoost {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.cyan.opacity(0.12),
                                        Color.accentColor.opacity(0.06)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    settings.gamingBoost
                        ? LinearGradient(
                            colors: [Color.cyan.opacity(0.55), Color.accentColor.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [Color.primary.opacity(0.14), Color.primary.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                    lineWidth: settings.gamingBoost ? 1.5 : 1
                )
        }
    }

    // MARK: - Display Configuration Card

    private var displayConfigurationCard: some View {
        FrostedGroupBox(
            title: "Display & Resolution",
            icon: "display",
            content: {
                VStack(alignment: .leading, spacing: 14) {
                    // Hero Toggle: Match device display
                    HStack(spacing: 12) {
                        Image(systemName: "ipad.and.iphone")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(settings.matchDevice ? .accentColor : .secondary)
                            .frame(width: 32, height: 32)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(
                                        settings.matchDevice
                                            ? Color.accentColor.opacity(0.15)
                                            : Color.primary.opacity(0.05)
                                    )
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Match device display")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("RECOMMENDED")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                    .foregroundColor(.accentColor)
                            }
                            Text("Size the display to the phone's screen; orientation follows the phone.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $settings.matchDevice)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                settings.matchDevice
                                    ? Color.accentColor.opacity(0.07)
                                    : Color.primary.opacity(0.03)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        settings.matchDevice
                                            ? Color.accentColor.opacity(0.25)
                                            : Color.primary.opacity(0.06),
                                        lineWidth: 1
                                    )
                            }
                    }

                    // Resolution Presets & Custom Resolution
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Resolution Preset")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(settings.resolution.replacingOccurrences(of: "x", with: " × "))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                            Spacer()
                            Toggle("Show all", isOn: $settings.showAllResolutions)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .font(.system(size: 11))
                        }

                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if settings.showAllResolutions {
                                    // Custom (Apply) values aren't in any preset group —
                                    // surface them so the selection is visible in the list.
                                    if !DisplaySettings.allResolutions.contains(settings.resolution) {
                                        HStack(spacing: 6) {
                                            Text("Custom")
                                                .font(.system(size: 11, weight: .semibold))
                                            Text("User defined")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.primary.opacity(0.04))

                                        ResolutionRow(resolution: settings.resolution, isSelected: true) {}
                                    }
                                    ForEach(DisplaySettings.resolutionGroups) { group in
                                        HStack(spacing: 6) {
                                            Text(group.name)
                                                .font(.system(size: 11, weight: .semibold))
                                            Text(group.ratio)
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.primary.opacity(0.04))

                                        ForEach(group.resolutions, id: \.self) { res in
                                            ResolutionRow(resolution: res, isSelected: settings.resolution == res) {
                                                settings.resolution = res
                                            }
                                        }
                                    }
                                } else {
                                    ForEach(DisplaySettings.commonResolutions, id: \.self) { res in
                                        ResolutionRow(resolution: res, isSelected: settings.resolution == res) {
                                            settings.resolution = res
                                        }
                                    }
                                    // Current selection from the full list or a custom
                                    // Apply — keep it visible in the compact list too.
                                    if !DisplaySettings.commonResolutions.contains(settings.resolution) {
                                        ResolutionRow(resolution: settings.resolution, isSelected: true) {}
                                    }
                                }
                            }
                        }
                        .frame(height: settings.showAllResolutions ? 175 : 124)
                        .background(Color.primary.opacity(0.03))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                        )

                        if settings.showAllResolutions {
                            HStack(spacing: 8) {
                                Text("Custom:")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                                TextField("W", text: $customWidthText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 68)
                                Text("×")
                                    .foregroundColor(.secondary)
                                TextField("H", text: $customHeightText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 68)
                                Button("Apply") {
                                    guard customResolutionValid,
                                          let w = customWidthValue,
                                          let h = customHeightValue else { return }
                                    settings.customWidth = w
                                    settings.customHeight = h
                                    settings.applyCustomResolution()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(!customResolutionValid)
                            }
                            .onAppear {
                                customWidthText = String(settings.customWidth)
                                customHeightText = String(settings.customHeight)
                            }
                            if !customResolutionValid {
                                Text("Supported range: 640–7680 × 480–4320")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            }
                        }
                        if settings.matchDevice {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10))
                                Text("Resolution follows the connected device (fallback preset used until device reports its screen)")
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(.accentColor)
                        }
                    }
                    .disabled(settings.matchDevice)
                    .opacity(settings.matchDevice ? 0.55 : 1)

                    Divider()

                    // HiDPI (Retina)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("HiDPI (Retina 2×)")
                                    .font(.system(size: 12, weight: .medium))
                                Text("SHARP TEXT")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                                    .foregroundColor(.secondary)
                            }
                            Text("Renders desktop at 2× pixel density for crisp typography.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.hiDPI)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(settings.isRunning)
                    }

                    Divider()

                    // HDR Mode with live status pill
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("HDR Dynamic Range")
                                .font(.system(size: 12, weight: .medium))
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(hdrStatusBadgeColor)
                                    .frame(width: 6, height: 6)
                                Text(hdrStatusBadgeText)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(hdrStatusBadgeColor)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(hdrStatusBadgeColor.opacity(0.12)))

                            Spacer()

                            Picker("", selection: $settings.hdrMode) {
                                Text("Auto").tag(HDRMode.auto)
                                Text("On").tag(HDRMode.on)
                                Text("Off").tag(HDRMode.off)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 156)
                        }
                        Text(hdrHint)
                            .font(.system(size: 10))
                            .foregroundColor(ScreenCapture.captureSupportsHDR || settings.hdrMode == .off ? .secondary : .orange)
                    }

                    Divider()

                    // Rotation & Mirroring
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Orientation & Mirroring")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            if settings.matchDevice {
                                Text("Follows phone sensor")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.accentColor)
                            } else if settings.rotation == 90 || settings.rotation == 270 {
                                Text("Portrait (\(settings.rotation)°)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.accentColor)
                            } else {
                                Text("Landscape (\(settings.rotation)°)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                                    .frame(width: 96, height: 68)

                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1.5)
                                    )
                                    .frame(width: 68, height: 42)
                                    .scaleEffect(
                                        x: settings.flipHorizontal ? -1 : 1,
                                        y: settings.flipVertical ? -1 : 1
                                    )
                                    .rotationEffect(.degrees(Double(settings.rotation)))

                                Text(settings.rotation == 90 || settings.rotation == 270 ? "Portrait" : "Landscape")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }

                            HStack(spacing: 6) {
                                RotationButton(degrees: 0, label: "0°", isSelected: settings.rotation == 0) {
                                    settings.rotation = 0
                                }
                                RotationButton(degrees: 90, label: "90°", isSelected: settings.rotation == 90) {
                                    settings.rotation = 90
                                }
                                RotationButton(degrees: 180, label: "180°", isSelected: settings.rotation == 180) {
                                    settings.rotation = 180
                                }
                                RotationButton(degrees: 270, label: "270°", isSelected: settings.rotation == 270) {
                                    settings.rotation = 270
                                }
                            }
                            .disabled(settings.matchDevice)
                            .opacity(settings.matchDevice ? 0.5 : 1)
                        }

                        HStack(spacing: 12) {
                            HStack {
                                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Text("Flip Horizontal")
                                    .font(.system(size: 11))
                                Spacer()
                                Toggle("", isOn: $settings.flipHorizontal)
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .labelsHidden()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))

                            HStack {
                                Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Text("Flip Vertical")
                                    .font(.system(size: 11))
                                Spacer()
                                Toggle("", isOn: $settings.flipVertical)
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .labelsHidden()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                        }
                    }
                }
            },
            trailing: {
                Button(action: {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.displays?displayArrangement")!
                    )
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.connected.to.line.below")
                            .font(.system(size: 11))
                        Text("Arrange Displays…")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        )
    }

    // MARK: - Refresh Rate Card

    private var refreshRateCard: some View {
        FrostedGroupBox(
            title: "Refresh Rate",
            icon: "speedometer",
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach([30, 60, 90, 120], id: \.self) { rate in
                            BitrateButton(
                                label: "\(rate) Hz",
                                value: rate,
                                currentValue: settings.refreshRate,
                                disabled: false
                            ) {
                                settings.refreshRate = rate
                            }
                        }
                    }

                    // Custom rate (issue #41): budget tablets can be
                    // artifact-free below a preset but not at it —
                    // let users find their panel's sweet spot.
                    HStack(spacing: 8) {
                        Text("Custom")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(settings.refreshRate) },
                                set: {
                                    let rate = Int($0.rounded())
                                    // Same-value stores still fire didSet +
                                    // UserDefaults writes — skip them.
                                    if rate != settings.refreshRate {
                                        settings.refreshRate = rate
                                    }
                                }
                            ),
                            in: 15...120,
                            step: 1
                        )
                        Text("15–120 Hz")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    if settings.refreshRate >= 90 {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                            Text("High refresh rate for ultra-smooth motion and low frame latency")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.green)
                    } else if ![30, 60].contains(settings.refreshRate) {
                        Text("Custom rate — handy when a tablet shows artifacts above a certain FPS")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            },
            trailing: {
                Text("\(settings.effectiveRefreshRate) Hz")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        )
    }

    // MARK: - Streaming Settings Card

    private var streamingSettingsCard: some View {
        FrostedGroupBox(
            title: "Streaming & Encoding",
            icon: "antenna.radiowaves.left.and.right",
            content: {
                VStack(alignment: .leading, spacing: 14) {
                    // Bitrate
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Target Bitrate")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            if settings.gamingBoost {
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 9))
                                    Text("Locked in Low Latency Mode")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundColor(.cyan)
                            }
                        }

                        HStack(spacing: 6) {
                            ForEach([50, 80, 100, 150, 300], id: \.self) { value in
                                BitrateButton(
                                    label: "\(value)",
                                    value: value,
                                    currentValue: settings.bitrate,
                                    disabled: settings.gamingBoost
                                ) {
                                    settings.bitrate = value
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Text("20")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            Slider(
                                value: Binding(
                                    get: { Double(settings.bitrate) },
                                    set: { settings.bitrate = Int($0) }
                                ),
                                in: 20...500,
                                step: 5
                            )
                            .disabled(settings.gamingBoost)
                            Text("500")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }

                        if !settings.gamingBoost {
                            Text("USB: 80 Mbps for 120 fps on foldables, 50 for 1080p phones. Wi-Fi: 40–60 Mbps at 120 fps, 25–30 at 60.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // Quality Preset
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Encoder Latency / Quality")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            if settings.gamingBoost || settings.quality == "ultralow" {
                                Text("Fastest encode · lowest latency")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.green)
                            }
                        }

                        Picker("", selection: $settings.quality) {
                            Text("Ultra Low").tag("ultralow")
                            Text("Low").tag("low")
                            Text("Medium").tag("medium")
                            Text("High").tag("high")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(settings.gamingBoost)
                    }
                }
            },
            trailing: {
                Text("\(settings.effectiveBitrate) Mbps")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        )
    }

    // MARK: - Touch & Network Card

    private var touchAndNetworkCard: some View {
        FrostedGroupBox(title: "Input & Network", icon: "hand.tap") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Touch Input")
                            .font(.system(size: 12, weight: .medium))
                        Text(
                            settings.touchEnabled
                                ? "Tap, drag, pinch, and scroll on your Mac from the tablet"
                                : "Touch input is disabled — tablet is display-only"
                        )
                        .font(.system(size: 10))
                        .foregroundColor(settings.touchEnabled ? .secondary : .orange)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.touchEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Server Port")
                                .font(.system(size: 12, weight: .medium))
                            Text("TCP listener port for USB and Wireless sessions")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        TextField("Port", value: $settings.port, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 84)
                            .disabled(settings.isRunning)
                    }

                    if settings.isRunning {
                        Text("Stop server to change port")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    } else if settings.connectionMode == .wireless {
                        Text("Changing the port invalidates existing pairings — re-scan the QR on each tablet.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else if settings.port != 54321 {
                        Text("Custom port set — Android client must use the same port.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Startup Card

    private var startupCard: some View {
        FrostedGroupBox(title: "Startup & Automation", icon: "power") {
            VStack(alignment: .leading, spacing: 12) {
                if #available(macOS 13.0, *) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")
                                .font(.system(size: 12, weight: .medium))
                            Text("Run SideScreen in the background automatically after you log in.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { daemonEnabled },
                            set: { newValue in
                                do {
                                    if newValue {
                                        try DaemonManager.shared.enable()
                                    } else {
                                        try DaemonManager.shared.disable()
                                    }
                                } catch {
                                    print("Daemon toggle failed: \(error)")
                                }
                                daemonEnabled = DaemonManager.shared.isEnabled
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    Divider()
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-start streaming on launch")
                            .font(.system(size: 12, weight: .medium))
                        Text("Start the server automatically when the app opens, so the tablet can connect hands-free.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.autoStartStreamingOnLaunch)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Startup mode")
                            .font(.system(size: 12, weight: .medium))
                        Text("Which connection mode to start in when auto-starting.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $settings.startupMode) {
                        Text("USB").tag(ConnectionMode.usb)
                        Text("Wireless").tag(ConnectionMode.wireless)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(!settings.autoStartStreamingOnLaunch)
                }
            }
        }
        .onAppear {
            if #available(macOS 13.0, *) {
                daemonEnabled = DaemonManager.shared.isEnabled
            }
        }
    }

    // MARK: - Status & Permissions Card

    private var statusAndPermissionsCard: some View {
        FrostedGroupBox(title: "Diagnostics & Permissions", icon: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 10) {
                StatusRow(
                    title: "Virtual Display",
                    status: settings.displayCreated ? "Active" : "Inactive",
                    color: settings.displayCreated ? .green : .secondary,
                    hint: "The macOS virtual display we render into. Created when you click Start; the tablet streams its pixels."
                )
                StatusRow(
                    title: "Client Connected",
                    status: settings.clientConnected ? "Yes" : "No",
                    color: settings.clientConnected ? .green : .secondary,
                    hint: "Whether the Android client app currently has an active stream session."
                )
                StatusRow(
                    title: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
                        ? "Screen & System Audio"
                        : "Screen Recording",
                    status: settings.hasScreenRecordingPermission ? "Granted" : "Required",
                    color: settings.hasScreenRecordingPermission ? .green : .red,
                    hint: "macOS privacy permission required to capture the virtual display. Grant in System Settings → Privacy & Security → Screen Recording."
                )
                StatusRow(
                    title: "Accessibility",
                    status: settings.hasAccessibilityPermission ? "Granted" : "Optional",
                    color: settings.hasAccessibilityPermission ? .green : .orange,
                    hint: "Optional permission. Required only if you want touch/tap input from the tablet to control the Mac. Streaming works without it."
                )
                if settings.isRunning {
                    StatusRow(
                        title: "Capture Method",
                        status: settings.captureMethod,
                        color: settings.captureMethod.contains("fallback") ? .orange : .green,
                        hint: "Which macOS API is currently capturing the virtual display. SCStream is the modern path; CGDisplayStream fallback activates if SCStream fails (e.g. on certain virtual display configs)."
                    )
                    StatusRow(
                        title: "Stream format",
                        status: settings.streamFormatDescription.isEmpty ? "Waiting for client" : settings.streamFormatDescription,
                        color: settings.streamFormatDescription.isEmpty ? .secondary : .green,
                        hint: "Dynamic range, bit depth, frame rate and encoded size of the stream the connected device receives."
                    )
                }

                // Mode-aware contextual rows
                Divider().padding(.vertical, 2)
                if settings.connectionMode == .usb {
                    StatusRow(
                        title: "ADB installed",
                        status: settings.adbInstalled ? "Installed" : "Missing",
                        color: settings.adbInstalled ? .green : .red,
                        hint: "USB mode tunnels the TCP stream through the cable using `adb reverse`. Requires the `adb` command on the Mac. Searched paths: Homebrew, /usr/local/bin, ~/Library/Android/sdk/platform-tools, and PATH (`which adb`)."
                    )
                    if !settings.adbInstalled {
                        Text("brew install android-platform-tools")
                            .font(.system(size: 10, design: .monospaced))
                            .padding(6)
                            .background(Color.black.opacity(0.08))
                            .cornerRadius(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    StatusRow(
                        title: "ADB reverse",
                        status: settings.adbReverseConfigured ? "OK" : "Pending",
                        color: settings.adbReverseConfigured ? .green : .orange,
                        hint: "Whether `adb reverse tcp:\(settings.port) tcp:\(settings.port)` is currently configured. The Mac app sets this up automatically when you click Start. Goes green within ~2 seconds after the tablet is plugged in and authorized."
                    )
                    StatusRow(
                        title: "USB device",
                        status: settings.usbDeviceConnected ? "Detected" : "Not detected",
                        color: settings.usbDeviceConnected ? .green : .red,
                        hint: "An Android device authorized for ADB and visible to your Mac. Plug in via USB-C and tap Allow on the device's USB debugging prompt."
                    )
                } else {
                    StatusRow(
                        title: "WiFi",
                        status: settings.wifiConnected ? "Connected" : "Disconnected",
                        color: settings.wifiConnected ? .green : .red,
                        hint: "Whether the Mac currently has a working internet route. Wireless mode requires the Mac to be on a WiFi (or Ethernet) network — the same network the tablet is on."
                    )
                    StatusRow(
                        title: "Listening on",
                        status: settings.listeningAddress.map { "\($0):\(settings.port)" } ?? "—",
                        color: settings.listeningAddress != nil ? .green : .secondary,
                        hint: "The LAN address the tablet must reach. The QR code embeds this exact host:port — if it changes (e.g. you switch WiFi), re-scan the new QR on the tablet."
                    )
                }

                if !settings.hasScreenRecordingPermission {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(
                                ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
                                    ? "Screen & System Audio Recording Required"
                                    : "Screen Recording Required"
                            )
                            .font(.system(size: 12, weight: .semibold))
                        }
                        Text(
                            ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
                                ? "Required to capture the virtual display. Go to System Settings > Privacy & Security > Screen & System Audio Recording."
                                : "Required to capture the virtual display."
                        )
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        Button(action: {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                            )
                        }) {
                            HStack {
                                Image(systemName: "gear")
                                Text("Open System Settings")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                if !settings.displaysHaveSeparateSpaces {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Tablet goes black in fullscreen apps")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text("\"Displays have separate Spaces\" is turned off, so macOS blanks every other display — including the tablet — whenever an app enters fullscreen. Turn it on in System Settings → Desktop & Dock → Mission Control, then log out and back in.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(action: {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!
                            )
                        }) {
                            HStack {
                                Image(systemName: "gear")
                                Text("Open System Settings")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                if !settings.hasAccessibilityPermission {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap.fill")
                                .foregroundColor(.blue)
                            Text("Enable Touch Control")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text("Grant Accessibility permission so touches on your tablet control the Mac cursor.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Button(action: {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            )
                        }) {
                            HStack {
                                Image(systemName: "gear")
                                Text("Open Settings")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(8)
                }
            }
        }
    }

    // MARK: - Footer Bar

    private var footerSection: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

            HStack(spacing: 12) {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        settings.toggleServer()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: settings.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(settings.isRunning ? "Stop Server" : "Start Server")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(settings.isRunning ? Color.red : Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!settings.hasScreenRecordingPermission)
                .opacity(settings.hasScreenRecordingPermission ? 1.0 : 0.5)

                if settings.isRunning {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(settings.clientConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                            .overlay {
                                Circle()
                                    .stroke((settings.clientConnected ? Color.green : Color.orange).opacity(0.3), lineWidth: 2)
                                    .scaleEffect(1.5)
                            }
                        Text(
                            settings.clientConnected
                                ? String(format: "Streaming · %.0f fps · %.1f Mbps", settings.currentFPS, settings.currentBitrate)
                                : "Running on port \(settings.port)"
                        )
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background {
                        Capsule().fill(.ultraThinMaterial)
                            .overlay {
                                Capsule().strokeBorder(
                                    (settings.clientConnected ? Color.green : Color.orange).opacity(0.25),
                                    lineWidth: 1
                                )
                            }
                    }
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Text("Ready to start on port \(settings.port)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Restart button
                Button(action: {
                    restartApp()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .background {
                            Circle().fill(.ultraThinMaterial)
                                .overlay {
                                    Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                }
                        }
                }
                .buttonStyle(.plain)
                .help("Restart App")

                // Quit button
                Button(action: {
                    NSApp.terminate(nil)
                }) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .background {
                            Circle().fill(.ultraThinMaterial)
                                .overlay {
                                    Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                }
                        }
                }
                .buttonStyle(.plain)
                .help("Quit Side Screen (⌘Q)")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }

    /// Restart the app by launching a new instance and terminating current one
    private func restartApp() {
        // Get the app bundle path
        guard let appPath = Bundle.main.bundlePath as String? else {
            print("❌ Could not get app path")
            return
        }

        // Use Process to launch a new instance after a short delay
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5 && open \"\(appPath)\""]

        do {
            try task.run()
            // Terminate current app
            NSApp.terminate(nil)
        } catch {
            print("❌ Failed to restart: \(error)")
        }
    }
}

// MARK: - Supporting Views

struct HeaderStatusBadge: View {
    let icon: String
    let label: String
    let tint: Color
    var isPulsing = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: isPulsing ? 7 : 9, weight: .semibold))
                .foregroundColor(tint)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                }
        }
    }
}

struct LowLatencyMetricPill: View {
    let icon: String
    let title: String
    let subtitle: String
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isActive ? .cyan : .secondary)
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(isActive ? .primary : .secondary)
            }
            Text(subtitle)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.cyan.opacity(0.10) : Color.primary.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isActive ? Color.cyan.opacity(0.28) : Color.primary.opacity(0.06),
                            lineWidth: 1
                        )
                }
        }
    }
}

struct StatusRow: View {
    let title: String
    let status: String
    let color: Color
    var hint: String?
    @State private var showHint = false
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            if let hint = hint {
                Button(action: { showHint.toggle() }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(hovering ? .accentColor : .secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(hint)
                .popover(isPresented: $showHint, arrowEdge: .top) {
                    Text(hint)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 280, alignment: .leading)
                        .padding(12)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(status)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
        }
    }
}

struct ResolutionRow: View {
    let resolution: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(resolution.replacingOccurrences(of: "x", with: " × "))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .monospaced))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct BitrateButton: View {
    let label: String
    let value: Int
    let currentValue: Int
    let disabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var isSelected: Bool { currentValue == value }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor)
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            }
                    }
                }
                .foregroundColor(isSelected ? .white : (disabled ? .secondary : .primary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { isHovered = $0 }
    }
}

struct RotationButton: View {
    let degrees: Int
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5)
                    .frame(
                        width: degrees == 90 || degrees == 270 ? 14 : 22,
                        height: degrees == 90 || degrees == 270 ? 22 : 14
                    )

                Text(label)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular, design: .rounded))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Display Settings

/// The settings that decide the display transform, as a value the server's
/// network queue and encoder threads can hold (they must not read `@Published`).
struct DisplayTransformSettings: Equatable {
    var matchDevice = true
    var rotation = 0
    var flipHorizontal = false
    var flipVertical = false

    /// The client owns orientation only while matching the device AND it
    /// advertised its panel (type 15); old clients keep the host rotation.
    func clientOwnsOrientation(clientAdvertisesPanel: Bool) -> Bool {
        matchDevice && clientAdvertisesPanel
    }

    /// Rotation the host applies to the desktop and announces in the display
    /// transform: none while the client owns orientation.
    func hostRotation(clientAdvertisesPanel: Bool) -> Int {
        clientOwnsOrientation(clientAdvertisesPanel: clientAdvertisesPanel) ? 0 : rotation
    }
}

class DisplaySettings: ObservableObject {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "SideScreen_"

    @Published var resolution: String {
        didSet { save("resolution", resolution) }
    }
    @Published var refreshRate: Int {
        didSet { save("refreshRate", refreshRate) }
    }
    @Published var hiDPI: Bool {
        didSet { save("hiDPI", hiDPI) }
    }
    @Published var bitrate: Int {
        didSet { save("bitrate", bitrate) }
    }
    @Published var quality: String {
        didSet { save("quality", quality) }
    }
    @Published var gamingBoost: Bool {
        didSet { save("gamingBoost", gamingBoost) }
    }
    @Published var port: UInt16 {
        didSet { save("port", Int(port)) }
    }
    @Published var rotation: Int {
        didSet { save("rotation", rotation) }
    }
    @Published var flipHorizontal: Bool {
        didSet { save("flipHorizontal", flipHorizontal) }
    }
    @Published var flipVertical: Bool {
        didSet { save("flipVertical", flipVertical) }
    }
    @Published var showAllResolutions: Bool {
        didSet { save("showAllResolutions", showAllResolutions) }
    }
    @Published var customWidth: Int {
        didSet { save("customWidth", customWidth) }
    }
    @Published var customHeight: Int {
        didSet { save("customHeight", customHeight) }
    }
    @Published var touchEnabled: Bool {
        didSet { save("touchEnabled", touchEnabled) }
    }
    @Published var connectionMode: ConnectionMode {
        didSet { save("connectionMode", connectionMode.rawValue) }
    }
    @Published var autoStartStreamingOnLaunch: Bool {
        didSet { save("autoStartStreamingOnLaunch", autoStartStreamingOnLaunch) }
    }
    @Published var startupMode: ConnectionMode {
        didSet { save("startupMode", startupMode.rawValue) }
    }
    /// HDR streaming preference (HDR10 needs host HDR capture, a Main10 decoder
    /// and an HDR10 panel on the client; `.auto` requires all three).
    @Published var hdrMode: HDRMode {
        didSet { save("hdrMode", hdrMode.rawValue) }
    }
    /// Size the virtual display to the client's presentation area (type 15)
    /// and let the client own orientation; the resolution list and rotation
    /// picker are ignored while on.
    @Published var matchDevice: Bool {
        didSet { save("matchDevice", matchDevice) }
    }

    // Runtime state (not persisted)
    @Published var displayCreated = false
    @Published var clientConnected = false
    /// Device name of the wireless client currently streaming (nil when none).
    /// WirelessSection reads this to show a "Connected" badge on the matching row.
    @Published var currentWirelessDevice: String?
    /// One-time wireless pairing code (issue #35). Non-nil only while the
    /// server is running in wireless mode; never persisted.
    @Published var pairingCode: String?
    @Published var hasScreenRecordingPermission = false
    @Published var hasAccessibilityPermission = false
    /// Mirrors `NSScreen.screensHaveSeparateSpaces`. When the user has turned
    /// off "Displays have separate Spaces", macOS blanks every other display
    /// (including our virtual one) whenever any app goes fullscreen — the
    /// tablet shows black while the stream keeps flowing (issue #50). The
    /// setting only takes effect after logout, so this is a per-session fact.
    @Published var displaysHaveSeparateSpaces = true
    @Published var adbInstalled = false
    @Published var adbReverseConfigured = false
    @Published var usbDeviceConnected = false
    @Published var wifiConnected = false
    @Published var listeningAddress: String?
    @Published var isRunning = false
    @Published var currentFPS: Double = 0
    @Published var currentBitrate: Double = 0
    @Published var captureMethod: String = "Initializing..."
    /// Live stream format, e.g. "HDR10 · 10-bit · 120 fps · 2340×1080"; empty when stopped.
    @Published var streamFormatDescription = ""

    var onToggleServer: (() -> Void)?

    init() {
        self.resolution = defaults.string(forKey: keyPrefix + "resolution") ?? "1920x1200"
        // Fresh installs: 120 Hz, HiDPI, 80 Mbps (sized for 120 fps on large
        // foldables over USB). Existing users keep their saved values.
        self.refreshRate = defaults.object(forKey: keyPrefix + "refreshRate") as? Int ?? 120
        self.hiDPI = defaults.object(forKey: keyPrefix + "hiDPI") as? Bool ?? true
        self.bitrate = defaults.object(forKey: keyPrefix + "bitrate") as? Int ?? 80
        self.quality = defaults.string(forKey: keyPrefix + "quality") ?? "ultralow"  // Default: fastest encoding
        self.gamingBoost = defaults.bool(forKey: keyPrefix + "gamingBoost")
        // Default port 54321 (was 8888 in <=0.7.1; 8888 collides with jupyter/splunk/HP printers).
        // Existing users keep their saved value.
        self.port = UInt16(defaults.object(forKey: keyPrefix + "port") as? Int ?? 54321)
        self.rotation = defaults.object(forKey: keyPrefix + "rotation") as? Int ?? 0
        self.flipHorizontal = defaults.bool(forKey: keyPrefix + "flipHorizontal")
        self.flipVertical = defaults.bool(forKey: keyPrefix + "flipVertical")
        self.showAllResolutions = defaults.bool(forKey: keyPrefix + "showAllResolutions")
        self.customWidth = defaults.object(forKey: keyPrefix + "customWidth") as? Int ?? 1920
        self.customHeight = defaults.object(forKey: keyPrefix + "customHeight") as? Int ?? 1200
        self.touchEnabled = defaults.object(forKey: keyPrefix + "touchEnabled") as? Bool ?? true
        let modeRaw = defaults.string(forKey: keyPrefix + "connectionMode") ?? ConnectionMode.usb.rawValue
        self.connectionMode = ConnectionMode(rawValue: modeRaw) ?? .usb
        self.autoStartStreamingOnLaunch = defaults.object(forKey: keyPrefix + "autoStartStreamingOnLaunch") as? Bool ?? false
        let startupRaw = defaults.string(forKey: keyPrefix + "startupMode") ?? modeRaw
        self.startupMode = ConnectionMode(rawValue: startupRaw) ?? .usb
        self.hdrMode = defaults.string(forKey: keyPrefix + "hdrMode").flatMap(HDRMode.init(rawValue:)) ?? .auto
        self.matchDevice = defaults.object(forKey: keyPrefix + "matchDevice") as? Bool ?? true

        print("Loaded settings: \(resolution) @ \(refreshRate)Hz, bitrate=\(bitrate), quality=\(quality), hdr=\(hdrMode.rawValue), matchDevice=\(matchDevice)")
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: keyPrefix + key)
    }

    struct ResolutionGroup: Identifiable {
        let id = UUID()
        let name: String
        let ratio: String
        let resolutions: [String]
    }

    static let resolutionGroups: [ResolutionGroup] = [
        ResolutionGroup(name: "16:10", ratio: "Widescreen", resolutions: [
            "1280x800", "1440x900", "1680x1050", "1920x1200", "2304x1440", "2560x1600"
        ]),
        ResolutionGroup(name: "16:9", ratio: "HD/4K", resolutions: [
            "1280x720", "1366x768", "1600x900", "1920x1080", "2560x1440", "3840x2160"
        ]),
        ResolutionGroup(name: "4:3", ratio: "Classic", resolutions: [
            "1024x768", "1280x960", "1600x1200"
        ]),
        ResolutionGroup(name: "3:2", ratio: "Surface/Pixel", resolutions: [
            "1920x1280", "2160x1440", "2736x1824"
        ]),
        ResolutionGroup(name: "5:3", ratio: "Tablet Wide", resolutions: [
            "2000x1200", "2560x1536", "2800x1680"
        ]),
        ResolutionGroup(name: "4:3", ratio: "iPad", resolutions: [
            "2048x1536", "2224x1668", "2388x1668", "2732x2048"
        ]),
        ResolutionGroup(name: "4:3", ratio: "Foldables", resolutions: [
            "1224x924", "1632x1232", "2448x1848"
        ])
    ]

    static let commonResolutions = [
        "1920x1080", "1920x1200", "2560x1440", "2560x1600"
    ]

    static var allResolutions: [String] {
        resolutionGroups.flatMap { $0.resolutions }
    }

    var effectiveBitrate: Int {
        return gamingBoost ? 150 : bitrate
    }

    var effectiveQuality: String {
        return gamingBoost ? "ultralow" : quality
    }

    var effectiveRefreshRate: Int {
        return gamingBoost ? 120 : refreshRate
    }

    /// Snapshot of the settings that decide the display transform.
    var transformSettings: DisplayTransformSettings {
        DisplayTransformSettings(matchDevice: matchDevice, rotation: rotation,
                                 flipHorizontal: flipHorizontal, flipVertical: flipVertical)
    }

    /// Status text for a stream: "HDR10 · 10-bit · 120 fps · 2340×1080".
    static func describeStreamFormat(_ format: StreamColorFormat, fps: Int, width: Int, height: Int) -> String {
        let range: String
        switch format.transfer {
        case 16: range = "HDR10"
        case 18: range = "HLG"
        default: range = "SDR"
        }
        return "\(range) · \(format.bitDepth)-bit · \(fps) fps · \(width)×\(height)"
    }

    func toggleServer() {
        onToggleServer?()
    }

    func resetToDefaults() {
        let keys = ["resolution", "refreshRate", "hiDPI", "bitrate", "quality",
                    "gamingBoost", "port", "rotation", "flipHorizontal", "flipVertical", "showAllResolutions",
                    "customWidth", "customHeight", "touchEnabled", "autoStartStreamingOnLaunch", "startupMode",
                    "hdrMode", "matchDevice"]
        for key in keys {
            defaults.removeObject(forKey: keyPrefix + key)
        }

        resolution = "1920x1200"
        refreshRate = 120  // Default: highest FPS
        hiDPI = true
        bitrate = 80  // Default: 80 Mbps (120 fps on a large foldable over USB)
        quality = "ultralow"  // Default: fastest encoding
        gamingBoost = false
        port = 54321
        rotation = 0
        flipHorizontal = false
        flipVertical = false
        showAllResolutions = false
        customWidth = 1920
        customHeight = 1200
        touchEnabled = true
        autoStartStreamingOnLaunch = false
        startupMode = .usb
        hdrMode = .auto
        matchDevice = true

        print("Settings reset to defaults")
    }

    /// The configured resolution, rotated as the host rotates the desktop.
    func resolutionSize(clientAdvertisesPanel: Bool) -> (width: Int, height: Int) {
        let parts = resolution.split(separator: "x")
        let baseWidth = Int(parts[0]) ?? 1920
        let baseHeight = Int(parts[1]) ?? 1200
        let rotation = transformSettings.hostRotation(clientAdvertisesPanel: clientAdvertisesPanel)
        if rotation == 90 || rotation == 270 {
            return (baseHeight, baseWidth)
        }
        return (baseWidth, baseHeight)
    }

    static func isValidCustomResolution(width: Int, height: Int) -> Bool {
        width >= 640 && width <= 7680 && height >= 480 && height <= 4320
    }

    func applyCustomResolution() {
        if DisplaySettings.isValidCustomResolution(width: customWidth, height: customHeight) {
            resolution = "\(customWidth)x\(customHeight)"
        }
    }
}

// MARK: - Window Controller

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init(settings: DisplaySettings) {
        let window = ConstrainedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 800),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Side Screen"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen ?? NSScreen.main else { return }

        var frame = window.frame
        let visibleFrame = screen.visibleFrame
        let minVisibleWidth: CGFloat = 100
        let minVisibleHeight: CGFloat = 50

        if frame.maxX < visibleFrame.minX + minVisibleWidth {
            frame.origin.x = visibleFrame.minX - frame.width + minVisibleWidth
        } else if frame.minX > visibleFrame.maxX - minVisibleWidth {
            frame.origin.x = visibleFrame.maxX - minVisibleWidth
        }

        if frame.maxY < visibleFrame.minY + minVisibleHeight {
            frame.origin.y = visibleFrame.minY - frame.height + minVisibleHeight
        } else if frame.minY > visibleFrame.maxY - minVisibleHeight {
            frame.origin.y = visibleFrame.maxY - minVisibleHeight
        }

        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }
}

class ConstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen = screen ?? self.screen ?? NSScreen.main else {
            return frameRect
        }

        var constrainedRect = frameRect
        let visibleFrame = screen.visibleFrame
        let minVisibleWidth: CGFloat = 100
        let minVisibleHeight: CGFloat = 50

        if constrainedRect.maxX < visibleFrame.minX + minVisibleWidth {
            constrainedRect.origin.x = visibleFrame.minX - constrainedRect.width + minVisibleWidth
        } else if constrainedRect.minX > visibleFrame.maxX - minVisibleWidth {
            constrainedRect.origin.x = visibleFrame.maxX - minVisibleWidth
        }

        if constrainedRect.maxY < visibleFrame.minY + minVisibleHeight {
            constrainedRect.origin.y = visibleFrame.minY - constrainedRect.height + minVisibleHeight
        } else if constrainedRect.minY > visibleFrame.maxY - minVisibleHeight {
            constrainedRect.origin.y = visibleFrame.maxY - minVisibleHeight
        }

        return constrainedRect
    }
}

// MARK: - Wireless Section

struct WirelessSection: View {
    @ObservedObject var settings: DisplaySettings
    let pairedDeviceStore: PairedDeviceStore
    @State private var qrImage: NSImage?
    @State private var pairedDevices: [PairedDevice] = []
    @State private var showResetConfirm = false
    /// Used to force the relative-time labels to recompute every tick even when
    /// the underlying lastConnected timestamp hasn't changed (e.g. while a
    /// device is disconnected and we still want "5 minutes ago" to count up).
    @State private var nowTick: Date = Date()

    var body: some View {
        VStack(spacing: 12) {
            if !settings.isRunning {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Click Start Server below to begin listening, then scan the QR code.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Start") {
                        settings.toggleServer()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!settings.hasScreenRecordingPermission)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
                        )
                )
            }

            FrostedGroupBox(title: "Pair Wireless Device", icon: "qrcode") {
                VStack(spacing: 10) {
                    if let qr = qrImage {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 170, height: 170)
                            .padding(10)
                            .background(Color.white)
                            .cornerRadius(12)
                            .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
                    } else {
                        Text("Generating QR…")
                            .foregroundColor(.secondary)
                    }

                    Text("Scan this QR from Side Screen Android (Wireless tab)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(LANAddressResolver.primaryIPv4() != nil ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(
                            LANAddressResolver.primaryIPv4().map { "Listening: \($0):\(settings.port)" }
                                ?? "WiFi disconnected — no LAN address"
                        )
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))

                    if let code = settings.pairingCode {
                        HStack(spacing: 10) {
                            VStack { Divider() }
                            Text("No camera on your tablet?")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .fixedSize()
                            VStack { Divider() }
                        }
                        .padding(.top, 4)

                        Text(PairingCode.display(code))
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .kerning(3)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                            .textSelection(.enabled)

                        Text("Type this one-time code in the Android app instead.\nA new code is issued after each pairing.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            FrostedGroupBox(
                title: "Paired Devices (\(pairedDevices.count))",
                icon: "ipad.and.iphone",
                content: {
                    if pairedDevices.isEmpty {
                        Text("No devices paired yet.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(pairedDevices, id: \.name) { device in
                                let isLive = settings.currentWirelessDevice == device.name
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .font(.system(size: 12, weight: .semibold))
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(isLive ? Color.green : Color.secondary)
                                                .frame(width: 6, height: 6)
                                            Text(
                                                isLive
                                                    ? "Connected"
                                                    : relativeTimeString(from: device.lastConnected, to: nowTick)
                                            )
                                            .font(.system(size: 10))
                                            .foregroundColor(isLive ? .green : .secondary)
                                        }
                                    }
                                    Spacer()
                                    Button("Forget") {
                                        pairedDeviceStore.forget(name: device.name)
                                        refreshPaired()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.primary.opacity(0.04))
                                )
                            }
                        }
                    }
                    Button("Reset Token (forget all)") {
                        showResetConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(.red)
                    .padding(.top, 4)
                },
                trailing: {
                    Button(action: {
                        nowTick = Date()
                        refreshPaired()
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh list and timestamps")
                }
            )
        }
        .onAppear {
            refreshQR()
            refreshPaired()
            nowTick = Date()
        }
        // One-parameter onChange(of:perform:) works on macOS 13+. The
        // two-parameter form requires macOS 14 and would block Ventura.
        // Deprecation is a compile-time warning only on Xcode 15+ SDKs.
        .onChange(of: settings.port) { _ in refreshQR() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { now in
            nowTick = now
            refreshPaired()
        }
        .alert("Reset Token?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                _ = WirelessAuth.reset()
                pairedDeviceStore.clear()
                refreshQR()
                refreshPaired()
            }
        } message: {
            Text("This will disconnect all paired devices. They will need to scan the new QR to connect again.")
        }
    }

    private func refreshQR() {
        let token = WirelessAuth.loadOrCreate()
        let host = LANAddressResolver.primaryIPv4() ?? "0.0.0.0"
        let name = Host.current().localizedName ?? "Mac"
        let url = PairingURL.build(host: host, port: settings.port, token: token, name: name)
        qrImage = QRRenderer.render(url: url, size: 180)
    }

    private func refreshPaired() {
        pairedDevices = pairedDeviceStore.all()
    }

    private func relativeTimeString(from past: Date, to now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(past))
        if elapsed < 30 { return "just now" }
        if elapsed < 60 { return "\(Int(elapsed)) seconds ago" }
        if elapsed < 3600 {
            let m = Int(elapsed / 60)
            return "\(m) minute\(m == 1 ? "" : "s") ago"
        }
        if elapsed < 86400 {
            let h = Int(elapsed / 3600)
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = Int(elapsed / 86400)
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }
}

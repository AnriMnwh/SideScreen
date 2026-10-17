import Foundation
import AppKit
import CoreGraphics
import CGVirtualDisplayBridge

/// Manages virtual display creation and lifecycle using CGVirtualDisplay API
class VirtualDisplayManager {
    private var virtualDisplay: CGVirtualDisplay?
    private var displayDescriptor: CGVirtualDisplayDescriptor?
    private var displaySettings: CGVirtualDisplaySettings?
    private var screenParamsObserver: NSObjectProtocol?

    var displayID: CGDirectDisplayID? {
        return virtualDisplay?.displayID
    }

    var isActive: Bool {
        return virtualDisplay != nil
    }

    /// Whether the live display was created with the HDR (tf=1) mode list.
    private(set) var isHDR = false

    /// Physical pixel size of the live display's anchor mode, nil when none exists.
    var physicalSize: (Int, Int)?
    /// Mode the last create/re-mode asked for, selected explicitly by `applyPlannedMode`.
    private struct PlannedMode { let width: Int, height: Int, hiDPI: Bool, refreshRate: Int }
    private var plannedMode: PlannedMode?

    /// Whether the private HDR mode initializer exists on this OS.
    private static var supportsHDRModes: Bool {
        CGVirtualDisplayMode.instancesRespond(
            to: NSSelectorFromString("initWithWidth:height:refreshRate:transferFunction:"))
    }

    /// Mode list for a logical size; with HiDPI the 2× physical anchor mode comes first.
    private static func makeModes(
        width: Int, height: Int, refreshRate: Int, hiDPI: Bool, hdr: Bool
    ) -> [CGVirtualDisplayMode] {
        func mode(_ w: Int, _ h: Int) -> CGVirtualDisplayMode {
            if hdr {
                return CGVirtualDisplayMode(
                    width: UInt32(w), height: UInt32(h),
                    refreshRate: Double(refreshRate), transferFunction: 1)
            }
            return CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h), refreshRate: Double(refreshRate))
        }
        // HiDPI: anchor mode (physical) + logical mode
        // The anchor tells macOS "this display is high-density" → unlocks HiDPI for logical mode
        // non-HiDPI: single mode at requested resolution
        var modes: [CGVirtualDisplayMode] = []
        if hiDPI { modes.append(mode(width * 2, height * 2)) }
        modes.append(mode(width, height))
        return modes
    }

    /// Create a virtual display with specified configuration
    /// - Parameters:
    ///   - width: Display width in pixels
    ///   - height: Display height in pixels
    ///   - refreshRate: Refresh rate in Hz (default: 60)
    ///   - hiDPI: Enable HiDPI mode (default: false)
    ///   - hdr: Request an HDR/EDR display (tf=1 modes, BT.2020 primaries); falls back to SDR if unsupported
    ///   - name: Display name (default: "Virtual Display")
    func createDisplay(
        width: Int,
        height: Int,
        refreshRate: Int = 60,
        hiDPI: Bool = false,
        hdr: Bool = false,
        name: String = "Virtual Display"
    ) throws {
        // Clean up existing display if any
        destroyDisplay()

        // Physical pixels = 2x logical when HiDPI, 1x otherwise
        let physW = hiDPI ? width * 2 : width
        let physH = hiDPI ? height * 2 : height
        let useHDR = hdr && Self.supportsHDRModes

        // Create display descriptor
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        // Square bounds so later in-place re-modes (rotation, fold switch) fit;
        // applySettings: fails if a new mode exceeds either bound.
        let maxBound = UInt32(min(max(physW, physH, 4096), 8192))
        descriptor.maxPixelsWide = maxBound
        descriptor.maxPixelsHigh = maxBound
        if useHDR {
            descriptor.redPrimary = CGPoint(x: 0.708, y: 0.292)
            descriptor.greenPrimary = CGPoint(x: 0.170, y: 0.797)
            descriptor.bluePrimary = CGPoint(x: 0.131, y: 0.046)
            descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        }

        // HiDPI needs high PPI so macOS recognises as Retina (≥200 PPI threshold)
        // non-HiDPI stays at 110 PPI (typical tablet assumption)
        let ppi: Double = hiDPI ? 220.0 : 110.0
        descriptor.sizeInMillimeters = CGSize(
            width: Double(physW) * 25.4 / ppi,
            height: Double(physH) * 25.4 / ppi
        )

        // Set vendor/product IDs
        // Use width * 10000 + height so (3840,2400) ≠ (2400,3840) — avoids portrait/landscape collision
        descriptor.productID = UInt32((physW * 10000 + physH) & 0xFFFFFFFF)
        descriptor.vendorID = 0xEEEE
        descriptor.serialNum = 0x0001

        self.displayDescriptor = descriptor

        // Create display settings
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = Self.makeModes(width: width, height: height,
                                        refreshRate: refreshRate, hiDPI: hiDPI, hdr: useHDR)

        self.displaySettings = settings

        // Create virtual display
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw VirtualDisplayError.creationFailed("Failed to create CGVirtualDisplay")
        }

        self.virtualDisplay = display

        // Apply settings (`applySettings:` imports into Swift as `apply(_:)`)
        let result = display.apply(settings)
        if !result {
            destroyDisplay()
            throw VirtualDisplayError.settingsApplyFailed("Failed to apply settings")
        }
        self.isHDR = useHDR
        self.physicalSize = (physW, physH)

        plannedMode = PlannedMode(width: width, height: height, hiDPI: hiDPI, refreshRate: refreshRate)
        let modeDesc = hiDPI ? "\(width)x\(height) HiDPI (physical \(physW)x\(physH))" : "\(width)x\(height)"
        debugLog("Virtual display created: \(modeDesc) @ \(refreshRate)Hz\(useHDR ? " HDR" : "") " +
                 "(ID: \(display.displayID))")

        registerScreenParamsObserver()
    }

    /// Re-assert the physical-main invariant on every display-topology change:
    /// WindowServer can re-adopt the virtual display as main from a remembered
    /// arrangement at any point after creation (issue #39), not only during
    /// the one-shot restore — e.g. when a physical display is hot-plugged.
    /// Our own re-arrangement re-fires the notification, but the main-display
    /// guard in ensurePhysicalDisplayStaysMain makes that pass a no-op.
    private func registerScreenParamsObserver() {
        guard screenParamsObserver == nil else { return }
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.ensurePhysicalDisplayStaysMain()
        }
    }

    private func removeScreenParamsObserver() {
        if let token = screenParamsObserver {
            NotificationCenter.default.removeObserver(token)
            screenParamsObserver = nil
        }
    }

    /// Clone the main display configuration
    func cloneMainDisplay() throws {
        guard let mainDisplay = CGMainDisplayID() as CGDirectDisplayID? else {
            throw VirtualDisplayError.mainDisplayNotFound
        }

        let width = Int(CGDisplayPixelsWide(mainDisplay))
        let height = Int(CGDisplayPixelsHigh(mainDisplay))

        // Get refresh rate
        var refreshRate = 60
        if let mode = CGDisplayCopyDisplayMode(mainDisplay) {
            refreshRate = Int(mode.refreshRate)
        }

        try createDisplay(
            width: width,
            height: height,
            refreshRate: refreshRate,
            name: "Virtual Display (Clone)"
        )
    }

    /// Enable mirror mode with main display
    func enableMirrorMode() throws {
        guard let display = virtualDisplay else {
            throw VirtualDisplayError.displayNotCreated
        }

        let mainDisplay = CGMainDisplayID()

        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)

        guard beginResult == CGError.success, let config = config else {
            throw VirtualDisplayError.configurationFailed("Failed to begin display configuration")
        }

        let mirrorResult = CGConfigureDisplayMirrorOfDisplay(
            config,
            display.displayID,
            mainDisplay
        )

        if mirrorResult != CGError.success {
            CGCancelDisplayConfiguration(config)
            throw VirtualDisplayError.mirrorModeFailed("Failed to configure mirror mode: \(mirrorResult)")
        }

        let completeResult = CGCompleteDisplayConfiguration(config, .permanently)

        if completeResult != CGError.success {
            throw VirtualDisplayError.mirrorModeFailed("Failed to complete mirror configuration: \(completeResult)")
        }

        print("✅ Mirror mode enabled")
    }

    /// Disable mirror mode (extend mode)
    func disableMirrorMode() throws {
        guard let display = virtualDisplay else {
            throw VirtualDisplayError.displayNotCreated
        }

        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)

        guard beginResult == CGError.success, let config = config else {
            throw VirtualDisplayError.configurationFailed("Failed to begin display configuration")
        }

        // Setting mirror to kCGNullDirectDisplay disables mirroring
        let mirrorResult = CGConfigureDisplayMirrorOfDisplay(
            config,
            display.displayID,
            CGDirectDisplayID(kCGNullDirectDisplay)
        )

        if mirrorResult != CGError.success {
            CGCancelDisplayConfiguration(config)
            throw VirtualDisplayError.mirrorModeFailed("Failed to disable mirror mode: \(mirrorResult)")
        }

        let completeResult = CGCompleteDisplayConfiguration(config, .permanently)

        if completeResult != CGError.success {
            throw VirtualDisplayError.mirrorModeFailed("Failed to complete configuration: \(completeResult)")
        }

        print("✅ Extend mode enabled (mirror disabled)")
    }

    /// Get current display position (origin)
    func getDisplayPosition() -> CGPoint? {
        guard let displayID = displayID else { return nil }
        let bounds = CGDisplayBounds(displayID)
        return bounds.origin
    }

    /// Set display position in arrangement
    func setDisplayPosition(x: Int32, y: Int32) throws {
        guard let display = virtualDisplay else {
            throw VirtualDisplayError.displayNotCreated
        }

        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)

        guard beginResult == CGError.success, let config = config else {
            throw VirtualDisplayError.configurationFailed("Failed to begin display configuration")
        }

        let originResult = CGConfigureDisplayOrigin(config, display.displayID, x, y)

        if originResult != CGError.success {
            CGCancelDisplayConfiguration(config)
            throw VirtualDisplayError.configurationFailed("Failed to set display origin: \(originResult)")
        }

        // Session-scoped on purpose: position is persisted via UserDefaults, and
        // baking the virtual display into WindowServer's permanent prefs lets the
        // system re-adopt it as main on later startups (#39).
        let completeResult = CGCompleteDisplayConfiguration(config, .forSession)

        if completeResult != CGError.success {
            throw VirtualDisplayError.configurationFailed("Failed to complete configuration: \(completeResult)")
        }

        print("📍 Display position set to (\(x), \(y))")
    }

    /// Save current display position to UserDefaults
    func saveDisplayPosition() {
        guard let position = getDisplayPosition() else { return }
        let defaults = UserDefaults.standard
        defaults.set(Int(position.x), forKey: "SideScreen_positionX")
        defaults.set(Int(position.y), forKey: "SideScreen_positionY")
        defaults.set(true, forKey: "SideScreen_hasPosition")
        print("💾 Saved display position: (\(Int(position.x)), \(Int(position.y)))")
    }

    /// Restore saved display position
    func restoreDisplayPosition() {
        // Run the main-display safety net on every path, including early
        // returns: WindowServer can re-adopt the virtual display as main from
        // its own remembered arrangement even when we restore nothing (#39).
        defer { ensurePhysicalDisplayStaysMain() }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "SideScreen_hasPosition") else {
            print("📍 No saved display position found")
            return
        }

        let x = defaults.integer(forKey: "SideScreen_positionX")
        let y = defaults.integer(forKey: "SideScreen_positionY")

        // A position saved while the tablet was the Mac's only screen is the
        // main slot (0,0). Re-applying it with a physical display attached
        // moves the menu bar and all input focus onto a screen that may not be
        // visible anywhere — e.g. right after the tablet was unpaired (#39).
        if x == 0 && y == 0 && !onlinePhysicalDisplays().isEmpty {
            print("🛟 Skipping saved main-slot position — a physical display is attached")
            return
        }

        do {
            try setDisplayPosition(x: Int32(x), y: Int32(y))
            print("📍 Restored display position: (\(x), \(y))")
        } catch {
            print("⚠️  Failed to restore display position: \(error)")
        }
    }

    /// Online displays other than this virtual display. Filters by the vendor
    /// ID our descriptor registers (0xEEEE) so a stale SideScreen display from
    /// a previous instance is not mistaken for a physical screen.
    private func onlinePhysicalDisplays() -> [CGDirectDisplayID] {
        var online = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &online, &count) == .success else { return [] }
        return online.prefix(Int(count)).filter { id in
            id != displayID && CGDisplayVendorNumber(id) != 0xEEEE
        }
    }

    /// Safety net for #39: whenever at least one physical display is online,
    /// the main slot (0,0) must belong to a physical display, never to the
    /// virtual one. Otherwise the menu bar, dock, and keyboard focus land on a
    /// screen nobody can see, which presents as a completely unresponsive Mac.
    /// No-ops in true headless operation (no physical display online).
    func ensurePhysicalDisplayStaysMain() {
        guard let displayID = displayID else { return }
        guard CGMainDisplayID() == displayID,
              let physicalMain = onlinePhysicalDisplays().first else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == CGError.success, let config = config else { return }

        // Give the physical display the main slot and park the virtual display
        // to its right.
        let physicalWidth = Int32(CGDisplayBounds(physicalMain).width)
        var result = CGConfigureDisplayOrigin(config, physicalMain, 0, 0)
        if result == CGError.success {
            result = CGConfigureDisplayOrigin(config, displayID, physicalWidth, 0)
        }
        guard result == CGError.success else {
            CGCancelDisplayConfiguration(config)
            print("⚠️  Failed to rearrange displays: \(result)")
            return
        }

        if CGCompleteDisplayConfiguration(config, .forSession) == CGError.success {
            print("🛟 Physical display restored as main — virtual display parked beside it")
        }
    }

    /// Verify the virtual display is registered in the system display list
    func verifyDisplayRegistered() -> Bool {
        guard let displayID = displayID else {
            debugLog("verifyDisplayRegistered: no displayID set")
            return false
        }

        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        let err = CGGetOnlineDisplayList(16, &onlineDisplays, &displayCount)

        guard err == .success else {
            debugLog("verifyDisplayRegistered: CGGetOnlineDisplayList failed with \(err)")
            return false
        }

        let onlineIDs = Array(onlineDisplays.prefix(Int(displayCount)))
        let found = onlineIDs.contains(displayID)
        debugLog("verifyDisplayRegistered: displayID \(displayID) \(found ? "FOUND" : "NOT FOUND") in online displays \(onlineIDs)")
        return found
    }

    /// Re-mode the live display in place (same displayID, no destroy/recreate).
    /// Keeps the transfer function chosen at creation. Returns false when there is
    /// no display, the requested size exceeds the descriptor's pixel bounds, the
    /// apply fails, or the display does not report the new mode within 500 ms.
    func reconfigure(width: Int, height: Int, refreshRate: Int, hiDPI: Bool) -> Bool {
        guard let display = virtualDisplay, let descriptor = displayDescriptor else { return false }
        let physW = hiDPI ? width * 2 : width
        let physH = hiDPI ? height * 2 : height
        guard physW > 0, physH > 0,
              UInt32(physW) <= descriptor.maxPixelsWide,
              UInt32(physH) <= descriptor.maxPixelsHigh else { return false }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = Self.makeModes(width: width, height: height,
                                        refreshRate: refreshRate, hiDPI: hiDPI, hdr: isHDR)
        guard display.apply(settings) else { return false }
        displaySettings = settings
        physicalSize = (physW, physH)
        plannedMode = PlannedMode(width: width, height: height, hiDPI: hiDPI, refreshRate: refreshRate)

        // WindowServer adopts its own default (the largest point size) after apply, so pick the
        // exact points/pixels mode, then read it back rather than assuming it was adopted.
        let id = display.displayID
        guard Self.selectMode(displayID: id, width: width, height: height,
                              hiDPI: hiDPI, refreshRate: refreshRate) else { return false }
        let deadline = Date().addingTimeInterval(0.5)
        while true {
            if let mode = CGDisplayCopyDisplayMode(id),
               Self.modeMatches(size: (mode.width, mode.height), pixels: (mode.pixelWidth, mode.pixelHeight),
                                requested: (width, height), hiDPI: hiDPI) {
                debugLog("Virtual display re-moded: \(width)x\(height)\(hiDPI ? " HiDPI" : "") " +
                         "@ \(refreshRate)Hz (ID: \(id))")
                return true
            }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Selects the exact mode `createDisplay` asked for. WindowServer otherwise adopts its own
    /// default (the largest point size: e.g. 1920×1080@2× for a 960×540 HiDPI request).
    /// Call off the main thread once the display is online: it blocks, and WindowServer needs
    /// the main run loop to publish the new display's mode list.
    func applyPlannedMode() -> Bool {
        guard let id = displayID, let plan = plannedMode else { return false }
        return Self.selectMode(displayID: id, width: plan.width, height: plan.height,
                               hiDPI: plan.hiDPI, refreshRate: plan.refreshRate)
    }

    /// Switches `displayID` to the mode showing `width`×`height` points at 2× (HiDPI) or 1×
    /// pixels, closest to `refreshRate`. Waits up to 1 s for WindowServer to publish the mode
    /// list after an apply. Blocks the calling thread for the mode switch (~300 ms measured on
    /// macOS 27). Returns false when no such mode appears or the switch fails.
    @discardableResult
    static func selectMode(displayID: CGDirectDisplayID, width: Int, height: Int,
                           hiDPI: Bool, refreshRate: Int) -> Bool {
        let scale = hiDPI ? 2 : 1
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let deadline = Date().addingTimeInterval(1.0)
        while true {
            let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
            let target = modes
                .filter {
                    $0.width == width && $0.height == height &&
                        $0.pixelWidth == width * scale && $0.pixelHeight == height * scale
                }
                .min { abs($0.refreshRate - Double(refreshRate)) < abs($1.refreshRate - Double(refreshRate)) }
            if let target {
                if let current = CGDisplayCopyDisplayMode(displayID),
                   current.width == width, current.height == height,
                   current.pixelWidth == target.pixelWidth, current.pixelHeight == target.pixelHeight,
                   abs(current.refreshRate - target.refreshRate) < 0.5 {
                    return true
                }
                let error = CGDisplaySetDisplayMode(displayID, target, nil)
                if error != .success { debugLog("CGDisplaySetDisplayMode failed: \(error.rawValue)") }
                return error == .success
            }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Whether a read-back mode is the one `reconfigure` requested: the logical size must match,
    /// and HiDPI additionally needs the 2× pixel size (WindowServer also offers 1× modes whose
    /// pixel count equals a 2× request, e.g. 1920×1080@1x vs 960×540@2x).
    static func modeMatches(size: (width: Int, height: Int), pixels: (width: Int, height: Int),
                            requested: (width: Int, height: Int), hiDPI: Bool) -> Bool {
        guard size.width == requested.width, size.height == requested.height else { return false }
        let scale = hiDPI ? 2 : 1
        return pixels.width == requested.width * scale && pixels.height == requested.height * scale
    }

    /// Destroy the virtual display
    func destroyDisplay() {
        removeScreenParamsObserver()
        if virtualDisplay != nil {
            virtualDisplay = nil
            displayDescriptor = nil
            displaySettings = nil
            physicalSize = nil
            isHDR = false
            print("🗑️  Virtual display destroyed")
        }
    }

    deinit {
        destroyDisplay()
    }
}

// MARK: - Error Types
enum VirtualDisplayError: Error, LocalizedError {
    case creationFailed(String)
    case settingsApplyFailed(String)
    case displayNotCreated
    case mainDisplayNotFound
    case configurationFailed(String)
    case mirrorModeFailed(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let msg):
            return "Virtual display creation failed: \(msg)"
        case .settingsApplyFailed(let msg):
            return "Settings apply failed: \(msg)"
        case .displayNotCreated:
            return "Virtual display has not been created"
        case .mainDisplayNotFound:
            return "Main display not found"
        case .configurationFailed(let msg):
            return "Display configuration failed: \(msg)"
        case .mirrorModeFailed(let msg):
            return "Mirror mode operation failed: \(msg)"
        }
    }
}

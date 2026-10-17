import Foundation
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics
import CoreVideo
import IOSurface
import IOKit.pwr_mgt
import os

// MARK: - SCStreamDelegate

private class StreamDelegate: NSObject, SCStreamDelegate {
    /// Receives the failing stream so the owner can ignore errors from a
    /// stream it already retired (stop / restart / re-setup on a new display).
    var onStreamError: ((SCStream, Error) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        debugLog("SCStream stopped with error — domain: \(nsError.domain), code: \(nsError.code), description: \(nsError.localizedDescription)")
        onStreamError?(stream, error)
    }
}

// MARK: - ScreenCapture

/// Captures the virtual display and feeds the encoder.
///
/// Queue ownership:
/// - Control plane (`stream`, `display`, codec / client limits / capabilities,
///   restart bookkeeping) is driven by the owner as before — AppDelegate on the
///   main actor or its startup task, `negotiate` on the server's network queue —
///   plus this class's own restart / fallback tasks. The async operations that
///   replace or retarget the SCStream (setup, start, restart, in-place resize)
///   run one at a time through `enqueueControl`.
/// - `sampleQueue` (serial) runs every SCStream sample, CGDisplayStream frame,
///   cached-frame replay and keepalive, and submits to VideoToolbox inline. It is
///   the only encode-submission context, so frames reach VT in capture order.
/// - `pipeline` (lock) holds what both sides share: the live encoder and its
///   output sink, the cached pixel buffer, keyframe-request bookkeeping and the
///   published stream format.
/// - `stateLock` holds the frame-monitor state.
/// - Callbacks are set once before `startStreaming`. `shouldSkipEncode` runs on
///   `sampleQueue`; `onStreamFormatChanged` runs on whichever thread installed the
///   encoder (caller of `startStreaming`/`negotiate`/`startNewSegment`, or the
///   SCStream delegate queue when the fallback switches to SDR) — hop before
///   touching UI.
class ScreenCapture {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var streamDelegate: StreamDelegate?
    private var display: SCDisplay?
    private var virtualDisplayID: CGDirectDisplayID?
    /// Refresh rate of the virtual display.
    private var refreshRate: Int = 60
    /// User HDR preference and whether the virtual display itself is HDR (EDR).
    private var hdrMode: HDRMode = .off
    private var displayIsHDR = false
    /// Physical pixel size passed to `resize`; wins over the mode lookup until
    /// the next `setupForVirtualDisplay` / `stopStreaming`.
    private var resizedPixelSize: (width: Int, height: Int)?
    /// Tail of the serial chain of control operations (see `enqueueControl`).
    private let controlTail = OSAllocatedUnfairLock<Task<Void, Never>?>(uncheckedState: nil)
    /// Whether the live SCStream was configured with the HDR10 preset.
    private var streamConfiguredHDR = false
    /// True while the 8-bit CGDisplayStream fallback forced an SDR encoder
    /// although the negotiated format is HDR; the next SCStream restart lifts it.
    private var fallbackForcedSDR = false

    /// Serial queue for every frame callback and encode submission (see type doc).
    private let sampleQueue = DispatchQueue(label: "com.sidescreen.capture.samples", qos: .userInteractive)

    // Thread-safe state for cross-thread access (sample queue + main queue)
    private let stateLock = OSAllocatedUnfairLock(initialState: FrameMonitorState())

    private struct FrameMonitorState {
        var lastFrameTime: DispatchTime?
        var hasReceivedFirstFrame = false
        var fallbackActive = false
    }

    private struct ReportedFormat: Equatable {
        var format: StreamColorFormat
        var fps: Int
    }

    /// Shared between the control plane and `sampleQueue`; guarded by `pipeline`.
    private struct PipelineState {
        var encoder: VideoEncoder?
        /// The live encoder's path to the server.
        var sink: EncodedFrameSink?
        /// Latest captured frame, re-encoded for keyframe replays and idle keepalives.
        var lastPixelBuffer: CVPixelBuffer?
        /// A keyframe was requested before any encoder existed.
        var pendingKeyframe = false
        var lastKeyframeOrReplayRequestNs: UInt64 = 0
        /// `activeFormat` of the most recently installed encoder.
        var activeFormat: StreamColorFormat = .sdr709
        /// Last (format, fps) handed to `onStreamFormatChanged`.
        var reported: ReportedFormat?
    }
    private let pipeline = OSAllocatedUnfairLock(uncheckedState: PipelineState())
    private static let keyframeRequestThrottleNs: UInt64 = 500_000_000

    // Main-thread-only state
    private var frameMonitorTimer: DispatchSourceTimer?
    private var restartAttempted = false
    private var wakeObservers: [NSObjectProtocol] = []
    /// True between startStreaming and stopStreaming. Guards wake-triggered
    /// restarts from re-enabling capture after a stop.
    private var isStreaming = false
    /// Bumped on every stopStreaming and every restart so a superseded
    /// in-flight restart Task aborts instead of resurrecting capture.
    private var streamGeneration: UInt64 = 0

    // Display-sleep assertion held while streaming (see createDisplaySleepAssertion)
    private var displaySleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var hasDisplaySleepAssertion = false
    private var wakeRestartPending = false

    // CGDisplayStream fallback
    private var cgDisplayStream: CGDisplayStream?

    // Streaming parameters (saved for restart)
    private weak var currentServer: StreamingServer?
    private var currentBitrateMbps: Int = 20
    private var currentQuality: String = "medium"
    private var currentGamingBoost: Bool = false

    /// Callback when capture method changes (e.g. SCStream → CGDisplayStream fallback)
    var onCaptureMethodChanged: ((String) -> Void)?
    /// Fired with the encoder's achieved format and the encode frame rate
    /// whenever either changes (first encoder included).
    var onStreamFormatChanged: ((StreamColorFormat, Int) -> Void)?
    /// Consulted on `sampleQueue` before each captured frame is encoded; `true`
    /// drops the frame (network backpressure). The frame is still cached.
    var shouldSkipEncode: (() -> Bool)?

    /// Format the live (or last) encoder actually produces — what type 16 must announce.
    var activeStreamFormat: StreamColorFormat {
        pipeline.withLockUnchecked { $0.activeFormat }
    }
    /// Frame rate encoders are built for: `min(refreshRate, client peakRefreshHz)`.
    private(set) var encodeFps: Int = 60
    /// Format negotiated for the connection; the encoder may achieve less.
    private var requestedFormat: StreamColorFormat = .sdr709

    /// Force the encoder to emit an IDR keyframe on the next frame.
    /// If the encoder hasn't been created yet (request arrived before
    /// startStreaming), the request is stored and applied at encoder init.
    func requestKeyframe() {
        let encoder = pipeline.withLockUnchecked { state -> VideoEncoder? in
            if state.encoder == nil { state.pendingKeyframe = true }
            return state.encoder
        }
        encoder?.requestKeyframe()
    }

    /// Force a keyframe for the next captured frame, AND immediately re-encode
    /// the last cached frame as a forced keyframe if the display is currently
    /// idle. Without this, a client connecting during a static screen would
    /// wait up to one full GOP duration before its decoder could start.
    func requestKeyframeOrReplayCachedFrame(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldRequest = pipeline.withLockUnchecked { state -> Bool in
            if !force,
               state.lastKeyframeOrReplayRequestNs > 0,
               now - state.lastKeyframeOrReplayRequestNs < Self.keyframeRequestThrottleNs {
                return false
            }
            state.lastKeyframeOrReplayRequestNs = now
            return true
        }
        guard shouldRequest else { return }

        requestKeyframe()
        // An explicit client request bypasses `shouldSkipEncode`: the decoder needs this IDR.
        // Only replay the cached buffer if no live SCStream frame consumed `pendingForceKeyframe` first.
        reencodeCachedFrame(honorBackpressure: false, onlyIfKeyframePending: true)
    }

    /// Re-submits the cached frame on `sampleQueue` with a fresh timestamp.
    /// Returns false only when nothing was ever captured (the stream looks dead);
    /// a cached frame with no encoder yet (no client streaming) is a healthy idle.
    @discardableResult
    private func reencodeCachedFrame(honorBackpressure: Bool, onlyIfKeyframePending: Bool = false) -> Bool {
        let hasCached = pipeline.withLockUnchecked { $0.lastPixelBuffer != nil }
        guard hasCached else { return false }
        sampleQueue.async { [weak self] in
            guard let self = self else { return }
            if honorBackpressure, self.shouldSkipEncode?() == true { return }
            let (encoder, cached) = self.pipeline.withLockUnchecked { ($0.encoder, $0.lastPixelBuffer) }
            guard let encoder, let cached else { return }
            if onlyIfKeyframePending, !encoder.hasPendingForceKeyframe { return }
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let pts = CMTime(value: CMTimeValue(nowNs / 1000), timescale: 1_000_000)
            encoder.encode(pixelBuffer: cached, presentationTimeStamp: pts, captureNanos: nowNs)
        }
        return true
    }

    var displayWidth: Int { displayPixelSize.width }
    var displayHeight: Int { displayPixelSize.height }

    private var displayPixelSize: (width: Int, height: Int) {
        if let resizedPixelSize { return resizedPixelSize }
        guard let id = virtualDisplayID else { return (display?.width ?? 0, display?.height ?? 0) }
        return ScreenCapture.physicalSize(for: id)
    }

    /// Codec for the current encode session. Switching restarts the stream.
    private(set) var codec: StreamCodec = .hevc

    /// Largest frame the connected client wants to receive (issue #41): the
    /// smaller of its panel size and what its decoder can sustain at the panel
    /// refresh rate. Nil for legacy clients that report nothing.
    private var clientDecodeLimit: (width: Int, height: Int)?
    /// The same ceiling measured per frame rate (type 14), when the client sent it.
    private var clientDecodeLimitTable: [Int: (width: Int, height: Int)]?
    /// Type-15 capabilities; nil for clients that predate it.
    private var clientCapabilities: ClientCapabilities?

    /// Encode dimensions for a codec: physical display pixels, clamped to the
    /// client's reported ceiling at `encodeFps` when known, else to the
    /// conservative AVC floor when streaming H.264. SCStream/CGDisplayStream
    /// scale the capture into this size, so no virtual-display change is needed.
    ///
    /// This is what makes HiDPI usable on a tablet: macOS renders at 2x, SCStream
    /// downsamples to the client's ceiling before encode, and the client decodes
    /// a frame it can sustain — sharper than a 1x capture of the same size.
    func encodeSize(for codec: StreamCodec) -> (width: Int, height: Int) {
        let phys = displayPixelSize
        // A reported limit is authoritative for both codecs: it is what the
        // client's own MediaCodec claims it can decode.
        if let budget = CodecLimits.budget(limit: clientDecodeLimit, table: clientDecodeLimitTable, forFps: encodeFps) {
            return CodecLimits.clampToClientLimit(width: phys.width, height: phys.height, limit: budget)
        }
        switch codec {
        case .hevc: return phys
        case .h264: return CodecLimits.clampForAvc(width: phys.width, height: phys.height)
        }
    }

    /// Returns physical pixel dimensions for a display ID.
    /// CGDisplayPixelsWide/High return logical pixels on HiDPI displays — use
    /// CGDisplayModeGetPixelWidth/Height to always get the true physical size.
    static func physicalSize(for displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let w = mode.pixelWidth
            let h = mode.pixelHeight
            if w > 0 && h > 0 { return (w, h) }
        }
        // Mode lookup failed — falling back to logical pixels (may be stale on HiDPI display)
        debugLog("physicalSize fallback for display \(displayID) — CGDisplayCopyDisplayMode returned nil")
        return (Int(CGDisplayPixelsWide(displayID)), Int(CGDisplayPixelsHigh(displayID)))
    }

    /// True when this build and OS can capture HDR10 with ScreenCaptureKit
    /// (`.captureHDRRecordingPreservedSDRHDR10`, macOS 26 SDK and runtime).
    static var captureSupportsHDR: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }

    init() async throws {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        debugLog("ScreenCapture init — macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
    }

    /// Setup screen capture for a specific virtual display. Re-callable after
    /// `stopStreaming()` (e.g. on a recreated display with a new ID); the codec,
    /// client limits and capabilities from the last `negotiate` carry over.
    func setupForVirtualDisplay(
        _ displayID: CGDirectDisplayID,
        refreshRate: Int = 60,
        hdrMode: HDRMode = .off,
        displayIsHDR: Bool = false
    ) async throws {
        try await enqueueControl { [self] in
            virtualDisplayID = displayID
            self.refreshRate = max(refreshRate, 1)
            self.hdrMode = hdrMode
            self.displayIsHDR = displayIsHDR
            resizedPixelSize = nil
            display = nil
            updateNegotiatedStreamParameters()
            try await setupDisplay()
            try await setupStream()
        }.value
        await MainActor.run { registerWakeObservers() }
    }

    /// Runs `operation` after every previously enqueued control operation has
    /// finished, so two of them never interleave their `stream` / `streamOutput`
    /// / `display` mutations across suspension points (e.g. a negotiate-triggered
    /// restart and an in-place resize on connect). Operations must not await
    /// another enqueued operation.
    @discardableResult
    private func enqueueControl(_ operation: @escaping () async throws -> Void) -> Task<Void, Error> {
        controlTail.withLockUnchecked { tail in
            let previous = tail
            let task = Task {
                await previous?.value
                try await operation()
            }
            tail = Task { _ = await task.result }
            return task
        }
    }

    // MARK: - Display wake handling

    /// Display sleep tears down SCStream (SCStreamErrorDomain -3815, "no
    /// displays or windows to capture"), which silently drops capture onto
    /// the CGDisplayStream fallback for the rest of the session. Restart
    /// the capture whenever the screens wake so it returns to SCStream.
    private func registerWakeObservers() {
        guard wakeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleWake()
            }
            wakeObservers.append(token)
        }
        debugLog("Wake observers registered")
    }

    private func unregisterWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.forEach { center.removeObserver($0) }
        wakeObservers.removeAll()
    }

    deinit {
        // Defensive: stopStreaming() already unregisters and releases, but make
        // sure a dropped instance never leaves observer tokens behind or keeps
        // holding the display-sleep assertion for the rest of the process.
        unregisterWakeObservers()
        releaseDisplaySleepAssertion()
    }

    private func handleWake() {
        // Only act while a capture is actually running.
        guard stream != nil || cgDisplayStream != nil else { return }
        // A full system wake fires both screensDidWake and didWake —
        // coalesce them into a single restart.
        guard !wakeRestartPending else { return }
        wakeRestartPending = true
        debugLog("Screens woke — scheduling capture restart")
        // Give WindowServer a moment to settle before touching the stream.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.wakeRestartPending = false
            guard self.stream != nil || self.cgDisplayStream != nil else { return }
            // Display sleep usually kills SCStream with error -3815 ("no
            // displays or windows to capture"), which pushes capture onto the
            // CGDisplayStream fallback. After wake, always try to get back
            // onto SCStream — restartStream() re-enters the fallback by
            // itself if SCStream still cannot start.
            let fallbackActive = self.stateLock.withLock { $0.fallbackActive }
            if fallbackActive {
                debugLog("Wake restart: leaving CGDisplayStream fallback, retrying SCStream")
                self.cgDisplayStream?.stop()
                self.cgDisplayStream = nil
                self.stateLock.withLock { $0.fallbackActive = false }
            }
            self.restartStream()
            // A wake-triggered restart must not consume the one-shot budget
            // the frame monitor uses for stall recovery.
            self.restartAttempted = false
        }
    }

    // MARK: - SCShareableContent with timeout

    private func getShareableContentWithTimeout(seconds: Int = 10) async throws -> SCShareableContent {
        try await withThrowingTaskGroup(of: SCShareableContent.self) { group in
            group.addTask {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw NSError(domain: "ScreenCapture", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "SCShareableContent timed out after \(seconds)s (possible Apple bug FB12114396)"])
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Display setup

    private func setupDisplay() async throws {
        guard let virtualDisplayID = virtualDisplayID else {
            throw NSError(domain: "ScreenCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Virtual display ID not set"])
        }

        for attempt in 1...5 {
            let content: SCShareableContent
            do {
                content = try await getShareableContentWithTimeout(seconds: 10)
            } catch {
                debugLog("SCShareableContent attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < 5 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                throw error
            }

            debugLog("SCShareableContent returned \(content.displays.count) displays: \(content.displays.map { $0.displayID })")

            if let virtualDisplay = content.displays.first(where: { $0.displayID == virtualDisplayID }) {
                display = virtualDisplay
                debugLog("Capturing virtual display: \(virtualDisplay.width)x\(virtualDisplay.height) (ID: \(virtualDisplayID))")
                return
            }

            if attempt < 5 {
                debugLog("Virtual display \(virtualDisplayID) not found in attempt \(attempt), retrying...")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        throw NSError(domain: "ScreenCapture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Virtual display with ID \(virtualDisplayID) not found after 5 attempts"])
    }

    // MARK: - Stream setup

    /// Whether the SCStream should capture HDR: follows the live encoder (its
    /// session ladder may have fallen back to SDR), else the negotiated format.
    private var captureWantsHDR: Bool {
        let live = pipeline.withLockUnchecked { $0.encoder?.activeFormat }
        return (live ?? requestedFormat).isHDR
    }

    /// Stream configuration for the given encode size. `hdr` selects the macOS 26
    /// HDR10 preset; otherwise today's 8-bit video-range SDR configuration.
    private static func makeStreamConfiguration(width: Int, height: Int, fps: Int, hdr: Bool) -> SCStreamConfiguration {
        let config = baseConfiguration(hdr: hdr)
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        config.showsCursor = true
        // 5 surfaces: one being encoded, one cached for replay, and free surfaces for 120Hz SCK.
        config.queueDepth = 5
        config.capturesAudio = false
        config.backgroundColor = .clear
        config.scalesToFit = false
        return config
    }

    private static func baseConfiguration(hdr: Bool) -> SCStreamConfiguration {
        #if compiler(>=6.2)
        if hdr, #available(macOS 26, *) {
            // The preset picks captureDynamicRange, 10-bit x420, BT.2020/PQ and
            // HDR10 metadata that keeps SDR UI at SDR brightness. Never override
            // pixelFormat / colorSpaceName / colorMatrix here: it clips EDR headroom.
            return SCStreamConfiguration(preset: .captureHDRRecordingPreservedSDRHDR10)
        }
        #endif
        let config = SCStreamConfiguration()
        // Video-range (16-235) rather than full-range (0-255). VideoToolbox
        // derives the bitstream's VUI full_range_flag from the pixel format,
        // and several Android vendor display paths (Xiaomi/HyperOS among
        // them) apply a limited-range YUV->RGB matrix regardless of that
        // flag, which clips full-range highlights to white and crushes
        // shadows (#55). Limited range is what every decoder/GPU assumes by
        // default, so it renders identically everywhere.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return config
    }

    private func setupStream() async throws {
        guard let display = display, virtualDisplayID != nil else {
            throw NSError(domain: "ScreenCapture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Display not initialized"])
        }

        // Physical pixels for full Retina sharpness, clamped when H.264 (SCStream scales)
        let (width, height) = encodeSize(for: codec)
        let fps = encodeFps
        let hdr = captureWantsHDR

        // Keep a local reference. `streamOutput` is cleared by the restart, fallback
        // and stop paths, so force-unwrapping the property further down races with
        // any of them and crashes setup with "Unexpectedly found nil".
        let output = StreamOutput()
        streamOutput = output

        let delegate = StreamDelegate()
        delegate.onStreamError = { [weak self] failedStream, _ in
            guard let self = self else { return }
            guard failedStream === self.stream else {
                debugLog("StreamDelegate error from a retired SCStream — ignored")
                return
            }
            debugLog("StreamDelegate error callback — attempting fallback")
            let alreadyActive = self.stateLock.withLock { $0.fallbackActive }
            if !alreadyActive {
                self.attemptFallbackCapture()
            }
        }
        streamDelegate = delegate

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = Self.makeStreamConfiguration(width: width, height: height, fps: fps, hdr: hdr)

        let scStream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try scStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)

        stream = scStream
        streamConfiguredHDR = hdr
        debugLog("Stream configured: \(width)x\(height) @ \(fps)fps, \(hdr ? "HDR10 preset" : "SDR 420v") (with delegate)")
    }

    // MARK: - Frame handling (sampleQueue)

    private func attachFrameHandler(label: String) {
        pipeline.withLockUnchecked { $0.lastPixelBuffer = nil }
        streamOutput?.onFrameReceived = { [weak self] sampleBuffer in
            self?.handleSample(sampleBuffer, label: label)
        }
    }

    /// Runs on `sampleQueue` for every SCStream sample.
    private func handleSample(_ sampleBuffer: CMSampleBuffer, label: String) {
        // Thread-safe update of frame monitor state
        let isFirst = stateLock.withLock { state -> Bool in
            state.lastFrameTime = DispatchTime.now()
            if !state.hasReceivedFirstFrame {
                state.hasReceivedFirstFrame = true
                return true
            }
            return false
        }

        if isFirst {
            debugLog("First frame received from SCStream (\(label))")
            onCaptureMethodChanged?("SCStream")
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let captureNanos = Self.captureNanos(of: sampleBuffer, pts: pts)
        // Samples without an image buffer (idle) re-encode the cached frame.
        submitCapturedFrame(CMSampleBufferGetImageBuffer(sampleBuffer), pts: pts, captureNanos: captureNanos)
    }

    /// Caches `pixelBuffer` (when given) and encodes it — or the cached frame —
    /// inline unless `shouldSkipEncode` reports backpressure. `sampleQueue` only.
    private func submitCapturedFrame(_ pixelBuffer: CVPixelBuffer?, pts: CMTime, captureNanos: UInt64) {
        let snapshot = pipeline.withLockUnchecked { state -> (VideoEncoder?, CVPixelBuffer?) in
            if let pixelBuffer { state.lastPixelBuffer = pixelBuffer }
            return (state.encoder, state.lastPixelBuffer)
        }
        guard let encoder = snapshot.0, let buffer = snapshot.1 else { return }
        if shouldSkipEncode?() == true { return }
        encoder.encode(pixelBuffer: buffer, presentationTimeStamp: pts, captureNanos: captureNanos)
    }

    private static let displayTimeKey = SCStreamFrameInfo.displayTime.rawValue as CFString

    /// Capture instant in the `DispatchTime.uptimeNanoseconds` domain: the
    /// frame's `SCStreamFrameInfo.displayTime` (mach absolute time), else the
    /// sample PTS (host-clock time, same domain), else now.
    private static func captureNanos(of sampleBuffer: CMSampleBuffer, pts: CMTime) -> UInt64 {
        if let machTime = displayTime(of: sampleBuffer) {
            return uptimeNanos(machTime: machTime)
        }
        if pts.isNumeric {
            let ns = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
            if ns > 0 { return UInt64(ns) }
        }
        return DispatchTime.now().uptimeNanoseconds
    }

    /// Reads `SCStreamFrameInfo.displayTime` straight from the CF attachment
    /// dictionary — no per-frame Swift collection bridging.
    private static func displayTime(of sampleBuffer: CMSampleBuffer) -> UInt64? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0,
              let rawDictionary = CFArrayGetValueAtIndex(attachments, 0) else { return nil }
        let dictionary = Unmanaged<CFDictionary>.fromOpaque(rawDictionary).takeUnretainedValue()
        guard CFGetTypeID(dictionary) == CFDictionaryGetTypeID(),
              let rawValue = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(displayTimeKey).toOpaque()) else {
            return nil
        }
        let value = Unmanaged<AnyObject>.fromOpaque(rawValue).takeUnretainedValue()
        guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var machTime: Int64 = 0
        guard CFNumberGetValue(unsafeBitCast(value, to: CFNumber.self), .sInt64Type, &machTime), machTime > 0 else {
            return nil
        }
        return UInt64(machTime)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Mach absolute time → nanoseconds, the conversion `DispatchTime.uptimeNanoseconds`
    /// applies; split to avoid overflowing `machTime * numer`.
    static func uptimeNanos(machTime: UInt64) -> UInt64 {
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        guard denom != 0, numer != denom else { return machTime }
        return (machTime / denom) * numer + (machTime % denom) * numer / denom
    }

    // MARK: - Encoder lifecycle

    private var hasEncoder: Bool { pipeline.withLockUnchecked { $0.encoder != nil } }

    /// Format new encoders are asked for: the negotiated one, except while the
    /// 8-bit CGDisplayStream fallback feeds the encoder.
    private var encoderRequestFormat: StreamColorFormat {
        stateLock.withLock { $0.fallbackActive } ? .sdr709 : requestedFormat
    }

    /// An encoder plus the sink its output reaches the server through.
    private struct LiveEncoder {
        let encoder: VideoEncoder
        let sink: EncodedFrameSink
    }

    private func makeEncoder(format: StreamColorFormat) -> LiveEncoder {
        let (width, height) = encodeSize(for: codec)
        let encoder = VideoEncoder(
            width: width,
            height: height,
            codec: codec,
            format: format,
            bitrateMbps: currentBitrateMbps,
            quality: currentQuality,
            gamingBoost: currentGamingBoost,
            frameRate: encodeFps,
            headerReserve: StreamingServer.frameHeaderReserve
        )
        let sink = EncodedFrameSink(server: currentServer)
        encoder.onEncodedFrame = { [sink] frame in sink.deliver(frame) }
        if encoder.activeFormat != format {
            debugLog("Encoder fell back from requested \(format) to \(encoder.activeFormat)")
        }
        return LiveEncoder(encoder: encoder, sink: sink)
    }

    /// Makes `new` the live encoder. In order: cuts the current encoder's
    /// output off (none of its frames — in flight, flushed or replayed — reach
    /// the wire afterwards), publishes the new format (type 16), runs
    /// `openSegment`, then applies a pending/forced keyframe and goes live. So
    /// whatever `openSegment` sends (new stream segment, display config) precedes
    /// the new encoder's first frame and follows the old one's last. The retired
    /// encoder is released on `sampleQueue` behind queued submissions, so its VT
    /// flush never runs on the caller's thread.
    private func installEncoder(_ new: LiveEncoder, forceKeyframe: Bool, openSegment: () -> Void = {}) {
        pipeline.withLockUnchecked { $0.sink }?.close()

        let current = ReportedFormat(format: new.encoder.activeFormat, fps: encodeFps)
        let changed = pipeline.withLockUnchecked { state -> Bool in
            guard state.reported != current else { return false }
            state.reported = current
            return true
        }
        if changed {
            debugLog("Stream format: \(current.format) @ \(current.fps) fps")
            onStreamFormatChanged?(current.format, current.fps)
        }

        openSegment()

        let retired = pipeline.withLockUnchecked { state -> VideoEncoder? in
            if forceKeyframe || state.pendingKeyframe {
                new.encoder.requestKeyframe()
            }
            state.pendingKeyframe = false
            let previous = state.encoder
            state.encoder = new.encoder
            state.sink = new.sink
            state.activeFormat = current.format
            return previous
        }
        if let retired {
            sampleQueue.async { withExtendedLifetime(retired) {} }
        }
    }

    /// Rebuilds the live encoder at the current size/format/fps with a forced
    /// IDR; `openSegment` runs between cutting off the old encoder and starting
    /// the new one (see `installEncoder`).
    private func rebuildActiveEncoder(openSegment: () -> Void = {}) {
        let format = encoderRequestFormat
        fallbackForcedSDR = format != requestedFormat
        installEncoder(makeEncoder(format: format), forceKeyframe: true, openSegment: openSegment)
    }

    // MARK: - Start streaming

    func startStreaming(to server: StreamingServer?, bitrateMbps: Int = 20, quality: String = "medium", gamingBoost: Bool = false) {
        // Save parameters for potential restart
        currentServer = server
        currentBitrateMbps = bitrateMbps
        currentQuality = quality
        currentGamingBoost = gamingBoost

        isStreaming = true
        fallbackForcedSDR = false

        // Keep the display awake for the whole streaming session so the virtual
        // display never idle-sleeps (the sleep/wake cycle is what strands the
        // cursor — see the wake handling above for the residual cases).
        createDisplaySleepAssertion()

        installEncoder(makeEncoder(format: encoderRequestFormat), forceKeyframe: false)

        // Reset frame monitor state
        stateLock.withLock { state in
            state.lastFrameTime = nil
            state.hasReceivedFirstFrame = false
        }

        let gen = streamGeneration
        enqueueControl { [self] in
            do {
                // The stream was set up before the encoder existed; rebuild it when
                // the encoder achieved a different dynamic range, or when it is gone.
                if stream == nil || streamConfiguredHDR != captureWantsHDR {
                    if display == nil { try await setupDisplay() }
                    try await setupStream()
                }
                guard isStreaming, gen == streamGeneration, let scStream = stream else {
                    debugLog("startStreaming(gen \(gen)) superseded before start — aborting")
                    return
                }
                attachFrameHandler(label: "initial")
                try await scStream.startCapture()
                guard isStreaming, gen == streamGeneration else {
                    debugLog("startStreaming(gen \(gen)) superseded after startCapture — aborting")
                    try? await scStream.stopCapture()
                    return
                }
                debugLog("SCStream capture started — starting frame flow monitor (3s interval, 5s timeout)")
                startFrameMonitor()
            } catch {
                debugLog("Failed to start SCStream capture: \(error)")
                guard isStreaming, gen == streamGeneration else { return }
                debugLog("Attempting CGDisplayStream fallback due to start failure")
                attemptFallbackCapture()
            }
        }
    }

    // MARK: - Continuous frame-flow monitor

    private func startFrameMonitor() {
        stopFrameMonitor()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            let isFallback = self.stateLock.withLock { $0.fallbackActive }
            guard !isFallback else {
                self.stopFrameMonitor()
                return
            }

            let stalled: Bool
            let lastTime = self.stateLock.withLock { $0.lastFrameTime }
            if let last = lastTime {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000_000
                stalled = elapsed > 5.0
                if stalled {
                    debugLog("Frame flow stalled — no frames for \(String(format: "%.1f", elapsed))s, triggering fallback")
                }
            } else {
                stalled = true
                debugLog("Frame flow stalled — no frames ever received after 5s, triggering fallback")
            }

            if stalled {
                let hasHadFrames = self.stateLock.withLock { $0.hasReceivedFirstFrame }

                // Screen is idle — SCStream is healthy but not delivering frames (macOS optimization).
                // Re-send the last captured frame as a keepalive so the tablet stays connected.
                if hasHadFrames, self.reencodeCachedFrame(honorBackpressure: true) {
                    self.stateLock.withLock { $0.lastFrameTime = DispatchTime.now() }
                    // Keep monitoring — real errors are handled by the SCStream error delegate
                } else {
                    self.stopFrameMonitor()
                    if !self.restartAttempted {
                        debugLog("Attempting SCStream restart...")
                        self.restartStream()
                    } else {
                        debugLog("Restart already attempted — falling back to CGDisplayStream")
                        self.attemptFallbackCapture()
                    }
                }
            }
        }
        timer.resume()
        frameMonitorTimer = timer
    }

    private func stopFrameMonitor() {
        frameMonitorTimer?.cancel()
        frameMonitorTimer = nil
    }

    // MARK: - Stream restart

    private func restartStream() {
        guard isStreaming else {
            debugLog("restartStream skipped — not streaming")
            return
        }

        streamGeneration &+= 1
        let gen = streamGeneration
        restartAttempted = true
        stateLock.withLock { $0.hasReceivedFirstFrame = false }

        enqueueControl { [self] in
            do {
                // Queued behind another control operation that may have
                // superseded this restart meanwhile.
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded before it ran — aborting")
                    return
                }
                // Stop existing stream
                try? await stream?.stopCapture()
                // A stopStreaming() or a newer restart superseded this one — do
                // NOT bring capture back up (would resurrect a stopped stream).
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded after stopCapture — aborting")
                    return
                }

                stream = nil
                streamOutput = nil
                streamDelegate = nil
                display = nil

                // Back on SCStream after the 8-bit fallback: restore the negotiated format.
                if fallbackForcedSDR, !stateLock.withLock({ $0.fallbackActive }), hasEncoder {
                    rebuildActiveEncoder()
                }

                // Re-setup
                try await setupDisplay()
                try await setupStream()
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded during setup — aborting")
                    try? await stream?.stopCapture()
                    stream = nil
                    return
                }

                // Re-attach encoding pipeline using shared handler
                attachFrameHandler(label: "restart")
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded before start — aborting")
                    return
                }

                try await stream?.startCapture()
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded after startCapture — aborting")
                    try? await stream?.stopCapture()
                    return
                }

                debugLog("SCStream restarted — starting frame flow monitor")
                startFrameMonitor()
            } catch {
                debugLog("SCStream restart failed: \(error) — falling back to CGDisplayStream")
                if isStreaming, gen == streamGeneration {
                    attemptFallbackCapture()
                } else {
                    debugLog("restartStream(gen \(gen)) superseded before fallback — aborted")
                }
            }
        }
    }

    // MARK: - Display-sleep assertion

    /// Keep the display awake while streaming. The captured surface is a
    /// virtual display; when the physical display idle-sleeps (pmset
    /// displaysleep), the virtual display stops producing frames and the
    /// cursor overlay is lost on wake. Holding
    /// kIOPMAssertionTypePreventUserIdleDisplaySleep avoids the whole
    /// sleep/wake transition; the wake observers above cover what it cannot
    /// (manual/forced sleep, lid close, display reconnects). Released in
    /// stopStreaming.
    private func createDisplaySleepAssertion() {
        guard !hasDisplaySleepAssertion else { return }
        let reason = "Side Screen is streaming to an external tablet display" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displaySleepAssertionID)
        if result == kIOReturnSuccess {
            hasDisplaySleepAssertion = true
            debugLog("Display-sleep assertion held — display stays awake while streaming")
        } else {
            debugLog("Failed to create display-sleep assertion: IOReturn \(result)")
        }
    }

    private func releaseDisplaySleepAssertion() {
        guard hasDisplaySleepAssertion else { return }
        let result = IOPMAssertionRelease(displaySleepAssertionID)
        if result != kIOReturnSuccess {
            debugLog("IOPMAssertionRelease failed: IOReturn \(result)")
        }
        hasDisplaySleepAssertion = false
        displaySleepAssertionID = IOPMAssertionID(0)
        debugLog("Display-sleep assertion released")
    }

    // MARK: - CGDisplayStream fallback

    private func attemptFallbackCapture() {
        guard let displayID = virtualDisplayID else {
            debugLog("Fallback skipped — no displayID")
            return
        }

        // Thread-safe check-and-set for fallbackActive
        let alreadyActive = stateLock.withLock { state -> Bool in
            if state.fallbackActive { return true }
            state.fallbackActive = true
            return false
        }
        guard !alreadyActive else {
            debugLog("Fallback skipped — already active")
            return
        }

        // Stop SCStream (nil out output first to prevent new frames)
        streamOutput?.onFrameReceived = nil
        let failedStream = stream
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        Task {
            try? await failedStream?.stopCapture()
        }

        // CGDisplayStream only delivers 8-bit SDR: an HDR encoder would tag
        // BT.709 pixels as PQ. Switch to SDR for as long as the fallback runs.
        if activeStreamFormat.isHDR, hasEncoder {
            debugLog("CGDisplayStream fallback is SDR-only — switching the encoder to SDR")
            rebuildActiveEncoder()
        }

        // CGDisplayStream scales natively via outputWidth/Height, so the
        // AVC clamp applies here exactly as in the SCStream path.
        let (width, height) = encodeSize(for: codec)

        debugLog("CGDisplayStream fallback — display \(displayID) (\(width)x\(height))")

        // Video-range to match the SCStream path (see #55 note above).
        let pixelFormat = Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        // Without kCGDisplayStreamShowCursor the fallback stream never
        // composites the cursor at all (the key defaults to false), so any
        // session that degrades to CGDisplayStream loses the pointer on the
        // tablet even when WindowServer is healthy.
        let streamProps = [CGDisplayStream.showCursor as String: true] as CFDictionary

        // Delivered on `sampleQueue`, like SCStream samples.
        guard let displayStream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: width,
            outputHeight: height,
            pixelFormat: pixelFormat,
            properties: streamProps,
            queue: sampleQueue,
            handler: { [weak self] _, displayTime, frameSurface, _ in
                guard let self = self, let surface = frameSurface else { return }

                var unmanagedPB: Unmanaged<CVPixelBuffer>?
                let attrs: [String: Any] = [
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
                ]
                let cvReturn = CVPixelBufferCreateWithIOSurface(
                    kCFAllocatorDefault,
                    surface,
                    attrs as CFDictionary,
                    &unmanagedPB
                )

                guard cvReturn == kCVReturnSuccess, let pb = unmanagedPB?.takeRetainedValue() else { return }

                // Use CMClock for accurate timestamps instead of raw Mach time
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                let captureNanos = displayTime > 0
                    ? ScreenCapture.uptimeNanos(machTime: displayTime)
                    : DispatchTime.now().uptimeNanoseconds
                self.submitCapturedFrame(pb, pts: pts, captureNanos: captureNanos)
            }
        ) else {
            debugLog("Failed to create CGDisplayStream — fallback unavailable")
            stateLock.withLock { $0.fallbackActive = false }
            return
        }

        let startResult = displayStream.start()
        if startResult == .success {
            cgDisplayStream = displayStream
            debugLog("CGDisplayStream fallback started successfully")
            onCaptureMethodChanged?("CGDisplayStream (fallback)")
        } else {
            debugLog("CGDisplayStream.start() failed: \(startResult)")
            stateLock.withLock { $0.fallbackActive = false }
        }
    }

    // MARK: - Settings update

    func updateEncoderSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        // Saved so a later rebuild (negotiate / new segment / fallback) keeps them.
        currentBitrateMbps = bitrateMbps
        currentQuality = quality
        currentGamingBoost = gamingBoost
        let encoder = pipeline.withLockUnchecked { $0.encoder }
        encoder?.updateSettings(bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost)
    }

    // MARK: - Negotiation

    /// HDR needs an EDR virtual display, HEVC (Main10) and the macOS 26 capture preset.
    private var hostCanCaptureHDR: Bool {
        displayIsHDR && codec == .hevc && Self.captureSupportsHDR
    }

    private func updateNegotiatedStreamParameters() {
        let peak = clientCapabilities?.peakRefreshHz ?? 0
        encodeFps = peak > 0 ? min(refreshRate, peak) : refreshRate
        requestedFormat = StreamColorFormat.negotiate(mode: hdrMode, hostCanHDR: hostCanCaptureHDR, client: clientCapabilities)
    }

    /// Apply the per-connection negotiation result: stream codec, the client's
    /// reported decoder ceiling and its type-15 capabilities (nil for older
    /// clients). Derives the colour format and `encodeFps`; when any of codec,
    /// encode size, frame rate or requested format changes mid-stream, rebuilds
    /// the encoder and restarts capture so SCStream delivers buffers in the new
    /// size / dynamic range. The client's keyframe-request loop (force, 200 ms
    /// interval) bridges the restart gap. If the CGDisplayStream fallback is
    /// active, restartStream() only rebuilds the SCStream path; that rare
    /// combination recovers on the next fallback restart.
    /// - Parameter openSegment: runs only when the encode size of a live
    ///   encoder changes, after the old encoder is cut off and before the new
    ///   one's first frame (the owner's new stream segment + display config).
    func negotiate(
        codec newCodec: StreamCodec,
        clientLimit: (width: Int, height: Int)?,
        clientLimitTable: [Int: (width: Int, height: Int)]? = nil,
        clientCapabilities: ClientCapabilities?,
        openSegment: () -> Void = {}
    ) {
        let sizeBefore = encodeSize(for: codec)
        let fpsBefore = encodeFps
        let formatBefore = requestedFormat
        let codecChanged = newCodec != codec
        if codecChanged {
            debugLog("Switching stream codec: \(codec) -> \(newCodec)")
        }
        codec = newCodec
        clientDecodeLimit = clientLimit
        clientDecodeLimitTable = clientLimitTable
        self.clientCapabilities = clientCapabilities
        updateNegotiatedStreamParameters()

        guard hasEncoder else { return }  // not streaming yet; startStreaming will pick everything up

        let sizeAfter = encodeSize(for: newCodec)
        guard codecChanged || sizeBefore != sizeAfter || fpsBefore != encodeFps || formatBefore != requestedFormat else { return }
        if sizeBefore != sizeAfter {
            let budget = CodecLimits.budget(limit: clientLimit, table: clientLimitTable, forFps: encodeFps)
            let limitDesc = budget.map { "\($0.width)x\($0.height) at \(encodeFps) fps" } ?? "none"
            debugLog("Encode size \(sizeBefore.width)x\(sizeBefore.height) -> \(sizeAfter.width)x\(sizeAfter.height) (client decoder limit: \(limitDesc))")
        }
        if fpsBefore != encodeFps {
            debugLog("Encode fps \(fpsBefore) -> \(encodeFps)")
        }
        if formatBefore != requestedFormat {
            debugLog("Requested stream format \(formatBefore) -> \(requestedFormat)")
        }
        if sizeBefore != sizeAfter {
            rebuildActiveEncoder(openSegment: openSegment)
        } else {
            rebuildActiveEncoder()
        }
        restartStream()
    }

    // MARK: - In-place resize

    /// In-place re-mode (plan §11), step 1: the virtual display kept its ID and
    /// changed to a new mode. Retargets the SAME SCStream via
    /// `updateConfiguration` at the new encode size; the live encoder keeps
    /// running. Step 2 is `startNewSegment`, once the owner can announce the
    /// new size (`encodeSize(for: codec)` already reports it). Serialised with
    /// setup / start / restart, so it waits for a negotiate-triggered restart.
    /// - Parameters: width, height: the display's new physical pixel size.
    /// - Throws: when no SCStream is live (CGDisplayStream fallback, stopped,
    ///   not set up) or the update fails; the caller then falls back to a full
    ///   re-setup.
    func resize(width: Int, height: Int) async throws {
        try await enqueueControl { [self] in
            try await retargetStream(width: width, height: height)
        }.value
    }

    private func retargetStream(width: Int, height: Int) async throws {
        guard let scStream = stream, !stateLock.withLock({ $0.fallbackActive }) else {
            throw NSError(domain: "ScreenCapture", code: 20,
                userInfo: [NSLocalizedDescriptionKey: "No live SCStream to resize"])
        }
        let previousSize = resizedPixelSize
        resizedPixelSize = (width, height)
        pipeline.withLockUnchecked { $0.lastPixelBuffer = nil }

        let hdr = captureWantsHDR
        let (encodeWidth, encodeHeight) = encodeSize(for: codec)
        let config = Self.makeStreamConfiguration(width: encodeWidth, height: encodeHeight, fps: encodeFps, hdr: hdr)
        do {
            try await scStream.updateConfiguration(config)
        } catch {
            if stream === scStream { resizedPixelSize = previousSize }
            debugLog("SCStream updateConfiguration failed for \(width)x\(height): \(error)")
            throw error
        }
        guard stream === scStream else {
            throw NSError(domain: "ScreenCapture", code: 21,
                userInfo: [NSLocalizedDescriptionKey: "SCStream stopped during resize"])
        }
        streamConfiguredHDR = hdr
        debugLog("Capture resized in place: display \(width)x\(height), encode \(encodeWidth)x\(encodeHeight) @ \(encodeFps)fps")
    }

    /// Starts a new stream segment at the current encode size (plan §3/§9):
    /// builds an encoder for it, cuts the live encoder's output off, runs
    /// `openSegment` (the owner's `beginNewStreamSegment()` and display config),
    /// then makes the new encoder live with a forced IDR. Wire order is thus
    /// old frames → `openSegment`'s messages → new IDR. Without a live encoder
    /// (capture stopped meanwhile) only `openSegment` runs.
    func startNewSegment(_ openSegment: () -> Void) {
        guard hasEncoder else {
            openSegment()
            return
        }
        rebuildActiveEncoder(openSegment: openSegment)
    }

    // MARK: - Stop streaming

    /// Stops capture and releases the stream, display and encoder. The object
    /// stays reusable: `setupForVirtualDisplay` (any display ID) then
    /// `startStreaming` resume with the negotiated codec, limits and capabilities.
    func stopStreaming() {
        // Invalidate any in-flight restart (incl. the delayed wake restart) so
        // it cannot resurrect capture after this stop.
        isStreaming = false
        streamGeneration &+= 1

        // Cancel frame flow monitor
        stopFrameMonitor()

        // Let the display idle-sleep normally again once we stop streaming.
        releaseDisplaySleepAssertion()

        // Stop SCStream; no frame from it may reach a later encoder.
        streamOutput?.onFrameReceived = nil
        let stoppingStream = stream
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        display = nil
        streamConfiguredHDR = false
        resizedPixelSize = nil
        fallbackForcedSDR = false
        if let stoppingStream {
            Task {
                do {
                    try await stoppingStream.stopCapture()
                } catch {
                    debugLog("Failed to stop SCStream capture: \(error)")
                }
            }
        }

        // Stop CGDisplayStream fallback
        let wasFallback = stateLock.withLock { $0.fallbackActive }
        if wasFallback {
            cgDisplayStream?.stop()
            cgDisplayStream = nil
            debugLog("CGDisplayStream fallback stopped")
        }

        // Retire the encoder once queued submissions have run (its deinit
        // flushes VT off the caller's thread). Its output is cut off first: a
        // later stream segment must never sync on one of its frames.
        let retired = pipeline.withLockUnchecked { state -> (VideoEncoder?, EncodedFrameSink?) in
            defer {
                state.encoder = nil
                state.sink = nil
                state.lastPixelBuffer = nil
            }
            return (state.encoder, state.sink)
        }
        retired.1?.close()
        let retiredEncoder = retired.0
        sampleQueue.async { withExtendedLifetime(retiredEncoder) {} }

        // Reset state
        stateLock.withLock { state in
            state.lastFrameTime = nil
            state.hasReceivedFirstFrame = false
            state.fallbackActive = false
        }
        restartAttempted = false
        unregisterWakeObservers()
    }
}

// MARK: - EncodedFrameSink

/// One encoder's path to the server. `close()` cuts it off and waits for a
/// delivery in progress, so after it returns no frame of that encoder (in
/// flight, flushed by VideoToolbox, or a replay) reaches the wire.
final class EncodedFrameSink {
    private let lock = NSLock()
    private weak var server: StreamingServer?
    private var isOpen = true

    init(server: StreamingServer?) {
        self.server = server
    }

    /// VideoToolbox output thread.
    func deliver(_ frame: EncodedFrame) {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return }
        server?.sendFrame(frame)
    }

    func close() {
        lock.lock()
        isOpen = false
        lock.unlock()
    }
}

// MARK: - StreamOutput

class StreamOutput: NSObject, SCStreamOutput {
    var onFrameReceived: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        onFrameReceived?(sampleBuffer)
    }
}

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import os

final class VideoEncoder {
    private struct EncoderState {
        var pendingForceKeyframe = false
        var submitFailures = 0
        var outputFailures = 0
        var droppedFrames = 0
        var lastPtsUs: Int64 = 0
    }

    private enum FailureKind {
        case submit
        case output
        case dropped
    }

    /// Average-bitrate floor. Anything lower smears text at panel resolutions.
    static let minimumBitrateMbps = 20
    /// Upper bound between scheduled IDRs. Keyframes otherwise come only on
    /// request (client connect, decoder reset, re-mode); TCP does not lose frames.
    static let keyframeIntervalSeconds = 60

    /// Called on the VideoToolbox output thread for every encoded access unit.
    var onEncodedFrame: ((EncodedFrame) -> Void)?
    let codec: StreamCodec
    /// Colour format the live session actually encodes; `.sdr709` when HDR was
    /// requested but every HDR session configuration was rejected.
    private(set) var activeFormat: StreamColorFormat = .sdr709
    /// Whether the live session was created with low-latency rate control.
    private(set) var usesLowLatencyRateControl = false

    /// Written once during init, read-only afterwards.
    private var compressionSession: VTCompressionSession?
    private let width: Int
    private let height: Int
    private let frameRate: Int
    private let frameDuration: CMTime
    private let headerReserve: Int
    private let stateLock = OSAllocatedUnfairLock(initialState: EncoderState())

    /// - Parameters:
    ///   - format: requested colour format; `activeFormat` reports what was achieved.
    ///   - bitrateMbps: average bitrate, floored at `minimumBitrateMbps`.
    ///   - headerReserve: zero bytes left at the front of every `EncodedFrame.packet`
    ///     so the sender can write its frame header in place.
    init(width: Int, height: Int, codec: StreamCodec = .hevc, format: StreamColorFormat = .sdr709,
         bitrateMbps: Int, quality: String, gamingBoost: Bool, frameRate: Int, headerReserve: Int) {
        self.width = width
        self.height = height
        self.codec = codec
        self.frameRate = max(frameRate, 1)
        self.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(frameRate, 1)))
        self.headerReserve = max(headerReserve, 0)
        createSession(requested: format, rate: RateSettings(bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost))
    }

    /// Retunes bitrate, burst cap and quality on the live session. The colour
    /// format and rate-control mode are fixed for the session's lifetime.
    func updateSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        guard let session = compressionSession else { return }
        let rate = RateSettings(bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost)
        applyRate(rate, to: session, label: "update")
        debugLog("VideoEncoder: rate updated to \(rate.bitrateBps / 1_000_000) Mbps, quality \(rate.quality)")
    }

    /// Force the next encoded frame to be an IDR (sync) frame.
    /// Used when a fresh client connects so its decoder can start immediately
    /// instead of waiting for the next scheduled keyframe.
    var hasPendingForceKeyframe: Bool {
        stateLock.withLock { $0.pendingForceKeyframe }
    }

    func requestKeyframe() {
        stateLock.withLock { $0.pendingForceKeyframe = true }
    }

    /// - Parameter captureNanos: capture instant in the `DispatchTime.now().uptimeNanoseconds`
    ///   domain; carried through to `EncodedFrame.captureNanos`.
    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime, captureNanos: UInt64) {
        guard let session = compressionSession else { return }
        // Drop mismatched buffers from a prior mode/orientation before they
        // consume pendingForceKeyframe or get scaled into the new session size.
        guard CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height else {
            return
        }

        let (forceKeyframe, monotonicPts) = stateLock.withLock { state -> (Bool, CMTime) in
            let rawUs = CMTimeConvertScale(presentationTimeStamp, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
            let clampedUs = max(rawUs, state.lastPtsUs + 1)
            state.lastPtsUs = clampedUs
            let pts = CMTime(value: clampedUs, timescale: 1_000_000)
            guard state.pendingForceKeyframe else { return (false, pts) }
            state.pendingForceKeyframe = false
            return (true, pts)
        }
        let frameProperties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        // The capture instant travels as the refcon's bit pattern. VideoToolbox
        // never dereferences the refcon, so nothing is allocated per frame and
        // nothing can leak on the failure, drop or nil-sample-buffer paths.
        let refcon = UnsafeMutableRawPointer(bitPattern: UInt(truncatingIfNeeded: captureNanos))

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: monotonicPts,
            duration: frameDuration,
            frameProperties: frameProperties,
            sourceFrameRefcon: refcon,
            infoFlagsOut: nil
        )
        if status != noErr {
            if forceKeyframe {
                requestKeyframe()
            }
            noteFailure(.submit, "VTCompressionSessionEncodeFrame failed: \(status)")
        }
    }

    deinit {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    // MARK: - Session setup

    private struct RateSettings {
        let bitrateBps: Int
        let quality: Float

        init(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
            bitrateBps = max(bitrateMbps, VideoEncoder.minimumBitrateMbps) * 1_000_000
            if gamingBoost {
                self.quality = 0.3
            } else {
                self.quality = switch quality {
                case "ultralow": 0.5
                case "low": 0.65
                case "medium": 0.8
                case "high": 0.9
                default: 0.5
                }
            }
        }

        /// Burst cap: at most 1.5× the average rate inside any 100 ms window,
        /// which bounds how long an IDR or a scene change can stall the link.
        var dataRateLimits: CFArray {
            let bytesPerWindow = bitrateBps * 3 / 2 / 8 / 10
            return [bytesPerWindow as CFNumber, 0.1 as CFNumber] as CFArray
        }
    }

    /// Ladder: requested format with low-latency rate control → requested format
    /// without it → the same two steps for 8-bit BT.709. First success wins.
    private func createSession(requested: StreamColorFormat, rate: RateSettings) {
        var formats = [requested]
        if codec == .h264, requested != .sdr709 {
            debugLog("VideoEncoder: H.264 has no hardware 10-bit/HDR path; encoding SDR BT.709")
            formats = [.sdr709]
        } else if requested != .sdr709 {
            formats.append(.sdr709)
        }

        for format in formats {
            for lowLatency in [true, false] {
                guard let session = makeSession(format: format, lowLatency: lowLatency, rate: rate) else { continue }
                compressionSession = session
                activeFormat = format
                usesLowLatencyRateControl = lowLatency
                let codecName = codec == .hevc ? "H.265" : "H.264"
                debugLog("VideoEncoder configured: \(codecName) \(width)x\(height) \(format.encoderLabel), "
                    + "\(lowLatency ? "low-latency RC" : "standard RC"), "
                    + "\(rate.bitrateBps / 1_000_000) Mbps, \(frameRate) fps")
                return
            }
        }
        debugLog("VideoEncoder: every session configuration failed for \(width)x\(height); no frames will be encoded")
    }

    private func makeSession(format: StreamColorFormat, lowLatency: Bool, rate: RateSettings) -> VTCompressionSession? {
        let label = format.encoderLabel + (lowLatency ? " +LLRC" : "")

        var specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        if lowLatency {
            specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }

        // No source pixel-buffer attributes: the session accepts whatever the
        // capture delivers (8-bit or 10-bit, any size) without a forced pool.
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodingOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else {
            debugLog("VideoEncoder: session create failed (\(label)): \(status)")
            return nil
        }
        guard configure(session, format: format, rate: rate, label: label) else {
            VTCompressionSessionInvalidate(session)
            return nil
        }
        return session
    }

    /// Returns false when a property the format depends on is rejected.
    private func configure(_ session: VTCompressionSession, format: StreamColorFormat, rate: RateSettings, label: String) -> Bool {
        setProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, label)
        // No B-frames and no lookahead: every frame leaves the encoder as soon as it is coded.
        setProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, label)
        if !label.hasSuffix("+LLRC") {
            setProperty(session, kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber, label)
            setProperty(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue, label)
        }
        // H.264 Main: decodable by every AVC hardware decoder; High's 8x8
        // transform is rejected by some low-end vendor decoders.
        guard setProperty(session, kVTCompressionPropertyKey_ProfileLevel, profileLevel(for: format), label) else {
            return false
        }

        setProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, frameRate as CFNumber, label)
        // Effectively infinite GOP: IDRs come at start and on request only.
        let interval = Self.keyframeIntervalSeconds
        setProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (frameRate * interval) as CFNumber, label)
        setProperty(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, Double(interval) as CFNumber, label)

        applyRate(rate, to: session, label: label)

        // Explicit VUI colour description so every client decoder uses the
        // intended matrix/transfer instead of guessing (#55).
        let tagsRequired = format.isHDR
        guard let primaries = format.vtColorPrimaries,
              let transfer = format.vtTransferFunction,
              let matrix = format.vtYCbCrMatrix else {
            debugLog("VideoEncoder: no VideoToolbox colour tags for \(label)")
            return !tagsRequired
        }
        let tagged = setProperty(session, kVTCompressionPropertyKey_ColorPrimaries, primaries, label)
            && setProperty(session, kVTCompressionPropertyKey_TransferFunction, transfer, label)
            && setProperty(session, kVTCompressionPropertyKey_YCbCrMatrix, matrix, label)
        if tagsRequired && !tagged {
            return false
        }
        if format.isHDR {
            // Static HDR10 metadata (mastering display / content light level)
            // is taken from the capture buffer attachments.
            setProperty(session, kVTCompressionPropertyKey_HDRMetadataInsertionMode, kVTHDRMetadataInsertionMode_Auto, label)
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            debugLog("VideoEncoder: PrepareToEncodeFrames failed (\(label)): \(prepareStatus)")
            return false
        }
        return true
    }

    private func applyRate(_ rate: RateSettings, to session: VTCompressionSession, label: String) {
        setProperty(session, kVTCompressionPropertyKey_AverageBitRate, rate.bitrateBps as CFNumber, label)
        setProperty(session, kVTCompressionPropertyKey_DataRateLimits, rate.dataRateLimits, label)
        if !usesLowLatencyRateControl && !label.hasSuffix("+LLRC") {
            setProperty(session, kVTCompressionPropertyKey_Quality, rate.quality as CFNumber, label)
        }
    }

    @discardableResult
    private func setProperty(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef, _ label: String) -> Bool {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            debugLog("VideoEncoder: \(key) rejected (\(label)): \(status)")
        }
        return status == noErr
    }

    private func profileLevel(for format: StreamColorFormat) -> CFString {
        switch codec {
        case .hevc:
            return format.bitDepth > 8 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        case .h264:
            return kVTProfileLevel_H264_Main_AutoLevel
        }
    }

    /// Counts failures and logs the first few of each kind, then every 120th,
    /// so a persistently failing session cannot flood the file logger.
    private func noteFailure(_ kind: FailureKind, _ message: @autoclosure () -> String) {
        let count = stateLock.withLock { state -> Int in
            switch kind {
            case .submit:
                state.submitFailures += 1
                return state.submitFailures
            case .output:
                state.outputFailures += 1
                return state.outputFailures
            case .dropped:
                state.droppedFrames += 1
                return state.droppedFrames
            }
        }
        if count <= 5 || count % 120 == 0 {
            debugLog("VideoEncoder: \(message()) (×\(count))")
        }
    }

    // MARK: - Output

    fileprivate func handleOutput(status: OSStatus, infoFlags: VTEncodeInfoFlags,
                                  sampleBuffer: CMSampleBuffer?, captureNanos: UInt64) {
        guard status == noErr else {
            // The encoder's reference state is suspect after an error; resync.
            requestKeyframe()
            noteFailure(.output, "encode output error: \(status)")
            return
        }
        if infoFlags.contains(.frameDropped) {
            noteFailure(.dropped, "frame dropped by encoder")
            return
        }
        guard let sampleBuffer, let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let isKeyframe = Self.isSyncSample(sampleBuffer)
        guard let packet = makePacket(sampleBuffer, dataBuffer: dataBuffer, isKeyframe: isKeyframe) else {
            // A frame the client never sees breaks its reference chain.
            requestKeyframe()
            return
        }
        onEncodedFrame?(EncodedFrame(packet: packet, headerReserve: headerReserve,
                                     captureNanos: captureNanos, isKeyframe: isKeyframe))
    }

    /// `[headerReserve zeros][parameter sets on IDR][access unit]` built with one
    /// allocation and one bulk copy of the block buffer; the AVCC length prefixes
    /// are then rewritten in place as Annex-B start codes.
    private func makePacket(_ sampleBuffer: CMSampleBuffer, dataBuffer: CMBlockBuffer, isKeyframe: Bool) -> Data? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            noteFailure(.output, "encoded sample has no format description")
            return nil
        }
        let getParameterSet = parameterSetGetter
        var parameterSetCount = 0
        var nalHeaderLength: Int32 = 0
        let countStatus = getParameterSet(description, 0, nil, nil, &parameterSetCount, &nalHeaderLength)
        guard countStatus == noErr, nalHeaderLength == 4 else {
            noteFailure(.output, "unsupported NAL length prefix (status \(countStatus), \(nalHeaderLength) bytes)")
            return nil
        }

        var parameterSets: [UnsafeBufferPointer<UInt8>] = []
        if isKeyframe {
            parameterSets.reserveCapacity(parameterSetCount)
            for index in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = getParameterSet(description, index, &pointer, &size, nil, nil)
                guard status == noErr, let pointer else {
                    noteFailure(.output, "parameter set \(index) unavailable: \(status)")
                    return nil
                }
                parameterSets.append(UnsafeBufferPointer(start: pointer, count: size))
            }
        }

        let payloadLength = CMBlockBufferGetDataLength(dataBuffer)
        let parameterBytes = parameterSets.reduce(0) { $0 + 4 + $1.count }
        // Data(count:) is zero-filled, which also yields the zeroed header reserve.
        var packet = Data(count: headerReserve + parameterBytes + payloadLength)
        let built = packet.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var cursor = headerReserve
            for parameterSetBytes in parameterSets {
                Self.writeStartCode(raw, at: cursor)
                cursor += 4
                if let source = parameterSetBytes.baseAddress {
                    (base + cursor).copyMemory(from: source, byteCount: parameterSetBytes.count)
                }
                cursor += parameterSetBytes.count
            }
            let copyStatus = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: payloadLength,
                                                        destination: base + cursor)
            guard copyStatus == kCMBlockBufferNoErr else {
                noteFailure(.output, "block buffer copy failed: \(copyStatus)")
                return false
            }
            guard Self.convertLengthPrefixesToStartCodes(UnsafeMutableRawBufferPointer(rebasing: raw[cursor...])) else {
                noteFailure(.output, "malformed AVCC access unit (\(payloadLength) bytes)")
                return false
            }
            return true
        }
        return built ? packet : nil
    }

    /// `CMVideoFormatDescriptionGet{HEVC,H264}ParameterSetAtIndex` for the
    /// session codec: (description, index, pointerOut, sizeOut, countOut, nalHeaderLengthOut).
    private typealias ParameterSetGetter = (
        CMFormatDescription, Int,
        UnsafeMutablePointer<UnsafePointer<UInt8>?>?, UnsafeMutablePointer<Int>?,
        UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?
    ) -> OSStatus

    private var parameterSetGetter: ParameterSetGetter {
        switch codec {
        case .hevc: return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
        case .h264: return CMVideoFormatDescriptionGetH264ParameterSetAtIndex
        }
    }

    /// Reads `kCMSampleAttachmentKey_NotSync` without bridging the attachments to Swift collections.
    private static func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0,
              let first = CFArrayGetValueAtIndex(attachments, 0) else {
            return true
        }
        let dictionary = unsafeBitCast(first, to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        guard let value = CFDictionaryGetValue(dictionary, key) else { return true }
        return !CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    private static func writeStartCode(_ buffer: UnsafeMutableRawBufferPointer, at offset: Int) {
        buffer[offset] = 0
        buffer[offset + 1] = 0
        buffer[offset + 2] = 0
        buffer[offset + 3] = 1
    }

    /// Rewrites every 4-byte big-endian AVCC NAL length prefix in `buffer` as an
    /// Annex-B start code (`00 00 00 01`), in place. Returns false when a length
    /// runs past the end of the buffer or a trailing prefix is truncated.
    static func convertLengthPrefixesToStartCodes(_ buffer: UnsafeMutableRawBufferPointer) -> Bool {
        var offset = 0
        while offset < buffer.count {
            guard buffer.count - offset >= 4 else { return false }
            let length = Int(buffer[offset]) << 24 | Int(buffer[offset + 1]) << 16
                | Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3])
            writeStartCode(buffer, at: offset)
            offset += 4
            guard length <= buffer.count - offset else { return false }
            offset += length
        }
        return true
    }
}

private let encodingOutputCallback: VTCompressionOutputCallback = { outputRefcon, sourceFrameRefcon, status, infoFlags, sampleBuffer in
    guard let outputRefcon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(outputRefcon).takeUnretainedValue()
    // Inverse of the bit-pattern encoding in `encode`; a nil refcon is capture instant 0.
    let captureNanos = UInt64(UInt(bitPattern: sourceFrameRefcon))
    encoder.handleOutput(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer, captureNanos: captureNanos)
}

/// VideoToolbox tags for the H.273 code points the host can encode.
private extension StreamColorFormat {
    var encoderLabel: String {
        isHDR ? "HDR\(transfer == 18 ? " HLG" : "10") \(bitDepth)-bit" : "SDR BT.709 \(bitDepth)-bit"
    }

    var vtColorPrimaries: CFString? {
        switch primaries {
        case 1: return kCVImageBufferColorPrimaries_ITU_R_709_2
        case 9: return kCVImageBufferColorPrimaries_ITU_R_2020
        default: return nil
        }
    }

    var vtTransferFunction: CFString? {
        switch transfer {
        case 1: return kCVImageBufferTransferFunction_ITU_R_709_2
        case 16: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case 18: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default: return nil
        }
    }

    var vtYCbCrMatrix: CFString? {
        switch matrix {
        case 1: return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case 9: return kCVImageBufferYCbCrMatrix_ITU_R_2020
        default: return nil
        }
    }
}

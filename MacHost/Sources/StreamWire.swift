import Foundation

/// Message type ids: the first byte of every message, in both directions.
enum WireMessage {
    static let legacyVideoFrame: UInt8 = 0
    static let displayConfig: UInt8 = 1
    static let touchEvent: UInt8 = 2
    static let ping: UInt8 = 4
    static let pong: UInt8 = 5
    static let videoFrameWithMetadata: UInt8 = 6
    static let keyframeRequest: UInt8 = 7
    static let clientSupportsFrameMetadata: UInt8 = 8
    /// Client→server, payload-free (old hosts consume 1 byte safely):
    /// "this device has no HEVC decoder".
    static let clientAvcOnly: UInt8 = 9
    /// Server→client, 1-byte payload (StreamCodec.wireId). Sent ONLY to
    /// clients that sent clientAvcOnly — old clients disconnect on unknown
    /// message types, so this must never be sent unsolicited.
    static let codecSelected: UInt8 = 10
    /// Client→server, 4-byte payload: the client's max decode size (issue
    /// #41). Every payload byte has the high bit set, so old hosts that
    /// consume unknown types byte-by-byte skip the payload harmlessly.
    static let clientDecoderLimits: UInt8 = 11
    /// Client→server, payload-free: "I understand desktopGeometry, and I read
    /// displayConfig as the encoded stream size."
    static let clientSupportsDesktopGeometry: UInt8 = 12
    /// Server→client, 8-byte payload: the logical desktop size, for display
    /// only. Sent ONLY to clients that sent clientSupportsDesktopGeometry —
    /// older clients disconnect on unknown message types.
    static let desktopGeometry: UInt8 = 13
    /// Client→server, 12-byte payload: the client's sustainable decode size
    /// at each CodecLimits.tableFps rate (three 4-byte sizes in the type-11
    /// encoding, every byte high-bit set). Sent after type 11, which older
    /// hosts still read; hosts that know this type prefer it (issue #78).
    static let clientDecoderLimitTable: UInt8 = 14
    /// Client→server, 12-byte payload, every byte high-bit set (old hosts skip
    /// it byte by byte): decode/display capabilities and the size the client
    /// presents video in right now. Re-sent whenever it changes (rotation,
    /// fold switch, cutout mode). See `StreamWire.parseClientCapabilities`.
    static let clientCapabilities: UInt8 = 15
    /// Server→client, 8-byte payload: the encoded colour format, fps and host
    /// feature flags. Sent ONLY to clients that sent a valid type 15.
    static let streamFormat: UInt8 = 16
    /// Client→server, 8-byte payload: the client's send instant (Int64 BE).
    /// Clients send it only after receiving type 16.
    static let clockSyncRequest: UInt8 = 17
    /// Server→client, 24-byte payload: t0 echoed, host receive t1, host send t2.
    static let clockSyncResponse: UInt8 = 18
}

/// Pure encoders/decoders for the wire types added with HDR and clock sync
/// (15–18) and the in-place video frame header (types 0 and 6).
enum StreamWire {
    /// Type-15 payload size after the type byte.
    static let clientCapabilitiesPayloadSize = 12
    /// Type-17 payload size after the type byte.
    static let clockSyncRequestPayloadSize = 8
    /// Type-6 header: `[6][size Int32 BE][flags u8][captureNanos UInt64 BE]`.
    /// Every frame packet reserves this many bytes in front of the payload.
    static let frameHeaderSize = 14
    /// Type-0 header: `[0][size Int32 BE]`, written at the END of the reserve.
    static let legacyFrameHeaderSize = 5
    static let streamFormatVersion: UInt8 = 1

    /// Type-16 flags.
    static let streamFormatFlagClockSync: UInt8 = 1 << 0
    static let streamFormatFlagMatchesPanel: UInt8 = 1 << 1

    private enum CapabilityFlag {
        static let decodesHevcMain10 = 1 << 0
        static let displayHDR10 = 1 << 1
        static let displayHLG = 1 << 2
        static let decodesHdr10Profile = 1 << 3
    }

    /// Below this a presentation size is a nonsense report (same floor as type 11).
    private static let minimumPresentationSide = 256
    private static let refreshRange = 24...240

    /// Decodes a type-15 payload (the 12 bytes after the type byte):
    /// `[flagsHi][flagsLo][hzHi][hzLo][nitsHi][nitsLo][pwHi][pwLo][phHi][phLo][0x80|panelKind][0x80|ver]`,
    /// pairs are 14-bit values in two 7-bit groups (high first), nits travel divided by 10.
    /// Returns nil when the size is wrong, any byte lacks bit 7, the version is 0, or the
    /// presentation size is implausible. The refresh rate is clamped to 24...240.
    static func parseClientCapabilities(_ payload: [UInt8]) -> ClientCapabilities? {
        guard payload.count == clientCapabilitiesPayloadSize,
              payload.allSatisfy({ $0 & 0x80 != 0 }) else { return nil }

        func pair(_ offset: Int) -> Int {
            (Int(payload[offset] & 0x7F) << 7) | Int(payload[offset + 1] & 0x7F)
        }

        let flags = pair(0)
        let width = pair(6)
        let height = pair(8)
        let version = Int(payload[11] & 0x7F)
        guard version >= 1,
              width >= minimumPresentationSide,
              height >= minimumPresentationSide else { return nil }

        return ClientCapabilities(
            decodesHevcMain10: flags & CapabilityFlag.decodesHevcMain10 != 0,
            decodesHdr10Profile: flags & CapabilityFlag.decodesHdr10Profile != 0,
            displayHDR10: flags & CapabilityFlag.displayHDR10 != 0,
            displayHLG: flags & CapabilityFlag.displayHLG != 0,
            peakRefreshHz: min(max(pair(2), refreshRange.lowerBound), refreshRange.upperBound),
            maxLuminanceNits: pair(4) * 10,
            presentationWidth: width,
            presentationHeight: height,
            panelKind: Int(payload[10] & 0x7F),
            protocolVersion: version
        )
    }

    /// The complete type-16 message, type byte included:
    /// `[16][ver=1][bitDepth][primaries][transfer][matrix][range][fps][flags]`,
    /// range 1 = full / 0 = limited, fps clamped to 1...255, flags bit0 = clock
    /// sync supported (always set), bit1 = host display matches the client panel.
    static func encodeStreamFormat(_ f: StreamColorFormat, fps: Int, matchesPanel: Bool) -> Data {
        var flags = streamFormatFlagClockSync
        if matchesPanel { flags |= streamFormatFlagMatchesPanel }
        return Data([
            WireMessage.streamFormat,
            streamFormatVersion,
            f.bitDepth,
            f.primaries,
            f.transfer,
            f.matrix,
            f.fullRange ? 1 : 0,
            UInt8(min(max(fps, 1), 255)),
            flags
        ])
    }

    /// The complete type-18 message, type byte included: `[18][t0][t1][t2]`,
    /// each UInt64 BE. t0 is the client's request instant echoed bit for bit;
    /// t1/t2 are host receive/send instants in `DispatchTime` uptime ns.
    static func encodeClockSyncResponse(t0: UInt64, t1: UInt64, t2: UInt64) -> Data {
        var message = Data(capacity: 1 + 3 * MemoryLayout<UInt64>.size)
        message.append(WireMessage.clockSyncResponse)
        for value in [t0, t1, t2] {
            withUnsafeBytes(of: value.bigEndian) { message.append(contentsOf: $0) }
        }
        return message
    }

    /// Writes the frame header into the first `frameHeaderSize` bytes of `packet`
    /// (the reserved prefix) and returns the offset the wire message starts at.
    /// - `legacy == false`: type 6 `[6][size][flags bit0 = keyframe][captureNanos]` at 0.
    /// - `legacy == true`: type 0 `[0][size]` at `frameHeaderSize - legacyFrameHeaderSize`
    ///   (9), so `packet.dropFirst(9)` is byte-identical to the old type-0 stream.
    @discardableResult
    static func writeFrameHeader(into packet: inout Data, payloadSize: Int, isKeyframe: Bool,
                                 captureNanos: UInt64, legacy: Bool) -> Int {
        precondition(packet.count >= frameHeaderSize, "packet lacks the frame header reserve")
        return packet.withUnsafeMutableBytes { buffer in
            writeFrameHeader(to: buffer, payloadSize: payloadSize, isKeyframe: isKeyframe,
                             captureNanos: captureNanos, legacy: legacy)
        }
    }

    /// Same as `writeFrameHeader(into:...)`, on raw memory that holds at least
    /// `frameHeaderSize` bytes.
    static func writeFrameHeader(to buffer: UnsafeMutableRawBufferPointer, payloadSize: Int, isKeyframe: Bool,
                                 captureNanos: UInt64, legacy: Bool) -> Int {
        precondition(buffer.count >= frameHeaderSize, "buffer lacks the frame header reserve")
        let size = Int32(payloadSize).bigEndian
        if legacy {
            let offset = frameHeaderSize - legacyFrameHeaderSize
            buffer[offset] = WireMessage.legacyVideoFrame
            buffer.storeBytes(of: size, toByteOffset: offset + 1, as: Int32.self)
            return offset
        }
        buffer[0] = WireMessage.videoFrameWithMetadata
        buffer.storeBytes(of: size, toByteOffset: 1, as: Int32.self)
        buffer[5] = isKeyframe ? 1 : 0
        buffer.storeBytes(of: captureNanos.bigEndian, toByteOffset: 6, as: UInt64.self)
        return 0
    }
}

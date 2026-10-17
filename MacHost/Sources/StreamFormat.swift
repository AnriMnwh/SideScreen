import Foundation

/// User preference for HDR streaming (UserDefaults key "SideScreen_hdrMode").
enum HDRMode: String, CaseIterable {
    /// HDR10 when the host can produce it and the client can decode and show it.
    case auto
    /// HDR10 whenever the host can produce it and the client speaks the capability protocol.
    case on
    /// Always 8-bit BT.709 SDR (the pre-HDR behaviour).
    case off
}

/// Colour description of the encoded stream, as ITU-T H.273 code points.
/// Sent to the client in wire type 16 so its decoder and surface are tagged correctly.
struct StreamColorFormat: Equatable {
    var bitDepth: UInt8
    var primaries: UInt8
    var transfer: UInt8
    var matrix: UInt8
    var fullRange: Bool

    /// 8-bit BT.709 limited range: the stream every client understands.
    static let sdr709 = StreamColorFormat(bitDepth: 8, primaries: 1, transfer: 1, matrix: 1, fullRange: false)
    /// 10-bit BT.2020 primaries, SMPTE ST 2084 (PQ) transfer, BT.2020 non-constant-luminance matrix.
    static let hdr10 = StreamColorFormat(bitDepth: 10, primaries: 9, transfer: 16, matrix: 9, fullRange: false)

    /// PQ (16) or HLG (18) transfer.
    var isHDR: Bool { transfer == 16 || transfer == 18 }

    /// Picks the stream format for a connection.
    /// - `off`, or a client that never sent capabilities (old peer): `sdr709`.
    /// - `on`: `hdr10` iff the host can capture HDR.
    /// - `auto`: `hdr10` iff the host can capture HDR and the client decodes HEVC Main10 and its panel shows HDR10.
    static func negotiate(mode: HDRMode, hostCanHDR: Bool, client: ClientCapabilities?) -> StreamColorFormat {
        guard let client, hostCanHDR else { return .sdr709 }
        switch mode {
        case .off:
            return .sdr709
        case .on:
            return .hdr10
        case .auto:
            return client.decodesHevcMain10 && client.displayHDR10 ? .hdr10 : .sdr709
        }
    }
}

/// What the client reported in wire type 15.
struct ClientCapabilities: Equatable {
    var decodesHevcMain10: Bool
    var decodesHdr10Profile: Bool
    var displayHDR10: Bool
    var displayHLG: Bool
    /// Highest refresh rate of the client panel, 24...240.
    var peakRefreshHz: Int
    /// Panel peak luminance in nits; 0 when unknown.
    var maxLuminanceNits: Int
    /// Pixels the client shows video in, in its CURRENT orientation
    /// (e.g. 2340×1080 landscape, 1080×2340 portrait), minus cutout insets
    /// when the client is in "avoid cutout" mode.
    var presentationWidth: Int
    var presentationHeight: Int
    /// 0 unknown, 1 built-in default display, 3 external.
    var panelKind: Int
    var protocolVersion: Int
}

/// One encoded access unit, ready for the wire.
struct EncodedFrame {
    /// `[headerReserve zero bytes][Annex-B access unit]`; VPS/SPS/PPS are prepended on IDR frames.
    /// The sender writes its frame header into the reserved prefix in place.
    var packet: Data
    let headerReserve: Int
    /// Capture instant in the `DispatchTime.now().uptimeNanoseconds` domain.
    let captureNanos: UInt64
    let isKeyframe: Bool
}

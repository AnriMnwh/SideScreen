import XCTest
@testable import SideScreen

final class StreamFormatTests: XCTestCase {
    private func caps(main10: Bool, hdr10Display: Bool, hlgDisplay: Bool = false) -> ClientCapabilities {
        ClientCapabilities(
            decodesHevcMain10: main10,
            decodesHdr10Profile: main10,
            displayHDR10: hdr10Display,
            displayHLG: hlgDisplay,
            peakRefreshHz: 120,
            maxLuminanceNits: 1000,
            presentationWidth: 2340,
            presentationHeight: 1080,
            panelKind: 1,
            protocolVersion: 1
        )
    }

    // MARK: - Constants

    func testSdr709CodePoints() {
        let f = StreamColorFormat.sdr709
        XCTAssertEqual(f.bitDepth, 8)
        XCTAssertEqual(f.primaries, 1)
        XCTAssertEqual(f.transfer, 1)
        XCTAssertEqual(f.matrix, 1)
        XCTAssertFalse(f.fullRange)
        XCTAssertFalse(f.isHDR)
    }

    func testHdr10CodePoints() {
        let f = StreamColorFormat.hdr10
        XCTAssertEqual(f.bitDepth, 10)
        XCTAssertEqual(f.primaries, 9)
        XCTAssertEqual(f.transfer, 16)
        XCTAssertEqual(f.matrix, 9)
        XCTAssertFalse(f.fullRange)
        XCTAssertTrue(f.isHDR)
    }

    func testIsHDRFollowsTransferOnly() {
        var f = StreamColorFormat.sdr709
        f.transfer = 18  // HLG
        XCTAssertTrue(f.isHDR)
        f.transfer = 16  // PQ
        XCTAssertTrue(f.isHDR)
        f.transfer = 14  // BT.2020 10-bit SDR transfer
        XCTAssertFalse(f.isHDR)
        var wideSdr = StreamColorFormat.hdr10
        wideSdr.transfer = 1
        XCTAssertFalse(wideSdr.isHDR)
    }

    func testHDRModeRawValuesMatchUserDefaults() {
        XCTAssertEqual(HDRMode.allCases, [.auto, .on, .off])
        XCTAssertEqual(HDRMode(rawValue: "auto"), .auto)
        XCTAssertEqual(HDRMode(rawValue: "on"), .on)
        XCTAssertEqual(HDRMode(rawValue: "off"), .off)
        XCTAssertNil(HDRMode(rawValue: "HDR"))
    }

    // MARK: - negotiate matrix

    /// Every combination of mode × hostCanHDR × client (nil, or Main10 decode × HDR10 panel).
    func testNegotiateFullMatrix() {
        let clients: [(String, ClientCapabilities?)] = [
            ("nil", nil),
            ("noMain10/noHDR", caps(main10: false, hdr10Display: false)),
            ("main10/noHDR", caps(main10: true, hdr10Display: false)),
            ("noMain10/HDR", caps(main10: false, hdr10Display: true)),
            ("main10/HDR", caps(main10: true, hdr10Display: true))
        ]
        for mode in HDRMode.allCases {
            for hostCanHDR in [false, true] {
                for (name, client) in clients {
                    let expected: StreamColorFormat
                    switch (mode, hostCanHDR, client) {
                    case (_, false, _), (_, _, nil), (.off, _, _):
                        expected = .sdr709
                    case (.on, true, .some):
                        expected = .hdr10
                    case let (.auto, true, .some(c)):
                        expected = c.decodesHevcMain10 && c.displayHDR10 ? .hdr10 : .sdr709
                    }
                    XCTAssertEqual(
                        StreamColorFormat.negotiate(mode: mode, hostCanHDR: hostCanHDR, client: client),
                        expected,
                        "mode=\(mode) hostCanHDR=\(hostCanHDR) client=\(name)"
                    )
                }
            }
        }
    }

    func testAutoNeedsBothMain10AndHDR10Panel() {
        XCTAssertEqual(StreamColorFormat.negotiate(mode: .auto, hostCanHDR: true, client: caps(main10: true, hdr10Display: true)), .hdr10)
        XCTAssertEqual(StreamColorFormat.negotiate(mode: .auto, hostCanHDR: true, client: caps(main10: true, hdr10Display: false)), .sdr709)
        XCTAssertEqual(StreamColorFormat.negotiate(mode: .auto, hostCanHDR: true, client: caps(main10: false, hdr10Display: true)), .sdr709)
    }

    func testAutoIgnoresHLGOnlyPanel() {
        let hlgOnly = caps(main10: true, hdr10Display: false, hlgDisplay: true)
        XCTAssertEqual(StreamColorFormat.negotiate(mode: .auto, hostCanHDR: true, client: hlgOnly), .sdr709)
    }

    func testOnForcesHDRForCapableHostEvenWithoutClientHDR() {
        XCTAssertEqual(StreamColorFormat.negotiate(mode: .on, hostCanHDR: true, client: caps(main10: false, hdr10Display: false)), .hdr10)
    }

    func testOnWithoutHostHDRIsSDR() {
        XCTAssertEqual(StreamColorFormat.negotiate(mode: .on, hostCanHDR: false, client: caps(main10: true, hdr10Display: true)), .sdr709)
    }

    func testOldClientWithoutCapabilitiesIsAlwaysSDR() {
        for mode in HDRMode.allCases {
            XCTAssertEqual(StreamColorFormat.negotiate(mode: mode, hostCanHDR: true, client: nil), .sdr709, "mode=\(mode)")
        }
    }

    func testOffIsAlwaysSDR() {
        XCTAssertEqual(StreamColorFormat.negotiate(mode: .off, hostCanHDR: true, client: caps(main10: true, hdr10Display: true)), .sdr709)
    }

    // MARK: - Encoder constants

    func testEncoderConstants() {
        XCTAssertEqual(VideoEncoder.minimumBitrateMbps, 20)
        XCTAssertEqual(VideoEncoder.keyframeIntervalSeconds, 60)
    }
}

/// The encoder's in-place AVCC → Annex-B rewrite (no per-NAL copies).
final class AnnexBConversionTests: XCTestCase {
    private func convert(_ bytes: [UInt8]) -> (Bool, [UInt8]) {
        var data = Data(bytes)
        let ok = data.withUnsafeMutableBytes { VideoEncoder.convertLengthPrefixesToStartCodes($0) }
        return (ok, [UInt8](data))
    }

    func testRewritesEveryLengthPrefixInPlace() {
        let avcc: [UInt8] = [
            0, 0, 0, 3, 0x40, 0x01, 0x0C,       // 3-byte NAL
            0, 0, 0, 1, 0x26,                   // 1-byte NAL
            0, 0, 1, 0                          // 256-byte NAL follows
        ] + [UInt8](repeating: 0xAB, count: 256)
        let (ok, out) = convert(avcc)
        XCTAssertTrue(ok)
        XCTAssertEqual(out.count, avcc.count)
        XCTAssertEqual(Array(out[0..<7]), [0, 0, 0, 1, 0x40, 0x01, 0x0C])
        XCTAssertEqual(Array(out[7..<12]), [0, 0, 0, 1, 0x26])
        XCTAssertEqual(Array(out[12..<16]), [0, 0, 0, 1])
        XCTAssertEqual(Array(out[16...]), [UInt8](repeating: 0xAB, count: 256))
    }

    func testEmptyBufferIsValid() {
        let (ok, out) = convert([])
        XCTAssertTrue(ok)
        XCTAssertTrue(out.isEmpty)
    }

    func testLengthPastEndIsRejected() {
        XCTAssertFalse(convert([0, 0, 0, 5, 1, 2, 3]).0)
    }

    func testTruncatedTrailingPrefixIsRejected() {
        XCTAssertFalse(convert([0, 0, 0, 1, 0x26, 0, 0]).0)
    }
}

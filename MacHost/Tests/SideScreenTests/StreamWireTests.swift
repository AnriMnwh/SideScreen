import Foundation
import Network
import os
import XCTest
@testable import SideScreen

final class StreamWireTests: XCTestCase {
    // MARK: - Type 15 (client capabilities)

    /// Landscape 2340×1080, Main10 + HDR10 profile + HDR10 panel, 120 Hz, 1000 nits.
    private let landscapeAdvert: [UInt8] = [0x80, 0x8B, 0x80, 0xF8, 0x80, 0xE4, 0x92, 0xA4, 0x88, 0xB8, 0x81, 0x81]
    /// Portrait 1080×2340, SDR-only, 60 Hz, luminance unknown.
    private let portraitAdvert: [UInt8] = [0x80, 0x80, 0x80, 0xBC, 0x80, 0x80, 0x88, 0xB8, 0x92, 0xA4, 0x81, 0x81]

    private let landscapeCapabilities = ClientCapabilities(
        decodesHevcMain10: true, decodesHdr10Profile: true, displayHDR10: true, displayHLG: false,
        peakRefreshHz: 120, maxLuminanceNits: 1000, presentationWidth: 2340, presentationHeight: 1080,
        panelKind: 1, protocolVersion: 1
    )

    private let portraitCapabilities = ClientCapabilities(
        decodesHevcMain10: false, decodesHdr10Profile: false, displayHDR10: false, displayHLG: false,
        peakRefreshHz: 60, maxLuminanceNits: 0, presentationWidth: 1080, presentationHeight: 2340,
        panelKind: 1, protocolVersion: 1
    )

    func testParsesLandscapeAdvert() {
        XCTAssertEqual(StreamWire.parseClientCapabilities(landscapeAdvert), landscapeCapabilities)
    }

    func testParsesPortraitAdvert() {
        XCTAssertEqual(StreamWire.parseClientCapabilities(portraitAdvert), portraitCapabilities)
    }

    func testParsesFoldInnerAdvertWithEveryFlag() {
        // Fold inner 2448×1848, all four flags, 1500 nits, external panel kind 3.
        let advert: [UInt8] = [0x80, 0x8F, 0x80, 0xF8, 0x81, 0x96, 0x93, 0x90, 0x8E, 0xB8, 0x83, 0x81]
        XCTAssertEqual(
            StreamWire.parseClientCapabilities(advert),
            ClientCapabilities(
                decodesHevcMain10: true, decodesHdr10Profile: true, displayHDR10: true, displayHLG: true,
                peakRefreshHz: 120, maxLuminanceNits: 1500, presentationWidth: 2448, presentationHeight: 1848,
                panelKind: 3, protocolVersion: 1
            )
        )
    }

    func testRejectsAdvertWithAnyByteMissingBit7() {
        for index in landscapeAdvert.indices {
            var advert = landscapeAdvert
            advert[index] &= 0x7F
            XCTAssertNil(StreamWire.parseClientCapabilities(advert), "byte \(index) without bit7 must be rejected")
        }
    }

    func testRejectsWrongSizeVersionZeroAndNonsenseGeometry() {
        XCTAssertNil(StreamWire.parseClientCapabilities(Array(landscapeAdvert.dropLast())))
        XCTAssertNil(StreamWire.parseClientCapabilities(landscapeAdvert + [0x80]))

        var versionZero = landscapeAdvert
        versionZero[11] = 0x80
        XCTAssertNil(StreamWire.parseClientCapabilities(versionZero))

        var tinyWidth = landscapeAdvert
        tinyWidth[6] = 0x80
        tinyWidth[7] = 0x80
        XCTAssertNil(StreamWire.parseClientCapabilities(tinyWidth))
    }

    func testClampsRefreshRate() {
        var tooFast = landscapeAdvert
        tooFast[2] = 0x82  // 300 Hz = 2 << 7 | 44
        tooFast[3] = 0xAC
        XCTAssertEqual(StreamWire.parseClientCapabilities(tooFast)?.peakRefreshHz, 240)

        var unknown = landscapeAdvert
        unknown[2] = 0x80
        unknown[3] = 0x80
        XCTAssertEqual(StreamWire.parseClientCapabilities(unknown)?.peakRefreshHz, 24)
    }

    // MARK: - Type 16 (stream format)

    func testStreamFormatGoldenHDR10At120MatchingPanel() {
        XCTAssertEqual(
            Array(StreamWire.encodeStreamFormat(.hdr10, fps: 120, matchesPanel: true)),
            [16, 1, 10, 9, 16, 9, 0, 120, 0x03]
        )
    }

    func testStreamFormatGoldenSDR709At60() {
        XCTAssertEqual(
            Array(StreamWire.encodeStreamFormat(.sdr709, fps: 60, matchesPanel: false)),
            [16, 1, 8, 1, 1, 1, 0, 60, 0x01]
        )
    }

    func testStreamFormatFullRangeAndFpsClamp() {
        var fullRange = StreamColorFormat.sdr709
        fullRange.fullRange = true
        let message = Array(StreamWire.encodeStreamFormat(fullRange, fps: 300, matchesPanel: false))
        XCTAssertEqual(message[6], 1)
        XCTAssertEqual(message[7], 255)
        XCTAssertEqual(StreamWire.encodeStreamFormat(.sdr709, fps: 0, matchesPanel: false)[7], 1)
    }

    // MARK: - Type 18 (clock sync response)

    func testClockSyncResponseLayout() {
        let message = StreamWire.encodeClockSyncResponse(
            t0: 0x0102_0304_0506_0708,
            t1: 0x1112_1314_1516_1718,
            t2: 0x2122_2324_2526_2728
        )
        XCTAssertEqual(Array(message), [
            18,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
            0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28
        ])
    }

    func testClockSyncResponseEchoesNegativeClientTimestampBitForBit() {
        let t0 = UInt64(bitPattern: -2)
        let message = StreamWire.encodeClockSyncResponse(t0: t0, t1: 0, t2: 0)
        XCTAssertEqual(Array(message[1...8]), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE])
    }

    // MARK: - Frame header

    private let payload: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0xAF]

    private func reservedPacket() -> Data {
        Data(repeating: 0, count: StreamingServer.frameHeaderReserve) + Data(payload)
    }

    func testFrameHeaderReserveFitsMetadataHeader() {
        XCTAssertEqual(StreamingServer.frameHeaderReserve, 14)
        XCTAssertEqual(StreamWire.frameHeaderSize, 14)
    }

    func testWriteFrameHeaderMetadataMode() {
        var packet = reservedPacket()
        let offset = StreamWire.writeFrameHeader(
            into: &packet, payloadSize: payload.count, isKeyframe: true,
            captureNanos: 0x1122_3344_5566_7788, legacy: false
        )
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(
            Array(packet),
            [6, 0, 0, 0, 7, 1, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88] + payload
        )

        var delta = reservedPacket()
        StreamWire.writeFrameHeader(into: &delta, payloadSize: payload.count, isKeyframe: false,
                                    captureNanos: 1, legacy: false)
        XCTAssertEqual(delta[5], 0)
    }

    func testWriteFrameHeaderLegacyModeMatchesOldType0Bytes() {
        var packet = reservedPacket()
        let offset = StreamWire.writeFrameHeader(
            into: &packet, payloadSize: payload.count, isKeyframe: true,
            captureNanos: 0x1122_3344_5566_7788, legacy: true
        )
        XCTAssertEqual(offset, 9)
        // Exactly what the old makeFramePacket built: [0][Int32 BE size][AU].
        XCTAssertEqual(Array(packet.dropFirst(offset)), [0, 0, 0, 0, 7] + payload)
        XCTAssertEqual(Array(packet.prefix(offset)), [UInt8](repeating: 0, count: 9))
    }

    func testWriteFrameHeaderHonoursSliceStartIndex() {
        let backing = Data([0xEE, 0xEE, 0xEE]) + reservedPacket()
        var packet = backing[3...]
        let offset = StreamWire.writeFrameHeader(into: &packet, payloadSize: payload.count, isKeyframe: false,
                                                 captureNanos: 0, legacy: true)
        XCTAssertEqual(Array(packet.dropFirst(offset)), [0, 0, 0, 0, 7] + payload)
    }

    // MARK: - StreamingServer over loopback

    func testServerWithoutClientIsNotBackpressuredAndDropsFrames() {
        let server = StreamingServer(port: 0)
        XCTAssertFalse(server.isBackpressured)
        server.sendFrame(frame(isKeyframe: true, captureNanos: 1))
        XCTAssertFalse(server.isBackpressured)
        XCTAssertNil(server.clientCapabilities)
        XCTAssertFalse(server.clientIsLoopback)
    }

    func testLegacyClientGetsOnlyTodaysBytes() async throws {
        let server = StreamingServer(port: 0)
        defer { server.stop() }
        server.setDisplaySize(width: 1920, height: 1080)
        server.onCodecNegotiated = { [weak server] _ in
            server?.setStreamFormat(.sdr709, fps: 60, matchesPanel: false)
        }
        let connected = ListenerStartupGate()
        server.onClientConnected = { connected.resolve(.success(())) }
        try await server.start()

        let client = try await connectClient(to: server)
        defer { client.cancel() }

        // No type 8/15 from the client: the 100 ms grace ends startup with a
        // bare display config and no type 16.
        let config = try await receive(13, on: client)
        XCTAssertEqual(Array(config), [1, 0, 0, 0x07, 0x80, 0, 0, 0x04, 0x38, 0, 0, 0, 0])
        try await connected.wait()
        XCTAssertNil(server.clientCapabilities)
        XCTAssertTrue(server.clientIsLoopback)

        server.sendFrame(frame(isKeyframe: false, captureNanos: 5))  // dropped: no keyframe yet
        server.sendFrame(frame(isKeyframe: true, captureNanos: 6))
        let packet = try await receive(5 + payload.count, on: client)
        XCTAssertEqual(Array(packet), [0, 0, 0, 0, 7] + payload)

        try await assertBackpressureDrains(server)
    }

    func testCapableClientGetsFormatBeforeDisplayConfigClockSyncAndReAdverts() async throws {
        let server = StreamingServer(port: 0)
        defer { server.stop() }
        server.setDisplaySize(width: 2340, height: 1080)
        server.onCodecNegotiated = { [weak server] _ in
            server?.setStreamFormat(.hdr10, fps: 120, matchesPanel: true)
        }
        let connected = ListenerStartupGate()
        server.onClientConnected = { connected.resolve(.success(())) }
        let readvertised = ListenerStartupGate()
        let reported = OSAllocatedUnfairLock<ClientCapabilities?>(initialState: nil)
        server.onClientCapabilities = { capabilities in
            reported.withLock { $0 = capabilities }
            readvertised.resolve(.success(()))
        }
        try await server.start()

        let client = try await connectClient(to: server)
        defer { client.cancel() }

        try await send([WireMessage.clientCapabilities] + landscapeAdvert + [WireMessage.clientSupportsFrameMetadata],
                       on: client)

        let format = try await receive(9, on: client)
        XCTAssertEqual(Array(format), [16, 1, 10, 9, 16, 9, 0, 120, 0x03])
        let config = try await receive(13, on: client)
        XCTAssertEqual(Array(config), [1, 0, 0, 0x09, 0x24, 0, 0, 0x04, 0x38, 0, 0, 0, 0])
        try await connected.wait()
        XCTAssertEqual(server.clientCapabilities, landscapeCapabilities)

        // Type 17 → 18: t0 echoed, t1 ≤ t2, both in this process's uptime clock.
        let t0: UInt64 = 0x0102_0304_0506_0708
        let before = DispatchTime.now().uptimeNanoseconds
        try await send([WireMessage.clockSyncRequest] + bigEndianBytes(t0), on: client)
        let responseData = try await receive(25, on: client)
        let response = Array(responseData)
        let after = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(response[0], 18)
        XCTAssertEqual(bigEndianUInt64(response, at: 1), t0)
        let t1 = bigEndianUInt64(response, at: 9)
        let t2 = bigEndianUInt64(response, at: 17)
        XCTAssertLessThanOrEqual(before, t1)
        XCTAssertLessThanOrEqual(t1, t2)
        XCTAssertLessThanOrEqual(t2, after)

        // Type 6 carries the capture instant; P-frames wait for a keyframe.
        server.sendFrame(frame(isKeyframe: false, captureNanos: 7))
        server.sendFrame(frame(isKeyframe: true, captureNanos: 0x1122_3344_5566_7788))
        let packet = try await receive(14 + payload.count, on: client)
        XCTAssertEqual(Array(packet), [6, 0, 0, 0, 7, 1, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88] + payload)

        // Rotation: a changed advert after startup reaches the owner.
        try await send([WireMessage.clientCapabilities] + portraitAdvert, on: client)
        try await readvertised.wait()
        XCTAssertEqual(reported.withLock { $0 }, portraitCapabilities)
        XCTAssertEqual(server.clientCapabilities, portraitCapabilities)

        // Re-mode: new format goes out at once; the new segment starts on a keyframe.
        server.setStreamFormat(.sdr709, fps: 60, matchesPanel: true)
        let newFormat = try await receive(9, on: client)
        XCTAssertEqual(Array(newFormat), [16, 1, 8, 1, 1, 1, 0, 60, 0x03])
        server.beginNewStreamSegment()
        server.sendFrame(frame(isKeyframe: false, captureNanos: 8))
        server.sendFrame(frame(isKeyframe: true, captureNanos: 9))
        let segmentStart = try await receive(14 + payload.count, on: client)
        XCTAssertEqual(Array(segmentStart), [6, 0, 0, 0, 7, 1, 0, 0, 0, 0, 0, 0, 0, 9] + payload)

        try await assertBackpressureDrains(server)
    }

    /// Re-mode wire order (plan §9), as `ScreenCapture.startNewSegment` drives
    /// it: the retired encoder's sink is closed, then the new segment and
    /// display config, then the new encoder. Nothing of the old encoder — not
    /// even a flushed keyframe — may follow the display config or satisfy the
    /// new segment's sync.
    func testNewSegmentDisplayConfigPrecedesFirstFrameAndRetiredEncoderIsCutOff() async throws {
        let server = StreamingServer(port: 0)
        defer { server.stop() }
        server.setDisplaySize(width: 2340, height: 1080)
        server.onCodecNegotiated = { [weak server] _ in
            server?.setStreamFormat(.sdr709, fps: 60, matchesPanel: true)
        }
        let connected = ListenerStartupGate()
        server.onClientConnected = { connected.resolve(.success(())) }
        try await server.start()

        let client = try await connectClient(to: server)
        defer { client.cancel() }
        try await send([WireMessage.clientCapabilities] + landscapeAdvert + [WireMessage.clientSupportsFrameMetadata],
                       on: client)
        _ = try await receive(9, on: client)   // type 16
        _ = try await receive(13, on: client)  // landscape display config
        try await connected.wait()

        let oldSink = EncodedFrameSink(server: server)
        oldSink.deliver(frame(isKeyframe: true, captureNanos: 1))
        let oldFrame = try await receive(14 + payload.count, on: client)
        XCTAssertEqual(oldFrame[13], 1)

        oldSink.close()
        server.beginNewStreamSegment()
        server.setDisplaySize(width: 1080, height: 2340)
        server.sendDisplaySize()
        oldSink.deliver(frame(isKeyframe: true, captureNanos: 2))  // flushed by the retired encoder
        let newSink = EncodedFrameSink(server: server)
        newSink.deliver(frame(isKeyframe: false, captureNanos: 3))  // segment waits for a keyframe
        newSink.deliver(frame(isKeyframe: true, captureNanos: 4))

        let config = try await receive(13, on: client)
        XCTAssertEqual(Array(config), [1, 0, 0, 0x04, 0x38, 0, 0, 0x09, 0x24, 0, 0, 0, 0])
        let segmentStart = try await receive(14 + payload.count, on: client)
        XCTAssertEqual(Array(segmentStart), [6, 0, 0, 0, 7, 1, 0, 0, 0, 0, 0, 0, 0, 4] + payload)

        try await assertBackpressureDrains(server)
    }

    // MARK: - Helpers

    private let clientQueue = DispatchQueue(label: "StreamWireTests.client")

    private func frame(isKeyframe: Bool, captureNanos: UInt64) -> EncodedFrame {
        EncodedFrame(packet: reservedPacket(), headerReserve: StreamingServer.frameHeaderReserve,
                     captureNanos: captureNanos, isKeyframe: isKeyframe)
    }

    private func connectClient(to server: StreamingServer) async throws -> NWConnection {
        let port = try XCTUnwrap(server.boundPort.flatMap { NWEndpoint.Port(rawValue: $0) })
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let ready = ListenerStartupGate()
        client.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.resolve(.success(()))
            case .failed(let error):
                ready.resolve(.failure(error))
            case .cancelled:
                ready.resolve(.failure(CancellationError()))
            default:
                break
            }
        }
        client.start(queue: clientQueue)
        // Watchdog: a missing message fails the pending receive instead of hanging the run.
        clientQueue.asyncAfter(deadline: .now() + 10) { [weak client] in
            client?.cancel()
        }
        try await ready.wait()
        return client
    }

    private func send(_ bytes: [UInt8], on client: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receive(_ count: Int, on client: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            client.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    private func assertBackpressureDrains(_ server: StreamingServer) async throws {
        let deadline = Date().addingTimeInterval(2)
        while server.isBackpressured, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(server.isBackpressured, "send completions must release the in-flight budget")
    }

    private func bigEndianBytes(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func bigEndianUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        bytes[offset..<offset + 8].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

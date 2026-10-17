import Foundation
import Network
import os

private extension NWEndpoint {
    var isLoopback: Bool {
        switch self {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let v4): return v4.isLoopback
            case .ipv6(let v6): return v6.isLoopback
            case .name(let name, _): return name == "localhost"
            @unknown default: return false
            }
        default:
            return false
        }
    }
}

enum StreamingServerStartError: LocalizedError {
    case listenerFailed(port: UInt16, underlying: Error)
    case cancelledBeforeReady(port: UInt16)
    case startupTimedOut(port: UInt16, lastWaitingError: Error?)

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let port, let underlying):
            return "Could not listen on port \(port): \(underlying.localizedDescription)"
        case .cancelledBeforeReady(let port):
            return "Server startup on port \(port) was cancelled before the listener became ready."
        case .startupTimedOut(let port, let lastWaitingError):
            let detail = lastWaitingError.map { " Last listener error: \($0.localizedDescription)" } ?? ""
            return "Timed out while waiting for the server to listen on port \(port).\(detail)"
        }
    }
}

/// Bridges NWListener's state callback to async startup without risking a
/// leaked or double-resumed continuation. The listener may publish a state
/// before `wait()` installs its continuation, so the first result is cached.
final class ListenerStartupGate: @unchecked Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Void, Error>)
        case completed(Result<Void, Error>)
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var lastWaitingError: Error?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completedResult: Result<Void, Error>?
                lock.lock()
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    completedResult = nil
                case .completed(let result):
                    completedResult = result
                case .waiting:
                    // A StreamingServer has exactly one startup waiter.
                    completedResult = .failure(
                        NSError(
                            domain: "StreamingServer",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Server startup was awaited more than once."]
                        )
                    )
                }
                lock.unlock()

                if let completedResult {
                    continuation.resume(with: completedResult)
                }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    func noteWaitingError(_ error: Error) {
        lock.lock()
        lastWaitingError = error
        lock.unlock()
    }

    func resolveTimeout(port: UInt16) {
        lock.lock()
        let waitingError = lastWaitingError
        lock.unlock()
        resolve(.failure(StreamingServerStartError.startupTimedOut(port: port, lastWaitingError: waitingError)))
    }

    func resolve(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        switch state {
        case .pending:
            state = .completed(result)
            continuation = nil
        case .waiting(let waiter):
            state = .completed(result)
            continuation = waiter
        case .completed:
            continuation = nil
        }
        lock.unlock()

        continuation?.resume(with: result)
    }
}

class StreamingServer {
    private let port: UInt16
    private var listener: NWListener?
    /// The current client connection. Lives in `sendState` because the
    /// encoder thread reads it for every frame.
    private var connection: NWConnection? {
        sendState.withLockUnchecked { $0.connection }
    }
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    /// Fired once per connection during protocol startup, BEFORE the display
    /// config is sent, for every outcome (.hevc or .h264) — so the capture
    /// pipeline can also revert to HEVC after an AVC-only client goes away.
    var onCodecNegotiated: ((StreamCodec) -> Void)?
    // Touch callback: (x1, y1, action, pointerCount, x2, y2)
    var onTouchEvent: ((Float, Float, Int, Int, Float, Float) -> Void)?
    var onStats: ((Double, Double) -> Void)?
    var onKeyframeRequested: ((Bool) -> Void)?
    /// Fired on the network queue with every type-15 advert that differs from
    /// the previous one and arrives after protocol startup (rotation, fold
    /// switch, cutout-mode change, first late advert). Adverts that land
    /// before startup are only stored: read `clientCapabilities` from
    /// `onCodecNegotiated`.
    var onClientCapabilities: ((ClientCapabilities) -> Void)?
    // Whether host wants to receive touch events from client. Ping/pong is
    // handled regardless. When false, incoming touch frames are dropped
    // immediately without parsing or dispatching to main queue.
    var touchEnabled: Bool = true

    // Wireless auth: when non-nil, non-loopback connections must present this
    // 32-byte token before being allowed to proceed. nil means wireless mode
    // is inactive — non-loopback connections are rejected immediately.
    var expectedAuthToken: Data?
    var onWirelessClientPaired: ((String) -> Void)?

    // Code pairing (issue #35): when non-nil, a pre-auth "SSPC" request
    // carrying this one-time code is answered with the real auth token, and
    // the client reconnects through the normal SSWA handshake. Only honored
    // while wireless mode is active (expectedAuthToken != nil).
    //
    // The code is written from the main thread (rotation) and read on
    // networkQueue (validation), so state lives behind a lock — and
    // validate-and-consume is a single critical section, so a code can never
    // be redeemed twice and pipelined guesses can never exceed the attempt
    // budget before the invalidation lands.
    private struct PairingState {
        var code: String?
        var failedAttempts = 0
    }

    private let pairingStateLock = OSAllocatedUnfairLock(initialState: PairingState())
    private static let maxPairingAttempts = 5

    var expectedPairingCode: String? {
        get { pairingStateLock.withLock { $0.code } }
        set {
            pairingStateLock.withLock { state in
                state.code = newValue
                state.failedAttempts = 0
            }
        }
    }

    var pairingMacName: String = "Mac"
    /// Fired with the device name after a code was accepted and the token
    /// issued. The code is already consumed (nil); the owner should install a
    /// fresh one.
    var onPairingSuccess: ((String) -> Void)?
    /// Fired when the attempt budget is exhausted. The code is already
    /// invalidated (nil); the owner should install a fresh one.
    var onPairingCodeExhausted: (() -> Void)?

    /// Type-6/0 header bytes every `EncodedFrame` must reserve in front of its payload.
    static let frameHeaderReserve = StreamWire.frameHeaderSize
    /// `isBackpressured` limits: frames handed to the socket whose send has not completed.
    private static let maxFramesInFlight = 2
    private static let maxBytesInFlight = 1_500_000

    private struct SendStats {
        var bytesSent: UInt64 = 0
        var frameCount: UInt64 = 0
        var droppedFrames: UInt64 = 0
        var totalFrameAgeNs: UInt64 = 0
        var profiledFrameCount: UInt64 = 0
        var windowStartNs = DispatchTime.now().uptimeNanoseconds
    }

    /// Everything `sendFrame` (encoder thread), `setStreamFormat` (any thread)
    /// and the network queue share. Per-connection fields are reset in
    /// `handleConnection`; `streamFormatMessage` outlives connections.
    private struct SendState {
        var connection: NWConnection?
        /// Bumped per connection so late send completions of a replaced
        /// connection never touch the new connection's counters.
        var generation: UInt64 = 0
        /// Protocol startup finished: the display config went out, frames flow.
        var ready = false
        /// Client sent type 8: frames go out as type 6, else legacy type 0.
        var frameMetadata = false
        /// Drop frames until the next keyframe (new client or new stream segment).
        var waitingForSyncFrame = false
        var inFlightFrames = 0
        var inFlightBytes = 0
        var stats = SendStats()
        /// Last valid type-15 advert of this connection; gates types 16 and 18.
        var capabilities: ClientCapabilities?
        /// Type 16 may go out (startup reached the display-config step).
        var streamFormatAllowed = false
        /// Latest type-16 message from `setStreamFormat`.
        var streamFormatMessage: Data?
        /// Type-16 message last sent on this connection; gates type 18.
        var sentStreamFormat: Data?
    }

    private let sendState = OSAllocatedUnfairLock(uncheckedState: SendState())
    private let networkQueue = DispatchQueue(label: "networkQueue", qos: .userInteractive)
    private var displayWidth = 1920
    private var displayHeight = 1080
    private var rotation = 0
    private var flipHorizontal = false
    private var flipVertical = false
    private var isReceiving = false
    private var isStopped = false
    private var clientIsAvcOnly = false
    /// The connected client reached us over loopback (USB via `adb reverse`).
    private(set) var clientIsLoopback = false
    /// Max decode size reported by the connected client (issue #41).
    private(set) var clientDecodeLimits: (width: Int, height: Int)?
    /// Sustainable decode size per frame rate (type 14), keyed by fps.
    private(set) var clientDecodeLimitTable: [Int: (width: Int, height: Int)]?
    /// Set when the client opts in via type 12. Gates desktopGeometry sends.
    private var clientSupportsDesktopGeometry = false
    /// Logical desktop size, reported alongside the encoded size for display.
    private var desktopWidth = 0
    private var desktopHeight = 0
    private var inputBuffer = Data()

    private var connectionReady: Bool {
        sendState.withLockUnchecked { $0.ready }
    }

    private var clientSupportsFrameMetadata: Bool {
        sendState.withLockUnchecked { $0.frameMetadata }
    }

    /// Latest valid type-15 advert of the current connection (nil for clients
    /// that never sent one).
    var clientCapabilities: ClientCapabilities? {
        sendState.withLockUnchecked { $0.capabilities }
    }

    /// True while the socket lags: at least `maxFramesInFlight` frames or more
    /// than `maxBytesInFlight` bytes handed to it have not finished sending.
    /// The capture pipeline skips encoding while this holds.
    var isBackpressured: Bool {
        sendState.withLockUnchecked {
            $0.inFlightFrames >= Self.maxFramesInFlight || $0.inFlightBytes > Self.maxBytesInFlight
        }
    }

    init(port: UInt16) {
        self.port = port
    }

    var boundPort: UInt16? {
        listener?.port?.rawValue
    }

    func start(startupTimeout: TimeInterval = 10) async throws {
        isStopped = false
        let startupGate = ListenerStartupGate()
        let startupPort = port

        let newListener: NWListener
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            // Optimize TCP for low-latency streaming
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true  // Disable Nagle's algorithm
            }

            newListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
        } catch {
            debugLog("Failed to start server: \(error)")
            throw StreamingServerStartError.listenerFailed(port: port, underlying: error)
        }

        listener = newListener
        newListener.newConnectionHandler = { [weak self] newConnection in
            self?.handleConnection(newConnection)
        }

        newListener.stateUpdateHandler = { [weak self, startupGate] state in
            guard let self else {
                startupGate.resolve(.failure(CancellationError()))
                return
            }
            switch state {
            case .ready:
                debugLog("TCP Server listening on port \(self.port)")
                startupGate.resolve(.success(()))
            case .waiting(let error):
                debugLog("Server waiting to listen: \(error)")
                if case .posix(.EADDRINUSE) = error {
                    startupGate.resolve(
                        .failure(StreamingServerStartError.listenerFailed(port: self.port, underlying: error))
                    )
                } else {
                    startupGate.noteWaitingError(error)
                }
            case .failed(let error):
                debugLog("Server failed: \(error)")
                startupGate.resolve(
                    .failure(StreamingServerStartError.listenerFailed(port: self.port, underlying: error))
                )
            case .cancelled:
                startupGate.resolve(
                    .failure(StreamingServerStartError.cancelledBeforeReady(port: self.port))
                )
            default:
                break
            }
        }

        let timeoutWorkItem = DispatchWorkItem { [startupGate] in
            startupGate.resolveTimeout(port: startupPort)
        }
        networkQueue.asyncAfter(
            deadline: .now() + max(0, startupTimeout),
            execute: timeoutWorkItem
        )
        newListener.start(queue: networkQueue)

        defer { timeoutWorkItem.cancel() }
        do {
            try await startupGate.wait()
            try Task.checkCancellation()
        } catch {
            newListener.cancel()
            if listener === newListener {
                listener = nil
            }
            debugLog("Failed to start server: \(error)")
            throw error
        }
    }

    private func handleConnection(_ newConnection: NWConnection) {
        debugLog("New connection incoming...")

        // Swap the connection and reset every per-connection send field in one
        // critical section, so the encoder thread never sends a frame to the
        // new client under the old client's framing.
        let oldConnection = sendState.withLockUnchecked { state -> NWConnection? in
            let old = state.connection
            state.connection = newConnection
            state.generation &+= 1
            state.ready = false
            state.frameMetadata = false
            state.waitingForSyncFrame = true
            state.inFlightFrames = 0
            state.inFlightBytes = 0
            state.stats.droppedFrames = 0
            state.capabilities = nil
            state.streamFormatAllowed = false
            state.sentStreamFormat = nil
            return old
        }
        // Clean up old connection properly
        if let oldConnection {
            isReceiving = false
            oldConnection.cancel()
        }

        clientIsAvcOnly = false
        clientIsLoopback = false
        clientDecodeLimits = nil
        clientDecodeLimitTable = nil
        clientSupportsDesktopGeometry = false
        inputBuffer.removeAll(keepingCapacity: true)

        newConnection.stateUpdateHandler = { [weak self] state in
            debugLog("Connection state: \(state)")
            guard let self = self else { return }
            switch state {
            case .ready:
                guard self.connection === newConnection else { return }
                self.onConnectionReady(newConnection)
            case .failed(let error):
                debugLog("Connection failed: \(error)")
                if self.connection === newConnection {
                    self.onClientDisconnected?()
                }
            case .cancelled:
                debugLog("Connection cancelled")
                if self.connection === newConnection {
                    self.onClientDisconnected?()
                }
            default:
                break
            }
        }

        newConnection.start(queue: networkQueue)
    }

    private func onConnectionReady(_ conn: NWConnection) {
        clientIsLoopback = conn.endpoint.isLoopback
        if clientIsLoopback {
            debugLog("Client connected via loopback (USB) — skipping auth")
            beginExistingProtocol(on: conn)
            return
        }
        guard let expected = expectedAuthToken else {
            debugLog("Rejecting non-loopback client: wireless mode not active")
            conn.cancel()
            return
        }
        debugLog("Client connected via LAN — running auth handshake")
        runAuthHandshake(connection: conn, expectedToken: expected)
    }

    private func beginExistingProtocol(on conn: NWConnection) {
        startReceivingInput(on: conn)

        // Give new clients a short chance to opt in before the first frame.
        // Legacy clients send no capability message, so we continue shortly
        // after this window with the old frame type.
        networkQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            self.finishProtocolStartup(on: conn)
        }
    }

    private func finishProtocolStartup(on conn: NWConnection) {
        guard connection === conn, !isStopped, !connectionReady else { return }

        let codec: StreamCodec = clientIsAvcOnly ? .h264 : .hevc
        if clientIsAvcOnly {
            // Safe to send: this client opted in via type 9. Must precede the
            // display config so the client knows the codec before it sizes
            // and configures its decoder.
            let msg = Data([WireMessage.codecSelected, codec.wireId])
            conn.send(content: msg, completion: .contentProcessed { _ in })
            debugLog("Sent codecSelected: H.264")
        }
        // Synchronous, before sendDisplaySize(): the handler switches the
        // encoder AND updates displayWidth/Height (clamped for H.264) so the
        // display config below carries decoder-safe dimensions.
        onCodecNegotiated?(codec)

        // Type 16 (only to clients that sent a valid type 15) precedes the
        // display config so the client tags its decoder before sizing it.
        sendState.withLockUnchecked { $0.streamFormatAllowed = true }
        sendStreamFormatIfNeeded()

        debugLog("Client connected - sending display config first")
        sendDisplaySize()
        sendState.withLockUnchecked { $0.ready = true }
        debugLog("Connection ready for frames (metadata=\(clientSupportsFrameMetadata ? "on" : "off"), codec=\(codec), capabilities=\(clientCapabilities != nil ? "yes" : "no"))")
        onClientConnected?()
    }

    private func runAuthHandshake(connection conn: NWConnection, expectedToken: Data) {
        // Read fixed prefix [magic 4][token 32][name_len 1] = 37 bytes.
        conn.receive(minimumIncompleteLength: HandshakeCodec.fixedPrefixLen,
                     maximumLength: HandshakeCodec.fixedPrefixLen) { [weak self] prefixData, _, _, error in
            guard let self = self else { return }
            if let error = error {
                debugLog("Auth read error: \(error)")
                conn.cancel()
                return
            }
            guard let prefix = prefixData, prefix.count == HandshakeCodec.fixedPrefixLen else {
                self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                return
            }
            let prefixBytes = Array(prefix)
            if Array(prefixBytes[0..<4]) == HandshakeCodec.pairingRequestMagic {
                self.runPairingExchange(connection: conn, prefix: prefix)
                return
            }
            guard Array(prefixBytes[0..<4]) == HandshakeCodec.requestMagic else {
                self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                return
            }
            self.receiveNameSuffix(on: conn, prefix: prefix, onInvalid: {
                self.sendAuthResponse(conn, status: .invalidName, thenClose: true)
            }) { full in
                do {
                    let parsed = try HandshakeCodec.parseRequest(full)
                    if WirelessAuth.validate(parsed.token, expected: expectedToken) {
                        debugLog("Wireless auth OK — device: \(parsed.deviceName)")
                        self.sendAuthResponse(conn, status: .ok, thenClose: false)
                        self.onWirelessClientPaired?(parsed.deviceName)
                        self.beginExistingProtocol(on: conn)
                    } else {
                        debugLog("Wireless auth rejected: token mismatch")
                        self.sendAuthResponse(conn, status: .invalidToken, thenClose: true)
                    }
                } catch HandshakeError.invalidMagic {
                    self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                } catch HandshakeError.invalidName {
                    self.sendAuthResponse(conn, status: .invalidName, thenClose: true)
                } catch {
                    self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                }
            }
        }
    }

    /// Reads the variable `[name N]` tail shared by SSWA and SSPC requests and
    /// hands back the full request bytes. `onInvalid` fires for a bad name
    /// length or a short read; read errors cancel the connection.
    private func receiveNameSuffix(
        on conn: NWConnection,
        prefix: Data,
        onInvalid: @escaping () -> Void,
        completion: @escaping (Data) -> Void
    ) {
        let nameLen = Int(Array(prefix)[36])
        guard (1...64).contains(nameLen) else {
            onInvalid()
            return
        }
        conn.receive(minimumIncompleteLength: nameLen, maximumLength: nameLen) { nameData, _, _, error in
            if let error = error {
                debugLog("Handshake name read error: \(error)")
                conn.cancel()
                return
            }
            guard let nameData = nameData, nameData.count == nameLen else {
                onInvalid()
                return
            }
            completion(prefix + nameData)
        }
    }

    /// Handles a pre-auth "SSPC" code-pairing request (issue #35). On a valid
    /// one-time code, answers with the real 32-byte token + Mac name and closes;
    /// the client then reconnects through the normal SSWA handshake.
    private func runPairingExchange(connection conn: NWConnection, prefix: Data) {
        receiveNameSuffix(on: conn, prefix: prefix, onInvalid: { [weak self] in
            self?.sendPairingResponse(conn, status: .invalidCode)
        }) { [weak self] full in
            guard let self = self else { return }
            do {
                let parsed = try HandshakeCodec.parsePairingRequest(full)
                switch self.consumePairingCode(candidate: parsed.code) {
                case .issued(let token):
                    debugLog("Pairing code accepted — issuing token to \(parsed.deviceName)")
                    self.sendPairingResponse(conn, status: .ok, token: token)
                    self.onPairingSuccess?(parsed.deviceName)
                case .rejected:
                    debugLog("Pairing code rejected")
                    self.sendPairingResponse(conn, status: .invalidCode)
                case .exhausted:
                    debugLog("Pairing code rejected — attempt budget exhausted, invalidating code")
                    self.sendPairingResponse(conn, status: .invalidCode)
                    self.onPairingCodeExhausted?()
                }
            } catch {
                // Malformed requests carry no code guess, so they don't touch
                // the attempt budget.
                debugLog("Malformed pairing request: \(error)")
                self.sendPairingResponse(conn, status: .invalidCode)
            }
        }
    }

    private enum PairingOutcome {
        case issued(Data)
        case rejected
        case exhausted
    }

    /// Single critical section for validate-and-consume: a correct guess nils
    /// the code before the token leaves the lock, and the attempt counter is
    /// bumped under the same lock — so neither double redemption nor
    /// budget-overrun is possible however requests are pipelined.
    private func consumePairingCode(candidate: String) -> PairingOutcome {
        pairingStateLock.withLock { state in
            guard let expected = state.code,
                  let token = self.expectedAuthToken,
                  PairingCode.validate(candidate, expected: expected) else {
                guard state.code != nil else { return .rejected }
                state.failedAttempts += 1
                if state.failedAttempts >= Self.maxPairingAttempts {
                    state.code = nil
                    state.failedAttempts = 0
                    return .exhausted
                }
                return .rejected
            }
            state.code = nil
            state.failedAttempts = 0
            return .issued(token)
        }
    }

    private func sendPairingResponse(_ conn: NWConnection, status: PairingStatus, token: Data? = nil) {
        let bytes = HandshakeCodec.encodePairingResponse(status: status, token: token, macName: pairingMacName)
        conn.send(content: bytes, completion: .contentProcessed { _ in
            // Pairing connections never stream: close after the reply either
            // way. On success the client reconnects with the issued token.
            conn.cancel()
        })
    }

    private func sendAuthResponse(_ conn: NWConnection, status: HandshakeStatus, thenClose: Bool) {
        let bytes = HandshakeCodec.encodeResponse(status: status)
        conn.send(content: bytes, completion: .contentProcessed { _ in
            if thenClose {
                debugLog("Auth rejected (\(status)), closing connection")
                conn.cancel()
            }
        })
    }

    /// The logical desktop the user picked. Purely informational: the client
    /// must size its decoder from displayConfig, never from this.
    func setDesktopSize(width: Int, height: Int) {
        desktopWidth = width
        desktopHeight = height
    }

    func setDisplaySize(width: Int, height: Int, rotation: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        displayWidth = width
        displayHeight = height
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    func updateDisplayTransform(rotation: Int, flipHorizontal: Bool, flipVertical: Bool) {
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        sendDisplaySize()
    }

    func sendDisplaySize() {
        guard let connection = connection else { return }

        let transform = rotation + (flipHorizontal ? 1000 : 0) + (flipVertical ? 2000 : 0)
        var data = Data()
        data.append(WireMessage.displayConfig)
        data.append(contentsOf: withUnsafeBytes(of: Int32(displayWidth).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(displayHeight).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(transform).bigEndian) { Data($0) })

        connection.send(content: data, completion: .contentProcessed { _ in })
        debugLog("Sent display config: \(displayWidth)x\(displayHeight) @ \(rotation)°, h=\(flipHorizontal), v=\(flipVertical)")
        sendDesktopGeometry()
    }

    /// Follows every display config so the two can never disagree on screen.
    private func sendDesktopGeometry() {
        guard clientSupportsDesktopGeometry, let connection = connection else { return }
        guard desktopWidth > 0, desktopHeight > 0 else { return }

        var data = Data()
        data.append(WireMessage.desktopGeometry)
        data.append(contentsOf: withUnsafeBytes(of: Int32(desktopWidth).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(desktopHeight).bigEndian) { Data($0) })
        connection.send(content: data, completion: .contentProcessed { _ in })
        debugLog("Sent desktop geometry: \(desktopWidth)x\(desktopHeight)")
    }

    /// Records the stream's colour format, frame rate and whether the host
    /// display matches the client panel (type-16 flags bit1: the client then
    /// owns orientation). Sends type 16 right away when it changed and the
    /// client is eligible (sent a valid type 15, startup reached); otherwise
    /// `finishProtocolStartup` sends it before the display config. Callable
    /// from any thread; call it before `sendDisplaySize()` when both change.
    func setStreamFormat(_ format: StreamColorFormat, fps: Int, matchesPanel: Bool) {
        let message = StreamWire.encodeStreamFormat(format, fps: fps, matchesPanel: matchesPanel)
        sendState.withLockUnchecked { $0.streamFormatMessage = message }
        sendStreamFormatIfNeeded()
    }

    /// Marks a stream discontinuity (encoder rebuilt, display re-moded): frames
    /// are dropped until the next keyframe, so the client never decodes
    /// P-frames against the previous segment's references. Call before the
    /// first frame of the new segment.
    func beginNewStreamSegment() {
        sendState.withLockUnchecked { $0.waitingForSyncFrame = true }
        debugLog("New stream segment — holding frames until the next keyframe")
    }

    /// Sends the latest type-16 message if this connection may receive it and
    /// has not received exactly these bytes yet.
    private func sendStreamFormatIfNeeded() {
        let pending = sendState.withLockUnchecked { state -> (NWConnection, Data)? in
            guard let conn = state.connection,
                  state.capabilities != nil,
                  state.streamFormatAllowed,
                  let message = state.streamFormatMessage,
                  message != state.sentStreamFormat else { return nil }
            state.sentStreamFormat = message
            return (conn, message)
        }
        guard case let (conn, message)? = pending else { return }
        conn.send(content: message, completion: .contentProcessed { _ in })
        debugLog("Sent stream format: \(Array(message.dropFirst()))")
    }

    private func startReceivingInput(on conn: NWConnection) {
        guard !isReceiving else {
            debugLog("Already receiving input")
            return
        }
        isReceiving = true
        debugLog("Starting input receive loop... (touch=\(touchEnabled ? "on" : "off"))")
        receiveInput(on: conn)
    }

    /// Completions run on `networkQueue` (the connection's queue) and re-arm
    /// the next receive directly: no extra queue hop per message, and no stack
    /// growth since each completion is a fresh callback.
    private func receiveInput(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, isComplete, error in
            // A replaced connection's late completions must not touch the
            // new connection's input buffer.
            guard let self = self, self.isReceiving, !self.isStopped, self.connection === conn else { return }

            if error != nil || isComplete {
                self.isReceiving = false
                self.inputBuffer.removeAll(keepingCapacity: true)
                conn.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                self.inputBuffer.append(data)
                self.processInputBuffer(connection: conn)
            }

            self.receiveInput(on: conn)
        }
    }

    private func processInputBuffer(connection: NWConnection) {
        while let msgType = inputBuffer.first {
            switch msgType {
            case WireMessage.touchEvent:
                // Touch event: 1 type + 1 pointerCount + N*(4x+4y) + 4 action.
                // 1 finger: 14 bytes, 2 fingers: 22 bytes.
                guard inputBuffer.count >= 2 else { return }

                let pointerCount = Int(inputByte(at: 1))
                guard pointerCount == 1 || pointerCount == 2 else {
                    debugLog("Invalid touch pointer count: \(pointerCount)")
                    consumeInputBytes(1)
                    continue
                }

                let expectedSize = 2 + pointerCount * 8 + 4
                guard inputBuffer.count >= expectedSize else { return }

                // Drop early if host has touch disabled. Parsed straight out of
                // inputBuffer, then exactly this touch frame is consumed so
                // coalesced ping/keyframe messages survive.
                if touchEnabled {
                    handleTouchMessage(pointerCount: pointerCount)
                }
                consumeInputBytes(expectedSize)

            case WireMessage.ping:
                // Ping from client: echo back as pong (type=5) with client's timestamp.
                guard inputBuffer.count >= 9 else { return }

                let clientTimestamp = Data(inputBuffer.dropFirst().prefix(8))
                consumeInputBytes(9)

                var pong = Data(capacity: 9)
                pong.append(WireMessage.pong) // Type: Pong
                pong.append(clientTimestamp)
                connection.send(content: pong, completion: .contentProcessed { _ in })

            case WireMessage.keyframeRequest:
                // Keyframe request from Android decoder. The client sends a
                // two-byte message: type + flags.
                guard inputBuffer.count >= 2 else { return }

                let flags = inputByte(at: 1)
                consumeInputBytes(2)
                onKeyframeRequested?((flags & 1) != 0)

            case WireMessage.clientSupportsFrameMetadata:
                // One-byte opt-in from newer clients. Keeping this payload-free
                // lets older hosts safely ignore it without misaligning input.
                consumeInputBytes(1)
                if !clientSupportsFrameMetadata {
                    sendState.withLockUnchecked { $0.frameMetadata = true }
                    debugLog("Client supports video frame metadata")
                }
                finishProtocolStartup(on: connection)

            case WireMessage.clientAvcOnly:
                // Payload-free opt-in (same convention as type 8): the client
                // has no HEVC decoder, stream H.264 instead. Clients send this
                // BEFORE type 8, so it lands before finishProtocolStartup runs.
                consumeInputBytes(1)
                if !clientIsAvcOnly {
                    clientIsAvcOnly = true
                    debugLog("Client is AVC-only — will negotiate H.264")
                }

            case WireMessage.clientDecoderLimits:
                // Type + 4 payload bytes: [w-hi][w-lo][h-hi][h-lo], 7 data
                // bits each with the high bit always set (old hosts skip the
                // payload harmlessly). Sent BEFORE type 8, like type 9.
                guard inputBuffer.count >= 5 else { return }

                let payload = (1...4).map { inputByte(at: $0) }
                consumeInputBytes(5)
                guard payload.allSatisfy({ $0 & 0x80 != 0 }) else {
                    debugLog("Malformed decoder-limits payload — ignoring")
                    continue
                }
                let w = (Int(payload[0] & 0x7F) << 7) | Int(payload[1] & 0x7F)
                let h = (Int(payload[2] & 0x7F) << 7) | Int(payload[3] & 0x7F)
                // Anything below QVGA-ish is a nonsense report — ignore it.
                if w >= 256 && h >= 256 {
                    clientDecodeLimits = (w, h)
                    debugLog("Client decoder limit: \(w)x\(h)")
                    // Arrived after the 100 ms legacy grace already finished
                    // startup (slow link, slow device): re-negotiate now so the
                    // limit still takes effect instead of waiting for the next
                    // restart. The handler re-sends the display config itself
                    // when the encode size changes.
                    if connectionReady {
                        debugLog("Decoder limit arrived late — re-negotiating")
                        let before = (displayWidth, displayHeight)
                        onCodecNegotiated?(clientIsAvcOnly ? .h264 : .hevc)
                        if (displayWidth, displayHeight) != before {
                            sendDisplaySize()
                        }
                    }
                }

            case WireMessage.clientDecoderLimitTable:
                // Type + 12 payload bytes: one (w, h) pair per
                // CodecLimits.tableFps entry, in order, each in the type-11
                // encoding. Sent BEFORE type 8, like type 11.
                let payloadCount = 4 * CodecLimits.tableFps.count
                guard inputBuffer.count >= 1 + payloadCount else { return }

                let payload = (1...payloadCount).map { inputByte(at: $0) }
                consumeInputBytes(1 + payloadCount)
                guard payload.allSatisfy({ $0 & 0x80 != 0 }) else {
                    debugLog("Malformed decoder-limit-table payload — ignoring")
                    continue
                }
                var table: [Int: (width: Int, height: Int)] = [:]
                for (i, fps) in CodecLimits.tableFps.enumerated() {
                    let w = (Int(payload[4 * i] & 0x7F) << 7) | Int(payload[4 * i + 1] & 0x7F)
                    let h = (Int(payload[4 * i + 2] & 0x7F) << 7) | Int(payload[4 * i + 3] & 0x7F)
                    // Anything below QVGA-ish is a nonsense report — drop the whole table.
                    guard w >= 256, h >= 256 else {
                        table.removeAll()
                        break
                    }
                    table[fps] = (w, h)
                }
                guard !table.isEmpty else {
                    debugLog("Decoder limit table has a nonsense entry — ignoring")
                    continue
                }
                clientDecodeLimitTable = table
                let desc = CodecLimits.tableFps.compactMap { fps in table[fps].map { "\(fps)fps=\($0.width)x\($0.height)" } }
                debugLog("Client decoder limit table: \(desc.joined(separator: ", "))")
                if connectionReady {
                    // Same late-arrival handling as type 11.
                    debugLog("Decoder limit table arrived late — re-negotiating")
                    let before = (displayWidth, displayHeight)
                    onCodecNegotiated?(clientIsAvcOnly ? .h264 : .hevc)
                    if (displayWidth, displayHeight) != before {
                        sendDisplaySize()
                    }
                }

            case WireMessage.clientSupportsDesktopGeometry:
                // Payload-free opt-in (same convention as types 8 and 9), sent
                // BEFORE type 8 so it lands before finishProtocolStartup runs.
                consumeInputBytes(1)
                if !clientSupportsDesktopGeometry {
                    clientSupportsDesktopGeometry = true
                    debugLog("Client reads displayConfig as the encoded size")
                    // Late opt-in (after startup): the display config already
                    // went out without geometry, so send it on its own.
                    if connectionReady { sendDesktopGeometry() }
                }

            case WireMessage.clientCapabilities:
                // Type + 12 payload bytes, every byte high-bit set (old hosts
                // skip them byte by byte). Sent BEFORE type 8 at connect, and
                // again whenever the client's presentation geometry or
                // capabilities change (rotation, fold switch, cutout mode).
                let payloadCount = StreamWire.clientCapabilitiesPayloadSize
                guard inputBuffer.count >= 1 + payloadCount else { return }

                let payload = (1...payloadCount).map { inputByte(at: $0) }
                consumeInputBytes(1 + payloadCount)
                guard let capabilities = StreamWire.parseClientCapabilities(payload) else {
                    debugLog("Malformed client-capabilities payload — ignoring")
                    continue
                }
                handleClientCapabilities(capabilities)

            case WireMessage.clockSyncRequest:
                // Type + client t0 (Int64 BE). Answered inline on this queue so
                // t1→t2 spans only this parse. Clients send it only after type
                // 16; earlier requests are consumed and ignored.
                let messageSize = 1 + StreamWire.clockSyncRequestPayloadSize
                guard inputBuffer.count >= messageSize else { return }

                let t1 = DispatchTime.now().uptimeNanoseconds
                let t0 = inputBuffer.withUnsafeBytes {
                    UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt64.self))
                }
                consumeInputBytes(messageSize)
                replyToClockSync(t0: t0, t1: t1, on: connection)

            default:
                debugLog("Unknown client input type: \(msgType)")
                consumeInputBytes(1)
            }
        }
    }

    /// Stores a changed type-15 advert. Before startup it only feeds the
    /// negotiation; after startup it is reported via `onClientCapabilities`.
    private func handleClientCapabilities(_ capabilities: ClientCapabilities) {
        let (changed, ready) = sendState.withLockUnchecked { state -> (Bool, Bool) in
            let changed = state.capabilities != capabilities
            state.capabilities = capabilities
            return (changed, state.ready)
        }
        guard changed else { return }
        debugLog("Client capabilities: \(capabilities.presentationWidth)x\(capabilities.presentationHeight) @ \(capabilities.peakRefreshHz) Hz, main10=\(capabilities.decodesHevcMain10), hdr10=\(capabilities.displayHDR10), panel=\(capabilities.panelKind)")
        // A first advert that lands after startup makes the client eligible
        // for type 16 now.
        sendStreamFormatIfNeeded()
        if ready {
            onClientCapabilities?(capabilities)
        }
    }

    /// Type 18, only once this connection has received type 16.
    private func replyToClockSync(t0: UInt64, t1: UInt64, on conn: NWConnection) {
        guard sendState.withLockUnchecked({ $0.sentStreamFormat != nil }) else { return }
        let response = StreamWire.encodeClockSyncResponse(t0: t0, t1: t1, t2: DispatchTime.now().uptimeNanoseconds)
        conn.send(content: response, completion: .contentProcessed { _ in })
    }

    /// Reads the touch message at the front of `inputBuffer` in place:
    /// `[2][count][x1 y1 (x2 y2) Float32 LE][action Int32 LE]`.
    private func handleTouchMessage(pointerCount: Int) {
        let x1 = inputFloat(at: 2)
        let y1 = inputFloat(at: 6)

        var x2: Float = 0
        var y2: Float = 0
        if pointerCount >= 2 {
            x2 = inputFloat(at: 10)
            y2 = inputFloat(at: 14)
        }

        let actionOffset = 2 + pointerCount * 8
        let action = inputBuffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: actionOffset, as: Int32.self) }

        DispatchQueue.main.async {
            self.onTouchEvent?(x1, y1, Int(action), pointerCount, x2, y2)
        }
    }

    /// Native-endian (little-endian on every Mac) Float32 from `inputBuffer`.
    private func inputFloat(at offset: Int) -> Float {
        inputBuffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
    }

    private func inputByte(at offset: Int) -> UInt8 {
        inputBuffer[inputBuffer.index(inputBuffer.startIndex, offsetBy: offset)]
    }

    private func consumeInputBytes(_ count: Int) {
        let endIndex = inputBuffer.index(inputBuffer.startIndex, offsetBy: count)
        inputBuffer.removeSubrange(inputBuffer.startIndex..<endIndex)
    }

    private struct FrameAdmission {
        let connection: NWConnection
        let generation: UInt64
        let legacy: Bool
        let wireBytes: Int
        let isFirstKeyframe: Bool
    }

    private struct StatsReport {
        let fps: Double
        let mbps: Double
        let avgFrameAgeMs: Double?
        let droppedFrames: UInt64
    }

    /// Sends one encoded frame. Called on the encoder's output thread: the
    /// header goes into the frame's reserved prefix in place and the packet is
    /// handed straight to the socket — no queue hop, no copy. Every frame is
    /// sent; flow control is the caller's job via `isBackpressured`.
    func sendFrame(_ frame: EncodedFrame) {
        let payloadSize = frame.packet.count - frame.headerReserve
        // payloadSize > 0 also keeps the packet larger than Data's inline
        // representation (≤ 14 bytes), so its bytes live in a heap buffer.
        guard frame.headerReserve == Self.frameHeaderReserve, payloadSize > 0 else {
            debugLog("Dropping frame without a \(Self.frameHeaderReserve)-byte header reserve (reserve \(frame.headerReserve), \(frame.packet.count) bytes)")
            return
        }

        let admission = sendState.withLockUnchecked { state -> FrameAdmission? in
            guard let conn = state.connection, state.ready else { return nil }
            // A fresh client (or a new stream segment) must start on a
            // keyframe — P-frames before it would feed garbage to the decoder.
            var isFirstKeyframe = false
            if state.waitingForSyncFrame {
                guard frame.isKeyframe else {
                    state.stats.droppedFrames += 1
                    return nil
                }
                state.waitingForSyncFrame = false
                isFirstKeyframe = true
            }
            let legacy = !state.frameMetadata
            let headerSize = legacy ? StreamWire.legacyFrameHeaderSize : StreamWire.frameHeaderSize
            let wireBytes = headerSize + payloadSize
            state.inFlightFrames += 1
            state.inFlightBytes += wireBytes
            return FrameAdmission(connection: conn, generation: state.generation, legacy: legacy,
                                  wireBytes: wireBytes, isFirstKeyframe: isFirstKeyframe)
        }
        guard let admission else { return }
        if admission.isFirstKeyframe {
            debugLog("First keyframe of the stream segment sent")
        }

        // The packet's storage is shared with the caller's `frame`, so a
        // mutating write would copy the whole access unit (copy-on-write).
        // The reserved prefix belongs to the sender (see EncodedFrame), so the
        // header is written into the existing buffer instead.
        let offset = frame.packet.withUnsafeBytes { raw in
            StreamWire.writeFrameHeader(to: UnsafeMutableRawBufferPointer(mutating: raw), payloadSize: payloadSize,
                                        isKeyframe: frame.isKeyframe, captureNanos: frame.captureNanos,
                                        legacy: admission.legacy)
        }
        // Legacy (type 0) starts 9 bytes in: exactly the old `[0][size][AU]` bytes.
        let content = frame.packet.dropFirst(offset)
        let generation = admission.generation
        let wireBytes = admission.wireBytes
        admission.connection.send(content: content, completion: .contentProcessed { [weak self] error in
            self?.frameSendCompleted(generation: generation, wireBytes: wireBytes, failed: error != nil)
        })

        let now = DispatchTime.now().uptimeNanoseconds
        let frameAgeNs = now > frame.captureNanos ? now - frame.captureNanos : 0
        recordSentFrame(payloadBytes: payloadSize, frameAgeNs: frameAgeNs, now: now)
    }

    /// Balances `sendFrame`'s in-flight accounting, on success and on error.
    private func frameSendCompleted(generation: UInt64, wireBytes: Int, failed: Bool) {
        sendState.withLockUnchecked { state in
            // Counters were reset when the connection was replaced or stopped.
            guard state.generation == generation else { return }
            state.inFlightFrames = max(state.inFlightFrames - 1, 0)
            state.inFlightBytes = max(state.inFlightBytes - wireBytes, 0)
            if failed {
                state.stats.droppedFrames += 1
            }
        }
    }

    /// One-second fps/Mbps windows for `onStats`, plus the capture→send age
    /// profile (frame age = send instant − capture instant).
    private func recordSentFrame(payloadBytes: Int, frameAgeNs: UInt64, now: UInt64) {
        let report = sendState.withLockUnchecked { state -> StatsReport? in
            state.stats.bytesSent += UInt64(payloadBytes)
            state.stats.frameCount += 1
            if frameAgeNs > 0 {
                state.stats.totalFrameAgeNs += frameAgeNs
                state.stats.profiledFrameCount += 1
            }

            let windowStart = state.stats.windowStartNs
            let elapsedNs = now > windowStart ? now - windowStart : 0
            guard elapsedNs >= 1_000_000_000 else { return nil }

            let elapsed = Double(elapsedNs) / 1_000_000_000
            let stats = state.stats
            let avgAgeMs = stats.profiledFrameCount > 0
                ? Double(stats.totalFrameAgeNs) / Double(stats.profiledFrameCount) / 1_000_000.0
                : nil
            state.stats = SendStats(windowStartNs: now)
            return StatsReport(fps: Double(stats.frameCount) / elapsed,
                               mbps: Double(stats.bytesSent * 8) / elapsed / 1_000_000,
                               avgFrameAgeMs: avgAgeMs,
                               droppedFrames: stats.droppedFrames)
        }
        guard let report else { return }

        onStats?(report.fps, report.mbps)
        // Log pipeline latency profile
        if let avgAgeMs = report.avgFrameAgeMs {
            debugLog("Pipeline: \(String(format: "%.1f", report.fps))fps, \(String(format: "%.1f", report.mbps))Mbps, avg capture→send age: \(String(format: "%.1f", avgAgeMs))ms, dropped: \(report.droppedFrames)")
        }
    }

    func stop() {
        isStopped = true
        isReceiving = false

        // After this no frame is admitted; late send completions are ignored.
        let conn = sendState.withLockUnchecked { state -> NWConnection? in
            let conn = state.connection
            state.connection = nil
            state.ready = false
            state.generation &+= 1
            state.inFlightFrames = 0
            state.inFlightBytes = 0
            return conn
        }
        conn?.cancel()
        listener?.cancel()
        listener = nil
    }
}

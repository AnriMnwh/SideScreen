package com.sidescreen.app

import android.content.Context
import android.media.MediaFormat
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Process
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.io.IOException
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class StreamClient(
    private val host: String,
    private val port: Int,
    private val context: Context,
) {
    private var socket: Socket? = null
    private var inputStream: DataInputStream? = null
    private var outputStream: java.io.DataOutputStream? = null

    @Volatile private var isConnected = false

    /**
     * Frame buffer, valid byte count (the pooled buffer may be larger), receive `System.nanoTime()`,
     * whether the frame can restart decoding, and the host capture instant in the host clock
     * (map it with [clockSync]); 0 when the host never sent a type 16, so its timestamps are not
     * capture instants.
     */
    var onFrameReceived: ((ByteArray, Int, Long, Boolean, Long) -> Unit)? = null
    var onConnectionStatus: ((Boolean) -> Unit)? = null
    var onDisplaySize: ((Int, Int, Int, Boolean, Boolean) -> Unit)? = null

    /** Logical desktop size behind the stream. Display only; never size the decoder from it. */
    var onDesktopSize: ((Int, Int) -> Unit)? = null
    var onStats: ((Double, Double) -> Unit)? = null

    /** Invoked when the server confirms the stream codec (true = HEVC). */
    var onCodecSelected: ((Boolean) -> Unit)? = null

    /** Stream codec for sync-frame parsing. HEVC unless the server says otherwise. */
    @Volatile var streamCodecIsHevc = true
        private set

    /** True once a MESSAGE_CODEC_SELECTED arrived — distinguishes new Macs from old. */
    @Volatile var codecNegotiated = false
        private set

    /** Latest type 16, null until a host that supports it sends one. */
    @Volatile var streamFormat: StreamFormat? = null
        private set

    /** Fired on the receive thread for every valid type 16. */
    var onStreamFormat: ((StreamFormat) -> Unit)? = null

    /** Host↔client clock estimate fed by the type-17/18 exchange. */
    val clockSync = ClockSyncEstimator()

    /** (offsetNs, minRttNs) after every type-18 sample, on the receive thread. */
    var onClockSync: ((Long, Long) -> Unit)? = null

    /**
     * Queried at connect (and once more right after) for the type-15 advertisement. Null provider
     * or null result: no type 15 at connect, and the host stays on SDR / its own display size.
     */
    var capabilitiesProvider: (() -> ClientCapabilities?)? = null

    private val capabilitiesLock = Any()
    private var lastAdvertisedCapabilities: ClientCapabilities? = null

    @Volatile private var clockSyncJob: Job? = null

    // Receive-thread only.
    private val streamFormatPayload = ByteArray(StreamFormat.WIRE_SIZE)
    private val clockSyncPayload = ByteArray(ClockSyncWire.RESPONSE_SIZE)
    private var clockSyncLogged = false

    private var bytesReceived = 0L
    private var framesReceived = 0L
    private var diagFrameCount = 0L
    private var lastStatsTime = System.currentTimeMillis()
    private val keyframeRequestLock = Any()
    private var lastKeyframeRequestNs = 0L

    // Buffer pooling to reduce GC pressure from per-frame allocations
    // At 60fps with ~100KB frames, this prevents ~6MB/s of allocations
    private val bufferPool = ArrayDeque<ByteArray>(8)
    private val poolLock = Any()

    /**
     * Acquire a buffer from pool or allocate new one if needed
     * @param minSize Minimum size required for the buffer
     */
    private fun acquireBuffer(minSize: Int): ByteArray {
        synchronized(poolLock) {
            val iterator = bufferPool.iterator()
            while (iterator.hasNext()) {
                val buffer = iterator.next()
                if (buffer.size >= minSize) {
                    iterator.remove()
                    return buffer
                }
            }
        }
        // No suitable buffer found, allocate new one
        return ByteArray(maxOf(minSize, 64 * 1024))
    }

    /**
     * Release a buffer back to the pool for reuse
     * Called after decode completes via onFrameDecoded callback
     */
    fun releaseBuffer(buffer: ByteArray) {
        synchronized(poolLock) {
            // Keep pool size limited to prevent memory bloat
            if (bufferPool.size < 8) {
                bufferPool.addLast(buffer)
            } else {
                val minIdx = bufferPool.indices.minByOrNull { bufferPool[it].size } ?: return
                if (buffer.size > bufferPool[minIdx].size) {
                    bufferPool.removeAt(minIdx)
                    bufferPool.addLast(buffer)
                }
            }
        }
    }

    // High-priority thread for touch events to minimize latency
    // Use THREAD_PRIORITY_DISPLAY instead of URGENT_DISPLAY to avoid starving system processes
    private val touchExecutor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(
                {
                    // Use DISPLAY priority (less aggressive than URGENT_DISPLAY).
                    // ThreadFactory runs on the caller thread, so set Linux priority
                    // from inside the worker thread before processing touch writes.
                    try {
                        Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY)
                    } catch (_: Exception) {
                    }
                    runnable.run()
                },
                "TouchThread",
            ).apply {
                priority = Thread.MAX_PRIORITY
            }
        }
    private val touchDispatcher = touchExecutor.asCoroutineDispatcher()
    private val touchScope = CoroutineScope(touchDispatcher)

    suspend fun connect() =
        withContext(Dispatchers.IO) {
            try {
                socket =
                    Socket(host, port).apply {
                        tcpNoDelay = true
                    }
                inputStream = DataInputStream(java.io.BufferedInputStream(socket?.getInputStream(), INPUT_BUFFER_SIZE))
                outputStream = java.io.DataOutputStream(socket?.getOutputStream())
                streamCodecIsHevc = true
                codecNegotiated = false
                prepareAdvertisements()
                advertiseAvcOnlyIfNeeded() // MUST precede type 8: type 8 can trigger the server's early protocol finish
                advertiseDecoderLimits() // Also before type 8, for the same reason
                advertiseCapabilitiesAtConnect() // After 14, before 8: the host negotiates format from it
                advertiseDesktopGeometrySupport() // Likewise
                advertiseFrameMetadataSupport()
                isConnected = true
                synchronized(keyframeRequestLock) {
                    lastKeyframeRequestNs = 0L
                }
                readvertiseCapabilitiesIfChanged()

                diagLog("Connected to $host:$port")
                onConnectionStatus?.invoke(true)

                receiveData()
            } catch (e: Exception) {
                Log.e(TAG, "❌ Connection error", e)
                onConnectionStatus?.invoke(false)
                cleanup()
            }
        }

    sealed class WirelessConnectError(msg: String) : Exception(msg) {
        object NetworkUnreachable : WirelessConnectError("Mac unreachable — check both on same WiFi")

        object TokenRejected : WirelessConnectError("Token rejected — re-pair required")

        object ProtocolError : WirelessConnectError("Connection error, please rescan QR")
    }

    /**
     * Code-pairing failures (issue #35). Kept OUT of [WirelessConnectError] on
     * purpose: these can only be thrown by [pairWithCode] and are handled in
     * the pairing dialog, so putting them in the shared sealed class would just
     * grow dead branches in every exhaustive `when` over connect errors.
     */
    sealed class PairingError(msg: String) : Exception(msg) {
        /** The Mac rejected the typed one-time code. */
        object CodeRejected : PairingError("Pairing code not accepted")

        /** The Mac runs a version that predates code pairing. */
        object HostTooOld : PairingError("Update Side Screen on the Mac to use code pairing")
    }

    data class PairingSuccess(val token: ByteArray, val macName: String)

    /**
     * Opens a TCP socket to host:port, bound to the active WiFi network. On some
     * Android setups (especially LG/Android 12), an app's default outbound socket
     * may take a route that silently drops LAN traffic; binding to the WIFI
     * Network explicitly avoids that.
     */
    private fun openWirelessSocket(): Socket {
        try {
            val sock = Socket()
            sock.tcpNoDelay = true
            val cm = context.getSystemService(ConnectivityManager::class.java)
            val wifiNetwork =
                cm.allNetworks.firstOrNull { net ->
                    val caps = cm.getNetworkCapabilities(net)
                    caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                }
            if (wifiNetwork != null) {
                Log.i(TAG, "openWirelessSocket: binding socket to WiFi network $wifiNetwork")
                wifiNetwork.bindSocket(sock)
            } else {
                Log.w(TAG, "openWirelessSocket: no WiFi network found, using default routing")
            }
            sock.connect(java.net.InetSocketAddress(host, port), 5000)
            return sock
        } catch (e: java.net.SocketTimeoutException) {
            Log.e(TAG, "openWirelessSocket: TCP connect timeout to $host:$port (5s)")
            throw WirelessConnectError.NetworkUnreachable
        } catch (e: IOException) {
            Log.e(TAG, "openWirelessSocket: TCP connect failed to $host:$port: ${e.javaClass.simpleName}: ${e.message}")
            throw WirelessConnectError.NetworkUnreachable
        }
    }

    private fun readFully(
        s: Socket,
        buf: ByteArray,
    ): Boolean {
        var read = 0
        try {
            while (read < buf.size) {
                val r = s.getInputStream().read(buf, read, buf.size - read)
                if (r <= 0) break
                read += r
            }
        } catch (e: IOException) {
            return false
        }
        return read == buf.size
    }

    /**
     * Code pairing (issue #35): send the typed one-time code, receive the real
     * 32-byte token + Mac name, then close. The caller stores the result and
     * reconnects through the normal [connectWireless] handshake.
     * Throws [WirelessConnectError] or [PairingError] on failure. `use {}`
     * guarantees the socket closes on every path, including coroutine
     * cancellation and unexpected exceptions.
     */
    suspend fun pairWithCode(
        code: String,
        deviceName: String,
    ): PairingSuccess =
        withContext(Dispatchers.IO) {
            Log.i(TAG, "pairWithCode: trying $host:$port (device=$deviceName)")
            openWirelessSocket().use { s ->
                // A silent listener (user typed the wrong port) must not hang
                // the dialog forever: bound every blocking read.
                s.soTimeout = PAIRING_READ_TIMEOUT_MS

                try {
                    s.getOutputStream().write(AuthHandshake.encodePairingRequest(code, deviceName))
                    s.getOutputStream().flush()
                } catch (e: IOException) {
                    throw WirelessConnectError.NetworkUnreachable
                }

                val header = ByteArray(5)
                if (!readFully(s, header)) {
                    throw WirelessConnectError.ProtocolError
                }
                val parsed =
                    AuthHandshake.parsePairingResponseHeader(header)
                        ?: throw WirelessConnectError.ProtocolError
                when (parsed) {
                    is AuthHandshake.PairingHeader.LegacyHost -> throw PairingError.HostTooOld
                    is AuthHandshake.PairingHeader.Pairing -> {
                        if (parsed.status != AuthHandshake.PairingStatus.OK) {
                            throw PairingError.CodeRejected
                        }
                    }
                }

                val token = ByteArray(32)
                val nameLenBuf = ByteArray(1)
                if (!readFully(s, token) || !readFully(s, nameLenBuf)) {
                    throw WirelessConnectError.ProtocolError
                }
                val nameLen = nameLenBuf[0].toInt() and 0xFF
                if (nameLen !in 1..64) {
                    throw WirelessConnectError.ProtocolError
                }
                val nameBuf = ByteArray(nameLen)
                if (!readFully(s, nameBuf)) {
                    throw WirelessConnectError.ProtocolError
                }
                val macName = String(nameBuf, Charsets.UTF_8)
                Log.i(TAG, "pairWithCode: token issued by $macName")
                PairingSuccess(token, macName)
            }
        }

    /**
     * Wireless connect: opens TCP, performs auth handshake, then resumes the existing receive loop on success.
     * Throws WirelessConnectError on any failure.
     */
    suspend fun connectWireless(
        token: ByteArray,
        deviceName: String,
    ) = withContext(Dispatchers.IO) {
        Log.i(TAG, "connectWireless: trying $host:$port (device=$deviceName, token bytes=${token.size})")

        val s = openWirelessSocket()
        Log.i(
            TAG,
            "connectWireless: TCP connected, sending handshake (${37 + deviceName.toByteArray().size} bytes)",
        )

        val request = AuthHandshake.encodeRequest(token, deviceName)
        try {
            s.getOutputStream().write(request)
            s.getOutputStream().flush()
        } catch (e: IOException) {
            try {
                s.close()
            } catch (_: IOException) {
            }
            throw WirelessConnectError.NetworkUnreachable
        }

        val responseBuf = ByteArray(5)
        var read = 0
        try {
            while (read < 5) {
                val r = s.getInputStream().read(responseBuf, read, 5 - read)
                if (r <= 0) break
                read += r
            }
        } catch (e: IOException) {
            try {
                s.close()
            } catch (_: IOException) {
            }
            throw WirelessConnectError.NetworkUnreachable
        }
        if (read != 5) {
            try {
                s.close()
            } catch (_: IOException) {
            }
            throw WirelessConnectError.ProtocolError
        }

        val status =
            AuthHandshake.parseResponse(responseBuf) ?: run {
                try {
                    s.close()
                } catch (_: IOException) {
                }
                throw WirelessConnectError.ProtocolError
            }
        Log.i(TAG, "connectWireless: handshake response status=$status")
        when (status) {
            AuthHandshake.ResponseStatus.OK -> {
                socket = s
                inputStream = DataInputStream(java.io.BufferedInputStream(s.getInputStream(), INPUT_BUFFER_SIZE))
                outputStream = java.io.DataOutputStream(s.getOutputStream())
                streamCodecIsHevc = true
                codecNegotiated = false
                prepareAdvertisements()
                advertiseAvcOnlyIfNeeded() // MUST precede type 8: type 8 can trigger the server's early protocol finish
                advertiseDecoderLimits() // Also before type 8, for the same reason
                advertiseCapabilitiesAtConnect() // After 14, before 8: the host negotiates format from it
                advertiseDesktopGeometrySupport() // Likewise
                advertiseFrameMetadataSupport()
                isConnected = true
                readvertiseCapabilitiesIfChanged()
                diagLog("Wireless connected to $host:$port")
                onConnectionStatus?.invoke(true)
                receiveData()
            }
            AuthHandshake.ResponseStatus.INVALID_TOKEN -> {
                try {
                    s.close()
                } catch (_: IOException) {
                }
                throw WirelessConnectError.TokenRejected
            }
            else -> {
                try {
                    s.close()
                } catch (_: IOException) {
                }
                throw WirelessConnectError.ProtocolError
            }
        }
    }

    private fun advertiseDesktopGeometrySupport() {
        outputStream?.let { out ->
            out.writeByte(MESSAGE_CLIENT_SUPPORTS_DESKTOP_GEOMETRY)
            out.flush()
            diagLog("Advertised desktop-geometry support")
        }
    }

    private fun advertiseFrameMetadataSupport() {
        outputStream?.let { out ->
            out.writeByte(MESSAGE_CLIENT_SUPPORTS_FRAME_METADATA)
            out.flush()
            diagLog("Advertised frame metadata support")
        }
    }

    /** Type 15 inside the connect sequence, before [isConnected] opens mid-session writes. */
    private fun advertiseCapabilitiesAtConnect() {
        val caps = capabilitiesProvider?.invoke() ?: return
        synchronized(capabilitiesLock) {
            outputStream?.let { writeCapabilities(it, caps) }
        }
    }

    /** Queries the provider once more after connecting, catching a change that landed mid-handshake. */
    private fun readvertiseCapabilitiesIfChanged() {
        capabilitiesProvider?.invoke()?.let { advertiseCapabilities(it) }
    }

    /**
     * Type 15 mid-session (rotation, fold switch, cutout mode change). Safe from any thread: the
     * write runs on the touch thread with every other client→host message, and an advert equal to
     * the last one sent is dropped. Ignored while disconnected; the connect sequence asks
     * [capabilitiesProvider] instead.
     */
    fun advertiseCapabilities(caps: ClientCapabilities) {
        if (!isConnected) return
        touchScope.launch {
            try {
                synchronized(capabilitiesLock) {
                    val out = outputStream
                    if (out != null && isConnected && caps != lastAdvertisedCapabilities) {
                        writeCapabilities(out, caps)
                    }
                }
            } catch (_: Exception) {
            }
        }
    }

    /** Caller holds [capabilitiesLock]. One write so the 13 bytes never interleave with others. */
    private fun writeCapabilities(
        out: java.io.DataOutputStream,
        caps: ClientCapabilities,
    ) {
        out.write(byteArrayOf(MESSAGE_CLIENT_CAPABILITIES.toByte()) + caps.encode())
        out.flush()
        lastAdvertisedCapabilities = caps
        diagLog("Advertised capabilities $caps")
    }

    private fun handleStreamFormat(format: StreamFormat) {
        if (format != streamFormat) diagLog("Stream format: $format")
        streamFormat = format
        if (format.hostSupportsClockSync) startClockSync()
        onStreamFormat?.invoke(format)
    }

    /** Type 17 every 100 ms for the first 2 s, then every 500 ms, until disconnect. Idempotent. */
    private fun startClockSync() {
        if (!isConnected || clockSyncJob?.isActive == true) return
        clockSyncJob =
            touchScope.launch {
                val start = System.nanoTime()
                while (isActive && isConnected) {
                    val out = outputStream ?: break
                    try {
                        out.write(ClockSyncWire.encodeRequest(System.nanoTime()))
                        out.flush()
                    } catch (_: IOException) {
                        break
                    }
                    val inBurst = System.nanoTime() - start < CLOCK_SYNC_BURST_NS
                    delay(if (inBurst) CLOCK_SYNC_BURST_INTERVAL_MS else CLOCK_SYNC_STEADY_INTERVAL_MS)
                }
            }
    }

    /** Type 18 payload follows the type byte; t3 is taken as soon as it is fully read. */
    private fun receiveClockSyncResponse(input: DataInputStream) {
        input.readFully(clockSyncPayload)
        val t3 = System.nanoTime()
        val (t0, t1, t2) = ClockSyncWire.parseResponse(clockSyncPayload)
        clockSync.addSample(t0, t1, t2, t3)
        val offset = clockSync.offsetNs ?: return
        val minRtt = clockSync.minRttNs ?: return
        if (!clockSyncLogged && clockSync.isConfident) {
            clockSyncLogged = true
            diagLog("Clock sync: offset=${offset}ns, minRtt=${minRtt / 1000}us")
        }
        onClockSync?.invoke(offset, minRtt)
    }

    /** Panel and codec the current connection advertises; fixed once per connect so every message agrees. */
    private var panel: PanelGeometry? = null
    private var negotiationMime: String = MediaFormat.MIMETYPE_VIDEO_HEVC

    private fun prepareAdvertisements() {
        panel = PanelGeometry.ofDefaultDisplay(context)
        val fallback =
            if (CodecCapabilities.hasHevcDecoder) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        negotiationMime = panel?.let { CodecCapabilities.preferredStreamMime(it.width, it.height) } ?: fallback
        streamFormat = null
        clockSync.reset()
        clockSyncLogged = false
        synchronized(capabilitiesLock) {
            lastAdvertisedCapabilities = null
        }
    }

    private fun advertiseAvcOnlyIfNeeded() {
        if (negotiationMime != MediaFormat.MIMETYPE_VIDEO_AVC) return
        outputStream?.let { out ->
            out.writeByte(MESSAGE_CLIENT_AVC_ONLY)
            out.flush()
            val why =
                if (CodecCapabilities.hasHevcDecoder) {
                    "H.264 sustains a larger picture than HEVC on this device"
                } else {
                    "no HEVC decoder on this device"
                }
            diagLog("Advertised AVC-only ($why)")
        }
    }

    private fun advertiseDecoderLimits() {
        val mime = negotiationMime
        // Nominal limit only as a fallback: it ignores blocks-per-second, so on most devices it is
        // far too high to protect anything.
        val limit =
            panel?.let { CodecCapabilities.maxStreamSize(mime, it.width, it.height, CodecCapabilities.REFERENCE_FPS) }
                ?: CodecCapabilities.nominalMaxDecodeSize(mime)
                ?: return
        val (maxW, maxH) = limit
        if (maxW < 256 || maxH < 256) return
        outputStream?.let { out ->
            out.writeByte(MESSAGE_CLIENT_DECODER_LIMITS)
            out.write(DecoderLimitWire.encodeSize(maxW, maxH))
            out.flush()
            val fps = CodecCapabilities.REFERENCE_FPS
            diagLog("Advertised stream limit ${maxW}x$maxH at $fps fps for $mime (panel=$panel)")
        }
        advertiseDecoderLimitTable(mime)
    }

    /**
     * Type 14: the sustainable size at each CodecCapabilities.TABLE_FPS rate, so the Mac can use
     * the figure for the rate it actually streams at instead of scaling the 60 fps one (issue
     * #78). Sent after type 11, which stays for Macs that predate this message and skip it.
     */
    private fun advertiseDecoderLimitTable(mime: String) {
        val p = panel ?: return
        val table = CodecCapabilities.streamLimitTable(mime, p.width, p.height) ?: return
        if (table.any { (w, h) -> w < 256 || h < 256 }) return
        outputStream?.let { out ->
            out.writeByte(MESSAGE_CLIENT_DECODER_LIMIT_TABLE)
            out.write(DecoderLimitWire.encodeTable(table))
            out.flush()
            val desc =
                CodecCapabilities.TABLE_FPS.zip(table).joinToString {
                        (fps, size) ->
                    "${fps}fps=${size.first}x${size.second}"
                }
            diagLog("Advertised stream limit table $desc for $mime")
        }
    }

    private suspend fun receiveData() =
        withContext(Dispatchers.IO) {
            val input = inputStream ?: return@withContext
            try {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_DISPLAY)
            } catch (_: Exception) {
            }

            try {
                while (isConnected) {
                    val type = input.readByte()

                    when (type.toInt()) {
                        MESSAGE_VIDEO_FRAME -> {
                            receiveVideoFrame(input, hasMetadata = false)
                        }

                        MESSAGE_VIDEO_FRAME_WITH_METADATA -> {
                            receiveVideoFrame(input, hasMetadata = true)
                        }

                        1 -> {
                            val width = input.readInt()
                            val height = input.readInt()
                            val transform = input.readInt()
                            val rotation = transform % 1000
                            val flags = transform / 1000
                            val flipHorizontal = flags and 1 == 1
                            val flipVertical = flags and 2 == 2
                            diagLog("Display config: ${width}x$height @ $rotation°, h=$flipHorizontal, v=$flipVertical")
                            onDisplaySize?.invoke(width, height, rotation, flipHorizontal, flipVertical)
                        }

                        5 -> { // Pong response — measure round-trip latency
                            val buf = ByteArray(8)
                            input.readFully(buf)
                            val sentTime = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN).long
                            val rtt = (System.nanoTime() - sentTime) / 1_000_000.0 // ms
                            onLatencyMeasured?.invoke(rtt)
                        }

                        MESSAGE_DESKTOP_GEOMETRY -> {
                            val dw = input.readInt()
                            val dh = input.readInt()
                            diagLog("Desktop geometry: ${dw}x$dh")
                            onDesktopSize?.invoke(dw, dh)
                        }

                        MESSAGE_CODEC_SELECTED -> {
                            val codecId = input.readByte().toInt()
                            streamCodecIsHevc = codecId == 0
                            codecNegotiated = true
                            diagLog("Server selected codec: ${if (streamCodecIsHevc) "HEVC" else "H.264"}")
                            onCodecSelected?.invoke(streamCodecIsHevc)
                        }

                        MESSAGE_STREAM_FORMAT -> {
                            input.readFully(streamFormatPayload)
                            val format = StreamFormat.parse(streamFormatPayload)
                            if (format != null) {
                                handleStreamFormat(format)
                            } else {
                                diagLog("Ignoring unsupported stream format ${streamFormatPayload.contentToString()}")
                            }
                        }

                        ClockSyncWire.MESSAGE_RESPONSE -> {
                            receiveClockSyncResponse(input)
                        }

                        else -> {
                            Log.e(
                                TAG,
                                "Unknown message type: ${type.toInt()}, stream may be misaligned — disconnecting",
                            )
                            break
                        }
                    }
                }
            } catch (e: IOException) {
                if (isConnected) {
                    Log.e(TAG, "❌ Read error", e)
                }
            } finally {
                disconnect()
            }
        }

    fun sendTouch(
        x: Float,
        y: Float,
        action: Int,
        pointerCount: Int = 1,
        x2: Float = 0f,
        y2: Float = 0f,
    ) {
        if (!isConnected) return

        touchScope.launch {
            try {
                socket?.getOutputStream()?.let { out ->
                    val count = pointerCount.coerceIn(1, 2)
                    val size = 6 + count * 8 // 1 type + 1 count + N*(4x+4y) + 4 action
                    val buffer = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
                    buffer.put(2.toByte())
                    buffer.put(count.toByte())
                    buffer.putFloat(x)
                    buffer.putFloat(y)
                    if (count == 2) {
                        buffer.putFloat(x2)
                        buffer.putFloat(y2)
                    }
                    buffer.putInt(action)
                    out.write(buffer.array())
                    out.flush()
                }
            } catch (_: Exception) {
            }
        }
    }

    // Callback for latency measurement (round-trip ping/pong)
    var onLatencyMeasured: ((Double) -> Unit)? = null

    /**
     * Ask the host to send an IDR/sync frame.
     *
     * Non-forced requests are rate-limited here so all callers share the same
     * backpressure guard. Forced requests are reserved for startup and hard
     * decoder recovery paths where waiting for the throttle would leave the
     * client black or unsynchronized.
     */
    fun requestKeyframe(
        force: Boolean = false,
        reason: String = "client request",
    ) {
        if (!isConnected) return
        val now = System.nanoTime()
        val shouldSend =
            synchronized(keyframeRequestLock) {
                if (!force &&
                    lastKeyframeRequestNs > 0L &&
                    now - lastKeyframeRequestNs < KEYFRAME_REQUEST_INTERVAL_NS
                ) {
                    false
                } else {
                    lastKeyframeRequestNs = now
                    true
                }
            }
        if (!shouldSend) return

        val flags = if (force) KEYFRAME_REQUEST_FLAG_FORCE else 0
        diagLog("Requesting keyframe: reason=$reason, force=$force")
        touchScope.launch {
            try {
                outputStream?.let { out ->
                    out.write(byteArrayOf(MESSAGE_KEYFRAME_REQUEST.toByte(), flags.toByte()))
                    out.flush()
                }
            } catch (_: Exception) {
            }
        }
    }

    /**
     * Send a ping to measure round-trip latency through the USB connection
     */
    fun sendPing() {
        if (!isConnected) return
        touchScope.launch {
            try {
                socket?.getOutputStream()?.let { out ->
                    val buffer = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
                    buffer.put(4.toByte()) // Type 4: ping
                    buffer.putLong(System.nanoTime())
                    out.write(buffer.array())
                    out.flush()
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun updateStats(bytes: Int) {
        bytesReceived += bytes
        framesReceived++

        val now = System.currentTimeMillis()
        val elapsed = now - lastStatsTime

        if (elapsed >= 1000) {
            val mbps = (bytesReceived * 8.0) / (elapsed / 1000.0) / 1_000_000
            val fps = (framesReceived * 1000.0) / elapsed
            onStats?.invoke(fps, mbps)

            bytesReceived = 0
            framesReceived = 0
            lastStatsTime = now
        }
    }

    private fun receiveVideoFrame(
        input: DataInputStream,
        hasMetadata: Boolean,
    ) {
        val frameSize = input.readInt()

        if (frameSize <= 0 || frameSize > MAX_FRAME_SIZE) {
            throw IOException("Invalid frame size: $frameSize")
        }

        var isKeyframe = false
        var hostCaptureNs = 0L
        if (hasMetadata) {
            val flags = input.readUnsignedByte()
            val timestamp = input.readLong()
            isKeyframe = (flags and FRAME_FLAG_KEYFRAME) != 0
            // Only hosts that send type 16 stamp the capture instant in the clock type 18 reports.
            if (streamFormat != null) hostCaptureNs = timestamp
        }

        val frameData = acquireBuffer(frameSize)
        input.readFully(frameData, 0, frameSize)

        if (!hasMetadata && !isKeyframe) {
            isKeyframe = isSyncFrame(frameData, frameSize, streamCodecIsHevc)
        }

        // Capture timestamp after full frame received for accurate age tracking.
        val receiveTimestamp = System.nanoTime()
        diagFrameCount++
        if (diagFrameCount == 1L) {
            diagLog(
                "First video frame: size=$frameSize, keyframe=$isKeyframe, " +
                    "metadata=$hasMetadata, callback=${onFrameReceived != null}",
            )
        }
        if (diagFrameCount % 60L == 0L) {
            diagLog("Frames received: $diagFrameCount")
        }

        val callback = onFrameReceived
        if (callback != null) {
            callback.invoke(frameData, frameSize, receiveTimestamp, isKeyframe, hostCaptureNs)
        } else {
            releaseBuffer(frameData)
        }
        updateStats(frameSize)
    }

    fun disconnect() {
        isConnected = false
        cleanup()
        onConnectionStatus?.invoke(false)
        Log.d(TAG, "Disconnected")
    }

    private fun cleanup() {
        clockSyncJob?.cancel()
        clockSyncJob = null
        try {
            outputStream?.close()
            inputStream?.close()
            socket?.close()

            // Properly shutdown executor with timeout to prevent orphaned threads
            touchExecutor.shutdown()
            try {
                if (!touchExecutor.awaitTermination(500, TimeUnit.MILLISECONDS)) {
                    touchExecutor.shutdownNow()
                    // Wait a bit more for forced shutdown
                    touchExecutor.awaitTermination(200, TimeUnit.MILLISECONDS)
                }
            } catch (e: InterruptedException) {
                touchExecutor.shutdownNow()
                Thread.currentThread().interrupt()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error during cleanup", e)
        }
        outputStream = null
        inputStream = null
        socket = null
    }

    private fun diagLog(msg: String) = DiagLog.log("SC", msg)

    companion object {
        private const val TAG = "StreamClient"

        // Only a desync guard — acquireBuffer allocates the real frame size, so a generous bound
        // costs nothing. Must clear a keyframe at panel resolution and the highest offered bitrate.
        private const val MAX_FRAME_SIZE = 32 * 1024 * 1024 // 32MB

        // 8 KB buffers headers into a single read() while allowing video frames (>= 8 KB) to
        // bypass BufferedInputStream's internal array and read directly into frameData.
        private const val INPUT_BUFFER_SIZE = 8 * 1024
        private const val PAIRING_READ_TIMEOUT_MS = 10_000
        private const val CLOCK_SYNC_BURST_NS = 2_000_000_000L
        private const val CLOCK_SYNC_BURST_INTERVAL_MS = 100L
        private const val CLOCK_SYNC_STEADY_INTERVAL_MS = 500L
        private const val KEYFRAME_REQUEST_INTERVAL_NS = 500_000_000L
        private const val MESSAGE_VIDEO_FRAME = 0
        private const val MESSAGE_VIDEO_FRAME_WITH_METADATA = 6
        private const val MESSAGE_KEYFRAME_REQUEST = 7
        private const val MESSAGE_CLIENT_SUPPORTS_FRAME_METADATA = 8
        private const val MESSAGE_CLIENT_AVC_ONLY = 9
        private const val MESSAGE_CODEC_SELECTED = 10
        private const val MESSAGE_CLIENT_DECODER_LIMITS = 11
        private const val MESSAGE_CLIENT_SUPPORTS_DESKTOP_GEOMETRY = 12
        private const val MESSAGE_DESKTOP_GEOMETRY = 13
        private const val MESSAGE_CLIENT_DECODER_LIMIT_TABLE = 14
        private const val MESSAGE_CLIENT_CAPABILITIES = 15
        private const val MESSAGE_STREAM_FORMAT = 16
        private const val FRAME_FLAG_KEYFRAME = 1
        private const val KEYFRAME_REQUEST_FLAG_FORCE = 1

        /**
         * Codec-aware sync-frame (keyframe) detection on the legacy
         * MESSAGE_VIDEO_FRAME path. HEVC: IRAP NAL types 16..21 from
         * (header and 0x7E) shr 1. H.264: IDR slice, (header and 0x1F) == 5.
         * Internal (not private) so unit tests can exercise both branches.
         */
        internal fun isSyncFrame(
            data: ByteArray,
            size: Int,
            isHevc: Boolean,
        ): Boolean {
            var i = 0
            while (i + 5 < size) {
                var start = -1
                var startCodeLength = 0

                while (i + 3 < size) {
                    if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                        if (data[i + 2] == 1.toByte()) {
                            start = i
                            startCodeLength = 3
                            break
                        }
                        if (i + 3 < size && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                            start = i
                            startCodeLength = 4
                            break
                        }
                    }
                    i++
                }

                if (start < 0) return false

                val nalStart = start + startCodeLength
                if (nalStart + 1 >= size) return false

                val header = data[nalStart].toInt()
                val isSync =
                    if (isHevc) {
                        ((header and 0x7E) shr 1) in 16..21
                    } else {
                        (header and 0x1F) == 5
                    }
                if (isSync) {
                    return true
                }

                i = nalStart + 2
            }
            return false
        }
    }
}

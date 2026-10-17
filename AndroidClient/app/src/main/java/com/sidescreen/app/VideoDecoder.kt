package com.sidescreen.app

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import android.view.Display
import android.view.Surface
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.math.roundToInt

private fun diagLog(msg: String) = DiagLog.log("VD", msg)

class VideoDecoder(
    private val surface: Surface,
    private val display: Display? = null,
    initialWidth: Int = 1920,
    initialHeight: Int = 1200,
    // Exposed so MainActivity can detect a codec-negotiation/decoder mismatch
    // and recreate the decoder (see MainActivity.onStreamCodecSelected).
    val mime: String = MediaFormat.MIMETYPE_VIDEO_HEVC,
    streamFormat: StreamFormat? = null,
    private val targetFps: Int = 60,
) {
    // Replaced by restart() on the UI thread while the receive thread decodes.
    private val codecLock = Any()

    @Volatile private var decoder: MediaCodec? = null
    private var decoderThread: HandlerThread? = null
    private var decoderHandler: Handler? = null

    private var droppedFrames = 0L
    private var supersededOutputs = 0L
    private var inputFrameCount = 0L
    private var outputFrameCount = 0L

    // Decoder pipeline latency (input enqueue -> output buffer available),
    // accumulated over ~60 frames then logged. High values indicate the codec
    // is queuing frames internally (compose/present can't keep up downstream),
    // which surfaces to the user as input lag on the captured display.
    private var latencySumNs: Long = 0
    private var latencySamples: Int = 0
    private var latencyMaxNs: Long = 0

    /**
     * Highest refresh rate the panel offers. Not the current mode: an LTPO panel idles at a low
     * rate until something animates, and an operating rate taken from that would clock the
     * decoder down for the whole session.
     */
    private val peakRefreshHz: Int =
        display
            ?.supportedModes
            ?.maxOfOrNull { it.refreshRate }
            ?.roundToInt()
            ?.takeIf { it > 0 } ?: DEFAULT_REFRESH_HZ

    private var currentWidth = initialWidth
    private var currentHeight = initialHeight

    @Volatile private var currentFormat: StreamFormat? = streamFormat

    /** True when the running codec was configured for an HDR stream (10-bit profile + colour keys). */
    @Volatile var isHdrConfigured = false
        private set

    @Volatile private var isRunning = false

    @Volatile private var needsKeyframe = true

    private var lastKeyframeRequestNs = 0L

    /**
     * Decoder thread, once per decoded picture as it becomes available (before the latest-wins
     * render decision): `ptsUs` is the `frameTimestamp / 1000` given to [decode], `nowNs` is
     * `System.nanoTime()`.
     */
    var onFrameOutput: ((ptsUs: Long, nowNs: Long) -> Unit)? = null

    /**
     * Decoder thread, from [MediaCodec.OnFrameRenderedListener]: `renderNs` is the
     * `System.nanoTime()` instant the picture was rendered to the output surface (about the
     * SurfaceFlinger latch). Reports may arrive batched and are best-effort.
     */
    var onFrameRendered: ((ptsUs: Long, renderNs: Long) -> Unit)? = null
    var onFrameDecoded: ((ByteArray) -> Unit)? = null
    var onKeyframeRequired: ((force: Boolean, reason: String) -> Unit)? = null

    /** Fired once when the decoder has accepted many frames but never output any —
     *  the black-screen-with-live-stats signature (stream above the device's
     *  decode limit, or an unusable decoder). Counts only frames actually queued
     *  to MediaCodec, so pre-keyframe drops on a slow start can't trigger it. */
    var onDecoderStalled: (() -> Unit)? = null
    private var stallReported = false
    private var queuedInputCount = 0L

    // Available input buffer indices — fed by onInputBufferAvailable callback
    private val availableInputBuffers = ConcurrentLinkedQueue<Int>()

    init {
        setupDecoder()
    }

    fun updateResolution(
        width: Int,
        height: Int,
    ) = synchronized(codecLock) {
        if (width != currentWidth || height != currentHeight) {
            currentWidth = width
            currentHeight = height
            restart("resolution changed")
        }
    }

    /**
     * Adopt the host's type-16 stream format. The codec is recreated only when the part it is
     * configured with changes (bit depth / HDR colour description); fps or flag changes are
     * absorbed without a gap.
     */
    fun updateStreamFormat(format: StreamFormat) =
        synchronized(codecLock) {
            val previous = currentFormat
            currentFormat = format
            if (colorConfig(previous) == colorConfig(format)) return@synchronized
            diagLog("Stream format changed: $previous -> $format")
            restart("stream format changed")
        }

    private fun restart(reason: String) {
        release()
        setupDecoder()
        // A fresh codec cannot decode anything until the next IDR: never throttle this request.
        lastKeyframeRequestNs = 0L
        requestKeyframe(reason, force = true)
    }

    /**
     * The part of a stream format the codec is configured with. 8-bit SDR configures exactly
     * like an old host's stream (no colour keys), so it maps to null as well.
     */
    private fun colorConfig(format: StreamFormat?): StreamFormat? =
        format
            ?.takeIf { it.isHdr || it.bitDepth > 8 }
            ?.copy(fps = 0, hostSupportsClockSync = false, hostMatchesPanel = false)

    /** Configure rungs, tried in order; vendor keys go first, then everything not essential. */
    private enum class ConfigRung(
        val label: String,
        val turboRate: Boolean,
        val vendorKeys: Boolean,
        val lowLatency: Boolean,
        val tuned: Boolean,
    ) {
        TURBO("turbo low-latency + vendor keys", turboRate = true, vendorKeys = true, lowLatency = true, tuned = true),
        VENDOR("full low-latency + vendor keys", turboRate = false, vendorKeys = true, lowLatency = true, tuned = true),
        LOW_LATENCY("full low-latency", turboRate = false, vendorKeys = false, lowLatency = true, tuned = true),
        BASIC("basic", turboRate = false, vendorKeys = false, lowLatency = false, tuned = true),
        MINIMAL("minimal", turboRate = false, vendorKeys = false, lowLatency = false, tuned = false),
    }

    private fun setupDecoder() {
        val thread = HandlerThread("DecoderThread", Process.THREAD_PRIORITY_URGENT_DISPLAY).also { it.start() }
        val handler = Handler(thread.looper)
        decoderThread = thread
        decoderHandler = handler
        availableInputBuffers.clear()
        queuedInputCount = 0L
        outputFrameCount = 0L
        stallReported = false
        val isHevc = mime.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true)
        val wanted = colorConfig(currentFormat)?.takeIf { isHevc }
        val streamFps = currentFormat?.fps?.takeIf { it > 0 } ?: targetFps
        val operatingRate = maxOf(targetFps, streamFps, peakRefreshHz)

        // Find a decoder that supports our resolution (prefer HW, fallback to SW)
        val decoderName =
            findBestDecoder(
                currentWidth,
                currentHeight,
                streamFps,
                if (wanted != null) MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10 else null,
            )
        diagLog("setupDecoder: ${currentWidth}x$currentHeight, decoder=$decoderName, format=$currentFormat")

        val codec =
            if (decoderName != null) {
                MediaCodec.createByCodecName(decoderName)
            } else {
                MediaCodec.createDecoderByType(mime)
            }
        // The 10-bit profile and colour description only go to a decoder that advertises Main10;
        // any other decoder is configured exactly like the SDR path.
        val profile = wanted?.let { hevc10BitProfile(codec.codecInfo, it) }
        val color = wanted.takeIf { profile != null }
        val vendorKeys = vendorLowLatencyKeys(codec.name)
        val callback =
            object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                ) {
                    if (isRunning) availableInputBuffers.offer(index)
                }

                override fun onOutputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                    info: MediaCodec.BufferInfo,
                ) {
                    handleOutputBuffer(codec, index, info)
                }

                override fun onError(
                    codec: MediaCodec,
                    e: MediaCodec.CodecException,
                ) {
                    diagLog("Codec error: ${e.diagnosticInfo}")
                    Log.e(TAG, "Codec error: ${e.diagnosticInfo}", e)
                    needsKeyframe = true
                    requestKeyframe("codec error", force = true)
                }

                override fun onOutputFormatChanged(
                    codec: MediaCodec,
                    format: MediaFormat,
                ) {
                    diagLog("Output format changed: $format")
                }
            }
        val renderedListener =
            MediaCodec.OnFrameRenderedListener { _, ptsUs, renderNs ->
                onFrameRendered?.invoke(ptsUs, renderNs)
            }
        // reset() drops both registrations, so every failed rung re-installs them.
        val install = {
            codec.setCallback(callback, handler)
            codec.setOnFrameRenderedListener(renderedListener, handler)
        }
        install()

        val rungs = ConfigRung.entries.filter { !it.vendorKeys || vendorKeys.isNotEmpty() }
        var configured: ConfigRung? = null
        var lastError: Exception? = null
        for (rung in rungs) {
            try {
                codec.configure(buildFormat(rung, operatingRate, color, profile, vendorKeys), surface, null, 0)
                configured = rung
                diagLog("Configured with ${rung.label}")
                break
            } catch (e: Exception) {
                diagLog("${rung.label} config failed: ${e.message}")
                lastError = e
                if (rung != rungs.last()) {
                    codec.reset()
                    install()
                }
            }
        }
        if (configured == null) {
            diagLog("All configure attempts failed: ${lastError?.message}")
            Log.e(TAG, "All configure attempts failed", lastError)
            codec.release()
            thread.quitSafely()
            decoderThread = null
            decoderHandler = null
            throw lastError ?: IllegalStateException("Decoder configure failed")
        }

        codec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
        isHdrConfigured = color?.isHdr == true && configured.tuned
        needsKeyframe = true
        isRunning = true
        codec.start()
        if (configured.lowLatency) {
            try {
                val params =
                    android.os.Bundle().apply {
                        putInt(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
                    }
                codec.setParameters(params)
            } catch (_: Exception) {
            }
        }
        decoder = codec
        diagLog(
            "Decoder started: ${currentWidth}x$currentHeight, operatingRate=$operatingRate " +
                "(peak ${peakRefreshHz}Hz), profile=$profile, hdr=$isHdrConfigured, " +
                "vendorKeys=${vendorKeys.keys}, surface=$surface, valid=${surface.isValid}",
        )
    }

    private fun buildFormat(
        rung: ConfigRung,
        operatingRate: Int,
        color: StreamFormat?,
        profile: Int?,
        vendorKeys: Map<String, Int>,
    ): MediaFormat {
        val format = MediaFormat.createVideoFormat(mime, currentWidth, currentHeight)
        if (rung.tuned) {
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, operatingRate)
            if (color != null) {
                profile?.let { format.setInteger(MediaFormat.KEY_PROFILE, it) }
                // Hints only: the decoder takes the VUI and the in-band mastering-display /
                // content-light SEI the Mac's encoder inserts, so no KEY_HDR_STATIC_INFO is
                // invented here.
                format.setInteger(MediaFormat.KEY_COLOR_STANDARD, color.colorStandard())
                format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, color.colorTransfer())
                format.setInteger(MediaFormat.KEY_COLOR_RANGE, color.colorRange())
            }
        }
        if (rung.lowLatency) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            val targetRate = if (rung.turboRate) maxOf(operatingRate * 4, 480) else operatingRate
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, targetRate)
        }
        if (rung.vendorKeys) {
            vendorKeys.forEach { (key, value) -> format.setInteger(key, value) }
        }
        return format
    }

    /**
     * Main10HDR10 for PQ streams when [info] advertises it (static metadata pass-through), else
     * Main10 when advertised (an HDR10 profile implies it), else null: not a 10-bit decoder.
     */
    private fun hevc10BitProfile(
        info: MediaCodecInfo,
        color: StreamFormat,
    ): Int? {
        val main10 = MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10
        val hdr10 = MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10
        val hdr10Plus = MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10Plus
        val supportsHdr10 = CodecCapabilities.supportsProfile(info, mime, hdr10)
        val isPq = color.colorTransfer() == MediaFormat.COLOR_TRANSFER_ST2084
        return when {
            isPq && supportsHdr10 -> hdr10
            supportsHdr10 ||
                CodecCapabilities.supportsProfile(info, mime, main10) ||
                CodecCapabilities.supportsProfile(info, mime, hdr10Plus) -> main10
            else -> null
        }
    }

    /**
     * Find the best decoder for [mime] at the given resolution and [fps], preferring one that
     * advertises [requiredProfile] when set (falls back to any decoder if none does).
     * Prefers hardware decoders, falls back to software if HW can't handle the resolution.
     * Returns codec name to use with MediaCodec.createByCodecName(), or null for default.
     */
    private fun findBestDecoder(
        width: Int,
        height: Int,
        fps: Int,
        requiredProfile: Int?,
    ): String? {
        val infos =
            try {
                MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.filter { !it.isEncoder }
            } catch (e: Exception) {
                diagLog("Decoder search failed: ${e.message}")
                return null
            }
        if (requiredProfile != null) {
            pickDecoder(infos, width, height, fps) {
                CodecCapabilities.supportsProfile(it, mime, requiredProfile)
            }?.let { return it }
            diagLog("No decoder advertises profile $requiredProfile — choosing without it")
        }
        return pickDecoder(infos, width, height, fps) { true }
    }

    private fun pickDecoder(
        infos: List<MediaCodecInfo>,
        width: Int,
        height: Int,
        fps: Int,
        accept: (MediaCodecInfo) -> Boolean,
    ): String? {
        val targetRate = fps.toDouble().coerceAtLeast(30.0)
        var hwLowLatencyRateDecoder: String? = null
        var hwRateDecoder: String? = null
        var hwSizeDecoder: String? = null
        var swRateDecoder: String? = null
        var swSizeDecoder: String? = null

        for (info in infos) {
            val caps =
                try {
                    info.getCapabilitiesForType(mime)
                } catch (_: Exception) {
                    continue
                }
            if (!accept(info)) continue
            // Secure-only decoders (e.g. c2.qti.hevc.decoder.secure) need a protected surface.
            if (caps.isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_SecurePlayback)) continue
            val lowLatency = caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)

            val videoCaps = caps.videoCapabilities ?: continue
            val isHardware =
                !info.name.startsWith("c2.android.") &&
                    !info.name.startsWith("OMX.google.")
            val supported = videoCaps.isSizeSupported(width, height)
            val rateSupported =
                supported &&
                    try {
                        videoCaps.areSizeAndRateSupported(width, height, targetRate)
                    } catch (_: Exception) {
                        false
                    }

            diagLog(
                "$mime decoder '${info.name}': " +
                    "width=${videoCaps.supportedWidths}, " +
                    "height=${videoCaps.supportedHeights}, " +
                    "hw=$isHardware, lowLatency=$lowLatency, supports ${width}x$height=$supported, " +
                    "supports @${"%.0f".format(targetRate)}fps=$rateSupported",
            )

            if (supported) {
                if (isHardware && rateSupported && lowLatency && hwLowLatencyRateDecoder == null) {
                    hwLowLatencyRateDecoder = info.name
                } else if (isHardware && rateSupported && hwRateDecoder == null) {
                    hwRateDecoder = info.name
                } else if (isHardware && hwSizeDecoder == null) {
                    hwSizeDecoder = info.name
                } else if (!isHardware && rateSupported && swRateDecoder == null) {
                    swRateDecoder = info.name
                } else if (!isHardware && swSizeDecoder == null) {
                    swSizeDecoder = info.name
                }
            }
        }

        // Prefer hardware that advertises low latency (Qualcomm ships a dedicated
        // `c2.qti.hevc.decoder.low_latency`) at the target rate, then any hardware at
        // the rate, then any hardware for the size, then software as a last resort.
        val chosen = hwLowLatencyRateDecoder ?: hwRateDecoder ?: hwSizeDecoder ?: swRateDecoder ?: swSizeDecoder
        if (chosen != null) {
            diagLog(
                "Selected decoder: $chosen " +
                    "(rateSupported=${chosen == hwLowLatencyRateDecoder || chosen == hwRateDecoder ||
                        chosen == swRateDecoder})",
            )
        } else {
            diagLog("No decoder supports ${width}x$height — will use default")
        }
        return chosen
    }

    fun decode(
        frameData: ByteArray,
        frameSize: Int = frameData.size,
        frameTimestamp: Long = System.nanoTime(),
        isKeyframe: Boolean = false,
    ) = synchronized(codecLock) {
        if (!isRunning) {
            diagLog("decode called but isRunning=false")
            onFrameDecoded?.invoke(frameData)
            return
        }

        inputFrameCount++
        if (inputFrameCount == 1L) {
            val header =
                frameData
                    .take(minOf(16, frameSize))
                    .joinToString(" ") { String.format("%02x", it) }
            diagLog(
                "First frame: size=$frameSize, header=[$header], " +
                    "keyframe=$isKeyframe, surface=$surface, valid=${surface.isValid}",
            )
        }
        if (inputFrameCount % 60L == 0L) {
            diagLog(
                "Decode stats: input=$inputFrameCount, output=$outputFrameCount, " +
                    "dropped=$droppedFrames, superseded=$supersededOutputs, " +
                    "availBufs=${availableInputBuffers.size}",
            )
        }
        val codec =
            decoder ?: run {
                diagLog("decoder is null in decode()")
                onFrameDecoded?.invoke(frameData)
                return
            }

        if (needsKeyframe && !isKeyframe) {
            dropFrame(
                frameData,
                isKeyframe,
                "waiting for keyframe",
                waitForKeyframe = true,
            )
            return
        }

        // Direct feed: grab an available input buffer. If momentarily empty,
        // brief retry for up to 2 ms before giving up to avoid dropping reference frames.
        var index = availableInputBuffers.poll()
        if (index == null) {
            val deadline = System.nanoTime() + 2_000_000L
            while (index == null && System.nanoTime() < deadline) {
                Thread.yield()
                index = availableInputBuffers.poll()
            }
        }
        if (index == null) {
            // Pool truly exhausted: wait for keyframe to prevent ghost cursor / inverted reference corruption.
            dropFrame(frameData, isKeyframe, "no input buffer", waitForKeyframe = true)
            requestKeyframe("no input buffer", force = true)
            return@synchronized
        }

        queueFrame(codec, index, frameData, frameSize, frameTimestamp, isKeyframe)
    }

    private fun queueFrame(
        codec: MediaCodec,
        index: Int,
        frameData: ByteArray,
        frameSize: Int,
        frameTimestamp: Long,
        isKeyframe: Boolean,
    ) {
        try {
            val inputBuffer =
                codec.getInputBuffer(index)
                    ?: throw IllegalStateException("Input buffer $index is null")
            inputBuffer.clear()
            inputBuffer.put(frameData, 0, frameSize)
            codec.queueInputBuffer(index, 0, frameSize, frameTimestamp / 1000, 0)
            queuedInputCount++
            if (queuedInputCount == STALL_DETECT_INPUT_FRAMES && outputFrameCount == 0L && !stallReported) {
                stallReported = true
                diagLog("Decoder stalled: $queuedInputCount frames queued, none out")
                onDecoderStalled?.invoke()
            }
            if (isKeyframe) {
                needsKeyframe = false
            }
        } catch (e: Exception) {
            needsKeyframe = true
            requestKeyframe("queue input failed")
            Log.e(TAG, "decode direct feed error", e)
        } finally {
            onFrameDecoded?.invoke(frameData)
        }
    }

    private fun dropFrame(
        frameData: ByteArray,
        isKeyframe: Boolean,
        reason: String,
        waitForKeyframe: Boolean,
        requestRefresh: Boolean = waitForKeyframe,
    ) {
        droppedFrames++
        if (droppedFrames <= 3L || droppedFrames % 60L == 0L) {
            diagLog("Dropping frame ($reason, keyframe=$isKeyframe, dropped=$droppedFrames)")
        }
        if (waitForKeyframe) {
            needsKeyframe = true
        }
        if (requestRefresh) {
            requestKeyframe(reason)
        }
        onFrameDecoded?.invoke(frameData)
    }

    private fun requestKeyframe(
        reason: String,
        force: Boolean = false,
    ) {
        val now = System.nanoTime()
        val interval =
            if (force) FORCE_KEYFRAME_REQUEST_INTERVAL_NS else KEYFRAME_REQUEST_INTERVAL_NS
        if (now - lastKeyframeRequestNs < interval) {
            return
        }
        lastKeyframeRequestNs = now
        diagLog("Requesting keyframe: reason=$reason, force=$force")
        onKeyframeRequired?.invoke(force, reason)
    }

    private fun handleOutputBuffer(
        codec: MediaCodec,
        index: Int,
        info: MediaCodec.BufferInfo,
    ) {
        if (!isRunning) return
        val nowNs = System.nanoTime()
        val renderTimestampNs =
            (info.presentationTimeUs * 1000L).takeIf { it > 0L && nowNs - it in 0..MAX_REASONABLE_LATENCY_NS }
                ?: nowNs
        try {
            // Immediate release with explicit timestamp (isAutoTimestamp = false):
            // BLASTBufferQueue/SurfaceFlinger natively drops any older unlatched buffer in the
            // same VSYNC interval while avoiding OutputPacer's extra Looper message-queue turn.
            codec.releaseOutputBuffer(index, renderTimestampNs)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "releaseOutputBuffer failed", e)
            return
        }

        outputFrameCount++
        if (outputFrameCount == 1L) {
            diagLog("First output frame! size=${info.size}, flags=${info.flags}")
        }

        // Decoder latency: time from queueInputBuffer (where we encoded
        // System.nanoTime()/1000 as PTS) to now. Captures how long the
        // frame spent inside the codec's input/reorder/output queues.
        val latencyNs = nowNs - info.presentationTimeUs * 1000L
        if (latencyNs in 0..MAX_REASONABLE_LATENCY_NS) {
            latencySumNs += latencyNs
            latencySamples++
            if (latencyNs > latencyMaxNs) latencyMaxNs = latencyNs
        }

        if (outputFrameCount % 60L == 0L) {
            val avgMs = if (latencySamples > 0) latencySumNs / latencySamples / 1_000_000.0 else 0.0
            val maxMs = latencyMaxNs / 1_000_000.0
            val inBufs = availableInputBuffers.size
            diagLog(
                "Output #$outputFrameCount: decoder latency avg=${"%.1f".format(avgMs)}ms " +
                    "max=${"%.1f".format(maxMs)}ms over $latencySamples samples, " +
                    "input bufs avail=$inBufs, dropped=$droppedFrames, superseded=$supersededOutputs",
            )
            latencySumNs = 0
            latencySamples = 0
            latencyMaxNs = 0
        }

        onFrameOutput?.invoke(info.presentationTimeUs, nowNs)
    }

    fun release() =
        synchronized(codecLock) {
            isRunning = false
            isHdrConfigured = false
            val oldDecoder = decoder
            decoder = null
            try {
                oldDecoder?.stop()
            } catch (_: Exception) {
            }
            try {
                oldDecoder?.release()
            } catch (_: Exception) {
            }
            availableInputBuffers.clear()
            try {
                decoderThread?.quitSafely()
            } catch (_: Exception) {
            }
            decoderThread = null
            decoderHandler = null
        }

    companion object {
        private const val TAG = "VideoDecoder"
        private const val DEFAULT_REFRESH_HZ = 60
        private const val STALL_DETECT_INPUT_FRAMES = 120L
        private const val KEYFRAME_REQUEST_INTERVAL_NS = 1_000_000_000L
        private const val FORCE_KEYFRAME_REQUEST_INTERVAL_NS = 200_000_000L
        private const val MAX_REASONABLE_LATENCY_NS = 2_000_000_000L

        private val QUALCOMM_PREFIXES = listOf("c2.qti.", "omx.qcom.")
        private val EXYNOS_PREFIXES = listOf("c2.exynos.", "omx.exynos.")

        /**
         * Vendor low-latency extensions for [codecName], matched by (case-insensitive) name
         * prefix so no other vendor ever sees them. Qualcomm's picture-order key emits frames in
         * decode order, which is only correct because the Mac encodes without frame reordering.
         * MediaTek (`c2.mtk.`) has no documented decoder low-latency key; [MediaFormat.KEY_LOW_LATENCY]
         * is all it gets.
         */
        private fun vendorLowLatencyKeys(codecName: String): Map<String, Int> {
            val name = codecName.lowercase()
            return when {
                QUALCOMM_PREFIXES.any { name.startsWith(it) } ->
                    mapOf(
                        "vendor.qti-ext-dec-low-latency.enable" to 1,
                        "vendor.qti-ext-dec-picture-order.enable" to 1,
                    )
                EXYNOS_PREFIXES.any { name.startsWith(it) } ->
                    mapOf("vendor.rtc-ext-dec-low-latency.enable" to 1)
                else -> emptyMap()
            }
        }
    }
}

package dev.qiyu.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

private const val OMNI_CALL_CHANNEL = "dev.qiyu.app/omni_call"
internal const val OMNI_MIC_PERMISSION_REQUEST_CODE = 7062

/**
 * Omni 双工通话的原生桥（T05）：连续上行采集 + 通话播放流 + microphone
 * 前台服务，一条通道（`dev.qiyu.app/omni_call`）承载。
 *
 * 与 VoiceBridge（按住说话/朗读）的关系：那是一条「录完才交、单轮互斥」
 * 的通道——整段字节 stop 后才回传，且采集持独占焦点、禁止与播放同时。
 * 双工通话（T05:11）要求同时录放，本桥不复用那套互斥：采集用标准通信
 * 音源（VOICE_COMMUNICATION）加设备可用回声消除（AcousticEchoCanceler，
 * 不写自制 DSP，spec:82），焦点整通持有（AUDIOFOCUS_GAIN，非独占非瞬
 * 态），与播放流共存；按住说话路径的行为零变化。
 *
 * 生命周期归属与 VoiceBridge 的关键差异：**不跟随 Activity 前后台**。
 * 锁屏／切 App 期间通话继续（spec:23），Activity 只在销毁（onDestroy）
 * 时才经 [unregister] 收口整通（含前台服务）——界面没了麦克风必须灭。
 * 前台服务（OmniCallForegroundService）只在可见聊天界面手动或已授权自动
 * 拉起，系统或用户从系统入口停止它时如实上报 Dart 结束通话，绝不自行
 * 复活（T05:14）。
 *
 * 线协议（与 Dart 侧 `omni_call_native_channel.dart` 一一对应）：
 * - Dart→原生：`hasMicrophonePermission`、`requestMicrophonePermission`、
 *   `canAutoStartCapture`、`startCapture`、`cancelPendingCaptureStart`、
 *   `stopCapture`、`setMuted`、`prepareForAutoPlayback`、`startStream`、
 *   `appendStreamChunk`、`endStream`、`setStreamVolume`、`stopStream`。
 * - 原生→Dart：`onCaptureChunk`（PCM16 16k 单声道约 100ms 一块，字节
 *   直接走 StandardMessageCodec）、`onCaptureUnavailable {reason}`、
 *   `onPlaybackFinished {id}`。
 *
 * 焦点与打断语义：负向焦点变化只停当前播放流（onPlaybackFinished 逐路
 * 通知，Dart 侧 done 收口后下一路才能开流）；通话与麦克风继续，用户说
 * 话与下一轮回复照常。永久丢失（AUDIOFOCUS_LOSS）额外上报 unavailable，
 * 由 Dart 真实结束通话——音频已不归本应用支配，硬撑通话不诚实。
 *
 * 线程纪律：起采/收口全部排在单线程 executor 上串行（start 与 stop 交错
 * 不会互相拆对方的家当）；MethodChannel 的 Result 与下行通知一律经
 * mainHandler 回主线程；AudioRecord 的 stop/release 归采集线程自己的
 * finally（与 VoiceBridge 同一教训：并发释放阻塞在 read 上的 record 是
 * 原生层崩溃隐患）。
 */
internal object OmniCallBridge {
    // 上行契约（T04 定档）：PCM16、16 kHz、单声道，约 100ms 一块。
    // 与 Dart 侧 omniCaptureSampleRate 同源同值（跨语言，改动必须两端同步）。
    private const val SAMPLE_RATE = 16000
    private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
    private const val ENCODING = AudioFormat.ENCODING_PCM_16BIT
    private const val CHUNK_BYTES = SAMPLE_RATE * 2 / 10

    /** 采集线程复查麦克风授权的周期：isClientSilenced 只有 API 30+，
     *  官方文档也未对更早版本明文保证「设置撤销即杀进程」（usage-notes
     *  反而预期应用处理设置 toggle off 后的异常）——复查让 spec:23 的
     *  「权限撤销真实结束」在全部受支持版本上无条件成立。 */
    private const val PERMISSION_RECHECK_INTERVAL_MS = 2000L

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    /** 通话通道与界面绑定；服务启停用 applicationContext（进程级）。 */
    @Volatile
    private var activity: MainActivity? = null

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var channel: MethodChannel? = null

    @Volatile
    private var activityVisible = false

    private val cancelledCaptureRequest = AtomicInteger(-1)
    private val bridgeGeneration = AtomicInteger(0)
    @Volatile
    private var activeCaptureRequest = -1

    private val pendingPermissionResult = AtomicReference<MethodChannel.Result?>(null)

    // ---- 采集状态（起/停串行在 executor 上；标志位跨线程读用 volatile） ----
    @Volatile
    private var capturing = false

    @Volatile
    private var muted = false

    @Volatile
    private var captureInterrupted = false

    @Volatile
    private var captureThread: Thread? = null

    private var aec: AcousticEchoCanceler? = null
    private var releaseCallObservers: (() -> Unit)? = null
    @Volatile
    private var callFocusHeld = false

    // ---- 通话播放流：AudioTrack MODE_STREAM，块经通道写进原生写队列，
    // 音频只在内存。与 VoiceBridge 的朗读流分开（焦点与生命周期归通话）。----
    private val nextStreamId = AtomicInteger(1)
    private val streams = ConcurrentHashMap<Int, AudioTrack>()
    private val streamQueues = ConcurrentHashMap<Int, java.util.concurrent.LinkedBlockingQueue<ByteArray>>()
    private val streamEnded = ConcurrentHashMap<Int, Boolean>()
    private val streamStopped = ConcurrentHashMap<Int, Boolean>()

    /** 原生侧收口（焦点打断/整通收尾）置位：writer 出口据此照常通知 Dart。 */
    private val streamInterrupted = ConcurrentHashMap<Int, Boolean>()
    private val streamWriters = ConcurrentHashMap<Int, Thread>()

    fun register(messenger: BinaryMessenger, hostActivity: MainActivity) {
        bridgeGeneration.incrementAndGet()
        cancelledCaptureRequest.set(-1)
        activity = hostActivity
        appContext = hostActivity.applicationContext
        channel = MethodChannel(messenger, OMNI_CALL_CHANNEL).also { chan ->
            chan.setMethodCallHandler { call, result -> handle(call, result) }
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode != OMNI_MIC_PERMISSION_REQUEST_CODE) {
            return
        }
        // 结果只看 RECORD_AUDIO：POST_NOTIFICATIONS（33+ 一并请求）是
        // 通知可见性的尽力而为，**不作为**服务启动或通话开始的前提
        // （T05:12——不把通知授权误当系统版本前提）。
        val index = permissions.indexOf(Manifest.permission.RECORD_AUDIO)
        val granted = index >= 0 &&
            grantResults[index] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult.getAndSet(null)?.success(granted)
    }

    /** 可见性仅限制新通话；已有通话照常在后台／锁屏运行。 */
    fun onForegroundChanged(visible: Boolean) {
        activityVisible = visible
    }

    /**
     * Activity 销毁：界面没了麦克风不该还亮着。整通收口（采集、播放、
     * 观察者、前台服务）照常执行——engine 拆除后通道已不可达，不再向
     * Dart 发任何通知，也绝不复活。
     */
    fun unregister() {
        bridgeGeneration.incrementAndGet()
        activityVisible = false
        pendingPermissionResult.getAndSet(null)?.error(
            "ACTIVITY_DESTROYED",
            "界面已销毁，权限请求已取消。",
            null,
        )
        // 通道与 Activity 即刻摘除：engine 拆除后不得再有下行通知；
        // 资源收口排在同一 executor 上与起/停串行。
        channel = null
        activity = null
        executor.execute { stopCallResources() }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasMicrophonePermission" -> result.success(hasMicPermission())
            "canAutoStartCapture" -> result.success(canAutoStartCapture())
            "requestMicrophonePermission" -> requestMicPermission(result)
            "startCapture" -> {
                val requestId = captureRequestId(call) ?: 0
                val generation = bridgeGeneration.get()
                executor.execute { startCapture(result, requestId, generation) }
            }
            "cancelPendingCaptureStart" -> {
                val requestId = captureRequestId(call)
                if (requestId != null) {
                    val generation = bridgeGeneration.get()
                    cancelledCaptureRequest.accumulateAndGet(requestId) { old, next -> maxOf(old, next) }
                    executor.execute {
                        if (generation == bridgeGeneration.get() && activeCaptureRequest == requestId) {
                            stopCallResources()
                        }
                    }
                }
                result.success(null)
            }
            "stopCapture" -> {
                val requestId = captureRequestId(call)
                executor.execute { stopCapture(result, requestId) }
            }
            "prepareForAutoPlayback" -> executor.execute {
                val ready = prepareForAutoPlayback()
                postResult(result) { success(ready) }
            }
            "setMuted" -> {
                // 闭麦只停发有效音频（spec 前端摆放）：采集继续读以免恢复
                // 时吐旧数据，块不再出桥；Dart 侧同步发 mute 帧给 Host。
                muted = call.arguments as? Boolean ?: false
                result.success(null)
            }
            "startStream" -> startStream(call, result)
            "appendStreamChunk" -> appendStreamChunk(call, result)
            "endStream" -> {
                val id = (call.arguments as? Map<*, *>)?.get("id") as? Int
                if (id != null && streams.containsKey(id)) streamEnded[id] = true
                result.success(null)
            }
            "setStreamVolume" -> {
                val args = call.arguments as? Map<*, *>
                val id = args?.get("id") as? Int
                val volume = (args?.get("volume") as? Number)?.toDouble() ?: 1.0
                streams[id]?.setVolume(volume.toFloat().coerceIn(0.0f, 1.0f))
                result.success(null)
            }
            "stopStream" -> {
                val id = (call.arguments as? Map<*, *>)?.get("id") as? Int
                if (id != null) releaseStream(id)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun hasMicPermission(): Boolean =
        activity?.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun captureRequestId(call: MethodCall): Int? =
        ((call.arguments as? Map<*, *>)?.get("requestId") as? Number)?.toInt()

    private fun canAutoStartCapture(): Boolean {
        if (!activityVisible || !hasMicPermission() || capturing) return false
        val manager = activity?.getSystemService(AudioManager::class.java) ?: return false
        if (manager.isMicrophoneMute) return false
        if (manager.getDevices(AudioManager.GET_DEVICES_INPUTS).none { it.isSource }) return false
        return AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, ENCODING) > 0
    }

    private fun requestMicPermission(result: MethodChannel.Result) {
        val host = activity
        if (host == null || !activityVisible) {
            result.success(false)
            return
        }
        if (hasMicPermission()) {
            result.success(true)
            return
        }
        // 并发的第二次请求按失败回：弹窗节奏由用户点击驱动，串行足够。
        if (!pendingPermissionResult.compareAndSet(null, result)) {
            result.error("BUSY", "已有权限请求在等待结果。", null)
            return
        }
        val permissions = if (Build.VERSION.SDK_INT >= 33) {
            arrayOf(
                Manifest.permission.RECORD_AUDIO,
                Manifest.permission.POST_NOTIFICATIONS,
            )
        } else {
            arrayOf(Manifest.permission.RECORD_AUDIO)
        }
        host.requestPermissions(permissions, OMNI_MIC_PERMISSION_REQUEST_CODE)
    }

    // ------------------------------------------------------------------
    // 采集（连续 PCM 上行）
    // ------------------------------------------------------------------

    /** 起采（executor 串行）：前台服务 → AudioRecord（通信音源）→ 焦点
     *  与观察者 → 采集线程。任一步失败回滚已起资源并如实 success(false)。 */
    @SuppressLint("MissingPermission")
    private fun startCapture(result: MethodChannel.Result, requestId: Int, generation: Int) {
        if (capturing) {
            postResult(result) { success(false) }
            return
        }
        if (!activityVisible || !hasMicPermission() || captureRequestCancelled(requestId, generation)) {
            // Dart 侧已先请求过授权；这里复查兜底（34+ 的 while-in-use
            // 服务启动同样依赖它）。
            postResult(result) { success(false) }
            return
        }
        OmniCallForegroundService.stoppedListener = {
            notifyCaptureUnavailable("foreground service stopped by system")
        }
        if (!startForegroundService(requestId, generation)) {
            OmniCallForegroundService.stoppedListener = null
            postResult(result) { success(false) }
            return
        }
        val record = createRecord()
        if (record == null) {
            stopForegroundService()
            postResult(result) { success(false) }
            return
        }
        if (!attachCallObservers(record)) {
            releaseQuietly(record)
            stopForegroundService()
            postResult(result) { success(false) }
            return
        }
        if (captureRequestCancelled(requestId, generation) || !activityVisible) {
            detachCallObservers()
            releaseQuietly(record)
            stopForegroundService()
            postResult(result) { success(false) }
            return
        }
        attachAec(record)
        try {
            record.startRecording()
        } catch (_: Exception) {
            // startRecording 按文档会抛 IllegalStateException（设备被占用等）。
            detachCallObservers()
            releaseAecQuietly()
            releaseQuietly(record)
            stopForegroundService()
            postResult(result) { success(false) }
            return
        }
        capturing = true
        activeCaptureRequest = requestId
        muted = false
        captureInterrupted = false
        captureThread = Thread { captureLoop(record) }.also { it.start() }
        if (captureRequestCancelled(requestId, generation)) {
            stopCallResources()
            postResult(result) { success(false) }
        } else {
            postResult(result) { success(true) }
        }
    }

    /** 停采（executor 串行）：置停标志等线程退出（释放归线程 finally），
     *  摘观察者与回声消除、清播放流、停前台服务。幂等。 */
    private fun stopCapture(result: MethodChannel.Result, requestId: Int?) {
        if (requestId == null || activeCaptureRequest == requestId) stopCallResources()
        postResult(result) { success(null) }
    }

    /** 整通原生资源收口（停采 + 停流 + 停服务）。 */
    private fun stopCallResources() {
        capturing = false
        activeCaptureRequest = -1
        captureInterrupted = true
        val thread = captureThread
        try {
            thread?.join(2000)
        } catch (_: InterruptedException) {
            // 等待被打断也照常收尾；释放归采集线程自己的 finally。
        }
        if (captureThread === thread) captureThread = null
        detachCallObservers()
        releaseAecQuietly()
        interruptAllStreams()
        stopForegroundService()
    }

    private fun createRecord(): AudioRecord? {
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, ENCODING)
        if (minBuffer <= 0) {
            return null
        }
        val record = try {
            AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(ENCODING)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(CHANNEL_CONFIG)
                        .build(),
                )
                .setBufferSizeInBytes(minBuffer * 4)
                .build()
        } catch (_: Exception) {
            return null
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            releaseQuietly(record)
            return null
        }
        return record
    }

    /** 设备可用时挂回声消除（不写自制 DSP，spec:82）。尽力而为。 */
    private fun attachAec(record: AudioRecord) {
        if (!AcousticEchoCanceler.isAvailable()) {
            return
        }
        try {
            aec = AcousticEchoCanceler.create(record.audioSessionId)?.also { it.enabled = true }
        } catch (_: Exception) {
            aec = null
        }
    }

    private fun releaseAecQuietly() {
        try {
            aec?.release()
        } catch (_: Exception) {
            // 释放失败没有可补救动作。
        }
        aec = null
    }

    /**
     * 通话级焦点与观察者（executor 线程安装）：
     * - 焦点：整通持有 AUDIOFOCUS_GAIN，属性用通信类用法
     *   （USAGE_VOICE_COMMUNICATION，T05:11「标准通信音源与焦点」）——
     *   其他媒体应用据此把我们当通话让路；负向变化只停当前播放流（不
     *   打断采集与通话），AUDIOFOCUS_LOSS 额外上报 unavailable。
     * - 播放轨的属性仍是 USAGE_MEDIA（见 openStream）：已验证的扬声器
     *   路由与音量链路；两处属性分工是真机验证点（扬声器回声/耳机），
     *   若真机出现路由或回声异常，切通信用法是既定候选。
     * - 输入设备被移除：上报 unavailable（麦克风没了，通话如实结束）。
     * - 录音被系统静音（API 30+，系统麦克风开关/op 级静音等进程不死的
     *   场景）：上报 unavailable。权限撤销本身由采集线程的周期复查兜住
     *   （全版本，见 [captureLoop]——30- 的撤销收口方式无官方明文）。
     */
    private fun attachCallObservers(record: AudioRecord): Boolean {
        val host = activity ?: return false
        val manager = host.getSystemService(AudioManager::class.java) ?: return false
        var observing = true
        val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
            if (!observing || change >= 0) {
                return@OnAudioFocusChangeListener
            }
            callFocusHeld = false
            interruptAllStreams()
            if (change == AudioManager.AUDIOFOCUS_LOSS) {
                notifyCaptureUnavailable("audio focus lost permanently")
            }
        }
        val focusAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val focus = if (Build.VERSION.SDK_INT >= 26) {
            AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(focusAttributes)
                .setOnAudioFocusChangeListener(focusListener, mainHandler)
                .build()
        } else {
            null
        }
        val granted = if (focus != null) {
            manager.requestAudioFocus(focus)
        } else {
            @Suppress("DEPRECATION")
            manager.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        }
        if (granted != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            return false
        }
        callFocusHeld = true
        val devices = object : AudioDeviceCallback() {
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                if (!observing) {
                    return
                }
                if (removedDevices.any { it.isSource }) {
                    notifyCaptureUnavailable("microphone device removed")
                } else if (removedDevices.any { it.isSink }) {
                    // 耳机拔出等输出迁移：停当前播放流，通话继续（下一轮
                    // 回复照常开流）。
                    interruptAllStreams()
                }
            }
        }
        manager.registerAudioDeviceCallback(devices, mainHandler)
        val recordingCallback = object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
                if (observing && Build.VERSION.SDK_INT >= 30 && configs.any {
                        it.clientAudioSessionId == record.audioSessionId && it.isClientSilenced
                    }
                ) {
                    notifyCaptureUnavailable("microphone silenced by system")
                }
            }
        }
        manager.registerAudioRecordingCallback(recordingCallback, mainHandler)
        releaseCallObservers = {
            observing = false
            manager.unregisterAudioDeviceCallback(devices)
            manager.unregisterAudioRecordingCallback(recordingCallback)
            if (focus != null) {
                manager.abandonAudioFocusRequest(focus)
            } else {
                @Suppress("DEPRECATION")
                manager.abandonAudioFocus(focusListener)
            }
        }
        return true
    }

    private fun detachCallObservers() {
        callFocusHeld = false
        releaseCallObservers?.invoke()
        releaseCallObservers = null
    }

    /**
     * 采集线程：非阻塞读（取消不依赖设备继续产出，同 VoiceBridge 教训），
     * 攒满一块（约 100ms）出桥；闭麦照读不外发，恢复时无旧数据残留。
     * 音频只在内存流转，块出桥即交，永不落盘。
     */
    private fun captureLoop(record: AudioRecord) {
        val scratch = ByteArray(CHUNK_BYTES)
        val chunk = ByteArray(CHUNK_BYTES)
        var buffered = 0
        var failed = false
        // 周期复查麦克风授权（全版本，理由见常量注释）：撤销即如实上报
        // 并退出采集，收口仍由 Dart 的 stopCapture 统一执行。
        var nextPermissionRecheck =
            SystemClock.elapsedRealtime() + PERMISSION_RECHECK_INTERVAL_MS
        try {
            while (!captureInterrupted) {
                val now = SystemClock.elapsedRealtime()
                if (now >= nextPermissionRecheck) {
                    nextPermissionRecheck = now + PERMISSION_RECHECK_INTERVAL_MS
                    // activity 已摘除时按已授权处理：unregister 会置
                    // captureInterrupted，循环马上退出，不得误报。
                    val granted = activity
                        ?.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                        ?: PackageManager.PERMISSION_GRANTED
                    if (granted != PackageManager.PERMISSION_GRANTED) {
                        notifyCaptureUnavailable("microphone permission revoked")
                        break
                    }
                }
                val read = try {
                    record.read(scratch, 0, scratch.size, AudioRecord.READ_NON_BLOCKING)
                } catch (_: Exception) {
                    failed = true
                    break
                }
                if (read < 0) {
                    failed = true
                    break
                }
                if (read == 0) {
                    Thread.sleep(10)
                    continue
                }
                var offset = 0
                while (offset < read && !captureInterrupted) {
                    val take = minOf(read - offset, CHUNK_BYTES - buffered)
                    System.arraycopy(scratch, offset, chunk, buffered, take)
                    buffered += take
                    offset += take
                    if (buffered == CHUNK_BYTES) {
                        if (!muted) {
                            val bytes = chunk.copyOf()
                            mainHandler.post {
                                channel?.invokeMethod("onCaptureChunk", bytes)
                            }
                        }
                        buffered = 0
                    }
                }
            }
        } catch (_: InterruptedException) {
            // 退出信号：按正常收尾。
        } finally {
            try {
                record.stop()
            } catch (_: Exception) {
                // 从未成功起录时 stop 会抛，按无数据收尾。
            }
            releaseQuietly(record)
            if (failed && !captureInterrupted) {
                notifyCaptureUnavailable("audio record failed")
            }
        }
    }

    private fun captureRequestCancelled(requestId: Int, generation: Int): Boolean =
        generation != bridgeGeneration.get() || requestId <= cancelledCaptureRequest.get()

    private fun startForegroundService(requestId: Int, generation: Int): Boolean {
        // 主线程检查与 onPause 串行；不能把早先 permissionGranted 当成
        // while-in-use FGS 的后台启动许可。
        val done = CountDownLatch(1)
        var started = false
        mainHandler.post {
            try {
                val context = appContext
                if (context != null && activityVisible && hasMicPermission() &&
                    !captureRequestCancelled(requestId, generation)
                ) {
                    if (Build.VERSION.SDK_INT >= 26) {
                        context.startForegroundService(OmniCallForegroundService.intent(context))
                    } else {
                        context.startService(OmniCallForegroundService.intent(context))
                    }
                    started = true
                }
            } catch (_: Exception) {
                // 系统拒绝时如实回手动入口。
            } finally {
                done.countDown()
            }
        }
        done.await()
        return started
    }

    private fun stopForegroundService() {
        // 先摘「预期外停止」监听再停服务：我们自己发起的停止不得触发
        // 上报（也防服务销毁晚于下一次起采的误报）。
        OmniCallForegroundService.stoppedListener = null
        val context = appContext ?: return
        try {
            context.stopService(OmniCallForegroundService.intent(context))
        } catch (_: Exception) {
            // 服务不在即是已停，幂等。
        }
    }

    // ------------------------------------------------------------------
    // 播放流（通话下行，AudioTrack MODE_STREAM）
    // ------------------------------------------------------------------

    private fun prepareForAutoPlayback(): Boolean {
        if (!capturing || captureInterrupted || !callFocusHeld || !hasMicPermission()) return false
        // 走实际播放链路，不向模型发帧、不播放占位声音。短静音 PCM 验证
        // 24kHz MODE_STREAM 轨的启动与写入；句柄只归本次探测，立即释放。
        val id = openStream(24000, 0.0) ?: return false
        return try {
            val track = streams[id] ?: return false
            val silence = ByteArray(480)
            track.playState == AudioTrack.PLAYSTATE_PLAYING &&
                track.write(silence, 0, silence.size, AudioTrack.WRITE_NON_BLOCKING) == silence.size &&
                capturing && !captureInterrupted && callFocusHeld && hasMicPermission()
        } catch (_: Exception) {
            false
        } finally {
            releaseStream(id)
        }
    }

    private fun startStream(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val sampleRate = (args?.get("sampleRate") as? Number)?.toInt()
        val volume = (args?.get("volume") as? Number)?.toDouble() ?: 1.0
        if (sampleRate == null || sampleRate <= 0) {
            postResult(result) { success(null) }
            return
        }
        val id = openStream(sampleRate, volume)
        postResult(result) { success(id) }
    }

    /** 起一路流式播放：焦点已由整通持有，这里不再单独请求（同时录放的
     *  前提——若失败如实返回 null，文字照常）。轨属性用 USAGE_MEDIA：
     *  与朗读链路同一扬声器路由与音量行为（真机验证点，见
     *  attachCallObservers 的属性分工注释）。 */
    private fun openStream(sampleRate: Int, volume: Double): Int? {
        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) {
            return null
        }
        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(maxOf(minBuffer * 4, 8192))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } catch (_: Exception) {
            return null
        }
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            releaseQuietly(track)
            return null
        }
        val id = nextStreamId.getAndIncrement()
        streams[id] = track
        streamQueues[id] = java.util.concurrent.LinkedBlockingQueue()
        streamEnded[id] = false
        streamStopped[id] = false
        streamInterrupted[id] = false
        try {
            track.setVolume(volume.toFloat().coerceIn(0.0f, 1.0f))
            track.play()
        } catch (_: Exception) {
            releaseTrackQuietly(id)
            return null
        }
        val writer = Thread {
            val queue = streamQueues[id] ?: return@Thread
            var explicit = false
            var failed = false
            try {
                while (true) {
                    if (streamStopped[id] == true) {
                        explicit = true
                        break
                    }
                    if (streamInterrupted[id] == true) {
                        break
                    }
                    // 轮询而非无限阻塞：旗标置位后最迟 40ms 收口。
                    val chunk = queue.poll(40, TimeUnit.MILLISECONDS)
                    if (chunk != null) {
                        var offset = 0
                        while (offset < chunk.size) {
                            if (streamStopped[id] == true) {
                                explicit = true
                                break
                            }
                            if (streamInterrupted[id] == true) {
                                break
                            }
                            // 轨道被底下停掉（焦点打断收口）时不再写。
                            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
                                failed = true
                                break
                            }
                            val written = track.write(
                                chunk,
                                offset,
                                chunk.size - offset,
                                AudioTrack.WRITE_BLOCKING,
                            )
                            if (written < 0) {
                                failed = true
                                break
                            }
                            offset += written
                        }
                        if (explicit || failed || streamInterrupted[id] == true) {
                            break
                        }
                    }
                    // endStream 后队列排空即自然播完。
                    if (streamEnded[id] == true && queue.isEmpty()) {
                        break
                    }
                }
            } catch (_: InterruptedException) {
                // 唤醒性中断：按发起方旗标判定——焦点打断要通知，显式
                // 停止不通知（Dart 侧本地完成 done）。
                if (streamInterrupted[id] != true) {
                    explicit = true
                }
            } catch (_: Exception) {
                failed = true
            }
            // 句柄由 writer 自己释放：write 阻塞中的 AudioTrack 不能被
            // 别的线程 release（use-after-release，行为未定义）。
            releaseTrackQuietly(id)
            if (explicit) {
                return@Thread
            }
            mainHandler.post {
                channel?.invokeMethod("onPlaybackFinished", mapOf("id" to id))
            }
        }
        streamWriters[id] = writer
        writer.start()
        return id
    }

    private fun appendStreamChunk(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val id = args?.get("id") as? Int
        val bytes = args?.get("bytes") as? ByteArray
        val queue = id?.let { streamQueues[it] }
        if (id == null || bytes == null || bytes.isEmpty() || queue == null) {
            result.success(null)
            return
        }
        queue.put(bytes)
        result.success(null)
    }

    /** Dart 显式停止：只发信号，摘队列；writer 出口自释放且不通知。 */
    private fun releaseStream(id: Int) {
        streamQueues.remove(id)
        streamEnded.remove(id)
        streamStopped[id] = true
        streamWriters[id]?.interrupt()
    }

    /** 原生侧收口（焦点打断/整通收尾）：writer 出口照常通知，Dart 侧的
     *  播放会话据此完成 done，下一路回复才能开流。 */
    private fun interruptAllStreams() {
        for (id in streams.keys.toList()) {
            streamQueues.remove(id)
            streamEnded.remove(id)
            streamInterrupted[id] = true
            streamWriters[id]?.interrupt()
        }
    }

    /** writer 出口的自释放：幂等，清五张表并停轨。 */
    private fun releaseTrackQuietly(id: Int) {
        streamWriters.remove(id)
        streams.remove(id)?.let { releaseQuietly(it) }
        streamQueues.remove(id)
        streamEnded.remove(id)
        streamStopped.remove(id)
        streamInterrupted.remove(id)
    }

    // ------------------------------------------------------------------
    // 小件
    // ------------------------------------------------------------------

    /** Result 只能在主线程回话：executor 上下文一律经此回主线程。 */
    private inline fun postResult(result: MethodChannel.Result, crossinline reply: MethodChannel.Result.() -> Unit) {
        mainHandler.post { result.reply() }
    }

    private fun notifyCaptureUnavailable(reason: String) {
        mainHandler.post {
            channel?.invokeMethod("onCaptureUnavailable", mapOf("reason" to reason))
        }
    }

    private fun releaseQuietly(record: AudioRecord?) {
        try {
            record?.release()
        } catch (_: Exception) {
            // 释放失败没有可补救动作，静默。
        }
    }

    private fun releaseQuietly(track: AudioTrack?) {
        try {
            track?.stop()
        } catch (_: Exception) {
            // 未起播或已停的 track stop 会抛，release 照常执行。
        }
        try {
            track?.release()
        } catch (_: Exception) {
            // 释放失败没有可补救动作，静默。
        }
    }
}

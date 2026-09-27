package dev.qiyu.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaDataSource
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Handler
import android.os.Build
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

private const val VOICE_RECORDER_CHANNEL = "dev.qiyu.app/voice_recorder"
private const val VOICE_PLAYER_CHANNEL = "dev.qiyu.app/voice_player"
internal const val MIC_PERMISSION_REQUEST_CODE = 7061

/**
 * 语音链路的原生桥（票 06）：录音与朗读两个平台缝的 Android 侧。
 *
 * 录音：AudioRecord 直接按豆包契约采样（16kHz、16-bit、单声道 PCM），
 * 字节只进内存 ByteArrayOutputStream，stopRecording 时经通道回传 Dart
 * 由 Dart 侧打包 RIFF/WAV 头（与 web 实现的打包产物逐字节同构）——
 * 原生侧不落盘、不转格式、不写日志。
 *
 * 播放：整段走 Host 经 /api/chat/speak 返回的完整音频字节 + MediaPlayer
 * 的内存 MediaDataSource（不写临时文件）；流式走 AudioTrack MODE_STREAM
 * 逐块写 PCM（票二，startStream/appendStreamChunk/endStream，块经通道
 * 进原生写队列，音频只在内存）。音量实时可调；完成与出错都以
 * onPlaybackFinished 通知 Dart（显式停止不通知，Dart 侧本地完成 done）。
 *
 * 麦克风权限：requestMicrophonePermission 在已授权时立即成功，否则
 * 发起系统权限弹窗（仅由用户点麦克风的动作触发，拒绝后不重复骚扰），
 * 结果经 onRequestPermissionsResult 原路回传。
 */
internal object VoiceBridge {
    // 契约采样率与帧格式：与 Dart 侧 voice_recorder_platform.dart 的
    // wav16kMonoTargetSampleRate 同源同值（跨语言，改动必须两端同步）。
    private const val SAMPLE_RATE = 16000
    private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
    private const val ENCODING = AudioFormat.ENCODING_PCM_16BIT
    // 非阻塞读取，空缓冲只短暂让出线程；取消不依赖音频设备继续产出数据。
    private const val CHUNK_BYTES = 2048

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    /** 权限请求需要 Activity；注册即挂入，Activity 销毁时由 [unregister] 摘除。 */
    @Volatile
    private var activity: MainActivity? = null

    // ---- 录音状态（单会话：控制器同时至多持有一个会话） ----
    private val pendingPermissionResult = AtomicReference<MethodChannel.Result?>(null)

    @Volatile
    private var recording = false

    @Volatile
    private var captureThread: Thread? = null

    @Volatile
    private var pcmBuffer: ByteArrayOutputStream? = null
    private var recorderChannel: MethodChannel? = null
    private var releaseCaptureObservers: (() -> Unit)? = null
    private var releaseInputDevices: (() -> Unit)? = null
    private var inputPrepared = false
    private var captureInterrupted = false
    private var foreground = false

    // ---- 播放状态（合成前建立输出会话，准备与播放均由主线程收尾） ----
    private val nextPlaybackId = AtomicInteger(1)
    private val players = ConcurrentHashMap<Int, MediaPlayer>()
    private var playbackChannel: MethodChannel? = null
    private var outputSession: Int? = null
    private val pendingPlayers = mutableMapOf<Int, MethodChannel.Result>()
    private var releaseOutputObservers: (() -> Unit)? = null

    // ---- 流式 PCM 播放（票二）：AudioTrack MODE_STREAM，块经通道写
    // 进原生写队列，音频只在内存、不落盘。句柄表与整段 MediaPlayer
    // 分开（onPlaybackFinished 同一分发口）。 ----
    private val streams = ConcurrentHashMap<Int, AudioTrack>()
    private val streamQueues = ConcurrentHashMap<Int, java.util.concurrent.LinkedBlockingQueue<ByteArray>>()
    private val streamEnded = ConcurrentHashMap<Int, Boolean>()
    private val streamStopped = ConcurrentHashMap<Int, Boolean>()
    private val streamWriters = ConcurrentHashMap<Int, Thread>()

    /** 合成前取得焦点并观察路由；没有延迟授权或自动恢复。 */
    @Suppress("DEPRECATION")
    private fun prepareOutput(session: Int): Boolean {
        endOutput()
        if (!foreground || inputPrepared || captureThread != null) return false
        val host = activity ?: return false
        val manager = host.getSystemService(AudioManager::class.java)
        outputSession = session
        var observing = true
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            if (observing && outputSession == session && change < 0) interruptOutput()
        }
        val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
        val focus = if (Build.VERSION.SDK_INT >= 26) {
            AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes).setWillPauseWhenDucked(true)
                .setOnAudioFocusChangeListener(listener, mainHandler).build()
        } else null
        val granted = if (focus != null) manager.requestAudioFocus(focus)
            else manager.requestAudioFocus(listener, AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        if (granted != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            outputSession = null
            return false
        }
        val devices = object : AudioDeviceCallback() {
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                if (observing && removedDevices.any { it.isSink }) interruptOutput()
            }
        }
        val noisy = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (observing && intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    interruptOutput()
                }
            }
        }
        manager.registerAudioDeviceCallback(devices, mainHandler)
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= 33) host.registerReceiver(noisy, filter, Context.RECEIVER_NOT_EXPORTED)
        else host.registerReceiver(noisy, filter)
        releaseOutputObservers = {
            observing = false
            manager.unregisterAudioDeviceCallback(devices)
            host.unregisterReceiver(noisy)
            if (focus != null) manager.abandonAudioFocusRequest(focus)
            else manager.abandonAudioFocus(listener)
        }
        return true
    }

    private fun endOutput() {
        outputSession = null
        releaseOutputObservers?.invoke()
        releaseOutputObservers = null
        for (id in players.keys.toList()) {
            players.remove(id)?.let { releaseQuietly(it) }
            pendingPlayers.remove(id)?.success(null)
        }
        for (id in streams.keys.toList()) {
            releaseStream(id)
        }
    }

    private fun interruptOutput() {
        val session = outputSession
        endOutput()
        if (session != null) {
            playbackChannel?.invokeMethod("onOutputInterrupted", mapOf("sessionId" to session))
        }
    }

    fun register(messenger: BinaryMessenger, hostActivity: MainActivity) {
        activity = hostActivity
        playbackChannel = MethodChannel(messenger, VOICE_PLAYER_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result -> handlePlayerCall(call, result) }
        }
        recorderChannel = MethodChannel(messenger, VOICE_RECORDER_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result -> handleRecorderCall(call, result) }
        }
    }

    fun onRequestPermissionsResult(granted: Boolean) {
        pendingPermissionResult.getAndSet(null)?.success(granted)
    }

    /**
     * Activity 销毁时摘挂：界面已经不在了，不能再占着麦克风（系统录音指示点
     * 不该还亮着）。这里只请采集线程停手——AudioRecord 的 stop/release 归它
     * 自己的 finally（见 startCapture），并发释放会 use-after-free；不置空
     * recording 的话线程会继续 read 并把字节灌进无人认领的缓冲。
     * 顺手把仍在等待回包的权限请求按失败收尾，不留一个永不 resolve 的 Result；
     * 播放句柄同样清空——界面没了之后 Dart 再也发不来 stopPlayback，留着就是
     * 幽灵朗读（释放归本表，与 finishPlayback 同一去处）。
     */
    fun unregister() {
        foreground = false
        interruptRecording()
        pendingPermissionResult.getAndSet(null)?.error(
            "ACTIVITY_DESTROYED",
            "界面已销毁，权限请求已取消。",
            null,
        )
        interruptOutput()
        activity = null
    }

    fun onForegroundChanged(value: Boolean) {
        foreground = value
        if (!value) {
            interruptRecording()
            interruptOutput()
        }
    }

    /** 作废准备或采集；焦点恢复或 Activity 恢复不启动任何录音。 */
    fun interruptRecording() {
        if ((!inputPrepared && captureThread == null) || captureInterrupted) return
        captureInterrupted = true
        finishInputPreparation()
        recording = false
        pcmBuffer = null
        releaseCaptureObservers?.invoke()
        releaseCaptureObservers = null
        recorderChannel?.invokeMethod("onRecordingInterrupted", null)
        val thread = captureThread ?: return
        executor.execute {
            thread?.join()
            mainHandler.post {
                if (captureThread === thread) captureThread = null
            }
        }
    }

    /** 权限查询之前就观察输入设备，不占用麦克风或音频焦点。 */
    private fun prepareRecording(): Boolean {
        if (!foreground || captureThread != null) return false
        finishInputPreparation()
        val manager = activity?.getSystemService(AudioManager::class.java) ?: return false
        inputPrepared = true
        captureInterrupted = false
        var observing = true
        val devices = object : AudioDeviceCallback() {
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                if (observing && removedDevices.any { it.isSource }) interruptRecording()
            }
        }
        manager.registerAudioDeviceCallback(devices, mainHandler)
        releaseInputDevices = {
            observing = false
            manager.unregisterAudioDeviceCallback(devices)
        }
        return true
    }

    private fun finishInputPreparation() {
        inputPrepared = false
        releaseInputDevices?.invoke()
        releaseInputDevices = null
    }

    @Suppress("DEPRECATION")
    private fun observeCapture(record: AudioRecord): Boolean {
        val manager = activity?.getSystemService(AudioManager::class.java) ?: return false
        var observing = true
        val sessionId = record.audioSessionId
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            if (observing && change < 0) interruptRecording()
        }
        val focus = if (Build.VERSION.SDK_INT >= 26) {
            AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setOnAudioFocusChangeListener(listener, mainHandler)
                .build()
        } else null
        val granted = if (focus != null) manager.requestAudioFocus(focus)
            else manager.requestAudioFocus(listener, AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
        if (granted != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) return false
        val configurations = object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
                if (observing && Build.VERSION.SDK_INT >= 29 && configs.any {
                        it.clientAudioSessionId == sessionId && it.isClientSilenced
                    }) interruptRecording()
            }
        }
        manager.registerAudioRecordingCallback(configurations, mainHandler)
        releaseCaptureObservers = {
            observing = false
            manager.unregisterAudioRecordingCallback(configurations)
            if (focus != null) manager.abandonAudioFocusRequest(focus)
            else manager.abandonAudioFocus(listener)
        }
        return true
    }

    private fun handleRecorderCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareRecording" -> {
                if (prepareRecording()) result.success(null)
                else result.error("INPUT_UNAVAILABLE", "当前无法准备麦克风。", null)
            }
            "hasMicrophonePermission" -> result.success(
                activity?.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                    PackageManager.PERMISSION_GRANTED,
            )
            "requestMicrophonePermission" -> {
                val host = activity
                if (host == null) {
                    result.success(false)
                    return
                }
                if (host.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                    PackageManager.PERMISSION_GRANTED
                ) {
                    result.success(true)
                    return
                }
                // 并发的第二次请求按失败回：弹窗节奏由用户点击驱动，串行足够。
                if (!pendingPermissionResult.compareAndSet(null, result)) {
                    result.error("BUSY", "已有权限请求在等待结果。", null)
                    return
                }
                host.requestPermissions(
                    arrayOf(Manifest.permission.RECORD_AUDIO),
                    MIC_PERMISSION_REQUEST_CODE,
                )
            }
            "startRecording" -> {
                val host = activity
                val granted = host?.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                    PackageManager.PERMISSION_GRANTED
                result.success(foreground && inputPrepared && !captureInterrupted && granted && startCapture())
            }
            "stopRecording" -> stopCapture(returnBytes = true, result)
            "discardRecording" -> stopCapture(returnBytes = false, result)
            else -> result.notImplemented()
        }
    }

    /** 前置检查已过权限（startRecording 分支）；此处的 Suppress 只覆盖
     *  构造器 lint，权限缺失时本函数不会被调用。 */
    @SuppressLint("MissingPermission")
    private fun startCapture(): Boolean {
        if (recording || captureThread != null) {
            return false
        }
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, ENCODING)
        if (minBuffer <= 0) {
            return false
        }
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                CHANNEL_CONFIG,
                ENCODING,
                minBuffer * 4,
            )
        } catch (_: Exception) {
            return false
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            releaseQuietly(record)
            return false
        }
        if (!observeCapture(record)) {
            releaseQuietly(record)
            return false
        }
        val out = ByteArrayOutputStream()
        pcmBuffer = out
        captureInterrupted = false
        recording = true
        try {
            record.startRecording()
        } catch (_: Exception) {
            // startRecording 按文档会抛 IllegalStateException（设备被占用等）。
            // 采集线程此刻还没起，收尾没有别人，只能本函数就地释放并复位——
            // 留着 recording=true 会让之后每次点麦克风都被开头那道门挡死。
            releaseQuietly(record)
            recording = false
            pcmBuffer = null
            releaseCaptureObservers?.invoke()
            releaseCaptureObservers = null
            return false
        }
        // AudioRecord 的收尾归采集线程自己：只有停手不再 read 的人才有资格
        // stop()/release()。stopCapture 那边并发释放一个仍阻塞在 read 上的
        // record 是原生层崩溃隐患（见 stopCapture）。
        captureThread = Thread {
            val chunk = ByteArray(CHUNK_BYTES)
            var failed = false
            try {
                while (recording) {
                    val read = try {
                        record.read(chunk, 0, chunk.size, AudioRecord.READ_NON_BLOCKING)
                    } catch (_: Exception) {
                        failed = true
                        break
                    }
                    if (read < 0) {
                        failed = true
                        break
                    }
                    if (read == 0) Thread.sleep(10)
                    else if (recording) out.write(chunk, 0, read)
                }
            } finally {
                try {
                    record.stop()
                } catch (_: Exception) {
                    // 从未成功起录时 stop 会抛，按无数据收尾。
                }
                releaseQuietly(record)
                if (failed) {
                    // 同步到主线程再通知，旧线程不得取消后来的一次录音。
                    val failedThread = Thread.currentThread()
                    mainHandler.post {
                        if (captureThread === failedThread) interruptRecording()
                    }
                }
            }
        }.also { it.start() }
        return true
    }

    /**
     * 请非阻塞采集线程停手，等待释放完成再回话。
     * 不碰 AudioRecord——它的 stop/release 归采集线程（见 startCapture），
     * 停止期间拒绝新起录；音频错误或中断优先于正常收尾，不回传半段字节。
     */
    private fun stopCapture(returnBytes: Boolean, result: MethodChannel.Result) {
        recording = false
        finishInputPreparation()
        val thread = captureThread
        val out = pcmBuffer
        pcmBuffer = null
        releaseCaptureObservers?.invoke()
        releaseCaptureObservers = null
        executor.execute {
            try {
                thread?.join()
            } catch (_: InterruptedException) {
                // 等待被打断也照常收尾：按已采集到的字节返回。
            }
            mainHandler.post {
                if (captureThread === thread) captureThread = null
                val bytes = if (returnBytes && !captureInterrupted)
                    out?.toByteArray() ?: ByteArray(0) else ByteArray(0)
                result.success(bytes)
            }
        }
    }

    private fun handlePlayerCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareOutput" -> {
                val session = (call.arguments as? Map<*, *>)?.get("sessionId") as? Int
                result.success(session != null && prepareOutput(session))
            }
            "endOutput" -> {
                val session = (call.arguments as? Map<*, *>)?.get("sessionId") as? Int
                if (session == outputSession) endOutput()
                result.success(null)
            }
            "startPlayback" -> {
                val args = call.arguments as? Map<*, *>
                val bytes = args?.get("bytes") as? ByteArray
                val volume = (args?.get("volume") as? Number)?.toDouble() ?: 1.0
                val session = args?.get("sessionId") as? Int
                if (bytes == null || bytes.isEmpty() || session == null ||
                    session != outputSession || !foreground) {
                    result.success(null)
                    return
                }
                startPlayback(bytes, volume, session, result)
            }
            "stopPlayback" -> {
                val id = (call.arguments as? Map<*, *>)?.get("id") as? Int
                if (id != null) {
                    players.remove(id)?.let { releaseQuietly(it) }
                    pendingPlayers.remove(id)?.success(null)
                    // 旗标表只服务流式会话：整段 MediaPlayer 的 id 没有
                    // writer 出口清表，写进去就是永远残留的条目——按
                    // streams 里有没有句柄决定发不发停止信号。
                    if (streams.containsKey(id)) releaseStream(id)
                }
                result.success(null)
            }
            "setPlaybackVolume" -> {
                val args = call.arguments as? Map<*, *>
                val id = args?.get("id") as? Int
                val volume = (args?.get("volume") as? Number)?.toDouble() ?: 1.0
                val clamped = volume.toFloat().coerceIn(0.0f, 1.0f)
                players[id]?.setVolume(clamped, clamped)
                // AudioTrack.setVolume 只有单声道路：流式 PCM 是单声道，
                // 左右同一值没有第二个入口。
                streams[id]?.setVolume(clamped)
                result.success(null)
            }
            "startStream" -> {
                val args = call.arguments as? Map<*, *>
                val sampleRate = (args?.get("sampleRate") as? Number)?.toInt()
                val volume = (args?.get("volume") as? Number)?.toDouble() ?: 1.0
                val session = args?.get("sessionId") as? Int
                if (sampleRate == null || sampleRate <= 0 || session == null ||
                    session != outputSession || !foreground) {
                    result.success(null)
                    return
                }
                startStream(sampleRate, volume, session, result)
            }
            "appendStreamChunk" -> {
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
            "endStream" -> {
                val id = (call.arguments as? Map<*, *>)?.get("id") as? Int
                // 同 stopPlayback：只有流式会话有旗标表条目，整段
                // MediaPlayer 的 id 写进去也没有 writer 出口清表。
                if (id != null && streams.containsKey(id)) streamEnded[id] = true
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * 流式 PCM 播放（票二）：AudioTrack MODE_STREAM 按协商采样率起播，
     * 写线程把队列里的块连续 write；endStream 后队列排空即自然结束
     * （onPlaybackFinished 通知 Dart）。音频只在内存，不落盘。
     */
    private fun startStream(sampleRate: Int, volume: Double, session: Int,
                            result: MethodChannel.Result) {
        val id = nextPlaybackId.getAndIncrement()
        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) {
            result.success(null)
            return
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
            result.success(null)
            return
        }
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            releaseQuietly(track)
            result.success(null)
            return
        }
        streams[id] = track
        streamQueues[id] = java.util.concurrent.LinkedBlockingQueue()
        streamEnded[id] = false
        streamStopped[id] = false
        val clamped = volume.toFloat().coerceIn(0.0f, 1.0f)
        // 单声道流式轨：setVolume 只收一个增益值（MediaPlayer 的双声道
        // 重载不适用于 AudioTrack）。
        track.setVolume(clamped)
        try {
            track.play()
        } catch (_: Exception) {
            releaseStream(id)
            result.success(null)
            return
        }
        val writer = Thread {
            val queue = streamQueues[id] ?: return@Thread
            var failed = false
            var stopped = false
            try {
                while (true) {
                    if (streamStopped[id] == true) {
                        stopped = true
                        break
                    }
                    // 轮询而非无限阻塞：endStream 只置旗标也能在超时内收尾
                    // （否则 writer 卡在 take 上，Dart 侧 done 永不完成）。
                    val chunk = queue.poll(40, java.util.concurrent.TimeUnit.MILLISECONDS)
                    if (chunk != null) {
                        var offset = 0
                        while (offset < chunk.size) {
                            if (streamStopped[id] == true) {
                                stopped = true
                                break
                            }
                            // 轨道被底下停掉（会话收尾/焦点丢失）时不再写。
                            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
                                failed = true
                                break
                            }
                            val written = track.write(
                                chunk, offset, chunk.size - offset,
                                AudioTrack.WRITE_BLOCKING,
                            )
                            if (written < 0) {
                                failed = true
                                break
                            }
                            offset += written
                        }
                        if (stopped || failed) break
                    }
                    // endStream 后队列排空即自然播完。
                    if (streamEnded[id] == true && queue.isEmpty()) break
                }
            } catch (_: InterruptedException) {
                // 停止信号：按正常收尾，不再通知完成。
                stopped = true
            } catch (_: Exception) {
                failed = true
            }
            // 句柄由 writer 自己释放：write 阻塞中的 AudioTrack 不能被
            // 别的线程 release（use-after-release，行为未定义）。
            releaseTrackQuietly(id)
            // 显式停止不通知（Dart 侧本地完成 done）；自然播完与底层
            // 出错都照常通知——与整段 MediaPlayer 路径同一语义。
            if (stopped) return@Thread
            mainHandler.post {
                playbackChannel?.invokeMethod("onPlaybackFinished", mapOf("id" to id))
            }
        }
        streamWriters[id] = writer
        writer.start()
        result.success(id)
    }

    /** 请求停止（停止键 / 会话收尾 / 焦点丢失）：只发信号，摘队列。
     *  真正 release 由 writer 自己出队后做——见 startStream 尾部注释。 */
    private fun releaseStream(id: Int) {
        streamQueues.remove(id)
        streamEnded.remove(id)
        streamStopped[id] = true
        streamWriters[id]?.interrupt() // 唤醒 poll，不解除 write 阻塞
    }

    /** writer 出口的自释放：幂等，清四张表并停轨。 */
    private fun releaseTrackQuietly(id: Int) {
        streamWriters.remove(id)
        streams.remove(id)?.let { releaseQuietly(it) }
        streamQueues.remove(id)
        streamEnded.remove(id)
        streamStopped.remove(id)
    }

    private fun startPlayback(bytes: ByteArray, volume: Double, session: Int,
                              result: MethodChannel.Result) {
        val id = nextPlaybackId.getAndIncrement()
        val player = MediaPlayer()
        players[id] = player
        pendingPlayers[id] = result
        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            player.setDataSource(
                object : MediaDataSource() {
                    override fun readAt(
                        position: Long,
                        buffer: ByteArray,
                        offset: Int,
                        size: Int,
                    ): Int {
                        if (position >= bytes.size) {
                            return -1
                        }
                        val count = minOf(size.toLong(), bytes.size - position).toInt()
                        System.arraycopy(bytes, position.toInt(), buffer, offset, count)
                        return count
                    }

                    override fun getSize(): Long = bytes.size.toLong()

                    override fun close() {}
                },
            )
            player.setOnPreparedListener {
                if (players[id] !== player || outputSession != session || !foreground) {
                    return@setOnPreparedListener
                }
                try {
                    val clamped = volume.toFloat().coerceIn(0.0f, 1.0f)
                    player.setVolume(clamped, clamped)
                    player.start()
                    pendingPlayers.remove(id)?.success(id)
                } catch (_: Exception) {
                    finishPlayback(id)
                }
            }
            player.setOnCompletionListener { finishPlayback(id) }
            player.setOnErrorListener { _, _, _ ->
                finishPlayback(id)
                true
            }
            player.prepareAsync()
        } catch (_: Exception) {
            finishPlayback(id)
        }
    }

    private fun finishPlayback(id: Int) {
        players.remove(id)?.let { releaseQuietly(it) }
        pendingPlayers.remove(id)?.success(null)
        mainHandler.post {
            playbackChannel?.invokeMethod("onPlaybackFinished", mapOf("id" to id))
        }
    }

    private fun releaseQuietly(record: AudioRecord?) {
        try {
            record?.release()
        } catch (_: Exception) {
            // 释放失败没有可补救动作，静默。
        }
    }

    private fun releaseQuietly(player: MediaPlayer?) {
        try {
            player?.stop()
        } catch (_: Exception) {
            // 未起播的 player stop 会抛，release 照常执行。
        }
        try {
            player?.release()
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

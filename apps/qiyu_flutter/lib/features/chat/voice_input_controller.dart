import 'dart:async';

import 'package:flutter/foundation.dart';

import '../baseline/host_api_gateway.dart';
import 'api_error_dialog.dart';
import 'voice_recorder_platform.dart';

/// 语音输入状态机的可见状态（spec：idle → recording → transcribing →
/// 成功回 idle / 失败进 retryable）。unsupported 与 notConfigured 是
/// 进入 idle 前的门槛状态：按钮置灰并引导，不参与转移。
enum VoiceInputStatus {
  unsupported,
  notConfigured,
  idle,
  recording,
  transcribing,
  retryable,
}

/// 语音服务状态探针的结果：是否已配置，以及是否需要浏览器端把录音
/// 转换成 WAV（豆包协议只吃 16kHz/16-bit 单声道 WAV；OpenAI 兼容协议
/// 原样上送 webm）。
typedef VoiceServiceStatus = ({bool configured, bool wantsWavAudio});

/// 聊天页语音输入控制器：录音只在内存里，成功、丢弃、页面离开即清空；
/// 失败进可重试态，点麦克风重传同一段音频，Esc 丢弃。
final class VoiceInputController extends ChangeNotifier {
  VoiceInputController(
    this._platform,
    this._serviceStatus,
    this._transcribe, {
    required this.onTranscribed,
    this.onApiError,
    this.autoStopAfter = const Duration(seconds: 60),
  });

  static const _tickInterval = Duration(seconds: 1);

  final VoiceRecorderPlatform _platform;
  final Future<VoiceServiceStatus> Function() _serviceStatus;
  final Future<String> Function(Uint8List audio, String mimeType) _transcribe;

  /// 转写成功：文本交回聊天页走既有发送链路（与手打完全一致）。
  final void Function(String text) onTranscribed;

  /// 转写遇到 429 或 40x 异常时的回调。
  final void Function(ApiErrorCategory category)? onApiError;

  /// 录音上限：到点自动收尾并照常转写，不丢用户的话。
  final Duration autoStopAfter;

  VoiceInputStatus _status = VoiceInputStatus.idle;
  String? _errorMessage;
  VoiceRecordingSession? _session;
  Uint8List? _pendingAudio;
  String _pendingMimeType = '';
  bool _pendingAudioIsWav = false;
  bool _wantsWavAudio = false;
  Timer? _autoStopTimer;
  Timer? _elapsedTimer;
  int _elapsedSeconds = 0;

  /// 转写尝试令牌：Esc 中止或丢弃后，迟到的转写结果一律作废。
  int _attempt = 0;
  bool _disposed = false;

  VoiceInputStatus get status => _status;
  String? get errorMessage => _errorMessage;
  int get elapsedSeconds => _elapsedSeconds;
  bool get hasRetainedAudio => _pendingAudio != null;

  /// 聊天页初始化时拉一次：浏览器不支持或未配置语音服务都如实置灰。
  Future<void> initialize() async {
    if (_disposed) {
      return;
    }
    if (!_platform.supported) {
      _status = VoiceInputStatus.unsupported;
      notifyListeners();
      return;
    }
    var status = (configured: false, wantsWavAudio: false);
    try {
      status = await _serviceStatus();
    } on Object {
      // 拉不到配置按未配置呈现：按钮置灰引导去设置页，不出错弹层。
    }
    if (_disposed) {
      return;
    }
    _wantsWavAudio = status.wantsWavAudio;
    _status = status.configured
        ? VoiceInputStatus.idle
        : VoiceInputStatus.notConfigured;
    notifyListeners();
  }

  /// 置灰态点击麦克风时惰性重查：从设置页配好语音服务返回后，不用
  /// 刷新页面就能直接开始说话。
  Future<void> refreshConfigured() async {
    if (_disposed ||
        !_platform.supported ||
        _status != VoiceInputStatus.notConfigured) {
      return;
    }
    VoiceServiceStatus status;
    try {
      status = await _serviceStatus();
    } on Object {
      return;
    }
    if (_disposed ||
        !status.configured ||
        _status != VoiceInputStatus.notConfigured) {
      return;
    }
    _wantsWavAudio = status.wantsWavAudio;
    _status = VoiceInputStatus.idle;
    _errorMessage = null;
    notifyListeners();
  }

  /// 麦克风按钮的唯一入口，按当前状态分派。
  void handleMicTap() {
    switch (_status) {
      case VoiceInputStatus.idle:
        unawaited(startRecording());
      case VoiceInputStatus.recording:
        unawaited(stopAndTranscribe());
      case VoiceInputStatus.retryable:
        unawaited(retryTranscribe());
      case VoiceInputStatus.unsupported:
      case VoiceInputStatus.notConfigured:
      case VoiceInputStatus.transcribing:
        break;
    }
  }

  Future<void> startRecording() async {
    if (_status != VoiceInputStatus.idle) {
      return;
    }
    _errorMessage = null;
    VoiceRecordingSession? session;
    try {
      session = await _platform.start();
    } on Object {
      session = null;
    }
    if (_disposed) {
      session?.discard();
      return;
    }
    if (session == null) {
      // 授权被拒或设备不可用：留在 idle，错误就近平铺在语音状态行。
      // 文案平台中性：web 是浏览器权限，安卓是系统麦克风权限。
      _errorMessage = '无法使用麦克风，请检查麦克风权限或设备状态。';
      notifyListeners();
      return;
    }
    _session = session;
    _status = VoiceInputStatus.recording;
    _elapsedSeconds = 0;
    _autoStopTimer = Timer(autoStopAfter, () {
      if (_status == VoiceInputStatus.recording && !_disposed) {
        unawaited(stopAndTranscribe());
      }
    });
    _elapsedTimer = Timer.periodic(_tickInterval, (_) {
      if (_status == VoiceInputStatus.recording && !_disposed) {
        _elapsedSeconds += 1;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  /// 再点一次麦克风：结束录音并立即转写。
  Future<void> stopAndTranscribe() async {
    final session = _session;
    if (_status != VoiceInputStatus.recording || session == null) {
      return;
    }
    // 停止录音前先登记本次转写令牌：session.stop() 等待期间用户按 Esc
    // 会递增 _attempt 作废它，返回后凭快照感知中止，绝不发起转写。
    final attempt = _registerAttempt();
    _cancelTimers();
    _session = null;
    _status = VoiceInputStatus.transcribing;
    _errorMessage = null;
    notifyListeners();
    Uint8List audio;
    try {
      audio = await session.stop();
    } on Object {
      if (_disposed || attempt != _attempt) {
        return;
      }
      _status = VoiceInputStatus.idle;
      _errorMessage = '录音结束失败，请重新说一次。';
      notifyListeners();
      return;
    }
    if (_disposed) {
      return;
    }
    if (attempt != _attempt) {
      // 等待停止期间被 Esc 中止：仅当中止后停在可重试态（第一次
      // Esc）才把音频留在内存供重试；若已按第二次 Esc 丢弃（回
      // idle），音频随之丢弃，不留任何字节。
      if (_status == VoiceInputStatus.retryable) {
        _retainPendingAudio(audio, session.mimeType);
      }
      return;
    }
    _retainPendingAudio(audio, session.mimeType);
    await _runTranscribe(attempt);
  }

  /// 可重试态点麦克风：不重录，重传内存里的同一段音频。
  Future<void> retryTranscribe() async {
    if (_status != VoiceInputStatus.retryable || _pendingAudio == null) {
      return;
    }
    final attempt = _registerAttempt();
    _status = VoiceInputStatus.transcribing;
    _errorMessage = null;
    notifyListeners();
    await _runTranscribe(attempt);
  }

  /// Esc 的语义随状态变化：录音中丢弃、转写中中止上传回可重试态、
  /// 可重试态丢弃。
  void handleEscape() {
    switch (_status) {
      case VoiceInputStatus.recording:
        discard();
      case VoiceInputStatus.transcribing:
        // 中止等待：底层 HTTP 若仍在途会自然完成，结果按令牌作废。
        _attempt += 1;
        _status = VoiceInputStatus.retryable;
        _errorMessage = '已停止转写，点麦克风重试，Esc 丢弃。';
        notifyListeners();
      case VoiceInputStatus.retryable:
        discard();
      case VoiceInputStatus.unsupported:
      case VoiceInputStatus.notConfigured:
      case VoiceInputStatus.idle:
        break;
    }
  }

  /// 丢弃录音回 idle，不留任何字节。
  void discard() {
    _cancelTimers();
    _session?.discard();
    _session = null;
    _attempt += 1;
    _clearPendingAudio();
    _status = VoiceInputStatus.idle;
    _errorMessage = null;
    notifyListeners();
  }

  /// 登记一次新的转写尝试令牌：Esc 中止与丢弃都会递增 [_attempt]，
  /// 令牌过期的转写绝不发起、结果也绝不采纳。
  int _registerAttempt() => _attempt += 1;

  /// 把「停止录音得到的音频」按待重传形态留在内存（豆包转换尚未发生，
  /// isWav 恒为 false；转换成功后的形态更新走 [_runTranscribe]）。
  void _retainPendingAudio(Uint8List audio, String mimeType) {
    _pendingAudio = audio;
    _pendingMimeType = mimeType;
    _pendingAudioIsWav = false;
  }

  /// 清空待发音频三元组，不留任何字节。
  void _clearPendingAudio() {
    _pendingAudio = null;
    _pendingMimeType = '';
    _pendingAudioIsWav = false;
  }

  Future<void> _runTranscribe(int attempt) async {
    if (_pendingAudio == null) {
      _status = VoiceInputStatus.retryable;
      _errorMessage = '录音已不可用，请重新说一次。';
      notifyListeners();
      return;
    }
    // 豆包协议只吃 16kHz/16-bit 单声道 WAV：转写前在浏览器转换一次，
    // 转换结果缓存为待重传形态（重试不再重复转换）。
    if (_wantsWavAudio && !_pendingAudioIsWav) {
      try {
        final converted = await _platform.toWav16kMono(
          RecordedAudio(bytes: _pendingAudio!, mimeType: _pendingMimeType),
        );
        if (_disposed || attempt != _attempt) {
          return;
        }
        _pendingAudio = converted.bytes;
        _pendingMimeType = converted.mimeType;
        _pendingAudioIsWav = true;
      } on Object {
        if (_disposed || attempt != _attempt) {
          return;
        }
        _enterRetryable('这段录音无法转换成语音服务需要的格式，请重试或重新说一次。');
        return;
      }
    }
    final audio = _pendingAudio!;
    final mimeType = _pendingMimeType;
    try {
      final text = (await _transcribe(audio, mimeType)).trim();
      if (_disposed || attempt != _attempt) {
        return;
      }
      if (text.isEmpty) {
        // 兜底：Host 已把空文本按失败返回，这里防御客户端侧空串。
        _enterRetryable('没有识别到语音，可以再说一次。');
        return;
      }
      _clearPendingAudio();
      _status = VoiceInputStatus.idle;
      _errorMessage = null;
      notifyListeners();
      onTranscribed(text);
    } on Object catch (error) {
      if (_disposed || attempt != _attempt) {
        return;
      }
      _enterRetryable(_readableError(error));
      final category = categorizeVoiceApiError(error, isInput: true);
      if (category != null) {
        onApiError?.call(category);
      }
    }
  }

  void _enterRetryable(String message) {
    _status = VoiceInputStatus.retryable;
    _errorMessage = message;
    notifyListeners();
  }

  void _cancelTimers() {
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    _session?.discard();
    _session = null;
    _clearPendingAudio();
    super.dispose();
  }
}

String _readableError(Object error) =>
    readableError(error, fallback: '转写没有成功，点麦克风重试，Esc 丢弃。');

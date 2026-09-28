import 'package:flutter/foundation.dart';

import '../baseline/host_stopped_gate.dart';

/// 纯 Dart 强类型双语词表抽象基类（Spec & ADR 0023）。
///
/// 零 flutter_localizations 与 .arb 外部依赖，编译期严格保障中英词条 1:1 对齐。
abstract class QiyuStrings {
  const QiyuStrings();

  /// 依据语言标识获取对应词表实例。
  static QiyuStrings of(String locale) =>
      locale == 'en' ? const QiyuStringsEn() : const QiyuStringsZh();

  // ── 侧边栏与连接状态 ──
  String get connectionNormal;
  String get connectionFailed;
  String get connectionProbing;

  // ── 双语切换控件 ──
  String get languageSwitchZh;
  String get languageSwitchEn;
  String get toggleLanguageSemantics;
  String get navigationHistory;
  String get navigationMemory;
  String get navigationSettings;
  String get expandSidebar;
  String get collapseSidebar;
  String get closeDrawer;
  String get openNavigation;
  String get back;
  String get greetingMorning;
  String get greetingNoon;
  String get greetingAfternoon;
  String get greetingEvening;
  String get composerHint;
  String get localFallback;
  String get modelConnection;
  String get checkSettings;
  String get preparingMicrophone;
  String recordingAndroid(String clock);
  String recordingWeb(String clock);
  String get transcribing;
  String get transcribingCancelable;
  String get transcriptionRetryHint;
  String get voicePreparingRead;
  String get voiceReading;
  String get stopReading;
  String get acknowledge;
  String get qiyuThinking;
  String get qiyuReplying;
  String get qiyuThinkingVisible;
  String get hostStoppedSituation;
  String get hostStoppedGuidance;
  String get switchToHoldToTalk;
  String get voiceInputUnavailable;
  String get voiceInput;
  String get finishAndTranscribe;
  String get transcribingButton;
  String get retryTranscription;
  String get switchToTextInput;
  String get voicePending;
  String get cancel;
  String get retry;
  String get recordAgain;
  String get discard;
  String get microphoneUnavailableAndroid;
  String get microphoneUnavailableWeb;
  String get voiceNotConfigured;
  String get goToSettings;
  String get send;
  String get stopReply;
  String get releaseToCancel;
  String get releaseToSend;
  String get holdToTalk;
  String get startRecording;
  String get finishRecording;
  String get cancelRecording;
  String get youSaid;
  String get qiyuSaid;
  String get incomplete;
  String get readingShort;
  String get replayMessage;
  String get copyMessage;
  String get voiceVolume;
  String get voiceDisabled;
  String get unmute;
  String get mute;
  String get firstGreeting;
  String get firstIntro;
  String get appellationHint;
  String get appellationGuide;
  String get startChat;
  String get connectModelFirst;
  String get chatLocallyFirst;
  String get localModeExplanation;
  String get backgroundFailure;
  String get backgroundRecovered;
  String get openSettings;
  String localizeStatus(String message);
}

/// 中文界面词表（当前标准原文，严格保持字面一致）。
class QiyuStringsZh extends QiyuStrings {
  const QiyuStringsZh();

  @override
  String get connectionNormal => '栖语在本机';

  @override
  String get connectionFailed => '连不上本机，点此重试';

  @override
  String get connectionProbing => '正在确认本机连接';

  @override
  String get languageSwitchZh => '中';

  @override
  String get languageSwitchEn => 'EN';

  @override
  String get toggleLanguageSemantics => '切换为英文';

  @override
  String get navigationHistory => '历史';
  @override
  String get navigationMemory => '记忆中心';
  @override
  String get navigationSettings => '设置';
  @override
  String get expandSidebar => '展开侧边栏';
  @override
  String get collapseSidebar => '收起侧边栏';
  @override
  String get closeDrawer => '关闭导航抽屉';
  @override
  String get openNavigation => '打开导航菜单';
  @override
  String get back => '返回上一页';
  @override
  String get greetingMorning => '早上想说点什么？';
  @override
  String get greetingNoon => '中午想说点什么？';
  @override
  String get greetingAfternoon => '下午想说点什么？';
  @override
  String get greetingEvening => '今晚想说点什么？';
  @override
  String get composerHint => '想说点什么…';
  @override
  String get localFallback => '本地规则回复';
  @override
  String get modelConnection => '模型连接';
  @override
  String get checkSettings => '去设置检查';
  @override
  String get preparingMicrophone => '正在准备麦克风…';
  @override
  String recordingAndroid(String clock) => '正在录音 $clock，最长 60 秒';
  @override
  String recordingWeb(String clock) => '正在录音 $clock，再点一次说完，按 Esc 取消';
  @override
  String get transcribing => '正在转文字…';
  @override
  String get transcribingCancelable => '正在转文字…（Esc 中止）';
  @override
  String get transcriptionRetryHint => '转写没有成功，点麦克风重试，Esc 丢弃。';
  @override
  String get voicePreparingRead => '栖语准备读…';
  @override
  String get voiceReading => '栖语正在读';
  @override
  String get stopReading => '停止朗读';
  @override
  String get acknowledge => '知道了';
  @override
  String get qiyuThinking => '栖语在想';
  @override
  String get qiyuReplying => '栖语正在回复';
  @override
  String get qiyuThinkingVisible => '栖语在想…';
  @override
  String get hostStoppedSituation => hostStoppedGateSituation;
  @override
  String get hostStoppedGuidance => hostStoppedGateGuidance;
  @override
  String get switchToHoldToTalk => '切换到按住说话';
  @override
  String get voiceInputUnavailable => '语音输入（当前不可用）';
  @override
  String get voiceInput => '语音输入';
  @override
  String get finishAndTranscribe => '说完，转成文字';
  @override
  String get transcribingButton => '正在转文字';
  @override
  String get retryTranscription => '重试转写';
  @override
  String get switchToTextInput => '切换到文字输入';
  @override
  String get voicePending => '语音待发送，等待当前回复结束';
  @override
  String get cancel => '取消';
  @override
  String get retry => '重试';
  @override
  String get recordAgain => '重新录制';
  @override
  String get discard => '丢弃';
  @override
  String get microphoneUnavailableAndroid => '当前设备无法使用麦克风，请检查安卓系统权限和设备状态。';
  @override
  String get microphoneUnavailableWeb => '当前浏览器不支持语音输入，请换 Chrome 或 Edge。';
  @override
  String get voiceNotConfigured => '还没有配置语音服务，先去设置页填写地址、模型和 Key。';
  @override
  String get goToSettings => '去设置';
  @override
  String get send => '发送';
  @override
  String get stopReply => '停止回复';
  @override
  String get releaseToCancel => '松开取消';
  @override
  String get releaseToSend => '松开发送，上滑取消';
  @override
  String get holdToTalk => '按住说话';
  @override
  String get startRecording => '开始录音';
  @override
  String get finishRecording => '结束并发送';
  @override
  String get cancelRecording => '取消录音';
  @override
  String get youSaid => '你说';
  @override
  String get qiyuSaid => '栖语说';
  @override
  String get incomplete => '未完成';
  @override
  String get readingShort => '正在读';
  @override
  String get replayMessage => '再听一遍这句';
  @override
  String get copyMessage => '复制这条消息';
  @override
  String get voiceVolume => '朗读音量与静音调节';
  @override
  String get voiceDisabled => '语音朗读已关闭，点击开启与调节';
  @override
  String get unmute => '解除静音';
  @override
  String get mute => '静音';
  @override
  String get firstGreeting => '嗨。我是栖语。';
  @override
  String get firstIntro => '栖，是鸟归巢的栖。\n睡不着的时候，可以跟我说说话。';
  @override
  String get appellationHint => '怎么称呼你？';
  @override
  String get appellationGuide => '名字、昵称、代号都行；不想说就先跳过。';
  @override
  String get startChat => '开始聊天';
  @override
  String get connectModelFirst => '先去连上模型';
  @override
  String get chatLocallyFirst => '先聊聊';
  @override
  String get localModeExplanation => '不连模型也能聊，只是回复会简单一些。';
  @override
  String get backgroundFailure => '今晚的记忆整理没完成，下次会自动补';
  @override
  String get backgroundRecovered => '记忆整理已恢复';
  @override
  String get openSettings => '前往设置';
  @override
  String localizeStatus(String message) => message;
}

/// 英文界面词表（地道英文，符合栖语安静低摩擦陪伴气质）。
class QiyuStringsEn extends QiyuStrings {
  const QiyuStringsEn();

  @override
  String get connectionNormal => 'Qiyu is local';

  @override
  String get connectionFailed => 'Local host unreachable, tap to retry';

  @override
  String get connectionProbing => 'Connecting locally...';

  @override
  String get languageSwitchZh => '中';

  @override
  String get languageSwitchEn => 'EN';

  @override
  String get toggleLanguageSemantics => 'Switch to Chinese';

  @override
  String get navigationHistory => 'History';
  @override
  String get navigationMemory => 'Memory Center';
  @override
  String get navigationSettings => 'Settings';
  @override
  String get expandSidebar => 'Expand sidebar';
  @override
  String get collapseSidebar => 'Collapse sidebar';
  @override
  String get closeDrawer => 'Close navigation drawer';
  @override
  String get openNavigation => 'Open navigation menu';
  @override
  String get back => 'Go back';
  @override
  String get greetingMorning => 'Want to talk about something this morning?';
  @override
  String get greetingNoon => 'Want to talk about something today?';
  @override
  String get greetingAfternoon =>
      'Want to talk about something this afternoon?';
  @override
  String get greetingEvening => 'Want to talk about something tonight?';
  @override
  String get composerHint => 'Say something…';
  @override
  String get localFallback => 'Local reply';
  @override
  String get modelConnection => 'Model connection';
  @override
  String get checkSettings => 'Check settings';
  @override
  String get preparingMicrophone => 'Preparing microphone…';
  @override
  String recordingAndroid(String clock) => 'Recording $clock, up to 60 seconds';
  @override
  String recordingWeb(String clock) =>
      'Recording $clock. Tap again to finish, or press Esc to cancel';
  @override
  String get transcribing => 'Transcribing…';
  @override
  String get transcribingCancelable => 'Transcribing… (Esc to stop)';
  @override
  String get transcriptionRetryHint =>
      'Transcription failed. Tap the microphone to retry, or Esc to discard.';
  @override
  String get voicePreparingRead => 'Qiyu is getting ready to read…';
  @override
  String get voiceReading => 'Qiyu is reading';
  @override
  String get stopReading => 'Stop reading';
  @override
  String get acknowledge => 'Got it';
  @override
  String get qiyuThinking => 'Qiyu is thinking';
  @override
  String get qiyuReplying => 'Qiyu is replying';
  @override
  String get qiyuThinkingVisible => 'Qiyu is thinking…';
  @override
  String get hostStoppedSituation =>
      'Qiyu is not running locally, or has been updated.';
  @override
  String get hostStoppedGuidance =>
      'Restart Qiyu on this device, then refresh this page.';
  @override
  String get switchToHoldToTalk => 'Switch to hold to talk';
  @override
  String get voiceInputUnavailable => 'Voice input unavailable';
  @override
  String get voiceInput => 'Voice input';
  @override
  String get finishAndTranscribe => 'Finish and transcribe';
  @override
  String get transcribingButton => 'Transcribing';
  @override
  String get retryTranscription => 'Retry transcription';
  @override
  String get switchToTextInput => 'Switch to text input';
  @override
  String get voicePending => 'Voice message waiting for the current reply';
  @override
  String get cancel => 'Cancel';
  @override
  String get retry => 'Retry';
  @override
  String get recordAgain => 'Record again';
  @override
  String get discard => 'Discard';
  @override
  String get microphoneUnavailableAndroid =>
      'Microphone unavailable. Check Android permissions and device status.';
  @override
  String get microphoneUnavailableWeb =>
      'This browser does not support voice input. Try Chrome or Edge.';
  @override
  String get voiceNotConfigured =>
      'Voice service is not set up yet. Add its address, model, and Key in Settings.';
  @override
  String get goToSettings => 'Go to settings';
  @override
  String get send => 'Send';
  @override
  String get stopReply => 'Stop reply';
  @override
  String get releaseToCancel => 'Release to cancel';
  @override
  String get releaseToSend => 'Release to send, swipe up to cancel';
  @override
  String get holdToTalk => 'Hold to talk';
  @override
  String get startRecording => 'Start recording';
  @override
  String get finishRecording => 'Finish and send';
  @override
  String get cancelRecording => 'Cancel recording';
  @override
  String get youSaid => 'You said';
  @override
  String get qiyuSaid => 'Qiyu said';
  @override
  String get incomplete => 'Incomplete';
  @override
  String get readingShort => 'Reading';
  @override
  String get replayMessage => 'Listen again';
  @override
  String get copyMessage => 'Copy this message';
  @override
  String get voiceVolume => 'Reading volume and mute';
  @override
  String get voiceDisabled => 'Read aloud is off. Tap to turn on or adjust';
  @override
  String get unmute => 'Unmute';
  @override
  String get mute => 'Mute';
  @override
  String get firstGreeting => 'Hi. I’m Qiyu.';
  @override
  String get firstIntro =>
      'My name means a bird returning to its nest.\nIf you can’t sleep, you can talk to me.';
  @override
  String get appellationHint => 'What should I call you?';
  @override
  String get appellationGuide =>
      'Your name, a nickname, anything. You can skip this.';
  @override
  String get startChat => 'Start chatting';
  @override
  String get connectModelFirst => 'Connect a model first';
  @override
  String get chatLocallyFirst => 'Chat for now';
  @override
  String get localModeExplanation =>
      'You can still chat without a model. Replies will be simpler.';
  @override
  String get backgroundFailure =>
      'Tonight’s memory update didn’t finish. Qiyu will retry later';
  @override
  String get backgroundRecovered => 'Memory update resumed';
  @override
  String get openSettings => 'Open settings';
  @override
  String localizeStatus(String message) => switch (message) {
    '回复未完成，可以重新发送。' => 'The reply did not finish. You can try again.',
    '本地聊天暂时不可用，请稍后重试。' =>
      'Local chat is temporarily unavailable. Try again later.',
    '本机聊天暂时不可用，请稍后重试。' =>
      'Local chat is temporarily unavailable. Try again later.',
    '本机程序暂时不可用，请稍后重试。' => 'Qiyu is temporarily unavailable. Try again later.',
    '本机程序返回了无法读取的内容。' =>
      'Qiyu received a response it could not read.',
    '设置服务暂时不可用，请稍后重试。' =>
      'Settings are temporarily unavailable. Try again later.',
    '已允许麦克风，请重新按住说话。' => 'Microphone access granted. Hold to talk again.',
    '无法使用麦克风，请在安卓系统设置中允许麦克风权限。' =>
      'Microphone unavailable. Allow access in Android settings.',
    '无法使用麦克风，请检查麦克风权限或设备状态。' =>
      'Microphone unavailable. Check permissions or device status.',
    '说话时间太短，请重新按住说话' => 'Recording was too short. Hold to talk again.',
    '录音结束失败，请重新说一次。' => 'Recording could not finish. Please try again.',
    '已停止转写，点麦克风重试，Esc 丢弃。' =>
      'Transcription stopped. Tap the microphone to retry, or Esc to discard.',
    '录音已不可用，请重新说一次。' => 'Recording is unavailable. Please try again.',
    '这段录音无法转换成语音服务需要的格式，请重试或重新说一次。' =>
      'Could not prepare this recording for the voice service. Retry or record again.',
    '没有识别到语音，可以再说一次。' => 'No speech detected. Please try again.',
    '转写没有成功，请重试或重新录制。' => 'Transcription failed. Retry or record again.',
    '转写没有成功，点麦克风重试，Esc 丢弃。' =>
      'Transcription failed. Tap the microphone to retry, or Esc to discard.',
    '有句话没合成出来，后面的先不读了。' =>
      'A sentence could not be spoken. Reading has stopped.',
    '语音服务连不上，这条读不出来。' =>
      'The voice service is unavailable. This message cannot be read aloud.',
    '无法播放语音，点小喇叭再听一次。' => 'Audio could not play. Tap the speaker to try again.',
    _ => message,
  };
}

/// 全局语言控制器：广播语言状态变更（Spec Implementation Decisions 1）。
class LocaleController extends ChangeNotifier {
  LocaleController({String initialLocale = 'zh'}) : _locale = initialLocale;

  String _locale;
  String get locale => _locale;
  bool get isZh => _locale == 'zh';
  bool get isEn => _locale == 'en';

  QiyuStrings get strings => QiyuStrings.of(_locale);

  void setLocale(String next) {
    if (_locale == next) return;
    _locale = next;
    notifyListeners();
  }

  void toggle() {
    setLocale(_locale == 'zh' ? 'en' : 'zh');
  }
}

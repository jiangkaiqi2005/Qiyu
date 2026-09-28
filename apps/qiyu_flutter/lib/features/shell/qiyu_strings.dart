import 'package:flutter/foundation.dart';

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

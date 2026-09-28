import 'package:flutter/material.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../shell/qiyu_widgets.dart';
import '../shell/qiyu_ui_locale.dart';

import 'api_error_policy.dart';
import 'local_chat_client.dart';

// 异常类别枚举（含文案）已收进纯 Dart 策略表 api_error_policy.dart，
// 这里原样导出，既有引用面不变。
export 'api_error_policy.dart' show ApiErrorCategory;

/// 只消费 Host 公开的精确错误码；未知故障与网络抖动保留就地提示。
ApiErrorCategory? categorizeVoiceApiError(
  Object error, {
  required bool isInput,
}) {
  if (error is! LocalChatGatewayException) return null;
  return switch ((isInput, error.code)) {
    (true, 'stt_authentication') ||
    (false, 'tts_authentication') => ApiErrorCategory.authentication,
    (true, 'stt_model_not_found') ||
    (false, 'tts_model_not_found') => ApiErrorCategory.modelNotFound,
    (true, 'stt_rate_limited') ||
    (false, 'tts_rate_limited') => ApiErrorCategory.rateLimited,
    (true, 'stt_model_interface_mismatch') => ApiErrorCategory.sttError,
    (false, 'tts_model_interface_mismatch') => ApiErrorCategory.ttsError,
    (true, 'stt_client' || 'stt_config_invalid') => ApiErrorCategory.sttError,
    (false, 'tts_client' || 'tts_config_invalid') => ApiErrorCategory.ttsError,
    _ => null,
  };
}

/// 判断异常对象是否属于 429 限流或 40x 鉴权/模型不存在等配置错误。
bool isVoiceApiError(Object error) =>
    categorizeVoiceApiError(error, isInput: true) != null ||
    categorizeVoiceApiError(error, isInput: false) != null;

/// 接口限流与 40x 异常提示弹窗（ADR 0007 / Spec §2）。
///
/// 遵循 Material 3 AlertDialog，暗夜毛玻璃实底、发丝描边、ink 标题、
/// 降饱和暗红 danger 图标。双按钮布局：次按钮【知道了】关闭并返还焦点，
/// 主要按钮【前往设置】为深鸢尾紫渐变胶囊圆角，无多余中间确认与 toast。
class QiyuApiErrorDialog extends StatelessWidget {
  const QiyuApiErrorDialog({
    super.key,
    required this.category,
    this.customTitle,
    this.customMessage,
    required this.onDismiss,
    required this.onGoToSettings,
  });

  final ApiErrorCategory category;
  final String? customTitle;
  final String? customMessage;
  final VoidCallback onDismiss;
  final VoidCallback onGoToSettings;

  String get title => customTitle ?? category.title;
  String get message => customMessage ?? category.message;

  @override
  Widget build(BuildContext context) {
    final type = QiyuTypography.of(context);
    return AlertDialog(
      key: const Key('api-error-dialog'),
      shape: qiyuCardShape,
      backgroundColor: QiyuColors.panel,
      surfaceTintColor: Colors.transparent,
      icon: const Icon(
        QiyuIcons.error,
        color: QiyuColors.danger,
        size: QiyuIconSpec.size,
      ),
      title: Text(
        customTitle ?? category.titleForLocale(qiyuIsEn(context) ? 'en' : 'zh'),
        textAlign: TextAlign.center,
        style: type.title.copyWith(color: QiyuColors.ink),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: QiyuLayout.dialogContentMaxWidth,
        ),
        child: Text(
          customMessage ??
              category.messageForLocale(qiyuIsEn(context) ? 'en' : 'zh'),
          textAlign: TextAlign.start,
          style: type.body.copyWith(color: QiyuColors.ink),
        ),
      ),
      actionsAlignment: MainAxisAlignment.end,
      actions: [
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.circleBorder,
          child: TextButton(
            key: const Key('api-error-dialog-dismiss'),
            onPressed: onDismiss,
            child: Text(
              qiyuStrings(context).acknowledge,
              style: type.body.copyWith(color: QiyuColors.muted),
            ),
          ),
        ),
        QiyuFocusRingScope(
          borderRadius: QiyuRadii.pillBorder,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              borderRadius: QiyuRadii.pillBorder,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [QiyuColors.accentGlassA, QiyuColors.accentGlassB],
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const Key('api-error-dialog-settings'),
                borderRadius: QiyuRadii.pillBorder,
                onTap: onGoToSettings,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: QiyuSpacing.md,
                    vertical: QiyuSpacing.xs,
                  ),
                  child: Text(
                    qiyuStrings(context).openSettings,
                    style: type.body.copyWith(
                      color: QiyuColors.onAccent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

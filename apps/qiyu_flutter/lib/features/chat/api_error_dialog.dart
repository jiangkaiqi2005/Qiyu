import 'package:flutter/material.dart';

import '../../theme/qiyu_icons.dart';
import '../../theme/qiyu_theme.dart';
import '../../theme/qiyu_tokens.dart';
import '../shell/qiyu_widgets.dart';

import 'local_chat_client.dart';

/// 接口与语音服务异常类型：语义分流与文案定义（Spec §2）。
enum ApiErrorCategory {
  /// 429 请求过于频繁 / 限流
  rateLimited(
    title: '服务请求受限',
    message: '模型服务返回请求过于频繁（429）。本次已为您切换为本地基础模式回复，建议稍后再试或检查服务商用量额度。',
  ),

  /// 401 / 403 鉴权未通过
  authentication(
    title: 'API Key 鉴权失败',
    message: '服务商未通过验证（401/403），通常是 API Key 填写错误、已失效或未开通权限。本次已为您切换为本地基础模式回复。',
  ),

  /// 404 模型未找到
  modelNotFound(
    title: '模型名称不存在',
    message: '服务商未找到当前配置的模型（404）。请检查模型名称拼写，或前往设置确认服务商是否支持该模型。',
  ),

  /// 其他 4xx 客户端异常
  otherClientError(
    title: '模型服务异常',
    message: '服务商返回客户端请求异常。本次已为您切换为本地基础模式回复，建议前往设置检查模型配置。',
  ),

  /// 语音输入（STT 转写）受限
  sttError(
    title: '语音服务受限',
    message: '语音服务请求受限或配置异常。请检查语音服务配置或服务商用量额度。',
  ),

  /// 语音朗读（TTS 合成）受限
  ttsError(
    title: '语音朗读受限',
    message: '语音朗读合成请求受限或配置异常。请检查语音服务配置或服务商用量额度。',
  );

  const ApiErrorCategory({
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  /// 输入框上方状态行频控去重时的轻量提示文案。
  String get noticeText => switch (this) {
    ApiErrorCategory.rateLimited => '⚠️ 接口频繁受限 (429)，当前保持本地基础回复',
    ApiErrorCategory.authentication => '⚠️ API Key 鉴权失败 (401/403)，当前保持本地基础回复',
    ApiErrorCategory.modelNotFound => '⚠️ 模型名称不存在 (404)，当前保持本地基础回复',
    ApiErrorCategory.otherClientError => '⚠️ 模型服务异常，当前保持本地基础回复',
    ApiErrorCategory.sttError => '⚠️ 语音服务频繁受限，当前保持静音',
    ApiErrorCategory.ttsError => '⚠️ 语音朗读频繁受限，当前保持静音',
  };
}

/// 基于结构化错误码或特征识别，精准归类语音链路（TTS / STT）的异常类别。
///
/// 消除基本类型偏执：优先且主要依赖 [LocalChatGatewayException.code]
/// （如 `tts_model_not_found`、`stt_model_not_found`、`tts_rate_limited`、
/// `stt_auth_failed` 等结构化错误码）。仅在 code 为空时降级为严格的特征识别。
ApiErrorCategory? categorizeVoiceApiError(
  Object error, {
  required bool isInput,
}) {
  String? code;
  if (error is LocalChatGatewayException) {
    code = error.code;
  }
  if (code != null && code.isNotEmpty) {
    final c = code.toLowerCase();
    // 无有效语音只需重试或重录，不代表服务配置或额度故障。
    if (c == 'stt_no_speech') return null;
    if (c.contains('model_not_found') ||
        c.contains('not_found') ||
        c.contains('404')) {
      return ApiErrorCategory.modelNotFound;
    }
    if (c.contains('authentication') ||
        c.contains('auth_failed') ||
        c.contains('401') ||
        c.contains('403')) {
      return ApiErrorCategory.authentication;
    }
    if (c.contains('rate_limited') || c.contains('429')) {
      return ApiErrorCategory.rateLimited;
    }
    if (c.contains('stt_') ||
        c.contains('tts_') ||
        c.contains('config_invalid') ||
        c.contains('service_error')) {
      return isInput ? ApiErrorCategory.sttError : ApiErrorCategory.ttsError;
    }
  }

  // code 为空时降级为严格特征识别
  final str = error.toString().toLowerCase();
  if (str.contains('not_found') ||
      str.contains('404') ||
      str.contains('不存在') ||
      str.contains('未找到')) {
    return ApiErrorCategory.modelNotFound;
  }
  if (str.contains('401') ||
      str.contains('403') ||
      str.contains('authentication') ||
      str.contains('未通过验证') ||
      str.contains('鉴权')) {
    return ApiErrorCategory.authentication;
  }
  if (str.contains('429') ||
      str.contains('rate_limited') ||
      str.contains('过于频繁') ||
      str.contains('请求受限')) {
    return ApiErrorCategory.rateLimited;
  }
  if (isInput &&
      (str.contains('stt') ||
          str.contains('转写') ||
          str.contains('语音服务') ||
          str.contains('麦克风'))) {
    return ApiErrorCategory.sttError;
  }
  if (!isInput &&
      (str.contains('tts') ||
          str.contains('朗读') ||
          str.contains('合成') ||
          str.contains('播报'))) {
    return ApiErrorCategory.ttsError;
  }
  return null;
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
        title,
        textAlign: TextAlign.center,
        style: type.title.copyWith(color: QiyuColors.ink),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: QiyuLayout.dialogContentMaxWidth,
        ),
        child: Text(
          message,
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
              '知道了',
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
                    '前往设置',
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

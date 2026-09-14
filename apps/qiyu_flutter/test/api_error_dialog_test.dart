import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/api_error_dialog.dart';
import 'package:qiyu_flutter/features/chat/local_chat_client.dart';
import 'package:qiyu_flutter/theme/qiyu_icons.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

void main() {
  test('voice classification never guesses from message text or code substrings', () {
    for (final error in [
      const LocalChatGatewayException('API Key 鉴权失败 401'),
      const LocalChatGatewayException('unknown', code: 'custom_tts_429'),
      const LocalChatGatewayException('unknown', code: 'tts_network'),
    ]) {
      expect(categorizeVoiceApiError(error, isInput: false), isNull);
    }
  });
  group('QiyuApiErrorDialog', () {
    testWidgets('429 限流：语义标题、正文与按钮布局', (tester) async {
      var dismissed = false;
      var wentToSettings = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: qiyuDarkTheme(),
          home: Scaffold(
            body: QiyuApiErrorDialog(
              category: ApiErrorCategory.rateLimited,
              onDismiss: () => dismissed = true,
              onGoToSettings: () => wentToSettings = true,
            ),
          ),
        ),
      );

      // 验证标题与正文
      expect(find.text('服务请求受限'), findsOneWidget);
      expect(
        find.textContaining('模型服务返回请求过于频繁（429）。本次已为您切换为本地基础模式回复'),
        findsOneWidget,
      );

      // 验证图标与危险色
      final iconFinder = find.byIcon(QiyuIcons.error);
      expect(iconFinder, findsOneWidget);
      final icon = tester.widget<Icon>(iconFinder);
      expect(icon.color, QiyuColors.danger);

      // 验证按钮
      final dismissBtn = find.byKey(const Key('api-error-dialog-dismiss'));
      expect(dismissBtn, findsOneWidget);
      expect(find.text('知道了'), findsOneWidget);

      final settingsBtn = find.byKey(const Key('api-error-dialog-settings'));
      expect(settingsBtn, findsOneWidget);
      expect(find.text('前往设置'), findsOneWidget);
      final settingsText = tester.widget<Text>(find.text('前往设置'));
      expect(settingsText.style?.fontFamily, QiyuType.fontFamily);

      // 点击知道了
      await tester.tap(dismissBtn);
      expect(dismissed, isTrue);

      // 点击前往设置
      await tester.tap(settingsBtn);
      expect(wentToSettings, isTrue);
    });

    testWidgets('401/403 鉴权失败：文案分流', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: qiyuDarkTheme(),
          home: Scaffold(
            body: QiyuApiErrorDialog(
              category: ApiErrorCategory.authentication,
              onDismiss: () {},
              onGoToSettings: () {},
            ),
          ),
        ),
      );

      expect(find.text('API Key 鉴权失败'), findsOneWidget);
      expect(
        find.textContaining('服务商未通过验证（401/403）'),
        findsOneWidget,
      );
    });

    testWidgets('404 模型不存在：文案分流', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: qiyuDarkTheme(),
          home: Scaffold(
            body: QiyuApiErrorDialog(
              category: ApiErrorCategory.modelNotFound,
              onDismiss: () {},
              onGoToSettings: () {},
            ),
          ),
        ),
      );

      expect(find.text('模型名称不存在'), findsOneWidget);
      expect(
        find.textContaining('服务商未找到当前配置的模型（404）'),
        findsOneWidget,
      );
    });

    testWidgets('语音服务（STT / TTS）：文案分流', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: qiyuDarkTheme(),
          home: Scaffold(
            body: Column(
              children: [
                QiyuApiErrorDialog(
                  category: ApiErrorCategory.sttError,
                  onDismiss: () {},
                  onGoToSettings: () {},
                ),
                QiyuApiErrorDialog(
                  category: ApiErrorCategory.ttsError,
                  onDismiss: () {},
                  onGoToSettings: () {},
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('语音服务受限'), findsOneWidget);
      expect(find.text('语音朗读受限'), findsOneWidget);
    });

    test('isVoiceApiError 仅接受公开结构化错误码', () {
      expect(
        isVoiceApiError(const LocalChatGatewayException('任意文案', code: 'stt_rate_limited')),
        isTrue,
      );
      for (final value in [
        'HTTP 429 Too Many Requests',
        'stt_rate_limited',
        '401 Unauthorized',
        '404 Not Found',
        '语音服务请求过于频繁。',
        '鉴权失败，请检查 Key',
      ]) {
        expect(isVoiceApiError(value), isFalse);
      }
    });
    test('categorizeVoiceApiError 结构化错误码与保守未知规则', () {
      expect(
        categorizeVoiceApiError(
          const LocalChatGatewayException(
            '没有识别到语音，可以再说一次。', code: 'stt_no_speech'),
          isInput: true,
        ),
        isNull,
      );
      // 结构化 code 优先
      expect(
        categorizeVoiceApiError(
          const LocalChatGatewayException('error', code: 'tts_model_not_found'),
          isInput: false,
        ),
        ApiErrorCategory.modelNotFound,
      );
      expect(
        categorizeVoiceApiError(
          const LocalChatGatewayException('error', code: 'stt_model_not_found'),
          isInput: true,
        ),
        ApiErrorCategory.modelNotFound,
      );
      expect(
        categorizeVoiceApiError(
          const LocalChatGatewayException('error', code: 'tts_rate_limited'),
          isInput: false,
        ),
        ApiErrorCategory.rateLimited,
      );
      expect(
        categorizeVoiceApiError(
          const LocalChatGatewayException('error', code: 'stt_rate_limited'),
          isInput: true,
        ),
        ApiErrorCategory.rateLimited,
      );
      expect(
        categorizeVoiceApiError(
          const LocalChatGatewayException('error', code: 'stt_authentication'),
          isInput: true,
        ),
        ApiErrorCategory.authentication,
      );
      expect(
        categorizeVoiceApiError(
          const LocalChatGatewayException('error', code: 'tts_authentication'),
          isInput: false,
        ),
        ApiErrorCategory.authentication,
      );
      expect(
        categorizeVoiceApiError(
          const LocalChatGatewayException('error', code: 'stt_client'),
          isInput: true,
        ),
        ApiErrorCategory.sttError,
      );
      expect(
        categorizeVoiceApiError(
          const LocalChatGatewayException('error', code: 'tts_config_invalid'),
          isInput: false,
        ),
        ApiErrorCategory.ttsError,
      );

      // 缺少类别、网络与未知码都不根据错误文案推断。
      for (final code in [null, 'tts_network', 'tts_dns', 'tts_tls',
        'tts_timeout', 'tts_provider', 'tts_internal', 'stt_service_error',
        'tts_incompatible_response', 'stt_no_speech', 'tts_turn_not_found']) {
        expect(
          categorizeVoiceApiError(
            LocalChatGatewayException('模型不存在 404 鉴权失败 401', code: code),
            isInput: false,
          ),
          isNull,
        );
      }
      expect(
        categorizeVoiceApiError(
          const LocalChatGatewayException('任意文案', code: 'stt_rate_limited'),
          isInput: false,
        ),
        isNull,
      );
    });
    test('noticeText 频控提示文案', () {
      expect(
        ApiErrorCategory.rateLimited.noticeText,
        '⚠️ 接口频繁受限 (429)，当前保持本地基础回复',
      );
      expect(
        ApiErrorCategory.authentication.noticeText,
        '⚠️ API Key 鉴权失败 (401/403)，当前保持本地基础回复',
      );
      expect(
        ApiErrorCategory.modelNotFound.noticeText,
        '⚠️ 模型名称不存在 (404)，当前保持本地基础回复',
      );
    });
  });
}

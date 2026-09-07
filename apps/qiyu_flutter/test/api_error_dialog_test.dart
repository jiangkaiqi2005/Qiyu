import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qiyu_flutter/features/chat/api_error_dialog.dart';
import 'package:qiyu_flutter/theme/qiyu_icons.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

void main() {
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

    test('isVoiceApiError 异常判定规则', () {
      expect(isVoiceApiError('HTTP 429 Too Many Requests'), isTrue);
      expect(isVoiceApiError('stt_rate_limited'), isTrue);
      expect(isVoiceApiError('tts_rate_limited'), isTrue);
      expect(isVoiceApiError('401 Unauthorized'), isTrue);
      expect(isVoiceApiError('403 Forbidden'), isTrue);
      expect(isVoiceApiError('404 Not Found'), isTrue);
      expect(isVoiceApiError('语音服务请求过于频繁。'), isTrue);
      expect(isVoiceApiError('鉴权失败，请检查 Key'), isTrue);

      expect(isVoiceApiError('Connection timeout'), isFalse);
      expect(isVoiceApiError('Network connection lost'), isFalse);
      expect(isVoiceApiError('SocketException: host unreachable'), isFalse);
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

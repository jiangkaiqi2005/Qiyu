import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_section.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/settings_section_shell.dart';
import 'package:qiyu_flutter/theme/qiyu_theme.dart';
import 'package:qiyu_flutter/theme/qiyu_tokens.dart';

/// 「高级参数」分节悬浮标签的几何回归。
///
/// ExpansionTile 展开体外层是一圈恒裁剪的 [ClipRect]（SDK `expansible.dart`
/// 的展开体 builder），完全展开时裁剪上沿与首行字段容器顶边重合；而
/// [InputDecorator] 的悬浮标签以边框线为中心缩放 0.75 摆放，会向上伸出边框
/// 约 5px——childrenPadding 不给顶部余量时，标签在边框线以上的整半截字形
/// 会被展开体裁掉。字段有内容（缺省 0.7 / 60）时标签即处于悬浮态，静置就
/// 触发，与获焦无关。
void main() {
  testWidgets('展开高级参数后，temperature 与超时（秒）的悬浮标签不被展开体裁剪', (tester) async {
    final viewModel = ProviderSettingsViewModel(
      _UnconfiguredProviderSettingsGateway(),
      autoStart: false,
    );
    await viewModel.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: qiyuDarkTheme(),
        home: Scaffold(
          body: ChangeNotifierProvider<ProviderSettingsViewModel>.value(
            value: viewModel,
            child: SingleChildScrollView(
              child: SettingsSectionCollapseScope(
                collapsed: const <String>{},
                onToggle: (_) {},
                child: const ProviderSettingsSection(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('provider-advanced-settings')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('provider-advanced-settings')));
    await tester.pumpAndSettle();

    // 核心判据是几何断言：标签绘制盒顶端不得低于展开体裁剪上沿。它不随
    // 主题或装饰器摆放规则漂移失守；样式锁（childrenPadding 的 8px 余量）
    // 则是这条约束在 widget 上的落点，余量被拿掉时这里当场红。
    for (final (fieldKey, labelText) in const [
      (Key('provider-temperature'), 'temperature'),
      (Key('provider-timeout'), '超时（秒）'),
    ]) {
      final field = tester.widget<TextField>(find.byKey(fieldKey));
      final border = field.decoration?.border as OutlineInputBorder?;
      expect(border?.borderRadius, QiyuRadii.smallBorder);

      final label = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(fieldKey),
          matching: find.text(labelText),
        ),
      );
      // 悬浮标签经装饰器的 _labelTransform 缩放 0.75 后才落到屏幕上：绘制盒
      // 是布局盒经整条 paint transform（applyPaintTransform 会应用该变换）
      // 映射后的那一份，不是标签 RenderParagraph 自身的布局位置。
      final labelRect = MatrixUtils.transformRect(
        label.getTransformTo(null),
        Offset.zero & label.size,
      );

      // 最近的 RenderClipRect 祖先＝ExpansionTile 展开体那道恒裁剪。
      RenderClipRect? clip;
      RenderObject? node = label.parent;
      while (node != null && clip == null) {
        if (node is RenderClipRect) {
          clip = node;
        }
        node = node.parent;
      }
      expect(
        clip,
        isNotNull,
        reason:
            '$labelText 的祖先链上找不到展开体的 ClipRect：展开体结构变了，'
            '这条几何断言已测不到目标',
      );

      final clipTop = clip!.localToGlobal(Offset.zero).dy;
      expect(
        labelRect.top,
        greaterThanOrEqualTo(clipTop - 0.5),
        reason:
            '$labelText 的悬浮标签绘制盒顶端（${labelRect.top.toStringAsFixed(2)}）'
            '低于裁剪上沿（${clipTop.toStringAsFixed(2)}）：标签上沿被展开体裁掉',
      );
    }

    // 样式锁：顶部 8px 余量就是上面那条几何约束在 widget 上的落点。
    expect(
      tester
          .widget<ExpansionTile>(
            find.byKey(const Key('provider-advanced-settings')),
          )
          .childrenPadding,
      const EdgeInsets.only(top: 8, bottom: 8),
      reason:
          'ExpansionTile 展开体自带恒裁剪的 ClipRect，childrenPadding 必须给'
          '悬浮标签留顶部余量（与 TTS 设置 tile 的 Padding(top: 8) 同值）',
    );
  });
}

/// 未配置 Provider 的固定网关：让分节以未配置形态渲染，temperature 与超时
/// 两个字段保留表单缺省值（有内容，标签悬浮在边框线上）。
final class _UnconfiguredProviderSettingsGateway
    implements ProviderSettingsGateway {
  @override
  Future<ProviderSettings> read() async =>
      const ProviderSettings(configured: false, keySet: false);

  @override
  Future<ProviderSettings> save(ProviderSettingsDraft draft) =>
      throw UnimplementedError();

  @override
  Future<ProviderSettings> forgetApiKey() => throw UnimplementedError();

  @override
  Future<ProviderTestResult> testConnection(ProviderSettingsDraft draft) =>
      throw UnimplementedError();
}

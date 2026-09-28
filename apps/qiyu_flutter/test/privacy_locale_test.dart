import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/settings/privacy_view.dart';
import 'package:qiyu_flutter/features/settings/diagnostics_view.dart';
import 'package:qiyu_flutter/features/settings/settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_view_model.dart';
import 'package:qiyu_flutter/features/shell/qiyu_strings.dart';

void main() {
  testWidgets('隐私说明随语言原地切换且英文救助说明使用 988', (tester) async {
    final locale = LocaleController();
    addTearDown(locale.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<LocaleController>.value(
        value: locale,
        child: const MaterialApp(home: PrivacyView()),
      ),
    );
    expect(find.text('隐私与边界'), findsOneWidget);
    locale.setLocale('en');
    await tester.pump();
    expect(find.text('Privacy & boundaries'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('988'), 200);
    expect(find.textContaining('988'), findsOneWidget);
    expect(find.text('隐私与边界'), findsNothing);
  });

  testWidgets('诊断页标题和固定状态随语言原地切换', (tester) async {
    final locale = LocaleController();
    final viewModel = SettingsViewModel(_DiagnosticsGateway());
    addTearDown(locale.dispose);
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LocaleController>.value(value: locale),
          ChangeNotifierProvider<SettingsViewModel>.value(value: viewModel),
        ],
        child: const MaterialApp(home: DiagnosticsView()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('开发者诊断'), findsOneWidget);
    locale.setLocale('en');
    await tester.pump();
    expect(find.text('Developer diagnostics'), findsOneWidget);
    expect(find.text('Recent requests (this launch)'), findsOneWidget);
    expect(find.text('开发者诊断'), findsNothing);
  });
}

class _DiagnosticsGateway implements SettingsGateway {
  @override
  Future<DiagnosticsSnapshot> readDiagnostics() async => DiagnosticsSnapshot(
    generatedAt: DateTime(2026, 9, 28),
    memoryDirectory: r'C:\Qiyu',
    recentRequests: const [],
    finalization: null,
    dream: null,
    fileHealth: const {},
  );

  @override
  Future<ExperiencePreferences> readPreferences() => throw UnimplementedError();
  @override
  Future<ExperiencePreferences> savePreferences({
    required bool developerMode,
  }) => throw UnimplementedError();
  @override
  Future<MemoryControlsOverview> readMemoryControls() =>
      throw UnimplementedError();
  @override
  Future<ClearPreview> readClearPreview() => throw UnimplementedError();
  @override
  Future<void> clearData() => throw UnimplementedError();
}

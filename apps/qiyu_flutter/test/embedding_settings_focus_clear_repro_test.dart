import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qiyu_flutter/features/settings/embedding_settings_client.dart';
import 'package:qiyu_flutter/features/settings/embedding_settings_section.dart';
import 'package:qiyu_flutter/features/settings/embedding_settings_view_model.dart';
import 'package:qiyu_flutter/features/settings/provider_settings_client.dart';
import 'package:qiyu_flutter/features/settings/settings_section_shell.dart';

/// 回归测试：记忆召回设置区块「切换焦点互相清空」。
///
/// 用户症状（真机验收 2026-10-09）：在「服务地址」输入内容后点击
/// 「模型名称」输入框，服务地址的内容消失；重新输入服务地址后模型
/// 名称又消失；三个输入框互相清空。
///
/// 机制（诊断报告 `.scratch/bugfix-recall-settings/diagnosis.md`）：
/// 区块 2 秒一次的可见期刷新（票 03 的状态轮询）经 fromJson 产生新
/// 设置快照对象，表单同步以 `identical` 判新，轮询快照永远「新」—
/// 失焦输入框按已保存值重灌（未配置时为空串），API Key 草稿被同步
/// 收尾清空。修复把同步判等收口为按内容比较（壳层
/// `SettingsCredentialForm.settingsContentEquals`）：值未变的轮询快
/// 照不得重灌任何输入框；保存、忘记 Key 这类内容确实变化的显式动作
/// 照常回显与清理。前三条用例钉住草稿保留（修复前在此变红），后三
/// 条钉住连带行为：保存读到用户眼前草稿、保存后新值回显、忘记 Key
/// 清 Key 草稿。
void main() {
  final gateway = _StaticEmbeddingGateway();
  late EmbeddingSettingsViewModel viewModel;

  setUp(() {
    gateway.reset();
    viewModel = EmbeddingSettingsViewModel(gateway, autoStart: false);
  });

  Future<void> pumpSection(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await viewModel.initialize();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: viewModel,
        child: MaterialApp(
          home: Scaffold(
            body: SettingsSectionCollapseScope(
              collapsed: const {},
              onToggle: (_) {},
              child: ListView(children: const [EmbeddingSettingsSection()]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 区块挂载期持有状态刷新计时器：测试结束时卸载整树，dispose 取消
    // 计时器，不留 pending timer。
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  testWidgets('回归：服务地址输入后点击模型名称框，服务地址草稿不被轮询同步清空', (tester) async {
    await pumpSection(tester);

    const typedUrl = 'https://my-host.example.com/v1';
    await tester.enterText(find.byKey(const Key('embedding-base-url')), typedUrl);
    await tester.pump(); // 只推一帧，不推进假时钟。

    // 用户动作：点击「模型名称」输入框（只点击，不输入）。
    await tester.tap(find.byKey(const Key('embedding-model')));
    await tester.pump();

    // 点击本身不清空任何内容。
    final before = tester.widget<TextField>(
      find.byKey(const Key('embedding-base-url')),
    );
    expect(before.controller!.text, typedUrl, reason: '点击另一输入框本身不应清空服务地址');

    // 区块 2 秒一次的可见期刷新到拍：产生新的设置快照对象并重建。
    // 值未变，同步判等必须跳过——失焦字段不得按已保存值重灌。
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    final after = tester.widget<TextField>(
      find.byKey(const Key('embedding-base-url')),
    );
    expect(after.controller!.text, typedUrl, reason: '焦点切走并被轮询刷新后服务地址草稿仍应保留');
  });

  testWidgets('回归：重新输入服务地址后，模型名称草稿同样保留（对称方向）', (tester) async {
    await pumpSection(tester);

    const typedUrl = 'https://my-host.example.com/v1';
    const typedModel = 'my-embedding-model';
    await tester.enterText(find.byKey(const Key('embedding-base-url')), typedUrl);
    await tester.pump();
    // enterText 会把焦点切到模型名称框（等价于用户点过去再输入）。
    await tester.enterText(find.byKey(const Key('embedding-model')), typedModel);
    await tester.pump();

    // 第一拍刷新：修复前服务地址失焦被清空。
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    // 用户重新输入服务地址（焦点切回，模型名称随之失焦）。
    await tester.enterText(find.byKey(const Key('embedding-base-url')), typedUrl);
    await tester.pump();

    // 第二拍刷新：修复前模型名称失焦被清空。
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    final modelField = tester.widget<TextField>(
      find.byKey(const Key('embedding-model')),
    );
    expect(modelField.controller!.text, typedModel, reason: '焦点切走并被轮询刷新后模型名称草稿仍应保留');
  });

  testWidgets('回归：API Key 输入后焦点切走，轮询同步不清空 Key 草稿', (tester) async {
    await pumpSection(tester);

    const typedKey = 'sk-embed-secret';
    await tester.enterText(find.byKey(const Key('embedding-api-key')), typedKey);
    await tester.pump();
    await tester.tap(find.byKey(const Key('embedding-base-url')));
    await tester.pump();

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    final keyField = tester.widget<TextField>(
      find.byKey(const Key('embedding-api-key')),
    );
    expect(keyField.controller!.text, typedKey, reason: '焦点切走并被轮询刷新后 API Key 草稿仍应保留');
  });

  testWidgets('回归：轮询到拍后点保存，写入的是用户眼前的草稿（含 Key）', (tester) async {
    await pumpSection(tester);

    const typedUrl = 'https://my-host.example.com/v1';
    const typedModel = 'my-embedding-model';
    const typedKey = 'sk-embed-secret';
    await tester.enterText(find.byKey(const Key('embedding-base-url')), typedUrl);
    await tester.enterText(find.byKey(const Key('embedding-model')), typedModel);
    await tester.enterText(find.byKey(const Key('embedding-api-key')), typedKey);
    // 把焦点切到地址框，三个草稿字段全部失焦，再等轮询到拍。
    await tester.tap(find.byKey(const Key('embedding-base-url')));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    // 草稿原样保留的前提下保存：写入的必须就是眼前所见——不出现
    // 「Key 静默丢失仍保存成功」「旧值＋新值混合配置」的连带行为。
    await tester.tap(find.byKey(const Key('save-embedding-settings')));
    await tester.pumpAndSettle();

    expect(gateway.savedDrafts, hasLength(1));
    expect(gateway.savedDrafts.single.baseUrl, typedUrl);
    expect(gateway.savedDrafts.single.model, typedModel);
    expect(gateway.savedDrafts.single.apiKey, typedKey);
  });

  testWidgets('回归：保存成功后已保存值回显表单（草稿保护不吞显式动作的回显）', (tester) async {
    await pumpSection(tester);

    // 地址带空白输入（保存会 trim）：已保存值与框内草稿不同，保存后
    // 的回显必须真实落框——草稿保护不能让表单永不刷新。模型框保存
    // 时仍获焦，按获焦保护保持草稿（既有语义），故只断言地址框。
    await tester.enterText(
      find.byKey(const Key('embedding-base-url')),
      ' https://my-host.example.com/v1 ',
    );
    await tester.enterText(
      find.byKey(const Key('embedding-model')),
      'my-embedding-model',
    );
    await tester.tap(find.byKey(const Key('save-embedding-settings')));
    await tester.pumpAndSettle();

    expect(gateway.savedDrafts, hasLength(1));
    expect(gateway.savedDrafts.single.baseUrl, 'https://my-host.example.com/v1');
    final urlField = tester.widget<TextField>(
      find.byKey(const Key('embedding-base-url')),
    );
    expect(
      urlField.controller!.text,
      'https://my-host.example.com/v1',
      reason: '保存成功后表单应回显已保存的新值',
    );
  });

  testWidgets('回归：忘记 Key 是显式动作——keySet 变化照常触发同步，Key 草稿清空', (tester) async {
    gateway.configured = true;
    gateway.keySet = true;
    gateway.baseUrl = 'https://my-host.example.com/v1';
    gateway.model = 'my-embedding-model';
    await pumpSection(tester);

    // 输入 Key 草稿后把焦点切走（忘记 Key 的清空语义只作用于未获焦
    // 的草稿，既有获焦保护不变）。
    const typedKey = 'sk-embed-secret';
    await tester.enterText(find.byKey(const Key('embedding-api-key')), typedKey);
    await tester.tap(find.byKey(const Key('embedding-base-url')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('forget-embedding-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('embedding-forget-key-confirm')));
    await tester.pumpAndSettle();
    expect(gateway.forgetCalls, 1);

    // keySet true→false 参与内容判等：同步照常执行，Key 草稿被清，
    // 不因「值未变跳过」而残留明文草稿。
    final keyField = tester.widget<TextField>(
      find.byKey(const Key('embedding-api-key')),
    );
    expect(
      keyField.controller!.text,
      isEmpty,
      reason: '忘记 Key 后未获焦的 Key 草稿应被清空（显式动作语义保持）',
    );
  });
}

/// 只服务于本文件的静态网关：read 每次返回**新**的设置快照对象（与
/// `HttpEmbeddingSettingsGateway.read` 的反序列化行为同形），轮询节拍
/// 因此总能拿到新对象。默认未配置（已保存地址与模型为空），对应用户
/// 首次填写配置的场景；显式动作用例可预置状态，save／forgetApiKey 落
/// 地后返回同样以新实例呈现的快照。
final class _StaticEmbeddingGateway implements EmbeddingSettingsGateway {
  bool configured = false;
  bool keySet = false;
  bool enabled = false;
  String? baseUrl;
  String? model;
  final savedDrafts = <EmbeddingSettingsDraft>[];
  int readCalls = 0;
  int forgetCalls = 0;

  void reset() {
    configured = false;
    keySet = false;
    enabled = false;
    baseUrl = null;
    model = null;
    savedDrafts.clear();
    readCalls = 0;
    forgetCalls = 0;
  }

  EmbeddingSettings _snapshot() => EmbeddingSettings(
    configured: configured,
    keySet: keySet,
    enabled: enabled,
    baseUrl: baseUrl,
    model: model,
  );

  @override
  Future<EmbeddingSettings> read() async {
    readCalls += 1;
    return _snapshot();
  }

  @override
  Future<EmbeddingSettings> save(EmbeddingSettingsDraft draft) async {
    savedDrafts.add(draft);
    configured = true;
    baseUrl = draft.baseUrl;
    model = draft.model;
    if (draft.apiKey != null) {
      keySet = true;
    }
    return _snapshot();
  }

  @override
  Future<EmbeddingSettings> forgetApiKey() async {
    forgetCalls += 1;
    keySet = false;
    return _snapshot();
  }

  @override
  Future<ProviderTestResult> testConnection(EmbeddingSettingsDraft draft) async =>
      const ProviderTestResult(
        succeeded: true,
        status: ProviderTestStatus.success,
        message: '连接成功，记忆召回服务可以使用。',
      );

  @override
  Future<EmbeddingSettings> enable() async {
    enabled = true;
    return _snapshot();
  }

  @override
  Future<EmbeddingSettings> disable() async {
    enabled = false;
    return _snapshot();
  }

  @override
  Future<EmbeddingSettings> rebuild() async => _snapshot();
}
